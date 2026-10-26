// The reconciler's log lines (docs/PILOT.md C-7; agreed with WP-WB and
// WP-TEL, 2026-10-11). One `ccof.reconciler.budget.v1` line per written
// state and one `ccof.reconciler.run.v1` line per run, written with
// context.log and read from FunctionAppLogs in the telemetry workspace.
// `schema` is the first key, so a query can match the line's prefix. Fields
// come from an allow-list: ids, codes, counts, exact decimal strings and
// times; never a name or free text.

import type { BudgetPeriod } from "./period.ts";
import type { AggregateBudgetStateDocument, BudgetStateDocument, ScopeTally } from "./documents.ts";
import { completenessOf } from "./documents.ts";
import type { ScopeRegistration } from "./registry.ts";

export const BUDGET_SCHEMA = "ccof.reconciler.budget.v1";
export const RUN_SCHEMA = "ccof.reconciler.run.v1";

// The agreed field order of a budget line.
export const BUDGET_FIELDS = [
  "schema",
  "runId",
  "scope",
  "scopeId",
  "personId",
  "projectId",
  "classification",
  "period",
  "periodStart",
  "periodEnd",
  "spentCcu",
  "budgetCcu",
  "exhausted",
  "mode",
  "completeness",
  "pricedRequests",
  "partialRequests",
  "unpricedRequests",
  "activeMemberCount",
  "rateCardVersion",
  "computedAt",
  "validUntil",
  // ADR 0035: person lines only, null without pacing; appended so earlier readers keep their fields.
  "softLimitReached",
] as const;

export interface LineContext {
  runId: string;
  period: BudgetPeriod;
  rateCardVersion: string;
}

function periodFields(period: BudgetPeriod) {
  return { period: period.label, periodStart: period.start.toISOString(), periodEnd: period.end.toISOString() };
}

const counts = (tally: ScopeTally) => ({
  pricedRequests: tally.priced,
  partialRequests: tally.partial,
  unpricedRequests: tally.unpriced,
});

export function personBudgetLine(context: LineContext, doc: BudgetStateDocument, tally: ScopeTally): string {
  const { period, periodStart, periodEnd } = periodFields(context.period);
  return JSON.stringify({
    schema: BUDGET_SCHEMA,
    runId: context.runId,
    scope: "person",
    scopeId: doc.id,
    personId: doc.personId,
    projectId: doc.projectId,
    classification: doc.classification,
    period,
    periodStart,
    periodEnd,
    spentCcu: doc.spentCcu,
    budgetCcu: doc.budgetCcu,
    exhausted: doc.exhausted,
    // A person's own budget is always enforced (docs/LLD.md, `projects`).
    mode: "strict",
    completeness: doc.completeness,
    ...counts(tally),
    activeMemberCount: null,
    rateCardVersion: context.rateCardVersion,
    computedAt: doc.computedAt,
    validUntil: doc.validUntil,
    softLimitReached: doc.softLimitReached ?? null,
  });
}

export function groupBudgetLine(context: LineContext, doc: AggregateBudgetStateDocument, scope: ScopeRegistration, tally: ScopeTally): string {
  const { period, periodStart, periodEnd } = periodFields(context.period);
  return JSON.stringify({
    schema: BUDGET_SCHEMA,
    runId: context.runId,
    scope: "group",
    scopeId: doc.scopeId,
    personId: null,
    projectId: scope.projectId,
    classification: scope.classification,
    period,
    periodStart,
    periodEnd,
    spentCcu: doc.spentCcu,
    budgetCcu: doc.budgetCcu,
    exhausted: doc.exhausted,
    mode: doc.mode,
    completeness: completenessOf(tally),
    ...counts(tally),
    activeMemberCount: doc.activeMemberCount,
    rateCardVersion: context.rateCardVersion,
    computedAt: doc.computedAt,
    validUntil: doc.validUntil,
    softLimitReached: null,
  });
}

export type RunOutcome = "written" | "skipped_lease_held" | "failed" | "settings_invalid" | "refused";

// The run line. `schema` first; every other field is optional so that a run
// that stops early reports only what it knows.
export interface RunLine {
  runId: string;
  outcome: RunOutcome;
  reason: string | null;
  errorCode?: string;
  problems?: string[];
  [field: string]: unknown;
}

export function runLine(line: RunLine): string {
  return JSON.stringify({ schema: RUN_SCHEMA, ...line });
}
