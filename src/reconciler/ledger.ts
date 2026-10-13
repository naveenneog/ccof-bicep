// The ledger read (docs/PILOT.md C-7): WP-TEL's `CcofUsageLedger` function
// (analytics/ledger.kql, ADR-0010), invoked over the budget period for one
// gateway, and the checks on the Log Analytics query API's answer. Anything
// short of a complete PrimaryResult table is a failed read: a partial or
// malformed answer must never read as "no usage" (ADR-0014).

import type { BudgetPeriod } from "./period.ts";

// The ledger columns the reconciler uses, by their names in ledger.kql.
export const LEDGER_COLUMNS = [
  "timestamp",
  "ingestedAt",
  "gatewayRequestId",
  "personId",
  "projectId",
  "classification",
  "attributionKnown",
  "model",
  "inference_geo",
  "usageSource",
  "inputTokens",
  "outputTokens",
  "cacheWrite5mTokens",
  "cacheWrite1hTokens",
  "cacheReadTokens",
] as const;

export type LedgerColumn = (typeof LEDGER_COLUMNS)[number];
export type LedgerRow = Readonly<Record<LedgerColumn, unknown>>;

// The query API's JSON body, and the age in seconds of an answer it served from its response cache (the
// `Age` header; null for a fresh answer).
export interface LedgerAnswer {
  body: unknown;
  responseAgeSeconds: number | null;
}

export type LedgerFailure =
  | "ledger_request_failed"
  | "ledger_http_error"
  | "ledger_timeout"
  | "ledger_partial_result"
  | "ledger_response_invalid"
  | "ledger_row_limit_reached"
  | "ledger_row_outside_period";

export class LedgerReadError extends Error {
  readonly reason: LedgerFailure;
  // A status code or error code, safe to log; never a response body.
  readonly code: string | undefined;

  constructor(reason: LedgerFailure, code?: string) {
    super(code === undefined ? reason : `${reason} (${code})`);
    this.name = "LedgerReadError";
    this.reason = reason;
    this.code = code;
  }
}

// The value is placed inside a KQL string literal: no quote or backslash can
// pass this pattern (the same pattern as the setting).
const APIM_RESOURCE_ID = /^\/subscriptions\/[0-9a-fA-F-]{36}\/resourceGroups\/[A-Za-z0-9._-]+\/providers\/Microsoft\.ApiManagement\/service\/[A-Za-z0-9-]+$/;
const LEDGER_FUNCTION = /\blet\s+CcofUsageLedger\s*=\s*\(/;

export function buildLedgerQuery(ledgerFunctionKql: string, period: BudgetPeriod, gatewayResourceId: string): string {
  if (!LEDGER_FUNCTION.test(ledgerFunctionKql)) throw new Error("the ledger KQL does not define CcofUsageLedger");
  if (!APIM_RESOURCE_ID.test(gatewayResourceId)) throw new Error("the gateway resource id is not an APIM resource id");
  const from = period.start.toISOString();
  const to = period.end.toISOString();
  // A request refused before any backend call (WP-TEL's usageSource
  // "no-backend-call") has no usage: filtered here, it never counts toward
  // RECONCILER_LEDGER_MAX_ROWS (security council, 2026-10-11).
  return `${ledgerFunctionKql}\nCcofUsageLedger(datetime(${from}), datetime(${to}), '${gatewayResourceId}')\n| where usageSource != "no-backend-call"\n| project ${LEDGER_COLUMNS.join(", ")}\n`;
}

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

// The query API's response format (Learn, "Azure Monitor Log Analytics API
// response format", retrieved 2026-10-11): `tables`, each with `columns`
// and `rows`; a non-fatal error returns 200 with an `error` property, code
// PartialError, beside whatever rows were returned.
export function parseLedgerResponse(body: unknown, maxRows: number): LedgerRow[] {
  if (!isObject(body)) throw new LedgerReadError("ledger_response_invalid", "body");
  if (body.error !== undefined && body.error !== null) {
    const code = isObject(body.error) && typeof body.error.code === "string" && /^[A-Za-z0-9_.-]{1,64}$/.test(body.error.code) ? body.error.code : undefined;
    throw new LedgerReadError("ledger_partial_result", code);
  }
  if (!Array.isArray(body.tables)) throw new LedgerReadError("ledger_response_invalid", "tables");
  const table = body.tables.find((t) => isObject(t) && t.name === "PrimaryResult");
  if (!isObject(table) || !Array.isArray(table.columns) || !Array.isArray(table.rows)) {
    throw new LedgerReadError("ledger_response_invalid", "PrimaryResult");
  }
  const names = table.columns.map((column) => (isObject(column) && typeof column.name === "string" ? column.name : ""));
  const index = new Map<LedgerColumn, number>();
  for (const column of LEDGER_COLUMNS) {
    const position = names.indexOf(column);
    if (position < 0) throw new LedgerReadError("ledger_response_invalid", `column:${column}`);
    index.set(column, position);
  }
  // At the limit the service may have stopped early; the period would be
  // under-counted without any error to show for it.
  if (table.rows.length >= maxRows) throw new LedgerReadError("ledger_row_limit_reached", String(table.rows.length));
  return table.rows.map((row) => {
    if (!Array.isArray(row) || row.length !== names.length) throw new LedgerReadError("ledger_response_invalid", "row");
    const record = {} as Record<LedgerColumn, unknown>;
    for (const column of LEDGER_COLUMNS) record[column] = row[index.get(column) as number];
    return record;
  });
}
