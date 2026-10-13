// The M1.7 pilot contract (docs/PILOT.md C-1 to C-4), through resolveRequest:
// - C-1 a request may name its project with a selector instead of a
//   subscription key; without either, the single active membership is used;
// - C-2 the selected membership's aggregate limits are retained in familyPolicy;
// - C-3 in token-limits-only mode no budget document is read;
// - C-4 subscriptionId is optional on a membership, and an empty membership
//   list is the same refusal as a missing document.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveRequest } from "../src/resolver/decide.ts";
import {
  activeMembership,
  context,
  entitlementWithMembership,
  fakeReads,
  STD_TOKEN_LIMITS,
  STD_FAMILY_POLICY,
  tokenLimitsOnlyContext,
} from "./helpers/resolver-fixtures.ts";

const prmMembership = {
  ...activeMembership,
  projectId: "SAMPLEORGAIAZ210",
  classification: "PRM",
  classificationGroupId: "44444444-4444-4444-4444-444444444444",
  backendId: "foundry-other",
  familyPolicy: {
    ...STD_FAMILY_POLICY,
    aggregateLimits: {
      person: { tokensPerMinute: 1000000, tokenQuota: 2000000, tokenQuotaPeriod: "Daily" as const },
      group: { tokensPerMinute: null, tokenQuota: 5000000, tokenQuotaPeriod: "Daily" as const },
    },
  },
};
const { subscriptionId: _unused, ...membershipWithoutKey } = activeMembership;
const twoProjects = { ...entitlementWithMembership, projectMemberships: [activeMembership, prmMembership] };

// Records every read; the selector path must never touch subscriptionIndex.
function countingReads(entitlement: unknown) {
  const calls: string[] = [];
  const deps = fakeReads({
    readSubscriptionIndex: async () => {
      calls.push("subscriptionIndex");
      return null;
    },
    readEntitlement: async () => {
      calls.push("entitlement");
      return entitlement;
    },
    readBudgetState: async () => {
      calls.push("budgetState");
      return null;
    },
    readAggregateBudgetState: async () => {
      calls.push("aggregateBudgetState");
      return null;
    },
  });
  return { deps, calls };
}

// ---- C-1 project selection ----

test("C-1: with no key and no selector, the single active membership is used", async () => {
  const { deps, calls } = countingReads({ ...entitlementWithMembership, projectMemberships: [membershipWithoutKey] });
  const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
  assert.equal(result.projectId, "SAMPLEORGAIAZ103");
  assert.equal(result.classification, "STD");
  assert.deepEqual(calls, ["entitlement"]);
});

test("C-1: inactive memberships do not count when picking the single active one", async () => {
  const removed = { ...prmMembership, status: "removed" };
  const { deps } = countingReads({ ...entitlementWithMembership, projectMemberships: [removed, activeMembership] });
  const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
  assert.equal(result.projectId, "SAMPLEORGAIAZ103");
});

test("C-1: more than one active membership and no selector is refused 400 project_selection_required", async () => {
  const { deps } = countingReads(twoProjects);
  const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, true);
  assert.equal(result.reason, "project_selection_required");
  assert.equal(result.httpStatus, 400);
});

