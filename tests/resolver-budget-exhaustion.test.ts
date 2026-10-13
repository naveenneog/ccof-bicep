// C-7 (docs/PILOT.md): CCU budget enforcement, resolver side, in budget-state
// mode. The reconciler (WP-REC) writes `exhausted`; the resolver checks the
// state's validity first (ADR-0008) and then the flag:
// - person exhausted → 403 budget_exhausted;
// - group exhausted, strict → 403 aggregate_budget_exhausted;
// - group exhausted, notify → served, degraded, one degraded event.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveRequest } from "../src/resolver/decide.ts";
import { externalCategory, handleResolveRequest } from "../src/resolver/http-handler.ts";
import type { ResolverRuntime } from "../src/resolver/http-handler.ts";
import type { ResolveDependencies } from "../src/resolver/decide.ts";
import {
  activeBudgetState,
  aggregateRecord,
  context,
  fakeReads,
  POLICY,
  RESOLVE_NOW,
  secondsAfterValidUntil,
  strictEntitlement,
} from "./helpers/resolver-fixtures.ts";

const input = { personId: "person-1", subscriptionId: "sub-abc" };
const exhaustedPerson = { ...activeBudgetState, exhausted: true, realtimeCeilingTokensPerMinute: 0 };
const exhaustedGroup = { ...aggregateRecord, exhausted: true };

function resolveWith(reads: Parameters<typeof fakeReads>[0], now: Date = RESOLVE_NOW) {
  return resolveRequest(input, fakeReads(reads), context({ now }));
}

// ---- person budget ----

test("an exhausted person budget is 403 budget_exhausted, naming the project and classification", async () => {
  const result = await resolveWith({ readBudgetState: async () => exhaustedPerson });
  assert.equal(result.refused, true);
  assert.equal(result.reason, "budget_exhausted");
  assert.equal(result.httpStatus, 403);
  assert.equal(result.projectId, "SAMPLEORGAIAZ103");
  assert.equal(result.classification, "STD");
  assert.equal(result.budgetState, "fresh");
  assert.equal(result.detail, undefined);
});

test("the decision rests on exhausted alone: other document fields neither change it nor reach the log", async () => {
  const extra = { spentCcu: "25000.00", budgetCcu: "25000.00", completeness: "partial", exhaustedReason: "unpriced_usage" };
  const refusedResult = await resolveWith({ readBudgetState: async () => ({ ...exhaustedPerson, ...extra }) });
  assert.equal(refusedResult.refused, true);
  assert.equal(refusedResult.reason, "budget_exhausted");
  assert.equal(refusedResult.detail, undefined);
  const served = await resolveWith({ readBudgetState: async () => ({ ...activeBudgetState, ...extra }) });
  assert.equal(served.refused, false);
});

test("exhausted state inside the grace window still refuses, labelled degraded", async () => {
  const result = await resolveWith({ readBudgetState: async () => exhaustedPerson }, secondsAfterValidUntil(60));
  assert.equal(result.refused, true);
  assert.equal(result.reason, "budget_exhausted");
  assert.equal(result.budgetState, "degraded");
});

test("validity comes first: exhausted state past the hard limit is 503 budget_state_stale", async () => {
  const result = await resolveWith({ readBudgetState: async () => exhaustedPerson }, secondsAfterValidUntil(3601));
  assert.equal(result.refused, true);
  assert.equal(result.reason, "budget_state_stale");
  assert.equal(result.httpStatus, 503);
});

test("a person state whose exhausted flag is missing or not a boolean is 503 budget_state_invalid", async () => {
  const { exhausted: _omit, ...withoutFlag } = activeBudgetState;
  for (const record of [withoutFlag, { ...activeBudgetState, exhausted: "false" }, { ...activeBudgetState, exhausted: 0 }, { ...activeBudgetState, exhausted: null }]) {
    const result = await resolveWith({ readBudgetState: async () => record });
    assert.equal(result.refused, true, JSON.stringify((record as Record<string, unknown>).exhausted));
    assert.equal(result.reason, "budget_state_invalid");
    assert.equal(result.httpStatus, 503);
  }
});

