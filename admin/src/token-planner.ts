// Budget-to-token planner for the V3 project form (docs/ADMIN-V3-DESIGN.md, "Budget assistant").
// Turns a monthly USD budget into suggested token quotas and tokens-per-minute limits per model
// family, from the approved rate card and an assumed traffic mix. Pure and exact (decimal.js); it
// suggests values for the admin to review and never writes enforcement on its own.
//
// A token quota cannot cap dollars exactly: the same token count costs more when it is output than
// cached input. So every plan reports two figures: the expected spend at the assumed mix, and the
// worst-case spend if every token were billed at the family's most expensive category (output).
// "guaranteed" sizing uses that worst case, so the quota alone can never exceed the budget.

import { Money } from "../../src/cost/money.ts";
import type { Decimal } from "decimal.js";

export interface TokenRates { input: string; output: string; cacheRead: string; cacheWrite5m: string; cacheWrite1h: string }
// Shares of *input* tokens by category, in percent; uncached input is the remainder.
export interface TrafficMix { outputPercentOfTokens: number; cacheReadPercentOfInput: number; cacheWrite5mPercentOfInput: number; cacheWrite1hPercentOfInput: number }
export interface FamilyAllocation { family: string; model: string; budgetPercent: number; rates: TokenRates; worstRates?: TokenRates }
export interface PlanInput {
  personMonthlyBudgetUsd: string | number;
  groupMonthlyBudgetUsd?: string | number | null;
  geoMultiplier?: number;
  sizing: "expected" | "guaranteed";
  mix: TrafficMix;
  families: FamilyAllocation[];
  // Rate limit shaping: working days/hours the budget is spread over, and how bursty usage is.
  workingDaysPerMonth?: number;
  workingHoursPerDay?: number;
  burstFactor?: number;
}
export interface FamilyPlan {
  family: string; model: string; budgetUsd: string;
  blendedUsdPerMTok: string; worstUsdPerMTok: string;
  groupMonthlyTokens: number | null; personMonthlyTokens: number;
  personTokensPerMinute: number; groupTokensPerMinute: number | null;
  expectedSpendUsd: string; worstCaseSpendUsd: string;
}
export interface Plan {
  families: FamilyPlan[]; totalBudgetUsd: string; groupBudgetUsd: string | null;
  expectedSpendUsd: string; worstCaseSpendUsd: string; warnings: string[]; applicable: boolean;
}

export class PlanError extends Error {}
const MTOK = new Money(1_000_000);
const pct = (v: number, name: string) => {
  if (!Number.isFinite(v) || v < 0 || v > 100) throw new PlanError(`${name}: 0..100 required`);
  return new Money(v).dividedBy(100);
};
const rate = (v: string, name: string): Decimal => {
  if (!/^\d{1,6}(\.\d{1,6})?$/.test(v)) throw new PlanError(`${name}: decimal USD per MTok required`);
  return new Money(v);
};

// Blended USD per million tokens at the mix: output share at the output rate; the input share split
// into cache read / 5m write / 1h write / uncached input at their own rates.
export function blendedRate(rates: TokenRates, mix: TrafficMix, geo = 1): Decimal {
  const out = pct(mix.outputPercentOfTokens, "outputPercentOfTokens");
  const read = pct(mix.cacheReadPercentOfInput, "cacheReadPercentOfInput");
  const w5 = pct(mix.cacheWrite5mPercentOfInput, "cacheWrite5mPercentOfInput");
  const w1 = pct(mix.cacheWrite1hPercentOfInput, "cacheWrite1hPercentOfInput");
  const cached = read.plus(w5).plus(w1);
  if (cached.gt(1)) throw new PlanError("cache shares exceed 100% of input");
  const input = new Money(1).minus(out);
  const perInput = rate(rates.input, "input").times(new Money(1).minus(cached))
    .plus(rate(rates.cacheRead, "cacheRead").times(read))
    .plus(rate(rates.cacheWrite5m, "cacheWrite5m").times(w5))
    .plus(rate(rates.cacheWrite1h, "cacheWrite1h").times(w1));
  return perInput.times(input).plus(rate(rates.output, "output").times(out)).times(geo);
}
export function worstRate(rates: TokenRates, geo = 1): Decimal {
  const all = [rates.input, rates.output, rates.cacheRead, rates.cacheWrite5m, rates.cacheWrite1h].map((r, i) => rate(r, `rate${i}`));
  return all.reduce((a, b) => (b.gt(a) ? b : a)).times(geo);
}

