// Refusal reasons and their HTTP statuses, in one place (ADR-0008, docs/PILOT.md
// C-1): http-handler.ts derives the external category from the status, so a
// new reason cannot drift from its category.

const REFUSAL_STATUS = {
  unknown_subscription: 403,
  subscription_person_mismatch: 403,
  no_entitlement: 403,
  entitlement_legacy_expired: 403,
  project_mismatch: 403,
  classification_mismatch: 403,
  project_selection_required: 400,
  // C-7: the budget refusals follow a verified membership.
  budget_exhausted: 403,
  aggregate_budget_exhausted: 403,
  // C-8: the gateway routes only to backends the resolver returns.
  backend_not_active: 403,
  backend_record_invalid: 503,
  entitlement_record_invalid: 503,
  budget_state_missing: 503,
  budget_state_invalid: 503,
  budget_state_stale: 503,
  aggregate_budget_state_missing: 503,
  aggregate_budget_state_invalid: 503,
  aggregate_budget_state_stale: 503,
} as const;

export type RefusalReason = keyof typeof REFUSAL_STATUS;

export function refusalStatus(reason: string): number | undefined {
  return Object.hasOwn(REFUSAL_STATUS, reason) ? REFUSAL_STATUS[reason as RefusalReason] : undefined;
}

// `reason` is an internal diagnostic string, safe to log, NOT safe to return
// verbatim in an external HTTP response: the distinct reasons
// (unknown_subscription vs subscription_person_mismatch vs project_mismatch
// vs classification_mismatch) would let an attacker probing many subscription
// keys tell "key doesn't exist" from "key exists but belongs to someone
// else" - an enumeration oracle. http-handler.ts collapses them (U-12).
export interface ResolveRefusal {
  refused: true;
  reason: RefusalReason;
  httpStatus: number;
  // For the log event only: the project the key or the record resolved to.
  // Never a raw selector that matched nothing (ADR-0006 decision 4).
  projectId?: string;
  // For the log event only: which part of a malformed record is wrong, or
  // why a budget is exhausted.
  detail?: string;
  // Budget refusals only (C-7): the body names the budget's classification.
  classification?: string;
  budgetState?: "stale" | "missing" | "fresh" | "degraded";
}

const REFUSAL_BUDGET_STATE: Partial<Record<RefusalReason, "stale" | "missing">> = {
  budget_state_missing: "missing",
  aggregate_budget_state_missing: "missing",
  budget_state_invalid: "stale",
  aggregate_budget_state_invalid: "stale",
  budget_state_stale: "stale",
  aggregate_budget_state_stale: "stale",
};

export function refuse(reason: RefusalReason, projectId?: string, detail?: string): ResolveRefusal {
  const refusal: ResolveRefusal = { refused: true, reason, httpStatus: REFUSAL_STATUS[reason] };
  if (projectId !== undefined) refusal.projectId = projectId;
  if (detail !== undefined) refusal.detail = detail;
  const budgetState = REFUSAL_BUDGET_STATE[reason];
  if (budgetState) refusal.budgetState = budgetState;
  return refusal;
}

// A read the decision depends on that failed is raised to the caller, which
// owns error translation (http-handler.ts answers 503).
export function settledValue<T>(result: PromiseSettledResult<T>): T {
  if (result.status === "rejected") throw result.reason;
  return result.value;
}
