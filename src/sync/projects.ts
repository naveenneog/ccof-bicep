// Reads a `projects` document (docs/LLD.md §1, docs/PILOT.md C-5) into the
// registrations the sync projects. Only onboarding Stage 3 writes these
// documents; the sync checks every field it copies and reports problems as
// field paths with problem codes, never values.

import { GUID, TOKEN_QUOTA_PERIODS } from "./types.ts";
import type { AggregateMode, TokenLimit, TokenLimits } from "./types.ts";

export interface ClassificationRegistration {
  projectId: string;
  classification: string;
  groupId: string;
  modelAllowList: string[];
  backendId: string;
  aggregateMode: AggregateMode;
  tokenLimits: TokenLimits;
}

export type ProjectReadResult =
  | { ok: true; projectId: string; classifications: ClassificationRegistration[] }
  | { ok: false; projectId: string | null; problems: string[] };

// The same patterns WP-ONB's Stage 3 schema enforces (scripts/Onboarding.Schemas.psm1 on wp/onb).
const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
const MODEL = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;

// The resolver accepts tokensPerMinute up to the 32-bit integer maximum (WP-RES, 2026-10-11).
const MAX_TOKENS_PER_MINUTE = 2147483647;

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isLimit(value: unknown, max = Number.MAX_SAFE_INTEGER): value is number | null {
  return value === null || (typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= max);
}

function readTokenLimit(value: unknown, path: string, problems: string[]): TokenLimit | null {
  if (value === undefined) {
    problems.push(`${path}:missing`);
    return null;
  }
  if (!isObject(value)) {
    problems.push(`${path}:invalid`);
    return null;
  }
  const before = problems.length;
  // A key's name is not echoed: it is free text from the document.
  if (Object.keys(value).some((key) => !["tokensPerMinute", "tokenQuota", "tokenQuotaPeriod"].includes(key))) problems.push(`${path}:unexpected_key`);
  for (const key of ["tokensPerMinute", "tokenQuota"] as const) {
    if (!(key in value)) problems.push(`${path}.${key}:missing`);
    else if (!isLimit(value[key], key === "tokensPerMinute" ? MAX_TOKENS_PER_MINUTE : undefined)) problems.push(`${path}.${key}:invalid`);
  }
  const period = value.tokenQuotaPeriod;
  if (!("tokenQuotaPeriod" in value)) problems.push(`${path}.tokenQuotaPeriod:missing`);
  else if (period !== null && !(TOKEN_QUOTA_PERIODS as readonly unknown[]).includes(period)) problems.push(`${path}.tokenQuotaPeriod:invalid`);
  if (problems.length > before) return null;
  // C-2: a quota and its period are both set or both null.
  if ((value.tokenQuota === null) !== (period === null)) {
    problems.push(`${path}:quota_period_mismatch`);
    return null;
  }
  return { tokensPerMinute: value.tokensPerMinute as number | null, tokenQuota: value.tokenQuota as number | null, tokenQuotaPeriod: period as TokenLimit["tokenQuotaPeriod"] };
}

export function readTokenLimits(value: unknown, path: string, problems: string[]): TokenLimits | null {
  if (value === undefined) {
    problems.push(`${path}:missing`);
    return null;
  }
  if (!isObject(value)) {
    problems.push(`${path}:invalid`);
    return null;
  }
  const unexpected = Object.keys(value).some((k) => k !== "person" && k !== "group");
  if (unexpected) problems.push(`${path}:unexpected_key`);
  const person = readTokenLimit(value.person, `${path}.person`, problems);
  const group = readTokenLimit(value.group, `${path}.group`, problems);
  return person && group && !unexpected ? { person, group } : null;
}

function readModelAllowList(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.length === 0) return null;
  if (!value.every((m) => typeof m === "string" && MODEL.test(m))) return null;
  return new Set(value).size === value.length ? [...(value as string[])] : null;
}

function readClassification(
  projectId: string,
  backendId: string,
  code: string,
  value: unknown,
  problems: string[],
): ClassificationRegistration | null {
  const path = `classifications.${code}`;
  if (!isObject(value)) {
    problems.push(`${path}:invalid`);
    return null;
  }
  const before = problems.length;
  const groupId = typeof value.groupId === "string" && GUID.test(value.groupId) ? value.groupId.toLowerCase() : null;
  if (!groupId) problems.push(`${path}.groupId:invalid`);
  const modelAllowList = readModelAllowList(value.modelAllowList);
  if (!modelAllowList) problems.push(`${path}.modelAllowList:invalid`);
  const aggregateMode = value.aggregateMode === "strict" || value.aggregateMode === "notify" ? value.aggregateMode : null;
  if (!aggregateMode) problems.push(`${path}.aggregateMode:invalid`);
  const tokenLimits = readTokenLimits(value.tokenLimits, `${path}.tokenLimits`, problems);
  if (problems.length > before || !groupId || !modelAllowList || !aggregateMode || !tokenLimits) return null;
  return { projectId, classification: code, groupId, modelAllowList, backendId, aggregateMode, tokenLimits };
}

export function readProjectDocument(doc: unknown): ProjectReadResult {
  if (!isObject(doc)) return { ok: false, projectId: null, problems: ["document:not_an_object"] };
  const problems: string[] = [];
  const projectId = typeof doc.projectId === "string" && ID.test(doc.projectId) ? doc.projectId : null;
  if (!projectId) problems.push("projectId:invalid");
  if (projectId && doc.id !== projectId) problems.push("id:not_equal_to_projectId");
  if (doc.status !== "active") problems.push("status:not_active");
  const backendId = typeof doc.backendId === "string" && ID.test(doc.backendId) ? doc.backendId : null;
  if (!backendId) problems.push("backendId:invalid");

  const registrations: ClassificationRegistration[] = [];
  if (!isObject(doc.classifications)) {
    problems.push("classifications:invalid");
  } else {
    const codes = Object.keys(doc.classifications).sort();
    if (codes.length === 0) problems.push("classifications:empty");
    if (codes.some((code) => !ID.test(code))) problems.push("classifications:invalid_code");
    for (const code of codes.filter((c) => ID.test(c))) {
      const registration = readClassification(projectId ?? "", backendId ?? "", code, doc.classifications[code], problems);
      if (registration) registrations.push(registration);
    }
    const groups = registrations.map((r) => r.groupId);
    if (new Set(groups).size !== groups.length) problems.push("classifications:group_reused");
  }

  if (problems.length > 0 || !projectId) return { ok: false, projectId, problems };
  return { ok: true, projectId, classifications: registrations };
}