export function planBudget(p: PlanInput): Plan {
  const amount = (v: string | number, field: string) => {
    if (!/^\d{1,9}(\.\d{1,12})?$/.test(String(v))) throw new PlanError(`${field}: positive decimal amount required`);
    const n = new Money(v);
    if (n.lte(0) || n.gt(10_000_000)) throw new PlanError(`${field}: positive amount up to 10000000 required`);
    return n;
  };
  const budget = amount(p.personMonthlyBudgetUsd, "personMonthlyBudgetUsd");
  const groupBudget = p.groupMonthlyBudgetUsd == null ? null : amount(p.groupMonthlyBudgetUsd, "groupMonthlyBudgetUsd");
  if (p.sizing !== "expected" && p.sizing !== "guaranteed") throw new PlanError("sizing: expected or guaranteed required");
  if (!p.families.length) throw new PlanError("families: at least one required");
  const geo = p.geoMultiplier ?? 1;
  if (!Number.isFinite(geo) || geo < 1 || geo > 5) throw new PlanError("geoMultiplier: 1..5 required");
  const share = p.families.reduce((s, f) => s.plus(pct(f.budgetPercent, `${f.family}.budgetPercent`)), new Money(0));
  if (!share.eq(1)) throw new PlanError("family budget percentages must total 100");
  const days = p.workingDaysPerMonth ?? 22, hours = p.workingHoursPerDay ?? 8, burst = p.burstFactor ?? 3;
  if (![days, hours, burst].every((n) => Number.isFinite(n) && n > 0) || days > 31 || hours > 24 || burst > 50) throw new PlanError("rate-limit shaping out of range");
  const minutes = new Money(days).times(hours).times(60);
  const warnings: string[] = [];
  let expected = new Money(0), worst = new Money(0);
  const families = p.families.map((f) => {
    const famBudget = budget.times(f.budgetPercent).dividedBy(100);
    const blended = blendedRate(f.rates, p.mix, geo);
    const worstR = worstRate(f.worstRates ?? f.rates, geo);
    const sizingRate = p.sizing === "guaranteed" ? worstR : blended;
    if (sizingRate.lte(0)) throw new PlanError(`${f.family}: zero rate`);
    // Floor, so rounding never lets the quota exceed the budget.
    const personTokens = famBudget.dividedBy(sizingRate).times(MTOK).floor();
    const groupTokens = groupBudget?.times(f.budgetPercent).dividedBy(100).dividedBy(sizingRate).times(MTOK).floor() ?? null;
    const personTpm = personTokens.dividedBy(minutes).times(burst).ceil();
    const groupTpm = groupTokens?.dividedBy(minutes).times(burst).ceil() ?? null;
    const exp = personTokens.dividedBy(MTOK).times(blended);
    const wc = personTokens.dividedBy(MTOK).times(worstR);
    expected = expected.plus(exp); worst = worst.plus(wc);
    if (personTokens.lt(10_000)) warnings.push(`${f.family}: under 10,000 tokens per person per month; a single long session can exhaust it`);
    return {
      family: f.family, model: f.model, budgetUsd: famBudget.toFixed(2),
      blendedUsdPerMTok: blended.toFixed(4), worstUsdPerMTok: worstR.toFixed(4),
      groupMonthlyTokens: groupTokens?.toNumber() ?? null, personMonthlyTokens: personTokens.toNumber(),
      personTokensPerMinute: personTpm.toNumber(), groupTokensPerMinute: groupTpm?.toNumber() ?? null,
      expectedSpendUsd: exp.toFixed(2), worstCaseSpendUsd: wc.toFixed(2),
    };
  });
  if (p.sizing === "expected" && worst.gt(budget)) {
    warnings.push(`Per-user quotas sized at the expected mix can cost up to $${worst.toFixed(2)}, above the $${budget.toFixed(2)} per-user budget. Use conservative sizing and separately review monetary-budget enforcement.`);
  }
  const applicable = families.every((f) => [f.personMonthlyTokens, f.groupMonthlyTokens].every((q) => q === null || Number.isSafeInteger(q) && q > 0)) &&
    ["personMonthlyTokens", "groupMonthlyTokens", "personTokensPerMinute", "groupTokensPerMinute"].every((key) => {
      const values = families.map((f) => f[key as keyof FamilyPlan]).filter((n): n is number => typeof n === "number");
      const sum = values.reduce((a, b) => a + b, 0);
      return !values.length || Number.isSafeInteger(sum) && sum > 0 && sum <= (key.endsWith("Minute") ? 2147483647 : Number.MAX_SAFE_INTEGER);
    });
  if (!applicable) warnings.push("Some suggested limits are zero or exceed supported numeric bounds. Adjust the budget or family split before applying; limits are never silently rounded up.");
  return { families, totalBudgetUsd: budget.toFixed(2), groupBudgetUsd: groupBudget?.toFixed(2) ?? null,
    expectedSpendUsd: expected.toFixed(2), worstCaseSpendUsd: worst.toFixed(2), warnings, applicable };
}
