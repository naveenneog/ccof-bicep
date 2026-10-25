// Per-tick reconciler orchestration (docs/COST-MODEL.md's sequence diagram):
// read usage since the period start, compute Decimal-exact cumulative spend,
// derive the next realtime ceiling against the most expensive allowed
// model's rate, and hand the result to the caller's write function. Pure
// orchestration, framework-free - the real Log Analytics/Cosmos plumbing is
// a separate, thin wiring layer (not yet written), same split as
// src/resolver/decide.ts vs src/resolver/cosmos-reads.ts.

import { Decimal } from "decimal.js";
import { computeCeilingTokensFromCcu, computeSpend, computeNextCeilingTokens, pacedCeilingTokens } from "./compute-ceiling.ts";
import type { RateTable, SpendPacing, UsageEvent } from "./compute-ceiling.ts";
import { completenessOf } from "./documents.ts";
import type { BudgetStateDocument, ScopeTally, StateStamp } from "./documents.ts";
import type { Membership, ScopeRegistration } from "./registry.ts";

// The C-7 person state (docs/PILOT.md): the budget is the member's current
// classification's personBudget; `exhausted` is spent >= budget; the ceiling
// is COST-MODEL's (ADR-0018 D-3), 0 once exhausted, and paced when the
// reconciler is configured to (ADR 0035). The CCU path that the
// timer-run reconciler uses; reconcilePerson below is the earlier USD form.
export function buildPersonState(
  member: Membership,
  scope: ScopeRegistration,
  tally: ScopeTally,
  worstCaseCcuPerToken: Decimal,
  stamp: StateStamp,
  pacing: SpendPacing | null = null,
): BudgetStateDocument {
  const exhausted = tally.spentCcu.greaterThanOrEqualTo(scope.personBudgetCcu);
  const paced = pacing === null ? null : pacedCeilingTokens(scope.personBudgetCcu, tally.spentCcu, worstCaseCcuPerToken, pacing);
  return {
    id: `${member.personId}:${member.projectId}`,
    personId: member.personId,
    projectId: member.projectId,
    classification: member.classification,
    spentCcu: tally.spentCcu.toFixed(),
    budgetCcu: scope.personBudgetCcu.toFixed(),
    exhausted,
    period: stamp.period,
    rateCardVersion: stamp.rateCardVersion,
    contractScheduleVersion: stamp.contractScheduleVersion,
    computedAt: stamp.computedAt,
    validUntil: stamp.validUntil,
    completeness: completenessOf(tally),
    realtimeCeilingTokensPerMinute: paced
      ? paced.ceilingTokensPerMinute
      : exhausted
        ? 0
        : computeCeilingTokensFromCcu(scope.personBudgetCcu.minus(tally.spentCcu), worstCaseCcuPerToken),
    ...(paced && pacing ? { softLimitPercent: pacing.softLimitPercent, softLimitReached: paced.softLimitReached } : {}),
  };
}

export interface ReconcilePersonInput {
  personId: string;
  projectId: string;
  classification: string;
  personBudgetUsd: number;
  modelAllowList: string[];
  rates: RateTable;
}

export interface BudgetStateWrite {
  personId: string;
  projectId: string;
  classification: string;
  spentSoFarUsd: number;
  currency: "USD";
  realtimeCeilingTokensPerMinute: number;
  reconciledAt: string;
  validUntil: string;
}

export interface ReconcilePersonDeps {
  // Returns every usage event since the budget period started (e.g. the
  // start of the current month) - not just since the last tick, so this
  // function never needs to track or combine partial running sums itself.
  // Scope note: re-reading the full period's usage every tick is simpler
  // but not the most Log-Analytics-query-efficient shape at high scale;
  // a deliberate simplicity choice for this packet, not an oversight -
  // revisit if U-5's real throughput numbers show it matters.
  readUsageSince: (personId: string, projectId: string) => Promise<UsageEvent[]>;
  writeBudgetState: (state: BudgetStateWrite) => Promise<void>;
}

export interface ReconcileTiming {
  reconciledAt: Date;
  validUntil: Date;
}

export async function reconcilePerson(
  input: ReconcilePersonInput,
  deps: ReconcilePersonDeps,
  timing: ReconcileTiming,
): Promise<BudgetStateWrite> {
  if (input.modelAllowList.length === 0) {
    throw new Error(`modelAllowList is empty for classification ${input.classification} - cannot compute a ceiling with no allowed model to price against`);
  }

  // Fail closed on an unpriced allow-listed model before computing anything -
  // a classification whose allow-list includes a model this reconciler
  // cannot price must not silently under-count that model's real cost.
  // The ceiling divides by the output rate even with five categories: the
  // realtime counter it feeds sees prompt and completion tokens only, and
  // output is the dearer of those two (docs/MARKETPLACE-COST.md §7). Cache
  // categories are counted in spentSoFar when the ledger captured them, and
  // are never bounded by the ceiling (U-17).
  const mostExpensiveRate = Math.max(
    ...input.modelAllowList.map((model) => {
      const rate = input.rates[model]?.output;
      if (rate === undefined) {
        throw new Error(`no rate for allow-listed model ${model}`);
      }
      return rate;
    }),
  );

  const usage = await deps.readUsageSince(input.personId, input.projectId);
  const spentSoFar = computeSpend(usage, input.rates);
  const remaining = new Decimal(input.personBudgetUsd).minus(spentSoFar);
  const ceiling = computeNextCeilingTokens({
    remainingBudgetUsd: remaining.toNumber(),
    mostExpensiveRatePerThousandTokens: mostExpensiveRate,
  });

  const state: BudgetStateWrite = {
    personId: input.personId,
    projectId: input.projectId,
    classification: input.classification,
    spentSoFarUsd: spentSoFar.toNumber(),
    currency: "USD",
    realtimeCeilingTokensPerMinute: ceiling.toNumber(),
    reconciledAt: timing.reconciledAt.toISOString(),
    validUntil: timing.validUntil.toISOString(),
  };

  await deps.writeBudgetState(state);
  return state;
}
