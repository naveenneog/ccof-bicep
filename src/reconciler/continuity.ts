// The ledger continuity gate (DR-05; docs/DR-ACTIVE-PASSIVE.md, failover runbook step 5). On only
// with RECONCILER_CONTINUITY_GATE=on. Before any write the run reads, per gateway, the earliest and
// newest ApiManagementGatewayLlmLog record of the period (the table the ledger's usage rows come
// from) and the budget states already persisted for the scopes it is about to write. It refuses:
//   ledger_continuity_gap / no_recent_record: records exist in the period, but no listed gateway has
//     one newer than now minus the maximum gap;
//   ledger_continuity_gap / early_history_missing: persisted spend in this period is non-zero, and
//     the period's earliest record is later than its start plus the maximum gap (or there is none);
//   spend_would_decrease: a state would record less spend than the persisted one for the same scope
//     and period.
// Pure: run.ts does the reads and the logging.

import { Money } from "../cost/money.ts";
import type { AggregateBudgetStateDocument, BudgetStateDocument } from "./documents.ts";
import { LedgerReadError, assertGatewayIds, readPrimaryResult } from "./ledger.ts";
import { budgetPeriodAt } from "./period.ts";
import type { BudgetPeriod } from "./period.ts";

export interface GatewayExtent {
  gatewayResourceId: string;
  earliest: Date;
  newest: Date;
}

export type ContinuityCondition = "no_recent_record" | "early_history_missing";

// Condition (a): only the extents and the clock are needed, so the run checks it before reading states.
export function noRecentRecord(extents: readonly GatewayExtent[], now: Date, maxGapSeconds: number): boolean {
  if (extents.length === 0) return false;
  const threshold = now.getTime() - maxGapSeconds * 1000;
  return !extents.some((extent) => extent.newest.getTime() > threshold);
}

export function buildContinuityQuery(period: BudgetPeriod, gatewayResourceIds: readonly string[]): string {
  assertGatewayIds(gatewayResourceIds);
  const ids = gatewayResourceIds.map((id) => `'${id}'`).join(", ");
  return [
    "ApiManagementGatewayLlmLog",
    `| where TimeGenerated >= datetime(${period.start.toISOString()}) and TimeGenerated < datetime(${period.end.toISOString()})`,
    `| where _ResourceId in~ (${ids})`,
    "| summarize earliest = min(TimeGenerated), newest = max(TimeGenerated) by gatewayResourceId = tolower(_ResourceId)",
    "",
  ].join("\n");
}

const COLUMNS = ["gatewayResourceId", "earliest", "newest"] as const;

function dateOf(value: unknown): Date {
  const date = typeof value === "string" ? new Date(value) : new Date(Number.NaN);
  if (Number.isNaN(date.getTime())) throw new LedgerReadError("ledger_response_invalid", "continuity_time");
  return date;
}

export function parseContinuityResponse(body: unknown): GatewayExtent[] {
  const { names, rows } = readPrimaryResult(body);
  const [id, earliest, newest] = COLUMNS.map((column) => {
    const position = names.indexOf(column);
    if (position < 0) throw new LedgerReadError("ledger_response_invalid", `column:${column}`);
    return position;
  });
  return rows.map((row) => {
    if (typeof row[id] !== "string" || !row[id]) throw new LedgerReadError("ledger_response_invalid", "continuity_gateway");
    return { gatewayResourceId: row[id] as string, earliest: dateOf(row[earliest]), newest: dateOf(row[newest]) };
  });
}

// Condition (b).
export function earlyHistoryMissing(extents: readonly GatewayExtent[], period: BudgetPeriod, maxGapSeconds: number, persistedSpendNonZero: boolean): boolean {
  if (!persistedSpendNonZero) return false;
  const bound = period.start.getTime() + maxGapSeconds * 1000;
  return !extents.some((extent) => extent.earliest.getTime() <= bound);
}

export class StateReadError extends Error {
  constructor() {
    super("budget_state_invalid");
    this.name = "StateReadError";
  }
}

const DECIMAL = /^\d{1,30}(\.\d{1,30})?$/;

// A persisted state's spend in this period; null when there is none or it belongs to another period.
// A person state names its period; a group state is in the period of its computedAt.
export function persistedSpend(doc: unknown, kind: "person" | "group", period: BudgetPeriod) {
  if (doc === null || doc === undefined) return null;
  if (typeof doc !== "object" || Array.isArray(doc)) throw new StateReadError();
  const record = doc as Record<string, unknown>;
  if (typeof record.spentCcu !== "string" || !DECIMAL.test(record.spentCcu)) throw new StateReadError();
  let label: unknown = record.period;
  if (kind === "group") {
    const computedAt = typeof record.computedAt === "string" ? new Date(record.computedAt) : new Date(Number.NaN);
    if (Number.isNaN(computedAt.getTime())) throw new StateReadError();
    label = budgetPeriodAt(computedAt).label;
  }
  if (typeof label !== "string") throw new StateReadError();
  return label === period.label ? new Money(record.spentCcu) : null;
}

export interface PersistedState {
  scopeId: string;
  kind: "person" | "group";
  doc: unknown;
}

export interface PlannedState {
  scopeId: string;
  kind: "person" | "group";
  spentCcu: string;
}

export function plannedStates(persons: ReadonlyArray<{ doc: BudgetStateDocument }>, groups: ReadonlyArray<{ doc: AggregateBudgetStateDocument }>): PlannedState[] {
  return [
    ...persons.map(({ doc }) => ({ scopeId: doc.id, kind: "person" as const, spentCcu: doc.spentCcu })),
    ...groups.map(({ doc }) => ({ scopeId: doc.id, kind: "group" as const, spentCcu: doc.spentCcu })),
  ];
}

export interface SpendComparison {
  persistedSpendNonZero: boolean;
  decreasedScopes: string[];
}

export function compareSpend(planned: readonly PlannedState[], persisted: ReadonlyMap<string, unknown>, period: BudgetPeriod): SpendComparison {
  let persistedSpendNonZero = false;
  const decreasedScopes: string[] = [];
  for (const state of planned) {
    const previous = persistedSpend(persisted.get(`${state.kind}:${state.scopeId}`), state.kind, period);
    if (previous === null) continue;
    if (previous.gt(0)) persistedSpendNonZero = true;
    if (new Money(state.spentCcu).lt(previous)) decreasedScopes.push(state.scopeId);
  }
  return { persistedSpendNonZero, decreasedScopes };
}
