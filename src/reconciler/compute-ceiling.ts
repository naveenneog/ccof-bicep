// Reconciler core computation logic (docs/COST-MODEL.md). Pure, framework-
// free: no Log Analytics client, no Cosmos client - a caller (the actual
// scheduled reconciler job, not yet written) supplies plain data and reads
// plain results. Uses decimal.js throughout for spend arithmetic - plain
// IEEE 754 doubles are not safe for billing math (docs/COST-MODEL.md's
// "Decimal-exact" requirement; the classic 0.1 + 0.2 !== 0.3 trap).

import { Decimal } from "decimal.js";
import { CCU_PER_USD } from "../cost/budget-units.ts";
import { Money } from "../cost/money.ts";
import { findRateEntry } from "../cost/rate-card.ts";
import type { RateCard } from "../cost/rate-card.ts";
import { TOKEN_CATEGORIES, isTokenCategory } from "../cost/token-categories.ts";
import type { TokenCategory } from "../cost/token-categories.ts";

// The five categories Anthropic prices separately: input, cache write 5 min,
// cache write 1 h, cache read and output (ADR-0005). Cache writes are never
// one undivided category: the 1 h write costs 2x input, the 5 min write 1.25x.
export type UsageCategory = TokenCategory;

export interface UsageEvent {
  model: string;
  category: UsageCategory;
  tokens: number;
}

// Contract rates in $ per 1,000 tokens, per model and category: the list
// rate from the rate card in force at the request's time, less the contract
// schedule's discount (ADR-0005, ADR-0011, src/cost). This module only
// consumes whatever rate map its caller supplies.
export type RateTable = Record<string, Partial<Record<UsageCategory, number>>>;

export function computeSpend(usage: UsageEvent[], rates: RateTable): Decimal {
  let total = new Decimal(0);
  for (const event of usage) {
    // Usage arrives untyped from the ledger, so the category is checked here
    // too: a row in the old four-category shape must not find a stray rate.
    if (!isTokenCategory(event.category)) {
      throw new Error(`unknown usage category ${String(event.category)} for model ${event.model}; expected one of ${TOKEN_CATEGORIES.join(", ")}`);
    }
    // A negative or non-numeric count would lower spend or poison the ceiling.
    if (!Number.isSafeInteger(event.tokens) || event.tokens < 0) {
      throw new Error(`invalid token count ${String(event.tokens)} for model ${event.model} category ${event.category}`);
    }
    const modelRates = rates[event.model];
    const rate = modelRates?.[event.category];
    if (rate === undefined) {
      throw new Error(`no rate for model ${event.model} category ${event.category}`);
    }
    total = total.plus(new Decimal(event.tokens).dividedBy(1000).times(rate));
  }
  return total;
}

export interface CeilingInput {
  remainingBudgetUsd: number;
  mostExpensiveRatePerThousandTokens: number;
}

// docs/COST-MODEL.md: "nextCeiling = remaining / price(most expensive model
// in the allow-list)". Implemented exactly as specified. NOTE: how this
// token count is actually enforced as a tokens-per-minute rate limit across
// a reconciliation interval of N minutes - i.e. what bounds N so that
// N x ceiling cannot itself exceed the ±2-3% overshoot target - is not yet
// resolved (docs/UNKNOWNS.md U-5, "needs the gateway's measured sustained
// per-identity throughput"). This function computes the budget-to-tokens
// conversion only; it does not decide what interval makes that conversion
// safe to enforce as a recurring per-minute allowance.
export function computeNextCeilingTokens(input: CeilingInput): Decimal {
  const remaining = Decimal.max(0, new Decimal(input.remainingBudgetUsd));
  if (remaining.isZero()) return new Decimal(0);
  if (input.mostExpensiveRatePerThousandTokens <= 0) {
    throw new Error("mostExpensiveRatePerThousandTokens must be positive - a free model has no price to bound a ceiling against");
  }
  return remaining.dividedBy(input.mostExpensiveRatePerThousandTokens).times(1000);
}

// The largest ceiling the resolver accepts: a 32-bit signed integer
// (WP-RES, 2026-10-11).
export const MAX_CEILING_TOKENS = 2_147_483_647;

const larger = (a: Decimal, b: Decimal): Decimal => (b.greaterThan(a) ? b : a);

