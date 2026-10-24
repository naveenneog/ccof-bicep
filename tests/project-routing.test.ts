// Per-project backend failover contract (src/contracts/project-routing.ts, ADR 0034).
// Failover is off unless a project carries an enabled `failover` with a verified active pool;
// every malformed value routes direct to the primary backend.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  admittedModelsOf, circuitBreakerProblems, failoverCompatibilityProblems, failoverProblems, memberBackendIdFor,
  POOL_ID, poolBackendIdFor, registeredBackendProblems, routeBackendIdOf, type RegisteredBackend,
} from "../src/contracts/project-routing.ts";

const POOL = poolBackendIdFor("SASLAB1", 2);
const active = { revision: 2, poolBackendId: POOL, verifiedAt: "2026-10-23T10:00:00Z" };
const on = (over: Record<string, unknown> = {}) => ({ enabled: true, fallbackBackendIds: ["foundry-b"], revision: 2, active, ...over });

test("pool and member ids match the pool pattern, are lower-case and differ for projects with the same slug", () => {
  assert.match(POOL, POOL_ID);
  assert.match(poolBackendIdFor("X".repeat(80), 999_999_999), POOL_ID);
  assert.ok(poolBackendIdFor("X".repeat(80), 1).length <= 80);
  assert.ok(memberBackendIdFor("X".repeat(80), 999_999_999, 4).length <= 80);
  assert.notEqual(poolBackendIdFor("A_B", 1), poolBackendIdFor("a-b", 1));
  assert.notEqual(memberBackendIdFor("A_B", 1, 0), memberBackendIdFor("a-b", 1, 0));
  assert.notEqual(poolBackendIdFor("AB", 1), poolBackendIdFor("ab", 1));
  assert.equal(poolBackendIdFor("SASLAB1", 2), POOL);
});

test("absent failover is valid and routes direct", () => {
  assert.deepEqual(failoverProblems(undefined, "foundry-a"), []);
  assert.equal(routeBackendIdOf(undefined, "foundry-a"), null);
});

test("enabled failover with a verified pool routes to the pool", () => {
  assert.deepEqual(failoverProblems(on(), "foundry-a"), []);
  assert.equal(routeBackendIdOf(on(), "foundry-a"), POOL);
});

test("disabled failover keeps the verified pool on record but routes direct", () => {
  assert.deepEqual(failoverProblems(on({ enabled: false }), "foundry-a"), []);
  assert.equal(routeBackendIdOf(on({ enabled: false }), "foundry-a"), null);
});

test("a pending revision keeps the previously verified pool", () => {
  const pending = on({ revision: 3 });
  assert.deepEqual(failoverProblems(pending, "foundry-a"), []);
  assert.equal(routeBackendIdOf(pending, "foundry-a"), POOL);
});

test("enabled failover before any verified publication routes direct", () => {
  assert.equal(routeBackendIdOf(on({ active: null }), "foundry-a"), null);
});

const invalid: Array<[string, unknown, string]> = [
  ["not an object", "on", "failover:invalid"],
  ["an unexpected key", { ...on(), weight: 1 }, "failover:unexpected_key"],
  ["enabled not boolean", on({ enabled: "true" }), "failover.enabled:invalid"],
  ["enabled without fallbacks", on({ fallbackBackendIds: [] }), "failover.fallbackBackendIds:required_when_enabled"],
  ["a duplicate fallback", on({ fallbackBackendIds: ["foundry-b", "foundry-b"] }), "failover.fallbackBackendIds:duplicate"],
  ["the primary as fallback", on({ fallbackBackendIds: ["foundry-a"] }), "failover.fallbackBackendIds:includes_primary"],
  ["five fallbacks", on({ fallbackBackendIds: ["b1", "b2", "b3", "b4", "b5"] }), "failover.fallbackBackendIds:invalid"],
  ["a malformed fallback id", on({ fallbackBackendIds: ["bad id"] }), "failover.fallbackBackendIds:invalid"],
  ["revision zero", on({ revision: 0 }), "failover.revision:invalid"],
  ["active newer than revision", on({ revision: 1 }), "failover.active.revision:invalid"],
  ["a pool id outside the pattern", on({ active: { ...active, poolBackendId: "foundry-a" } }), "failover.active.poolBackendId:invalid"],
  ["verifiedAt without a zone", on({ active: { ...active, verifiedAt: "2026-10-23T10:00:00" } }), "failover.active.verifiedAt:invalid"],
  ["active missing", { enabled: false, fallbackBackendIds: [], revision: 1 }, "failover.active:required"],
];
for (const [name, value, problem] of invalid) {
  test(`failover with ${name} is refused (${problem}) and never routes`, () => {
    assert.ok(failoverProblems(value, "foundry-a").includes(problem), JSON.stringify(failoverProblems(value, "foundry-a")));
    assert.equal(routeBackendIdOf(value, "foundry-a"), null);
  });
}

