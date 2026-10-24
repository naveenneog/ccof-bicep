// Removal limits set from the admin console (admin/src/sync-limits.ts writes the document).
// The sync's app settings (SYNC_MAX_REMOVALS_PER_RUN, SYNC_MAX_REMOVAL_FRACTION) stay the default.
// An override applies only while it is enabled, valid and not expired; anything else, including a
// read failure, falls back to the app settings. Never more permissive by accident: a malformed or
// unreadable document cannot raise the limits.

import type { RemovalLimits } from "./plan-types.ts";

export const REMOVAL_LIMITS_DOCUMENT_ID = "syncRemovalLimits";
export const MAX_REMOVALS_CEILING = 10_000_000;
// At most six decimal places, so the removal check can run in integers (same rule as config.ts).
export const FRACTION_TEXT = /^(0(\.\d{1,6})?|1(\.0{1,6})?)$/;
const UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;

export type LimitsSource = "settings" | "admin";
export interface EffectiveLimits {
  limits: RemovalLimits;
  source: LimitsSource;
  // Why the override was not used: absent, disabled, expired, invalid or unreadable.
  reason: string | null;
  expiresAt: string | null;
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

// Problems as field codes, shared with the admin API so the console cannot save what the sync would ignore.
export function removalLimitsProblems(doc: unknown): string[] {
  if (!isObject(doc)) return ["document:not_an_object"];
  const problems: string[] = [];
  if (doc.schemaVersion !== 1) problems.push("schemaVersion:invalid");
  if (typeof doc.enabled !== "boolean") problems.push("enabled:invalid");
  const n = doc.maxRemovalsPerRun;
  if (typeof n !== "number" || !Number.isSafeInteger(n) || n < 0 || n > MAX_REMOVALS_CEILING) problems.push("maxRemovalsPerRun:invalid");
  if (typeof doc.maxRemovalFraction !== "string" || !FRACTION_TEXT.test(doc.maxRemovalFraction)) problems.push("maxRemovalFraction:invalid");
  if (doc.expiresAt !== null && (typeof doc.expiresAt !== "string" || !UTC.test(doc.expiresAt) || !Number.isFinite(Date.parse(doc.expiresAt)))) {
    problems.push("expiresAt:invalid");
  }
  if (typeof doc.reason !== "string" || !doc.reason.trim() || doc.reason.length > 200) problems.push("reason:invalid");
  return problems;
}

export function effectiveRemovalLimits(settings: RemovalLimits, read: { ok: true; doc: unknown | null } | { ok: false }, now: Date): EffectiveLimits {
  const fallback = (reason: string, expiresAt: string | null = null): EffectiveLimits => ({ limits: settings, source: "settings", reason, expiresAt });
  if (!read.ok) return fallback("override_unreadable");
  if (read.doc === null) return fallback("override_absent");
  if (removalLimitsProblems(read.doc).length > 0) return fallback("override_invalid");
  const doc = read.doc as { enabled: boolean; maxRemovalsPerRun: number; maxRemovalFraction: string; expiresAt: string | null };
  if (!doc.enabled) return fallback("override_disabled");
  if (doc.expiresAt !== null && Date.parse(doc.expiresAt) <= now.getTime()) return fallback("override_expired", doc.expiresAt);
  return {
    limits: { maxRemovalsPerRun: doc.maxRemovalsPerRun, maxRemovalFraction: Number(doc.maxRemovalFraction) },
    source: "admin", reason: null, expiresAt: doc.expiresAt,
  };
}
