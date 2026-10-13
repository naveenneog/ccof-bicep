// Resolver core decision logic (ADR-0003). Pure, framework-free: every
// Cosmos read and the clock are injected, so this module is testable without a
// Functions host or a real Cosmos account (tests/resolver-*.test.ts).
//
// Given a person and, optionally, a subscription key or a project selector,
// it selects one of the person's memberships (select-membership.ts: the key
// is cross-checked against entitlement, ADR-0002; a selector only chooses,
// docs/PILOT.md C-1) and returns a routing, limits and budget decision or a
// named, fail-closed refusal.
//
// Freshness (ADR-0008): entitlement records persist until a sync changes them,
// and stale budget state is served, marked degraded, until the configured hard
// limit. In token-limits-only mode (docs/PILOT.md C-3) no budget document is
// read at all.

import type { BackendDescriptor, BackendRecord } from "./backend.ts";
import { checkBackendRecord } from "./backend.ts";
import type { BudgetEnforcement, BudgetStalenessPolicy, ValidMembership } from "./freshness.ts";
import { classifyBudgetValidity, MAX_TOKENS_PER_MINUTE, validateMembership } from "./freshness.ts";
import type { RefusalReason, ResolveRefusal } from "./refusals.ts";
import { refuse, settledValue } from "./refusals.ts";
import { selectByKey, selectBySelector } from "./select-membership.ts";

export { refusalStatus } from "./refusals.ts";
export type { RefusalReason, ResolveRefusal } from "./refusals.ts";

export interface ResolveInput {
  personId: string;
  // The per-project key path (ADR-0002); optional since M1.7.
  subscriptionId?: string;
  // The project selector (docs/PILOT.md C-1).
  projectId?: string;
}

export interface ResolveContext {
  // Read once per request by the caller; this module never reads the clock.
  now: Date;
  budgetEnforcement: BudgetEnforcement;
  // The request's abort signal (http-handler.ts): every read gets it, so no
  // read outlives the request.
  signal?: AbortSignal;
}

export interface SubscriptionIndexRecord {
  subscriptionId: string;
  personId: string;
  projectId: string;
  classification: string;
  status: string;
}

// The periods llm-token-limit accepts (docs/PILOT.md C-2).
export type TokenQuotaPeriod = "Hourly" | "Daily" | "Weekly" | "Monthly" | "Yearly";

// Each value is a positive integer, or null for "the gateway applies no such
// limit"; a quota and its period are both set or both null.
export interface TokenLimit {
  tokensPerMinute: number | null;
  tokenQuota: number | null;
  tokenQuotaPeriod: TokenQuotaPeriod | null;
}

export interface TokenLimits {
  person: TokenLimit;
  group: TokenLimit;
}

// Written only by the sync (docs/PILOT.md C-4), which copies classification,
// classificationGroupId, modelAllowList, backendId, aggregateMode and
// tokenLimits from the projects document. WP-SYNC mirrors this type: change it
// additively only.
export interface ProjectMembership {
  projectId: string;
  classification: string;
  classificationGroupId: string;
  // Only on the per-project key path (ADR-0002); optional since M1.7.
  subscriptionId?: string;
  modelAllowList: string[];
  backendId: string;
  aggregateMode: "strict" | "notify";
  tokenLimits: TokenLimits;
  denormalizedAt: string;
  joinedAt: string;
  status: string;
}

export interface EntitlementRecord {
  id: string;
  personId: string;
  projectMemberships: ProjectMembership[];
  generation: number;
  lastVerifiedAt: string;
  // Legacy lease from before ADR-0008; writers no longer set it.
  expiresAt?: string;
}

// Written by the reconciler (docs/PILOT.md C-7, WP-REC; exhausted means
// spentCcu >= budgetCcu). The resolver reads only exhausted, validUntil and
// the ceiling; the other fields are WP-REC's.
export interface BudgetStateRecord {
  personId: string;
  projectId: string;
  exhausted: boolean;
  realtimeCeilingTokensPerMinute: number;
  validUntil: string;
}

export interface AggregateBudgetStateRecord {
  scopeId: string;
  exhausted: boolean;
  validUntil: string;
}

export interface ResolveDependencies {
  readSubscriptionIndex: (subscriptionId: string, signal?: AbortSignal) => Promise<SubscriptionIndexRecord | null>;
  readEntitlement: (personId: string, signal?: AbortSignal) => Promise<EntitlementRecord | null>;
  readBudgetState: (personId: string, projectId: string, signal?: AbortSignal) => Promise<BudgetStateRecord | null>;
  readAggregateBudgetState: (scopeId: string, signal?: AbortSignal) => Promise<AggregateBudgetStateRecord | null>;
  readBackend: (backendId: string, signal?: AbortSignal) => Promise<BackendRecord | null>;
}

