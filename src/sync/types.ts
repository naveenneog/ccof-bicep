// The `entitlement` record the sync writes (docs/PILOT.md C-4).
//
// Mirror of `EntitlementRecord` and `ProjectMembership` in
// src/resolver/decide.ts on branch wp/res (ADR-0008: `generation`,
// `lastVerifiedAt`, no `expiresAt` written), plus `tokenLimits` (C-2) and an
// optional `subscriptionId` (C-4). Once wp/res merges to main, these types are
// replaced by the resolver's own, with a compile-time compatibility check.

export const TOKEN_QUOTA_PERIODS = ["Hourly", "Daily", "Weekly", "Monthly", "Yearly"] as const;
export type TokenQuotaPeriod = (typeof TOKEN_QUOTA_PERIODS)[number];

export interface TokenLimit {
  tokensPerMinute: number | null;
  tokenQuota: number | null;
  tokenQuotaPeriod: TokenQuotaPeriod | null;
}

export interface TokenLimits {
  person: TokenLimit;
  group: TokenLimit;
}

export type AggregateMode = "strict" | "notify";

export interface ProjectMembership {
  projectId: string;
  classification: string;
  classificationGroupId: string;
  subscriptionId?: string;
  modelAllowList: string[];
  backendId: string;
  aggregateMode: AggregateMode;
  tokenLimits: TokenLimits;
  denormalizedAt: string;
  joinedAt: string;
  status: string;
}

export interface EntitlementRecord {
  id: string;
  personId: string;
  projectMemberships: ProjectMembership[];
  generation: number;
  lastVerifiedAt: string;
  // Legacy lease from before ADR-0008. Never set by the sync; an existing one
  // still in the future is kept only while an unverified membership is carried
  // over, so the sync never extends access past it without directory evidence.
  expiresAt?: string;
}

export const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

// ISO 8601 date-time with `Z` or an offset: the form the resolver accepts
// (src/resolver/freshness.ts on wp/res). A zone-less value is local time.
const ZONED_DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;

export function parseZonedTimestamp(value: unknown): number | null {
  if (typeof value !== "string" || !ZONED_DATE_TIME.test(value)) return null;
  const epochMs = Date.parse(value);
  return Number.isFinite(epochMs) ? epochMs : null;
}
