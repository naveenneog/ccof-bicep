// The reconciler's pure core (docs/PILOT.md C-7): from the registry and the
// priced ledger rows of the period, one budgetState per registered member
// and project and one aggregateBudgetState per registered group.

import { test } from "node:test";
import assert from "node:assert/strict";
import type { LedgerRow } from "../src/reconciler/ledger.ts";
import { budgetPeriodAt } from "../src/reconciler/period.ts";
import { classifyRow } from "../src/reconciler/price-rows.ts";
import { reconcile } from "../src/reconciler/reconcile.ts";
import type { SpendPacing } from "../src/reconciler/compute-ceiling.ts";
import { readRegistry } from "../src/reconciler/registry.ts";
import {
  PERSON_A,
  PERSON_B,
  PERSON_C,
  entitlementDoc,
  ledgerRow,
  packagedRateCard,
  packagedSchedule,
  pilotProject,
} from "./helpers/reconciler-fixtures.ts";
import type { LedgerRowSpec } from "./helpers/reconciler-fixtures.ts";

const card = packagedRateCard();
const schedule = packagedSchedule(card);
const computedAt = new Date("2026-10-11T13:00:00.000Z");
const validUntil = new Date("2026-10-11T13:10:00.000Z");
const period = budgetPeriodAt(computedAt);

// A fully captured Haiku 4.5 row: 1,000 input + 100 output tokens = 0.15 CCU.
const FULL: LedgerRowSpec = { input: 1000, output: 100, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, inferenceGeo: "global" };

function run(options: { projects?: unknown[]; entitlements?: unknown[]; rows?: LedgerRowSpec[]; pacing?: SpendPacing } = {}) {
  const registry = readRegistry(
    options.projects ?? [pilotProject()],
    options.entitlements ?? [
      entitlementDoc(PERSON_A, [{ projectId: "CCOFPILOT01", classification: "STD" }]),
      entitlementDoc(PERSON_B, [{ projectId: "CCOFPILOT01", classification: "PRM" }]),
    ],
  );
  const rows = (options.rows ?? []).map((spec) => classifyRow(ledgerRow(spec) as LedgerRow, period, card, schedule));
  return reconcile({ registry, rows, rateCard: card, contractScheduleVersion: schedule.version, period, computedAt, validUntil, pacing: options.pacing });
}

const personDoc = (result: ReturnType<typeof run>, personId: string) => result.persons.find((p) => p.doc.personId === personId);
const groupDoc = (result: ReturnType<typeof run>, scopeId: string) => result.groups.find((g) => g.doc.scopeId === scopeId);

test("a registered member with usage gets the C-7 document: exact spend, budget, period, versions, validity, ceiling", () => {
  const result = run({ rows: [FULL, FULL] });
  assert.deepEqual(personDoc(result, PERSON_A)?.doc, {
    id: `${PERSON_A}:CCOFPILOT01`,
    personId: PERSON_A,
    projectId: "CCOFPILOT01",
    classification: "STD",
    spentCcu: "0.3",
    budgetCcu: "25000",
    exhausted: false,
    period: "2026-10",
    rateCardVersion: card.version,
    contractScheduleVersion: schedule.version,
    computedAt: "2026-10-11T13:00:00.000Z",
    validUntil: "2026-10-11T13:10:00.000Z",
    completeness: "complete",
    // (25,000 - 0.3) CCU / 0.0011 CCU per token (Sonnet 5 output at 1.1x) = 22,727,000 exactly.
    realtimeCeilingTokensPerMinute: 22_727_000,
  });
});

test("a registered member with no usage still gets a fresh document (onboarding Stage 5 needs everyone)", () => {
  const result = run({ rows: [] });
  const b = personDoc(result, PERSON_B)?.doc;
  assert.equal(b?.spentCcu, "0");
  assert.equal(b?.exhausted, false);
  assert.equal(b?.completeness, "complete");
  assert.equal(b?.validUntil, "2026-10-11T13:10:00.000Z");
  assert.equal(result.persons.length, 2);
});