export interface ResolveSuccess {
  refused: false;
  personId: string;
  projectId: string;
  classification: string;
  backendId: string;
  modelAllowList: string[];
  tokenLimits: TokenLimits;
  budgetEnforcement: BudgetEnforcement["mode"];
  // Whether the gateway must apply the CCU aggregate ceiling; false whenever
  // budgets are not enforced.
  aggregateStrict: boolean;
  aggregateState: AggregateBudgetStateRecord | null;
  personBudgetScope: string;
  // null in token-limits-only mode: no budget document was read.
  personCeilingTokensPerMinute: number | null;
  degraded: boolean;
  degradedReasons: string[];
  // WP-TEL's ccof.resolver.v1 vocabulary: null when no budget was evaluated
  // (token-limits-only mode); "degraded" only for stale state.
  budgetState: "fresh" | "degraded" | null;
  // C-8: present only when the backend registry has a document for backendId.
  backend?: BackendDescriptor;
}

export type ResolveResult = ResolveRefusal | ResolveSuccess;

type StateCheck = { ok: true; degradedReason: string | null } | { ok: false; reason: RefusalReason };

// Applies ADR-0008's staleness table to one present record. The same policy
// covers the person's state and a strict scope's aggregate state. The
// exhausted flag must be a boolean: a record without it cannot show that
// budget remains (C-7).
function checkBudgetState(
  record: { validUntil?: unknown; realtimeCeilingTokensPerMinute?: unknown; exhausted?: unknown },
  scope: "person" | "aggregate",
  nowMs: number,
  policy: BudgetStalenessPolicy,
): StateCheck {
  const prefix = scope === "aggregate" ? "aggregate_" : "";
  if (typeof record.exhausted !== "boolean") return { ok: false, reason: `${prefix}budget_state_invalid` };
  if (scope === "person") {
    const ceiling = record.realtimeCeilingTokensPerMinute;
    if (typeof ceiling !== "number" || !Number.isSafeInteger(ceiling) || ceiling < 0 || ceiling > MAX_TOKENS_PER_MINUTE) {
      return { ok: false, reason: "budget_state_invalid" };
    }
  }
  switch (classifyBudgetValidity(record.validUntil, nowMs, policy)) {
    case "fresh":
      return { ok: true, degradedReason: null };
    case "stale_within_grace":
      return { ok: true, degradedReason: `${prefix}budget_state_stale_within_grace` };
    case "stale_beyond_grace":
      return { ok: true, degradedReason: `${prefix}budget_state_stale_beyond_grace` };
    case "stale":
      return { ok: false, reason: `${prefix}budget_state_stale` };
    case "invalid":
      return { ok: false, reason: `${prefix}budget_state_invalid` };
  }
}

type Resolved = Omit<
  ResolveSuccess,
  | "budgetEnforcement"
  | "aggregateStrict"
  | "aggregateState"
  | "personCeilingTokensPerMinute"
  | "degraded"
  | "degradedReasons"
  | "budgetState"
>;

export async function resolveRequest(
  input: ResolveInput,
  deps: ResolveDependencies,
  context: ResolveContext,
): Promise<ResolveResult> {
  // Trust boundary (ADR-0009): `input.personId` is trusted only because only
  // APIM's managed identity can call the resolver (App Service Authentication
  // on the Function App), and APIM sets it from the `oid` of the developer
  // token it validated. This function decides authorization only: is this
  // person entitled to the project the request names or implies.
  const nowMs = context.now.getTime();
  const { signal } = context;
  const selection =
    input.subscriptionId !== undefined
      ? await selectByKey({ ...input, subscriptionId: input.subscriptionId }, deps, nowMs, signal)
      : await selectBySelector(input, deps, nowMs, signal);
  if ("refused" in selection) return selection;

  // Every field the gateway routes, filters or limits on is checked here; a
  // record the gateway could not apply is that person's 503, not a 200.
  const checked = validateMembership(selection.membership as unknown as Record<string, unknown>);
  const claimedProjectId = typeof selection.membership.projectId === "string" ? selection.membership.projectId : undefined;
  if (!checked.ok) return refuse("entitlement_record_invalid", checked.detail === "invalid_project_id" ? undefined : claimedProjectId, checked.detail);
  const membership = checked.value;

  const resolved: Resolved = {
    refused: false,
    personId: input.personId,
    projectId: membership.projectId,
    classification: membership.classification,
    backendId: membership.backendId,
    modelAllowList: membership.modelAllowList,
    tokenLimits: membership.tokenLimits,
    personBudgetScope: `${input.personId}:${membership.projectId}`,
  };

  // Wave 2 (docs/ARCHITECTURE.md §3): every read keyed by the verified
  // membership starts together. allSettled observes each read, so one that
  // fails after a refusal is decided never becomes an unhandled rejection.
  const enforcement = context.budgetEnforcement;
  if (enforcement.mode === "token-limits-only") {
    const [backendRead] = await Promise.allSettled([deps.readBackend(membership.backendId, signal)]);
    return withBackend(backendRead, membership, {
      ...resolved,
      budgetEnforcement: "token-limits-only",
      aggregateStrict: false,
      aggregateState: null,
      personCeilingTokensPerMinute: null,
      degraded: false,
      degradedReasons: [],
      budgetState: null,
    });
  }
  return resolveBudgetState(resolved, membership, deps, nowMs, enforcement.staleness, signal);
}

