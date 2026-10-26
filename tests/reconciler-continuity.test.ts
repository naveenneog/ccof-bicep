// The ledger continuity gate (DR-05R).
// With the gate on, a run refuses when gateway requests and LLM usage do not
// correlate, coverage begins after traffic, or persisted spend would decrease.
// Off, the run is unchanged and performs no state reads.

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
const COVERAGE_START = "2026-10-01T00:00:00.000Z";
const GATE_ON = {
  RECONCILER_CONTINUITY_GATE: "on",
  RECONCILER_LEDGER_COVERAGE_START_AT: COVERAGE_START,
  RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS: `${APIM_A},${APIM_B}`,
};
const PERSON_A_STATE = `${PERSON_A}:CCOFPILOT01`;

function personState(spentCcu: string, period = "2026-10", coverageStartAt: string | null = COVERAGE_START): Record<string, unknown> {
  return {
    id: PERSON_A_STATE,
    personId: PERSON_A,
    projectId: "CCOFPILOT01",
    classification: "STD",
    spentCcu,
    period,
    computedAt: "2026-10-11T12:58:00.000Z",
    ...(coverageStartAt ? { ledgerCoverageStartAt: coverageStartAt } : {}),
  };
}

function pilot(options: FakeAzureOptions = {}): FakeAzure {
  return new FakeAzure({
    projects: [pilotProject()],
    entitlements: [
      entitlementDoc(PERSON_A, [{ projectId: "CCOFPILOT01", classification: "STD" }]),
      entitlementDoc(PERSON_B, [{ projectId: "CCOFPILOT01", classification: "PRM" }]),
    ],
    ledger: ledgerBody([ledgerRow(FULL), ledgerRow({ ...FULL, classification: "PRM", personId: PERSON_B })]),
    continuity: continuityBody([]),
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

test("continuity query: verifies gateway request and LLM usage coverage from the configured start", () => {
  const query = buildContinuityQuery(OCTOBER, [APIM_A, APIM_B], COVERAGE_START);
  assert.match(query, /^let periodStart = datetime\(/);
  assert.ok(query.includes("ApiManagementGatewayLogs"), query);
  assert.ok(query.includes("ApiManagementGatewayLlmLog"), query);
  assert.ok(query.includes("2026-10-01T00:00:00.000Z"), query);
  assert.ok(query.includes("2026-11-01T00:00:00.000Z"), query);
  assert.ok(query.includes(COVERAGE_START), query);
  assert.ok(query.includes(`'${APIM_A}'`) && query.includes(`'${APIM_B}'`), query);
  assert.ok(query.includes("CorrelationId"), query);
  assert.ok(query.includes("BackendId"), query);
  assert.match(query, /join kind=leftanti/, "LLM usage without a gateway request is part of the continuity check");
  assert.throws(() => buildContinuityQuery(OCTOBER, [APIM_A, `${APIM_B}'`], COVERAGE_START), /gateway resource id/);
});

test("continuity answer: parsed by column name; a partial or malformed answer is a failed read", () => {
  const gaps = [
    { gatewayResourceId: APIM_A.toLowerCase(), gapKind: "backend_call_without_llm", issueCount: 2, firstAt: "2026-10-11T10:00:00.000Z" },
    { gatewayResourceId: APIM_B.toLowerCase(), gapKind: "request_before_coverage", issueCount: 1, firstAt: "2026-10-11T12:58:00.000Z" },
    { gatewayResourceId: APIM_B.toLowerCase(), gapKind: "llm_without_gateway", issueCount: 1, firstAt: "2026-10-11T12:59:00.000Z" },
  ];
  const parsed = parseContinuityResponse(continuityBody(gaps));
  assert.deepEqual(parsed.map((gap) => [gap.gatewayResourceId, gap.gapKind, gap.issueCount, gap.firstAt.toISOString()]), [
    [APIM_A.toLowerCase(), "backend_call_without_llm", 2, "2026-10-11T10:00:00.000Z"],
    [APIM_B.toLowerCase(), "request_before_coverage", 1, "2026-10-11T12:58:00.000Z"],
    [APIM_B.toLowerCase(), "llm_without_gateway", 1, "2026-10-11T12:59:00.000Z"],
  ]);
  for (const body of [
    { ...continuityBody(gaps), error: { code: "PartialError" } },
    { tables: [] },
    continuityBody([{ gatewayResourceId: APIM_A, gapKind: "unknown", issueCount: 1, firstAt: "x" }]),
    continuityBody([{ gatewayResourceId: APIM_A, gapKind: "backend_call_without_llm", issueCount: -1, firstAt: "2026-10-11T10:00:00.000Z" }]),
  ]) {
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
  assert.equal(run.continuityCoverageStartAt, COVERAGE_START);
  assert.deepEqual(run.continuityGaps, []);
  assert.ok(azure.budgetStates.every((doc) => doc.ledgerCoverageStartAt === COVERAGE_START));
  assert.ok(azure.aggregateStates.every((doc) => doc.ledgerCoverageStartAt === COVERAGE_START));
});

test("gate on: a quiet period does not refuse when the persisted coverage marker matches", async () => {
  const azure = pilot({ continuity: continuityBody([]) });
  const { run } = await runOnce(azure);
  assert.deepEqual([run.outcome, run.reason], ["written", null]);
  assert.equal(azure.writeCount, 5);
});

test("gate on: a fresh mid-month deployment establishes and reuses its coverage baseline", async () => {
  const coverageStartAt = "2026-10-11T12:00:00.000Z";
  const overrides = { ...GATE_ON, RECONCILER_LEDGER_COVERAGE_START_AT: coverageStartAt };
  const first = pilot({ continuity: continuityBody([]), persistedBudgetStates: {}, persistedAggregateStates: {} });
  const firstRun = await runOnce(first, overrides);
  assert.deepEqual([firstRun.run.outcome, firstRun.run.reason], ["written", null]);
  assert.ok(first.budgetStates.every((doc) => doc.ledgerCoverageStartAt === coverageStartAt));
  assert.ok(first.aggregateStates.every((doc) => doc.ledgerCoverageStartAt === coverageStartAt));
  const second = pilot({
    continuity: continuityBody([]),
    persistedBudgetStates: Object.fromEntries(first.budgetStates.map((doc) => [doc.id, doc])),
    persistedAggregateStates: Object.fromEntries(first.aggregateStates.map((doc) => [doc.id, doc])),
  });
  const secondRun = await runOnce(second, overrides);
  assert.deepEqual([secondRun.run.outcome, second.writeCount], ["written", 5]);
});

test("gate on: a backend request without an LLM usage row refuses before any write", async () => {
  const gap = {
    gatewayResourceId: APIM_B.toLowerCase(),
    gapKind: "backend_call_without_llm",
    issueCount: 1,
    firstAt: "2026-10-11T12:30:00.000Z",
  };
  const azure = pilot({ continuity: continuityBody([gap]) });
  const { run } = await runOnce(azure);
  assertRefused(azure, run, "ledger_continuity_gap");
  assert.equal(run.continuityCondition, "backend_call_without_llm");
});

test("gate on: an LLM usage row without its gateway request refuses before any write", async () => {
  const gap = {
    gatewayResourceId: APIM_B.toLowerCase(),
    gapKind: "llm_without_gateway",
    issueCount: 1,
    firstAt: "2026-10-11T12:30:00.000Z",
  };
  const azure = pilot({ continuity: continuityBody([gap]) });
  const { run } = await runOnce(azure);
  assertRefused(azure, run, "ledger_continuity_gap");
  assert.equal(run.continuityCondition, "llm_without_gateway");
});

test("gate on: a model request before diagnostic coverage refuses before any write", async () => {
  const gap = {
    gatewayResourceId: APIM_A.toLowerCase(),
    gapKind: "request_before_coverage",
    issueCount: 1,
    firstAt: "2026-10-01T00:01:00.000Z",
  };
  const azure = pilot({ continuity: continuityBody([gap]) });
  const { run } = await runOnce(azure, { ...GATE_ON, RECONCILER_LEDGER_COVERAGE_START_AT: "2026-10-01T00:02:00.000Z" });
  assertRefused(azure, run, "ledger_continuity_gap");
  assert.equal(run.continuityCondition, "request_before_coverage");
});

test("gate on: a future coverage start is refused before continuity reads or writes", async () => {
  const azure = pilot();
  const { run } = await runOnce(azure, { ...GATE_ON, RECONCILER_LEDGER_COVERAGE_START_AT: "2026-10-11T14:00:00.000Z" });
  assertRefused(azure, run, "ledger_coverage_start_future");
  assert.equal(azure.queries.length, 1, "only the ordinary ledger query ran");
});

test("gate on: usage without budget attribution refuses before any write", async () => {
  const azure = pilot({ ledger: ledgerBody([ledgerRow({ ...FULL, attributionKnown: false })]) });
  const { run } = await runOnce(azure);
  assertRefused(azure, run, "ledger_attribution_missing");
  assert.equal(run.unattributedRequests, 1);
});

const NO_TOKENS = { input: null, output: null, cacheWrite5m: null, cacheWrite1h: null, cacheRead: null };

test("gate on: an unattributed failed call with no token counts is reported, not refused", async () => {
  const failed = ledgerRow({ ...NO_TOKENS, attributionKnown: false, requestFailed: true, usageSource: "log" });
  const azure = pilot({ ledger: ledgerBody([ledgerRow(FULL), ledgerRow({ ...FULL, classification: "PRM", personId: PERSON_B }), failed]) });
  const { run } = await runOnce(azure);
  assert.deepEqual([run.outcome, run.reason], ["written", null]);
  assert.equal(run.unattributedFailedRequests, 1);
});

test("gate on: an unattributed call still refuses when it succeeded or carries any token count", async () => {
  const succeeded = pilot({ ledger: ledgerBody([ledgerRow({ ...NO_TOKENS, attributionKnown: false, requestFailed: false, usageSource: "log" })]) });
  assertRefused(succeeded, (await runOnce(succeeded)).run, "ledger_attribution_missing", "succeeded without tokens");
  const counted = pilot({ ledger: ledgerBody([ledgerRow({ ...NO_TOKENS, input: 5, attributionKnown: false, requestFailed: true, usageSource: "log" })]) });
  assertRefused(counted, (await runOnce(counted)).run, "ledger_attribution_missing", "failed with a token count");
});

test("gate on: a legacy current-period state without a verified coverage marker refuses", async () => {
  const azure = pilot({ persistedBudgetStates: { [PERSON_A_STATE]: personState("0.10", "2026-10", null) } });
  const { run } = await runOnce(azure);
  assertRefused(azure, run, "ledger_coverage_baseline_missing");
});

const ADOPT = { ...GATE_ON, RECONCILER_LEDGER_BASELINE_ADOPT: COVERAGE_START };

test("gate on with baseline adoption: an unmarked current-period state is adopted, stamped and counted", async () => {
  const azure = pilot({ persistedBudgetStates: { [PERSON_A_STATE]: personState("0.10", "2026-10", null) } });
  const { run } = await runOnce(azure, ADOPT);
  assert.deepEqual([run.outcome, run.reason], ["written", null]);
  assert.equal(run.continuityGate, "passed");
  assert.equal(run.continuityBaselineAdopted, 1);
  assert.ok(azure.budgetStates.every((doc) => doc.ledgerCoverageStartAt === COVERAGE_START));
  assert.ok(azure.aggregateStates.every((doc) => doc.ledgerCoverageStartAt === COVERAGE_START));
});

test("gate on with baseline adoption: a marked state is not counted as adopted", async () => {
  const { run } = await runOnce(pilot(), ADOPT);
  assert.deepEqual([run.outcome, run.continuityBaselineAdopted], ["written", 0]);
});

test("gate on with baseline adoption: a changed marker, a log gap and lower spend still refuse", async () => {
  const mismatch = pilot({ persistedBudgetStates: { [PERSON_A_STATE]: personState("0.10", "2026-10", "2026-10-02T00:00:00.000Z") } });
  assertRefused(mismatch, (await runOnce(mismatch, ADOPT)).run, "ledger_coverage_baseline_mismatch");
  const gap = { gatewayResourceId: APIM_B.toLowerCase(), gapKind: "backend_call_without_llm", issueCount: 1, firstAt: "2026-10-11T12:30:00.000Z" };
  const gapped = pilot({ continuity: continuityBody([gap]), persistedBudgetStates: { [PERSON_A_STATE]: personState("0.10", "2026-10", null) } });
  assertRefused(gapped, (await runOnce(gapped, ADOPT)).run, "ledger_continuity_gap");
  const lower = pilot({ persistedBudgetStates: { [PERSON_A_STATE]: personState("0.16", "2026-10", null) } });
  assertRefused(lower, (await runOnce(lower, ADOPT)).run, "spend_would_decrease", "an adopted state cannot lower spend");
});

test("gate on: a persisted coverage marker cannot change within a budget period", async () => {
  const azure = pilot({ persistedBudgetStates: { [PERSON_A_STATE]: personState("0.10", "2026-10", "2026-10-02T00:00:00.000Z") } });
  const { run } = await runOnce(azure);
  assertRefused(azure, run, "ledger_coverage_baseline_mismatch");
});

test("gate on: empty usage cannot lower persisted spend; an empty month without state is a valid baseline", async () => {
  const withSpend = pilot({ ledger: ledgerBody([]), continuity: continuityBody([]) });
  const refused = await runOnce(withSpend);
  assertRefused(withSpend, refused.run, "spend_would_decrease");
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
  const group = (computedAt: string) => ({ "CCOFPILOT01:STD": { id: "CCOFPILOT01:STD", scopeId: "CCOFPILOT01:STD", spentCcu: "10", computedAt, ledgerCoverageStartAt: COVERAGE_START } });
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
    ["continuity partial", { continuity: { ...continuityBody([]), error: { code: "PartialError" } } }, "ledger_partial_result"],
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
  const gap = continuityBody([{ gatewayResourceId: APIM_A.toLowerCase(), gapKind: "request_before_coverage", issueCount: 1, firstAt: "2026-10-09T00:00:00Z" }]);
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
