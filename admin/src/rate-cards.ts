// Rate-card helpers for V3: the plan route's family rates, and the cost-definitions load/review rules.
// The rate card itself is parsed only by src/cost/rate-card.ts (parseRateCard); history rules are v2's
// validateRateHistory plus one V3 rule: a new or closed entry may not take effect in the past, because
// that would reprice usage that has already been recorded and reconciled.

import { ApiError } from "./auth.ts";
import { canonical, isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";
import { parseRateCard } from "../../src/cost/rate-card.ts";
import { validateRateHistory } from "./v2.ts";
import { rateForDisplay } from "./units.ts";
import type { TokenRates } from "./token-planner.ts";

export const FAMILIES = ["haiku", "sonnet", "opus", "fable", "mythos"] as const;
export const familyOf = (model: string): string =>
  /^claude-(haiku|sonnet|opus|fable|mythos)(?:[-.]|$)/i.exec(model)?.[1]?.toLowerCase() ?? "unknown";

interface Entry { model: string; displayName?: string; effectiveFrom: string; effectiveTo: string | null; inferenceGeoMultipliers: Record<string, string>; promptTiers: { rates: Record<string, string> }[] }

function entries(card: unknown): Entry[] {
  if (!isObject(card) || !Array.isArray(card.entries)) throw new ApiError(503, "rate_card_unavailable");
  return card.entries.filter(isObject) as unknown as Entry[];
}
const perTokensOf = (card: unknown): number => (isObject(card) && isObject(card.rateUnit) && typeof card.rateUnit.perTokens === "number" ? card.rateUnit.perTokens : 1_000_000);
const inForce = (e: Entry, at: Date) => Date.parse(e.effectiveFrom) <= at.getTime() && (e.effectiveTo === null || Date.parse(e.effectiveTo) > at.getTime());

export interface PlanModel { family: string; model: string; displayName: string; geos: Record<string, string>; rates: TokenRates; tiered: boolean }

// In-force models by family, USD per million tokens, first (base) prompt tier.
export function planModels(card: unknown, at: Date): PlanModel[] {
  const perTokens = perTokensOf(card);
  return entries(card).filter((e) => inForce(e, at) && familyOf(e.model) !== "unknown").map((e) => {
    const base = e.promptTiers[0]?.rates ?? {};
    const r = (k: string) => rateForDisplay(String(base[k]), perTokens, "USD");
    return {
      family: familyOf(e.model), model: e.model, displayName: e.displayName ?? e.model, geos: { ...e.inferenceGeoMultipliers },
      rates: { input: r("input"), output: r("output"), cacheRead: r("cacheRead"), cacheWrite5m: r("cacheWrite5m"), cacheWrite1h: r("cacheWrite1h") },
      tiered: e.promptTiers.length > 1,
    };
  });
}

export interface RateCardReview {
  version: { before: string | null; after: string };
  added: Doc[];
  closed: { model: string; effectiveFrom: string; effectiveTo: string }[];
  unchanged: number;
  entries: number;
}

// Validates a candidate rate card against the parser and the history of the current one and returns
// the field-level review the console shows before saving. Throws ApiError(422, code) when refused.
export function reviewRateCard(current: unknown, candidate: unknown, now: Date): RateCardReview {
  try { parseRateCard(candidate); } catch (err) {
    throw new ApiError(422, `invalid_rate_card${err instanceof Error && /^[\w.[\]]+: [a-z_]+$/.test(err.message) ? `:${err.message.split(":")[0]}` : ""}`);
  }
  if (current !== undefined && current !== null) validateRateHistory(current, candidate);
  const before = current ? entries(current) : [];
  const after = entries(candidate);
  const key = (e: { model: string; effectiveFrom: string }) => `${e.model}@${e.effectiveFrom}`;
  const old = new Map(before.map((e) => [key(e), e]));
  const added = after.filter((e) => !old.has(key(e)));
  const closed = after.filter((e) => old.has(key(e)) && old.get(key(e))?.effectiveTo === null && e.effectiveTo !== null)
    .map((e) => ({ model: e.model, effectiveFrom: e.effectiveFrom, effectiveTo: String(e.effectiveTo) }));
  // Only a card that already has history can reprice the past; the first saved card defines it.
  if (current) {
    const floor = now.getTime() - 5 * 60_000;
    if (added.some((e) => Date.parse(e.effectiveFrom) < floor) || closed.some((c) => Date.parse(c.effectiveTo) < floor)) {
      throw new ApiError(422, "effective_date_in_past");
    }
  }
  const unchanged = after.filter((e) => old.has(key(e)) && canonical(old.get(key(e))) === canonical(e)).length;
  return {
    version: { before: isObject(current) && typeof current.version === "string" ? current.version : null, after: String((candidate as Doc).version) },
    added: added as unknown as Doc[], closed, unchanged, entries: after.length,
  };
}
