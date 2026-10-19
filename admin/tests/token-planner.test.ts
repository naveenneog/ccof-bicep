import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { blendedRate, planBudget, PlanError, worstRate } from "../src/token-planner.ts";
import type { TokenRates, TrafficMix } from "../src/token-planner.ts";

const card = JSON.parse(await readFile(new URL("../../config/rate-card.json", import.meta.url), "utf8"));
const ratesOf = (model: string): TokenRates => card.entries.find((e: { model: string }) => e.model === model).promptTiers[0].rates;
const mix: TrafficMix = { outputPercentOfTokens: 20, cacheReadPercentOfInput: 50, cacheWrite5mPercentOfInput: 10, cacheWrite1hPercentOfInput: 0 };

test("blended rate follows the cache mix exactly (Sonnet 5, from the rate card)", () => {
  // input $2, cacheRead $0.20, write5m $2.50, output $10 per MTok.
  // per input token: 0.4*2 + 0.5*0.2 + 0.1*2.5 = 1.15; blended: 0.8*1.15 + 0.2*10 = 2.92
  assert.equal(blendedRate(ratesOf("claude-sonnet-5"), mix).toFixed(4), "2.9200");
  assert.equal(worstRate(ratesOf("claude-sonnet-5")).toFixed(4), "10.0000");
  assert.equal(blendedRate(ratesOf("claude-sonnet-5"), mix, 1.1).toFixed(4), "3.2120", "US geography multiplier");
});
test("more caching buys more tokens for the same budget", () => {
  const base = { personMonthlyBudgetUsd: 100, sizing: "expected" as const, families: [{ family: "sonnet", model: "claude-sonnet-5", budgetPercent: 100, rates: ratesOf("claude-sonnet-5") }] };
  const low = planBudget({ ...base, mix: { ...mix, cacheReadPercentOfInput: 0, cacheWrite5mPercentOfInput: 0 } }).families[0].personMonthlyTokens;
  const high = planBudget({ ...base, mix: { ...mix, cacheReadPercentOfInput: 80, cacheWrite5mPercentOfInput: 5 } }).families[0].personMonthlyTokens;
  assert.ok(high > low, `${high} > ${low}`);
});
test("$100 split across families: expected sizing reports worst-case overshoot; guaranteed sizing never exceeds budget", () => {
  const families = [
    { family: "sonnet", model: "claude-sonnet-5", budgetPercent: 70, rates: ratesOf("claude-sonnet-5") },
    { family: "haiku", model: "claude-haiku-4-5", budgetPercent: 30, rates: ratesOf("claude-haiku-4-5") },
  ];
  const expected = planBudget({ personMonthlyBudgetUsd: 100, sizing: "expected", mix, families });
  assert.equal(expected.families[0].budgetUsd, "70.00");
  assert.equal(expected.families[0].groupMonthlyTokens, null, "No group cap is invented");
  assert.equal(expected.families[0].personMonthlyTokens, 23972602, "The full $70 family allocation belongs to each user");
  assert.ok(Number(expected.expectedSpendUsd) <= 100);
  assert.ok(Number(expected.worstCaseSpendUsd) > 100);
  assert.ok(expected.warnings.some((w) => w.includes("conservative")));
  const guaranteed = planBudget({ personMonthlyBudgetUsd: 100, sizing: "guaranteed", mix, families });
  assert.ok(Number(guaranteed.worstCaseSpendUsd) <= 100, guaranteed.worstCaseSpendUsd);
  assert.equal(guaranteed.families[0].personMonthlyTokens, 7000000, "70 / $10 output rate");
  assert.equal(guaranteed.warnings.length, 0);
});
test("rate limits spread the quota over working time with a burst factor", () => {
  const plan = planBudget({ personMonthlyBudgetUsd: 100, groupMonthlyBudgetUsd: 1000, sizing: "guaranteed", mix, workingDaysPerMonth: 20, workingHoursPerDay: 8, burstFactor: 4,
    families: [{ family: "sonnet", model: "claude-sonnet-5", budgetPercent: 100, rates: ratesOf("claude-sonnet-5") }] });
  // group 10,000,000 tokens / 9,600 minutes * 4 = 4,166.67 -> 4,167; person 1,000,000 / 9,600 * 4 -> 417
  assert.equal(plan.families[0].groupTokensPerMinute, 41667);
  assert.equal(plan.families[0].personTokensPerMinute, 4167);
});
test("invalid inputs are refused rather than producing a misleading plan", () => {
  const f = [{ family: "sonnet", model: "claude-sonnet-5", budgetPercent: 100, rates: ratesOf("claude-sonnet-5") }];
  const ok = { personMonthlyBudgetUsd: 100, sizing: "expected" as const, mix, families: f };
  assert.throws(() => planBudget({ ...ok, personMonthlyBudgetUsd: 0 }), PlanError);
  assert.throws(() => planBudget({ ...ok, groupMonthlyBudgetUsd: 0 }), PlanError);
  assert.throws(() => planBudget({ ...ok, families: [{ ...f[0], budgetPercent: 60 }] }), /total 100/);
  assert.throws(() => planBudget({ ...ok, mix: { ...mix, cacheReadPercentOfInput: 95, cacheWrite5mPercentOfInput: 10 } }), /exceed 100/);
  assert.throws(() => planBudget({ ...ok, families: [{ ...f[0], rates: { ...f[0].rates, output: "abc" } }] }), PlanError);
});
test("tiny per-person quotas are flagged", () => {
  const plan = planBudget({ personMonthlyBudgetUsd: "0.01", sizing: "guaranteed", mix,
    families: [{ family: "opus", model: "claude-opus-5", budgetPercent: 100, rates: ratesOf("claude-opus-5") }] });
  assert.ok(plan.warnings.some((w) => w.includes("10,000 tokens per person")));
});