const breaker = { enabled: true, failureCount: 3, failureIntervalSeconds: 60, tripDurationSeconds: 60, statusCodeRanges: [{ min: 429, max: 429 }, { min: 500, max: 599 }], acceptRetryAfter: true };
const backend = (over: Partial<RegisteredBackend> = {}): RegisteredBackend => ({
  backendId: "foundry-a", displayName: "Foundry A", url: "https://acct-a.services.ai.azure.com/anthropic",
  deployments: ["claude-haiku-4-5", "claude-sonnet-5"], inferenceGeo: "us", status: "active", circuitBreaker: breaker, ...over,
});

test("the circuit breaker is optional: null is valid, a valid breaker is valid", () => {
  assert.deepEqual(registeredBackendProblems(backend({ circuitBreaker: null })), []);
  assert.deepEqual(registeredBackendProblems(backend()), []);
  const missing: Record<string, unknown> = { ...backend() };
  delete missing.circuitBreaker;
  assert.deepEqual(registeredBackendProblems(missing), ["circuitBreaker:required"]);
});

const badBreakers: Array<[string, Record<string, unknown>, string]> = [
  ["failureCount 0", { failureCount: 0 }, "circuitBreaker.failureCount:invalid"],
  ["interval 5 s", { failureIntervalSeconds: 5 }, "circuitBreaker.failureIntervalSeconds:invalid"],
  ["trip 3601 s", { tripDurationSeconds: 3601 }, "circuitBreaker.tripDurationSeconds:invalid"],
  ["a 2xx range", { statusCodeRanges: [{ min: 200, max: 299 }] }, "circuitBreaker.statusCodeRanges:invalid"],
  ["an inverted range", { statusCodeRanges: [{ min: 599, max: 500 }] }, "circuitBreaker.statusCodeRanges:invalid"],
  ["no ranges", { statusCodeRanges: [] }, "circuitBreaker.statusCodeRanges:invalid"],
  ["acceptRetryAfter missing", { acceptRetryAfter: undefined }, "circuitBreaker.acceptRetryAfter:invalid"],
];
for (const [name, over, problem] of badBreakers) {
  test(`a breaker with ${name} is refused`, () => assert.deepEqual(circuitBreakerProblems({ ...breaker, ...over }), [problem]));
}

test("registry entries refuse reserved ids, non-Foundry URLs and unknown geographies", () => {
  assert.deepEqual(registeredBackendProblems(backend({ backendId: "ccof-pool-x-r1" })), ["backendId:invalid"]);
  assert.deepEqual(registeredBackendProblems(backend({ url: "https://evil.example.com/anthropic" })), ["url:invalid"]);
  assert.deepEqual(registeredBackendProblems(backend({ url: "http://acct-a.services.ai.azure.com/anthropic" })), ["url:invalid"]);
  assert.deepEqual(registeredBackendProblems(backend({ inferenceGeo: "apac" as "us" })), ["inferenceGeo:invalid"]);
  assert.deepEqual(registeredBackendProblems(backend({ deployments: ["a", "a"] })), ["deployments:invalid"]);
});

test("compatibility: primary needs an enabled breaker; fallbacks need the same geography and every admitted model", () => {
  const registry = new Map<string, RegisteredBackend>([
    ["foundry-a", backend()],
    ["foundry-b", backend({ backendId: "foundry-b", circuitBreaker: null })],
    ["foundry-eu", backend({ backendId: "foundry-eu", inferenceGeo: "eu" })],
    ["foundry-haiku", backend({ backendId: "foundry-haiku", deployments: ["claude-haiku-4-5"] })],
    ["foundry-off", backend({ backendId: "foundry-off", status: "disabled" })],
  ]);
  const models = ["claude-haiku-4-5", "claude-sonnet-5"];
  assert.deepEqual(failoverCompatibilityProblems("foundry-a", ["foundry-b"], models, registry), []);
  assert.deepEqual(failoverCompatibilityProblems("foundry-b", ["foundry-a"], models, registry), ["primary:circuit_breaker_required"]);
  registry.set("foundry-a", backend({ circuitBreaker: { ...breaker, enabled: false } }));
  assert.deepEqual(failoverCompatibilityProblems("foundry-a", ["foundry-b"], models, registry), ["primary:circuit_breaker_required"]);
  registry.set("foundry-a", backend());
  assert.deepEqual(failoverCompatibilityProblems("foundry-a", ["foundry-eu", "foundry-haiku", "foundry-off", "nope"], models, registry), [
    "fallbackBackendIds.0:geography_mismatch", "fallbackBackendIds.1:models_missing", "fallbackBackendIds.2:disabled", "fallbackBackendIds.3:not_registered",
  ]);
  assert.deepEqual(failoverCompatibilityProblems("nope", ["foundry-b"], models, registry), ["primary:not_registered"]);
  assert.deepEqual(failoverCompatibilityProblems("foundry-haiku", ["foundry-b"], models, registry), ["primary:models_missing"]);
});

test("admitted models are collected across classifications and families", () => {
  const project = { classifications: {
    STD: { familyPolicy: { families: { haiku: { models: ["claude-haiku-4-5"] } } } },
    PRM: { familyPolicy: { families: { sonnet: { models: ["claude-sonnet-5"] }, haiku: { models: ["claude-haiku-4-5"] } } } },
  } };
  assert.deepEqual(admittedModelsOf(project), ["claude-haiku-4-5", "claude-sonnet-5"]);
});
