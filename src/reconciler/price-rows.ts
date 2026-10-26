// Pricing one ledger row for the reconciler (docs/PILOT.md C-7): the row's
// columns (analytics/ledger.kql) mapped onto WP-COST's priceUsage, which
// prices it at the rates in force at its own time (ADR-0011). Usage the rate
// card cannot price is reported as unpriced, with reasons, and never priced
// at zero. A row the pricing module refuses as malformed is unpriced too, so
// one bad row affects only its own scope.

import type { Decimal } from "decimal.js";
import type { ContractSchedule } from "../cost/contract-schedule.ts";
import { UsageRowError } from "../cost/errors.ts";
import { priceUsage } from "../cost/price-usage.ts";
import type { RateCard } from "../cost/rate-card.ts";
import type { TokenCategory } from "../cost/token-categories.ts";
import { LedgerReadError } from "./ledger.ts";
import type { LedgerRow } from "./ledger.ts";
import { isInPeriod } from "./period.ts";
import type { BudgetPeriod } from "./period.ts";
import { GUID } from "./settings.ts";

export interface Attribution {
  // The person id in lower case: GUIDs compare case-insensitively.
  personKey: string;
  projectId: string;
  classification: string;
}

export type RowOutcome =
  | { kind: "no_usage" }
  | { kind: "priced" | "partial"; ccu: Decimal }
  | { kind: "unpriced"; reasons: readonly string[] };

export interface ClassifiedRow {
  attribution: Attribution | null;
  outcome: RowOutcome;
  // The gateway reported the request failed and the ledger has no token count of any kind.
  failedWithoutUsage: boolean;
  ingestionDelaySeconds: number | null;
  // When the row became queryable; null when the ledger gave no valid time.
  ingestedAtMs: number | null;
}

// The same id pattern as the registry (WP-ONB's Stage 3 schema).
const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
const UTC_INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z$/;

const TOKEN_COLUMNS: ReadonlyArray<readonly [TokenCategory, keyof LedgerRow]> = [
  ["input", "inputTokens"],
  ["cacheWrite5m", "cacheWrite5mTokens"],
  ["cacheWrite1h", "cacheWrite1hTokens"],
  ["cacheRead", "cacheReadTokens"],
  ["output", "outputTokens"],
];

const isCount = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
const invalidRow: RowOutcome = { kind: "unpriced", reasons: ["ledger_row_invalid"] };

function instant(value: unknown): Date | null {
  if (typeof value !== "string" || !UTC_INSTANT.test(value)) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? new Date(ms) : null;
}

function attributionOf(row: LedgerRow): Attribution | null {
  const { attributionKnown, personId, projectId, classification } = row;
  if (attributionKnown !== true) return null;
  if (typeof personId !== "string" || !GUID.test(personId)) return null;
  if (typeof projectId !== "string" || !ID.test(projectId)) return null;
  if (typeof classification !== "string" || !ID.test(classification)) return null;
  return { personKey: personId.toLowerCase(), projectId, classification };
}

function readTokens(row: LedgerRow): Record<TokenCategory, number | null> | null {
  const tokens = {} as Record<TokenCategory, number | null>;
  for (const [category, column] of TOKEN_COLUMNS) {
    const value = row[column];
    if (value !== null && !isCount(value)) return null;
    tokens[category] = value;
  }
  return tokens;
}

// The ledger marks a request refused before any backend call (WP-TEL,
// 2026-10-11): there is no model usage to price, whatever its counts. The
// query filters these rows; this check keeps that true for any caller. No
// other row is "no usage": known zero counts price at exactly zero, and
// unknown counts are unpriced and reported (security council, 2026-10-11).
const NO_BACKEND_CALL = "no-backend-call";

function priceRow(row: LedgerRow, at: Date, card: RateCard, schedule: ContractSchedule): RowOutcome {
  if (row.usageSource === NO_BACKEND_CALL) return { kind: "no_usage" };
  const tokens = readTokens(row);
  if (tokens === null) return invalidRow;
  const geo = row.inference_geo;
  // The ledger writes "unknown" when the deployment's geography is not
  // registered; pricing takes null for "not known" (docs/TELEMETRY.md).
  const inferenceGeo = typeof geo === "string" && geo !== "" && geo !== "unknown" ? geo : null;
  try {
    const outcome = priceUsage({ requestTime: at, model: typeof row.model === "string" ? row.model : "", inferenceGeo, tokens }, card, schedule);
    if (outcome.status === "unpriced") return { kind: "unpriced", reasons: outcome.reasons };
    return { kind: outcome.status, ccu: outcome.predictedCcu };
  } catch (error) {
    if (error instanceof UsageRowError) return invalidRow;
    throw error;
  }
}

export function classifyRow(row: LedgerRow, period: BudgetPeriod, card: RateCard, schedule: ContractSchedule): ClassifiedRow {
  const at = instant(row.timestamp);
  // The query asks for the period only; a row outside it means the query or
  // the ledger is wrong, and no total from this read can be trusted.
  if (at !== null && !isInPeriod(period, at)) throw new LedgerReadError("ledger_row_outside_period");
  const ingested = instant(row.ingestedAt);
  return {
    attribution: attributionOf(row),
    outcome: at === null ? invalidRow : priceRow(row, at, card, schedule),
    failedWithoutUsage: row.requestFailed === true && TOKEN_COLUMNS.every(([, column]) => row[column] === null),
    ingestionDelaySeconds: at === null || ingested === null ? null : (ingested.getTime() - at.getTime()) / 1000,
    ingestedAtMs: ingested === null ? null : ingested.getTime(),
  };
}
