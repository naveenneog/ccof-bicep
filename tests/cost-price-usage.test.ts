// RED-first tests for pricing one ledger row (ADR-0005 decision 1, ADR-0011
// decisions 3-8): listUsd, contractUsd and predictedCcu from the rate card
// and contract schedule in force at the request's time, with explicit
// priced, partial and unpriced outcomes. Rates come from the real
// config/rate-card.json; discounts are synthetic, because the customer's
// schedule is not known yet (U-18).

import { test } from "node:test";
import assert from "node:assert/strict";
import { priceUsage, totalPricing } from "../src/cost/price-usage.ts";
import type { PricedUsage, PricingOutcome, UsageToPrice } from "../src/cost/price-usage.ts";
import { loadRateCardFile, parseRateCard } from "../src/cost/rate-card.ts";
import type { RateCard } from "../src/cost/rate-card.ts";
import { loadContractScheduleFile, parseContractSchedule } from "../src/cost/contract-schedule.ts";
import type { ContractSchedule } from "../src/cost/contract-schedule.ts";
import { UsageRowError } from "../src/cost/errors.ts";
import type { TokenCategory } from "../src/cost/token-categories.ts";

const card: RateCard = await loadRateCardFile(new URL("../config/rate-card.json", import.meta.url));
const emptySchedule: ContractSchedule = await loadContractScheduleFile(new URL("../config/contract-schedule.json", import.meta.url), card);

function schedule(rateCard: RateCard, ...entries: Array<[string, string, string, string | null]>): ContractSchedule {
  return parseContractSchedule(
    {
      schemaVersion: 1,
      version: "synthetic",
      entries: entries.map(([model, discount, effectiveFrom, effectiveTo]) => ({
        model,
        discount,
        effectiveFrom,
        effectiveTo,
        offerReference: "synthetic-offer",
        recordedBy: "test",
        recordedAt: "2026-10-11T00:00:00Z",
      })),
    },
    rateCard,
  );
}

function usage(model: string, tokens: Partial<Record<TokenCategory, number | null>>, overrides: Partial<UsageToPrice> = {}): UsageToPrice {
  return {
    requestTime: "2026-10-12T09:30:00Z",
    model,
    inferenceGeo: "global",
    tokens: { input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0, ...tokens },
    ...overrides,
  };
}

function priced(outcome: PricingOutcome): PricedUsage {
  assert.notEqual(outcome.status, "unpriced", `expected a price, got ${JSON.stringify(outcome)}`);
  return outcome as PricedUsage;
}

const WORKED_EXAMPLE = { input: 1200, cacheRead: 48000, cacheWrite5m: 3000, output: 900 };

// ---- docs/MARKETPLACE-COST.md §3 ----------------------------------------------------------

test("the worked example prices at list 0.0285 USD, and at a 10% discount 0.02565 USD = 2.565 CCU", () => {
  const discounted = schedule(card, ["claude-sonnet-5", "0.10", "2026-10-01T00:00:00Z", null]);
  const outcome = priced(priceUsage(usage("claude-sonnet-5", WORKED_EXAMPLE), card, discounted));
  assert.equal(outcome.status, "priced");
  assert.equal(outcome.listUsd.toString(), "0.0285");
  assert.equal(outcome.contractUsd.toString(), "0.02565");
  assert.equal(outcome.predictedCcu.toString(), "2.565");
  assert.equal(outcome.pricingBasis, "contract");
  assert.equal(outcome.discount.toString(), "0.1");
  assert.equal(outcome.model, "claude-sonnet-5");
  assert.equal(outcome.rateCardVersion, card.version);
});

test("with the shipped, empty contract schedule the same request is list price, labelled as such", () => {
  const outcome = priced(priceUsage(usage("claude-sonnet-5", WORKED_EXAMPLE), card, emptySchedule));
  assert.equal(outcome.pricingBasis, "list");
  assert.ok(outcome.discount.isZero());
  assert.equal(outcome.contractUsd.toString(), "0.0285");
  assert.equal(outcome.predictedCcu.toString(), "2.85");
});

