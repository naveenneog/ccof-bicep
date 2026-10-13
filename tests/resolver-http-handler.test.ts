// RED-first unit tests for the HTTP-handler layer's framework-free logic
// (src/resolver/http-handler.ts): request-shape validation, the
// internal-reason -> external-category collapse (docs/UNKNOWNS.md U-12), the
// configuration and platform-authentication guards (ADR-0008, ADR-0009), the
// telemetry fields WP-GW copies, and the one-line JSON log events.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  externalCategory,
  handleHealthRequest,
  handleResolveRequest,
  hasPlatformPrincipal,
  isPlatformAuthEnabled,
} from "../src/resolver/http-handler.ts";
import type { ResolverRuntime } from "../src/resolver/http-handler.ts";
import type { ResolveDependencies } from "../src/resolver/decide.ts";
import {
  activeBudgetState,
  activeMembership,
  activeSubscriptionIndex,
  entitlementWithMembership,
  fakeReads,
  POLICY,
  RESOLVE_NOW,
  secondsAfterValidUntil,
  STD_FAMILY_POLICY,
} from "./helpers/resolver-fixtures.ts";

const validBody = { personId: "person-1", subscriptionId: "sub-abc" };
const authenticated = { platformAuthEnabled: true, authenticatedPrincipal: true };

// Long enough that only the deadline tests below ever reach it.
const TEST_DEADLINE_MS = 5000;

function runtime(
  options: { reads?: ResolveDependencies; now?: Date; logs?: string[]; requestDeadlineMs?: number } = {},
): ResolverRuntime {
  const logs = options.logs ?? [];
  return {
    readiness: {
      ready: true,
      budgetEnforcement: { mode: "budget-state", staleness: POLICY },
      requestDeadlineMs: options.requestDeadlineMs ?? TEST_DEADLINE_MS,
      reads: options.reads ?? fakeReads(),
    },
    now: () => options.now ?? RESOLVE_NOW,
    log: (line) => logs.push(line),
  };
}

// The pilot's configuration (docs/PILOT.md C-3).
function pilotRuntime(options: { reads?: ResolveDependencies; logs?: string[] } = {}): ResolverRuntime {
  const logs = options.logs ?? [];
  return {
    readiness: {
      ready: true,
      budgetEnforcement: { mode: "token-limits-only" },
      requestDeadlineMs: TEST_DEADLINE_MS,
      reads: options.reads ?? fakeReads(),
    },
    now: () => RESOLVE_NOW,
    log: (line) => logs.push(line),
  };
}

function unconfiguredRuntime(logs: string[] = []): ResolverRuntime {
  return {
    readiness: { ready: false, problems: [{ setting: "RESOLVER_BUDGET_STATE_GRACE_SECONDS", problem: "missing" }] },
    now: () => RESOLVE_NOW,
    log: (line) => logs.push(line),
  };
}

const ALLOWED_EVENT_KEYS = new Set([
  "schema", "event", "reason", "reasons", "detail", "httpStatus", "problems", "errorCode",
  "requestId", "personId", "subscriptionId", "projectId",
]);

function events(logs: string[]) {
  return logs.map((line) => JSON.parse(line) as Record<string, unknown>);
}

// ---- external categories (U-12) ----

test("externalCategory collapses budget-missing reasons to temporarily_unavailable", () => {
  assert.equal(externalCategory("budget_state_missing"), "temporarily_unavailable");
  assert.equal(externalCategory("aggregate_budget_state_missing"), "temporarily_unavailable");
});

test("externalCategory collapses every other refusal reason to not_authorized", () => {
  // The whole point (U-12): an attacker must not distinguish *why* they were
  // refused from the response alone.
  for (const reason of [
    "unknown_subscription",
    "subscription_person_mismatch",
    "no_entitlement",
    "project_mismatch",
    "classification_mismatch",
  ]) {
    assert.equal(externalCategory(reason), "not_authorized");
  }
});

