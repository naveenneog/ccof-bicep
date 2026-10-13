// RED-first unit tests for the reconciler's core computation logic
// (docs/COST-MODEL.md): Decimal-exact spend aggregation, the per-person
// realtime ceiling formula, and the project/classification aggregate
// capacity check. Pure, framework-free - no Cosmos, no Log Analytics,
// same pattern as tests/resolver-decide.test.ts.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  computeSpend,
  computeNextCeilingTokens,
  computeAggregateCapacity,
} from "../src/reconciler/compute-ceiling.ts";
import type { RateTable, UsageEvent } from "../src/reconciler/compute-ceiling.ts";

test("computeSpend sums usage across models and categories without floating-point drift", () => {
  // The classic floating-point trap (0.1 + 0.2 !== 0.3 in IEEE 754) must not
  // leak into billing math - docs/COST-MODEL.md requires "Decimal-exact".
  const usage = [
    { model: "claude-haiku-4-5", category: "input" as const, tokens: 100_000 },
    { model: "claude-haiku-4-5", category: "output" as const, tokens: 50_000 },
    { model: "claude-sonnet-5", category: "input" as const, tokens: 10_000 },
  ];
  const rates = {
    "claude-haiku-4-5": { input: 0.1, output: 0.5 }, // $ per 1,000 tokens
    "claude-sonnet-5": { input: 1, output: 3 },
  };

  const spend = computeSpend(usage, rates);

  // 100,000/1000*0.1 + 50,000/1000*0.5 + 10,000/1000*1 = 10 + 25 + 10 = 45
  assert.equal(spend.toNumber(), 45);
});

test("computeSpend accumulates many small fractional amounts exactly", () => {
  // 0.1 + 0.2 + ... (30 times) would drift under plain IEEE 754 doubles.
  const usage = Array.from({ length: 30 }, () => ({
    model: "claude-haiku-4-5",
    category: "input" as const,
    tokens: 1,
  }));
  const rates = { "claude-haiku-4-5": { input: 100, output: 0 } }; // $0.1 per token
  const spend = computeSpend(usage, rates);
  assert.equal(spend.toNumber(), 3); // exactly 3, not 2.9999999999999996
});

test("computeSpend throws a named error for an unpriced model rather than silently treating it as free", () => {
  const usage = [{ model: "claude-unknown-model", category: "input" as const, tokens: 100 }];
  assert.throws(() => computeSpend(usage, {}), /no rate for model claude-unknown-model/);
});

test("computeSpend prices the five token categories separately, cache write 5 min and 1 h at their own rates", () => {
  // ADR-0005: cache write 5 min and cache write 1 h are separate categories
  // (1.25x and 2x input on Anthropic's pricing page), never one undivided rate.
  const usage = [
    { model: "claude-sonnet-5", category: "input" as const, tokens: 1_000 },
    { model: "claude-sonnet-5", category: "cacheWrite5m" as const, tokens: 1_000 },
    { model: "claude-sonnet-5", category: "cacheWrite1h" as const, tokens: 1_000 },
    { model: "claude-sonnet-5", category: "cacheRead" as const, tokens: 1_000 },
    { model: "claude-sonnet-5", category: "output" as const, tokens: 1_000 },
  ];
  const rates = {
    "claude-sonnet-5": { input: 0.002, cacheWrite5m: 0.0025, cacheWrite1h: 0.004, cacheRead: 0.0002, output: 0.01 },
  };
  // 0.002 + 0.0025 + 0.004 + 0.0002 + 0.01 = 0.0187 ($ per 1,000 tokens x 1,000 tokens each)
  assert.equal(computeSpend(usage, rates).toString(), "0.0187");
});

test("computeSpend refuses the undivided legacy cacheWrite category, even when the rate table has a rate for it", () => {
  // Usage arrives untyped from the ledger; a row still using the four-category
  // shape must not be priced at whatever single rate happens to be present.
  const legacyUsage = [{ model: "claude-sonnet-5", category: "cacheWrite", tokens: 1_000 }];
  const legacyRates: Record<string, Record<string, number>> = { "claude-sonnet-5": { input: 0.002, cacheWrite: 0.0025, output: 0.01 } };
  assert.throws(
    () => computeSpend(legacyUsage as unknown as UsageEvent[], legacyRates as unknown as RateTable),
    /unknown usage category cacheWrite/,
  );
});