test("exhausted is spent >= budget: true at equality, false one smallest unit below", () => {
  const project = (amount: string) => {
    const p = pilotProject();
    (p.classifications as Record<string, Record<string, unknown>>).STD.personBudget = { amount, currency: "CCU", period: "monthly" };
    return p;
  };
  const atBudget = personDoc(run({ projects: [project("0.15")], rows: [FULL] }), PERSON_A)?.doc;
  assert.equal(atBudget?.exhausted, true);
  assert.equal(atBudget?.realtimeCeilingTokensPerMinute, 0);
  const below = personDoc(run({ projects: [project("0.1500000000000001")], rows: [FULL] }), PERSON_A)?.doc;
  assert.equal(below?.exhausted, false);
  const zeroBudget = personDoc(run({ projects: [project("0")], rows: [] }), PERSON_A)?.doc;
  assert.equal(zeroBudget?.exhausted, true, "a budget of zero allows no spend");
});

// Spend pacing (docs/adr/0035-budget-soft-limit-and-spend-pacing.md): the ceiling lets no more than
// the remaining budget be spent within one pacing window, and half that from the soft limit on.
// 0.0011 CCU per token is the STD worst case (Sonnet 5 output at 1.1x).
const PACING: SpendPacing = { softLimitPercent: 80, windowMinutes: 10 };
const budgetOf = (amount: string) => {
  const p = pilotProject();
  (p.classifications as Record<string, Record<string, unknown>>).STD.personBudget = { amount, currency: "CCU", period: "monthly" };
  return p;
};
const paced = (amount: string, rows: number) =>
  personDoc(run({ projects: [budgetOf(amount)], rows: Array(rows).fill(FULL), pacing: PACING }), PERSON_A)?.doc;

test("below the soft limit the ceiling spreads the remaining budget over one pacing window", () => {
  const doc = paced("1", 5); // 0.75 of 1 CCU: 75%
  assert.equal(doc?.softLimitReached, false);
  assert.equal(doc?.softLimitPercent, 80);
  // 0.25 CCU / 10 minutes / 0.0011 CCU per token = 22.7, rounded down to a power of two: 16.
  assert.equal(doc?.realtimeCeilingTokensPerMinute, 16);
});

// The gateway keys its pace counter by the ceiling (ADR 0035), so a ceiling that moves with every
// reconciler run opens a fresh counter each run; SASET 2026-10-24 admitted 4-6 streams a minute
// against a pace of one. Powers of two keep the key until the remaining budget halves.
test("the paced ceiling is a power of two at or below the exact value, unchanged by small spend changes", () => {
  const a = paced("1", 5)?.realtimeCeilingTokensPerMinute; // 22.7 exact
  const b = paced("0.99", 5)?.realtimeCeilingTokensPerMinute; // 0.24 CCU left: 21.8 exact
  assert.deepEqual([a, b], [16, 16]);
  const larger = paced("1.5", 5)?.realtimeCeilingTokensPerMinute; // 0.75 CCU left: 68.2 exact
  assert.equal(larger, 64);
});

test("at the soft limit, inclusive, the warning is set and the ceiling spreads the rest over two windows", () => {
  const atLimit = paced("0.75", 4); // 0.6 of 0.75 CCU: exactly 80%
  assert.equal(atLimit?.softLimitReached, true);
  // 0.15 CCU / 20 minutes / 0.0011 = 6.8 -> 4.
  assert.equal(atLimit?.realtimeCeilingTokensPerMinute, 4);
  const justBelow = paced("0.7500000000001", 4);
  assert.equal(justBelow?.softLimitReached, false, "one smallest unit below 80% is not a warning");
  const past = paced("1", 6); // 90%
  assert.equal(past?.softLimitReached, true);
  assert.equal(past?.exhausted, false);
  assert.equal(past?.realtimeCeilingTokensPerMinute, 4); // 0.1 / 20 / 0.0011 = 4.5 -> 4
});

test("a paced ceiling never rounds to 0 while budget remains, and is 0 once exhausted", () => {
  const nearlyGone = paced("0.1500001", 1);
  assert.equal(nearlyGone?.exhausted, false);
  assert.equal(nearlyGone?.realtimeCeilingTokensPerMinute, 1, "0 would read as 'no pace' at the gateway");
  const gone = paced("0.15", 1);
  assert.equal(gone?.exhausted, true);
  assert.equal(gone?.softLimitReached, true);
  assert.equal(gone?.realtimeCeilingTokensPerMinute, 0);
});

