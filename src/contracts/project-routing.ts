// Per-project backend failover (ADR 0034, docs/design/DR-IMPLEMENTATION.md).
//
// The project document keeps `backendId` as its primary backend. The optional `failover` field adds:
//   { enabled, fallbackBackendIds, revision, active }
// `active` is written only after the routing publisher verified a project-scoped APIM backend pool
// for that revision in every regional APIM. The sync copies `active.poolBackendId` into the
// entitlement membership as `routeBackendId` only while failover is enabled; otherwise, and before
// any verified publication, routing stays direct to `backendId`.
//
// Backends are registered in the admin console (one registry entry per approved Foundry deployment
// endpoint). Registration does not authorize any project. The circuit breaker is an optional
// registry setting: when a backend becomes a member of a project's pool, its member entity carries
// that breaker, so one project's breaker never affects another project's routing.

import { createHash } from "node:crypto";

const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
const UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;
// APIM backend ids are at most 80 characters; the publisher derives this from project and revision.
export const POOL_ID = /^ccof-pool-[a-z0-9-]{1,50}-r[0-9]{1,9}$/;
export const MAX_FALLBACKS = 4;

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

export interface ActiveRoute {
  revision: number;
  poolBackendId: string;
  verifiedAt: string;
}

export interface ProjectFailover {
  enabled: boolean;
  fallbackBackendIds: string[];
  revision: number;
  active: ActiveRoute | null;
}

// Project ids are case-sensitive and allow "_", APIM backend ids here are lower-case: the slug is
// lossy, so a hash of the exact project id keeps two projects ("A_B", "a-b") from sharing a pool.
function projectSlug(projectId: string, length: number): string {
  const slug = projectId.toLowerCase().replace(/[^a-z0-9-]/g, "-").slice(0, length);
  return `${slug}-${createHash("sha256").update(projectId, "utf8").digest("hex").slice(0, 8)}`;
}

export function poolBackendIdFor(projectId: string, revision: number): string {
  return `ccof-pool-${projectSlug(projectId, 40)}-r${revision}`;
}

export function memberBackendIdFor(projectId: string, revision: number, index: number): string {
  return `ccof-m-${projectSlug(projectId, 40)}-r${revision}-${index}`;
}

// Field-path problems for the stored `failover` value; absent (undefined) is valid and means off.
export function failoverProblems(value: unknown, primaryBackendId: unknown): string[] {
  if (value === undefined) return [];
  if (!isObject(value)) return ["failover:invalid"];
  const problems: string[] = [];
  const keys = ["enabled", "fallbackBackendIds", "revision", "active"];
  if (Object.keys(value).some((k) => !keys.includes(k))) problems.push("failover:unexpected_key");
  if (typeof value.enabled !== "boolean") problems.push("failover.enabled:invalid");
  const list = value.fallbackBackendIds;
  if (!Array.isArray(list) || list.length > MAX_FALLBACKS || list.some((id) => typeof id !== "string" || !ID.test(id))) {
    problems.push("failover.fallbackBackendIds:invalid");
  } else {
    if (new Set(list).size !== list.length) problems.push("failover.fallbackBackendIds:duplicate");
    if (list.includes(primaryBackendId as string)) problems.push("failover.fallbackBackendIds:includes_primary");
    if (value.enabled === true && list.length === 0) problems.push("failover.fallbackBackendIds:required_when_enabled");
  }
  if (typeof value.revision !== "number" || !Number.isSafeInteger(value.revision) || value.revision < 1) problems.push("failover.revision:invalid");
  const active = value.active;
  if (active !== null && active !== undefined) {
    if (!isObject(active) || Object.keys(active).some((k) => !["revision", "poolBackendId", "verifiedAt"].includes(k))) {
      problems.push("failover.active:invalid");
    } else {
      if (typeof active.revision !== "number" || !Number.isSafeInteger(active.revision) || active.revision < 1 ||
        (typeof value.revision === "number" && active.revision > value.revision)) problems.push("failover.active.revision:invalid");
      if (typeof active.poolBackendId !== "string" || !POOL_ID.test(active.poolBackendId)) problems.push("failover.active.poolBackendId:invalid");
      if (typeof active.verifiedAt !== "string" || !UTC.test(active.verifiedAt)) problems.push("failover.active.verifiedAt:invalid");
    }
  } else if (active === undefined) {
    problems.push("failover.active:required");
  }
  return problems;
}

// The APIM backend id the gateway uses for this project: the verified pool while failover is
// enabled, otherwise null (direct to the primary backendId). A malformed value never routes.
export function routeBackendIdOf(value: unknown, primaryBackendId: unknown): string | null {
  if (failoverProblems(value, primaryBackendId).length > 0 || !isObject(value)) return null;
  if (value.enabled !== true || !isObject(value.active)) return null;
  return value.active.poolBackendId as string;
}

// ---- Backend registry (admin console) ----

export interface CircuitBreaker {
  enabled: boolean;
  failureCount: number;
  failureIntervalSeconds: number;
  tripDurationSeconds: number;
  statusCodeRanges: { min: number; max: number }[];
  acceptRetryAfter: boolean;
}

export interface RegisteredBackend {
  backendId: string;
  displayName: string;
  // The Foundry Anthropic endpoint, https://<account>.services.ai.azure.com/anthropic
  url: string;
  deployments: string[];
  inferenceGeo: "global" | "us" | "eu";
  status: "active" | "disabled";
  circuitBreaker: CircuitBreaker | null;
}

