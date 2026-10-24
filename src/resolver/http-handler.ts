// The resolver's HTTP layer (ADR-0003), framework-free so it is unit-testable
// the way decide.ts is (tests/resolver-http-handler.test.ts). function-app.ts
// is the thin Azure Functions registration around it.
//
// Trust boundary (ADR-0009): only APIM's managed identity can call the
// resolver. App Service Authentication on the Function App enforces that,
// before this code runs; it is the one place that decides who may call. The
// guards below only check that it is on and that it ran, and fail closed
// otherwise: the body's personId is trusted solely because of that gate.
//
// Responses collapse the internal refusal reasons into a small external set
// before they leave this process (docs/UNKNOWNS.md U-12). The real reason goes
// to the log as one JSON event with reason codes and ids only, for alerts.

import type { ConfigProblem } from "./config.ts";
import type { ResolveDependencies, ResolveInput, ResolveResult } from "./decide.ts";
import { refusalStatus, resolveRequest } from "./decide.ts";
import type { BudgetEnforcement } from "./freshness.ts";
import { readMyUsage } from "./my-usage.ts";

export interface HandlerResponse {
  status: number;
  jsonBody: Record<string, unknown>;
}

export type ResolverReadiness =
  | { ready: true; budgetEnforcement: BudgetEnforcement; requestDeadlineMs: number; reads: ResolveDependencies }
  | { ready: false; problems: ConfigProblem[] };

export interface ResolverRuntime {
  readiness: ResolverReadiness;
  now: () => Date;
  log: (line: string) => void;
}

// Per-request facts the Functions host supplies.
export interface ResolverRequestContext {
  platformAuthEnabled: boolean; // WEBSITE_AUTH_ENABLED
  authenticatedPrincipal: boolean; // App Service set X-MS-CLIENT-PRINCIPAL*
  body?: unknown;
}

export const EVENT_SCHEMA = "ccof.resolver.event.v1";

// Reasons this layer adds; every one of them means "try again shortly".
const HANDLER_UNAVAILABLE_REASONS = new Set([
  "resolver_config_invalid",
  "platform_authentication_disabled",
  "registry_read_failed",
  "resolver_deadline_exceeded",
]);

// Internal reason -> small, uniform external category. A caller learns "not
// authorized" or "try again shortly", never which check failed (U-12). The
// exceptions concern only the caller's own verified memberships (personId is
// the caller's oid), so they reveal nothing about other projects:
// project_selection_required, which the caller can act on, and the two budget
// refusals (C-7), which the gateway names in its message.
const PASSED_THROUGH = new Set(["project_selection_required", "budget_exhausted", "aggregate_budget_exhausted"]);
const NAMES_THE_BUDGET = new Set(["budget_exhausted", "aggregate_budget_exhausted"]);

export function externalCategory(reason: string): string {
  if (PASSED_THROUGH.has(reason)) return reason;
  return refusalStatus(reason) === 503 || HANDLER_UNAVAILABLE_REASONS.has(reason)
    ? "temporarily_unavailable"
    : "not_authorized";
}

// The platform injects WEBSITE_AUTH_ENABLED (MS Learn, "Environment variables
// and app settings in Azure App Service"); anything else means it is off.
export function isPlatformAuthEnabled(value: string | undefined): boolean {
  return value?.toLowerCase() === "true";
}

// App Service sets these for authenticated callers, and external requests
// cannot set them while authentication is on (MS Learn, "Work with user
// identities in AuthN/AuthZ").
export function hasPlatformPrincipal(header: (name: string) => string | null | undefined): boolean {
  return Boolean(header("x-ms-client-principal-id") || header("x-ms-client-principal"));
}

const UNAVAILABLE = { error: "temporarily_unavailable", resolverOutcome: "unavailable" } as const;
const REQUEST_ID = /^[A-Za-z0-9-]{1,64}$/;
const ERROR_CODE = /^[A-Za-z0-9_.-]{1,32}$/;

interface EventIds {
  requestId?: string;
  personId?: string;
  subscriptionId?: string;
  projectId?: string;
}

interface ResolverEvent extends EventIds {
  event: "refused" | "degraded" | "unhealthy" | "failed";
  reason?: string;
  reasons?: string[];
  detail?: string;
  httpStatus?: number;
  problems?: string[];
  errorCode?: string;
}

