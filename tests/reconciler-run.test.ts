// One reconciler run end to end with fakes for Cosmos and the Log Analytics
// query API (docs/PILOT.md C-7, AC8-AC13): lease, no write on any failed
// read, one line per state and per run, ids and codes only.

import { test } from "node:test";
import assert from "node:assert/strict";
import { RECONCILER_LEASE_ID } from "../src/reconciler/lease.ts";
import { LedgerReadError } from "../src/reconciler/ledger.ts";
import { runReconciler, settingsFailure } from "../src/reconciler/run.ts";
import type { RunAssets } from "../src/reconciler/run.ts";
import { readReconcilerSettings } from "../src/reconciler/settings.ts";
import type { ReconcilerSettings } from "../src/reconciler/settings.ts";
import { BUDGET_FIELDS } from "../src/reconciler/telemetry.ts";
import { FakeAzure, LEDGER_KQL, ManualClock, ledgerBody } from "./helpers/reconciler-fakes.ts";
import type { FakeAzureOptions } from "./helpers/reconciler-fakes.ts";
import {
  PERSON_A,
  PERSON_B,
  entitlementDoc,
  ledgerRow,
  packagedRateCard,
  packagedSchedule,
  pilotProject,
  validSettings,
} from "./helpers/reconciler-fixtures.ts";

const card = packagedRateCard();
const assets: RunAssets = { rateCard: card, schedule: packagedSchedule(card), ledgerKql: LEDGER_KQL };
const START = "2026-10-11T13:00:00.000Z";
const FULL = { input: 1000, output: 100, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, inferenceGeo: "global" };

function settings(overrides: Record<string, string> = {}): ReconcilerSettings {
  const result = readReconcilerSettings(validSettings(overrides));
  if (!result.ok) throw new Error(JSON.stringify(result.problems));
  return result.settings;
}

function pilot(options: FakeAzureOptions = {}): FakeAzure {
  return new FakeAzure({
    projects: [pilotProject()],
    entitlements: [
      entitlementDoc(PERSON_A, [{ projectId: "CCOFPILOT01", classification: "STD" }]),
      entitlementDoc(PERSON_B, [{ projectId: "CCOFPILOT01", classification: "PRM" }]),
    ],
    ledger: ledgerBody([ledgerRow(FULL), ledgerRow({ ...FULL, classification: "PRM", personId: PERSON_B })]),
    ...options,
  });
}

async function runOnce(azure: FakeAzure, clock = new ManualClock(START), runId = "run-1", overrides: Record<string, string> = {}) {
  const lines: string[] = [];
  const summary = await runReconciler(settings(overrides), assets, azure.deps(), { now: clock.now, newRunId: () => runId, log: (l) => lines.push(l) });
  const parsed = lines.map((l) => JSON.parse(l) as Record<string, unknown>);
  return {
    summary,
    lines,
    runLine: parsed.filter((l) => l.schema === "ccof.reconciler.run.v1"),
    budgetLines: parsed.filter((l) => l.schema === "ccof.reconciler.budget.v1"),
  };
}

test("one run writes a state for every registered member and group, and logs one budget line each and one run line", async () => {
  const azure = pilot();
  const { summary, runLine, budgetLines, lines } = await runOnce(azure);
  assert.deepEqual(azure.budgetStates.map((d) => d.id), [`${PERSON_A}:CCOFPILOT01`, `${PERSON_B}:CCOFPILOT01`]);
  assert.deepEqual(azure.aggregateStates.map((d) => d.id), ["CCOFPILOT01:CYB", "CCOFPILOT01:PRM", "CCOFPILOT01:STD"]);
  assert.equal(budgetLines.length, 5);
  assert.equal(runLine.length, 1);
  assert.equal(summary.outcome, "written");
  assert.deepEqual(
    [runLine[0].personStates, runLine[0].groupStates, runLine[0].statesWritten, runLine[0].ledgerRows, runLine[0].pricedRequests],
    [2, 3, 5, 2, 2],
  );
  assert.ok(lines.every((l) => l.startsWith('{"schema":"ccof.reconciler.')), "schema is the first key of every line");
  assert.equal(azure.leases.docs.get(RECONCILER_LEASE_ID)?.doc.released, true, "the lease is released at the end");
});

test("a budget line has exactly the fields agreed with WP-WB, in order, with exact decimal strings", async () => {
  const { budgetLines } = await runOnce(pilot());
  for (const line of budgetLines) assert.deepEqual(Object.keys(line), [...BUDGET_FIELDS]);
  const person = budgetLines.find((l) => l.scope === "person" && l.personId === PERSON_A);
  assert.deepEqual(
    [person?.scopeId, person?.spentCcu, person?.budgetCcu, person?.mode, person?.activeMemberCount, person?.periodStart, person?.periodEnd],
    [`${PERSON_A}:CCOFPILOT01`, "0.15", "25000", "strict", null, "2026-10-01T00:00:00.000Z", "2026-11-01T00:00:00.000Z"],
  );
  const cyb = budgetLines.find((l) => l.scopeId === "CCOFPILOT01:CYB");
  assert.deepEqual([cyb?.scope, cyb?.personId, cyb?.budgetCcu, cyb?.mode, cyb?.activeMemberCount], ["group", null, null, "notify", 0]);
});

