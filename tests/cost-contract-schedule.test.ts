// RED-first tests for the contract schedule (ADR-0005 decision 3, ADR-0011
// decision 6): per-model private-offer discounts with effective intervals,
// validated against the rate card. The real file ships empty (U-18), which
// means every figure is list price. Discounts below are synthetic.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  findDiscount,
  loadContractScheduleFile,
  parseContractSchedule,
  parseContractScheduleJson,
} from "../src/cost/contract-schedule.ts";
import { loadRateCardFile } from "../src/cost/rate-card.ts";
import type { RateCard } from "../src/cost/rate-card.ts";
import { ContractScheduleError, CostConfigError } from "../src/cost/errors.ts";

const RATE_CARD_PATH = new URL("../config/rate-card.json", import.meta.url);
const SCHEDULE_PATH = new URL("../config/contract-schedule.json", import.meta.url);

let cardPromise: Promise<RateCard> | undefined;
function rateCard(): Promise<RateCard> {
  cardPromise ??= loadRateCardFile(RATE_CARD_PATH);
  return cardPromise;
}

function syntheticSchedule(): any {
  return {
    schemaVersion: 1,
    version: "test-1",
    description: "Synthetic schedule for unit tests.",
    entries: [syntheticDiscount("claude-sonnet-5", "0.10", "2026-10-01T00:00:00Z", null)],
  };
}

function syntheticDiscount(model: string, discount: unknown, effectiveFrom: string, effectiveTo: string | null): any {
  return {
    model,
    discount,
    effectiveFrom,
    effectiveTo,
    offerReference: "synthetic-offer-1",
    recordedBy: "finance-stage-test-at-example.test",
    recordedAt: "2026-10-11T09:00:00Z",
  };
}

function expectScheduleError(fn: () => unknown, code: string, field: string): void {
  let caught: unknown;
  try {
    fn();
  } catch (error) {
    caught = error;
  }
  assert.ok(caught instanceof ContractScheduleError, `expected a ContractScheduleError, got: ${String(caught)}`);
  assert.ok(caught instanceof CostConfigError);
  assert.equal(caught.name, "ContractScheduleError");
  assert.equal(caught.code, code, caught.message);
  assert.equal(caught.field, field, caught.message);
  assert.ok(caught.message.includes(field), `message should name the field: ${caught.message}`);
}

test("config/contract-schedule.json loads, is empty until the finance stage records an offer, and so discounts nothing", async () => {
  const card = await rateCard();
  const schedule = await loadContractScheduleFile(SCHEDULE_PATH, card);
  assert.ok(schedule.version.length > 0);
  assert.equal(schedule.entries.length, 0);
  for (const entry of card.entries) {
    assert.equal(findDiscount(schedule, entry.modelKey, new Date("2026-10-11T12:00:00Z")), null);
  }
});

test("findDiscount selects the discount in force at the timestamp, with half-open intervals, per model", async () => {
  const card = await rateCard();
  const raw = syntheticSchedule();
  raw.entries = [
    syntheticDiscount("claude-sonnet-5", "0.10", "2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z"),
    syntheticDiscount("claude-sonnet-5", "0.15", "2026-11-01T00:00:00Z", null),
    syntheticDiscount("claude-opus-5-5", "0.05", "2026-10-01T00:00:00Z", null),
  ];
  const schedule = parseContractSchedule(raw, card);
  const sonnet = card.entries.find((e) => e.model === "claude-sonnet-5");
  const haiku = card.entries.find((e) => e.model === "claude-haiku-4-5");
  assert.ok(sonnet && haiku);

  assert.equal(findDiscount(schedule, sonnet.modelKey, new Date("2026-10-31T23:59:59.999Z"))?.discount.toString(), "0.1");
  assert.equal(findDiscount(schedule, sonnet.modelKey, new Date("2026-11-01T00:00:00Z"))?.discount.toString(), "0.15");
  assert.equal(findDiscount(schedule, sonnet.modelKey, new Date("2026-09-30T00:00:00Z")), null);
  assert.equal(findDiscount(schedule, haiku.modelKey, new Date("2026-10-15T00:00:00Z")), null);
});

test("a discount entry records where it came from: offer reference, who recorded it and when", async () => {
  const schedule = parseContractSchedule(syntheticSchedule(), await rateCard());
  const [entry] = schedule.entries;
  assert.equal(entry.offerReference, "synthetic-offer-1");
  assert.equal(entry.recordedBy, "finance-stage-test-at-example.test");
  assert.equal(entry.recordedAt, "2026-10-11T09:00:00Z");
});