const FOUNDRY_URL = /^https:\/\/[a-z0-9][a-z0-9-]{1,62}\.(services\.ai\.azure\.com|cognitiveservices\.azure\.com|openai\.azure\.com)\/anthropic$/;
const DEPLOYMENT = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;
export const REGISTRY_KEYS = ["backendId", "displayName", "url", "deployments", "inferenceGeo", "status", "circuitBreaker"];

export function circuitBreakerProblems(value: unknown): string[] {
  if (value === null) return [];
  if (!isObject(value)) return ["circuitBreaker:invalid"];
  const keys = ["enabled", "failureCount", "failureIntervalSeconds", "tripDurationSeconds", "statusCodeRanges", "acceptRetryAfter"];
  const problems: string[] = [];
  if (Object.keys(value).some((k) => !keys.includes(k))) problems.push("circuitBreaker:unexpected_key");
  if (typeof value.enabled !== "boolean") problems.push("circuitBreaker.enabled:invalid");
  const int = (k: string, min: number, max: number) => {
    const v = value[k];
    if (typeof v !== "number" || !Number.isSafeInteger(v) || v < min || v > max) problems.push(`circuitBreaker.${k}:invalid`);
  };
  int("failureCount", 1, 10_000);
  int("failureIntervalSeconds", 10, 3600);
  int("tripDurationSeconds", 10, 3600);
  const ranges = value.statusCodeRanges;
  if (!Array.isArray(ranges) || ranges.length < 1 || ranges.length > 5 || ranges.some((r) => !isObject(r) || Object.keys(r).some((k) => k !== "min" && k !== "max") ||
    typeof r.min !== "number" || typeof r.max !== "number" || !Number.isInteger(r.min) || !Number.isInteger(r.max) || r.min < 400 || r.max > 599 || r.min > r.max)) {
    problems.push("circuitBreaker.statusCodeRanges:invalid");
  }
  if (typeof value.acceptRetryAfter !== "boolean") problems.push("circuitBreaker.acceptRetryAfter:invalid");
  return problems;
}

export function registeredBackendProblems(value: unknown): string[] {
  if (!isObject(value)) return ["backend:not_an_object"];
  const problems: string[] = [];
  if (Object.keys(value).some((k) => !REGISTRY_KEYS.includes(k))) problems.push("backend:unexpected_key");
  if (typeof value.backendId !== "string" || !ID.test(value.backendId) || value.backendId.startsWith("ccof-")) problems.push("backendId:invalid");
  if (typeof value.displayName !== "string" || !value.displayName.trim() || value.displayName.length > 120) problems.push("displayName:invalid");
  if (typeof value.url !== "string" || !FOUNDRY_URL.test(value.url)) problems.push("url:invalid");
  const d = value.deployments;
  if (!Array.isArray(d) || d.length < 1 || d.length > 50 || d.some((x) => typeof x !== "string" || !DEPLOYMENT.test(x)) || new Set(d).size !== d.length) {
    problems.push("deployments:invalid");
  }
  if (!["global", "us", "eu"].includes(value.inferenceGeo as string)) problems.push("inferenceGeo:invalid");
  if (value.status !== "active" && value.status !== "disabled") problems.push("status:invalid");
  if (!Object.hasOwn(value, "circuitBreaker")) problems.push("circuitBreaker:required");
  else problems.push(...circuitBreakerProblems(value.circuitBreaker));
  return problems;
}

// Compatibility of a failover selection with the registry: every member serves every model the
// project admits, in the same inference geography; the primary carries an enabled breaker,
// because a pool can only move away from a member whose breaker can open.
export function failoverCompatibilityProblems(
  primaryBackendId: string,
  fallbackBackendIds: string[],
  admittedModels: string[],
  registry: Map<string, RegisteredBackend>,
): string[] {
  const problems: string[] = [];
  const primary = registry.get(primaryBackendId);
  if (!primary) return ["primary:not_registered"];
  if (primary.status !== "active") problems.push("primary:disabled");
  if (!primary.circuitBreaker?.enabled) problems.push("primary:circuit_breaker_required");
  for (const [i, id] of fallbackBackendIds.entries()) {
    const b = registry.get(id);
    if (!b) { problems.push(`fallbackBackendIds.${i}:not_registered`); continue; }
    if (b.status !== "active") problems.push(`fallbackBackendIds.${i}:disabled`);
    if (b.inferenceGeo !== primary.inferenceGeo) problems.push(`fallbackBackendIds.${i}:geography_mismatch`);
    const missing = admittedModels.filter((m) => !b.deployments.includes(m));
    if (missing.length) problems.push(`fallbackBackendIds.${i}:models_missing`);
  }
  const missingPrimary = admittedModels.filter((m) => !primary.deployments.includes(m));
  if (missingPrimary.length) problems.push("primary:models_missing");
  return problems;
}

// Every model a project admits across its classifications (familyPolicy.families.*.models).
export function admittedModelsOf(project: Record<string, unknown>): string[] {
  const out = new Set<string>();
  if (!isObject(project.classifications)) return [];
  for (const c of Object.values(project.classifications)) {
    if (!isObject(c) || !isObject(c.familyPolicy) || !isObject(c.familyPolicy.families)) continue;
    for (const f of Object.values(c.familyPolicy.families)) {
      if (isObject(f) && Array.isArray(f.models)) for (const m of f.models) if (typeof m === "string") out.add(m);
    }
  }
  return [...out].sort();
}
