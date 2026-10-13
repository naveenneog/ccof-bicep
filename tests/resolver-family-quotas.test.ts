import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveRequest } from "../src/resolver/decide.ts";
import { handleResolveRequest } from "../src/resolver/http-handler.ts";
import {
  activeMembership,
  context,
  entitlementWithMembership,
  fakeReads,
  RESOLVE_NOW,
  STD_TOKEN_LIMITS,
  tokenLimitsOnlyContext,
} from "./helpers/resolver-fixtures.ts";

const groupId = "00000000-0000-4000-8000-000001101101";
const policy = {
  aggregateLimits: STD_TOKEN_LIMITS,
  families: {
    haiku: {
      models: ["claude-haiku-4-5", "claude-haiku-4-5-20261001"],
      person: { tokensPerMinute: 100, tokenQuota: 200, tokenQuotaPeriod: "Daily" },
      group: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null },
    },
  },
};
const membership = { ...activeMembership, classificationGroupId: groupId, familyPolicy: policy };
const recordWith = (value: unknown) => ({ ...entitlementWithMembership, projectMemberships: [value] });
const resolve = (value: unknown = membership) => resolveRequest(
  { personId: "person-1" },
  fakeReads({ readEntitlement: async () => recordWith(value) }),
  tokenLimitsOnlyContext(),
);

test("family v3: selected trusted policy and normalized group GUID replace legacy fields", async () => {
  const result = await resolve({ ...membership, classificationGroupId: groupId.toUpperCase() });
  assert.equal(result.refused, false);
  assert.equal(result.decisionVersion, 3);
  assert.equal(result.classificationGroupId, groupId);
  assert.deepEqual(result.familyPolicy, policy);
  assert.equal("modelAllowList" in result, false);
  assert.equal("tokenLimits" in result, false);
});

test("family v3: policy changes do not mutate aggregate ceilings or stored policy", async () => {
  const stored = structuredClone(membership);
  const before = structuredClone(stored);
  const result = await resolve(stored);
  assert.equal(result.refused, false);
  assert.deepEqual(result.familyPolicy.aggregateLimits, STD_TOKEN_LIMITS);
  assert.ok(result.familyPolicy.families.haiku);
  result.familyPolicy.families.haiku.models.push("claude-haiku-unknown");
  assert.deepEqual(stored, before);
});

const malformedPolicies: Array<[string, unknown]> = [
  ["missing policy", undefined],
  ["null policy", null],
  ["legacy limits alone", STD_TOKEN_LIMITS],
  ["missing aggregate limits", { families: policy.families }],
  ["missing families", { aggregateLimits: policy.aggregateLimits }],
  ["no families", { ...policy, families: {} }],
  ["unknown family", { ...policy, families: { unknown: policy.families.haiku } }],
  ["unknown policy property", { ...policy, unlimited: true }],
  ["empty model array", { ...policy, families: { haiku: { ...policy.families.haiku, models: [] } } }],
  ["duplicate exact model", { ...policy, families: { haiku: { ...policy.families.haiku, models: ["alias", "alias"] } } }],
  ["duplicate across families", { ...policy, families: {
    haiku: { ...policy.families.haiku, models: ["alias"] },
    sonnet: { ...policy.families.haiku, models: ["alias"] },
  } }],
  ["canonical family mismatch", { ...policy, families: { haiku: { ...policy.families.haiku, models: ["claude-sonnet-5"] } } }],
  ["invalid canonical prefix", { ...policy, families: { haiku: { ...policy.families.haiku, models: ["claude-haikux-5"] } } }],
  ["model wildcard", { ...policy, families: { haiku: { ...policy.families.haiku, models: ["*"] } } }],
];
for (const [name, familyPolicy] of malformedPolicies) {
  test(`family v3: ${name} fails closed before any routing/budget read`, async () => {
    const reads: string[] = [];
    const result = await resolveRequest(
      { personId: "person-1" },
      fakeReads({
        readEntitlement: async () => recordWith({ ...membership, familyPolicy }),
        readBackend: async () => { reads.push("backend"); return null; },
        readBudgetState: async () => { reads.push("budget"); return null; },
        readAggregateBudgetState: async () => { reads.push("aggregate"); return null; },
      }),
      context(),
    );
    assert.equal(result.refused, true);
    assert.equal(result.reason, "entitlement_record_invalid");
    assert.equal(result.detail, "invalid_family_policy");
    assert.equal(result.httpStatus, 503);
    assert.deepEqual(reads, []);
  });
}