test("externalCategory: every 503 reason is temporarily_unavailable, a passed legacy lease is not_authorized", () => {
  for (const reason of [
    "budget_state_stale",
    "aggregate_budget_state_stale",
    "budget_state_invalid",
    "aggregate_budget_state_invalid",
    "entitlement_record_invalid",
    "resolver_config_invalid",
    "platform_authentication_disabled",
  ]) {
    assert.equal(externalCategory(reason), "temporarily_unavailable", reason);
  }
  assert.equal(externalCategory("entitlement_legacy_expired"), "not_authorized");
  assert.equal(externalCategory("a_reason_nobody_defined"), "not_authorized");
});

// ---- request validation ----

test("rejects a body missing personId with 400 invalid_request", async () => {
  // Before M1.7 a body without subscriptionId was also rejected; docs/PILOT.md
  // C-1 made subscriptionId optional, so that case is now the selector path.
  for (const body of [{ subscriptionId: "sub-abc" }, { projectId: "SAMPLEORGAIAZ103" }, {}]) {
    const response = await handleResolveRequest({ ...authenticated, body }, runtime());
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.deepEqual(response.jsonBody, { error: "invalid_request" });
  }
});

test("rejects optional fields that are present but empty or not strings with 400 invalid_request", async () => {
  for (const extra of [
    { subscriptionId: "" },
    { projectId: "" },
    { subscriptionId: 42 },
    { projectId: ["SAMPLEORGAIAZ103"] },
    { personId: "" },
  ]) {
    const response = await handleResolveRequest(
      { ...authenticated, body: { personId: "person-1", ...extra } },
      pilotRuntime({ reads: fakeReads({ readEntitlement: async () => entitlementWithMembership }) }),
    );
    assert.equal(response.status, 400, JSON.stringify(extra));
    assert.deepEqual(response.jsonBody, { error: "invalid_request" });
  }
});

// ---- the pilot contract (docs/PILOT.md C-1 to C-3) ----

test("C-1: a body with personId only resolves the single active membership; null optional fields count as absent", async () => {
  for (const body of [{ personId: "person-1" }, { personId: "person-1", subscriptionId: null, projectId: null }]) {
    const response = await handleResolveRequest({ ...authenticated, body }, pilotRuntime());
    assert.equal(response.status, 200, JSON.stringify(body));
    assert.equal(response.jsonBody.projectId, "SAMPLEORGAIAZ103");
  }
});

test("C-1: project_selection_required is 400 with its own error, refused, and logged with ids only", async () => {
  const logs: string[] = [];
  const second = { ...activeMembership, projectId: "SAMPLEORGAIAZ210" };
  const response = await handleResolveRequest(
    { ...authenticated, body: { personId: "person-1", requestId: "00000000-0000-4000-8000-000001101110" } },
    pilotRuntime({
      logs,
      reads: fakeReads({ readEntitlement: async () => ({ ...entitlementWithMembership, projectMemberships: [activeMembership, second] }) }),
    }),
  );
  assert.equal(response.status, 400);
  assert.deepEqual(response.jsonBody, { error: "project_selection_required", resolverOutcome: "refused" });
  assert.deepEqual(events(logs), [
    {
      schema: "ccof.resolver.event.v1",
      event: "refused",
      reason: "project_selection_required",
      httpStatus: 400,
      requestId: "00000000-0000-4000-8000-000001101110",
      personId: "person-1",
    },
  ]);
});

test("externalCategory passes project_selection_required through: the caller can act on it, and it concerns only their own memberships", () => {
  assert.equal(externalCategory("project_selection_required"), "project_selection_required");
});

test("C-1: a selector that is not one of the person's projects is 403 not_authorized and is not logged", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: { personId: "person-1", projectId: "SOMEONE-ELSES-PROJECT" } },
    pilotRuntime({ logs }),
  );
  assert.equal(response.status, 403);
  assert.deepEqual(response.jsonBody, { error: "not_authorized", resolverOutcome: "refused" });
  assert.doesNotMatch(logs.join("\n"), /SOMEONE-ELSES-PROJECT/);
});