test("C-1: a selector picks that active membership", async () => {
  const { deps, calls } = countingReads(twoProjects);
  const result = await resolveRequest({ personId: "person-1", projectId: "SAMPLEORGAIAZ210" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
  assert.equal(result.projectId, "SAMPLEORGAIAZ210");
  assert.equal(result.classification, "PRM");
  assert.equal(result.backendId, "foundry-other");
  assert.deepEqual(calls, ["entitlement"]);
});

test("C-1: a selector naming a project without an active membership is refused 403 project_mismatch", async () => {
  for (const projectId of ["NOT-A-MEMBER", "SAMPLEORGAIAZ210"]) {
    const removed = { ...prmMembership, status: "removed" };
    const { deps } = countingReads({ ...entitlementWithMembership, projectMemberships: [activeMembership, removed] });
    const result = await resolveRequest({ personId: "person-1", projectId }, deps, tokenLimitsOnlyContext());
    assert.equal(result.refused, true, projectId);
    assert.equal(result.reason, "project_mismatch");
    assert.equal(result.httpStatus, 403);
    assert.equal(result.projectId, undefined, "an unresolved selector is never echoed");
  }
});

test("C-1: two active memberships for the selected project are a malformed record, never a silent pick", async () => {
  const sameProjectPrm = { ...prmMembership, projectId: "SAMPLEORGAIAZ103" };
  const { deps } = countingReads({ ...entitlementWithMembership, projectMemberships: [activeMembership, sameProjectPrm] });
  for (const input of [{ personId: "person-1", projectId: "SAMPLEORGAIAZ103" }, { personId: "person-1" }]) {
    const result = await resolveRequest(input, deps, tokenLimitsOnlyContext());
    assert.equal(result.refused, true, JSON.stringify(input));
    // Not project_selection_required: the person has one project, and setting
    // a project header could not help them.
    assert.equal(result.reason, "entitlement_record_invalid", JSON.stringify(input));
    assert.equal(result.httpStatus, 503);
    assert.equal(result.projectId, "SAMPLEORGAIAZ103");
  }
});

test("C-1: duplicate active memberships on the key path are a malformed record, never the first match", async () => {
  const sameProjectPrm = { ...prmMembership, projectId: "SAMPLEORGAIAZ103", classification: "STD" };
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads({ readEntitlement: async () => ({ ...entitlementWithMembership, projectMemberships: [activeMembership, sameProjectPrm] }) }),
    tokenLimitsOnlyContext(),
  );
  assert.equal(result.refused, true);
  assert.equal(result.reason, "entitlement_record_invalid");
});

test("C-1: project_selection_required counts distinct projects, even when one of them is duplicated", async () => {
  const sameProjectPrm = { ...prmMembership, projectId: "SAMPLEORGAIAZ103" };
  const { deps } = countingReads({
    ...entitlementWithMembership,
    projectMemberships: [activeMembership, sameProjectPrm, { ...prmMembership, projectId: "SAMPLEORGAIAZ999" }],
  });
  const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, true);
  assert.equal(result.reason, "project_selection_required");
});

test("C-1: the subscriptionId path is unchanged, and a selector that disagrees with the key is refused", async () => {
  const agreeing = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc", projectId: "SAMPLEORGAIAZ103" },
    fakeReads(),
    context(),
  );
  assert.equal(agreeing.refused, false);
  const disagreeing = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc", projectId: "SAMPLEORGAIAZ210" },
    fakeReads({ readEntitlement: async () => twoProjects }),
    context(),
  );
  assert.equal(disagreeing.refused, true);
  assert.equal(disagreeing.reason, "project_mismatch");
});

// ---- C-2 aggregate limits retained by the family contract ----

test("C-2: the selected membership's aggregate limits are returned exactly", async () => {
  const { deps } = countingReads(twoProjects);
  const std = await resolveRequest({ personId: "person-1", projectId: "SAMPLEORGAIAZ103" }, deps, tokenLimitsOnlyContext());
  assert.equal(std.refused, false);
  assert.deepEqual(std.familyPolicy.aggregateLimits, STD_TOKEN_LIMITS);
  const prm = await resolveRequest({ personId: "person-1", projectId: "SAMPLEORGAIAZ210" }, deps, tokenLimitsOnlyContext());
  assert.equal(prm.refused, false);
  assert.deepEqual(prm.familyPolicy.aggregateLimits, prmMembership.familyPolicy.aggregateLimits);
});

test("C-2: all-null limits are valid (the gateway applies none)", async () => {
  const none = { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null };
  const { deps } = countingReads({
    ...entitlementWithMembership,
    projectMemberships: [{ ...activeMembership, familyPolicy: { ...STD_FAMILY_POLICY, aggregateLimits: { person: none, group: none } } }],
  });
  const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
  assert.deepEqual(result.familyPolicy.aggregateLimits, { person: none, group: none });
});

test("C-2: each period that llm-token-limit accepts is valid", async () => {
  for (const period of ["Hourly", "Daily", "Weekly", "Monthly", "Yearly"]) {
    const limits = { ...STD_TOKEN_LIMITS, group: { tokensPerMinute: 5, tokenQuota: 10, tokenQuotaPeriod: period } };
    const { deps } = countingReads({ ...entitlementWithMembership, projectMemberships: [{ ...activeMembership, familyPolicy: { ...STD_FAMILY_POLICY, aggregateLimits: limits } }] });
    const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
    assert.equal(result.refused, false, period);
  }
});

