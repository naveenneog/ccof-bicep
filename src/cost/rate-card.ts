// The versioned rate card (ADR-0011): list prices per model, effective
// interval, prompt tier and token category, plus inference_geo multipliers,
// all read from configuration with their citations. This module validates the
// card and selects the entry in force at a request's timestamp; it holds no
// rates, model names, thresholds or multipliers of its own (owner rule,
// 2026-10-11).

import { readFile } from "node:fs/promises";
import type { Decimal } from "decimal.js";
import { RateCardError } from "./errors.ts";
import type { CostConfigErrorCode } from "./errors.ts";
import {
  DOCUMENT,
  assertNoOverlap,
  child,
  isInForce,
  readArray,
  readDecimalText,
  readFields,
  readHttpsUrl,
  readInterval,
  readIsoDate,
  readObject,
  readOptionalString,
  readOptionalStringList,
  readPositiveInteger,
  readString,
} from "./config-fields.ts";
import type { EffectiveInterval } from "./config-fields.ts";
import { Money } from "./money.ts";
import { modelKey, undatedModelKey } from "./model-key.ts";
import { TOKEN_CATEGORIES, isTokenCategory } from "./token-categories.ts";
import type { TokenCategory } from "./token-categories.ts";

export interface Citation {
  url: string;
  retrieved: string;
  quote: string | null;
}

export interface PromptTier {
  // Anthropic's wording: a tier covers prompts "over" one size and "up to" another.
  promptTokensOver: number | null;
  promptTokensUpTo: number | null;
  rates: Readonly<Record<TokenCategory, Decimal>>;
}

export interface RateCardEntry extends EffectiveInterval {
  model: string;
  modelKey: string;
  displayName: string | null;
  source: Citation;
  inferenceGeoMultipliers: ReadonlyMap<string, Decimal>;
  promptTokensCountedCategories: readonly TokenCategory[];
  promptTiers: readonly PromptTier[];
}

export interface RateCard {
  version: string;
  currency: "USD";
  tokensPerRate: Decimal;
  entries: readonly RateCardEntry[];
  entriesByModelKey: ReadonlyMap<string, readonly RateCardEntry[]>;
}

export type RateEntryLookup =
  | { found: true; entry: RateCardEntry }
  | { found: false; reason: "model_not_in_rate_card" | "no_rate_in_force" };

const fail = (field: string, code: CostConfigErrorCode, detail: string) => new RateCardError(field, code, detail);

export async function loadRateCardFile(path: string | URL): Promise<RateCard> {
  return parseRateCardJson(await readFile(path, "utf8"));
}

export function parseRateCardJson(text: string): RateCard {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch (error) {
    throw fail(DOCUMENT, "invalid_json", `is not valid JSON: ${(error as Error).message}`);
  }
  return parseRateCard(value);
}

export function parseRateCard(value: unknown): RateCard {
  const document = readFields(value, DOCUMENT, fail, ["schemaVersion", "version", "rateUnit", "entries"], ["description", "notes"]);
  if (document.schemaVersion !== 1) throw fail("schemaVersion", "unsupported_schema_version", "must be 1");
  const version = readString(document.version, "version", fail);
  readOptionalString(document, "description", DOCUMENT, fail);
  readOptionalStringList(document, "notes", DOCUMENT, fail);
  const tokensPerRate = readRateUnit(document.rateUnit, "rateUnit");

  const rawEntries = readArray(document.entries, "entries", fail);
  if (rawEntries.length === 0) throw fail("entries", "invalid_value", "must list at least one entry");
  const entries = rawEntries.map((raw, index) => readEntry(raw, child("entries", index)));
  assertOneSpellingPerModel(entries);
  assertNoOverlap(
    entries.map((entry) => ({ key: entry.modelKey, interval: entry })),
    (index) => child("entries", index),
    fail,
  );

  const entriesByModelKey = new Map<string, RateCardEntry[]>();
  for (const entry of entries) {
    entriesByModelKey.set(entry.modelKey, [...(entriesByModelKey.get(entry.modelKey) ?? []), entry]);
  }
  return { version, currency: "USD", tokensPerRate: new Money(tokensPerRate), entries, entriesByModelKey };
}

