// Field readers shared by the cost configuration parsers (rate card, contract
// schedule, budgets). Each reader validates one JSON value and, on failure,
// throws the caller's named error with the field's path, so every refusal
// says which configuration field is missing or invalid (ADR-0011 decision 2).

import type { Decimal } from "decimal.js";
import { Money } from "./money.ts";
import type { CostConfigError, CostConfigErrorCode } from "./errors.ts";

export type Fail = (field: string, code: CostConfigErrorCode, detail: string) => CostConfigError;

export const DOCUMENT = "(document)";

export function child(parent: string, key: string | number): string {
  const base = parent === DOCUMENT ? "" : parent;
  if (typeof key === "number") return `${base}[${key}]`;
  return base === "" ? key : `${base}.${key}`;
}

export function readObject(value: unknown, field: string, fail: Fail): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw fail(field, "invalid_value", "must be a JSON object");
  }
  return value as Record<string, unknown>;
}

// An object whose keys are exactly the required ones plus any optional ones.
export function readFields(
  value: unknown,
  field: string,
  fail: Fail,
  required: readonly string[],
  optional: readonly string[] = [],
): Record<string, unknown> {
  const object = readObject(value, field, fail);
  for (const key of Object.keys(object)) {
    if (!required.includes(key) && !optional.includes(key)) {
      throw fail(child(field, key), "unknown_field", "is not a recognised field");
    }
  }
  for (const key of required) {
    if (!Object.hasOwn(object, key)) throw fail(child(field, key), "missing_field", "is required");
  }
  return object;
}

export function readArray(value: unknown, field: string, fail: Fail): unknown[] {
  if (!Array.isArray(value)) throw fail(field, "invalid_value", "must be a JSON array");
  return value;
}

export function readString(value: unknown, field: string, fail: Fail): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw fail(field, "invalid_value", "must be a non-empty string");
  }
  return value;
}

export function readOptionalString(object: Record<string, unknown>, key: string, field: string, fail: Fail): string | null {
  return object[key] === undefined ? null : readString(object[key], child(field, key), fail);
}

export function readOptionalStringList(object: Record<string, unknown>, key: string, field: string, fail: Fail): string[] {
  if (object[key] === undefined) return [];
  return readArray(object[key], child(field, key), fail).map((item, i) => readString(item, child(child(field, key), i), fail));
}

const DECIMAL_TEXT = /^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/;

// Money values are decimal strings, never JSON numbers, so no value passes
// through binary floating point on its way in.
export function readDecimalText(value: unknown, field: string, fail: Fail): Decimal {
  if (typeof value !== "string" || !DECIMAL_TEXT.test(value)) {
    throw fail(field, "invalid_value", 'must be a non-negative decimal string such as "2.50"');
  }
  return new Money(value);
}

export function readPositiveInteger(value: unknown, field: string, fail: Fail): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw fail(field, "invalid_value", "must be a positive whole number");
  }
  return value;
}

const UTC_INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;

// A UTC instant written with a Z suffix; returns epoch milliseconds.
export function readUtcInstant(value: unknown, field: string, fail: Fail): number {
  if (typeof value !== "string" || !UTC_INSTANT.test(value)) {
    throw fail(field, "invalid_value", 'must be a UTC instant such as "2026-10-11T00:00:00Z"');
  }
  const ms = Date.parse(value);
  if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 19) !== value.slice(0, 19)) {
    throw fail(field, "invalid_value", "is not a real calendar instant");
  }
  return ms;
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

export function readIsoDate(value: unknown, field: string, fail: Fail): string {
  if (typeof value !== "string" || !ISO_DATE.test(value)) {
    throw fail(field, "invalid_value", 'must be a date such as "2026-10-11"');
  }
  const ms = Date.parse(`${value}T00:00:00Z`);
  if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== value) {
    throw fail(field, "invalid_value", "is not a real calendar date");
  }
  return value;
}

export function readHttpsUrl(value: unknown, field: string, fail: Fail): string {
  const text = readString(value, field, fail);
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    throw fail(field, "invalid_value", "must be an https URL");
  }
  if (url.protocol !== "https:") throw fail(field, "invalid_value", "must be an https URL");
  return text;
}

export interface EffectiveInterval {
  effectiveFrom: string;
  effectiveTo: string | null;
  fromMs: number;
  toMs: number | null;
}

// Half-open [effectiveFrom, effectiveTo); effectiveTo null means open-ended.
export function readInterval(object: Record<string, unknown>, field: string, fail: Fail): EffectiveInterval {
  const fromMs = readUtcInstant(object.effectiveFrom, child(field, "effectiveFrom"), fail);
  const toField = child(field, "effectiveTo");
  const toMs = object.effectiveTo === null ? null : readUtcInstant(object.effectiveTo, toField, fail);
  if (toMs !== null && toMs <= fromMs) throw fail(toField, "invalid_interval", "must be later than effectiveFrom");
  return {
    effectiveFrom: object.effectiveFrom as string,
    effectiveTo: toMs === null ? null : (object.effectiveTo as string),
    fromMs,
    toMs,
  };
}

export function isInForce(interval: EffectiveInterval, atMs: number): boolean {
  return interval.fromMs <= atMs && (interval.toMs === null || atMs < interval.toMs);
}

// Refuses two intervals with the same key that share any instant. The field
// named is the effectiveFrom of the later-starting interval of the pair.
export function assertNoOverlap(
  items: ReadonlyArray<{ key: string; interval: EffectiveInterval }>,
  fieldOf: (index: number) => string,
  fail: Fail,
): void {
  const order = items.map((item, index) => ({ ...item, index }));
  order.sort((a, b) => (a.key === b.key ? a.interval.fromMs - b.interval.fromMs : a.key < b.key ? -1 : 1));
  for (let i = 1; i < order.length; i += 1) {
    const previous = order[i - 1];
    const current = order[i];
    if (previous.key !== current.key) continue;
    if (previous.interval.toMs === null || previous.interval.toMs > current.interval.fromMs) {
      throw fail(
        child(fieldOf(current.index), "effectiveFrom"),
        "overlapping_interval",
        `overlaps ${fieldOf(previous.index)} for the same model`,
      );
    }
  }
}
