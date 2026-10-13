// Validity and freshness rules for registry records (ADR-0008). Pure functions
// of a record and the resolver's clock, so decide.ts can compose them and the
// tests can drive every boundary without a real clock.

import type { TokenLimit, TokenLimits, TokenQuotaPeriod } from "./decide.ts";

export interface BudgetStalenessPolicy {
  graceSeconds: number;
  hardLimitSeconds: number;
}

// docs/PILOT.md C-3: which budget the resolver enforces. token-limits-only
// reads no budget document; budget-state applies ADR-0008's staleness policy.
export type BudgetEnforcement =
  | { mode: "budget-state"; staleness: BudgetStalenessPolicy }
  | { mode: "token-limits-only" };

// ISO 8601 date-time with `Z` or a UTC offset. A date-time without a zone is
// refused because Date.parse reads it as local time, which differs per host.
const ZONED_DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;

export function parseZonedTimestamp(value: unknown): number | null {
  if (typeof value !== "string" || !ZONED_DATE_TIME.test(value)) return null;
  const epochMs = Date.parse(value);
  return Number.isFinite(epochMs) ? epochMs : null;
}

export type EntitlementVerdict =
  | { usable: true }
  | { usable: false; reason: "entitlement_record_invalid"; detail: RecordProblem }
  | { usable: false; reason: "entitlement_legacy_expired" };

// Detail codes for the log event, so an operator can tell which field a writer
// got wrong (reason codes only, never values).
export type RecordProblem =
  | "invalid_generation"
  | "invalid_last_verified_at"
  | "last_verified_at_in_future"
  | "memberships_not_array"
  | "invalid_expires_at";

export interface EntitlementFreshnessFields {
  generation?: unknown;
  lastVerifiedAt?: unknown;
  expiresAt?: unknown;
  projectMemberships?: unknown;
}

// Records persist until a sync changes them (reference ADR-0051), so age alone
// never makes a record unusable: a stopped sync must not deny anyone. Only a
// problem with this one record does. WP-SYNC can run this before each write.
export function checkEntitlementRecord(record: EntitlementFreshnessFields, nowMs: number): EntitlementVerdict {
  const invalid = (detail: RecordProblem): EntitlementVerdict => ({ usable: false, reason: "entitlement_record_invalid", detail });
  if (typeof record.generation !== "number" || !Number.isSafeInteger(record.generation) || record.generation < 0) {
    return invalid("invalid_generation");
  }
  const verifiedAt = parseZonedTimestamp(record.lastVerifiedAt);
  if (verifiedAt === null) return invalid("invalid_last_verified_at");
  if (verifiedAt > nowMs) return invalid("last_verified_at_in_future");
  if (!Array.isArray(record.projectMemberships)) return invalid("memberships_not_array");

  // Legacy lease from before ADR-0008. Ignoring a passed one would let records
  // left expired by an old writer grant access again (reference ADR-0051,
  // council round 1), so a passed lease reads as no record.
  if (record.expiresAt !== undefined && record.expiresAt !== null) {
    const expiresAt = parseZonedTimestamp(record.expiresAt);
    if (expiresAt === null) return invalid("invalid_expires_at");
    if (expiresAt < nowMs) return { usable: false, reason: "entitlement_legacy_expired" };
  }
  return { usable: true };
}

// The identifier patterns onboarding writes (WP-ONB) and the gateway checks
// (WP-GW), so every 200 passes the gateway's own validation.
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
const MODEL_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;

export type MembershipProblem =
  | "invalid_project_id"
  | "invalid_classification"
  | "invalid_backend_id"
  | "invalid_model_allow_list"
  | "invalid_aggregate_mode"
  | "invalid_token_limits";

export interface ValidMembership {
  projectId: string;
  classification: string;
  backendId: string;
  modelAllowList: string[];
  aggregateMode: "strict" | "notify";
  tokenLimits: TokenLimits;
}

export const isIdentifier = (value: unknown): value is string => typeof value === "string" && IDENTIFIER.test(value);

