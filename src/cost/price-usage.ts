// Prices one ledger row (ADR-0005 decision 1, ADR-0011 decisions 4-8):
//
//   listUsd      = geoMultiplier × Σ tokens[c] × rate(model, c, promptTier, t) / perTokens
//   contractUsd  = listUsd × (1 − discount(model, t))
//   predictedCcu = contractUsd × CCU per USD
//
// Rates, tiers, multipliers and discounts all come from the rate card and
// the contract schedule in force at the request's time. A row is "priced"
// when every input is known, "partial" (a lower bound) when cache categories
// or the geography were not captured or a reported feature has no rate, and
// "unpriced" (no amount, never $0) when it cannot be bounded. Amounts are
// exact decimals, never rounded here. Names echoed into `detail` are
// JSON-encoded, so a crafted model or geography cannot forge a log line.

import type { Decimal } from "decimal.js";
import { usdToCcu } from "./budget-units.ts";
import { findDiscount } from "./contract-schedule.ts";
import type { ContractSchedule } from "./contract-schedule.ts";
import { Money } from "./money.ts";
import { findRateEntry, promptTierIndex } from "./rate-card.ts";
import type { RateCard, RateCardEntry, RateEntryLookup } from "./rate-card.ts";
import { TOKEN_CATEGORIES } from "./token-categories.ts";
import type { TokenCategory } from "./token-categories.ts";
import { validateUsage } from "./usage-row.ts";
import type { UsageToPrice, ValidUsage } from "./usage-row.ts";

export type { UsageToPrice } from "./usage-row.ts";

export type UnpricedReason =
  | "model_not_in_rate_card"
  | "no_rate_in_force"
  | "inference_geo_not_priced"
  | "token_count_unknown";

export interface UnpricedUsage {
  status: "unpriced";
  reasons: readonly UnpricedReason[];
  detail: string;
  unpricedFeatures: readonly string[];
  rateCardVersion: string;
  contractScheduleVersion: string;
}

export interface PricedUsage {
  // "partial": unknownCategories or unpricedFeatures is non-empty, or
  // inferenceGeoKnown is false. The amounts are then lower bounds.
  status: "priced" | "partial";
  rateCardVersion: string;
  contractScheduleVersion: string;
  model: string;
  rateEntryEffectiveFrom: string;
  promptTierIndex: number;
  promptTierKnown: boolean;
  inferenceGeoMultiplier: Decimal;
  inferenceGeoKnown: boolean;
  unknownCategories: readonly TokenCategory[];
  // Features the row reports whose charge the rate card cannot price (U-22).
  unpricedFeatures: readonly string[];
  // "list" when the schedule records no discount for the model at that time.
  pricingBasis: "contract" | "list";
  discount: Decimal;
  listUsd: Decimal;
  contractUsd: Decimal;
  predictedCcu: Decimal;
}

export type PricingOutcome = PricedUsage | UnpricedUsage;

export interface PricingTotals {
  rows: number;
  priced: number;
  partial: number;
  unpriced: number;
  // Sums over priced and partial rows only; unpriced rows add no amount.
  listUsd: Decimal;
  contractUsd: Decimal;
  predictedCcu: Decimal;
}

// Input and output are always visible to the gateway, including for streamed
// responses (docs/MARKETPLACE-COST.md §4); a row without them has no
// meaningful lower bound, so it is unpriced rather than partial.
const ALWAYS_CAPTURED: readonly TokenCategory[] = ["input", "output"];

export function priceUsage(row: UsageToPrice, rateCard: RateCard, schedule: ContractSchedule): PricingOutcome {
  const usage = validateUsage(row);
  const versions = { rateCardVersion: rateCard.version, contractScheduleVersion: schedule.version };
  // The rate card prices no features yet (U-22), so any feature use is a
  // missing part of the cost: the row stays a lower bound rather than being
  // dropped, which would let a requester zero their own cost with one call.
  const unpricedFeatures = usage.features.filter(([, count]) => count > 0).map(([name]) => name);
  const lookup = findRateEntry(rateCard, usage.model, usage.at);
  const refusals = unpricedReasons(usage, lookup, rateCard.version);
  if (!lookup.found || refusals.length > 0) {
    return {
      status: "unpriced",
      reasons: refusals.map(([reason]) => reason),
      detail: refusals.map(([, detail]) => detail).join("; "),
      unpricedFeatures,
      ...versions,
    };
  }

  const entry = lookup.entry;
  const unknownCategories = TOKEN_CATEGORIES.filter((category) => usage.tokens[category] === null);
  const geo = geoMultiplier(entry, usage.inferenceGeo);
  const tier = cheapestConsistentTier(entry, usage.tokens, rateCard.tokensPerRate);
  const discount = findDiscount(schedule, entry.modelKey, usage.at);
  const listUsd = tier.baseUsd.times(geo.multiplier);
  const contractUsd = discount === null ? listUsd : listUsd.times(new Money(1).minus(discount.discount));
  const complete = unknownCategories.length === 0 && unpricedFeatures.length === 0 && geo.known;

  return {
    status: complete ? "priced" : "partial",
    ...versions,
    model: entry.model,
    rateEntryEffectiveFrom: entry.effectiveFrom,
    promptTierIndex: tier.index,
    promptTierKnown: tier.known,
    inferenceGeoMultiplier: geo.multiplier,
    inferenceGeoKnown: geo.known,
    unknownCategories,
    unpricedFeatures,
    pricingBasis: discount === null ? "list" : "contract",
    discount: discount === null ? new Money(0) : discount.discount,
    listUsd,
    contractUsd,
    predictedCcu: usdToCcu(contractUsd),
  };
}