test("C-2/C-3: a token-limits-only resolution carries familyPolicy and says budgets are not enforced", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: { personId: "person-1", projectId: "SAMPLEORGAIAZ103" } },
    pilotRuntime({ logs }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(response.jsonBody.familyPolicy, STD_FAMILY_POLICY);
  assert.equal(response.jsonBody.budgetEnforcement, "token-limits-only");
  // WP-TEL's vocabulary: null when no budget was evaluated.
  assert.equal(response.jsonBody.budgetState, null);
  assert.equal(response.jsonBody.personCeilingTokensPerMinute, null);
  assert.equal(response.jsonBody.resolverOutcome, "success");
  assert.deepEqual(logs, []);
});

test("rejects a non-object body with 400 invalid_request", async () => {
  const response = await handleResolveRequest({ ...authenticated, body: "not an object" }, runtime());
  assert.equal(response.status, 400);
  assert.deepEqual(response.jsonBody, { error: "invalid_request" });
});

test("returns 200 with the full resolution for a valid request", async () => {
  const response = await handleResolveRequest({ ...authenticated, body: validBody }, runtime());
  assert.equal(response.status, 200);
  assert.equal(response.jsonBody.refused, false);
  assert.equal(response.jsonBody.backendId, "foundry-sample-hub");
});

test("maps a refusal to its httpStatus and a collapsed external category, logging the real reason", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: { personId: "person-2", subscriptionId: "sub-abc" } },
    runtime({ logs }),
  );
  assert.equal(response.status, 403);
  assert.deepEqual(response.jsonBody, { error: "not_authorized", resolverOutcome: "refused" });
  assert.ok(logs.some((l) => l.includes("subscription_person_mismatch")));
});

// ---- telemetry fields for WP-GW (ccof.resolver.v1) ----

test("a fresh resolution says resolverOutcome success and budgetState fresh, and logs nothing", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest({ ...authenticated, body: validBody }, runtime({ logs }));
  assert.equal(response.jsonBody.resolverOutcome, "success");
  assert.equal(response.jsonBody.budgetState, "fresh");
  assert.equal(response.jsonBody.degraded, false);
  assert.deepEqual(logs, []);
});

test("a degraded serve says resolverOutcome degraded and logs one degraded event with ids only", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: { ...validBody, requestId: "00000000-0000-4000-8000-000001101110" } },
    runtime({ logs, now: secondsAfterValidUntil(30) }),
  );
  assert.equal(response.status, 200);
  assert.equal(response.jsonBody.resolverOutcome, "degraded");
  assert.equal(response.jsonBody.budgetState, "degraded");
  assert.equal(response.jsonBody.personCeilingTokensPerMinute, 4200);
  assert.deepEqual(events(logs), [
    {
      schema: "ccof.resolver.event.v1",
      event: "degraded",
      reasons: ["budget_state_stale_within_grace"],
      requestId: "00000000-0000-4000-8000-000001101110",
      personId: "person-1",
      subscriptionId: "sub-abc",
      projectId: "SAMPLEORGAIAZ103",
    },
  ]);
});

test("a stale-state refusal is 503 temporarily_unavailable, unavailable, budgetState stale, and logged", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: validBody },
    runtime({ logs, now: secondsAfterValidUntil(3601) }),
  );
  assert.equal(response.status, 503);
  assert.deepEqual(response.jsonBody, {
    error: "temporarily_unavailable",
    resolverOutcome: "unavailable",
    budgetState: "stale",
  });
  assert.deepEqual(events(logs), [
    {
      schema: "ccof.resolver.event.v1",
      event: "refused",
      reason: "budget_state_stale",
      httpStatus: 503,
      personId: "person-1",
      subscriptionId: "sub-abc",
      projectId: "SAMPLEORGAIAZ103",
    },
  ]);
});

test("a missing budget record is reported as budgetState missing", async () => {
  const response = await handleResolveRequest(
    { ...authenticated, body: validBody },
    runtime({ reads: fakeReads({ readBudgetState: async () => null }) }),
  );
  assert.equal(response.status, 503);
  assert.equal(response.jsonBody.budgetState, "missing");
});

