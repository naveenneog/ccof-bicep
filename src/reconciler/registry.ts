// The registry the reconciler prices against (docs/PILOT.md C-4, C-5): the
// budgets of every classification of every active `projects` document, and
// the active memberships in `entitlement`. A problem in one document or one
// classification removes only that scope; problems carry ids, field names and
// codes, never a value from the document.

import type { Decimal } from "decimal.js";
import { budgetInBothUnits, parseBudget, parseOptionalBudget } from "../cost/budget-units.ts";
import { CostConfigError } from "../cost/errors.ts";
import { parseFamilyPolicy } from "../contracts/model-families.ts";
import { GUID } from "./settings.ts";

export type AggregateMode = "strict" | "notify";

export interface ScopeRegistration {
  projectId: string;
  classification: string;
  // "<projectId>:<classification>", the aggregateBudgetState key (docs/LLD.md).
  scopeId: string;
  modelAllowList: readonly string[];
  aggregateMode: AggregateMode;
  personBudgetCcu: Decimal;
  // null: no cap (docs/LLD.md), never "unlimited by accident".
  aggregateBudgetCcu: Decimal | null;
}

export interface Membership {
  // Exactly as the sync stored it: the resolver keys budgetState by it.
  personId: string;
  projectId: string;
  classification: string;
  scopeId: string;
}

export interface RegistryProblem {
  code: "project_invalid" | "classification_invalid" | "entitlement_invalid" | "membership_scope_not_registered" | "duplicate_membership";
  projectId?: string;
  classification?: string;
  field?: string;
  personId?: string;
}

export interface Registry {
  scopes: Map<string, ScopeRegistration>;
  members: Membership[];
  problems: RegistryProblem[];
}

// The patterns WP-ONB's Stage 3 schema enforces (scripts/Onboarding.Schemas.psm1).
const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const isId = (value: unknown): value is string => typeof value === "string" && ID.test(value);

// Returns the registration, or the name of the first faulty field.
function readClassification(projectId: string, classification: string, value: unknown): ScopeRegistration | string {
  if (!isObject(value)) return "(classification)";
  if (Object.hasOwn(value, "modelAllowList") || Object.hasOwn(value, "tokenLimits")) return "familyPolicy";
  const policy = parseFamilyPolicy(value.familyPolicy, classification);
  if (!policy.ok) return "familyPolicy";
  const modelAllowList = Object.values(policy.value.families).flatMap((family) => family.models);
  if (value.aggregateMode !== "strict" && value.aggregateMode !== "notify") return "aggregateMode";
  let personBudgetCcu: Decimal;
  try {
    personBudgetCcu = budgetInBothUnits(parseBudget(value.personBudget, "personBudget")).ccu;
  } catch (error) {
    if (error instanceof CostConfigError) return "personBudget";
    throw error;
  }
  let aggregateBudgetCcu: Decimal | null;
  try {
    const aggregate = parseOptionalBudget(value.aggregateBudget, "aggregateBudget");
    aggregateBudgetCcu = aggregate === null ? null : budgetInBothUnits(aggregate).ccu;
  } catch (error) {
    if (error instanceof CostConfigError) return "aggregateBudget";
    throw error;
  }
  return {
    projectId,
    classification,
    scopeId: `${projectId}:${classification}`,
    modelAllowList,
    aggregateMode: value.aggregateMode,
    personBudgetCcu,
    aggregateBudgetCcu,
  };
}

function readProjects(docs: readonly unknown[], scopes: Map<string, ScopeRegistration>, problems: RegistryProblem[]): void {
  for (const doc of docs) {
    if (!isObject(doc) || !isId(doc.projectId) || doc.id !== doc.projectId || !isObject(doc.classifications)) {
      problems.push({ code: "project_invalid" });
      continue;
    }
    // Retired or otherwise inactive projects are simply not registered.
    if (doc.status !== "active") continue;
    const projectId = doc.projectId;
    for (const [classification, value] of Object.entries(doc.classifications).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
      if (!ID.test(classification)) {
        problems.push({ code: "project_invalid", projectId });
        continue;
      }
      const result = readClassification(projectId, classification, value);
      if (typeof result === "string") {
        problems.push({ code: "classification_invalid", projectId, classification, field: result });
        continue;
      }
      scopes.set(result.scopeId, result);
    }
  }
}

interface ActiveMembership {
  projectId: string;
  classification: string;
}

// The active memberships of one entitlement document, or null when the
// document or any of its active memberships is malformed.
function readActiveMemberships(doc: Record<string, unknown>): ActiveMembership[] | null {
  if (!Array.isArray(doc.projectMemberships)) return null;
  const active: ActiveMembership[] = [];
  for (const membership of doc.projectMemberships) {
    if (!isObject(membership)) return null;
    if (membership.status !== "active") continue;
    if (!isId(membership.projectId) || !isId(membership.classification)) return null;
    active.push({ projectId: membership.projectId, classification: membership.classification });
  }
  return active;
}

function readMembers(docs: readonly unknown[], scopes: ReadonlyMap<string, ScopeRegistration>, problems: RegistryProblem[]): Membership[] {
  const members: Membership[] = [];
  for (const doc of docs) {
    if (!isObject(doc) || typeof doc.personId !== "string" || !GUID.test(doc.personId)) {
      problems.push({ code: "entitlement_invalid" });
      continue;
    }
    const personId = doc.personId;
    const active = readActiveMemberships(doc);
    if (active === null) {
      problems.push({ code: "entitlement_invalid", personId });
      continue;
    }
    // One active classification per person and project (C-4); two make the
    // person's budget ambiguous, so neither is used.
    const perProject = new Map<string, number>();
    for (const m of active) perProject.set(m.projectId, (perProject.get(m.projectId) ?? 0) + 1);
    const reported = new Set<string>();
    for (const m of active) {
      if ((perProject.get(m.projectId) ?? 0) > 1) {
        if (!reported.has(m.projectId)) problems.push({ code: "duplicate_membership", personId, projectId: m.projectId });
        reported.add(m.projectId);
        continue;
      }
      const scopeId = `${m.projectId}:${m.classification}`;
      if (!scopes.has(scopeId)) {
        problems.push({ code: "membership_scope_not_registered", personId, projectId: m.projectId, classification: m.classification });
        continue;
      }
      members.push({ personId, projectId: m.projectId, classification: m.classification, scopeId });
    }
  }
  return members;
}

export function readRegistry(projectDocs: readonly unknown[], entitlementDocs: readonly unknown[]): Registry {
  const scopes = new Map<string, ScopeRegistration>();
  const problems: RegistryProblem[] = [];
  readProjects(projectDocs, scopes, problems);
  const members = readMembers(entitlementDocs, scopes, problems);
  return { scopes, members, problems };
}
