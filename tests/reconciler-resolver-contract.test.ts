// AC14: the documents the reconciler writes are accepted by the resolver's
// own validation (src/resolver/decide.ts and freshness.ts at c3acbdf, the code
// live on sample-pilot-resolver-func) in budget-state mode, read by the keys the
// resolver uses. Plus the fields WP-RES agreed to validate next (C-7):
// `exhausted` a boolean, the ceiling an integer 0..2,147,483,647.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveRequest } from "../src/resolver/decide.ts";
import type { ResolveDependencies } from "../src/resolver/decide.ts";
import type { LedgerRow } from "../src/reconciler/ledger.ts";
import { budgetPeriodAt } from "../src/reconciler/period.ts";
import { classifyRow } from "../src/reconciler/price-rows.ts";
import { reconcile } from "../src/reconciler/reconcile.ts";
import { readRegistry } from "../src/reconciler/registry.ts";
import { PERSON_A, entitlementDoc, ledgerRow, packagedRateCard, packagedSchedule, pilotProject } from "./helpers/reconciler-fixtures.ts";

const card = packagedRateCard();
const schedule = packagedSchedule(card);
const computedAt = new Date("2026-10-11T13:00:00.000Z");
const validUntil = new Date("2026-10-11T13:10:00.000Z");
const staleness = { graceSeconds: 600, hardLimitSeconds: 3600 };

function reconciled(aggregateMode: "strict" | "notify", budgets: { person?: string; group?: string } = {}) {
  const entitlement = entitlementDoc(PERSON_A, [{ projectId: "CCOFPILOT01", classification: "STD" }]);
  const membership = (entitlement.projectMemberships as Array<Record<string, unknown>>)[0];
  membership.aggregateMode = aggregateMode;
  const project = pilotProject();
  const std = (project.classifications as Record<string, Record<string, unknown>>).STD;
  if (budgets.person !== undefined) std.personBudget = { amount: budgets.person, currency: "CCU", period: "monthly" };
  if (budgets.group !== undefined) std.aggregateBudget = { amount: budgets.group, currency: "CCU", period: "monthly" };
  const registry = readRegistry([project], [entitlement]);
  const period = budgetPeriodAt(computedAt);
  const rows = [ledgerRow({ inferenceGeo: "global" }), ledgerRow({ cacheRead: null })].map((r) => classifyRow(r as LedgerRow, period, card, schedule));
  const result = reconcile({ registry, rows, rateCard: card, contractScheduleVersion: schedule.version, period, computedAt, validUntil });
  return { entitlement, result };
}

// Cosmos as the resolver reads it: point reads by the keys it computes. No
// backend registry document: the gateway's configured backend applies (C-8).
function cosmosReads(entitlement: unknown, result: ReturnType<typeof reconcile>, asked: string[]): ResolveDependencies {
  const budget = new Map(result.persons.map((p) => [p.doc.id, p.doc]));
  const aggregate = new Map(result.groups.map((g) => [g.doc.id, g.doc]));
  return {
    readSubscriptionIndex: async () => null,
    readEntitlement: async (personId) => (personId === PERSON_A ? (entitlement as never) : null),
    readBudgetState: async (personId, projectId) => {
      asked.push(`budgetState:${personId}:${projectId}`);
      return (budget.get(`${personId}:${projectId}`) as never) ?? null;
    },
    readAggregateBudgetState: async (scopeId) => {
      asked.push(`aggregateBudgetState:${scopeId}`);
      return (aggregate.get(scopeId) as never) ?? null;
    },
    readBackend: async () => null,
  };
}

