// The documents the reconciler writes (docs/PILOT.md C-7; field names from
// C-7, the WP-REC brief and docs/LLD.md; shape agreed with WP-RES). The
// resolver reads `exhausted`, `validUntil` and, for a person,
// `realtimeCeilingTokensPerMinute`; every other field is for people and
// reports. Amounts are exact decimal strings: the resolver never parses
// them, and a JSON number would pass through binary floating point.

import type { Decimal } from "decimal.js";

export type Completeness = "complete" | "partial";

// Container `budgetState`, partition key /personId.
export interface BudgetStateDocument {
  id: string;
  personId: string;
  projectId: string;
  classification: string;
  spentCcu: string;
  budgetCcu: string;
  exhausted: boolean;
  period: string;
  rateCardVersion: string;
  contractScheduleVersion: string;
  computedAt: string;
  validUntil: string;
  completeness: Completeness;
  realtimeCeilingTokensPerMinute: number;
  // Present only when the reconciler paces spend (ADR 0035).
  softLimitPercent?: number;
  softLimitReached?: boolean;
}

// Container `aggregateBudgetState`, partition key /scopeId.
export interface AggregateBudgetStateDocument {
  id: string;
  scopeId: string;
  spentCcu: string;
  budgetCcu: string | null;
  exhausted: boolean;
  mode: "strict" | "notify";
  activeMemberCount: number;
  computedAt: string;
  validUntil: string;
}

// What a scope's rows added up to in this run.
export interface ScopeTally {
  spentCcu: Decimal;
  priced: number;
  partial: number;
  unpriced: number;
}

// The fields every document of one run shares.
export interface StateStamp {
  period: string;
  rateCardVersion: string;
  contractScheduleVersion: string;
  computedAt: string;
  validUntil: string;
}

export function completenessOf(tally: ScopeTally): Completeness {
  return tally.partial > 0 || tally.unpriced > 0 ? "partial" : "complete";
}
