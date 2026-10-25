// Reads a `projects` document (docs/LLD.md §1, docs/PILOT.md C-5) into the
// registrations the sync projects. Only onboarding Stage 3 writes these
// documents; the sync checks every field it copies and reports problems as
// field paths with problem codes, never values.

import { GUID } from "./types.ts";
import type { AggregateMode } from "./types.ts";
import { parseFamilyPolicy } from "../contracts/model-families.ts";
import type { FamilyPolicy } from "../contracts/model-families.ts";

export interface ClassificationRegistration {
  projectId: string;
  classification: string;
  groupId: string;
  classificationGroupDisplayName?: string;
  familyPolicy: FamilyPolicy;
  backendId: string;
  // ADR 0034: the verified project-scoped APIM pool, only while failover is enabled.
  routeBackendId?: string;
  aggregateMode: AggregateMode;
}

// retired: the project document says status "retired" with a retiredAt timestamp. The sync removes
// every membership of a retired project (an explicit, audited registry change), instead of freezing it.
export type ProjectReadResult =
  | { ok: true; projectId: string; classifications: ClassificationRegistration[]; retired: boolean }
  | { ok: false; projectId: string | null; problems: string[] };

// The same patterns WP-ONB's Stage 3 schema enforces (scripts/Onboarding.Schemas.psm1 on wp/onb).
import { failoverProblems, routeBackendIdOf } from "../contracts/project-routing.ts";
const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;

const isTimestamp = (value: unknown): boolean =>
  typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/.test(value) && Number.isFinite(Date.parse(value));

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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
  const familyPolicy = parseFamilyPolicy(value.familyPolicy, code);
  if (!familyPolicy.ok) problems.push(`${path}.familyPolicy:${familyPolicy.detail}`);
  if (Object.hasOwn(value, "modelAllowList") || Object.hasOwn(value, "tokenLimits")) problems.push(`${path}:legacy_policy_fields`);
  const name = value.classificationGroupDisplayName;
  if (Object.hasOwn(value, "classificationGroupDisplayName") && (typeof name !== "string" || name.length < 1 || name.length > 256)) {
    problems.push(`${path}.classificationGroupDisplayName:invalid`);
  }
  const aggregateMode = value.aggregateMode === "strict" || value.aggregateMode === "notify" ? value.aggregateMode : null;
  if (!aggregateMode) problems.push(`${path}.aggregateMode:invalid`);
  if (problems.length > before || !groupId || !aggregateMode || !familyPolicy.ok) return null;
  return {
    projectId, classification: code, groupId, familyPolicy: familyPolicy.value, backendId, aggregateMode,
    ...(typeof name === "string" ? { classificationGroupDisplayName: name } : {}),
  };
}

export function readProjectDocument(doc: unknown): ProjectReadResult {
  if (!isObject(doc)) return { ok: false, projectId: null, problems: ["document:not_an_object"] };
  const problems: string[] = [];
  const projectId = typeof doc.projectId === "string" && ID.test(doc.projectId) ? doc.projectId : null;
  if (!projectId) problems.push("projectId:invalid");
  if (projectId && doc.id !== projectId) problems.push("id:not_equal_to_projectId");
  const retired = doc.status === "retired";
  if (doc.status !== "active" && !retired) problems.push("status:not_active");
  if (retired && !isTimestamp(doc.retiredAt)) problems.push("retiredAt:invalid");
  const backendId = typeof doc.backendId === "string" && ID.test(doc.backendId) ? doc.backendId : null;
  if (!backendId) problems.push("backendId:invalid");

  problems.push(...failoverProblems(doc.failover, backendId));
  const routeBackendId = routeBackendIdOf(doc.failover, backendId);

  const registrations: ClassificationRegistration[] = [];
  if (!isObject(doc.classifications)) {
    problems.push("classifications:invalid");
  } else {
    const codes = Object.keys(doc.classifications).sort();
    if (codes.length === 0) problems.push("classifications:empty");
    if (codes.some((code) => !ID.test(code))) problems.push("classifications:invalid_code");
    for (const code of codes.filter((c) => ID.test(c))) {
      const registration = readClassification(projectId ?? "", backendId ?? "", code, doc.classifications[code], problems);
      if (registration) registrations.push(routeBackendId ? { ...registration, routeBackendId } : registration);
    }
    const groups = registrations.map((r) => r.groupId);
    if (new Set(groups).size !== groups.length) problems.push("classifications:group_reused");
  }

  if (problems.length > 0 || !projectId) return { ok: false, projectId, problems };
  return { ok: true, projectId, classifications: registrations, retired };
}