test("a schedule may name a model by a dated id; it resolves to the rate card's family", async () => {
  const card = await rateCard();
  const raw = syntheticSchedule();
  raw.entries = [syntheticDiscount("claude-haiku-4-5-20251001", "0.20", "2026-10-01T00:00:00Z", null)];
  const schedule = parseContractSchedule(raw, card);
  const haiku = card.entries.find((e) => e.model === "claude-haiku-4-5");
  assert.ok(haiku);
  assert.equal(findDiscount(schedule, haiku.modelKey, new Date("2026-10-15T00:00:00Z"))?.discount.toString(), "0.2");
});

test("a discount is at least 0 and below 1, written as a decimal string", async () => {
  const card = await rateCard();
  for (const tooLarge of ["1", "1.5"]) {
    const raw = syntheticSchedule();
    raw.entries[0].discount = tooLarge;
    expectScheduleError(() => parseContractSchedule(raw, card), "invalid_discount", "entries[0].discount");
  }
  for (const malformed of ["-0.1", 0.1, "10%", null]) {
    const raw = syntheticSchedule();
    raw.entries[0].discount = malformed;
    expectScheduleError(() => parseContractSchedule(raw, card), "invalid_value", "entries[0].discount");
  }
  const zero = syntheticSchedule();
  zero.entries[0].discount = "0";
  assert.equal(parseContractSchedule(zero, card).entries[0].discount.toString(), "0");
});

test("a discount for a model the rate card does not price is refused, naming the model field", async () => {
  const card = await rateCard();
  const raw = syntheticSchedule();
  raw.entries.push(syntheticDiscount("claude-sonet-5", "0.10", "2026-10-01T00:00:00Z", null));
  expectScheduleError(() => parseContractSchedule(raw, card), "model_not_in_rate_card", "entries[1].model");
});

test("overlapping discount intervals for one model are refused", async () => {
  const card = await rateCard();
  const raw = syntheticSchedule();
  raw.entries = [
    syntheticDiscount("claude-sonnet-5", "0.10", "2026-10-01T00:00:00Z", "2026-11-15T00:00:00Z"),
    syntheticDiscount("claude-sonnet-5", "0.15", "2026-11-01T00:00:00Z", null),
  ];
  expectScheduleError(() => parseContractSchedule(raw, card), "overlapping_interval", "entries[1].effectiveFrom");
});

test("unknown and missing fields are refused, naming the field", async () => {
  const card = await rateCard();
  const cases: Array<[(raw: any) => void, string, string]> = [
    [(raw) => { raw.currency = "USD"; }, "unknown_field", "currency"],
    [(raw) => { raw.entries[0].percent = 10; }, "unknown_field", "entries[0].percent"],
    [(raw) => { delete raw.version; }, "missing_field", "version"],
    [(raw) => { delete raw.entries[0].recordedBy; }, "missing_field", "entries[0].recordedBy"],
    [(raw) => { delete raw.entries[0].offerReference; }, "missing_field", "entries[0].offerReference"],
    [(raw) => { raw.entries[0].recordedAt = "2026-10-11"; }, "invalid_value", "entries[0].recordedAt"],
    [(raw) => { raw.entries[0].effectiveFrom = "2026-10-01T00:00:00+01:00"; }, "invalid_value", "entries[0].effectiveFrom"],
    [(raw) => { raw.entries[0].effectiveTo = "2026-09-01T00:00:00Z"; }, "invalid_interval", "entries[0].effectiveTo"],
    [(raw) => { raw.entries = {}; }, "invalid_value", "entries"],
    [(raw) => { raw.schemaVersion = 2; }, "unsupported_schema_version", "schemaVersion"],
  ];
  for (const [mutate, code, field] of cases) {
    const raw = syntheticSchedule();
    mutate(raw);
    expectScheduleError(() => parseContractSchedule(raw, card), code, field);
  }
});

test("text that is not JSON is refused as a contract schedule", async () => {
  const card = await rateCard();
  expectScheduleError(() => parseContractScheduleJson("[", card), "invalid_json", "(document)");
  expectScheduleError(() => parseContractSchedule("discounts", card), "invalid_value", "(document)");
});
