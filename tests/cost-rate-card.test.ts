// RED-first tests for the versioned rate card (ADR-0011): loading and
// validating config/rate-card.json, and selecting the entry in force at a
// request's timestamp. Pure: no Azure, no network.
//
// The model names and rates below are expected values, transcribed
// independently from Anthropic's pricing page (retrieved 2026-10-11) so that
// a typo in the configuration fails a test. Production code holds none of
// them (owner rule, 2026-10-11: no model lists in code).

import { test } from "node:test";
import assert from "node:assert/strict";
import { Decimal } from "decimal.js";
import {
  findRateEntry,
  loadRateCardFile,
  parseRateCard,
  parseRateCardJson,
  promptTierIndex,
} from "../src/cost/rate-card.ts";
import type { RateCard, RateCardEntry } from "../src/cost/rate-card.ts";
import { CostConfigError, RateCardError } from "../src/cost/errors.ts";
import { TOKEN_CATEGORIES } from "../src/cost/token-categories.ts";

const RATE_CARD_PATH = new URL("../config/rate-card.json", import.meta.url);
const READ_ON = new Date("2026-10-11T12:00:00Z");

// Anthropic pricing page, "Model pricing" table, retrieved 2026-10-11:
// model, prompt tier index, input, 5m cache write, 1h cache write, cache hit, output (USD per MTok).
const PUBLISHED_2026_10_11: ReadonlyArray<readonly [string, number, string, string, string, string, string]> = [
  ["claude-fable-5-1", 0, "10", "12.50", "20", "0.25", "50"],
  ["claude-mythos-5-1", 0, "10", "12.50", "20", "0.25", "50"],
  ["claude-fable-5", 0, "10", "12.50", "20", "1", "50"],
  ["claude-mythos-5", 0, "10", "12.50", "20", "1", "50"],
  ["claude-opus-5-5", 0, "4", "5", "8", "0.20", "20"],
  ["claude-opus-5", 0, "5", "6.25", "10", "0.50", "25"],
  ["claude-sonnet-5-5", 0, "2", "2.50", "4", "0.10", "10"],
  ["claude-sonnet-5", 0, "2", "2.50", "4", "0.20", "10"],
  ["claude-haiku-5-5", 0, "0.10", "0.125", "0.20", "0.01", "0.50"],
  ["claude-haiku-5-5", 1, "0.50", "0.625", "1", "0.05", "2.50"],
  ["claude-haiku-4-5", 0, "1", "1.25", "2", "0.10", "5"],
];

// A minimal valid card, synthetic, so each validation test breaks exactly one field.
function syntheticCard(): any {
  return {
    schemaVersion: 1,
    version: "test-1",
    description: "Synthetic rate card for unit tests.",
    notes: ["Synthetic values."],
    rateUnit: {
      currency: "USD",
      perTokens: 1000000,
      source: { url: "https://example.test/pricing", retrieved: "2026-10-11" },
    },
    entries: [syntheticEntry("test-model-a", "2026-10-01T00:00:00Z", null)],
  };
}

function syntheticEntry(model: string, effectiveFrom: string, effectiveTo: string | null): any {
  return {
    model,
    displayName: "Synthetic model",
    effectiveFrom,
    effectiveTo,
    source: { url: "https://example.test/pricing", retrieved: "2026-10-11" },
    inferenceGeoMultipliers: { global: "1", us: "1.1" },
    promptTiers: [
      { rates: { input: "2", cacheWrite5m: "2.50", cacheWrite1h: "4", cacheRead: "0.20", output: "10" } },
    ],
  };
}

function syntheticTieredEntry(): any {
  const entry = syntheticEntry("test-model-tiered", "2026-10-01T00:00:00Z", null);
  entry.promptTokensCountedCategories = ["input", "cacheWrite5m", "cacheWrite1h", "cacheRead"];
  entry.promptTiers = [
    { promptTokensUpTo: 100000, rates: { input: "0.10", cacheWrite5m: "0.125", cacheWrite1h: "0.20", cacheRead: "0.01", output: "0.50" } },
    { promptTokensOver: 100000, rates: { input: "0.50", cacheWrite5m: "0.625", cacheWrite1h: "1", cacheRead: "0.05", output: "2.50" } },
  ];
  return entry;
}