const invalidLimits: Array<[string, Record<string, unknown>]> = [
  ["zero TPM", { tokensPerMinute: 0 }],
  ["negative TPM", { tokensPerMinute: -1 }],
  ["fractional TPM", { tokensPerMinute: 1.5 }],
  ["string TPM", { tokensPerMinute: "100" }],
  ["overflow TPM", { tokensPerMinute: 2147483648 }],
  ["unsafe quota", { tokenQuota: 9007199254740992 }],
  ["unpaired quota", { tokenQuotaPeriod: null }],
  ["unpaired period", { tokenQuota: null }],
  ["invalid period", { tokenQuotaPeriod: "daily" }],
  ["extra limit field", { unlimited: true }],
  ["missing field", { tokensPerMinute: undefined }],
];
for (const [name, change] of invalidLimits) {
  for (const scope of ["aggregate", "family"] as const) {
    test(`family v3: ${scope} ${name} fails closed`, async () => {
      const familyPolicy = structuredClone(policy);
      if (scope === "aggregate") Object.assign(familyPolicy.aggregateLimits.person, change);
      else Object.assign(familyPolicy.families.haiku.person, change);
      const result = await resolve({ ...membership, familyPolicy });
      assert.equal(result.refused, true);
      assert.equal(result.detail, "invalid_family_policy");
      assert.equal(result.httpStatus, 503);
    });
  }
}

for (const family of ["fable", "mythos"]) {
  for (const classification of ["STD", "PRM", "cyb", "CYB-extra"]) {
    test(`family v3: ${classification} cannot store restricted ${family}`, async () => {
      const familyPolicy = { ...policy, families: { ...policy.families, [family]: policy.families.haiku } };
      const result = await resolve({ ...membership, classification, familyPolicy, classificationGroupDisplayName: "CYB Approved" });
      assert.equal(result.refused, true);
      assert.equal(result.detail, "family_classification_forbidden");
      assert.equal(result.httpStatus, 503);
    });
  }
}

test("family v3: exact CYB accepts explicitly registered restricted aliases", async () => {
  const familyPolicy = {
    ...policy,
    families: { mythos: { ...policy.families.haiku, models: ["registered-private-alias"] } },
  };
  const result = await resolve({ ...membership, classification: "CYB", familyPolicy });
  assert.equal(result.refused, false);
  assert.deepEqual(result.familyPolicy, familyPolicy);
});

test("family v3: old allow-list and token limits cannot synthesize a missing policy", async () => {
  const result = await resolve({
    ...membership,
    familyPolicy: undefined,
    modelAllowList: ["claude-haiku-4-5"],
    tokenLimits: STD_TOKEN_LIMITS,
  });
  assert.equal(result.refused, true);
  assert.equal(result.detail, "invalid_family_policy");
  assert.equal(result.httpStatus, 503);
});

