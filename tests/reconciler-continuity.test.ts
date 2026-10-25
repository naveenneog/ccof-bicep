// The ledger continuity gate (DR-05; docs/DR-ACTIVE-PASSIVE.md, failover runbook step 5). With
// RECONCILER_CONTINUITY_GATE=on a run refuses to write when the ledger shows a gap, or when a state it
// would write has less spend than the one already persisted for the same scope and period. Off, the
// run is exactly today's: one ledger query, no state reads.

import { test } from "node:test";
import assert from "node:assert/strict";
import { RECONCILER_LEASE_ID } from "../src/reconciler/lease.ts";
import { LedgerReadError } from "../src/reconciler/ledger.ts";
import { buildContinuityQuery, parseContinuityResponse } from "../src/reconciler/continuity.ts";
import { budgetPeriodAt } from "../src/reconciler/period.ts";
import { runReconciler } from "../src/reconciler/run.ts";
import type { RunAssets } from "../src/reconciler/run.ts";
import { readReconcilerSettings } from "../src/reconciler/settings.ts";
import { FakeAzure, LEDGER_KQL, ManualClock, continuityBody, ledgerBody } from "./helpers/reconciler-fakes.ts";
import type { FakeAzureOptions } from "./helpers/reconciler-fakes.ts";
import { PERSON_A, PERSON_B, entitlementDoc, ledgerRow, packagedRateCard, packagedSchedule, pilotProject, validSettings } from "./helpers/reconciler-fixtures.ts";

const card = packagedRateCard();
const assets: RunAssets = { rateCard: card, schedule: packagedSchedule(card), ledgerKql: LEDGER_KQL };
const START = "2026-10-11T13:00:00.000Z";
const OCTOBER = budgetPeriodAt(new Date(START));
const FULL = { input: 1000, output: 100, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, inferenceGeo: "global" };
const APIM_A = validSettings().RECONCILER_LEDGER_GATEWAY_RESOURCE_ID as string;
const APIM_B = APIM_A.replace("sample-pilot-apim", "sample-dr-apim");
const GATE_ON = { RECONCILER_CONTINUITY_GATE: "on", RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS: `${APIM_A},${APIM_B}` };
const PERSON_A_STATE = `${PERSON_A}:CCOFPILOT01`;

// Both gateways: A has the month from its first minutes until the outage, B has records since failover.
const HEALTHY = [
  { gatewayResourceId: APIM_A.toLowerCase(), earliest: "2026-10-01T00:03:00Z", newest: "2026-10-11T10:00:00Z" },
  { gatewayResourceId: APIM_B.toLowerCase(), earliest: "2026-10-11T10:05:00Z", newest: "2026-10-11T12:58:00Z" },
];

const iso = (rows: typeof HEALTHY) =>
  rows.map((r) => ({ gatewayResourceId: r.gatewayResourceId, earliest: new Date(r.earliest).toISOString(), newest: new Date(r.newest).toISOString() }));

function personState(spentCcu: string, period = "2026-10"): Record<string, unknown> {
  return { id: PERSON_A_STATE, personId: PERSON_A, projectId: "CCOFPILOT01", classification: "STD", spentCcu, period, computedAt: "2026-10-11T12:58:00.000Z" };
}

function pilot(options: FakeAzureOptions = {}): FakeAzure {
  return new FakeAzure({
    projects: [pilotProject()],
    entitlements: [
      entitlementDoc(PERSON_A, [{ projectId: "CCOFPILOT01", classification: "STD" }]),
      entitlementDoc(PERSON_B, [{ projectId: "CCOFPILOT01", classification: "PRM" }]),
    ],
    ledger: ledgerBody([ledgerRow(FULL), ledgerRow({ ...FULL, classification: "PRM", personId: PERSON_B })]),
    continuity: continuityBody(HEALTHY),
    persistedBudgetStates: { [PERSON_A_STATE]: personState("0.10") },
    ...options,
  });
}

async function runOnce(azure: FakeAzure, overrides: Record<string, string> = GATE_ON) {
  const result = readReconcilerSettings(validSettings(overrides));
  if (!result.ok) throw new Error(JSON.stringify(result.problems));
  const lines: string[] = [];
  const clock = new ManualClock(START);
  const summary = await runReconciler(result.settings, assets, azure.deps(), { now: clock.now, newRunId: () => "run-1", log: (l) => lines.push(l) });
  const parsed = lines.map((l) => JSON.parse(l) as Record<string, unknown>);
  const runLines = parsed.filter((l) => l.schema === "ccof.reconciler.run.v1");
  assert.equal(runLines.length, 1);
  return { summary, run: runLines[0], budgetLines: parsed.filter((l) => l.schema === "ccof.reconciler.budget.v1") };
}