test("configured pacing reaches the written state and the budget line; a group line has no soft-limit flag", async () => {
  const azure = pilot();
  const { budgetLines } = await runOnce(azure, undefined, "run-1", { RECONCILER_SOFT_LIMIT_PERCENT: "80", RECONCILER_PACING_WINDOW_MINUTES: "10" });
  const doc = azure.budgetStates.find((d) => d.personId === PERSON_A);
  assert.deepEqual([doc?.softLimitPercent, doc?.softLimitReached], [80, false]);
  // (25,000 - 0.15) CCU / 10 minutes / 0.0011 CCU per token = 2,272,713.6, rounded down to 2^21.
  assert.equal(doc?.realtimeCeilingTokensPerMinute, 2_097_152);
  assert.equal(budgetLines.find((l) => l.scope === "person" && l.personId === PERSON_A)?.softLimitReached, false);
  assert.equal(budgetLines.find((l) => l.scope === "group")?.softLimitReached, null);
  const unpaced = await runOnce(pilot());
  assert.equal(unpaced.budgetLines.find((l) => l.scope === "person")?.softLimitReached, null, "no pacing: no flag");
});

test("the ledger query covers the UTC month and the configured gateway, with the matching timespan", async () => {
  const azure = pilot();
  await runOnce(azure);
  assert.equal(azure.queries.length, 1);
  assert.equal(azure.queries[0].timespan, "2026-10-01T00:00:00.000Z/2026-11-01T00:00:00.000Z");
  assert.ok(azure.queries[0].query.includes("CcofUsageLedger(datetime(2026-10-01T00:00:00.000Z), datetime(2026-11-01T00:00:00.000Z), '/subscriptions/"));
});

// The detector for WP-E2E G6: with Cache-Control no-cache every answer is fresh, so a number here means the
// query API served a cached answer that many seconds old.
test("the run line reports the ledger answer's cache age: null when fresh, its seconds when cached", async () => {
  const fresh = await runOnce(pilot());
  assert.equal(fresh.runLine[0].outcome, "written");
  assert.equal(fresh.runLine[0].ledgerResponseAgeSeconds, null);
  const cached = await runOnce(pilot({ ledgerAgeSeconds: 75 }));
  assert.equal(cached.runLine[0].outcome, "written");
  assert.equal(cached.runLine[0].ledgerResponseAgeSeconds, 75);
});

test("a failed ledger read writes nothing, whatever the failure", async () => {
  const failures: Array<[string, FakeAzureOptions["ledger"], string]> = [
    ["HTTP error", async () => { throw new LedgerReadError("ledger_http_error", "503"); }, "ledger_http_error"],
    ["timeout", async () => { throw new LedgerReadError("ledger_timeout"); }, "ledger_timeout"],
    ["network", async () => { throw new TypeError("fetch failed"); }, "ledger_read_failed"],
    ["partial result", { ...ledgerBody([ledgerRow(FULL)]), error: { code: "PartialError" } }, "ledger_partial_result"],
    ["malformed", { tables: [] }, "ledger_response_invalid"],
    ["row outside the period", ledgerBody([ledgerRow({ ...FULL, timestamp: "2026-09-30T23:59:59.0000000Z" })]), "ledger_row_outside_period"],
  ];
  for (const [label, ledger, reason] of failures) {
    const azure = pilot({ ledger });
    const { runLine, budgetLines } = await runOnce(azure);
    assert.equal(azure.writeCount, 0, label);
    assert.equal(budgetLines.length, 0, label);
    assert.deepEqual([runLine[0].outcome, runLine[0].reason], ["failed", reason], label);
    assert.equal(azure.leases.docs.get(RECONCILER_LEASE_ID)?.doc.released, true, `${label}: lease released`);
  }
});

test("a row count at the configured limit writes nothing", async () => {
  const azure = pilot();
  const { runLine } = await runOnce(azure, undefined, "run-1", { RECONCILER_LEDGER_MAX_ROWS: "2" });
  assert.equal(azure.writeCount, 0);
  assert.equal(runLine[0].reason, "ledger_row_limit_reached");
});

test("a failed registry read writes nothing and never queries the ledger", async () => {
  const azure = pilot({ failProjects: Object.assign(new Error("boom"), { code: 503 }) });
  const { runLine } = await runOnce(azure);
  assert.equal(azure.writeCount, 0);
  assert.equal(azure.queries.length, 0);
  assert.deepEqual([runLine[0].reason, runLine[0].errorCode], ["registry_read_failed", "503"]);
});

test("more states than RECONCILER_MAX_STATES writes nothing", async () => {
  const azure = pilot();
  const { runLine } = await runOnce(azure, undefined, "run-1", { RECONCILER_MAX_STATES: "4" });
  assert.equal(azure.writeCount, 0);
  assert.equal(runLine[0].reason, "state_limit_exceeded");
});

