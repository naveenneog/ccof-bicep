// The realtime ceiling in CCU (ADR-0018 D-3): docs/COST-MODEL.md's
// "nextCeiling = remaining ÷ price(most expensive model in the allow-list)",
// with the price taken from the packaged rate card, as an integer the
// resolver accepts (0 to 2,147,483,647).

import { test } from "node:test";
import assert from "node:assert/strict";
import { Decimal } from "decimal.js";
import { MAX_CEILING_TOKENS, computeCeilingTokensFromCcu, worstCaseCcuPerOutputToken } from "../src/reconciler/compute-ceiling.ts";
import { packagedRateCard } from "./helpers/reconciler-fixtures.ts";

const card = packagedRateCard();
const at = new Date("2026-10-11T13:00:00Z");

test("the worst case is the dearest output rate in the allow-list, at its largest geography multiplier, in CCU per token", () => {
  // Sonnet 5 output $10 per million tokens x 1.1 (us) x 100 CCU per USD / 1,000,000 = 0.0011 CCU per token.
  assert.equal(worstCaseCcuPerOutputToken(card, ["claude-haiku-4-5", "claude-sonnet-5"], at)?.toFixed(), "0.0011");
  // Haiku 4.5 lists only global: $5 x 1 x 100 / 1,000,000.
  assert.equal(worstCaseCcuPerOutputToken(card, ["claude-haiku-4-5"], at)?.toFixed(), "0.0005");
});

test("a tiered model's worst case is its dearest tier", () => {
  // Haiku 5.5 over 100,000 prompt tokens: output $2.50 x 1.1 x 100 / 1,000,000.
  assert.equal(worstCaseCcuPerOutputToken(card, ["claude-haiku-5-5"], at)?.toFixed(), "0.000275");
});

test("an allow-listed model with no rate in force means no worst case can be stated (null)", () => {
  assert.equal(worstCaseCcuPerOutputToken(card, ["claude-haiku-4-5", "claude-unknown-9"], at), null);
  assert.equal(worstCaseCcuPerOutputToken(card, ["claude-haiku-4-5"], new Date("2026-10-10T00:00:00Z")), null);
  assert.equal(worstCaseCcuPerOutputToken(card, [], at), null);
});

test("the ceiling is the remaining budget's worth of tokens at the worst case, rounded down", () => {
  // 25,000 CCU / 0.0011 = 22,727,272.72... tokens.
  assert.equal(computeCeilingTokensFromCcu(new Decimal(25000), new Decimal("0.0011")), 22_727_272);
  assert.equal(computeCeilingTokensFromCcu(new Decimal("0.0005"), new Decimal("0.0011")), 0);
});

test("no remaining budget means a ceiling of zero", () => {
  assert.equal(computeCeilingTokensFromCcu(new Decimal(0), new Decimal("0.0011")), 0);
  assert.equal(computeCeilingTokensFromCcu(new Decimal("-12.5"), new Decimal("0.0011")), 0);
});

test("the ceiling never exceeds the largest integer the resolver accepts", () => {
  assert.equal(MAX_CEILING_TOKENS, 2_147_483_647);
  assert.equal(computeCeilingTokensFromCcu(new Decimal(250000), new Decimal("0.000001")), MAX_CEILING_TOKENS);
});

test("a non-positive worst case is refused: a free model cannot bound a ceiling", () => {
  assert.throws(() => computeCeilingTokensFromCcu(new Decimal(1), new Decimal(0)), /positive/);
});
