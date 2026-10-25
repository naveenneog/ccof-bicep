// The resolver's freshness contract (ADR-0008), through resolveRequest:
// - entitlement records persist (no lease); only per-record problems answer 503;
// - stale budget state is served, degraded, within the configured grace window
//   and hard limit, and refused beyond the hard limit.
// The clock and the policy are injected; nothing here reads the machine's time.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveRequest } from "../src/resolver/decide.ts";
import {
  activeBudgetState,
  aggregateRecord,
  context,
  entitlementWithMembership,
  fakeReads,
  POLICY,
  secondsAfterValidUntil,
  strictEntitlement,
} from "./helpers/resolver-fixtures.ts";

const input = { personId: "person-1", subscriptionId: "sub-abc" };

async function resolveWithEntitlement(record: unknown, now = context().now) {
  return resolveRequest(input, fakeReads({ readEntitlement: async () => record }), context({ now }));
}

async function resolveWithBudget(budget: unknown, now: Date, budgetStaleness = POLICY) {
  return resolveRequest(input, fakeReads({ readBudgetState: async () => budget }), context({ now, budgetStaleness }));
}

// ---- Entitlement: records persist; 503 only for per-record problems ----

test("an entitlement record without expiresAt is served however long ago it was verified", async () => {
  // A stopped sync must not deny anyone (reference ADR-0051): no lease.
  const yearsLater = new Date("2031-01-01T00:00:00Z");
  const result = await resolveRequest(
    input,
    fakeReads({ readBudgetState: async () => ({ ...activeBudgetState, validUntil: "2031-01-01T00:05:00Z" }) }),
    context({ now: yearsLater }),
  );
  assert.equal(result.refused, false);
});

test("a legacy expiresAt still in the future is served", async () => {
  const result = await resolveWithEntitlement({ ...entitlementWithMembership, expiresAt: "2026-10-09T07:00:00Z" });
  assert.equal(result.refused, false);
});

test("a legacy expiresAt that has passed is treated as no record: 403 entitlement_legacy_expired", async () => {
  const result = await resolveWithEntitlement({ ...entitlementWithMembership, expiresAt: "2026-10-09T06:14:59Z" });
  assert.equal(result.refused, true);
  assert.equal(result.reason, "entitlement_legacy_expired");
  assert.equal(result.httpStatus, 403);
});

const invalidEntitlements: Array<[string, Record<string, unknown>]> = [
  ["generation missing", { generation: undefined }],
  ["generation negative", { generation: -1 }],
  ["generation fractional", { generation: 1.5 }],
  ["generation a string", { generation: "42" }],
  ["generation not a safe integer", { generation: 2 ** 53 }],
  ["lastVerifiedAt missing", { lastVerifiedAt: undefined }],
  ["lastVerifiedAt unparseable", { lastVerifiedAt: "yesterday" }],
  ["lastVerifiedAt without a zone", { lastVerifiedAt: "2026-10-09T06:00:00" }],
  ["lastVerifiedAt a date only", { lastVerifiedAt: "2026-10-09" }],
  ["lastVerifiedAt a number", { lastVerifiedAt: 1791525600000 }],
  ["lastVerifiedAt in the future", { lastVerifiedAt: "2026-10-09T06:15:00.001Z" }],
  ["legacy expiresAt unparseable", { expiresAt: "soon" }],
  ["projectMemberships not an array", { projectMemberships: { projectId: "SAMPLEORGAIAZ103" } }],
];

for (const [problem, change] of invalidEntitlements) {
  test(`503 entitlement_record_invalid when ${problem}`, async () => {
    const result = await resolveWithEntitlement({ ...entitlementWithMembership, ...change });
    assert.equal(result.refused, true);
    assert.equal(result.reason, "entitlement_record_invalid");
    assert.equal(result.httpStatus, 503);
  });
}

test("lastVerifiedAt exactly at the resolver's clock, or with a UTC offset, is valid", async () => {
  for (const lastVerifiedAt of ["2026-10-09T06:15:00Z", "2026-10-09T08:15:00+02:00", "2026-10-09T06:00:00.123Z"]) {
    const result = await resolveWithEntitlement({ ...entitlementWithMembership, lastVerifiedAt });
    assert.equal(result.refused, false, lastVerifiedAt);
  }
});

test("generation zero is valid", async () => {
  const result = await resolveWithEntitlement({ ...entitlementWithMembership, generation: 0 });
  assert.equal(result.refused, false);
});

test("503 entitlement_record_invalid when the matched membership has an unknown aggregateMode", async () => {
  // Anything other than "strict" was silently treated as notify, skipping the
  // aggregate check; an unknown mode is now a per-record problem.
  const result = await resolveWithEntitlement({
    ...entitlementWithMembership,
    projectMemberships: [{ ...entitlementWithMembership.projectMemberships[0], aggregateMode: "Strict" }],
  });
  assert.equal(result.refused, true);
  assert.equal(result.reason, "entitlement_record_invalid");
  assert.equal(result.httpStatus, 503);
});