const person = STD_TOKEN_LIMITS.person;
const invalidLimits: Array<[string, unknown]> = [
  ["aggregateLimits missing", undefined],
  ["aggregateLimits null", null],
  ["group missing", { person }],
  ["person not an object", { person: 5, group: person }],
  ["tokensPerMinute zero", { person: { ...person, tokensPerMinute: 0 }, group: person }],
  ["tokensPerMinute negative", { person: { ...person, tokensPerMinute: -1 }, group: person }],
  ["tokensPerMinute fractional", { person: { ...person, tokensPerMinute: 1.5 }, group: person }],
  ["tokensPerMinute a string", { person: { ...person, tokensPerMinute: "1000" }, group: person }],
  ["tokensPerMinute missing", { person: { tokenQuota: 5, tokenQuotaPeriod: "Daily" }, group: person }],
  // APIM types tokens-per-minute as a 32-bit integer (WP-GW U-35).
  ["tokensPerMinute above 2147483647", { person: { ...person, tokensPerMinute: 2147483648 }, group: person }],
  ["tokenQuota unsafe", { person: { ...person, tokenQuota: 2 ** 53 }, group: person }],
  ["quota without period", { person: { ...person, tokenQuotaPeriod: null }, group: person }],
  ["period without quota", { person: { ...person, tokenQuota: null }, group: person }],
  ["unknown period", { person: { ...person, tokenQuotaPeriod: "daily" }, group: person }],
  ["period Minutely", { person: { ...person, tokenQuotaPeriod: "Minutely" }, group: person }],
];

for (const [problem, aggregateLimits] of invalidLimits) {
  test(`C-2: 503 entitlement_record_invalid when ${problem}`, async () => {
    const { deps } = countingReads({
      ...entitlementWithMembership,
      projectMemberships: [{ ...activeMembership, familyPolicy: { ...STD_FAMILY_POLICY, aggregateLimits } }],
    });
    const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
    assert.equal(result.refused, true);
    assert.equal(result.reason, "entitlement_record_invalid");
    assert.equal(result.httpStatus, 503);
    assert.equal(result.detail, "invalid_family_policy");
  });
}

test("C-2: tokensPerMinute of exactly 2147483647 is valid", async () => {
  const limits = { ...STD_TOKEN_LIMITS, person: { ...person, tokensPerMinute: 2147483647 } };
  const { deps } = countingReads({ ...entitlementWithMembership, projectMemberships: [{ ...activeMembership, familyPolicy: { ...STD_FAMILY_POLICY, aggregateLimits: limits } }] });
  const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
});

// Every field the gateway routes or filters on is validated with the patterns
// WP-ONB writes and WP-GW checks, so a 200 always passes the gateway.
const invalidFields: Array<[string, Record<string, unknown>, string]> = [
  ["projectId with a space", { projectId: "SAMPLEORG AIAZ103" }, "invalid_project_id"],
  ["classification empty", { classification: "" }, "invalid_classification"],
  ["backendId missing", { backendId: undefined }, "invalid_backend_id"],
  ["backendId a number", { backendId: 42 }, "invalid_backend_id"],
  ["backendId starting with a dash", { backendId: "-foundry" }, "invalid_backend_id"],
  ["family models missing", { familyPolicy: { ...STD_FAMILY_POLICY, families: { haiku: { ...STD_FAMILY_POLICY.families.haiku, models: undefined } } } }, "invalid_family_policy"],
  ["family models empty", { familyPolicy: { ...STD_FAMILY_POLICY, families: { haiku: { ...STD_FAMILY_POLICY.families.haiku, models: [] } } } }, "invalid_family_policy"],
  ["family models a wildcard string", { familyPolicy: { ...STD_FAMILY_POLICY, families: { haiku: { ...STD_FAMILY_POLICY.families.haiku, models: "*" } } } }, "invalid_family_policy"],
  ["family models with a non-string entry", { familyPolicy: { ...STD_FAMILY_POLICY, families: { haiku: { ...STD_FAMILY_POLICY.families.haiku, models: ["claude-haiku-4-5", null] } } } }, "invalid_family_policy"],
  ["family models with a wildcard entry", { familyPolicy: { ...STD_FAMILY_POLICY, families: { haiku: { ...STD_FAMILY_POLICY.families.haiku, models: ["*"] } } } }, "invalid_family_policy"],
  ["aggregateMode unknown", { aggregateMode: "Strict" }, "invalid_aggregate_mode"],
];

for (const [problem, change, detail] of invalidFields) {
  test(`503 entitlement_record_invalid (${detail}) when ${problem}`, async () => {
    const membership = { ...activeMembership, ...change };
    const { deps } = countingReads({ ...entitlementWithMembership, projectMemberships: [membership] });
    // A malformed projectId can only be reached without a selector.
    const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
    assert.equal(result.refused, true);
    assert.equal(result.reason, "entitlement_record_invalid");
    assert.equal(result.detail, detail);
  });
}