// C-8: the descriptor from the backend registry, checked last, so a budget
// refusal stands even when the registry read fails.
function withBackend(
  read: PromiseSettledResult<BackendRecord | null>,
  membership: ValidMembership,
  success: ResolveSuccess,
): ResolveResult {
  const verdict = checkBackendRecord(settledValue(read), membership.backendId);
  switch (verdict.kind) {
    case "legacy":
      return success;
    case "active":
      return { ...success, backend: verdict.descriptor };
    case "not_active":
      return refuse("backend_not_active", membership.projectId);
    case "invalid":
      return refuse("backend_record_invalid", membership.projectId, verdict.detail);
  }
}

function refuseExhausted(
  reason: "budget_exhausted" | "aggregate_budget_exhausted",
  membership: ValidMembership,
  staleReasons: string[],
): ResolveRefusal {
  return {
    ...refuse(reason, membership.projectId),
    classification: membership.classification,
    budgetState: staleReasons.length > 0 ? "degraded" : "fresh",
  };
}

// Records a promise's outcome as soon as it settles, without waiting for it;
// the attached handlers also keep a later rejection from going unhandled.
function observe<T>(promise: Promise<T>): { result?: PromiseSettledResult<T> } {
  const box: { result?: PromiseSettledResult<T> } = {};
  promise.then(
    (value) => (box.result = { status: "fulfilled", value }),
    (reason: unknown) => (box.result = { status: "rejected", reason }),
  );
  return box;
}

async function resolveBudgetState(
  resolved: Resolved,
  membership: ValidMembership,
  deps: ResolveDependencies,
  nowMs: number,
  staleness: BudgetStalenessPolicy,
  signal?: AbortSignal,
): Promise<ResolveResult> {
  const aggregateStrict = membership.aggregateMode === "strict";
  const scopeId = `${resolved.projectId}:${membership.classification}`;
  // The aggregate is read in both modes since C-7: notify reads it to flag an
  // exhausted group. Only strict waits for it; a notify request is answered
  // when the reads it needs are in, with the flag if the group read is too.
  const budgetPromise = deps.readBudgetState(resolved.personId, resolved.projectId, signal);
  const aggregatePromise = deps.readAggregateBudgetState(scopeId, signal);
  const backendPromise = deps.readBackend(membership.backendId, signal);
  const notifyAggregate = aggregateStrict ? undefined : observe(aggregatePromise);
  const [budgetRead, aggregateRead, backendRead] = await Promise.allSettled([
    budgetPromise,
    aggregateStrict ? aggregatePromise : Promise.resolve(null),
    backendPromise,
  ]);

  // Fail closed: missing, invalid or too-stale reconciler state is never
  // evidence the person has budget left. Validity is checked before the
  // exhausted flag (C-7).
  const staleReasons: string[] = [];
  const budget = settledValue(budgetRead);
  if (!budget) return refuse("budget_state_missing", resolved.projectId);
  const personCheck = checkBudgetState(budget, "person", nowMs, staleness);
  if (!personCheck.ok) return refuse(personCheck.reason, resolved.projectId);
  if (personCheck.degradedReason) staleReasons.push(personCheck.degradedReason);
  if (budget.exhausted) return refuseExhausted("budget_exhausted", membership, staleReasons);

  const notices: string[] = [];
  let aggregateState: AggregateBudgetStateRecord | null = null;
  if (aggregateStrict) {
    aggregateState = settledValue(aggregateRead);
    if (!aggregateState) return refuse("aggregate_budget_state_missing", resolved.projectId);
    const aggregateCheck = checkBudgetState(aggregateState, "aggregate", nowMs, staleness);
    if (!aggregateCheck.ok) return refuse(aggregateCheck.reason, resolved.projectId);
    if (aggregateCheck.degradedReason) staleReasons.push(aggregateCheck.degradedReason);
    if (aggregateState.exhausted) return refuseExhausted("aggregate_budget_exhausted", membership, staleReasons);
  } else {
    // Notify never refuses: an unfinished, unreadable, missing, invalid or
    // too-stale aggregate is ignored, and only a trustworthy exhausted flag is
    // noted.
    const settled = notifyAggregate?.result;
    const notifyState = settled?.status === "fulfilled" ? settled.value : null;
    if (notifyState && checkBudgetState(notifyState, "aggregate", nowMs, staleness).ok && notifyState.exhausted) {
      notices.push("aggregate_budget_exhausted_notify");
    }
  }

  const degradedReasons = [...staleReasons, ...notices];
  return withBackend(backendRead, membership, {
    ...resolved,
    budgetEnforcement: "budget-state",
    aggregateStrict,
    aggregateState,
    // The last-known ceiling, also while degraded (ADR-0008 decision 3).
    personCeilingTokensPerMinute: budget.realtimeCeilingTokensPerMinute,
    degraded: degradedReasons.length > 0,
    degradedReasons,
    budgetState: staleReasons.length > 0 ? "degraded" : "fresh",
  });
}