function expectRateCardError(fn: () => unknown, code: string, field: string): void {
  let caught: unknown;
  try {
    fn();
  } catch (error) {
    caught = error;
  }
  assert.ok(caught instanceof RateCardError, `expected a RateCardError, got: ${String(caught)}`);
  assert.ok(caught instanceof CostConfigError);
  assert.equal(caught.name, "RateCardError");
  assert.equal(caught.code, code, caught.message);
  assert.equal(caught.field, field, caught.message);
  assert.ok(caught.message.includes(field), `message should name the field: ${caught.message}`);
}

function entryInForce(card: RateCard, model: string): RateCardEntry {
  const lookup = findRateEntry(card, model, READ_ON);
  assert.ok(lookup.found, `no entry in force for ${model}`);
  return lookup.entry;
}

// ---- the real configuration -------------------------------------------------------------

test("config/rate-card.json loads, and every entry cites an https source and its retrieval date", async () => {
  const card = await loadRateCardFile(RATE_CARD_PATH);
  assert.ok(card.version.length > 0);
  assert.equal(card.currency, "USD");
  assert.ok(card.tokensPerRate.equals(1_000_000));
  assert.ok(card.entries.length > 0);
  for (const entry of card.entries) {
    assert.match(entry.source.url, /^https:\/\/platform\.claude\.com\/docs\/en\/about-claude\/pricing/);
    assert.match(entry.source.retrieved, /^\d{4}-\d{2}-\d{2}$/);
  }
});

test("config/rate-card.json holds exactly the published 2026-10-11 rates, all five categories explicit", async () => {
  const card = await loadRateCardFile(RATE_CARD_PATH);
  const modelsInForce = new Set(card.entries.filter((e) => findRateEntry(card, e.model, READ_ON).found).map((e) => e.model));
  assert.deepEqual([...modelsInForce].sort(), [...new Set(PUBLISHED_2026_10_11.map((row) => row[0]))].sort());

  for (const [model, tier, input, cacheWrite5m, cacheWrite1h, cacheRead, output] of PUBLISHED_2026_10_11) {
    const rates = entryInForce(card, model).promptTiers[tier].rates;
    const expected = { input, cacheWrite5m, cacheWrite1h, cacheRead, output };
    for (const category of TOKEN_CATEGORIES) {
      assert.ok(rates[category].equals(expected[category]), `${model} tier ${tier} ${category}: ${rates[category]} != ${expected[category]}`);
    }
  }
});

test("cache hits cost 0.05x input on Opus 5.5 and Sonnet 5.5, 0.025x on Fable 5.1 and Mythos 5.1, 0.1x on every other model", async () => {
  const card = await loadRateCardFile(RATE_CARD_PATH);
  const special: Record<string, string> = {
    "claude-opus-5-5": "0.05",
    "claude-sonnet-5-5": "0.05",
    "claude-fable-5-1": "0.025",
    "claude-mythos-5-1": "0.025",
  };
  for (const entry of card.entries) {
    for (const tier of entry.promptTiers) {
      const ratio = tier.rates.cacheRead.dividedBy(tier.rates.input);
      assert.ok(ratio.equals(special[entry.model] ?? "0.1"), `${entry.model}: cache read is ${ratio}x input`);
    }
  }
});

test("cache writes cost 1.25x input for 5 minutes and 2x input for 1 hour on every entry, as published", async () => {
  const card = await loadRateCardFile(RATE_CARD_PATH);
  for (const entry of card.entries) {
    for (const tier of entry.promptTiers) {
      assert.ok(tier.rates.cacheWrite5m.dividedBy(tier.rates.input).equals("1.25"), `${entry.model} 5m write`);
      assert.ok(tier.rates.cacheWrite1h.dividedBy(tier.rates.input).equals("2"), `${entry.model} 1h write`);
    }
  }
});

test("Haiku 5.5's two prompt tiers split at 100,000 tokens counted over input, cache writes and cache reads", async () => {
  const card = await loadRateCardFile(RATE_CARD_PATH);
  const haiku = entryInForce(card, "claude-haiku-5-5");
  assert.deepEqual(haiku.promptTokensCountedCategories, ["input", "cacheWrite5m", "cacheWrite1h", "cacheRead"]);
  assert.equal(haiku.promptTiers.length, 2);
  assert.equal(haiku.promptTiers[0].promptTokensOver, null);
  assert.equal(haiku.promptTiers[0].promptTokensUpTo, 100000);
  assert.equal(haiku.promptTiers[1].promptTokensOver, 100000);
  assert.equal(haiku.promptTiers[1].promptTokensUpTo, null);
  assert.equal(promptTierIndex(haiku, 100000), 0);
  assert.equal(promptTierIndex(haiku, 100001), 1);
});