test("an invalid requestId is left out of the log, never copied", async () => {
  for (const requestId of ["has spaces", "x".repeat(65), 42, "<script>"]) {
    const logs: string[] = [];
    await handleResolveRequest(
      { ...authenticated, body: { personId: "person-2", subscriptionId: "sub-abc", requestId } },
      runtime({ logs }),
    );
    const [event] = events(logs);
    assert.equal("requestId" in event, false, String(requestId));
  }
});

test("log events carry only reason codes and ids", async () => {
  const logs: string[] = [];
  await handleResolveRequest({ ...authenticated, body: validBody }, runtime({ logs, now: secondsAfterValidUntil(700) }));
  await handleResolveRequest({ ...authenticated, body: { ...validBody, personId: "person-2" } }, runtime({ logs }));
  assert.equal(logs.length, 2);
  for (const event of events(logs)) {
    for (const key of Object.keys(event)) assert.ok(ALLOWED_EVENT_KEYS.has(key), `unexpected key ${key}`);
    assert.doesNotMatch(JSON.stringify(event), /foundry-sample-hub|claude-|4200/);
  }
});

test("each log event is one line that starts with the schema, so a query can match the prefix", async () => {
  const logs: string[] = [];
  await handleResolveRequest({ ...authenticated, body: validBody }, runtime({ logs, now: secondsAfterValidUntil(700) }));
  await handleResolveRequest({ ...authenticated, body: { ...validBody, personId: "person-2" } }, runtime({ logs }));
  await handleResolveRequest({ ...authenticated, body: validBody }, unconfiguredRuntime(logs));
  assert.equal(logs.length, 3);
  for (const line of logs) {
    assert.ok(line.startsWith('{"schema":"ccof.resolver.event.v1","event":'), line);
    assert.doesNotMatch(line, /\n/);
  }
});

// ---- registry failures ----

test("a malformed record's refusal event names the problem with a detail code", async () => {
  const logs: string[] = [];
  const broken = { ...activeMembership, familyPolicy: null };
  await handleResolveRequest(
    { ...authenticated, body: { personId: "person-1" } },
    pilotRuntime({ logs, reads: fakeReads({ readEntitlement: async () => ({ ...entitlementWithMembership, projectMemberships: [broken] }) }) }),
  );
  assert.deepEqual(events(logs), [
    {
      schema: "ccof.resolver.event.v1",
      event: "refused",
      reason: "entitlement_record_invalid",
      detail: "invalid_family_policy",
      httpStatus: 503,
      personId: "person-1",
      projectId: "SAMPLEORGAIAZ103",
    },
  ]);
});

test("a failure without a code is logged with the error's name, never its message", async () => {
  const logs: string[] = [];
  class CredentialUnavailableError extends Error {
    constructor() {
      super("ManagedIdentityCredential: no identity endpoint at http://169.254.169.254");
      this.name = "CredentialUnavailableError";
    }
  }
  await handleResolveRequest(
    { ...authenticated, body: validBody },
    runtime({ logs, reads: fakeReads({ readSubscriptionIndex: async () => { throw new CredentialUnavailableError(); } }) }),
  );
  const [event] = events(logs);
  assert.equal(event.reason, "registry_read_failed");
  assert.equal(event.errorCode, "CredentialUnavailableError");
  assert.doesNotMatch(logs[0], /169\.254|identity endpoint/);
});

test("a failed registry read is 503 unavailable with a failed event carrying only the error code", async () => {
  const logs: string[] = [];
  const failure = Object.assign(new Error("Request rate is large; endpoint https://example-x.documents.azure.com"), { code: 429 });
  const response = await handleResolveRequest(
    { ...authenticated, body: validBody },
    runtime({ logs, reads: fakeReads({ readEntitlement: async () => { throw failure; } }) }),
  );
  assert.equal(response.status, 503);
  assert.deepEqual(response.jsonBody, { error: "temporarily_unavailable", resolverOutcome: "unavailable" });
  assert.deepEqual(events(logs), [
    {
      schema: "ccof.resolver.event.v1",
      event: "failed",
      reason: "registry_read_failed",
      errorCode: "429",
      personId: "person-1",
      subscriptionId: "sub-abc",
    },
  ]);
});