test("without cache categories the worked example is partial at the prompt-and-completion figure, 0.0114 USD", () => {
  const streamed = usage("claude-sonnet-5", { ...WORKED_EXAMPLE, cacheRead: null, cacheWrite5m: null, cacheWrite1h: null });
  const outcome = priced(priceUsage(streamed, card, emptySchedule));
  assert.equal(outcome.status, "partial");
  assert.deepEqual(outcome.unknownCategories, ["cacheWrite5m", "cacheWrite1h", "cacheRead"]);
  assert.equal(outcome.listUsd.toString(), "0.0114");
  assert.equal(outcome.inferenceGeoKnown, true);
});

// ---- cache reads, per model ------------------------------------------------------------------

test("a million cache-read tokens cost 0.05x a million input tokens on Opus 5.5 and Sonnet 5.5, 0.025x on Fable 5.1 and Mythos 5.1", () => {
  const expected: Array<[string, string]> = [
    ["claude-opus-5-5", "0.05"],
    ["claude-sonnet-5-5", "0.05"],
    ["claude-fable-5-1", "0.025"],
    ["claude-mythos-5-1", "0.025"],
    ["claude-opus-5", "0.1"],
    ["claude-haiku-4-5", "0.1"],
  ];
  for (const [model, ratio] of expected) {
    const read = priced(priceUsage(usage(model, { cacheRead: 1_000_000 }), card, emptySchedule)).listUsd;
    const input = priced(priceUsage(usage(model, { input: 1_000_000 }), card, emptySchedule)).listUsd;
    assert.equal(read.dividedBy(input).toString(), ratio, model);
  }
  assert.equal(priced(priceUsage(usage("claude-opus-5-5", { cacheRead: 1_000_000 }), card, emptySchedule)).listUsd.toString(), "0.2");
});

// ---- Haiku 5.5 prompt tiers ------------------------------------------------------------------

test("Haiku 5.5: a prompt of exactly 100,000 tokens, cache reads included, takes the lower tier", () => {
  const outcome = priced(priceUsage(usage("claude-haiku-5-5", { input: 40_000, cacheRead: 60_000 }), card, emptySchedule));
  assert.equal(outcome.promptTierIndex, 0);
  assert.equal(outcome.listUsd.toString(), "0.0046");
});

test("Haiku 5.5: one token over 100,000 takes the upper tier, even when the prompt is almost all cache hits", () => {
  const outcome = priced(priceUsage(usage("claude-haiku-5-5", { input: 1, cacheRead: 100_000 }), card, emptySchedule));
  assert.equal(outcome.promptTierIndex, 1);
  assert.equal(outcome.listUsd.toString(), "0.0050005");
});

test("Haiku 5.5: both cache-write categories count toward the threshold, output does not", () => {
  const writes = priced(priceUsage(usage("claude-haiku-5-5", { input: 50_000, cacheWrite5m: 30_000, cacheWrite1h: 20_001 }), card, emptySchedule));
  assert.equal(writes.promptTierIndex, 1);
  const output = priced(priceUsage(usage("claude-haiku-5-5", { input: 100_000, output: 50_000 }), card, emptySchedule));
  assert.equal(output.promptTierIndex, 0);
  assert.equal(output.listUsd.toString(), "0.035");
});

test("Haiku 5.5 with unknown cache categories: the cheapest tier consistent with the known tokens, flagged", () => {
  const uncertain = priced(
    priceUsage(usage("claude-haiku-5-5", { input: 50_000, output: 1_000, cacheRead: null, cacheWrite5m: null, cacheWrite1h: null }), card, emptySchedule),
  );
  assert.equal(uncertain.status, "partial");
  assert.equal(uncertain.promptTierKnown, false);
  assert.equal(uncertain.promptTierIndex, 0);
  assert.equal(uncertain.listUsd.toString(), "0.0055");

  const certain = priced(
    priceUsage(usage("claude-haiku-5-5", { input: 150_000, cacheRead: null, cacheWrite5m: null, cacheWrite1h: null }), card, emptySchedule),
  );
  assert.equal(certain.status, "partial");
  assert.equal(certain.promptTierKnown, true);
  assert.equal(certain.promptTierIndex, 1);
  assert.equal(certain.listUsd.toString(), "0.075");
});

// ---- inference geography ---------------------------------------------------------------------