test("the returned family's allow-list is a copy, not the record's own array", async () => {
  const membership = { ...activeMembership, familyPolicy: structuredClone(STD_FAMILY_POLICY) };
  const { deps } = countingReads({ ...entitlementWithMembership, projectMemberships: [membership] });
  const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
  assert.deepEqual(result.familyPolicy.families.haiku?.models, ["claude-haiku-4-5"]);
  assert.notEqual(result.familyPolicy.families.haiku?.models, membership.familyPolicy.families.haiku.models);
});

test("C-2: invalid limits on another project's membership do not deny this one", async () => {
  const brokenOther = { ...prmMembership, familyPolicy: { ...STD_FAMILY_POLICY, aggregateLimits: { person: { tokensPerMinute: 0 } } } };
  const { deps } = countingReads({ ...entitlementWithMembership, projectMemberships: [activeMembership, brokenOther] });
  const result = await resolveRequest({ personId: "person-1", projectId: "SAMPLEORGAIAZ103" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
});

// ---- C-3 budget enforcement mode ----

test("C-3: token-limits-only reads no budget document, even for a strict scope", async () => {
  const strict = { ...activeMembership, aggregateMode: "strict" as const };
  const { deps, calls } = countingReads({ ...entitlementWithMembership, projectMemberships: [strict] });
  const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
  assert.deepEqual(calls, ["entitlement"]);
  assert.equal(result.budgetEnforcement, "token-limits-only");
  // WP-TEL's vocabulary: null when no budget was evaluated (ADR-0010).
  assert.equal(result.budgetState, null);
  assert.equal(result.personCeilingTokensPerMinute, null);
  assert.equal(result.aggregateState, null);
  // No CCU aggregate ceiling is applied while budgets are not enforced, even
  // though the membership's own mode is strict.
  assert.equal(result.aggregateStrict, false);
  assert.equal(result.degraded, false);
});

test("C-3: token-limits-only also skips budget reads on the subscriptionId path", async () => {
  const calls: string[] = [];
  const deps = fakeReads({
    readBudgetState: async () => {
      calls.push("budgetState");
      return null;
    },
  });
  const result = await resolveRequest({ personId: "person-1", subscriptionId: "sub-abc" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
  assert.deepEqual(calls, []);
});

test("C-3: budget-state mode still reads and enforces budget state", async () => {
  const { deps, calls } = countingReads({ ...entitlementWithMembership, projectMemberships: [membershipWithoutKey] });
  const result = await resolveRequest({ personId: "person-1" }, deps, context());
  assert.equal(result.refused, true);
  assert.equal(result.reason, "budget_state_missing");
  // C-7: notify scopes read their group state too, to flag exhaustion.
  assert.deepEqual(calls, ["entitlement", "budgetState", "aggregateBudgetState"]);
});

// ---- C-4 entitlement documents ----

test("C-4: a missing document and an empty membership list are both no_entitlement", async () => {
  for (const record of [null, { ...entitlementWithMembership, projectMemberships: [] }]) {
    for (const input of [{ personId: "person-1" }, { personId: "person-1", projectId: "SAMPLEORGAIAZ103" }]) {
      const { deps } = countingReads(record);
      const result = await resolveRequest(input, deps, tokenLimitsOnlyContext());
      assert.equal(result.refused, true);
      assert.equal(result.reason, "no_entitlement", JSON.stringify({ record: record && "empty", input }));
      assert.equal(result.httpStatus, 403);
    }
  }
  const keyed = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads({ readEntitlement: async () => ({ ...entitlementWithMembership, projectMemberships: [] }) }),
    context(),
  );
  assert.equal(keyed.refused, true);
  assert.equal(keyed.reason, "no_entitlement");
});

test("C-4: memberships that exist but none active, with no selector, is no_entitlement", async () => {
  const removed = { ...activeMembership, status: "removed" };
  const { deps } = countingReads({ ...entitlementWithMembership, projectMemberships: [removed] });
  const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, true);
  assert.equal(result.reason, "no_entitlement");
});

test("C-4: a membership without subscriptionId is valid", async () => {
  const { deps } = countingReads({ ...entitlementWithMembership, projectMemberships: [membershipWithoutKey] });
  const result = await resolveRequest({ personId: "person-1", projectId: "SAMPLEORGAIAZ103" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
});

test("the freshness contract still applies on the selector path", async () => {
  const { deps } = countingReads({ ...entitlementWithMembership, lastVerifiedAt: "2026-10-09T06:15:00.001Z" });
  const result = await resolveRequest({ personId: "person-1" }, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, true);
  assert.equal(result.reason, "entitlement_record_invalid");
});