function assertRefused(azure: FakeAzure, run: Record<string, unknown>, reason: string, label = reason): void {
  assert.deepEqual([run.outcome, run.reason], ["refused", reason], label);
  assert.equal(azure.writeCount, 0, `${label}: nothing is written`);
  assert.equal(azure.calls.includes("write"), false, label);
  assert.equal(azure.leases.docs.get(RECONCILER_LEASE_ID)?.doc.released, true, `${label}: lease released`);
}

test("continuity query: per-gateway earliest and newest LLM-log record in the half-open period, for the listed gateways only", () => {
  const query = buildContinuityQuery(OCTOBER, [APIM_A, APIM_B]);
  assert.match(query, /^ApiManagementGatewayLlmLog\n/);
  assert.ok(query.includes("| where TimeGenerated >= datetime(2026-10-01T00:00:00.000Z) and TimeGenerated < datetime(2026-11-01T00:00:00.000Z)"), query);
  assert.ok(query.includes(`| where _ResourceId in~ ('${APIM_A}', '${APIM_B}')`), query);
  assert.ok(query.includes("| summarize earliest = min(TimeGenerated), newest = max(TimeGenerated) by gatewayResourceId = tolower(_ResourceId)"), query);
  assert.throws(() => buildContinuityQuery(OCTOBER, [APIM_A, `${APIM_B}'`]), /gateway resource id/);
});

test("continuity answer: parsed by column name; a partial or malformed answer is a failed read", () => {
  const extents = parseContinuityResponse(continuityBody(HEALTHY));
  assert.deepEqual(extents.map((e) => [e.gatewayResourceId, e.newest.toISOString()]), [
    [APIM_A.toLowerCase(), "2026-10-11T10:00:00.000Z"],
    [APIM_B.toLowerCase(), "2026-10-11T12:58:00.000Z"],
  ]);
  for (const body of [{ ...continuityBody(HEALTHY), error: { code: "PartialError" } }, { tables: [] }, continuityBody([{ gatewayResourceId: APIM_A, earliest: "x", newest: "y" }])]) {
    assert.throws(() => parseContinuityResponse(body), (e: unknown) => e instanceof LedgerReadError);
  }
});

test("gate on, no gap and no lower spend: every state is written and the run line records the gate", async () => {
  const azure = pilot();
  const { run } = await runOnce(azure);
  assert.deepEqual([run.outcome, run.reason], ["written", null]);
  assert.equal(azure.writeCount, 5);
  assert.equal(azure.queries.length, 2, "the ledger query and the continuity query");
  assert.equal(run.continuityGate, "passed");
  assert.equal(run.continuityMaxGapSeconds, 900);
  assert.deepEqual(run.continuityGateways, iso(HEALTHY));
});

test("gate on, refusal (a): no listed gateway has a record newer than now minus the maximum gap", async () => {
  const stale = HEALTHY.map((g) => ({ ...g, newest: "2026-10-11T12:44:59Z" }));
  const azure = pilot({ continuity: continuityBody(stale) });
  const { run } = await runOnce(azure);
  assertRefused(azure, run, "ledger_continuity_gap");
  assert.equal(run.continuityCondition, "no_recent_record");
  assert.deepEqual(run.continuityGateways, iso(stale));
  const boundary = pilot({ continuity: continuityBody(HEALTHY.map((g) => ({ ...g, newest: "2026-10-11T12:45:00Z" }))) });
  assert.equal((await runOnce(boundary)).run.reason, "ledger_continuity_gap", "a record exactly 900 s old is not newer than now minus the gap");
});

test("gate on, (a) is per deployment: one recent gateway is enough, and the bound is the configured gap", async () => {
  const oneRecent = [{ ...HEALTHY[0], newest: "2026-10-11T12:00:00Z" }, { ...HEALTHY[1], newest: "2026-10-11T12:45:01Z" }];
  assert.equal((await runOnce(pilot({ continuity: continuityBody(oneRecent) }))).run.outcome, "written", "B is 899 s old");
  const wider = await runOnce(pilot({ continuity: continuityBody(HEALTHY.map((g) => ({ ...g, newest: "2026-10-11T12:30:01Z" }))) }),
    { ...GATE_ON, RECONCILER_CONTINUITY_MAX_GAP_SECONDS: "1800" });
  assert.equal(wider.run.outcome, "written");
});

test("gate on, refusal (b): the earliest record is later than period start plus the gap while persisted spend is non-zero", async () => {
  const late = [{ ...HEALTHY[0], earliest: "2026-10-01T00:15:01Z" }, HEALTHY[1]];
  const azure = pilot({ continuity: continuityBody(late) });
  const { run } = await runOnce(azure);
  assertRefused(azure, run, "ledger_continuity_gap");
  assert.equal(run.continuityCondition, "early_history_missing");
  assert.equal(run.persistedSpendNonZero, true);
  const atBound = await runOnce(pilot({ continuity: continuityBody([{ ...HEALTHY[0], earliest: "2026-10-01T00:15:00Z" }, HEALTHY[1]]) }));
  assert.equal(atBound.run.outcome, "written", "an earliest record exactly at period start plus the gap is not later than it");
});