test("a malformed membership for another project does not deny this project", async () => {
  const other = { ...entitlementWithMembership.projectMemberships[0], projectId: "OTHER", aggregateMode: "bogus" };
  const result = await resolveWithEntitlement({
    ...entitlementWithMembership,
    projectMemberships: [other, entitlementWithMembership.projectMemberships[0]],
  });
  assert.equal(result.refused, false);
});

// ---- Budget state: configured grace window and hard limit (G=600 s, H=3,600 s) ----

test("budget state at or before validUntil is fresh and not degraded", async () => {
  const result = await resolveWithBudget(activeBudgetState, secondsAfterValidUntil(0));
  assert.equal(result.refused, false);
  assert.equal(result.degraded, false);
  assert.deepEqual(result.degradedReasons, []);
  assert.equal(result.budgetState, "fresh");
});

test("within the grace window: served with the last-known ceiling, degraded within_grace", async () => {
  for (const seconds of [0.001, 600]) {
    const result = await resolveWithBudget(activeBudgetState, secondsAfterValidUntil(seconds));
    assert.equal(result.refused, false, `${seconds}s`);
    assert.equal(result.personCeilingTokensPerMinute, 4200);
    assert.equal(result.degraded, true);
    assert.deepEqual(result.degradedReasons, ["budget_state_stale_within_grace"]);
    assert.equal(result.budgetState, "degraded");
  }
});

test("past the grace window but within the hard limit: served, degraded beyond_grace", async () => {
  for (const seconds of [600.001, 3600]) {
    const result = await resolveWithBudget(activeBudgetState, secondsAfterValidUntil(seconds));
    assert.equal(result.refused, false, `${seconds}s`);
    assert.equal(result.personCeilingTokensPerMinute, 4200);
    assert.deepEqual(result.degradedReasons, ["budget_state_stale_beyond_grace"]);
  }
});

test("past the hard limit: 503 budget_state_stale", async () => {
  const result = await resolveWithBudget(activeBudgetState, secondsAfterValidUntil(3600.001));
  assert.equal(result.refused, true);
  assert.equal(result.reason, "budget_state_stale");
  assert.equal(result.httpStatus, 503);
  assert.equal(result.budgetState, "stale");
});

test("grace and hard limit of zero refuse as soon as validUntil passes", async () => {
  const strictPolicy = { graceSeconds: 0, hardLimitSeconds: 0 };
  const atLimit = await resolveWithBudget(activeBudgetState, secondsAfterValidUntil(0), strictPolicy);
  assert.equal(atLimit.refused, false);
  const justAfter = await resolveWithBudget(activeBudgetState, secondsAfterValidUntil(0.001), strictPolicy);
  assert.equal(justAfter.refused, true);
  assert.equal(justAfter.reason, "budget_state_stale");
});

test("the policy comes from the context, not from the code: a longer hard limit still serves", async () => {
  const longPolicy = { graceSeconds: 7200, hardLimitSeconds: 86400 };
  const result = await resolveWithBudget(activeBudgetState, secondsAfterValidUntil(7201), longPolicy);
  assert.equal(result.refused, false);
  assert.deepEqual(result.degradedReasons, ["budget_state_stale_beyond_grace"]);
});

const invalidBudgets: Array<[string, Record<string, unknown>]> = [
  ["validUntil missing", { validUntil: undefined }],
  ["validUntil unparseable", { validUntil: "later" }],
  ["validUntil without a zone", { validUntil: "2026-10-09T06:17:00" }],
  ["the ceiling missing", { realtimeCeilingTokensPerMinute: undefined }],
  ["the ceiling negative", { realtimeCeilingTokensPerMinute: -1 }],
  ["the ceiling not a number", { realtimeCeilingTokensPerMinute: "4200" }],
];

for (const [problem, change] of invalidBudgets) {
  test(`503 budget_state_invalid when ${problem}`, async () => {
    const result = await resolveWithBudget({ ...activeBudgetState, ...change }, secondsAfterValidUntil(-60));
    assert.equal(result.refused, true);
    assert.equal(result.reason, "budget_state_invalid");
    assert.equal(result.httpStatus, 503);
    assert.equal(result.budgetState, "stale");
  });
}

test("a missing budget record is labelled missing for telemetry", async () => {
  const result = await resolveWithBudget(null, secondsAfterValidUntil(-60));
  assert.equal(result.refused, true);
  assert.equal(result.reason, "budget_state_missing");
  assert.equal(result.budgetState, "missing");
});

// ---- Strict aggregate scopes follow the same policy ----