// Validates the fields the resolver returns or acts on, and returns a copy
// holding exactly those fields. WP-SYNC can run this before each write.
export function validateMembership(
  membership: Record<string, unknown>,
): { ok: true; value: ValidMembership } | { ok: false; detail: MembershipProblem } {
  const { projectId, classification, backendId, modelAllowList, aggregateMode } = membership;
  if (!isIdentifier(projectId)) return { ok: false, detail: "invalid_project_id" };
  if (!isIdentifier(classification)) return { ok: false, detail: "invalid_classification" };
  if (!isIdentifier(backendId)) return { ok: false, detail: "invalid_backend_id" };
  if (
    !Array.isArray(modelAllowList) ||
    modelAllowList.length === 0 ||
    !modelAllowList.every((model) => typeof model === "string" && MODEL_NAME.test(model))
  ) {
    return { ok: false, detail: "invalid_model_allow_list" };
  }
  // Anything but the two known modes is malformed, never "notify": reading it
  // as notify would silently skip the aggregate check.
  if (aggregateMode !== "strict" && aggregateMode !== "notify") return { ok: false, detail: "invalid_aggregate_mode" };
  const tokenLimits = parseTokenLimits(membership.tokenLimits);
  if (!tokenLimits) return { ok: false, detail: "invalid_token_limits" };
  return {
    ok: true,
    value: { projectId, classification, backendId, modelAllowList: [...modelAllowList], aggregateMode, tokenLimits },
  };
}

export type BudgetValidity = "fresh" | "stale_within_grace" | "stale_beyond_grace" | "stale" | "invalid";

// Lateness is measured from the record's own validUntil. Both bounds are
// inclusive: at exactly validUntil + grace the state is still within grace.
export function classifyBudgetValidity(validUntil: unknown, nowMs: number, policy: BudgetStalenessPolicy): BudgetValidity {
  const until = parseZonedTimestamp(validUntil);
  if (until === null) return "invalid";
  const lateMs = nowMs - until;
  if (lateMs <= 0) return "fresh";
  if (lateMs <= policy.graceSeconds * 1000) return "stale_within_grace";
  if (lateMs <= policy.hardLimitSeconds * 1000) return "stale_beyond_grace";
  return "stale";
}

// The periods llm-token-limit accepts (docs/PILOT.md C-2).
const TOKEN_QUOTA_PERIODS: readonly string[] = ["Hourly", "Daily", "Weekly", "Monthly", "Yearly"];

// APIM types tokens-per-minute as a 32-bit integer (WP-GW, U-35 measurement).
export const MAX_TOKENS_PER_MINUTE = 2147483647;

const isPositiveIntegerOrNull = (value: unknown): value is number | null =>
  value === null || (typeof value === "number" && Number.isSafeInteger(value) && value > 0);

function parseTokenLimit(value: unknown): TokenLimit | null {
  if (typeof value !== "object" || value === null) return null;
  const { tokensPerMinute, tokenQuota, tokenQuotaPeriod } = value as Record<string, unknown>;
  if (!isPositiveIntegerOrNull(tokensPerMinute) || !isPositiveIntegerOrNull(tokenQuota)) return null;
  if (tokensPerMinute !== null && tokensPerMinute > MAX_TOKENS_PER_MINUTE) return null;
  if (tokenQuotaPeriod !== null && !(typeof tokenQuotaPeriod === "string" && TOKEN_QUOTA_PERIODS.includes(tokenQuotaPeriod))) {
    return null;
  }
  // A quota without a period, or a period without a quota, cannot be applied.
  if ((tokenQuota === null) !== (tokenQuotaPeriod === null)) return null;
  return { tokensPerMinute, tokenQuota, tokenQuotaPeriod: tokenQuotaPeriod as TokenQuotaPeriod | null };
}

// Returns the limits with exactly the contract's fields, or null when the
// shape is invalid. Unknown extra fields are not copied to the gateway.
export function parseTokenLimits(value: unknown): TokenLimits | null {
  if (typeof value !== "object" || value === null) return null;
  const { person, group } = value as Record<string, unknown>;
  const personLimit = parseTokenLimit(person);
  const groupLimit = parseTokenLimit(group);
  return personLimit && groupLimit ? { person: personLimit, group: groupLimit } : null;
}