test("inference_geo 'us' is 1.1x on every 4.6-or-later model; Haiku 4.5 prices 'global' only (U-22)", async () => {
  const card = await loadRateCardFile(RATE_CARD_PATH);
  for (const entry of card.entries) {
    assert.ok(entry.inferenceGeoMultipliers.get("global")?.equals(1), `${entry.model} global`);
    if (entry.model === "claude-haiku-4-5") {
      assert.deepEqual([...entry.inferenceGeoMultipliers.keys()], ["global"]);
    } else {
      assert.ok(entry.inferenceGeoMultipliers.get("us")?.equals("1.1"), `${entry.model} us`);
    }
  }
});

// ---- selection by time and by model name --------------------------------------------------

test("findRateEntry selects the entry in force at the timestamp, with half-open intervals", () => {
  const raw = syntheticCard();
  raw.entries = [
    syntheticEntry("test-model-a", "2026-10-01T00:00:00Z", "2026-10-15T00:00:00Z"),
    syntheticEntry("test-model-a", "2026-10-15T00:00:00Z", null),
  ];
  raw.entries[1].promptTiers[0].rates.input = "3";
  const card = parseRateCard(raw);

  const before = findRateEntry(card, "test-model-a", new Date("2026-10-14T23:59:59.999Z"));
  const atBoundary = findRateEntry(card, "test-model-a", new Date("2026-10-15T00:00:00Z"));
  assert.ok(before.found && before.entry.promptTiers[0].rates.input.equals(2));
  assert.ok(atBoundary.found && atBoundary.entry.promptTiers[0].rates.input.equals(3));
  assert.deepEqual(findRateEntry(card, "test-model-a", new Date("2026-09-30T23:59:59Z")), { found: false, reason: "no_rate_in_force" });
  assert.deepEqual(findRateEntry(card, "test-model-b", new Date("2026-10-20T00:00:00Z")), { found: false, reason: "model_not_in_rate_card" });
});

test("a dated deployment name prices as its family, matching the reference repository's measured wire name", async () => {
  const card = await loadRateCardFile(RATE_CARD_PATH);
  const dated = findRateEntry(card, "claude-haiku-4-5-20251001", READ_ON);
  assert.ok(dated.found && dated.entry.model === "claude-haiku-4-5");
  const googleForm = findRateEntry(card, "claude-haiku-4-5@20251001", READ_ON);
  assert.ok(googleForm.found && googleForm.entry.model === "claude-haiku-4-5");
  const upperCase = findRateEntry(card, "Claude-Sonnet-5", READ_ON);
  assert.ok(upperCase.found && upperCase.entry.model === "claude-sonnet-5");

  // The reference price book spells the family "claude-haiku-4.5" (accel/config/price-book.json).
  const raw = syntheticCard();
  raw.entries = [syntheticEntry("claude-haiku-4.5", "2026-10-01T00:00:00Z", null)];
  const referenceSpelling = findRateEntry(parseRateCard(raw), "claude-haiku-4-5-20251001", READ_ON);
  assert.ok(referenceSpelling.found);
});

test("only a trailing calendar date is stripped: other digit runs do not match a family", async () => {
  const card = await loadRateCardFile(RATE_CARD_PATH);
  assert.equal(findRateEntry(card, "claude-sonnet-5-12345678", READ_ON).found, false);
  assert.equal(findRateEntry(card, "claude-sonnet-5-20261399", READ_ON).found, false);
  assert.equal(findRateEntry(card, "", READ_ON).found, false);
});

// ---- validation: every refusal names the field ---------------------------------------------

test("overlapping intervals for one model are refused, naming the later entry's effectiveFrom", () => {
  const raw = syntheticCard();
  raw.entries = [
    syntheticEntry("test-model-a", "2026-10-01T00:00:00Z", "2026-10-20T00:00:00Z"),
    syntheticEntry("test-model-a", "2026-10-15T00:00:00Z", null),
  ];
  expectRateCardError(() => parseRateCard(raw), "overlapping_interval", "entries[1].effectiveFrom");
});

test("an open-ended entry followed by a later entry for the same model is an overlap", () => {
  const raw = syntheticCard();
  raw.entries = [
    syntheticEntry("test-model-a", "2026-10-15T00:00:00Z", null),
    syntheticEntry("test-model-a", "2026-10-01T00:00:00Z", null),
  ];
  expectRateCardError(() => parseRateCard(raw), "overlapping_interval", "entries[0].effectiveFrom");
});

