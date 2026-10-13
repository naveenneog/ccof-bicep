// RED-first tests for budget units (ADR-0011 decision 9). A budget carries its
// own unit in `currency`, "CCU" or "USD", chosen by the administrator (owner,
// 2026-10-11); there is no default. The CCU definition is the one constant:
// 100 CCU = USD 1.00 (Anthropic pricing page, retrieved 2026-10-11).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  CCU_PER_USD,
  budgetInBothUnits,
  ccuToUsd,
  parseBudget,
  parseOptionalBudget,
  usdToCcu,
} from "../src/cost/budget-units.ts";
import { BudgetConfigError, CostConfigError } from "../src/cost/errors.ts";

const FIELD = "classifications.STD.personBudget";

function expectBudgetError(fn: () => unknown, code: string, field: string): void {
  let caught: unknown;
  try {
    fn();
  } catch (error) {
    caught = error;
  }
  assert.ok(caught instanceof BudgetConfigError, `expected a BudgetConfigError, got: ${String(caught)}`);
  assert.ok(caught instanceof CostConfigError);
  assert.equal(caught.name, "BudgetConfigError");
  assert.equal(caught.code, code, caught.message);
  assert.equal(caught.field, field, caught.message);
  assert.ok(caught.message.includes(field), `message should name the field: ${caught.message}`);
}

test("100 CCU is USD 1.00, and conversion is exact in both directions", () => {
  assert.ok(CCU_PER_USD.equals(100));
  assert.equal(usdToCcu("1").toString(), "100");
  assert.equal(usdToCcu("0.02565").toString(), "2.565");
  assert.equal(ccuToUsd("2.565").toString(), "0.02565");
  assert.equal(ccuToUsd(usdToCcu("0.000000099")).toString(), "9.9e-8");
  assert.ok(usdToCcu("0.1").plus(usdToCcu("0.2")).equals(usdToCcu("0.3")));
});

test("a budget set in CCU is shown with its USD equivalent", () => {
  const budget = parseBudget({ amount: 25000, currency: "CCU", period: "monthly" }, FIELD);
  assert.equal(budget.currency, "CCU");
  assert.equal(budget.period, "monthly");
  const both = budgetInBothUnits(budget);
  assert.equal(both.ccu.toString(), "25000");
  assert.equal(both.usd.toString(), "250");
});

test("a budget set in USD is shown with its CCU equivalent, and amounts may be decimal strings", () => {
  const usd = budgetInBothUnits(parseBudget({ amount: 250, currency: "USD", period: "monthly" }, FIELD));
  assert.equal(usd.ccu.toString(), "25000");
  assert.equal(usd.usd.toString(), "250");
  const text = budgetInBothUnits(parseBudget({ amount: "250.50", currency: "USD", period: "monthly" }, FIELD));
  assert.equal(text.ccu.toString(), "25050");
  const zero = budgetInBothUnits(parseBudget({ amount: 0, currency: "CCU", period: "monthly" }, FIELD));
  assert.ok(zero.usd.isZero());
});

test("there is no default unit: a missing currency is refused, naming the field", () => {
  expectBudgetError(() => parseBudget({ amount: 25000, period: "monthly" }, FIELD), "missing_field", `${FIELD}.currency`);
});

test("only CCU and USD are budget units, written exactly", () => {
  for (const currency of ["EUR", "ccu", "usd", "", 100, null]) {
    expectBudgetError(
      () => parseBudget({ amount: 25000, currency, period: "monthly" }, FIELD),
      "invalid_value",
      `${FIELD}.currency`,
    );
  }
});

test("a budget amount is a non-negative number or decimal string", () => {
  for (const amount of [-1, "-1", "abc", "1e3", Number.NaN, Number.POSITIVE_INFINITY, null, true]) {
    expectBudgetError(() => parseBudget({ amount, currency: "CCU", period: "monthly" }, FIELD), "invalid_value", `${FIELD}.amount`);
  }
  expectBudgetError(() => parseBudget({ currency: "CCU", period: "monthly" }, FIELD), "missing_field", `${FIELD}.amount`);
});

test("the budget period is monthly and must be stated", () => {
  expectBudgetError(() => parseBudget({ amount: 1, currency: "CCU", period: "weekly" }, FIELD), "invalid_value", `${FIELD}.period`);
  expectBudgetError(() => parseBudget({ amount: 1, currency: "CCU" }, FIELD), "missing_field", `${FIELD}.period`);
});

test("a field named 'unit' is refused: the schema's unit field is 'currency' (agreed with WP-ONB)", () => {
  expectBudgetError(
    () => parseBudget({ amount: 1, currency: "CCU", unit: "CCU", period: "monthly" }, FIELD),
    "unknown_field",
    `${FIELD}.unit`,
  );
  expectBudgetError(() => parseBudget("25000 CCU", FIELD), "invalid_value", FIELD);
});

test("an aggregate budget may be explicitly null (no cap), but not absent", () => {
  const field = "classifications.CYB.aggregateBudget";
  assert.equal(parseOptionalBudget(null, field), null);
  expectBudgetError(() => parseOptionalBudget(undefined, field), "missing_field", field);
  assert.equal(parseOptionalBudget({ amount: 10, currency: "USD", period: "monthly" }, field)?.amount.toString(), "10");
});

test("the projects example in docs/LLD.md validates, in CCU, with the USD figures it replaced", async () => {
  const lld = await readFile(new URL("../docs/LLD.md", import.meta.url), "utf8");
  const section = lld.indexOf("### `projects`");
  assert.ok(section >= 0, "docs/LLD.md has a `projects` section");
  const block = /```json\r?\n([\s\S]*?)\r?\n```/.exec(lld.slice(section));
  assert.ok(block, "the `projects` section has a JSON example");
  const project = JSON.parse(block[1]);

  const expectedUsd: Record<string, [string, string | null]> = {
    STD: ["250", "20000"],
    PRM: ["1000", "15000"],
    CYB: ["2500", null],
  };
  for (const [classification, [personUsd, aggregateUsd]] of Object.entries(expectedUsd)) {
    const base = `classifications.${classification}`;
    const person = parseBudget(project.classifications[classification].personBudget, `${base}.personBudget`);
    assert.equal(person.currency, "CCU");
    assert.equal(budgetInBothUnits(person).usd.toString(), personUsd);
    const aggregate = parseOptionalBudget(project.classifications[classification].aggregateBudget, `${base}.aggregateBudget`);
    assert.equal(aggregate === null ? null : budgetInBothUnits(aggregate).usd.toString(), aggregateUsd);
  }
});