async function resolveStrict(aggregate: unknown, now: Date) {
  return resolveRequest(
    input,
    fakeReads({
      readEntitlement: async () => strictEntitlement,
      readBudgetState: async () => ({ ...activeBudgetState, validUntil: "2026-10-09T09:00:00Z" }),
      readAggregateBudgetState: async () => aggregate,
    }),
    context({ now }),
  );
}

test("strict aggregate state within the grace window is served, degraded", async () => {
  const result = await resolveStrict(aggregateRecord, secondsAfterValidUntil(60));
  assert.equal(result.refused, false);
  assert.deepEqual(result.degradedReasons, ["aggregate_budget_state_stale_within_grace"]);
  assert.equal(result.budgetState, "degraded");
});

test("strict aggregate state past the grace window is served, degraded beyond_grace", async () => {
  const result = await resolveStrict(aggregateRecord, secondsAfterValidUntil(601));
  assert.equal(result.refused, false);
  assert.deepEqual(result.degradedReasons, ["aggregate_budget_state_stale_beyond_grace"]);
});

test("strict aggregate state past the hard limit: 503 aggregate_budget_state_stale", async () => {
  const result = await resolveStrict(aggregateRecord, secondsAfterValidUntil(3601));
  assert.equal(result.refused, true);
  assert.equal(result.reason, "aggregate_budget_state_stale");
  assert.equal(result.httpStatus, 503);
  assert.equal(result.budgetState, "stale");
});

test("strict aggregate state without a parseable validUntil: 503 aggregate_budget_state_invalid", async () => {
  const result = await resolveStrict({ ...aggregateRecord, validUntil: "n/a" }, secondsAfterValidUntil(-60));
  assert.equal(result.refused, true);
  assert.equal(result.reason, "aggregate_budget_state_invalid");
  assert.equal(result.httpStatus, 503);
});

test("both person and aggregate state degraded: both reasons are reported", async () => {
  const result = await resolveRequest(
    input,
    fakeReads({
      readEntitlement: async () => strictEntitlement,
      readAggregateBudgetState: async () => aggregateRecord,
    }),
    context({ now: secondsAfterValidUntil(700) }),
  );
  assert.equal(result.refused, false);
  assert.deepEqual(result.degradedReasons, [
    "budget_state_stale_beyond_grace",
    "aggregate_budget_state_stale_beyond_grace",
  ]);
});

// C-7: notify scopes read aggregate state only to flag an exhausted group;
// nothing about that state can refuse them.
test("notify scopes are served whatever their aggregate state: stale, invalid, missing or unreadable", async () => {
  const states: Array<[string, () => Promise<unknown>]> = [
    ["past the hard limit", async () => ({ ...aggregateRecord, validUntil: "2026-10-09T01:00:00Z" })],
    ["invalid", async () => ({ ...aggregateRecord, exhausted: "yes" })],
    ["missing", async () => null],
    ["unreadable", async () => {
      throw new Error("cosmos unavailable");
    }],
  ];
  for (const [label, readAggregateBudgetState] of states) {
    const result = await resolveRequest(input, fakeReads({ readAggregateBudgetState }), context({ now: secondsAfterValidUntil(-60) }));
    assert.equal(result.refused, false, label);
    assert.equal(result.degraded, false, label);
    assert.equal(result.aggregateState, null, label);
  }
});

// ---- ADR 0034: per-project failover route ----

test("a membership routeBackendId in the pool pattern is passed to the decision", async () => {
  const membership = { ...entitlementWithMembership.projectMemberships[0], routeBackendId: "ccof-pool-sampleorgaiaz103-1a2b3c4d-r2" };
  const result = await resolveWithEntitlement({ ...entitlementWithMembership, projectMemberships: [membership] });
  if (result.refused) assert.fail(result.reason);
  assert.equal(result.backendId, "foundry-sample-hub");
  assert.equal(result.routeBackendId, "ccof-pool-sampleorgaiaz103-1a2b3c4d-r2");
});

test("without a routeBackendId the decision has none (direct routing)", async () => {
  const result = await resolveWithEntitlement(entitlementWithMembership);
  if (result.refused) assert.fail(result.reason);
  assert.equal(Object.hasOwn(result, "routeBackendId"), false);
});

for (const bad of ["foundry-other", "ccof-pool-X-r1", "ccof-pool-a-r1\n", 7]) {
  test(`a membership routeBackendId ${JSON.stringify(bad)} outside the pool pattern is dropped, never forwarded`, async () => {
    const membership = { ...entitlementWithMembership.projectMemberships[0], routeBackendId: bad };
    const result = await resolveWithEntitlement({ ...entitlementWithMembership, projectMemberships: [membership] });
    if (result.refused) assert.fail(result.reason);
    assert.equal(Object.hasOwn(result, "routeBackendId"), false);
  });
}