// ---- request deadline (ADR-0014 decision 6: explicit, no default) ----

// A read that never settles, as a hung Cosmos connection looks to the caller.
const never = () => new Promise<never>(() => {});

test("a resolve that outlasts the request deadline is answered 503 at the deadline and logged", { timeout: 5000 }, async () => {
  const logs: string[] = [];
  const started = performance.now();
  const response = await handleResolveRequest(
    { ...authenticated, body: { ...validBody, requestId: "req-1" } },
    runtime({ logs, requestDeadlineMs: 50, reads: fakeReads({ readEntitlement: never }) }),
  );
  const elapsedMs = performance.now() - started;
  assert.equal(response.status, 503);
  assert.deepEqual(response.jsonBody, { error: "temporarily_unavailable", resolverOutcome: "unavailable" });
  assert.ok(elapsedMs >= 45 && elapsedMs < 1000, `answered after ${elapsedMs} ms`);
  assert.deepEqual(events(logs), [
    {
      schema: "ccof.resolver.event.v1",
      event: "failed",
      reason: "resolver_deadline_exceeded",
      requestId: "req-1",
      personId: "person-1",
      subscriptionId: "sub-abc",
    },
  ]);
});

test("the deadline covers the whole request: a slow first wave leaves less time for the budget reads", { timeout: 5000 }, async () => {
  const logs: string[] = [];
  const slow = <T>(value: T, ms: number) => new Promise<T>((resolve) => setTimeout(() => resolve(value), ms));
  const started = performance.now();
  const response = await handleResolveRequest(
    { ...authenticated, body: validBody },
    runtime({
      logs,
      requestDeadlineMs: 120,
      reads: fakeReads({
        readEntitlement: () => slow(entitlementWithMembership, 80),
        readBudgetState: () => slow(activeBudgetState, 80),
      }),
    }),
  );
  const elapsedMs = performance.now() - started;
  assert.equal(response.status, 503);
  assert.ok(elapsedMs < 1000, `answered after ${elapsedMs} ms`);
  assert.equal(events(logs)[0]?.reason, "resolver_deadline_exceeded");
});

// Reads that, like the SDK's, stop only when the signal they were given aborts.
// The signal is a read's last argument (readBudgetState has two keys).
function abortAwareRead<T>(signals: AbortSignal[], settleAfterMs?: number, value?: T) {
  return (...args: unknown[]) =>
    new Promise<T>((resolve, reject) => {
      const signal = args.find((arg): arg is AbortSignal => arg instanceof AbortSignal);
      if (signal) signals.push(signal);
      signal?.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })));
      if (settleAfterMs !== undefined) setTimeout(() => resolve(value as T), settleAfterMs);
    });
}

test("the deadline aborts every read of the request, including second-wave reads started later", { timeout: 5000 }, async () => {
  const firstWave: AbortSignal[] = [];
  const secondWave: AbortSignal[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: validBody },
    runtime({
      requestDeadlineMs: 300,
      reads: fakeReads({
        readSubscriptionIndex: abortAwareRead(firstWave, 0, activeSubscriptionIndex),
        readEntitlement: abortAwareRead(firstWave, 240, entitlementWithMembership),
        readBudgetState: abortAwareRead(secondWave),
        readAggregateBudgetState: abortAwareRead(secondWave),
        readBackend: abortAwareRead(secondWave),
      }),
    }),
  );
  assert.equal(response.status, 503);
  assert.equal(secondWave.length, 3);
  assert.ok(secondWave.every((signal) => signal.aborted), "every second-wave read is aborted when the 503 is sent");
  assert.ok(firstWave.length === 2 && firstWave[0] === secondWave[0], "one signal for the whole request");
});

test("a hung read is logged as resolver_deadline_exceeded even when its own abort error arrives first", { timeout: 5000 }, async () => {
  const logs: string[] = [];
  const signals: AbortSignal[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: validBody },
    runtime({ logs, requestDeadlineMs: 100, reads: fakeReads({ readEntitlement: abortAwareRead(signals) }) }),
  );
  assert.equal(response.status, 503);
  assert.equal(events(logs)[0]?.reason, "resolver_deadline_exceeded");
  assert.equal("errorCode" in events(logs)[0], false);
});

