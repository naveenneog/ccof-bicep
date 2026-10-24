// The caller's own budget use, for the developer's /usage view (docs/USAGE-SELF-SERVICE.md).
// The gateway takes personId from the caller's validated token (oid) and calls this through the
// same APIM-only gate as /api/resolve (http-handler.ts), so a person can read only their own
// documents. It reads the person's entitlement and, for each active membership, the budgetState
// document the reconciler writes; nothing is written. Amounts stay exact decimal strings.

import { Decimal } from "decimal.js";
import type { ResolveDependencies } from "./decide.ts";

export const MY_USAGE_SCHEMA = "ccof.usage.me.v1";
// 100 CCU = USD 1, exact (src/cost, admin/src/units.ts).
const CCU_PER_USD = new Decimal(100);
const DECIMAL = /^\d{1,24}(\.\d{1,12})?$/;
const UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?Z$/;
const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;

export interface MyUsageProject {
  projectId: string;
  classification: string;
  // available: a budget document was read; no_budget_state: none yet (the reconciler has not run
  // for this person, or the project has no person budget); invalid: the document is malformed.
  state: "available" | "no_budget_state" | "invalid";
  spentCcu: string | null;
  budgetCcu: string | null;
  remainingCcu: string | null;
  spentUsd: string | null;
  budgetUsd: string | null;
  remainingUsd: string | null;
  percentUsed: string | null;
  exhausted: boolean | null;
  period: string | null;
  computedAt: string | null;
  // The reconciler's validUntil has passed: the figures are older than its freshness window.
  stale: boolean | null;
  completeness: "complete" | "partial" | null;
  // ADR 0035: the reconciler's soft limit, when it paces spend; null without pacing or if malformed.
  softLimitPercent: number | null;
  softLimitReached: boolean | null;
}

export interface MyUsage {
  schema: typeof MY_USAGE_SCHEMA;
  observedAt: string;
  projects: MyUsageProject[];
  basis: string;
}

const empty = (projectId: string, classification: string, state: MyUsageProject["state"]): MyUsageProject => ({
  projectId, classification, state, spentCcu: null, budgetCcu: null, remainingCcu: null, spentUsd: null, budgetUsd: null,
  remainingUsd: null, percentUsed: null, exhausted: null, period: null, computedAt: null, stale: null, completeness: null,
  softLimitPercent: null, softLimitReached: null,
});

const usd = (ccu: Decimal) => ccu.dividedBy(CCU_PER_USD).toDecimalPlaces(2, Decimal.ROUND_DOWN).toFixed(2);

// Both fields or neither: a warning without its threshold cannot be shown truthfully.
function softLimitOf(d: Record<string, unknown>): Pick<MyUsageProject, "softLimitPercent" | "softLimitReached"> {
  const percent = d.softLimitPercent, reached = d.softLimitReached;
  return Number.isInteger(percent) && (percent as number) >= 1 && (percent as number) <= 99 && typeof reached === "boolean"
    ? { softLimitPercent: percent as number, softLimitReached: reached }
    : { softLimitPercent: null, softLimitReached: null };
}

export function shapeBudget(projectId: string, classification: string, doc: unknown, now: Date): MyUsageProject {
  if (doc === null || doc === undefined) return empty(projectId, classification, "no_budget_state");
  const d = doc as Record<string, unknown>;
  if (typeof d.spentCcu !== "string" || !DECIMAL.test(d.spentCcu) || typeof d.budgetCcu !== "string" || !DECIMAL.test(d.budgetCcu) ||
    typeof d.exhausted !== "boolean" || typeof d.validUntil !== "string" || !UTC.test(d.validUntil) ||
    typeof d.computedAt !== "string" || !UTC.test(d.computedAt)) return empty(projectId, classification, "invalid");
  const spent = new Decimal(d.spentCcu), budget = new Decimal(d.budgetCcu);
  const remaining = Decimal.max(0, budget.minus(spent));
  return {
    projectId, classification, state: "available",
    spentCcu: spent.toFixed(), budgetCcu: budget.toFixed(), remainingCcu: remaining.toFixed(),
    spentUsd: usd(spent), budgetUsd: usd(budget), remainingUsd: usd(remaining),
    percentUsed: budget.isZero() ? null : spent.dividedBy(budget).times(100).toDecimalPlaces(1, Decimal.ROUND_DOWN).toFixed(1),
    exhausted: d.exhausted,
    period: typeof d.period === "string" ? d.period : null,
    computedAt: d.computedAt,
    stale: Date.parse(d.validUntil) <= now.getTime(),
    completeness: d.completeness === "complete" || d.completeness === "partial" ? d.completeness : null,
    ...softLimitOf(d),
  };
}

type Reads = Pick<ResolveDependencies, "readEntitlement" | "readBudgetState">;

export async function readMyUsage(personId: string, reads: Reads, now: Date, signal?: AbortSignal): Promise<MyUsage> {
  const entitlement = await reads.readEntitlement(personId, signal);
  const memberships = (entitlement?.projectMemberships ?? [])
    .filter((m) => m?.status === "active" && typeof m.projectId === "string" && ID.test(m.projectId) &&
      typeof m.classification === "string" && ID.test(m.classification))
    .sort((a, b) => a.projectId.localeCompare(b.projectId));
  const projects = await Promise.all(memberships.map(async (m) =>
    shapeBudget(m.projectId, m.classification, await reads.readBudgetState(personId, m.projectId, signal), now)));
  return {
    schema: MY_USAGE_SCHEMA, observedAt: now.toISOString(), projects,
    basis: "Reconciler figures at the approved rate card (100 CCU = USD 1), as of computedAt; usage not yet priced is not included.",
  };
}
