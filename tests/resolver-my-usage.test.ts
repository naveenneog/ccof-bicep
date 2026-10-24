// The developer's own usage (src/resolver/my-usage.ts, http-handler.ts handleMyUsageRequest):
// only the caller's documents, exact amounts, the same APIM-only gate as /api/resolve.

import { test } from "node:test";
import assert from "node:assert/strict";
import { handleMyUsageRequest } from "../src/resolver/http-handler.ts";
import type { ResolverRuntime } from "../src/resolver/http-handler.ts";
import { readMyUsage, shapeBudget } from "../src/resolver/my-usage.ts";
import { activeMembership, entitlementWithMembership, fakeReads, POLICY, RESOLVE_NOW } from "./helpers/resolver-fixtures.ts";

const PERSON = "00000000-0000-4000-8000-0000000000a1";
const authenticated = { platformAuthEnabled: true, authenticatedPrincipal: true };
const budgetDoc = (over: Record<string, unknown> = {}) => ({
  id: `${PERSON}:PILOT1`, personId: PERSON, projectId: "PILOT1", classification: "STD",
  spentCcu: "4210.5", budgetCcu: "10000", exhausted: false, period: "2026-10", rateCardVersion: "2026-10-11",
  contractScheduleVersion: "1", computedAt: "2026-10-09T06:10:00Z", validUntil: "2026-10-09T06:17:00Z",
  completeness: "complete", realtimeCeilingTokensPerMinute: 1000, ...over,
});

function runtime(reads = fakeReads(), logs: string[] = []): ResolverRuntime {
  return {
    readiness: { ready: true, budgetEnforcement: { mode: "budget-state", staleness: POLICY }, requestDeadlineMs: 5000, reads },
    now: () => RESOLVE_NOW, log: (line) => logs.push(line),
  };
}

test("spend, budget and remaining come back exactly, in CCU and USD, with freshness", () => {
  const p = shapeBudget("PILOT1", "STD", budgetDoc(), RESOLVE_NOW);
  assert.deepEqual({ ...p }, {
    projectId: "PILOT1", classification: "STD", state: "available",
    spentCcu: "4210.5", budgetCcu: "10000", remainingCcu: "5789.5", spentUsd: "42.10", budgetUsd: "100.00", remainingUsd: "57.89",
    percentUsed: "42.1", exhausted: false, period: "2026-10", computedAt: "2026-10-09T06:10:00Z", stale: false, completeness: "complete",
    softLimitPercent: null, softLimitReached: null,
  });
  const over = shapeBudget("PILOT1", "STD", budgetDoc({ spentCcu: "12000", exhausted: true, validUntil: "2026-10-09T06:00:00Z" }), RESOLVE_NOW);
  assert.equal(over.remainingCcu, "0");
  assert.equal(over.exhausted, true);
  assert.equal(over.stale, true, "validUntil passed");
  assert.equal(shapeBudget("PILOT1", "STD", null, RESOLVE_NOW).state, "no_budget_state");
  assert.equal(shapeBudget("PILOT1", "STD", budgetDoc({ spentCcu: 4210.5 }), RESOLVE_NOW).state, "invalid", "a JSON number is not accepted");
});

test("the reconciler's soft-limit warning is passed through; a malformed one is dropped, not trusted", () => {
  const warned = shapeBudget("PILOT1", "STD", budgetDoc({ spentCcu: "8500", softLimitPercent: 80, softLimitReached: true }), RESOLVE_NOW);
  assert.deepEqual([warned.state, warned.softLimitPercent, warned.softLimitReached], ["available", 80, true]);
  for (const bad of [{ softLimitPercent: "80", softLimitReached: true }, { softLimitPercent: 80, softLimitReached: "yes" },
    { softLimitPercent: 0, softLimitReached: true }, { softLimitPercent: 100, softLimitReached: true }, { softLimitReached: true }]) {
    const p = shapeBudget("PILOT1", "STD", budgetDoc(bad), RESOLVE_NOW);
    assert.deepEqual([p.state, p.softLimitPercent, p.softLimitReached], ["available", null, null], JSON.stringify(bad));
  }
});

test("only the caller's active memberships are read, with the caller's own personId", async () => {
  const asked: string[] = [];
  const retired = { ...activeMembership, projectId: "OLD1", status: "removed" };
  const reads = fakeReads({
    readEntitlement: async (id: string) => { asked.push(`entitlement:${id}`); return { ...entitlementWithMembership, personId: id, projectMemberships: [activeMembership, retired] }; },
    readBudgetState: async (id: string, project: string) => { asked.push(`budget:${id}:${project}`); return budgetDoc({ projectId: project }); },
  } as never);
  const usage = await readMyUsage(PERSON, reads, RESOLVE_NOW);
  assert.deepEqual(asked, [`entitlement:${PERSON}`, `budget:${PERSON}:${activeMembership.projectId}`]);
  assert.deepEqual(usage.projects.map((p) => p.projectId), [activeMembership.projectId]);
  assert.equal(usage.schema, "ccof.usage.me.v1");
});

test("the route is behind the APIM-only gate and accepts exactly {personId: GUID}", async () => {
  const unauth = await handleMyUsageRequest({ platformAuthEnabled: true, authenticatedPrincipal: false, body: { personId: PERSON } }, runtime());
  assert.equal(unauth.status, 401);
  const off = await handleMyUsageRequest({ platformAuthEnabled: false, authenticatedPrincipal: true, body: { personId: PERSON } }, runtime());
  assert.equal(off.status, 503);
  for (const body of [undefined, {}, { personId: "not-a-guid" }, { personId: PERSON, projectId: "X" }, { personId: PERSON.toUpperCase() }]) {
    assert.equal((await handleMyUsageRequest({ ...authenticated, body }, runtime())).status, 400, JSON.stringify(body));
  }
  const ok = await handleMyUsageRequest({ ...authenticated, body: { personId: PERSON } }, runtime(fakeReads({ readBudgetState: async () => budgetDoc() } as never)));
  assert.equal(ok.status, 200);
  assert.equal((ok.jsonBody.projects as { spentUsd: string }[])[0].spentUsd, "42.10");
});

test("a failed read answers 503 without provider detail", async () => {
  const logs: string[] = [];
  const reads = fakeReads({ readEntitlement: async () => { throw Object.assign(new Error("https://secret.example/x"), { code: 503 }); } } as never);
  const r = await handleMyUsageRequest({ ...authenticated, body: { personId: PERSON } }, runtime(reads, logs));
  assert.equal(r.status, 503);
  assert.equal(r.jsonBody.error, "temporarily_unavailable");
  assert.ok(!logs.join("").includes("secret.example"));
});