test("family v3: all-null family limits retain aggregate ceilings without budget reads", async () => {
  const none = { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null };
  const familyPolicy = {
    ...policy,
    families: { haiku: { models: ["claude-haiku-4-5"], person: none, group: none } },
  };
  const calls: string[] = [];
  const result = await resolveRequest({ personId: "person-1" }, fakeReads({
    readEntitlement: async () => { calls.push("entitlement"); return recordWith({ ...membership, familyPolicy, aggregateMode: "strict" }); },
    readBackend: async () => { calls.push("backend"); return null; },
    readBudgetState: async () => { calls.push("person-budget"); return null; },
    readAggregateBudgetState: async () => { calls.push("group-budget"); return null; },
    readSubscriptionIndex: async () => { calls.push("key"); return null; },
  }), tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
  assert.deepEqual(result.familyPolicy, familyPolicy);
  assert.deepEqual(calls, ["entitlement", "backend"]);
  assert.equal(result.aggregateStrict, false);
  assert.equal(result.personCeilingTokensPerMinute, null);
});

for (const classificationGroupId of [undefined, null, "", "group-std", "{00000000-0000-4000-8000-000001101101}", `${groupId}\n`, 42]) {
  test(`family v3: malformed classification group ${JSON.stringify(classificationGroupId)} fails closed`, async () => {
    const result = await resolve({ ...membership, classificationGroupId });
    assert.equal(result.refused, true);
    assert.equal(result.detail, "invalid_classification_group_id");
    assert.equal(result.httpStatus, 503);
  });
}

test("family v3: an informational group name is preserved exactly, never inferred", async () => {
  const name = '  CYB Approved — "例"  ';
  const result = await resolve({ ...membership, classificationGroupDisplayName: name });
  assert.equal(result.refused, false);
  assert.equal(result.classification, "STD");
  assert.equal(result.classificationGroupDisplayName, name);
  const without = await resolve({ ...membership, classificationGroupDisplayName: 42 });
  assert.equal(without.refused, false);
  assert.equal("classificationGroupDisplayName" in without, false);
});

test("family v3: malformed policy in another project remains isolated on selector and key paths", async () => {
  const other = { ...membership, projectId: "OTHER", familyPolicy: undefined };
  const deps = fakeReads({ readEntitlement: async () => ({ ...entitlementWithMembership, projectMemberships: [other, membership] }) });
  for (const input of [
    { personId: "person-1", projectId: membership.projectId },
    { personId: "person-1", subscriptionId: "sub-abc" },
  ]) {
    const result = await resolveRequest(input, deps, tokenLimitsOnlyContext());
    assert.equal(result.refused, false);
    assert.deepEqual(result.familyPolicy, policy);
  }
  const refused = await resolveRequest({ personId: "person-1", projectId: "OTHER" }, deps, tokenLimitsOnlyContext());
  assert.equal(refused.refused, true);
  assert.equal(refused.detail, "invalid_family_policy");
});

test("family v3 HTTP: ignores request classification/family/group overrides and exposes v3 only", async () => {
  const response = await handleResolveRequest({
    platformAuthEnabled: true,
    authenticatedPrincipal: true,
    body: { personId: "person-1", classification: "CYB", modelFamily: "mythos", classificationGroupId: "forged" },
  }, {
    readiness: { ready: true, reads: fakeReads({ readEntitlement: async () => recordWith(membership) }), budgetEnforcement: { mode: "token-limits-only" }, requestDeadlineMs: 1000 },
    now: () => RESOLVE_NOW,
    log: () => {},
  });
  assert.equal(response.status, 200);
  assert.equal(response.jsonBody.resolverOutcome, "success");
  assert.equal(response.jsonBody.decisionVersion, 3);
  assert.equal(response.jsonBody.classification, "STD");
  assert.equal(response.jsonBody.classificationGroupId, groupId);
  assert.deepEqual(response.jsonBody.familyPolicy, policy);
});

test("family v3 HTTP: invalid policy detail is server-side only", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest({
    platformAuthEnabled: true, authenticatedPrincipal: true, body: { personId: "person-1" },
  }, {
    readiness: { ready: true, reads: fakeReads({ readEntitlement: async () => recordWith({ ...membership, familyPolicy: null }) }), budgetEnforcement: { mode: "token-limits-only" }, requestDeadlineMs: 1000 },
    now: () => RESOLVE_NOW,
    log: (line) => logs.push(line),
  });
  assert.deepEqual(response, { status: 503, jsonBody: { error: "temporarily_unavailable", resolverOutcome: "unavailable" } });
  assert.equal(JSON.parse(logs[0]).detail, "invalid_family_policy");
});