test("adjacent intervals are accepted, and entries for different models never overlap each other", () => {
  const raw = syntheticCard();
  raw.entries = [
    syntheticEntry("test-model-a", "2026-10-01T00:00:00Z", "2026-10-15T00:00:00Z"),
    syntheticEntry("test-model-a", "2026-10-15T00:00:00Z", null),
    syntheticEntry("test-model-b", "2026-10-01T00:00:00Z", null),
  ];
  assert.equal(parseRateCard(raw).entries.length, 3);
});

test("a missing category is refused, naming the rate field", () => {
  const raw = syntheticCard();
  delete raw.entries[0].promptTiers[0].rates.cacheWrite1h;
  expectRateCardError(() => parseRateCard(raw), "missing_category", "entries[0].promptTiers[0].rates.cacheWrite1h");
});

test("the undivided legacy cacheWrite category is an unknown field, not a sixth rate", () => {
  const raw = syntheticCard();
  raw.entries[0].promptTiers[0].rates.cacheWrite = "2.50";
  expectRateCardError(() => parseRateCard(raw), "unknown_field", "entries[0].promptTiers[0].rates.cacheWrite");
});

test("zero and negative rates are refused; a rate must be a positive decimal string", () => {
  for (const zero of ["0", "0.000"]) {
    const raw = syntheticCard();
    raw.entries[0].promptTiers[0].rates.cacheRead = zero;
    expectRateCardError(() => parseRateCard(raw), "non_positive_rate", "entries[0].promptTiers[0].rates.cacheRead");
  }
  for (const malformed of ["-1", "1e-7", " 2", "2.", ".5", "01", 2, null]) {
    const raw = syntheticCard();
    raw.entries[0].promptTiers[0].rates.output = malformed;
    expectRateCardError(() => parseRateCard(raw), "invalid_value", "entries[0].promptTiers[0].rates.output");
  }
});

test("unknown fields are refused at every level, naming the field", () => {
  const cases: Array<[(raw: ReturnType<typeof syntheticCard>) => void, string]> = [
    [(raw) => { raw.discount = "0.1"; }, "discount"],
    [(raw) => { raw.rateUnit.perMillion = true; }, "rateUnit.perMillion"],
    [(raw) => { raw.rateUnit.source.author = "x"; }, "rateUnit.source.author"],
    [(raw) => { raw.entries[0].multiplier = "1.1"; }, "entries[0].multiplier"],
    [(raw) => { raw.entries[0].source.page = "x"; }, "entries[0].source.page"],
    [(raw) => { raw.entries[0].promptTiers[0].name = "all"; }, "entries[0].promptTiers[0].name"],
  ];
  for (const [mutate, field] of cases) {
    const raw = syntheticCard();
    mutate(raw);
    expectRateCardError(() => parseRateCard(raw), "unknown_field", field);
  }
});

test("missing required fields are refused, naming the field", () => {
  const cases: Array<[(raw: ReturnType<typeof syntheticCard>) => void, string]> = [
    [(raw) => { delete raw.version; }, "version"],
    [(raw) => { delete raw.rateUnit.perTokens; }, "rateUnit.perTokens"],
    [(raw) => { delete raw.entries[0].source; }, "entries[0].source"],
    [(raw) => { delete raw.entries[0].source.retrieved; }, "entries[0].source.retrieved"],
    [(raw) => { delete raw.entries[0].effectiveTo; }, "entries[0].effectiveTo"],
    [(raw) => { delete raw.entries[0].inferenceGeoMultipliers; }, "entries[0].inferenceGeoMultipliers"],
  ];
  for (const [mutate, field] of cases) {
    const raw = syntheticCard();
    mutate(raw);
    expectRateCardError(() => parseRateCard(raw), "missing_field", field);
  }
});

test("effective instants must be UTC with a Z suffix, and an interval must end after it starts", () => {
  for (const notUtc of ["2026-10-01T00:00:00+05:30", "2026-10-01", "2026-02-30T00:00:00Z", "yesterday"]) {
    const raw = syntheticCard();
    raw.entries[0].effectiveFrom = notUtc;
    expectRateCardError(() => parseRateCard(raw), "invalid_value", "entries[0].effectiveFrom");
  }
  const raw = syntheticCard();
  raw.entries[0].effectiveTo = "2026-10-01T00:00:00Z";
  expectRateCardError(() => parseRateCard(raw), "invalid_interval", "entries[0].effectiveTo");
});