test("inference_geo 'us' is 1.1x the global price, on every category and on Haiku 5.5's upper tier", () => {
  const global = priced(priceUsage(usage("claude-sonnet-5", WORKED_EXAMPLE), card, emptySchedule));
  const us = priced(priceUsage(usage("claude-sonnet-5", WORKED_EXAMPLE, { inferenceGeo: "us" }), card, emptySchedule));
  assert.equal(us.listUsd.toString(), "0.03135");
  assert.ok(us.listUsd.equals(global.listUsd.times("1.1")));
  assert.equal(us.inferenceGeoMultiplier.toString(), "1.1");

  const haikuUpper = priced(priceUsage(usage("claude-haiku-5-5", { input: 1, cacheRead: 100_000 }, { inferenceGeo: "us" }), card, emptySchedule));
  assert.equal(haikuUpper.listUsd.toString(), "0.00550055");
});

test("a geography the entry does not price is refused: 'us' on Haiku 4.5 (U-22), or an unlisted value", () => {
  for (const [model, geo] of [["claude-haiku-4-5", "us"], ["claude-sonnet-5", "eu"], ["claude-sonnet-5", "unknown"]]) {
    const outcome = priceUsage(usage(model, WORKED_EXAMPLE, { inferenceGeo: geo }), card, emptySchedule);
    assert.equal(outcome.status, "unpriced", `${model} ${geo}`);
    assert.ok(outcome.status === "unpriced" && outcome.reasons.includes("inference_geo_not_priced"));
  }
});

test("an unknown geography is partial at the entry's smallest multiplier, flagged", () => {
  const outcome = priced(priceUsage(usage("claude-sonnet-5", WORKED_EXAMPLE, { inferenceGeo: null }), card, emptySchedule));
  assert.equal(outcome.status, "partial");
  assert.equal(outcome.inferenceGeoKnown, false);
  assert.deepEqual(outcome.unknownCategories, []);
  assert.equal(outcome.inferenceGeoMultiplier.toString(), "1");
  assert.equal(outcome.listUsd.toString(), "0.0285");
});

// ---- time ------------------------------------------------------------------------------------

test("a rate change and a discount change mid-period: each row is priced by its own request time", () => {
  const raw = {
    schemaVersion: 1,
    version: "synthetic-change",
    rateUnit: { currency: "USD", perTokens: 1000000, source: { url: "https://example.test/pricing", retrieved: "2026-10-11" } },
    entries: [
      { model: "claude-sonnet-5", effectiveFrom: "2026-10-01T00:00:00Z", effectiveTo: "2026-10-15T00:00:00Z" },
      { model: "claude-sonnet-5", effectiveFrom: "2026-10-15T00:00:00Z", effectiveTo: null },
    ],
  };
  for (const [index, input] of [[0, "2"], [1, "3"]] as const) {
    Object.assign(raw.entries[index], {
      source: { url: "https://example.test/pricing", retrieved: "2026-10-11" },
      inferenceGeoMultipliers: { global: "1" },
      promptTiers: [{ rates: { input, cacheWrite5m: "5", cacheWrite1h: "8", cacheRead: "0.5", output: "20" } }],
    });
  }
  const changing = parseRateCard(raw);
  const discounts = schedule(changing, ["claude-sonnet-5", "0.10", "2026-10-01T00:00:00Z", "2026-10-15T00:00:00Z"], ["claude-sonnet-5", "0.20", "2026-10-15T00:00:00Z", null]);
  const at = (requestTime: string) => priced(priceUsage(usage("claude-sonnet-5", { input: 1_000_000 }, { requestTime }), changing, discounts));

  const before = at("2026-10-14T23:59:59.9999999Z");
  const boundary = at("2026-10-15T00:00:00Z");
  const after = at("2026-10-15T00:00:00.0000001Z");
  assert.equal(before.listUsd.toString(), "2");
  assert.equal(before.contractUsd.toString(), "1.8");
  assert.equal(boundary.listUsd.toString(), "3");
  assert.equal(boundary.contractUsd.toString(), "2.4");
  assert.equal(after.rateEntryEffectiveFrom, "2026-10-15T00:00:00Z");
  assert.equal(totalPricing([before, boundary]).contractUsd.toString(), "4.2");
});

test("a request before the first rate-card entry is unpriced, not priced at a later rate (U-new-COST-2)", () => {
  const outcome = priceUsage(usage("claude-sonnet-5", WORKED_EXAMPLE, { requestTime: "2026-10-10T23:59:59Z" }), card, emptySchedule);
  assert.deepEqual(outcome.status === "unpriced" && outcome.reasons, ["no_rate_in_force"]);
});

