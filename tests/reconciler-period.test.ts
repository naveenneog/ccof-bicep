// The budget period (docs/PILOT.md C-7, ADR-0018 D-1): the UTC calendar month
// that contains the run's clock reading, half-open.

import { test } from "node:test";
import assert from "node:assert/strict";
import { budgetPeriodAt, isInPeriod } from "../src/reconciler/period.ts";

test("a mid-month instant belongs to that UTC month, labelled YYYY-MM, half-open", () => {
  const period = budgetPeriodAt(new Date("2026-10-11T13:05:00.123Z"));
  assert.equal(period.label, "2026-10");
  assert.equal(period.start.toISOString(), "2026-10-01T00:00:00.000Z");
  assert.equal(period.end.toISOString(), "2026-11-01T00:00:00.000Z");
});

test("the first instant of a month starts the new period; the last millisecond belongs to the old one", () => {
  assert.equal(budgetPeriodAt(new Date("2026-11-01T00:00:00.000Z")).label, "2026-11");
  assert.equal(budgetPeriodAt(new Date("2026-10-31T23:59:59.999Z")).label, "2026-10");
});

test("the period is UTC, not the host's local time zone: 05:29 IST on the 1st is still the previous UTC month", () => {
  // 2026-11-01T05:29:00+05:30 is 2026-10-31T23:59:00Z.
  assert.equal(budgetPeriodAt(new Date("2026-11-01T05:29:00+05:30")).label, "2026-10");
});

test("December rolls over to January of the next year, and months are zero-padded", () => {
  const december = budgetPeriodAt(new Date("2026-12-31T23:00:00Z"));
  assert.equal(december.label, "2026-12");
  assert.equal(december.end.toISOString(), "2027-01-01T00:00:00.000Z");
  assert.equal(budgetPeriodAt(new Date("2027-02-14T00:00:00Z")).label, "2027-02");
});

test("isInPeriod includes the start instant and excludes the end instant", () => {
  const period = budgetPeriodAt(new Date("2026-10-11T00:00:00Z"));
  assert.equal(isInPeriod(period, new Date("2026-10-01T00:00:00.000Z")), true);
  assert.equal(isInPeriod(period, new Date("2026-10-31T23:59:59.999Z")), true);
  assert.equal(isInPeriod(period, new Date("2026-11-01T00:00:00.000Z")), false);
  assert.equal(isInPeriod(period, new Date("2026-09-30T23:59:59.999Z")), false);
});

test("an invalid clock reading is refused, never mapped to a period", () => {
  assert.throws(() => budgetPeriodAt(new Date(Number.NaN)), RangeError);
});