test("prompt tiers must cover every prompt size exactly once, and a tiered entry names its counted categories", () => {
  const gap = syntheticCard();
  gap.entries = [syntheticTieredEntry()];
  gap.entries[0].promptTiers[1].promptTokensOver = 100001;
  expectRateCardError(() => parseRateCard(gap), "tier_partition", "entries[0].promptTiers[1].promptTokensOver");

  const unboundedFirst = syntheticCard();
  unboundedFirst.entries = [syntheticTieredEntry()];
  delete unboundedFirst.entries[0].promptTiers[0].promptTokensUpTo;
  expectRateCardError(() => parseRateCard(unboundedFirst), "tier_partition", "entries[0].promptTiers[0].promptTokensUpTo");

  const boundedSingle = syntheticCard();
  boundedSingle.entries[0].promptTiers[0].promptTokensUpTo = 100000;
  expectRateCardError(() => parseRateCard(boundedSingle), "tier_partition", "entries[0].promptTiers[0].promptTokensUpTo");

  const uncounted = syntheticCard();
  uncounted.entries = [syntheticTieredEntry()];
  delete uncounted.entries[0].promptTokensCountedCategories;
  expectRateCardError(() => parseRateCard(uncounted), "missing_field", "entries[0].promptTokensCountedCategories");

  const badCategory = syntheticCard();
  badCategory.entries = [syntheticTieredEntry()];
  badCategory.entries[0].promptTokensCountedCategories = ["input", "cacheWrite"];
  expectRateCardError(() => parseRateCard(badCategory), "invalid_value", "entries[0].promptTokensCountedCategories[1]");

  const valid = syntheticCard();
  valid.entries = [syntheticTieredEntry()];
  assert.equal(parseRateCard(valid).entries[0].promptTiers.length, 2);
});

test("two spellings that normalise to one model key are refused as ambiguous", () => {
  const raw = syntheticCard();
  raw.entries = [
    syntheticEntry("claude-haiku-4-5", "2026-10-01T00:00:00Z", "2026-10-15T00:00:00Z"),
    syntheticEntry("claude-haiku-4.5", "2026-10-15T00:00:00Z", null),
  ];
  expectRateCardError(() => parseRateCard(raw), "ambiguous_model_key", "entries[1].model");
});

test("geography multipliers must be positive decimal strings, and at least one geography is listed", () => {
  const zero = syntheticCard();
  zero.entries[0].inferenceGeoMultipliers.us = "0";
  expectRateCardError(() => parseRateCard(zero), "non_positive_multiplier", "entries[0].inferenceGeoMultipliers.us");

  const empty = syntheticCard();
  empty.entries[0].inferenceGeoMultipliers = {};
  expectRateCardError(() => parseRateCard(empty), "invalid_value", "entries[0].inferenceGeoMultipliers");
});

test("the rate unit is USD per a positive whole number of tokens, and the schema version is 1", () => {
  const currency = syntheticCard();
  currency.rateUnit.currency = "EUR";
  expectRateCardError(() => parseRateCard(currency), "invalid_value", "rateUnit.currency");

  const perTokens = syntheticCard();
  perTokens.rateUnit.perTokens = 0;
  expectRateCardError(() => parseRateCard(perTokens), "invalid_value", "rateUnit.perTokens");

  const version = syntheticCard();
  version.schemaVersion = 2;
  expectRateCardError(() => parseRateCard(version), "unsupported_schema_version", "schemaVersion");
});

test("source URLs must be https, and retrieval dates real calendar dates", () => {
  const http = syntheticCard();
  http.entries[0].source.url = "http://example.test/pricing";
  expectRateCardError(() => parseRateCard(http), "invalid_value", "entries[0].source.url");

  const date = syntheticCard();
  date.entries[0].source.retrieved = "2026-13-01";
  expectRateCardError(() => parseRateCard(date), "invalid_value", "entries[0].source.retrieved");
});

test("text that is not JSON, or not an object, is refused as a rate card", () => {
  expectRateCardError(() => parseRateCardJson("{ not json"), "invalid_json", "(document)");
  expectRateCardError(() => parseRateCard([]), "invalid_value", "(document)");
  expectRateCardError(() => parseRateCard(null), "invalid_value", "(document)");
});

test("a loaded rate card holds Decimal rates, not binary floating point", async () => {
  const card = await loadRateCardFile(RATE_CARD_PATH);
  const rate = entryInForce(card, "claude-haiku-5-5").promptTiers[0].rates.cacheWrite5m;
  assert.ok(Decimal.isDecimal(rate));
  assert.equal(rate.toString(), "0.125");
});
