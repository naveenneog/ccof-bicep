// Building and comparing memberships, and reading what an existing
// `entitlement` document holds. Used by the planner (plan.ts).

import type { ClassificationRegistration } from "./projects.ts";
import type { ExistingEntitlement } from "./plan-types.ts";
import type { ProjectMembership } from "./types.ts";
import { parseZonedTimestamp } from "./types.ts";

export type RawMembership = Record<string, unknown>;

export interface ParsedExisting {
  personId: string;
  etag: string;
  // As stored: what an unchanged plan must equal.
  memberships: RawMembership[];
  // What the resolver would serve today. Empty when the record grants nothing
  // (a passed or unreadable legacy expiresAt, or a record it refuses): the
  // sync never carries such memberships forward without directory evidence.
  effective: RawMembership[];
  generation: number | null;
  // Problems that make the resolver refuse the record (ADR-0008 decision 2).
  problems: string[];
  legacyExpiry: boolean;
  // A legacy expiresAt still in the future, kept while an unverified
  // membership is carried over.
  liveExpiresAt: string | null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

const GUID_ID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

// JSON with object keys sorted, so two documents compare equal whatever order
// their fields were stored in.
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (isObject(value)) {
    const keys = Object.keys(value).filter((k) => value[k] !== undefined).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

// Reads one stored document. Returns null for a document the sync does not
// own: its id must be an Entra object id (GUID) equal to its personId, the key
// the resolver point-reads.
export function parseExisting(entry: ExistingEntitlement, nowMs: number): ParsedExisting | null {
  const { doc, etag } = entry;
  if (typeof doc.id !== "string" || !GUID_ID.test(doc.id) || doc.id !== doc.personId) return null;
  const problems: string[] = [];
  const generation = typeof doc.generation === "number" && Number.isSafeInteger(doc.generation) && doc.generation >= 0 ? doc.generation : null;
  if (generation === null) problems.push("generation:invalid");
  const verifiedAt = parseZonedTimestamp(doc.lastVerifiedAt);
  if (verifiedAt === null) problems.push("lastVerifiedAt:invalid");
  else if (verifiedAt > nowMs) problems.push("lastVerifiedAt:in_future");
  let memberships: RawMembership[] = [];
  if (Array.isArray(doc.projectMemberships)) {
    memberships = doc.projectMemberships.filter(isObject);
    if (memberships.length !== doc.projectMemberships.length) problems.push("projectMemberships:invalid");
    const activeProjects = memberships.filter(isActive).map((m) => m.projectId);
    if (new Set(activeProjects).size !== activeProjects.length) problems.push("projectMemberships:duplicate_active_project");
  } else {
    problems.push("projectMemberships:invalid");
  }
  const legacyExpiry = doc.expiresAt !== undefined && doc.expiresAt !== null;
  const expiresAt = legacyExpiry ? parseZonedTimestamp(doc.expiresAt) : null;
  const expired = legacyExpiry && (expiresAt === null || expiresAt < nowMs);
  const grantsNothing = expired || problems.length > 0;
  return {
    personId: doc.id,
    etag,
    memberships,
    effective: grantsNothing ? [] : memberships,
    generation,
    problems,
    legacyExpiry,
    liveExpiresAt: legacyExpiry && !expired ? (doc.expiresAt as string) : null,
  };
}

export function isActive(m: RawMembership): m is RawMembership & { projectId: string } {
  return typeof m.projectId === "string" && m.status === "active";
}

// The fields copied from `projects` (C-4), in the stored order.
function copiedFields(reg: ClassificationRegistration) {
  return {
    projectId: reg.projectId,
    classification: reg.classification,
    classificationGroupId: reg.groupId,
    modelAllowList: [...reg.modelAllowList],
    backendId: reg.backendId,
    aggregateMode: reg.aggregateMode,
    tokenLimits: reg.tokenLimits,
  };
}

const COPIED_KEYS = ["projectId", "classification", "classificationGroupId", "modelAllowList", "backendId", "aggregateMode", "tokenLimits", "status"];

function sameCopiedFields(prior: RawMembership, reg: ClassificationRegistration): boolean {
  const stored = Object.fromEntries(COPIED_KEYS.map((k) => [k, prior[k]]));
  return canonical(stored) === canonical({ ...copiedFields(reg), status: "active" });
}

// The membership for one registration. `prior` is the person's existing
// active membership of the same project and classification, if any: its
// joinedAt is kept, and so is its denormalizedAt when nothing copied changed.
export function buildMembership(reg: ClassificationRegistration, prior: RawMembership | undefined, nowIso: string): ProjectMembership {
  const unchanged = prior !== undefined && sameCopiedFields(prior, reg);
  const membership: ProjectMembership = {
    ...copiedFields(reg),
    denormalizedAt: unchanged && parseZonedTimestamp(prior.denormalizedAt) !== null ? (prior.denormalizedAt as string) : nowIso,
    joinedAt: prior !== undefined && parseZonedTimestamp(prior.joinedAt) !== null ? (prior.joinedAt as string) : nowIso,
    status: "active",
  };
  // C-4: optional; kept when a key path still refers to this membership.
  if (prior !== undefined && typeof prior.subscriptionId === "string") membership.subscriptionId = prior.subscriptionId;
  return membership;
}

export function sortByProject<T extends { projectId?: unknown }>(memberships: T[]): T[] {
  return memberships
    .map((m, i) => ({ m, i }))
    .sort((a, b) => {
      const pa = String(a.m.projectId ?? "");
      const pb = String(b.m.projectId ?? "");
      return pa < pb ? -1 : pa > pb ? 1 : a.i - b.i;
    })
    .map(({ m }) => m);
}

// The resolver refuses a record with two active memberships of one project
// (WP-RES, 2026-10-11): keep the first, drop the rest.
export function withoutDuplicateActive<T extends { projectId?: unknown; status?: unknown }>(memberships: T[]): T[] {
  const seen = new Set<unknown>();
  return memberships.filter((m) => {
    if (m.status !== "active") return true;
    if (seen.has(m.projectId)) return false;
    seen.add(m.projectId);
    return true;
  });
}
