// The entitlement projection uses the same pure policy contract as the resolver.
import type { FamilyPolicy } from "../contracts/model-families.ts";

export type AggregateMode = "strict" | "notify";

export interface ProjectMembership {
  projectId: string;
  classification: string;
  classificationGroupId: string;
  subscriptionId?: string;
  classificationGroupDisplayName?: string;
  familyPolicy: FamilyPolicy;
  backendId: string;
  aggregateMode: AggregateMode;
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
