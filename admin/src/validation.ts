// Project document validation. The runtime check is the sync's own reader (src/sync/projects.ts) and
// family-policy parser (src/contracts/model-families.ts), imported unchanged, so this API cannot save a
// project the deployed sync would refuse. The extra checks mirror the registry seed's create shape.

import { readProjectDocument } from "../../src/sync/projects.ts";
import { parseFamilyPolicy } from "../../src/contracts/model-families.ts";
import { ApiError, isGuid } from "./auth.ts";

export type Doc = Record<string, unknown>;

export const isObject = (v: unknown): v is Doc => typeof v === "object" && v !== null && !Array.isArray(v);
export const isIdentifier = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/.test(v);

const PROJECT_KEYS = ["id", "projectId", "displayName", "status", "backendId", "designatedSubscriptionId", "supersedes", "retiredAt", "classifications", "adminTags"];
const CLASSIFICATION_KEYS = ["groupId", "classificationGroupDisplayName", "familyPolicy", "personBudget", "aggregateBudget", "aggregateMode", "onboardingMode"];
const BUDGET_KEYS = ["amount", "currency", "period"];
const LIMIT_KEYS = ["tokensPerMinute", "tokenQuota", "tokenQuotaPeriod"];

const onlyKeys = (doc: Doc, keys: readonly string[]) => Object.keys(doc).every((k) => keys.includes(k));

function isBudget(v: unknown): boolean {
  return isObject(v) && onlyKeys(v, BUDGET_KEYS) && typeof v.amount === "number" && Number.isFinite(v.amount) &&
    v.amount >= 0 && (v.currency === "USD" || v.currency === "CCU") && v.period === "monthly";
}

// Problem codes are field paths with short codes, never values.
export function projectProblems(value: unknown): string[] {
  if (!isObject(value)) return ["document:not_an_object"];
  const problems: string[] = [];
  if (!onlyKeys(value, PROJECT_KEYS)) problems.push("document:unexpected_key");
  const read = readProjectDocument(value);
  if (!read.ok) problems.push(...read.problems);
  if (typeof value.displayName !== "string" || !value.displayName.trim() || value.displayName.length > 200) problems.push("displayName:invalid");
  if (!isGuid(value.designatedSubscriptionId)) problems.push("designatedSubscriptionId:invalid");
  if (value.adminTags !== undefined && (!Array.isArray(value.adminTags) || value.adminTags.length > 20 ||
    value.adminTags.some((tag) => typeof tag !== "string" || !/^[A-Za-z0-9][A-Za-z0-9 .:_-]{0,59}$/.test(tag)) ||
    new Set(value.adminTags).size !== value.adminTags.length)) problems.push("adminTags:invalid");
  if (value.supersedes !== null) problems.push("supersedes:invalid");
  // A retired project carries its retiredAt timestamp (checked by the sync reader); an active one has null.
  if (value.status !== "retired" && value.retiredAt !== null) problems.push("retiredAt:invalid");
  if (isObject(value.classifications)) {
    for (const [code, c] of Object.entries(value.classifications)) {
      if (!isIdentifier(code) || !isObject(c)) continue;
      const path = `classifications.${code}`;
      if (!onlyKeys(c, CLASSIFICATION_KEYS)) problems.push(`${path}:unexpected_key`);
      if (!isBudget(c.personBudget)) problems.push(`${path}.personBudget:invalid`);
      if (c.aggregateBudget !== null && !isBudget(c.aggregateBudget)) problems.push(`${path}.aggregateBudget:invalid`);
      if (c.onboardingMode !== "block" && c.onboardingMode !== "warn") problems.push(`${path}.onboardingMode:invalid`);
    }
  }
  return [...new Set(problems)];
}

export function assertValidProject(value: unknown): Doc {
  const problems = projectProblems(value);
  if (problems.length > 0) throw new ValidationError(problems);
  return structuredClone(value as Doc);
}

export class ValidationError extends ApiError {
  readonly problems: string[];
  constructor(problems: string[]) {
    super(422, "invalid_project");
    this.problems = problems;
  }
}

export function assertValidFamilyPolicy(value: unknown, classification: string): void {
  const parsed = parseFamilyPolicy(value, classification);
  if (!parsed.ok) throw new ValidationError([`classifications.${classification}.familyPolicy:${parsed.detail}`]);
}

// A partial limits update: { aggregateLimits?: { person?, group? }, families?: { <family>: { person?, group? } } }.
// Each supplied limit object replaces that scope's limit; validity is then checked on the whole policy.
export function applyLimitPatch(policy: Doc, patch: unknown): Doc {
  if (!isObject(patch) || !onlyKeys(patch, ["aggregateLimits", "families"]) || Object.keys(patch).length === 0) {
    throw new ValidationError(["limits:invalid_patch"]);
  }
  const next = structuredClone(policy);
  const scopes = (target: unknown, source: unknown, path: string) => {
    if (!isObject(target) || !isObject(source) || !onlyKeys(source, ["person", "group"]) || Object.keys(source).length === 0) {
      throw new ValidationError([`${path}:invalid_patch`]);
    }
    for (const [scope, limit] of Object.entries(source)) {
      if (!isObject(limit) || !onlyKeys(limit, LIMIT_KEYS)) throw new ValidationError([`${path}.${scope}:invalid_patch`]);
      target[scope] = { ...(isObject(target[scope]) ? target[scope] : {}), ...limit };
    }
  };
  if (patch.aggregateLimits !== undefined) scopes(next.aggregateLimits, patch.aggregateLimits, "aggregateLimits");
  if (patch.families !== undefined) {
    if (!isObject(patch.families) || !isObject(next.families)) throw new ValidationError(["families:invalid_patch"]);
    for (const [family, source] of Object.entries(patch.families)) {
      if (!isObject(next.families[family])) throw new ValidationError([`families.${family}:not_admitted`]);
      scopes(next.families[family], source, `families.${family}`);
    }
  }
  return next;
}

export function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (isObject(v)) return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
  return JSON.stringify(v);
}

// Cosmos system properties (_rid, _etag, _ts, ...) are not part of the project document.
export function stripSystem(doc: Doc): Doc {
  return Object.fromEntries(Object.entries(doc).filter(([k]) => !k.startsWith("_")));
}