test("without pacing the document has no soft-limit fields and the ceiling is the whole remaining budget", () => {
  const doc = personDoc(run({ projects: [budgetOf("1")], rows: Array(6).fill(FULL) }), PERSON_A)?.doc;
  assert.equal("softLimitReached" in (doc ?? {}), false);
  assert.equal("softLimitPercent" in (doc ?? {}), false);
  assert.equal(doc?.realtimeCeilingTokensPerMinute, 90); // 0.1 / 0.0011 = 90.9 -> 90
});

test("unpriced usage is reported and makes the state partial, without an amount and without exhausting (C-7)", () => {
  const result = run({ rows: [FULL, { model: "claude-unknown-9" }] });
  const a = personDoc(result, PERSON_A);
  assert.equal(a?.doc.spentCcu, "0.15");
  assert.equal(a?.doc.completeness, "partial");
  assert.equal(a?.doc.exhausted, false);
  assert.deepEqual([a?.tally.priced, a?.tally.unpriced], [1, 1]);
  assert.deepEqual(result.unpricedReasons, { model_not_in_rate_card: 1 });
  assert.equal(result.counts.unpricedRequests, 1);
});

test("a partial row counts at its lower bound and marks the state partial", () => {
  const a = personDoc(run({ rows: [{ ...FULL, cacheRead: null }] }), PERSON_A);
  assert.equal(a?.doc.spentCcu, "0.15");
  assert.equal(a?.doc.completeness, "partial");
  assert.equal(a?.tally.partial, 1);
});

test("a person's spend is per project, across the classifications of the period; other projects are separate", () => {
  const second = pilotProject({ id: "CCOFPILOT02", projectId: "CCOFPILOT02" });
  const result = run({
    projects: [pilotProject(), second],
    entitlements: [entitlementDoc(PERSON_A, [{ projectId: "CCOFPILOT01", classification: "STD" }, { projectId: "CCOFPILOT02", classification: "STD" }])],
    rows: [FULL, { ...FULL, classification: "PRM" }, { ...FULL, projectId: "CCOFPILOT02" }],
  });
  assert.equal(result.persons.find((p) => p.doc.id === `${PERSON_A}:CCOFPILOT01`)?.doc.spentCcu, "0.3");
  assert.equal(result.persons.find((p) => p.doc.id === `${PERSON_A}:CCOFPILOT02`)?.doc.spentCcu, "0.15");
});

test("a group gets every row of its project and classification, members who left included", () => {
  const result = run({ rows: [FULL, { ...FULL, personId: PERSON_C }, { ...FULL, classification: "PRM", personId: PERSON_B }] });
  assert.deepEqual(groupDoc(result, "CCOFPILOT01:STD")?.doc, {
    id: "CCOFPILOT01:STD",
    scopeId: "CCOFPILOT01:STD",
    spentCcu: "0.3",
    budgetCcu: "2000000",
    exhausted: false,
    mode: "strict",
    activeMemberCount: 1,
    computedAt: "2026-10-11T13:00:00.000Z",
    validUntil: "2026-10-11T13:10:00.000Z",
  });
  assert.equal(groupDoc(result, "CCOFPILOT01:PRM")?.doc.spentCcu, "0.15");
  assert.equal(groupDoc(result, "CCOFPILOT01:PRM")?.doc.mode, "notify");
});

test("every registered group gets a document, with no members and no usage too", () => {
  const result = run({ entitlements: [], rows: [] });
  assert.deepEqual(result.groups.map((g) => g.doc.scopeId), ["CCOFPILOT01:CYB", "CCOFPILOT01:PRM", "CCOFPILOT01:STD"]);
  assert.equal(groupDoc(result, "CCOFPILOT01:CYB")?.doc.activeMemberCount, 0);
});

test("a group with no cap (aggregateBudget null) has budgetCcu null and is never exhausted", () => {
  const cyb = groupDoc(run({ rows: [{ ...FULL, classification: "CYB" }] }), "CCOFPILOT01:CYB")?.doc;
  assert.equal(cyb?.budgetCcu, null);
  assert.equal(cyb?.exhausted, false);
});

