import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { Money } from "../../src/cost/money.ts";
import { ccuToUsd, usdToCcu } from "../../src/cost/budget-units.ts";
import { ccuToUsdText, rateForDisplay, rateFromDisplay, shiftDecimal, usdToCcuText } from "../src/units.ts";

test("USD and CCU conversions are exact decimal-point shifts (100 CCU = USD 1)", () => {
  assert.equal(usdToCcuText("3"), "300");
  assert.equal(usdToCcuText("0.125"), "12.5");
  assert.equal(usdToCcuText("0.001"), "0.1");
  assert.equal(ccuToUsdText("12.5"), "0.125");
  assert.equal(ccuToUsdText("1"), "0.01");
  assert.equal(ccuToUsdText("0"), "0");
  assert.equal(shiftDecimal("000.5000", 0), "0.5");
  assert.equal(usdToCcuText("12345678901234567890.123456789012345678"), "1234567890123456789012.3456789012345678");
  assert.throws(() => usdToCcuText("1e3"), /decimal_text_required/);
  assert.throws(() => usdToCcuText("-1"), /decimal_text_required/);
});

test("conversions agree with the cost module's decimal arithmetic on many values", () => {
  let seed = 7;
  const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  for (let i = 0; i < 500; i++) {
    const v = `${Math.floor(rnd() * 100000)}.${String(Math.floor(rnd() * 1e9)).padStart(9, "0")}`;
    assert.equal(usdToCcuText(v), usdToCcu(v).toFixed(), v);
    assert.equal(ccuToUsdText(v), ccuToUsd(v).toFixed(), v);
    assert.ok(new Money(ccuToUsdText(usdToCcuText(v))).eq(new Money(v)), "round trip is lossless");
  }
});

test("rate card rates display and edit per million tokens in either unit, stored canonical USD", async () => {
  const card = JSON.parse(await readFile(new URL("../../config/rate-card.json", import.meta.url), "utf8"));
  for (const entry of card.entries) for (const tier of entry.promptTiers) for (const [, rate] of Object.entries(tier.rates) as [string, string][]) {
    const usd = rateForDisplay(rate, card.rateUnit.perTokens, "USD");
    const ccu = rateForDisplay(rate, card.rateUnit.perTokens, "CCU");
    assert.ok(new Money(ccu).eq(new Money(rate).times(100)));
    assert.ok(new Money(rateFromDisplay(ccu, card.rateUnit.perTokens, "CCU")).eq(new Money(rate)));
    assert.ok(new Money(rateFromDisplay(usd, card.rateUnit.perTokens, "USD")).eq(new Money(rate)));
  }
  // A card stored per 1,000 tokens still shows per million tokens.
  assert.equal(rateForDisplay("0.003", 1000, "USD"), "3");
  assert.equal(rateForDisplay("0.003", 1000, "CCU"), "300");
  assert.equal(rateFromDisplay("300", 1000, "CCU"), "0.003");
  assert.throws(() => rateForDisplay("1", 3000, "USD"), /perTokens_power_of_ten_required/);
});
