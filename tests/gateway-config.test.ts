// Gateway configuration validation (AC1). The schema file is the contract; the
// cross-field rules cover what JSON Schema cannot say. Every value is required
// and none has a default, so a missing value refuses before any rendering.

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, test } from "node:test";
import { fileURLToPath } from "node:url";

import { loadGatewayConfig, validateGatewayConfig } from "../infra/gateway/config.ts";
import { assertSupportedSchema, validateAgainstSchema } from "../infra/gateway/json-schema.ts";
import { sampleConfig } from "./helpers/gateway-fixtures.ts";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const schemaPath = path.join(repoRoot, "infra", "gateway", "gateway-config.schema.json");

function problemsFor(mutate: (config: Record<string, any>) => void): string[] {
  const config = sampleConfig();
  mutate(config);
  const result = validateGatewayConfig(config);
  return result.ok ? [] : result.problems;
}

function assertRefused(mutate: (config: Record<string, any>) => void, field: string): void {
  const problems = problemsFor(mutate);
  assert.ok(
    problems.some((p) => p.startsWith(field)),
    `expected a problem naming ${field}; got: ${JSON.stringify(problems)}`,
  );
}

describe("gateway configuration", () => {
  test("the sample configuration is valid", () => {
    const result = validateGatewayConfig(sampleConfig());
    assert.deepEqual(result.ok ? [] : result.problems, []);
  });

  test("the committed PoC configuration is valid", () => {
    const result = loadGatewayConfig(path.join(repoRoot, "tests", "fixtures", "gateway-public.json"));
    assert.deepEqual(result.ok ? [] : result.problems, []);
  });

  for (const key of ["schemaVersion", "configurationId", "apim", "entra", "admission", "resolver", "entitlementCache", "tokenLimits", "backends", "inferenceGeo", "forwarding"]) {
    test(`a missing top-level ${key} refuses, naming it`, () => {
      assertRefused((c) => delete c[key], key);
    });
  }

  const requiredLeaves: Array<[string, (c: Record<string, any>) => void]> = [
    ["entra.tenantId", (c) => delete c.entra.tenantId],
    ["entra.audiences", (c) => delete c.entra.audiences],
    ["admission.perPerson.calls", (c) => delete c.admission.perPerson.calls],
    ["admission.resolverMisses.maxConcurrent", (c) => delete c.admission.resolverMisses.maxConcurrent],
    ["resolver.url", (c) => delete c.resolver.url],
    ["resolver.tokenAudience", (c) => delete c.resolver.tokenAudience],
    ["resolver.timeoutSeconds", (c) => delete c.resolver.timeoutSeconds],
    ["resolver.projectHeaderName", (c) => delete c.resolver.projectHeaderName],
    ["entitlementCache.allowTtlSeconds", (c) => delete c.entitlementCache.allowTtlSeconds],
    ["entitlementCache.refusalTtlSeconds", (c) => delete c.entitlementCache.refusalTtlSeconds],
    ["entitlementCache.lastKnownGoodGraceSeconds", (c) => delete c.entitlementCache.lastKnownGoodGraceSeconds],
    ["entitlementCache.refreshBackoffSeconds", (c) => delete c.entitlementCache.refreshBackoffSeconds],
    ["tokenLimits.headers.personRemainingQuota", (c) => delete c.tokenLimits.headers.personRemainingQuota],
    ["backends[0].credential.clientSecretNamedValue", (c) => delete c.backends[0].credential.clientSecretNamedValue],
    ["forwarding.defaultAnthropicVersion", (c) => delete c.forwarding.defaultAnthropicVersion],
  ];
  for (const [field, mutate] of requiredLeaves) {
    test(`a missing ${field} refuses, naming it`, () => assertRefused(mutate, field));
  }

  test("a tenant id that is not a lower-case GUID refuses", () => {
    assertRefused((c) => (c.entra.tenantId = "example.invalid"), "entra.tenantId");
    assertRefused((c) => (c.entra.tenantId = "0000000A-0000-0000-0000-000000000001"), "entra.tenantId");
  });

  test("a value carrying a quote, brace, angle bracket or named-value reference refuses", () => {
    assertRefused((c) => (c.configurationId = 'x"y'), "configurationId");
    assertRefused((c) => (c.resolver.projectHeaderName = "x-{{secret}}"), "resolver.projectHeaderName");
    assertRefused((c) => (c.resolver.url = "https://resolver.example.test/api/<resolve>"), "resolver.url");
    assertRefused((c) => (c.backends[0].id = "@(context)"), "backends[0].id");
  });

  test("a URL that is not https refuses", () => {
    assertRefused((c) => (c.resolver.url = "http://resolver.example.test/api/resolve"), "resolver.url");
    assertRefused((c) => (c.entra.authorityHost = "https://login.example.test/"), "entra.authorityHost");
  });

  test("limits outside the platform's bounds refuse", () => {
    assertRefused((c) => (c.admission.perPerson.renewalPeriodSeconds = 301), "admission.perPerson.renewalPeriodSeconds");
    assertRefused((c) => (c.admission.perPerson.calls = 0), "admission.perPerson.calls");
    assertRefused((c) => (c.admission.perPerson.calls = 1.5), "admission.perPerson.calls");
    assertRefused((c) => (c.resolver.timeoutSeconds = 61), "resolver.timeoutSeconds");
    assertRefused((c) => (c.entitlementCache.allowTtlSeconds = "300"), "entitlementCache.allowTtlSeconds");
    assertRefused((c) => (c.entitlementCache.lastKnownGoodGraceSeconds = -1), "entitlementCache.lastKnownGoodGraceSeconds");
  });

  test("an unknown setting refuses, so a misspelt key is not silently ignored", () => {
    assertRefused((c) => (c.entitlementCache.allowTtlSecs = 300), "entitlementCache.allowTtlSecs");
    assertRefused((c) => (c.backends[0].credential.clientSecret = "should-never-be-here"), "backends[0].credential.clientSecret");
  });

  test("an unknown credential type refuses", () => {
    assertRefused((c) => (c.backends[0].credential = { type: "apiKey", key: "x" }), "backends[0].credential.type");
  });

  test("an unknown caching type refuses", () => {
    assertRefused((c) => (c.entitlementCache.cachingType = "redis"), "entitlementCache.cachingType");
  });

  test("duplicate backend ids refuse", () => {
    assertRefused((c) => c.backends.push(structuredClone(c.backends[0])), "backends");
  });

  test("a static backend must use named-value client credentials: managed identity comes by data (C-8)", () => {
    assertRefused((c) => (c.backends[0].credential = { type: "managedIdentity", resource: "https://models.example.test" }), "backends[0].credential");
  });

  test("no static backend is allowed: every backend can come by data (shape A)", () => {
    const result = validateGatewayConfig({ ...sampleConfig(), backends: [] });
    assert.deepEqual(result.ok ? [] : result.problems, []);
  });

  test("there is no gateway-side list of data backends or resources: C-8 routes only what the resolver returns", () => {
    assertRefused((c) => (c.backendRouting = { allowListNamedValue: "x", managedIdentityResources: [] }), "backendRouting");
  });

  test("the refresh backoff is within its range and never longer than the last-known-good grace", () => {
    assertRefused((c) => (c.entitlementCache.refreshBackoffSeconds = 0), "entitlementCache.refreshBackoffSeconds");
    assertRefused((c) => (c.entitlementCache.refreshBackoffSeconds = 3601), "entitlementCache.refreshBackoffSeconds");
    assertRefused((c) => {
      c.entitlementCache.lastKnownGoodGraceSeconds = 60;
      c.entitlementCache.refreshBackoffSeconds = 61;
    }, "entitlementCache.refreshBackoffSeconds: must not exceed lastKnownGoodGraceSeconds");
    const noGrace = sampleConfig();
    noGrace.entitlementCache.lastKnownGoodGraceSeconds = 0;
    const result = validateGatewayConfig(noGrace);
    assert.deepEqual(result.ok ? [] : result.problems, [], "with last-known-good off the backoff has nothing to bound");
  });

  test("app-only test identities must be consistent with the switch", () => {
    assertRefused((c) => (c.entra.testIdentities = { allowAppOnlyTokens: false, clientAppIds: ["00000000-0000-0000-0000-00000000000e"], appRole: null }), "entra.testIdentities.clientAppIds");
    assertRefused((c) => (c.entra.testIdentities = { allowAppOnlyTokens: true, clientAppIds: [], appRole: "Gateway.Test" }), "entra.testIdentities.clientAppIds");
  });

  // WP-NET S1, AC15. Learn "appRole resource type": a role value has at most 120 characters, may contain
  // commas and may not begin with "."; the configuration accepts a stricter set that is safe in the policy.
  test("an app-only token's required app role is configured exactly when app-only tokens are allowed (S1)", () => {
    assertRefused((c) => delete c.entra.testIdentities.appRole, "entra.testIdentities.appRole");
    assertRefused((c) => (c.entra.testIdentities.appRole = null), "entra.testIdentities.appRole: name the app role");
    assertRefused((c) => (c.entra.testIdentities = { allowAppOnlyTokens: false, clientAppIds: [], appRole: "Gateway.Test" }), "entra.testIdentities.appRole: must be null");
    for (const bad of ["", "Gateway Test", ".Gateway", "Gateway,Test", 'Gateway"Test', "a".repeat(121)]) {
      assertRefused((c) => (c.entra.testIdentities.appRole = bad), "entra.testIdentities.appRole");
    }
    const off = sampleConfig();
    off.entra.testIdentities = { allowAppOnlyTokens: false, clientAppIds: [], appRole: null };
    const result = validateGatewayConfig(off);
    assert.deepEqual(result.ok ? [] : result.problems, [], "with app-only tokens off no role is configured");
  });

  // WP-SEC A3. A person's token is accepted only from the reviewed client applications; the policy
  // compares the lower-cased azp/appid, so ids are lower-case GUIDs, and at least one is named.
  test("the client applications a person's token may come from are named, as lower-case GUIDs (A3)", () => {
    assertRefused((c) => delete c.entra.delegatedClientAppIds, "entra.delegatedClientAppIds");
    assertRefused((c) => (c.entra.delegatedClientAppIds = []), "entra.delegatedClientAppIds");
    for (const bad of ["not-a-guid", "00000000-0000-0000-0000-00000000000F", '00000000-0000-0000-0000-00000000000f"']) {
      assertRefused((c) => (c.entra.delegatedClientAppIds = [bad]), "entra.delegatedClientAppIds");
    }
    assertRefused((c) => (c.entra.delegatedClientAppIds = ["00000000-0000-0000-0000-00000000000f", "00000000-0000-0000-0000-00000000000f"]), "entra.delegatedClientAppIds");
  });

  test("response header names must be distinct and must not shadow reserved headers", () => {
    assertRefused((c) => (c.tokenLimits.headers.groupRemainingQuota = c.tokenLimits.headers.personRemainingQuota.toUpperCase()), "tokenLimits.headers.groupRemainingQuota");
    assertRefused((c) => (c.tokenLimits.headers.tokensConsumed = "Retry-After"), "tokenLimits.headers.tokensConsumed");
    assertRefused((c) => (c.resolver.projectHeaderName = "Authorization"), "resolver.projectHeaderName");
    assertRefused((c) => (c.resolver.projectHeaderName = "anthropic-beta"), "resolver.projectHeaderName");
  });

  test("an inference-geo map entry must name a backend, a deployment and a known geography", () => {
    assertRefused((c) => (c.inferenceGeo = { "backend-by-data": { "claude-x": "eu" } }), "inferenceGeo.backend-by-data.claude-x");
    assertRefused((c) => (c.inferenceGeo = { "backend-by-data": { "bad name": "us" } }), "inferenceGeo.backend-by-data.bad name");
    assertRefused((c) => (c.inferenceGeo = { "bad backend!": {} }), "inferenceGeo.bad backend!");
  });

  test("a configuration file that is not JSON refuses with its path", () => {
    const result = loadGatewayConfig(path.join(repoRoot, "infra", "gateway", "gateway-config.schema.json.missing"));
    assert.equal(result.ok, false);
    assert.match(result.ok ? "" : result.problems[0], /not found|cannot be read/);
  });
});

describe("schema interpreter", () => {
  test("the committed schema uses only supported keywords", () => {
    assert.doesNotThrow(() => assertSupportedSchema(JSON.parse(readFileSync(schemaPath, "utf8"))));
  });

  test("a schema keyword the interpreter does not implement is refused, not ignored", () => {
    assert.throws(() => assertSupportedSchema({ type: "object", patternProperties: {} }), /unsupported keyword "patternProperties"/);
    assert.throws(() => assertSupportedSchema({ properties: { a: { if: {} } } }), /unsupported keyword "if"/);
  });

  test("types, patterns and bounds are enforced", () => {
    const schema = { type: "object", required: ["n"], properties: { n: { type: "integer", minimum: 2 }, s: { type: "string", pattern: "^a+$" } } };
    assert.deepEqual(validateAgainstSchema(schema, { n: 2, s: "aa" }), []);
    assert.equal(validateAgainstSchema(schema, { n: 1 }).length, 1);
    assert.equal(validateAgainstSchema(schema, { n: 2, s: "b" }).length, 1);
    assert.equal(validateAgainstSchema(schema, {}).length, 1);
  });
});