test("a group is exhausted at spent >= its aggregate budget", () => {
  const p = pilotProject();
  (p.classifications as Record<string, Record<string, unknown>>).STD.aggregateBudget = { amount: "0.3", currency: "CCU", period: "monthly" };
  assert.equal(groupDoc(run({ projects: [p], rows: [FULL] }), "CCOFPILOT01:STD")?.doc.exhausted, false);
  assert.equal(groupDoc(run({ projects: [p], rows: [FULL, FULL] }), "CCOFPILOT01:STD")?.doc.exhausted, true);
});

test("usage the ledger cannot attribute, or of an unregistered scope, is counted and charged to no one", () => {
  const result = run({ rows: [{ ...FULL, attributionKnown: false }, { ...FULL, projectId: "OTHER" }, { model: "", input: null, output: null, usageSource: "no-backend-call" }] });
  assert.deepEqual(
    [result.counts.ledgerRows, result.counts.unattributedRequests, result.counts.unregisteredScopeRequests, result.counts.noUsageRequests],
    [3, 1, 1, 1],
  );
  assert.equal(result.unattributedCcu.toFixed(), "0.15");
  assert.ok(result.persons.every((p) => p.doc.spentCcu === "0"));
});

test("a scope whose allow-list has a model the rate card cannot price gets no person state; its group still does", () => {
  const p = pilotProject();
  const policy = (p.classifications as Record<string, { familyPolicy: { families: { haiku: { models: string[] } } } }>).STD.familyPolicy;
  policy.families.haiku.models = ["claude-haiku-4-5", "explicit-unpriced-deployment"];
  const result = run({ projects: [p] });
  assert.equal(personDoc(result, PERSON_A), undefined);
  assert.ok(personDoc(result, PERSON_B));
  assert.ok(groupDoc(result, "CCOFPILOT01:STD"));
  assert.deepEqual(result.problems, [{ code: "allow_listed_model_unpriced", projectId: "CCOFPILOT01", classification: "STD" }]);
});

test("the same inputs give identical documents in a stable order (idempotent upserts)", () => {
  const rows = [FULL, { ...FULL, classification: "PRM", personId: PERSON_B }, { ...FULL, cacheRead: null }];
  assert.deepEqual(run({ rows }), run({ rows }));
  const ids = run({ rows }).persons.map((p) => p.doc.id);
  assert.deepEqual(ids, [...ids].sort());
});

test("many tiny amounts add up exactly: 1,000 one-token rows are exactly 0.1 CCU", () => {
  // One Haiku 4.5 input token: $1 / 1,000,000 = 0.0001 CCU. Binary floating point drifts here.
  const tiny: LedgerRowSpec = { input: 1, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, inferenceGeo: "global" };
  const result = run({ rows: Array.from({ length: 1000 }, () => tiny) });
  assert.equal(personDoc(result, PERSON_A)?.doc.spentCcu, "0.1");
  let float = 0;
  for (let i = 0; i < 1000; i += 1) float += 0.0001;
  assert.notEqual(String(float), "0.1", "the float sum would not be exact");
});

test("the largest ingestion delay of the read, and the newest ingested row's time and delay, are reported for the run line", () => {
  const result = run({
    rows: [
      { ...FULL, timestamp: "2026-10-11T12:00:00.0000000Z", ingestedAt: "2026-10-11T12:01:00.0000000Z" },
      { ...FULL, timestamp: "2026-10-11T12:00:00.0000000Z", ingestedAt: "2026-10-11T12:04:10.0000000Z" },
      { ...FULL, timestamp: "2026-10-11T12:30:00.0000000Z", ingestedAt: "2026-10-11T12:31:30.0000000Z" },
    ],
  });
  assert.equal(result.maxIngestionDelaySeconds, 250);
  assert.equal(result.newestIngestedAt, "2026-10-11T12:31:30.000Z");
  assert.equal(result.newestRowIngestionDelaySeconds, 90);
  const empty = run({ rows: [] });
  assert.deepEqual([empty.maxIngestionDelaySeconds, empty.newestIngestedAt, empty.newestRowIngestionDelaySeconds], [null, null, null]);
});