// ---- unpriced outcomes: never $0 -------------------------------------------------------------

test("an unknown model is unpriced and carries no amount at all", () => {
  const outcome = priceUsage(usage("claude-unknown-9", WORKED_EXAMPLE), card, emptySchedule);
  assert.equal(outcome.status, "unpriced");
  assert.ok(outcome.status === "unpriced" && outcome.reasons.includes("model_not_in_rate_card"));
  assert.equal("listUsd" in outcome, false);
  assert.equal("predictedCcu" in outcome, false);
  assert.match(outcome.status === "unpriced" ? outcome.detail : "", /claude-unknown-9/);
});

test("a reported feature leaves the row partial at its token cost, naming the feature the card does not price (U-22)", () => {
  const search = priced(priceUsage(usage("claude-sonnet-5", WORKED_EXAMPLE, { features: { webSearchRequests: 2 } }), card, emptySchedule));
  assert.equal(search.status, "partial");
  assert.deepEqual(search.unpricedFeatures, ["webSearchRequests"]);
  assert.deepEqual(search.unknownCategories, []);
  assert.equal(search.listUsd.toString(), "0.0285");
  const unused = priced(priceUsage(usage("claude-sonnet-5", WORKED_EXAMPLE, { features: { webSearchRequests: 0 } }), card, emptySchedule));
  assert.equal(unused.status, "priced");
  assert.deepEqual(unused.unpricedFeatures, []);
});

test("a requester cannot zero their own cost by using a feature: the known token cost still counts in totals", () => {
  const plain = priceUsage(usage("claude-opus-5-5", { input: 200_000, output: 64_000 }), card, emptySchedule);
  const withSearch = priceUsage(usage("claude-opus-5-5", { input: 200_000, output: 64_000 }, { features: { webSearchRequests: 1 } }), card, emptySchedule);
  assert.equal(totalPricing([plain]).contractUsd.toString(), "2.08");
  assert.equal(totalPricing([withSearch]).contractUsd.toString(), "2.08");
  assert.equal(totalPricing([withSearch]).partial, 1);
});

test("unknown input or output tokens make a row unpriced; only cache categories may be partial", () => {
  for (const missing of ["input", "output"] as const) {
    const outcome = priceUsage(usage("claude-sonnet-5", { ...WORKED_EXAMPLE, [missing]: null }), card, emptySchedule);
    assert.ok(outcome.status === "unpriced" && outcome.reasons.includes("token_count_unknown"), missing);
  }
});

test("every reason that applies is reported together, and an unpriced row still names its unpriced features", () => {
  const outcome = priceUsage(
    usage("claude-unknown-9", { input: null }, { features: { codeExecutionRequests: 1 } }),
    card,
    emptySchedule,
  );
  assert.ok(outcome.status === "unpriced");
  assert.deepEqual([...outcome.reasons].sort(), ["model_not_in_rate_card", "token_count_unknown"]);
  assert.deepEqual(outcome.unpricedFeatures, ["codeExecutionRequests"]);
});

test("names echoed from a row are JSON-escaped, so a crafted name cannot forge a line in a log", () => {
  const outcome = priceUsage(usage("evil\nlevel=info msg=forged", WORKED_EXAMPLE), card, emptySchedule);
  assert.ok(outcome.status === "unpriced");
  assert.ok(!outcome.detail.includes("\n"), outcome.detail);
  assert.match(outcome.detail, /"evil\\nlevel=info msg=forged"/);

  const geo = priceUsage(usage("claude-sonnet-5", WORKED_EXAMPLE, { inferenceGeo: "x\r\ny" }), card, emptySchedule);
  assert.ok(geo.status === "unpriced" && !/[\r\n]/.test(geo.detail), geo.status === "unpriced" ? geo.detail : "");

  assert.throws(
    () => priceUsage(usage("claude-sonnet-5", {}, { features: { "a\nb": -1 } }), card, emptySchedule),
    (error: unknown) => error instanceof UsageRowError && error.field === 'features["a\\nb"]' && !error.message.includes("\n"),
  );
});

// ---- model names -----------------------------------------------------------------------------

test("the dated model name measured on the wire prices as Haiku 4.5", () => {
  const outcome = priced(priceUsage(usage("claude-haiku-4-5-20251001", { input: 1_000_000 }), card, emptySchedule));
  assert.equal(outcome.model, "claude-haiku-4-5");
  assert.equal(outcome.listUsd.toString(), "1");
});