export function totalPricing(outcomes: Iterable<PricingOutcome>): PricingTotals {
  const totals: PricingTotals = {
    rows: 0,
    priced: 0,
    partial: 0,
    unpriced: 0,
    listUsd: new Money(0),
    contractUsd: new Money(0),
    predictedCcu: new Money(0),
  };
  for (const outcome of outcomes) {
    totals.rows += 1;
    totals[outcome.status] += 1;
    if (outcome.status === "unpriced") continue;
    totals.listUsd = totals.listUsd.plus(outcome.listUsd);
    totals.contractUsd = totals.contractUsd.plus(outcome.contractUsd);
    totals.predictedCcu = totals.predictedCcu.plus(outcome.predictedCcu);
  }
  return totals;
}

function unpricedReasons(usage: ValidUsage, lookup: RateEntryLookup, rateCardVersion: string): Array<[UnpricedReason, string]> {
  const reasons: Array<[UnpricedReason, string]> = [];
  const model = JSON.stringify(usage.model);
  if (!lookup.found) {
    reasons.push([
      lookup.reason,
      lookup.reason === "model_not_in_rate_card"
        ? `model ${model} is not in rate card ${rateCardVersion}`
        : `rate card ${rateCardVersion} has no entry for ${model} at ${usage.at.toISOString()}`,
    ]);
  } else if (usage.inferenceGeo !== null && !lookup.entry.inferenceGeoMultipliers.has(usage.inferenceGeo)) {
    reasons.push(["inference_geo_not_priced", `inference_geo ${JSON.stringify(usage.inferenceGeo)} is not priced for ${lookup.entry.model}`]);
  }
  const uncaptured = ALWAYS_CAPTURED.filter((category) => usage.tokens[category] === null);
  if (uncaptured.length > 0) {
    reasons.push(["token_count_unknown", `${uncaptured.join(" and ")} token counts were not captured`]);
  }
  return reasons;
}

// A known geography's multiplier; an unknown one takes the entry's smallest
// multiplier, so the amount stays a lower bound.
function geoMultiplier(entry: RateCardEntry, inferenceGeo: string | null): { multiplier: Decimal; known: boolean } {
  if (inferenceGeo !== null) {
    const multiplier = entry.inferenceGeoMultipliers.get(inferenceGeo);
    if (multiplier !== undefined) return { multiplier, known: true };
  }
  const smallest = [...entry.inferenceGeoMultipliers.values()].reduce((min, value) => (value.lessThan(min) ? value : min));
  return { multiplier: smallest, known: false };
}

// The tier is set by the sum of the entry's counted categories. When one of
// them was not captured, the prompt is at least the known sum, so every tier
// from there up is possible; the cheapest of them keeps the amount a lower
// bound whatever the tiers' rates are.
function cheapestConsistentTier(
  entry: RateCardEntry,
  tokens: Readonly<Record<TokenCategory, number | null>>,
  tokensPerRate: Decimal,
): { index: number; known: boolean; baseUsd: Decimal } {
  const counted = entry.promptTokensCountedCategories;
  const knownPromptTokens = counted.reduce((sum, category) => sum + (tokens[category] ?? 0), 0);
  const first = promptTierIndex(entry, knownPromptTokens);
  const last = counted.every((category) => tokens[category] !== null) ? first : entry.promptTiers.length - 1;

  let cheapest = { index: first, baseUsd: knownTokensCost(entry, first, tokens, tokensPerRate) };
  for (let index = first + 1; index <= last; index += 1) {
    const baseUsd = knownTokensCost(entry, index, tokens, tokensPerRate);
    if (baseUsd.lessThan(cheapest.baseUsd)) cheapest = { index, baseUsd };
  }
  return { ...cheapest, known: first === last };
}

function knownTokensCost(
  entry: RateCardEntry,
  tierIndex: number,
  tokens: Readonly<Record<TokenCategory, number | null>>,
  tokensPerRate: Decimal,
): Decimal {
  const rates = entry.promptTiers[tierIndex].rates;
  let total = new Money(0);
  for (const category of TOKEN_CATEGORIES) {
    const count = tokens[category];
    if (count !== null) total = total.plus(new Money(count).times(rates[category]));
  }
  return total.dividedBy(tokensPerRate);
}