test("reads still pending when the answer leaves are aborted, so none outlives its request", { timeout: 5000 }, async () => {
  const signals: AbortSignal[] = [];
  const pendingAggregate = abortAwareRead(signals);
  const response = await handleResolveRequest(
    { ...authenticated, body: validBody },
    runtime({ reads: fakeReads({ readAggregateBudgetState: pendingAggregate }) }),
  );
  assert.equal(response.status, 200);
  assert.equal(signals.length, 1);
  assert.equal(signals[0].aborted, true);
});

test("a resolve that finishes inside the deadline is answered normally", async () => {
  const response = await handleResolveRequest({ ...authenticated, body: validBody }, runtime({ requestDeadlineMs: 1000 }));
  assert.equal(response.status, 200);
});

test("externalCategory: a passed deadline is temporarily_unavailable", () => {
  assert.equal(externalCategory("resolver_deadline_exceeded"), "temporarily_unavailable");
});

test("an error code or name that does not look like a code is left out of the log", async () => {
  const failures = [
    Object.assign(new Error("connect failed"), { code: "ECONNREFUSED 10.0.0.4:443" }),
    Object.assign(new Error("lookup failed"), { name: "Error at https://sample-pilot-cosmos.documents.azure.com/dbs/ccof" }),
    Object.assign(new Error("too long"), { code: "E".repeat(33) }),
  ];
  for (const failure of failures) {
    const logs: string[] = [];
    await handleResolveRequest(
      { ...authenticated, body: validBody },
      runtime({ logs, reads: fakeReads({ readEntitlement: async () => { throw failure; } }) }),
    );
    const [event] = events(logs);
    assert.equal(event.reason, "registry_read_failed");
    assert.equal("errorCode" in event, false, String((failure as { code?: unknown }).code ?? failure.name));
  }
});

test("a request answered inside the deadline leaves no timer behind", async () => {
  // Earlier tests may leave short timers; let them finish so the count is stable.
  await new Promise((resolve) => setTimeout(resolve, 200));
  const timers = () => process.getActiveResourcesInfo().filter((name) => name === "Timeout").length;
  const before = timers();
  const response = await handleResolveRequest({ ...authenticated, body: validBody }, runtime());
  assert.equal(response.status, 200);
  assert.equal(timers(), before);
});

// ---- configuration guard (ADR-0008 decision 5) ----

test("an unconfigured resolver refuses every request with 503 and logs unhealthy, without reading", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest({ ...authenticated, body: validBody }, unconfiguredRuntime(logs));
  assert.equal(response.status, 503);
  assert.deepEqual(response.jsonBody, { error: "temporarily_unavailable", resolverOutcome: "unavailable" });
  assert.deepEqual(events(logs), [
    {
      schema: "ccof.resolver.event.v1",
      event: "unhealthy",
      reason: "resolver_config_invalid",
      problems: ["RESOLVER_BUDGET_STATE_GRACE_SECONDS:missing"],
    },
  ]);
});

// ---- platform authentication guard (ADR-0009 decision 4) ----

test("with App Service Authentication off, every request is refused 503 and logged unhealthy", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { platformAuthEnabled: false, authenticatedPrincipal: true, body: validBody },
    runtime({ logs }),
  );
  assert.equal(response.status, 503);
  assert.deepEqual(response.jsonBody, { error: "temporarily_unavailable", resolverOutcome: "unavailable" });
  assert.deepEqual(events(logs), [
    { schema: "ccof.resolver.event.v1", event: "unhealthy", reason: "platform_authentication_disabled" },
  ]);
});

test("a request that reached the code without the platform principal is refused 401, and its body is not logged", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { platformAuthEnabled: true, authenticatedPrincipal: false, body: validBody },
    runtime({ logs }),
  );
  assert.equal(response.status, 401);
  assert.deepEqual(response.jsonBody, { error: "not_authenticated" });
  assert.deepEqual(events(logs), [
    { schema: "ccof.resolver.event.v1", event: "refused", reason: "request_not_authenticated", httpStatus: 401 },
  ]);
});