test("computeSpend refuses a token count that is negative, fractional or not a number, rather than lowering spend", () => {
  const rates = { "claude-sonnet-5": { input: 0.002 } };
  for (const tokens of [-1_000, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(
      () => computeSpend([{ model: "claude-sonnet-5", category: "input", tokens }], rates),
      /invalid token count/,
      String(tokens),
    );
  }
});

test("computeNextCeilingTokens converts remaining dollar budget to a token count at the worst-case rate", () => {
  // docs/COST-MODEL.md: "nextCeiling = remaining ÷ price(most expensive model in the allow-list)".
  // Implemented exactly as specified - the rate-limit-window semantics of
  // how this interacts with the reconciler interval N are explicitly not
  // yet resolved (docs/UNKNOWNS.md U-5), not invented here.
  const remaining = computeNextCeilingTokens({
    remainingBudgetUsd: 10,
    mostExpensiveRatePerThousandTokens: 2.5,
  });
  // $10 / ($2.5 per 1,000 tokens) = 4,000 tokens
  assert.equal(remaining.toNumber(), 4000);
});

test("computeNextCeilingTokens returns zero, never negative, once the budget is exhausted", () => {
  const remaining = computeNextCeilingTokens({
    remainingBudgetUsd: -5,
    mostExpensiveRatePerThousandTokens: 2.5,
  });
  assert.equal(remaining.toNumber(), 0);
});

test("computeNextCeilingTokens rejects a non-positive rate rather than dividing by zero", () => {
  assert.throws(
    () => computeNextCeilingTokens({ remainingBudgetUsd: 10, mostExpensiveRatePerThousandTokens: 0 }),
    /must be positive/,
  );
});

test("computeAggregateCapacity: worstCasePotential and a strict-mode refusal when it would exceed the aggregate budget", () => {
  // docs/COST-MODEL.md: "worstCasePotential = (activeMemberCount + 1) x personBudget"
  const result = computeAggregateCapacity({
    activeMemberCount: 10,
    personBudgetUsd: 250,
    aggregateBudgetUsd: 2500,
    aggregateMode: "strict",
  });
  // (10 + 1) * 250 = 2750 > 2500
  assert.equal(result.worstCasePotentialUsd, 2750);
  assert.equal(result.admit, false);
  assert.equal(result.reason, "capacity_exceeded_strict");
});

test("computeAggregateCapacity admits when worstCasePotential stays within the aggregate budget", () => {
  const result = computeAggregateCapacity({
    activeMemberCount: 5,
    personBudgetUsd: 250,
    aggregateBudgetUsd: 2500,
    aggregateMode: "strict",
  });
  // (5 + 1) * 250 = 1500 <= 2500
  assert.equal(result.worstCasePotentialUsd, 1500);
  assert.equal(result.admit, true);
  assert.equal(result.reason, null);
});

test("computeAggregateCapacity admits in notify mode even when worstCasePotential exceeds the aggregate budget, but flags it", () => {
  // notify mode never blocks (docs/COST-MODEL.md) - the addition proceeds,
  // an alert is raised separately (not this function's concern - it only
  // reports whether capacity was exceeded, the caller decides what to do).
  const result = computeAggregateCapacity({
    activeMemberCount: 10,
    personBudgetUsd: 250,
    aggregateBudgetUsd: 2500,
    aggregateMode: "notify",
  });
  assert.equal(result.worstCasePotentialUsd, 2750);
  assert.equal(result.admit, true);
  assert.equal(result.reason, "capacity_exceeded_notify");
});

test("computeAggregateCapacity treats a null aggregateBudget as uncapped (track for visibility only)", () => {
  // docs/LLD.md: "null means no cap, track for visibility only".
  const result = computeAggregateCapacity({
    activeMemberCount: 1000,
    personBudgetUsd: 250,
    aggregateBudgetUsd: null,
    aggregateMode: "strict",
  });
  assert.equal(result.admit, true);
  assert.equal(result.reason, null);
});
