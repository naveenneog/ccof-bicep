// The C-7 group state (docs/PILOT.md): one per project and classification,
// spend over every row of that scope in the period. A group with no
// aggregate budget (null, docs/LLD.md) has no cap and is never exhausted;
// `mode` tells the resolver's readers whether exhaustion blocks (strict) or
// only reports (notify).

import type { AggregateBudgetStateDocument, ScopeTally, StateStamp } from "./documents.ts";
import type { ScopeRegistration } from "./registry.ts";

export function buildGroupState(
  scope: ScopeRegistration,
  tally: ScopeTally,
  activeMemberCount: number,
  stamp: StateStamp,
): AggregateBudgetStateDocument {
  const budget = scope.aggregateBudgetCcu;
  return {
    id: scope.scopeId,
    scopeId: scope.scopeId,
    spentCcu: tally.spentCcu.toFixed(),
    budgetCcu: budget === null ? null : budget.toFixed(),
    exhausted: budget !== null && tally.spentCcu.greaterThanOrEqualTo(budget),
    mode: scope.aggregateMode,
    activeMemberCount,
    computedAt: stamp.computedAt,
    validUntil: stamp.validUntil,
  };
}
