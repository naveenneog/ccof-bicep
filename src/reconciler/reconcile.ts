// The reconciler's pure core (docs/PILOT.md C-7, ADR-0018): from the
// registry and the priced ledger rows of the period, one budgetState per
// registered member and project, and one aggregateBudgetState per registered
// project and classification. No I/O and no clock: the run supplies both.

import type { Decimal } from "decimal.js";
import { Money } from "../cost/money.ts";
import type { RateCard } from "../cost/rate-card.ts";
import { worstCaseCcuPerOutputToken } from "./compute-ceiling.ts";
import type { AggregateBudgetStateDocument, BudgetStateDocument, ScopeTally, StateStamp } from "./documents.ts";
import type { BudgetPeriod } from "./period.ts";
import type { ClassifiedRow } from "./price-rows.ts";
import { buildGroupState } from "./reconcile-group.ts";
import { buildPersonState } from "./reconcile-person.ts";
import type { Registry, RegistryProblem } from "./registry.ts";

export interface ReconcileInput {
  registry: Registry;
  rows: readonly ClassifiedRow[];
  rateCard: RateCard;
  contractScheduleVersion: string;
  period: BudgetPeriod;
  computedAt: Date;
  validUntil: Date;
}

export interface ScopeProblem {
  code: "allow_listed_model_unpriced";
  projectId: string;
  classification: string;
}

export interface RowCounts {
  ledgerRows: number;
  noUsageRequests: number;
  // Rows with usage that no scope can be charged for.
  unattributedRequests: number;
  // Attributed rows whose project and classification are not registered.
  unregisteredScopeRequests: number;
  // Over the attributed rows with usage.
  pricedRequests: number;
  partialRequests: number;
  unpricedRequests: number;
}

export interface ReconcileResult {
  persons: Array<{ doc: BudgetStateDocument; tally: ScopeTally }>;
  groups: Array<{ doc: AggregateBudgetStateDocument; tally: ScopeTally }>;
  counts: RowCounts;
  unattributedCcu: Decimal;
  unpricedReasons: Record<string, number>;
  problems: Array<RegistryProblem | ScopeProblem>;
  maxIngestionDelaySeconds: number | null;
  // The most recently ingested row, and its delay: a stalled ledger shows as
  // a newestIngestedAt that stops moving although the run succeeds.
  newestIngestedAt: string | null;
  newestRowIngestionDelaySeconds: number | null;
}

const emptyTally = (): ScopeTally => ({ spentCcu: new Money(0), priced: 0, partial: 0, unpriced: 0 });
const byKey = <T>(key: (item: T) => string) => (a: T, b: T): number => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0);

function add(tallies: Map<string, ScopeTally>, key: string, outcome: ClassifiedRow["outcome"]): void {
  if (outcome.kind === "no_usage") return;
  const tally = tallies.get(key) ?? emptyTally();
  tally[outcome.kind] += 1;
  if (outcome.kind !== "unpriced") tally.spentCcu = tally.spentCcu.plus(outcome.ccu);
  tallies.set(key, tally);
}

const personKeyOf = (personId: string, projectId: string): string => `${personId.toLowerCase()}|${projectId}`;

export function reconcile(input: ReconcileInput): ReconcileResult {
  const { registry, rows } = input;
  const personTallies = new Map<string, ScopeTally>();
  const groupTallies = new Map<string, ScopeTally>();
  const counts: RowCounts = {
    ledgerRows: rows.length,
    noUsageRequests: 0,
    unattributedRequests: 0,
    unregisteredScopeRequests: 0,
    pricedRequests: 0,
    partialRequests: 0,
    unpricedRequests: 0,
  };
  const unpricedReasons: Record<string, number> = {};
  let unattributedCcu: Decimal = new Money(0);
  let maxIngestionDelaySeconds: number | null = null;
  let newest: ClassifiedRow | null = null;

  for (const row of rows) {
    if (row.ingestionDelaySeconds !== null) {
      maxIngestionDelaySeconds = Math.max(maxIngestionDelaySeconds ?? row.ingestionDelaySeconds, row.ingestionDelaySeconds);
    }
    if (row.ingestedAtMs !== null && (newest?.ingestedAtMs ?? -Infinity) < row.ingestedAtMs) newest = row;
    const { outcome, attribution } = row;
    if (outcome.kind === "no_usage") {
      counts.noUsageRequests += 1;
      continue;
    }
    if (attribution === null) {
      counts.unattributedRequests += 1;
      if (outcome.kind !== "unpriced") unattributedCcu = unattributedCcu.plus(outcome.ccu);
      continue;
    }
    counts[`${outcome.kind}Requests`] += 1;
    if (outcome.kind === "unpriced") for (const reason of outcome.reasons) unpricedReasons[reason] = (unpricedReasons[reason] ?? 0) + 1;
    const scopeId = `${attribution.projectId}:${attribution.classification}`;
    if (!registry.scopes.has(scopeId)) counts.unregisteredScopeRequests += 1;
    add(personTallies, `${attribution.personKey}|${attribution.projectId}`, outcome);
    add(groupTallies, scopeId, outcome);
  }

  const stamp: StateStamp = {
    period: input.period.label,
    rateCardVersion: input.rateCard.version,
    contractScheduleVersion: input.contractScheduleVersion,
    computedAt: input.computedAt.toISOString(),
    validUntil: input.validUntil.toISOString(),
  };
  const problems: Array<RegistryProblem | ScopeProblem> = [...registry.problems];
  const scopes = [...registry.scopes.values()].sort(byKey((s) => s.scopeId));

  // A scope whose worst case cannot be bounded gets no person state: the
  // ceiling is a required field (compute-ceiling.ts refuses the same way).
  const worstCase = new Map<string, Decimal>();
  for (const scope of scopes) {
    const worst = worstCaseCcuPerOutputToken(input.rateCard, scope.modelAllowList, input.computedAt);
    if (worst === null) problems.push({ code: "allow_listed_model_unpriced", projectId: scope.projectId, classification: scope.classification });
    else worstCase.set(scope.scopeId, worst);
  }

  const persons = registry.members
    .filter((member) => worstCase.has(member.scopeId))
    .map((member) => {
      const tally = personTallies.get(personKeyOf(member.personId, member.projectId)) ?? emptyTally();
      const scope = registry.scopes.get(member.scopeId) as (typeof scopes)[number];
      return { doc: buildPersonState(member, scope, tally, worstCase.get(member.scopeId) as Decimal, stamp), tally };
    })
    .sort(byKey((p) => p.doc.id));

  const groups = scopes.map((scope) => {
    const tally = groupTallies.get(scope.scopeId) ?? emptyTally();
    const activeMemberCount = registry.members.filter((m) => m.scopeId === scope.scopeId).length;
    return { doc: buildGroupState(scope, tally, activeMemberCount, stamp), tally };
  });

  return {
    persons,
    groups,
    counts,
    unattributedCcu,
    unpricedReasons,
    problems,
    maxIngestionDelaySeconds,
    newestIngestedAt: newest?.ingestedAtMs == null ? null : new Date(newest.ingestedAtMs).toISOString(),
    newestRowIngestionDelaySeconds: newest?.ingestionDelaySeconds ?? null,
  };
}