test("the person ceiling is a whole number from 0 to 2147483647", async () => {
  for (const ceiling of [4200.5, -1, 2147483648, Number.NaN, "4200"]) {
    const result = await resolveWith({ readBudgetState: async () => ({ ...activeBudgetState, realtimeCeilingTokensPerMinute: ceiling }) });
    assert.equal(result.refused, true, String(ceiling));
    assert.equal(result.reason, "budget_state_invalid", String(ceiling));
  }
  for (const ceiling of [0, 2147483647]) {
    const result = await resolveWith({ readBudgetState: async () => ({ ...activeBudgetState, realtimeCeilingTokensPerMinute: ceiling }) });
    assert.equal(result.refused, false, String(ceiling));
  }
});

// ---- group budget, strict ----

function resolveStrict(aggregate: unknown, now: Date = RESOLVE_NOW, budget: unknown = activeBudgetState) {
  return resolveRequest(
    input,
    fakeReads({
      readEntitlement: async () => strictEntitlement,
      readBudgetState: async () => budget,
      readAggregateBudgetState: async () => aggregate,
    }),
    context({ now }),
  );
}

test("strict: an exhausted group is 403 aggregate_budget_exhausted for its member", async () => {
  const result = await resolveStrict(exhaustedGroup);
  assert.equal(result.refused, true);
  assert.equal(result.reason, "aggregate_budget_exhausted");
  assert.equal(result.httpStatus, 403);
  assert.equal(result.projectId, "SAMPLEORGAIAZ103");
  assert.equal(result.classification, "STD");
  assert.equal(result.budgetState, "fresh");
});

test("strict: a group state whose exhausted flag is missing or not a boolean is 503 aggregate_budget_state_invalid", async () => {
  const { exhausted: _omit, ...withoutFlag } = aggregateRecord;
  for (const record of [withoutFlag, { ...aggregateRecord, exhausted: "true" }]) {
    const result = await resolveStrict(record);
    assert.equal(result.refused, true);
    assert.equal(result.reason, "aggregate_budget_state_invalid");
    assert.equal(result.httpStatus, 503);
  }
});

test("strict: the person's own budget is checked before the group's", async () => {
  const result = await resolveStrict(exhaustedGroup, RESOLVE_NOW, exhaustedPerson);
  assert.equal(result.refused, true);
  assert.equal(result.reason, "budget_exhausted");
});

test("strict: a group within budget is served", async () => {
  const result = await resolveStrict(aggregateRecord);
  assert.equal(result.refused, false);
  assert.equal(result.degraded, false);
});

// ---- group budget, notify ----

test("notify: an exhausted group is served, flagged degraded, and the freshness label stays fresh", async () => {
  const result = await resolveWith({ readAggregateBudgetState: async () => exhaustedGroup });
  assert.equal(result.refused, false);
  assert.equal(result.degraded, true);
  assert.deepEqual(result.degradedReasons, ["aggregate_budget_exhausted_notify"]);
  assert.equal(result.budgetState, "fresh");
  assert.equal(result.aggregateStrict, false);
});

test("notify: the group is read by its scope id, project and classification", async () => {
  const scopes: string[] = [];
  await resolveWith({
    readAggregateBudgetState: async (scopeId: string) => {
      scopes.push(scopeId);
      return aggregateRecord;
    },
  });
  assert.deepEqual(scopes, ["SAMPLEORGAIAZ103:STD"]);
});

test("notify: exhaustion in state inside the hard limit is flagged with the staleness reasons of the person", async () => {
  const result = await resolveWith(
    { readAggregateBudgetState: async () => exhaustedGroup },
    secondsAfterValidUntil(60),
  );
  assert.equal(result.refused, false);
  assert.deepEqual(result.degradedReasons, ["budget_state_stale_within_grace", "aggregate_budget_exhausted_notify"]);
  assert.equal(result.budgetState, "degraded");
});

