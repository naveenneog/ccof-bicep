// Validation of a ledger row handed to pricing (ADR-0011 decision 7). A
// malformed row (wrong types, negative or fractional counts, a time without
// a UTC zone) is refused with a UsageRowError naming the field. A token count
// that was not captured is null: that is a pricing outcome, not an error.

import { UsageRowError } from "./errors.ts";
import { TOKEN_CATEGORIES, isTokenCategory } from "./token-categories.ts";
import type { TokenCategory } from "./token-categories.ts";

export interface UsageToPrice {
  // When the request was served: a Date, or a UTC instant with a Z suffix
  // (Log Analytics writes up to seven fractional digits).
  requestTime: Date | string;
  // The served model's name; dated names such as claude-haiku-4-5-20251001
  // match their family (ADR-0011 decision 3).
  model: string;
  // The request's inference geography, or null when it is not known.
  inferenceGeo: string | null;
  // All five categories, each a count or null when it was not captured.
  tokens: Readonly<Record<TokenCategory, number | null>>;
  // Uses of features charged beyond tokens, by name (for example web search
  // requests); absent or zero means none.
  features?: Readonly<Record<string, number>>;
}

export interface ValidUsage {
  at: Date;
  model: string;
  inferenceGeo: string | null;
  tokens: Readonly<Record<TokenCategory, number | null>>;
  features: ReadonlyArray<readonly [string, number]>;
}

const UTC_INSTANT = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$/;

export function validateUsage(row: UsageToPrice): ValidUsage {
  if (typeof row !== "object" || row === null) throw new UsageRowError("(row)", "must be an object");
  if (typeof row.model !== "string" || row.model.trim() === "") throw new UsageRowError("model", "must be a non-empty string");
  if (row.inferenceGeo !== null && typeof row.inferenceGeo !== "string") {
    throw new UsageRowError("inferenceGeo", "must be a string, or null when not known");
  }
  return {
    at: readRequestTime(row.requestTime),
    model: row.model,
    inferenceGeo: row.inferenceGeo,
    tokens: readTokens(row.tokens),
    features: readFeatures(row.features),
  };
}

function readRequestTime(value: unknown): Date {
  if (value instanceof Date) {
    if (Number.isNaN(value.getTime())) throw new UsageRowError("requestTime", "is not a valid date");
    return value;
  }
  const match = typeof value === "string" ? UTC_INSTANT.exec(value) : null;
  if (match === null) throw new UsageRowError("requestTime", 'must be a UTC instant such as "2026-10-11T09:30:00Z"');
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  const milliseconds = Number((match[7] ?? "").padEnd(3, "0").slice(0, 3));
  const at = new Date(Date.UTC(year, month - 1, day, hour, minute, second, milliseconds));
  const roundTrips =
    at.getUTCFullYear() === year && at.getUTCMonth() === month - 1 && at.getUTCDate() === day &&
    at.getUTCHours() === hour && at.getUTCMinutes() === minute && at.getUTCSeconds() === second;
  if (!roundTrips) throw new UsageRowError("requestTime", "is not a real calendar instant");
  return at;
}

function readTokens(value: unknown): Record<TokenCategory, number | null> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new UsageRowError("tokens", "must be an object with the five token categories");
  }
  const tokens = value as Record<string, unknown>;
  for (const key of Object.keys(tokens)) {
    if (!isTokenCategory(key)) throw new UsageRowError(fieldPath("tokens", key), "is not one of the five token categories");
  }
  const counts = {} as Record<TokenCategory, number | null>;
  let total = 0;
  for (const category of TOKEN_CATEGORIES) {
    const field = `tokens.${category}`;
    if (!Object.hasOwn(tokens, category)) throw new UsageRowError(field, "is required; use null when it was not captured");
    const count = tokens[category];
    if (count !== null && !isCount(count)) throw new UsageRowError(field, "must be a non-negative whole number or null");
    counts[category] = count;
    total += count ?? 0;
  }
  if (!Number.isSafeInteger(total)) throw new UsageRowError("tokens", "add up to more than a safe whole number");
  return counts;
}

function readFeatures(value: unknown): Array<[string, number]> {
  if (value === undefined) return [];
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new UsageRowError("features", "must be an object of counts by feature name");
  }
  return Object.entries(value as Record<string, unknown>).map(([name, count]) => {
    if (!isCount(count)) throw new UsageRowError(fieldPath("features", name), "must be a non-negative whole number");
    return [name, count];
  });
}

// A key taken from the row, written so that it cannot break a log line.
function fieldPath(parent: string, key: string): string {
  return /^[A-Za-z0-9_]+$/.test(key) ? `${parent}.${key}` : `${parent}[${JSON.stringify(key)}]`;
}

function isCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}