// The entry for a model name (matched per ADR-0011 decision 3) whose
// half-open interval contains the instant.
export function findRateEntry(card: RateCard, model: string, at: Date): RateEntryLookup {
  const atMs = at.getTime();
  if (Number.isNaN(atMs)) throw new RangeError("findRateEntry needs a valid Date");
  const key = resolveModelKey(card, model);
  if (key === null) return { found: false, reason: "model_not_in_rate_card" };
  const entry = card.entriesByModelKey.get(key)?.find((candidate) => isInForce(candidate, atMs));
  return entry === undefined ? { found: false, reason: "no_rate_in_force" } : { found: true, entry };
}

// The rate card's key for a model name: an exact match after normalising,
// else a match without a trailing calendar date; null when neither exists.
export function resolveModelKey(card: RateCard, model: string): string | null {
  const key = modelKey(model);
  if (card.entriesByModelKey.has(key)) return key;
  const undated = undatedModelKey(key);
  return undated !== null && card.entriesByModelKey.has(undated) ? undated : null;
}

// The index of the tier covering a prompt of this many tokens. The card's
// tiers cover every non-negative size exactly once (checked at load).
export function promptTierIndex(entry: RateCardEntry, promptTokens: number): number {
  if (!Number.isSafeInteger(promptTokens) || promptTokens < 0) {
    throw new RangeError("promptTokens must be a non-negative whole number");
  }
  return entry.promptTiers.findIndex(
    (tier) =>
      (tier.promptTokensOver === null || promptTokens > tier.promptTokensOver) &&
      (tier.promptTokensUpTo === null || promptTokens <= tier.promptTokensUpTo),
  );
}

function readRateUnit(value: unknown, field: string): number {
  const unit = readFields(value, field, fail, ["currency", "perTokens", "source"]);
  // CCU is defined in USD (budget-units.ts), so the card must be in USD too.
  if (unit.currency !== "USD") throw fail(child(field, "currency"), "invalid_value", 'must be "USD"');
  readCitation(unit.source, child(field, "source"));
  return readPositiveInteger(unit.perTokens, child(field, "perTokens"), fail);
}

function readCitation(value: unknown, field: string): Citation {
  const source = readFields(value, field, fail, ["url", "retrieved"], ["quote"]);
  return {
    url: readHttpsUrl(source.url, child(field, "url"), fail),
    retrieved: readIsoDate(source.retrieved, child(field, "retrieved"), fail),
    quote: readOptionalString(source, "quote", field, fail),
  };
}

function readEntry(value: unknown, field: string): RateCardEntry {
  const entry = readFields(
    value,
    field,
    fail,
    ["model", "effectiveFrom", "effectiveTo", "source", "inferenceGeoMultipliers", "promptTiers"],
    ["displayName", "promptTokensCountedCategories", "notes"],
  );
  const model = readString(entry.model, child(field, "model"), fail);
  const key = modelKey(model);
  if (key === "") throw fail(child(field, "model"), "invalid_value", "must contain letters or digits");
  readOptionalStringList(entry, "notes", field, fail);
  const promptTiers = readPromptTiers(entry.promptTiers, child(field, "promptTiers"));
  const countedField = child(field, "promptTokensCountedCategories");
  if (promptTiers.length > 1 && entry.promptTokensCountedCategories === undefined) {
    throw fail(countedField, "missing_field", "is required when an entry has more than one prompt tier");
  }
  return {
    model,
    modelKey: key,
    displayName: readOptionalString(entry, "displayName", field, fail),
    ...readInterval(entry, field, fail),
    source: readCitation(entry.source, child(field, "source")),
    inferenceGeoMultipliers: readGeoMultipliers(entry.inferenceGeoMultipliers, child(field, "inferenceGeoMultipliers")),
    promptTokensCountedCategories:
      entry.promptTokensCountedCategories === undefined ? [] : readCountedCategories(entry.promptTokensCountedCategories, countedField),
    promptTiers,
  };
}

function readGeoMultipliers(value: unknown, field: string): ReadonlyMap<string, Decimal> {
  const object = readObject(value, field, fail);
  const geos = Object.keys(object);
  if (geos.length === 0) throw fail(field, "invalid_value", "must list at least one inference_geo value");
  const multipliers = new Map<string, Decimal>();
  for (const geo of geos) {
    const geoField = child(field, geo);
    if (!/^[a-z][a-z0-9_-]*$/.test(geo)) throw fail(geoField, "invalid_value", "is not an inference_geo value");
    const multiplier = readDecimalText(object[geo], geoField, fail);
    if (!multiplier.greaterThan(0)) throw fail(geoField, "non_positive_multiplier", "must be greater than zero");
    multipliers.set(geo, multiplier);
  }
  return multipliers;
}