// One JSON line per event; `schema` first so a query can match on the prefix.
function logEvent(runtime: ResolverRuntime, event: ResolverEvent): void {
  const { event: name, reason, reasons, detail, httpStatus, problems, errorCode, requestId, personId, subscriptionId, projectId } =
    event;
  runtime.log(
    JSON.stringify({
      schema: EVENT_SCHEMA,
      event: name,
      reason,
      reasons,
      detail,
      httpStatus,
      problems,
      errorCode,
      requestId,
      personId,
      subscriptionId,
      projectId,
    }),
  );
}

// Guards shared by every route, in order: is the platform gate on, did it
// run, is the resolver configured.
type GuardFailure = "platform_authentication_disabled" | "request_not_authenticated" | "resolver_config_invalid";
type ReadyState = Extract<ResolverReadiness, { ready: true }>;
type Gate = { open: true; readiness: ReadyState } | { open: false; failure: GuardFailure };

function openGate(request: ResolverRequestContext, runtime: ResolverRuntime): Gate {
  if (!request.platformAuthEnabled) return { open: false, failure: "platform_authentication_disabled" };
  if (!request.authenticatedPrincipal) return { open: false, failure: "request_not_authenticated" };
  if (!runtime.readiness.ready) return { open: false, failure: "resolver_config_invalid" };
  return { open: true, readiness: runtime.readiness };
}

// Logs the guard failure; every route reports it the same way (AC11).
function logGuardFailure(failure: GuardFailure, runtime: ResolverRuntime): void {
  if (failure === "request_not_authenticated") {
    // Nothing from an unauthenticated body is logged.
    logEvent(runtime, { event: "refused", reason: failure, httpStatus: 401 });
    return;
  }
  const problems =
    failure === "resolver_config_invalid" && !runtime.readiness.ready
      ? runtime.readiness.problems.map(({ setting, problem }) => `${setting}:${problem}`)
      : undefined;
  logEvent(runtime, { event: "unhealthy", reason: failure, problems });
}

function refuseByGuard(failure: GuardFailure, runtime: ResolverRuntime): HandlerResponse {
  logGuardFailure(failure, runtime);
  if (failure === "request_not_authenticated") return { status: 401, jsonBody: { error: "not_authenticated" } };
  return { status: 503, jsonBody: { ...UNAVAILABLE } };
}

// The error's code, or its name when it has none (a credential failure or a
// code fault), never its message: messages can carry URLs and addresses.
const DEADLINE_EXCEEDED = Symbol("resolver_deadline_exceeded");

// The SDK retries a hung read up to 120 times and sleeps between some retries
// (@azure/cosmos 4.10.1, TimeoutFailoverRetryPolicy and retryUtility), so its
// own limits do not bound a request. This does: the answer leaves at the
// deadline whatever the reads are doing. One signal per request reaches every
// read (registry-reads.ts hands it to the SDK); it aborts at the deadline, and
// after the answer for any read still pending, so no read outlives its request.
async function withinDeadline<T>(work: (signal: AbortSignal) => Promise<T>, deadlineMs: number): Promise<T> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const expiry = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(DEADLINE_EXCEEDED);
    }, deadlineMs);
  });
  try {
    return await Promise.race([work(controller.signal), expiry]);
  } catch (err: unknown) {
    // A read may report the abort before the timer's own rejection arrives.
    throw controller.signal.aborted ? DEADLINE_EXCEEDED : err;
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}

function errorCodeOf(err: unknown): string | undefined {
  if (typeof err !== "object" || err === null) return undefined;
  const raw = "code" in err && err.code !== undefined ? String(err.code) : "name" in err ? String(err.name) : undefined;
  return raw !== undefined && ERROR_CODE.test(raw) ? raw : undefined;
}

// The request body (docs/PILOT.md C-1): personId is required; subscriptionId
// and projectId are optional, and absent or null means not sent. A present
// value must be a non-empty string; anything else is a malformed request.
function parseResolveBody(body: unknown): ResolveInput | null {
  if (typeof body !== "object" || body === null) return null;
  const { personId, subscriptionId, projectId } = body as Record<string, unknown>;
  if (typeof personId !== "string" || personId === "") return null;
  const input: ResolveInput = { personId };
  for (const [name, value] of [["subscriptionId", subscriptionId], ["projectId", projectId]] as const) {
    if (value === undefined || value === null) continue;
    if (typeof value !== "string" || value === "") return null;
    input[name] = value;
  }
  return input;
}