test("notify: a group read that has not finished does not hold the request", { timeout: 5000 }, async () => {
  // Never settles: a notify request must not wait for it (a strict one must).
  const result = await resolveWith({ readAggregateBudgetState: () => new Promise(() => {}) });
  assert.equal(result.refused, false);
  assert.equal(result.degraded, false);
});

test("notify: a group read that failed is ignored", async () => {
  const result = await resolveWith({
    readAggregateBudgetState: async () => {
      throw new Error("cosmos unavailable");
    },
  });
  assert.equal(result.refused, false);
});

test("notify: an exhausted flag in state past the hard limit is not trusted, and does not refuse", async () => {
  const stale = { ...exhaustedGroup, validUntil: "2026-10-09T01:00:00Z" };
  const result = await resolveWith({ readAggregateBudgetState: async () => stale });
  assert.equal(result.refused, false);
  assert.equal(result.degraded, false);
});

// ---- the HTTP layer ----

function runtime(reads: ResolveDependencies, logs: string[]): ResolverRuntime {
  return {
    readiness: { ready: true, budgetEnforcement: { mode: "budget-state", staleness: POLICY }, requestDeadlineMs: 5000, reads },
    now: () => RESOLVE_NOW,
    log: (line) => logs.push(line),
  };
}

const authenticated = { platformAuthEnabled: true, authenticatedPrincipal: true };

test("both budget refusals pass through as their own category: they follow a verified membership", () => {
  assert.equal(externalCategory("budget_exhausted"), "budget_exhausted");
  assert.equal(externalCategory("aggregate_budget_exhausted"), "aggregate_budget_exhausted");
});

test("a budget refusal answers 403 with the project, classification and budget state, and logs ids only", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: input },
    runtime(fakeReads({ readBudgetState: async () => exhaustedPerson }), logs),
  );
  assert.equal(response.status, 403);
  assert.deepEqual(response.jsonBody, {
    error: "budget_exhausted",
    resolverOutcome: "refused",
    projectId: "SAMPLEORGAIAZ103",
    classification: "STD",
    budgetState: "fresh",
  });
  assert.deepEqual(
    logs.map((line) => JSON.parse(line)),
    [
      {
        schema: "ccof.resolver.event.v1",
        event: "refused",
        reason: "budget_exhausted",
        httpStatus: 403,
        personId: "person-1",
        subscriptionId: "sub-abc",
        projectId: "SAMPLEORGAIAZ103",
      },
    ],
  );
});

test("a group budget refusal answers 403 aggregate_budget_exhausted with the same fields", async () => {
  const response = await handleResolveRequest(
    { ...authenticated, body: input },
    runtime(
      fakeReads({
        readEntitlement: async () => strictEntitlement,
        readAggregateBudgetState: async () => exhaustedGroup,
      }),
      [],
    ),
  );
  assert.equal(response.status, 403);
  assert.deepEqual(response.jsonBody, {
    error: "aggregate_budget_exhausted",
    resolverOutcome: "refused",
    projectId: "SAMPLEORGAIAZ103",
    classification: "STD",
    budgetState: "fresh",
  });
});

test("other 403 refusals still carry no project or classification", async () => {
  const response = await handleResolveRequest(
    { ...authenticated, body: input },
    runtime(fakeReads({ readSubscriptionIndex: async () => null }), []),
  );
  assert.equal(response.status, 403);
  assert.deepEqual(response.jsonBody, { error: "not_authorized", resolverOutcome: "refused" });
});

test("notify exhaustion answers 200 degraded and logs one degraded event", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: input },
    runtime(fakeReads({ readAggregateBudgetState: async () => exhaustedGroup }), logs),
  );
  assert.equal(response.status, 200);
  assert.equal(response.jsonBody.resolverOutcome, "degraded");
  assert.deepEqual(
    logs.map((line) => JSON.parse(line)),
    [
      {
        schema: "ccof.resolver.event.v1",
        event: "degraded",
        reasons: ["aggregate_budget_exhausted_notify"],
        personId: "person-1",
        subscriptionId: "sub-abc",
        projectId: "SAMPLEORGAIAZ103",
      },
    ],
  );
});