function readCountedCategories(value: unknown, field: string): TokenCategory[] {
  const items = readArray(value, field, fail);
  if (items.length === 0) throw fail(field, "invalid_value", "must list at least one token category");
  const categories: TokenCategory[] = [];
  items.forEach((item, index) => {
    if (!isTokenCategory(item) || categories.includes(item)) {
      throw fail(child(field, index), "invalid_value", `must be a distinct token category: ${TOKEN_CATEGORIES.join(", ")}`);
    }
    categories.push(item);
  });
  return categories;
}

function readPromptTiers(value: unknown, field: string): PromptTier[] {
  const items = readArray(value, field, fail);
  if (items.length === 0) throw fail(field, "invalid_value", "must list at least one prompt tier");
  const tiers = items.map((item, index) => readPromptTier(item, child(field, index)));
  assertTiersPartitionPromptSizes(tiers, field);
  return tiers;
}

function readPromptTier(value: unknown, field: string): PromptTier {
  const tier = readFields(value, field, fail, ["rates"], ["promptTokensOver", "promptTokensUpTo"]);
  const bound = (key: string): number | null =>
    tier[key] === undefined ? null : readPositiveInteger(tier[key], child(field, key), fail);
  return { promptTokensOver: bound("promptTokensOver"), promptTokensUpTo: bound("promptTokensUpTo"), rates: readRates(tier.rates, child(field, "rates")) };
}

// The first tier starts at zero, each later tier starts where the previous
// one ends, and the last is unbounded: every prompt size has one tier.
function assertTiersPartitionPromptSizes(tiers: readonly PromptTier[], field: string): void {
  const partition = (index: number, key: string, detail: string) => fail(child(child(field, index), key), "tier_partition", detail);
  if (tiers[0].promptTokensOver !== null) throw partition(0, "promptTokensOver", "must be absent: the first tier starts at zero tokens");
  tiers.forEach((tier, index) => {
    const isLast = index === tiers.length - 1;
    if (isLast && tier.promptTokensUpTo !== null) throw partition(index, "promptTokensUpTo", "must be absent: the last tier has no upper bound");
    if (!isLast && tier.promptTokensUpTo === null) throw partition(index, "promptTokensUpTo", "is required on every tier but the last");
    if (index > 0 && tier.promptTokensOver !== tiers[index - 1].promptTokensUpTo) {
      throw partition(index, "promptTokensOver", "must equal the previous tier's promptTokensUpTo");
    }
    if (tier.promptTokensOver !== null && tier.promptTokensUpTo !== null && tier.promptTokensUpTo <= tier.promptTokensOver) {
      throw partition(index, "promptTokensUpTo", "must be greater than promptTokensOver");
    }
  });
}

function readRates(value: unknown, field: string): Record<TokenCategory, Decimal> {
  const object = readObject(value, field, fail);
  for (const key of Object.keys(object)) {
    if (!isTokenCategory(key)) throw fail(child(field, key), "unknown_field", "is not one of the five token categories");
  }
  const rates = {} as Record<TokenCategory, Decimal>;
  for (const category of TOKEN_CATEGORIES) {
    const rateField = child(field, category);
    if (!Object.hasOwn(object, category)) throw fail(rateField, "missing_category", "is required: every category is stored explicitly");
    const rate = readDecimalText(object[category], rateField, fail);
    if (!rate.greaterThan(0)) throw fail(rateField, "non_positive_rate", "must be greater than zero");
    rates[category] = rate;
  }
  return rates;
}

// Two spellings of one model (for example "claude-haiku-4-5" and
// "claude-haiku-4.5") would make matching depend on entry order.
function assertOneSpellingPerModel(entries: readonly RateCardEntry[]): void {
  const firstSpelling = new Map<string, string>();
  entries.forEach((entry, index) => {
    const seen = firstSpelling.get(entry.modelKey);
    if (seen !== undefined && seen !== entry.model) {
      throw fail(child(child("entries", index), "model"), "ambiguous_model_key", `normalises to the same key as "${seen}"`);
    }
    firstSpelling.set(entry.modelKey, entry.model);
  });
}