// ---- exactness -------------------------------------------------------------------------------

test("ten thousand one-token rows sum exactly, where binary floating point drifts", () => {
  const discounted = schedule(card, ["claude-haiku-5-5", "0.10", "2026-10-01T00:00:00Z", null]);
  const row = usage("claude-haiku-5-5", { cacheRead: 1 }, { inferenceGeo: "us" });
  const outcomes = Array.from({ length: 10_000 }, () => priceUsage(row, card, discounted));
  const totals = totalPricing(outcomes);
  assert.equal(totals.priced, 10_000);
  assert.equal(totals.contractUsd.toString(), "0.000099");
  assert.equal(totals.predictedCcu.toString(), "0.0099");
  assert.equal(totals.listUsd.toString(), "0.00011");

  let float = 0;
  for (let i = 0; i < 10_000; i += 1) float += (0.01 / 1e6) * 1.1 * 0.9;
  assert.notEqual(float, 0.000099, "the comparison is meaningful only if floats drift");
});

test("a large total plus a sub-nanodollar amount keeps all 24 significant digits", () => {
  // decimal.js defaults to 20 significant digits, which would round this sum.
  const discounted = schedule(card, ["claude-haiku-5-5", "0.123456", "2026-10-01T00:00:00Z", null]);
  const large = priceUsage(usage("claude-opus-5", { output: 4_000_000_000_000 }), card, discounted);
  const tiny = priceUsage(usage("claude-haiku-5-5", { cacheRead: 1 }, { inferenceGeo: "us" }), card, discounted);
  const totals = totalPricing([large, tiny]);
  assert.equal(totals.contractUsd.toString(), "100000000.000000009641984");
  assert.equal(totals.predictedCcu.toString(), "10000000000.0000009641984");
});

test("totals count priced, partial and unpriced rows, and add money only from rows that have a price", () => {
  const totals = totalPricing([
    priceUsage(usage("claude-sonnet-5", WORKED_EXAMPLE), card, emptySchedule),
    priceUsage(usage("claude-sonnet-5", { ...WORKED_EXAMPLE, cacheRead: null }), card, emptySchedule),
    priceUsage(usage("claude-unknown-9", WORKED_EXAMPLE), card, emptySchedule),
  ]);
  assert.deepEqual([totals.rows, totals.priced, totals.partial, totals.unpriced], [3, 1, 1, 1]);
  assert.equal(totals.listUsd.toString(), "0.0474");
});

// ---- malformed rows --------------------------------------------------------------------------

test("a malformed row is refused with a UsageRowError naming the field", () => {
  const cases: Array<[UsageToPrice, string]> = [
    [usage("claude-sonnet-5", { input: -1 }), "tokens.input"],
    [usage("claude-sonnet-5", { output: 1.5 }), "tokens.output"],
    [{ ...usage("claude-sonnet-5", {}), tokens: { input: 1, output: 1, cacheRead: 0, cacheWrite5m: 0 } as never }, "tokens.cacheWrite1h"],
    [{ ...usage("claude-sonnet-5", {}), tokens: { input: 1, output: 1, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheWrite: 0 } as never }, "tokens.cacheWrite"],
    [usage("claude-sonnet-5", {}, { requestTime: "2026-10-12T09:30:00" }), "requestTime"],
    [usage("claude-sonnet-5", {}, { requestTime: "2026-10-12T09:30:00+05:30" }), "requestTime"],
    [usage("claude-sonnet-5", {}, { requestTime: "2026-02-30T00:00:00Z" }), "requestTime"],
    [usage("claude-sonnet-5", {}, { requestTime: new Date(Number.NaN) }), "requestTime"],
    [usage("claude-sonnet-5", {}, { inferenceGeo: undefined as never }), "inferenceGeo"],
    [usage("", {}), "model"],
    [usage("claude-sonnet-5", {}, { features: { webSearchRequests: -1 } }), "features.webSearchRequests"],
  ];
  for (const [row, field] of cases) {
    assert.throws(
      () => priceUsage(row, card, emptySchedule),
      (error: unknown) => error instanceof UsageRowError && error.field === field && error.message.includes(field),
      field,
    );
  }
});
