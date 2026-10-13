// Pricing one ledger row for the reconciler (docs/PILOT.md C-7, ADR-0011):
// WP-COST's priceUsage at the row's own time, with the ledger's columns
// mapped onto its input. A row the rate card cannot price is reported as
// unpriced with its reasons and never priced at zero.

import { test } from "node:test";
import assert from "node:assert/strict";
import { LedgerReadError } from "../src/reconciler/ledger.ts";
import type { LedgerRow } from "../src/reconciler/ledger.ts";
import { budgetPeriodAt } from "../src/reconciler/period.ts";
import { classifyRow } from "../src/reconciler/price-rows.ts";
import { PERSON_A, ledgerRow, packagedRateCard, packagedSchedule } from "./helpers/reconciler-fixtures.ts";

const card = packagedRateCard();
const schedule = packagedSchedule(card);
const october = budgetPeriodAt(new Date("2026-10-11T13:00:00Z"));
const classify = (spec: Parameters<typeof ledgerRow>[0]) => classifyRow(ledgerRow(spec) as LedgerRow, october, card, schedule);

test("a fully captured Haiku 4.5 row is priced exactly in CCU: 1,000 input + 100 output tokens = 0.15 CCU", () => {
  // Rate card: Haiku 4.5 input $1, output $5 per million tokens; 100 CCU = USD 1.
  const row = classify({ input: 1000, output: 100, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, inferenceGeo: "global" });
  assert.equal(row.outcome.kind, "priced");
  if (row.outcome.kind === "priced") assert.equal(row.outcome.ccu.toFixed(), "0.15");
  assert.deepEqual(row.attribution, { personKey: PERSON_A, projectId: "CCOFPILOT01", classification: "STD" });
});

test("cache categories that were not captured (a streamed row) price as a partial lower bound", () => {
  const row = classify({ input: 1000, output: 100, cacheWrite5m: null, cacheWrite1h: null, cacheRead: null, inferenceGeo: "global" });
  assert.equal(row.outcome.kind, "partial");
  if (row.outcome.kind === "partial") assert.equal(row.outcome.ccu.toFixed(), "0.15");
});

test("an unknown geography ('unknown' in the ledger) is partial, never guessed as global", () => {
  const row = classify({ inferenceGeo: "unknown" });
  assert.equal(row.outcome.kind, "partial");
});

test("rows the rate card cannot price are unpriced with WP-COST's reasons, never zero", () => {
  const cases: Array<[Parameters<typeof ledgerRow>[0], string]> = [
    [{ model: "claude-unknown-9" }, "model_not_in_rate_card"],
    [{ timestamp: "2026-10-10T23:59:59.9999999Z" }, "no_rate_in_force"],
    [{ input: null }, "token_count_unknown"],
    [{ inferenceGeo: "us" }, "inference_geo_not_priced"],
  ];
  for (const [spec, reason] of cases) {
    const row = classify(spec);
    assert.equal(row.outcome.kind, "unpriced", reason);
    if (row.outcome.kind === "unpriced") assert.deepEqual(row.outcome.reasons, [reason]);
  }
});

test("known zero counts are not 'no usage': with a model they cost exactly zero; without one they are unpriced (council finding)", () => {
  // Only the ledger's no-backend-call marks a request as never reaching a model.
  const withModel = classify({ input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, inferenceGeo: "global" });
  assert.equal(withModel.outcome.kind, "priced");
  if (withModel.outcome.kind === "priced") assert.equal(withModel.outcome.ccu.toFixed(), "0");
  const noModel = classify({ model: "", input: 0, output: 0, cacheWrite5m: null, cacheWrite1h: null, cacheRead: null });
  assert.equal(noModel.outcome.kind, "unpriced");
  if (noModel.outcome.kind === "unpriced") assert.deepEqual(noModel.outcome.reasons, ["ledger_row_invalid"]);
});

test("a row the ledger marks usageSource 'no-backend-call' (a refusal before the backend) is no usage, whatever its counts", () => {
  const row = classifyRow({ ...ledgerRow({ input: null, output: null, model: "" }), usageSource: "no-backend-call" } as LedgerRow, october, card, schedule);
  assert.equal(row.outcome.kind, "no_usage");
  // A failed or aborted backend call keeps its unknown counts: reported, not zero.
  const aborted = classifyRow({ ...ledgerRow({ input: null, output: null }), usageSource: "log" } as LedgerRow, october, card, schedule);
  assert.equal(aborted.outcome.kind, "unpriced");
});

test("zero input and output with a known non-zero cache count is usage, not 'no usage'", () => {
  const row = classify({ input: 0, output: 0, cacheRead: 5000, inferenceGeo: "global" });
  assert.equal(row.outcome.kind, "priced");
});

test("a malformed row is unpriced with reason ledger_row_invalid, not an error that stops everyone", () => {
  for (const spec of [{ input: -1 }, { output: 1.5 }, { cacheRead: Number.NaN }, { timestamp: "yesterday" }, { model: "", input: 10 }] as const) {
    const row = classifyRow({ ...ledgerRow(), ...rename(spec) } as LedgerRow, october, card, schedule);
    assert.equal(row.outcome.kind, "unpriced", JSON.stringify(spec));
    if (row.outcome.kind === "unpriced") assert.deepEqual(row.outcome.reasons, ["ledger_row_invalid"], JSON.stringify(spec));
  }
  const stringCount = classifyRow({ ...ledgerRow(), inputTokens: "14" } as LedgerRow, october, card, schedule);
  assert.equal(stringCount.outcome.kind, "unpriced");
});

test("a row stamped outside the period means the query is wrong: the whole read fails", () => {
  assert.throws(
    () => classify({ timestamp: "2026-11-01T00:00:00.0000000Z" }),
    (e: unknown) => e instanceof LedgerReadError && e.reason === "ledger_row_outside_period",
  );
  assert.throws(() => classify({ timestamp: "2026-09-30T23:59:59.9999999Z" }), LedgerReadError);
});

test("attribution needs the ledger's attributionKnown flag and well-formed ids; the person key is lower case", () => {
  assert.equal(classify({ attributionKnown: false }).attribution, null);
  assert.equal(classify({ personId: "not-a-guid" }).attribution, null);
  assert.equal(classify({ projectId: "" }).attribution, null);
  assert.equal(classify({ classification: "STD'" }).attribution, null);
  assert.equal(classify({ personId: PERSON_A.toUpperCase() }).attribution?.personKey, PERSON_A);
  // A string "true" is not the ledger's boolean.
  assert.equal(classifyRow({ ...ledgerRow(), attributionKnown: "true" } as LedgerRow, october, card, schedule).attribution, null);
});

test("the ingestion delay is measured per row from the request time to the ledger's ingestion time", () => {
  const row = classify({ timestamp: "2026-10-11T12:00:00.0000000Z", ingestedAt: "2026-10-11T12:01:30.5000000Z" });
  assert.equal(row.ingestionDelaySeconds, 90.5);
  assert.equal(classify({ ingestedAt: "not a time" }).ingestionDelaySeconds, null);
});

function rename(spec: Record<string, unknown>): Record<string, unknown> {
  const columns: Record<string, string> = { input: "inputTokens", output: "outputTokens", cacheRead: "cacheReadTokens" };
  return Object.fromEntries(Object.entries(spec).map(([key, value]) => [columns[key] ?? key, value]));
}
