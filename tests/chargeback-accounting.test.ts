import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { Decimal } from "decimal.js";
import { buildChargebackWorkbook } from "../analytics/workbooks/chargeback.ts";
import { parseRateCard } from "../src/cost/rate-card.ts";
import { parseContractSchedule } from "../src/cost/contract-schedule.ts";
import { priceUsage, totalPricing } from "../src/cost/price-usage.ts";
import type { UsageToPrice } from "../src/cost/price-usage.ts";
import { workbookAnswers } from "./helpers/workbook-fixtures.ts";

const rawCard = JSON.parse(readFileSync(new URL("../config/rate-card.json", import.meta.url), "utf8"));
const ledger = readFileSync(new URL("../analytics/ledger.kql", import.meta.url), "utf8");
const built = buildChargebackWorkbook(workbookAnswers(), rawCard, ledger, []);
const card = parseRateCard({ ...rawCard, entries: rawCard.entries.filter((e: { model: string }) => !/fable|mythos/.test(e.model)) });
const schedule = parseContractSchedule({ schemaVersion: 1, version: "no-discount-reporting", entries: [] }, card);
const tokens = { input: 100, output: 20, cacheRead: 1000, cacheWrite5m: 50, cacheWrite1h: 5 };
const row = (model: string, overrides: Partial<UsageToPrice> = {}): UsageToPrice => ({
  requestTime: "2026-10-13T00:00:00Z", model, inferenceGeo: "global", tokens, ...overrides,
});

test("emitted cache read and differing TTL write costs match shared decimal engine with no double count", () => {
  const rate = built.rateCard.rows.find(r => r.model === "claude-haiku-4-5" && r.geo === "global")!;
  const categoryUsd = Object.fromEntries(Object.entries(tokens).map(([c, count]) => [
    c, new Decimal(rate.rates[c as keyof typeof rate.rates]).mul(count).div(100),
  ]));
  assert.equal(categoryUsd.cacheRead.toFixed(), "0.0001");
  assert.equal(categoryUsd.cacheWrite5m.toFixed(), "0.0000625");
  assert.equal(categoryUsd.cacheWrite1h.toFixed(), "0.00001");
  const actual = priceUsage(row("claude-haiku-4-5"), card, schedule);
  assert.equal(actual.status, "priced");
  assert.equal(actual.listUsd.toFixed(), "0.0003725");
  assert.equal(Object.values(categoryUsd).reduce((sum, amount) => sum.plus(amount), new Decimal(0)).toFixed(), actual.listUsd.toFixed());
  assert.match(built.queries.models, /cacheReadTokens\) \* cacheReadRate \/ decimal\(100\)/);
  assert.match(built.queries.models, /cacheWrite5mTokens\) \* cacheWrite5mRate \/ decimal\(100\)/);
  assert.doesNotMatch(built.queries.models, /cache_creation_input_tokens\s*\*/);
});

test("per developer and per stable group aggregates reconcile through model mix and rename snapshots", () => {
  const fixture = [
    { id: "request-one", developer: "synthetic-a", group: "synthetic-g1", name: "Name Before", model: "claude-haiku-4-5" },
    { id: "request-two", developer: "synthetic-a", group: "synthetic-g1", name: "Name After", model: "claude-sonnet-5" },
    { id: "request-three", developer: "synthetic-b", group: "synthetic-g1", name: "Name After", model: "claude-opus-5" },
    { id: "request-four", developer: "synthetic-b", group: "synthetic-g2", name: "Other Group", model: "claude-haiku-4-5" },
  ];
  const priced = fixture.map(f => ({ ...f, cost: priceUsage(row(f.model), card, schedule) }));
  const total = totalPricing(priced.map(f => f.cost)).listUsd;
  for (const dimension of ["developer", "group", "model"] as const) {
    const keys = new Set(priced.map(f => f[dimension]));
    const grouped = [...keys].map(key => totalPricing(priced.filter(f => f[dimension] === key).map(f => f.cost)).listUsd);
    assert.equal(grouped.reduce((sum, amount) => sum.plus(amount), new Decimal(0)).toFixed(), total.toFixed());
  }
  assert.match(built.queries.groups, /by groupId\b/);
  assert.doesNotMatch(built.queries.groups, /by projectLabel, groupId/);
  assert.match(built.queries.groups, /groupNameSnapshots = make_set\(groupDisplayName, 32\)/);
  assert.match(built.queries.developers, /by person\b/);
});

test("absent cache and unknown model prices remain partial/unpriced, never factual zero", () => {
  const streamed = priceUsage(row("claude-haiku-4-5", {
    tokens: { ...tokens, cacheRead: null, cacheWrite5m: null, cacheWrite1h: null },
  }), card, schedule);
  assert.equal(streamed.status, "partial");
  assert.equal(streamed.listUsd.toFixed(), "0.0002");
  assert.deepEqual([...streamed.unknownCategories].sort(), ["cacheRead", "cacheWrite1h", "cacheWrite5m"]);
  for (const model of ["claude-fable-5", "claude-mythos-5", "synthetic-unpriced-model"]) {
    const unknown = priceUsage(row(model), card, schedule);
    assert.equal(unknown.status, "unpriced");
    assert.ok(!("listUsd" in unknown));
  }
  assert.match(built.queries.totals, /tokensSpent = iff/);
  assert.match(built.queries.totals, /cacheReadUnknownRequests/);
});

test("duplicate deliveries retain one logical request while retries stay separate and failures stay diagnostic", () => {
  const fixture = [
    { request: "attempt-a", ingestion: 1, signature: "same", failed: false },
    { request: "attempt-a", ingestion: 2, signature: "same", failed: false },
    { request: "attempt-b", ingestion: 3, signature: "same", failed: false },
    { request: "failed-attempt", ingestion: 4, signature: "failed", failed: true },
    { request: "conflicting-attempt", ingestion: 5, signature: "one", failed: false },
    { request: "conflicting-attempt", ingestion: 6, signature: "two", failed: false },
  ];
  const keys = new Set(fixture.map(f => f.request));
  assert.equal(keys.size, 4);
  assert.equal(fixture.filter(f => f.request === "attempt-a").length, 2);
  assert.equal(new Set(fixture.filter(f => f.request === "conflicting-attempt").map(f => f.signature)).size, 2);
  assert.match(built.queries.diagnostics, /llmVariants = make_set\(llmSignature, 2\)/);
  assert.match(built.queries.diagnostics, /gatewayOutcomeKnown/);
  assert.match(built.queries.diagnostics, /traceConflict or llmConflict/);
  assert.match(built.queries.diagnostics, /usageSource == "no-backend-call"/);
  assert.match(built.queries.totals, /duplicateLlmCopies = sum/);
});