// "price(most expensive model in the allow-list)" read from the rate card
// (ADR-0011): for each allow-listed model, the entry in force at `at`, its
// dearest tier's output rate times its largest geography multiplier, in CCU
// per token at list price, which a contract discount can only lower. Output
// is the dearer of the two categories the realtime counter sees (see
// reconcile-person.ts). null when any allow-listed model has no rate in
// force: no bound can then be stated.
export function worstCaseCcuPerOutputToken(card: RateCard, allowList: readonly string[], at: Date): Decimal | null {
  let worst: Decimal | null = null;
  for (const model of allowList) {
    const lookup = findRateEntry(card, model, at);
    if (!lookup.found) return null;
    const { entry } = lookup;
    const rate = entry.promptTiers.map((tier) => tier.rates.output).reduce(larger);
    const geo = [...entry.inferenceGeoMultipliers.values()].reduce(larger);
    const ccuPerToken = new Money(rate).times(geo).times(CCU_PER_USD).dividedBy(card.tokensPerRate);
    worst = worst === null ? ccuPerToken : larger(worst, ccuPerToken);
  }
  return worst;
}

// computeNextCeilingTokens' rule in CCU, without leaving Decimal: the
// remaining budget's worth of tokens at the worst case, in whole tokens
// rounded down, 0 when nothing remains, at most MAX_CEILING_TOKENS.
export function computeCeilingTokensFromCcu(remainingCcu: Decimal, worstCaseCcuPerToken: Decimal): number {
  if (!worstCaseCcuPerToken.greaterThan(0)) {
    throw new Error("worstCaseCcuPerToken must be positive - a free model has no price to bound a ceiling against");
  }
  if (!remainingCcu.greaterThan(0)) return 0;
  const tokens = new Money(remainingCcu).dividedBy(worstCaseCcuPerToken).floor();
  return tokens.greaterThan(MAX_CEILING_TOKENS) ? MAX_CEILING_TOKENS : tokens.toNumber();
}

// ADR 0035: the reconciler's two optional pacing settings, read as a pair.
export interface SpendPacing {
  softLimitPercent: number;
  windowMinutes: number;
}

export interface PacedCeiling {
  ceilingTokensPerMinute: number;
  softLimitReached: boolean;
}

// The remaining budget spread over one pacing window, two from the soft limit on, so that spend
// within the reconciler's delay cannot pass the budget. Rounded down to a power of two: the gateway
// keys its pace counter by this value, so it must not move with every small spend change. At least
// 1 while budget remains: the gateway reads 0 as "no pace". 0 once exhausted.
export function pacedCeilingTokens(budgetCcu: Decimal, spentCcu: Decimal, worstCaseCcuPerToken: Decimal, pacing: SpendPacing): PacedCeiling {
  const softLimitReached = new Money(spentCcu).greaterThanOrEqualTo(new Money(budgetCcu).times(pacing.softLimitPercent).dividedBy(100));
  const remaining = new Money(budgetCcu).minus(spentCcu);
  if (!remaining.greaterThan(0)) {
    return { ceilingTokensPerMinute: computeCeilingTokensFromCcu(remaining, worstCaseCcuPerToken), softLimitReached };
  }
  const windows = softLimitReached ? pacing.windowMinutes * 2 : pacing.windowMinutes;
  const ceiling = computeCeilingTokensFromCcu(remaining.dividedBy(windows), worstCaseCcuPerToken);
  return { ceilingTokensPerMinute: ceiling < 1 ? 1 : 2 ** Math.floor(Math.log2(ceiling)), softLimitReached };
}

export interface AggregateCapacityInput {
  activeMemberCount: number;
  personBudgetUsd: number;
  aggregateBudgetUsd: number | null;
  aggregateMode: "strict" | "notify";
}

export interface AggregateCapacityResult {
  worstCasePotentialUsd: number;
  admit: boolean;
  reason: "capacity_exceeded_strict" | "capacity_exceeded_notify" | null;
}

// docs/COST-MODEL.md "The capacity check when adding a member":
// worstCasePotential = (activeMemberCount + 1) x personBudget. strict mode
// refuses the addition when this would exceed aggregateBudget; notify mode
// always admits, but reports the same exceeded condition so the caller can
// raise an alert (raising the alert itself is not this function's job -
// it is a pure capacity calculation, not a side-effecting one).
export function computeAggregateCapacity(input: AggregateCapacityInput): AggregateCapacityResult {
  const worstCasePotential = new Decimal(input.activeMemberCount + 1).times(input.personBudgetUsd);
  const worstCasePotentialUsd = worstCasePotential.toNumber();

  if (input.aggregateBudgetUsd === null) {
    return { worstCasePotentialUsd, admit: true, reason: null };
  }

  const exceeded = worstCasePotential.greaterThan(input.aggregateBudgetUsd);
  if (!exceeded) {
    return { worstCasePotentialUsd, admit: true, reason: null };
  }

  return input.aggregateMode === "strict"
    ? { worstCasePotentialUsd, admit: false, reason: "capacity_exceeded_strict" }
    : { worstCasePotentialUsd, admit: true, reason: "capacity_exceeded_notify" };
}