test("the authentication guards run before configuration and body checks", async () => {
  const disabled = await handleResolveRequest(
    { platformAuthEnabled: false, authenticatedPrincipal: false, body: "garbage" },
    unconfiguredRuntime(),
  );
  assert.equal(disabled.status, 503);
  const anonymous = await handleResolveRequest(
    { platformAuthEnabled: true, authenticatedPrincipal: false, body: "garbage" },
    unconfiguredRuntime(),
  );
  assert.equal(anonymous.status, 401);
});

test("isPlatformAuthEnabled accepts only the platform's true value", () => {
  assert.equal(isPlatformAuthEnabled("True"), true);
  assert.equal(isPlatformAuthEnabled("true"), true);
  for (const value of [undefined, "", "False", "false", "1", "yes", " True"]) {
    assert.equal(isPlatformAuthEnabled(value), false, String(value));
  }
});

test("hasPlatformPrincipal is true only when App Service set a principal header", () => {
  const headers = (values: Record<string, string>) => (name: string) => values[name] ?? null;
  assert.equal(hasPlatformPrincipal(headers({ "x-ms-client-principal-id": "00000000-0000-4000-8000-000001101111" })), true);
  assert.equal(hasPlatformPrincipal(headers({ "x-ms-client-principal": "eyJhdXRoX3R5cCI6ImFhZCJ9" })), true);
  assert.equal(hasPlatformPrincipal(headers({})), false);
  assert.equal(hasPlatformPrincipal(headers({ "x-ms-client-principal-id": "" })), false);
  assert.equal(hasPlatformPrincipal(headers({ authorization: "Bearer not-checked-here" })), false);
});

// ---- health (the resolver reports itself unhealthy) ----

test("health is 200 healthy when configured and authenticated", () => {
  const response = handleHealthRequest(authenticated, runtime());
  assert.equal(response.status, 200);
  assert.deepEqual(response.jsonBody, { status: "healthy" });
});

test("health is 503 unhealthy with the reason when configuration is invalid", () => {
  const logs: string[] = [];
  const response = handleHealthRequest(authenticated, unconfiguredRuntime(logs));
  assert.equal(response.status, 503);
  assert.deepEqual(response.jsonBody, { status: "unhealthy", reason: "resolver_config_invalid" });
  // The unhealthy state is logged from the health route too (AC11).
  assert.deepEqual(events(logs), [
    {
      schema: "ccof.resolver.event.v1",
      event: "unhealthy",
      reason: "resolver_config_invalid",
      problems: ["RESOLVER_BUDGET_STATE_GRACE_SECONDS:missing"],
    },
  ]);
});

test("health is 503 unhealthy when App Service Authentication is off, and 401 without a principal", () => {
  const disabled = handleHealthRequest({ platformAuthEnabled: false, authenticatedPrincipal: true }, runtime());
  assert.equal(disabled.status, 503);
  assert.deepEqual(disabled.jsonBody, { status: "unhealthy", reason: "platform_authentication_disabled" });
  const anonymous = handleHealthRequest({ platformAuthEnabled: true, authenticatedPrincipal: false }, runtime());
  assert.equal(anonymous.status, 401);
});

test("budget state staleness in the handler uses the runtime clock, read once per request", async () => {
  let reads = 0;
  const clockRuntime: ResolverRuntime = {
    ...runtime(),
    now: () => {
      reads += 1;
      return secondsAfterValidUntil(0);
    },
  };
  const response = await handleResolveRequest(
    { ...authenticated, body: validBody },
    {
      ...clockRuntime,
      readiness: {
        ready: true,
        budgetEnforcement: { mode: "budget-state", staleness: POLICY },
        requestDeadlineMs: TEST_DEADLINE_MS,
        reads: fakeReads({ readBudgetState: async () => activeBudgetState }),
      },
    },
  );
  assert.equal(response.status, 200);
  assert.equal(reads, 1);
});