test("while another run holds the lease, a run reads nothing and writes nothing", async () => {
  const azure = pilot();
  const clock = new ManualClock(START);
  azure.leases.docs.set(RECONCILER_LEASE_ID, {
    doc: { id: RECONCILER_LEASE_ID, holder: "run-0", acquiredAt: START, renewedAt: START, leaseExpiresAt: "2026-10-11T13:05:00.000Z", released: false },
    etag: '"held"',
  });
  const { runLine } = await runOnce(azure, clock, "run-1");
  assert.deepEqual([runLine[0].outcome, runLine[0].heldBy], ["skipped_lease_held", "run-0"]);
  assert.deepEqual(azure.calls, []);
  clock.advance(300);
  const later = await runOnce(azure, clock, "run-2");
  assert.equal(later.runLine[0].outcome, "written", "the stopped run's lease expired");
});

test("a lost lease stops the writes: the run fails with lease_lost and logs only what it wrote", async () => {
  const azure = pilot();
  const clock = new ManualClock(START);
  const lines: string[] = [];
  const deps = azure.deps();
  const write = deps.writeBudgetState;
  // The first write takes 200 s; by the next ensure() a third of the lease
  // has passed and the renewal finds the lease taken.
  deps.writeBudgetState = async (doc) => {
    await write(doc);
    clock.advance(200);
    azure.leases.failNextReplace = true;
  };
  const summary = await runReconciler(settings({ RECONCILER_WRITE_CONCURRENCY: "1" }), assets, deps, { now: clock.now, newRunId: () => "run-1", log: (l) => lines.push(l) });
  assert.deepEqual([summary.outcome, summary.reason, summary.statesWritten], ["failed", "lease_lost", 1]);
  assert.equal(azure.writeCount, 1);
  assert.equal(lines.filter((l) => l.includes("ccof.reconciler.budget.v1")).length, 1);
});

test("a write failure stops further writes and reports how many states were written", async () => {
  const azure = pilot({ failWrite: { at: 3, error: Object.assign(new Error("throttled"), { code: 429 }) } });
  const { runLine, budgetLines } = await runOnce(azure, undefined, "run-1", { RECONCILER_WRITE_CONCURRENCY: "1" });
  assert.deepEqual([runLine[0].outcome, runLine[0].reason, runLine[0].errorCode, runLine[0].statesWritten], ["failed", "state_write_failed", "429", 2]);
  assert.equal(azure.writeCount, 2);
  assert.equal(budgetLines.length, 2);
});

test("two runs with the same inputs and clock write identical documents (idempotent)", async () => {
  const first = pilot();
  const second = pilot();
  await runOnce(first, new ManualClock(START), "run-1");
  await runOnce(second, new ManualClock(START), "run-2");
  assert.deepEqual(second.budgetStates, first.budgetStates);
  assert.deepEqual(second.aggregateStates, first.aggregateStates);
});

test("a period with no usage still renews every member's and group's state", async () => {
  const azure = pilot({ ledger: ledgerBody([]) });
  const { runLine } = await runOnce(azure);
  assert.equal(runLine[0].outcome, "written");
  assert.equal(azure.writeCount, 5);
  assert.ok(azure.budgetStates.every((d) => d.spentCcu === "0" && d.validUntil === "2026-10-11T13:10:00.000Z"));
});

test("log lines carry ids and codes, never a project's display name", async () => {
  const azure = pilot({ projects: [pilotProject({ displayName: "Confidential Programme Zeta" })] });
  const { lines } = await runOnce(azure);
  assert.ok(lines.every((l) => !l.includes("Zeta")));
});

test("registry problems are reported in the run line as codes and ids", async () => {
  const azure = pilot({ entitlements: [entitlementDoc(PERSON_A, [{ projectId: "OTHER", classification: "STD" }])] });
  const { runLine } = await runOnce(azure);
  assert.deepEqual(runLine[0].problems, [`membership_scope_not_registered:OTHER:STD:${PERSON_A}`]);
});

test("invalid settings produce one settings_invalid line naming them, and nothing else happens", () => {
  const lines: string[] = [];
  settingsFailure([{ setting: "RECONCILER_SCHEDULE", problem: "missing" }], { now: () => new Date(START), newRunId: () => "run-x", log: (l) => lines.push(l) });
  assert.equal(lines.length, 1);
  assert.deepEqual(JSON.parse(lines[0]), {
    schema: "ccof.reconciler.run.v1",
    runId: "run-x",
    outcome: "settings_invalid",
    reason: "settings_invalid",
    problems: ["RECONCILER_SCHEDULE:missing"],
  });
});

test("a slow ledger read past a third of the lease, then 8 concurrent writers: one renewal, every state written", async () => {
  const clock = new ManualClock(START);
  const body = ledgerBody([ledgerRow(FULL)]);
  const azure = pilot({
    ledger: async () => {
      clock.advance(101);
      return body;
    },
  });
  const { summary } = await runOnce(azure, clock, "run-1", { RECONCILER_WRITE_CONCURRENCY: "8" });
  assert.deepEqual([summary.outcome, summary.statesWritten], ["written", 5]);
  assert.equal(azure.leases.ops.filter((op) => op.startsWith("replace")).length, 2, "one renewal, one release");
});
