// The contract schedule (ADR-0005 decision 3, ADR-0011 decision 6): the
// customer's private-offer discount per model, with an effective interval
// and a record of who entered it, from which offer, and when. Discounts are
// "Applied as fewer CCUs metered" and a private offer "can carry different
// discount rates for different Claude models" (docs/MARKETPLACE-COST.md §1).
// The figures come only from configuration; an empty schedule means every
// amount is list price (U-18).

import { readFile } from "node:fs/promises";
import type { Decimal } from "decimal.js";
import { ContractScheduleError } from "./errors.ts";
import type { CostConfigErrorCode } from "./errors.ts";
import {
  DOCUMENT,
  assertNoOverlap,
  child,
  isInForce,
  readArray,
  readDecimalText,
  readFields,
  readInterval,
  readOptionalString,
  readOptionalStringList,
  readString,
  readUtcInstant,
} from "./config-fields.ts";
import type { EffectiveInterval } from "./config-fields.ts";
import { resolveModelKey } from "./rate-card.ts";
import type { RateCard } from "./rate-card.ts";

export interface ContractDiscount extends EffectiveInterval {
  model: string;
  modelKey: string;
  discount: Decimal;
  offerReference: string;
  recordedBy: string;
  recordedAt: string;
}

export interface ContractSchedule {
  version: string;
  entries: readonly ContractDiscount[];
}

const fail = (field: string, code: CostConfigErrorCode, detail: string) => new ContractScheduleError(field, code, detail);

export async function loadContractScheduleFile(path: string | URL, rateCard: RateCard): Promise<ContractSchedule> {
  return parseContractScheduleJson(await readFile(path, "utf8"), rateCard);
}

export function parseContractScheduleJson(text: string, rateCard: RateCard): ContractSchedule {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch (error) {
    throw fail(DOCUMENT, "invalid_json", `is not valid JSON: ${(error as Error).message}`);
  }
  return parseContractSchedule(value, rateCard);
}

// Validated against the rate card, so a discount cannot be recorded for a
// model that pricing would never match.
export function parseContractSchedule(value: unknown, rateCard: RateCard): ContractSchedule {
  const document = readFields(value, DOCUMENT, fail, ["schemaVersion", "version", "entries"], ["description", "notes"]);
  if (document.schemaVersion !== 1) throw fail("schemaVersion", "unsupported_schema_version", "must be 1");
  const version = readString(document.version, "version", fail);
  readOptionalString(document, "description", DOCUMENT, fail);
  readOptionalStringList(document, "notes", DOCUMENT, fail);
  const entries = readArray(document.entries, "entries", fail).map((raw, index) =>
    readDiscount(raw, child("entries", index), rateCard),
  );
  assertNoOverlap(
    entries.map((entry) => ({ key: entry.modelKey, interval: entry })),
    (index) => child("entries", index),
    fail,
  );
  return { version, entries };
}

// The discount in force for a rate-card model key at the instant, or null
// when the schedule records none (the row is then priced at list).
export function findDiscount(schedule: ContractSchedule, rateCardModelKey: string, at: Date): ContractDiscount | null {
  const atMs = at.getTime();
  if (Number.isNaN(atMs)) throw new RangeError("findDiscount needs a valid Date");
  return schedule.entries.find((entry) => entry.modelKey === rateCardModelKey && isInForce(entry, atMs)) ?? null;
}

function readDiscount(value: unknown, field: string, rateCard: RateCard): ContractDiscount {
  const entry = readFields(
    value,
    field,
    fail,
    ["model", "discount", "effectiveFrom", "effectiveTo", "offerReference", "recordedBy", "recordedAt"],
    ["notes"],
  );
  const modelField = child(field, "model");
  const model = readString(entry.model, modelField, fail);
  const key = resolveModelKey(rateCard, model);
  if (key === null) throw fail(modelField, "model_not_in_rate_card", `"${model}" has no entry in rate card ${rateCard.version}`);

  const discountField = child(field, "discount");
  const discount = readDecimalText(entry.discount, discountField, fail);
  if (discount.greaterThanOrEqualTo(1)) throw fail(discountField, "invalid_discount", "must be below 1 (a fraction such as \"0.10\")");

  readOptionalStringList(entry, "notes", field, fail);
  readUtcInstant(entry.recordedAt, child(field, "recordedAt"), fail);
  return {
    model,
    modelKey: key,
    discount,
    ...readInterval(entry, field, fail),
    offerReference: readString(entry.offerReference, child(field, "offerReference"), fail),
    recordedBy: readString(entry.recordedBy, child(field, "recordedBy"), fail),
    recordedAt: entry.recordedAt as string,
  };
}