test("a strict member's documents resolve as fresh budget state, with the reconciler's ceiling", async () => {
  const { entitlement, result } = reconciled("strict");
  const asked: string[] = [];
  const decision = await resolveRequest({ personId: PERSON_A }, cosmosReads(entitlement, result, asked), {
    now: new Date("2026-10-11T13:01:00Z"),
    budgetEnforcement: { mode: "budget-state", staleness },
  });
  assert.equal(decision.refused, false, JSON.stringify(decision));
  if (decision.refused) return;
  assert.equal(decision.budgetState, "fresh");
  assert.equal(decision.aggregateStrict, true);
  assert.equal(decision.personCeilingTokensPerMinute, result.persons[0].doc.realtimeCeilingTokensPerMinute);
  assert.deepEqual(asked.sort(), [`aggregateBudgetState:CCOFPILOT01:STD`, `budgetState:${PERSON_A}:CCOFPILOT01`]);
});

test("a notify member's document resolves as fresh too", async () => {
  const { entitlement, result } = reconciled("notify");
  const decision = await resolveRequest({ personId: PERSON_A }, cosmosReads(entitlement, result, []), {
    now: new Date("2026-10-11T13:01:00Z"),
    budgetEnforcement: { mode: "budget-state", staleness },
  });
  assert.equal(decision.refused, false, JSON.stringify(decision));
});

test("the reconciler's validUntil drives the resolver's staleness exactly: degraded after it, refused past the hard limit", async () => {
  const { entitlement, result } = reconciled("strict");
  const at = async (iso: string) =>
    resolveRequest({ personId: PERSON_A }, cosmosReads(entitlement, result, []), { now: new Date(iso), budgetEnforcement: { mode: "budget-state", staleness } });
  const late = await at("2026-10-11T13:11:00Z");
  assert.equal(!late.refused && late.budgetState, "degraded");
  const dead = await at("2026-10-11T14:10:01Z");
  assert.equal(dead.refused && dead.reason, "budget_state_stale");
});

test("every document carries the fields WP-RES validates for C-7: a boolean exhausted, an integer ceiling in range", () => {
  const { result } = reconciled("strict");
  for (const { doc } of result.persons) {
    assert.equal(typeof doc.exhausted, "boolean");
    assert.ok(Number.isSafeInteger(doc.realtimeCeilingTokensPerMinute));
    assert.ok(doc.realtimeCeilingTokensPerMinute >= 0 && doc.realtimeCeilingTokensPerMinute <= 2_147_483_647);
    assert.match(doc.validUntil, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  }
  for (const { doc } of result.groups) {
    assert.equal(typeof doc.exhausted, "boolean");
    assert.match(doc.validUntil, /Z$/);
  }
});

// C-7, resolver side (WP-RES 3cf5d81): the reconciler's exhausted flags drive
// the refusals. The two rows above cost 0.3 CCU together.
async function decide(aggregateMode: "strict" | "notify", budgets: { person?: string; group?: string }) {
  const { entitlement, result } = reconciled(aggregateMode, budgets);
  return resolveRequest({ personId: PERSON_A }, cosmosReads(entitlement, result, []), {
    now: new Date("2026-10-11T13:01:00Z"),
    budgetEnforcement: { mode: "budget-state", staleness },
  });
}

test("a person whose spend reached the budget is refused with budget_exhausted (403); just below, served", async () => {
  const exhausted = await decide("strict", { person: "0.3" });
  assert.deepEqual(exhausted.refused && [exhausted.reason, exhausted.httpStatus], ["budget_exhausted", 403]);
  const below = await decide("strict", { person: "0.3000001" });
  assert.equal(below.refused, false, JSON.stringify(below));
});

test("a strict group whose spend reached its budget refuses every member with aggregate_budget_exhausted (403)", async () => {
  const decision = await decide("strict", { group: "0.3" });
  assert.deepEqual(decision.refused && [decision.reason, decision.httpStatus], ["aggregate_budget_exhausted", 403]);
});

test("a notify group whose spend reached its budget is served, flagged degraded", async () => {
  const decision = await decide("notify", { group: "0.3" });
  assert.equal(decision.refused, false, JSON.stringify(decision));
  if (!decision.refused) assert.ok(decision.degradedReasons.includes("aggregate_budget_exhausted_notify"), JSON.stringify(decision.degradedReasons));
});
