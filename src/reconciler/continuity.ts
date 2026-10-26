// The ledger continuity gate (DR-05R). It verifies request-to-usage log coverage
// and the persisted period baseline before any budget write. Pure: run.ts does
// the reads and the logging.

import { Money } from "../cost/money.ts";
import type { AggregateBudgetStateDocument, BudgetStateDocument } from "./documents.ts";
import { LedgerReadError, assertGatewayIds, readPrimaryResult } from "./ledger.ts";
import { budgetPeriodAt } from "./period.ts";
import type { BudgetPeriod } from "./period.ts";

export type ContinuityGapKind = "request_before_coverage" | "backend_call_without_llm" | "llm_without_gateway";

export interface ContinuityGap {
  gatewayResourceId: string;
  gapKind: ContinuityGapKind;
  issueCount: number;
  firstAt: Date;
}

export type CoverageBaselineIssue = "ledger_coverage_baseline_missing" | "ledger_coverage_baseline_mismatch";

export function effectiveCoverageStartAt(period: BudgetPeriod, configuredStartAt: string): string {
  const configured = new Date(configuredStartAt);
  return new Date(Math.max(period.start.getTime(), configured.getTime())).toISOString();
}

export function buildContinuityQuery(period: BudgetPeriod, gatewayResourceIds: readonly string[], coverageStartAt: string): string {
  assertGatewayIds(gatewayResourceIds);
  const coverageStart = effectiveCoverageStartAt(period, coverageStartAt);
  const ids = gatewayResourceIds.map((id) => `'${id}'`).join(", ");
  return [
    `let periodStart = datetime(${period.start.toISOString()});`,
    `let periodEnd = datetime(${period.end.toISOString()});`,
    `let coverageStart = datetime(${coverageStart});`,
    "let usage = ApiManagementGatewayLlmLog",
    "| where TimeGenerated >= periodStart and TimeGenerated < periodEnd",
    `| where _ResourceId in~ (${ids})`,
    "| extend gatewayResourceId = tolower(_ResourceId), gatewayRequestId = tolower(tostring(CorrelationId))",
    "| where isnotempty(gatewayRequestId)",
    "| summarize usageTime = min(TimeGenerated) by gatewayResourceId, gatewayRequestId;",
    "let gatewayRequests = ApiManagementGatewayLogs",
    "| where TimeGenerated >= periodStart and TimeGenerated < periodEnd",
    `| where _ResourceId in~ (${ids})`,
    "| extend gatewayResourceId = tolower(_ResourceId), gatewayRequestId = tolower(tostring(CorrelationId))",
    "| where isnotempty(gatewayRequestId)",
    "| project gatewayResourceId, gatewayRequestId, requestTime = TimeGenerated, apiId = ApiId, hasBackend = isnotempty(BackendId) or isnotempty(BackendUrl);",
    "let gatewayRequestIds = gatewayRequests | distinct gatewayResourceId, gatewayRequestId;",
    "let modelRequests = gatewayRequests",
    "| where apiId == 'claude-messages' and hasBackend",
    "| summarize requestTime = min(requestTime) by gatewayResourceId, gatewayRequestId;",
    "let requestGaps = modelRequests",
    "| join kind=leftouter usage on gatewayResourceId, gatewayRequestId",
    "| extend gapKind = case(requestTime < coverageStart, 'request_before_coverage', isnull(usageTime), 'backend_call_without_llm', '')",
    "| where isnotempty(gapKind)",
    "| project gatewayResourceId, gatewayRequestId, gapKind, issueTime = requestTime;",
    "let usageGaps = usage",
    "| join kind=leftanti gatewayRequestIds on gatewayResourceId, gatewayRequestId",
    "| extend gapKind = 'llm_without_gateway'",
    "| project gatewayResourceId, gatewayRequestId, gapKind, issueTime = usageTime;",
    "union requestGaps, usageGaps",
    "| summarize issueCount = dcount(gatewayRequestId), firstAt = min(issueTime) by gatewayResourceId, gapKind",
    "",
  ].join("\n");
}

const COLUMNS = ["gatewayResourceId", "gapKind", "issueCount", "firstAt"] as const;

function dateOf(value: unknown): Date {
  const date = typeof value === "string" ? new Date(value) : new Date(Number.NaN);
  if (Number.isNaN(date.getTime())) throw new LedgerReadError("ledger_response_invalid", "continuity_time");
  return date;
}

export function parseContinuityResponse(body: unknown): ContinuityGap[] {
  const { names, rows } = readPrimaryResult(body);
  const [id, gapKind, issueCount, firstAt] = COLUMNS.map((column) => {
    const position = names.indexOf(column);
    if (position < 0) throw new LedgerReadError("ledger_response_invalid", `column:${column}`);
    return position;
  });
  return rows.map((row) => {
    if (typeof row[id] !== "string" || !row[id]) throw new LedgerReadError("ledger_response_invalid", "continuity_gateway");
    if (row[gapKind] !== "request_before_coverage" && row[gapKind] !== "backend_call_without_llm" && row[gapKind] !== "llm_without_gateway") {
      throw new LedgerReadError("ledger_response_invalid", "continuity_gap_kind");
    }
    const count = typeof row[issueCount] === "number" ? row[issueCount] : typeof row[issueCount] === "string" ? Number(row[issueCount]) : Number.NaN;
    if (!Number.isSafeInteger(count) || count < 1) throw new LedgerReadError("ledger_response_invalid", "continuity_gap_count");
    return { gatewayResourceId: row[id] as string, gapKind: row[gapKind], issueCount: count, firstAt: dateOf(row[firstAt]) };
  });
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

export function coverageBaselineIssue(
  planned: readonly PlannedState[],
  persisted: ReadonlyMap<string, unknown>,
  period: BudgetPeriod,
  coverageStartAt: string,
): CoverageBaselineIssue | null {
  for (const state of planned) {
    const doc = persisted.get(`${state.kind}:${state.scopeId}`);
    if (persistedSpend(doc, state.kind, period) === null) continue;
    if (typeof doc !== "object" || doc === null || Array.isArray(doc)) throw new StateReadError();
    const marker = (doc as Record<string, unknown>).ledgerCoverageStartAt;
    if (typeof marker !== "string") return "ledger_coverage_baseline_missing";
    if (marker !== coverageStartAt) return "ledger_coverage_baseline_mismatch";
  }
  return null;
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