export async function handleResolveRequest(
  request: ResolverRequestContext,
  runtime: ResolverRuntime,
): Promise<HandlerResponse> {
  const gate = openGate(request, runtime);
  if (!gate.open) return refuseByGuard(gate.failure, runtime);
  const { reads, budgetEnforcement, requestDeadlineMs } = gate.readiness;

  const input = parseResolveBody(request.body);
  if (!input) {
    logEvent(runtime, { event: "refused", reason: "invalid_request", httpStatus: 400 });
    return { status: 400, jsonBody: { error: "invalid_request" } };
  }

  // The selector is not logged: telemetry carries only a resolved projectId
  // (ADR-0006 decision 4).
  const ids: EventIds = { personId: input.personId, subscriptionId: input.subscriptionId };
  const requestId = (request.body as Record<string, unknown>).requestId;
  if (typeof requestId === "string" && REQUEST_ID.test(requestId)) ids.requestId = requestId;

  let result: ResolveResult;
  try {
    const now = runtime.now();
    result = await withinDeadline((signal) => resolveRequest(input, reads, { now, budgetEnforcement, signal }), requestDeadlineMs);
  } catch (err: unknown) {
    // A registry read failed or did not finish in time: the resolver's fault,
    // not the developer's.
    const reason = err === DEADLINE_EXCEEDED ? "resolver_deadline_exceeded" : "registry_read_failed";
    logEvent(runtime, { event: "failed", reason, errorCode: errorCodeOf(err), ...ids });
    return { status: 503, jsonBody: { ...UNAVAILABLE } };
  }

  if (result.refused) {
    logEvent(runtime, {
      event: "refused",
      reason: result.reason,
      detail: result.detail,
      httpStatus: result.httpStatus,
      ...ids,
      projectId: result.projectId,
    });
    const jsonBody: Record<string, unknown> = {
      error: externalCategory(result.reason),
      resolverOutcome: result.httpStatus === 503 ? "unavailable" : "refused",
    };
    if (NAMES_THE_BUDGET.has(result.reason)) {
      jsonBody.projectId = result.projectId;
      jsonBody.classification = result.classification;
    }
    if (result.budgetState) jsonBody.budgetState = result.budgetState;
    return { status: result.httpStatus, jsonBody };
  }

  if (result.degraded) {
    logEvent(runtime, { event: "degraded", reasons: result.degradedReasons, ...ids, projectId: result.projectId });
  }
  return { status: 200, jsonBody: { ...result, resolverOutcome: result.degraded ? "degraded" : "success" } };
}

// POST /api/me/usage: the caller's own spend and budget per project (my-usage.ts). Same gate as
// /api/resolve: only APIM calls it, with personId taken from the developer's validated token.
// The body is exactly {"personId": "<oid>"}: a GUID, nothing else.
const PERSON_GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export async function handleMyUsageRequest(request: ResolverRequestContext, runtime: ResolverRuntime): Promise<HandlerResponse> {
  const gate = openGate(request, runtime);
  if (!gate.open) return refuseByGuard(gate.failure, runtime);
  const body = request.body as Record<string, unknown> | null | undefined;
  if (typeof body !== "object" || body === null || Object.keys(body).length !== 1 ||
    typeof body.personId !== "string" || !PERSON_GUID.test(body.personId)) {
    logEvent(runtime, { event: "refused", reason: "invalid_usage_request", httpStatus: 400 });
    return { status: 400, jsonBody: { error: "invalid_request" } };
  }
  const personId = body.personId;
  try {
    const now = runtime.now();
    const usage = await withinDeadline((signal) => readMyUsage(personId, gate.readiness.reads, now, signal), gate.readiness.requestDeadlineMs);
    return { status: 200, jsonBody: { ...usage } };
  } catch (err: unknown) {
    const reason = err === DEADLINE_EXCEEDED ? "resolver_deadline_exceeded" : "registry_read_failed";
    logEvent(runtime, { event: "failed", reason, errorCode: errorCodeOf(err), personId });
    return { status: 503, jsonBody: { ...UNAVAILABLE } };
  }
}

// GET /api/health: the resolver reports itself unhealthy (ADR-0008 decision 5)
// behind the same gate as /api/resolve, and logs it the same way. It reports
// configuration and authentication readiness, not whether Cosmos answers.
export function handleHealthRequest(request: ResolverRequestContext, runtime: ResolverRuntime): HandlerResponse {
  const gate = openGate(request, runtime);
  if (gate.open) return { status: 200, jsonBody: { status: "healthy" } };
  logGuardFailure(gate.failure, runtime);
  if (gate.failure === "request_not_authenticated") return { status: 401, jsonBody: { error: "not_authenticated" } };
  return { status: 503, jsonBody: { status: "unhealthy", reason: gate.failure } };
}