test("gate on, (b) needs persisted spend in this period: none, zero or last month's does not refuse", async () => {
  const late = continuityBody([{ ...HEALTHY[0], earliest: "2026-10-05T00:00:00Z" }, HEALTHY[1]]);
  for (const [label, persisted] of [
    ["none", {}],
    ["zero", { [PERSON_A_STATE]: personState("0") }],
    ["last month", { [PERSON_A_STATE]: personState("900", "2026-09") }],
  ] as const) {
    const azure = pilot({ continuity: late, persistedBudgetStates: persisted });
    const { run } = await runOnce(azure);
    assert.equal(run.outcome, "written", label);
  }
});

test("gate on: an empty month with persisted spend is a gap; an empty month without it is the start of a month", async () => {
  const withSpend = pilot({ ledger: ledgerBody([]), continuity: continuityBody([]) });
  const refused = await runOnce(withSpend);
  assertRefused(withSpend, refused.run, "ledger_continuity_gap");
  assert.equal(refused.run.continuityCondition, "early_history_missing");
  const fresh = await runOnce(pilot({ ledger: ledgerBody([]), continuity: continuityBody([]), persistedBudgetStates: {} }));
  assert.equal(fresh.run.outcome, "written");
});

test("gate on: a person state with less spend than the persisted one for the same period is refused as spend_would_decrease", async () => {
  const azure = pilot({ persistedBudgetStates: { [PERSON_A_STATE]: personState("0.16") } });
  const { run } = await runOnce(azure);
  assertRefused(azure, run, "spend_would_decrease");
  assert.deepEqual(run.decreasedScopes, [PERSON_A_STATE]);
  assert.equal(run.decreasedScopeCount, 1);
  const equal = await runOnce(pilot({ persistedBudgetStates: { [PERSON_A_STATE]: personState("0.15") } }));
  assert.equal(equal.run.outcome, "written", "equal spend is not a decrease");
});

test("gate on: a group state with less spend than this period's persisted group state is refused; last period's is not compared", async () => {
  const group = (computedAt: string) => ({ "CCOFPILOT01:STD": { id: "CCOFPILOT01:STD", scopeId: "CCOFPILOT01:STD", spentCcu: "10", computedAt } });
  const azure = pilot({ persistedAggregateStates: group("2026-10-11T12:58:00.000Z") });
  const { run } = await runOnce(azure);
  assertRefused(azure, run, "spend_would_decrease");
  assert.deepEqual(run.decreasedScopes, ["CCOFPILOT01:STD"]);
  const previous = await runOnce(pilot({ persistedAggregateStates: group("2026-09-30T23:59:00.000Z") }));
  assert.equal(previous.run.outcome, "written");
});

test("gate on: a failed continuity read or a failed or malformed state read writes nothing", async () => {
  const failures: Array<[string, FakeAzureOptions, string]> = [
    ["continuity HTTP error", { continuity: async () => { throw new LedgerReadError("ledger_http_error", "503"); } }, "ledger_http_error"],
    ["continuity partial", { continuity: { ...continuityBody(HEALTHY), error: { code: "PartialError" } } }, "ledger_partial_result"],
    ["state read", { failStateRead: Object.assign(new Error("boom"), { code: 503 }) }, "budget_state_read_failed"],
    ["state malformed", { persistedBudgetStates: { [PERSON_A_STATE]: personState("lots") } }, "budget_state_read_failed"],
    ["state negative", { persistedBudgetStates: { [PERSON_A_STATE]: personState("-5") } }, "budget_state_read_failed"],
  ];
  for (const [label, options, reason] of failures) {
    const azure = pilot(options);
    const { run } = await runOnce(azure);
    assert.deepEqual([run.outcome, run.reason], ["failed", reason], label);
    assert.equal(azure.writeCount, 0, label);
  }
});

test("gate off: today's run, one ledger query, no state read, no gate fields, even with a gap and lower spend", async () => {
  const gap = continuityBody(HEALTHY.map((g) => ({ ...g, earliest: "2026-10-09T00:00:00Z", newest: "2026-10-09T01:00:00Z" })));
  for (const overrides of [{}, { RECONCILER_CONTINUITY_GATE: "off" }] as Array<Record<string, string>>) {
    const azure = pilot({ continuity: gap, persistedBudgetStates: { [PERSON_A_STATE]: personState("900") } });
    const { run } = await runOnce(azure, overrides);
    assert.deepEqual([run.outcome, run.reason], ["written", null]);
    assert.equal(azure.writeCount, 5);
    assert.equal(azure.queries.length, 1);
    assert.equal(azure.calls.some((c) => c.startsWith("read") && c.includes("State")), false);
    assert.equal(Object.keys(run).some((k) => k.startsWith("continuity") || k === "decreasedScopes"), false);
  }
});
