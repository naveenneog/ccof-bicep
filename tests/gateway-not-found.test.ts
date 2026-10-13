// WP-GW AC16: a request that matches no operation of the API is answered 404 not_found_error, and
// every other error keeps its answer.
//
// APIM's built-in step raises source "configuration", reason "OperationNotFound" ("URI doesn't match
// to any API or Operation") and processing "immediately jumps to the on-error policy section" (Learn,
// "Error handling in Azure API Management policies", ms.date 2026-04-22, retrieved 2026-10-13). Claude
// Code sends one such request at startup, its HEAD /api/hello connection-warming probe, which a gateway
// "can reject without breaking anything" (https://code.claude.com/docs/en/llm-gateway-protocol,
// retrieved 2026-10-13). Revision 8 answered it 500 "unexpected error" (docs/status/WP-E2E.md, G4).
// The tests run the rendered on-error section with tests/helpers/on-error-simulator.ts.

import { strict as assert } from "node:assert";
import { describe, test } from "node:test";

import type { XmlElement } from "../infra/gateway/apim-xml.ts";
import { descendants, parseApimXml } from "../infra/gateway/apim-xml.ts";
import type { GatewayConfig } from "../infra/gateway/config.ts";
import { renderPolicy } from "../infra/gateway/render.ts";
import { sampleConfig } from "./helpers/gateway-fixtures.ts";
import type { GatewayAnswer, GatewayError } from "./helpers/on-error-simulator.ts";
import { simulateOnError } from "./helpers/on-error-simulator.ts";

const REQUEST_ID = "00000000-0000-4000-8000-000001011110";

// Rendered inside each test, so a template that fails to render fails the tests, not the file's load.
function onErrorOf(config: Record<string, any> = sampleConfig()): XmlElement {
  const root = parseApimXml(renderPolicy(config as GatewayConfig).policyXml);
  const found = root.children.find((n): n is XmlElement => n.kind === "element" && n.name === "on-error");
  assert.ok(found, "the rendered policy has no on-error section");
  return found;
}

const answer = (error: GatewayError, config?: Record<string, any>): GatewayAnswer => simulateOnError(onErrorOf(config), error, REQUEST_ID);

function errorBody(a: GatewayAnswer): { type: string; message: string } {
  assert.ok(a.body !== null, "the answer has no body");
  const parsed = JSON.parse(a.body);
  assert.deepEqual(Object.keys(parsed), ["type", "error"], "the body is not Anthropic's error shape");
  assert.equal(parsed.type, "error");
  assert.deepEqual(Object.keys(parsed.error), ["type", "message"], "the error carries more than its type and message");
  return parsed.error;
}

const notFound = (method: string, path: string, statusCode: number): GatewayError => ({
  source: "configuration",
  reason: "OperationNotFound",
  section: "backend",
  message: "Unable to match incoming request to an operation.",
  statusCode,
  method,
  path,
});

const probes: Array<[string, string]> = [
  ["HEAD", "/anthropic/api/hello"],
  ["GET", "/anthropic/v1/models"],
  ["POST", "/anthropic/v1/messages/count_tokens"],
  ["GET", "/anthropic/v1/messages"],
];

describe("on-error: a request that matches no operation (AC16)", () => {
  test("is answered 404 not_found_error with the request id, whatever the path, method or status APIM set", () => {
    for (const [method, path] of probes) {
      for (const statusCode of [404, 500, 200]) {
        const a = answer(notFound(method, path, statusCode));
        const at = `${method} ${path} (status ${statusCode})`;
        assert.equal(a.status, 404, `${at}: status`);
        assert.equal(a.reason, "Not Found", `${at}: reason phrase`);
        assert.equal(a.headers["content-type"], "application/json", `${at}: content type`);
        assert.equal(a.headers["x-ccof-request-id"], REQUEST_ID, `${at}: request id header`);
        assert.equal(a.headers["retry-after"], undefined, `${at}: a missing path is not worth a retry`);
        assert.equal(a.headers["www-authenticate"], undefined, `${at}: no sign-in is asked for`);
        const error = errorBody(a);
        assert.equal(error.type, "not_found_error", `${at}: error type`);
        assert.ok(error.message.endsWith(` Request id: ${REQUEST_ID}.`), `${at}: the message ends with the request id`);
      }
    }
  });

  test("makes no backend call and writes no trace: on-error forwards nothing, on any path", () => {
    const a = answer(notFound("HEAD", "/anthropic/api/hello", 404));
    assert.equal(a.status, 404, "not the not-found answer");
    assert.deepEqual(a.calls, [], "the not-found answer sent a request out of the gateway");
    assert.deepEqual(a.traces, [], "the not-found answer wrote a trace");
    const outgoing = descendants(onErrorOf()).filter((e) => ["forward-request", "send-request", "send-one-way-request", "log-to-eventhub"].includes(e.name));
    assert.deepEqual(outgoing.map((e) => e.name), [], "on-error can send a request out of the gateway");
  });

  test("the body names no configuration value, request detail or internal error: it is the same text for every request and configuration", () => {
    const config = sampleConfig();
    const message = (error: GatewayError, c?: Record<string, any>) => {
      const a = answer(error, c);
      assert.equal(a.status, 404, "not the not-found answer");
      return errorBody(a).message;
    };
    const reference = message(notFound("HEAD", "/anthropic/api/hello", 404));
    for (const [method, path] of probes) {
      for (const statusCode of [404, 500]) assert.equal(message(notFound(method, path, statusCode)), reference, `${method} ${path} changes the message`);
    }
    const other = sampleConfig();
    other.configurationId = "other-gateway-config";
    other.apim.apiPath = "other-path";
    other.entra.tenantId = "00000000-0000-0000-0000-0000000000e1";
    other.entra.delegatedScope = "other_scope";
    other.entra.delegatedClientAppIds = ["00000000-0000-0000-0000-0000000000e2"];
    other.resolver.url = "https://other-resolver.example.test/api/resolve";
    other.entitlementCache.unavailableRetryAfterSeconds = 17;
    assert.equal(message(notFound("HEAD", "/other-path/api/hello", 404), other), reference, "the message depends on the configuration");

    // Every configured string long enough to identify something, and what the request and APIM's error said.
    const leaves = (v: unknown): string[] => (typeof v === "string" ? [v] : v !== null && typeof v === "object" ? Object.values(v).flatMap(leaves) : []);
    const forbidden = [
      ...leaves(config).filter((s) => s.length >= 6),
      "/anthropic/api/hello",
      "api/hello",
      "Unable to match incoming request to an operation.",
      "OperationNotFound",
      "configuration",
    ];
    for (const value of forbidden) assert.ok(!reference.includes(value), `the not-found message carries "${value}"`);
  });

  test("only APIM's own OperationNotFound is answered 404: the same reason from another source, or another configuration error, stays the unexpected 500", () => {
    const nearMisses: Array<Pick<GatewayError, "source" | "reason">> = [
      { source: "forward-request", reason: "OperationNotFound" },
      { source: "Configuration", reason: "OperationNotFound" },
      { source: "configuration", reason: "operationnotfound" },
      { source: "configuration", reason: "ApiNotFound" },
      { source: "configuration", reason: null },
      { source: null, reason: "OperationNotFound" },
      { source: "authorization", reason: "SubscriptionKeyNotFound" },
    ];
    for (const miss of nearMisses) {
      const a = answer({ ...miss, statusCode: 500, method: "HEAD", path: "/anthropic/api/hello" });
      const at = `source ${miss.source}, reason ${miss.reason}`;
      assert.equal(a.status, 500, `${at}: status`);
      assert.equal(a.reason, "Internal Server Error", `${at}: reason phrase`);
      assert.equal(errorBody(a).type, "api_error", `${at}: error type`);
    }
  });
});

describe("on-error: every other error keeps revision 8's answer (AC16)", () => {
  interface Case {
    name: string;
    error: GatewayError;
    status: number;
    reason: string;
    type: string;
    retryAfter?: string;
    wwwAuthenticate?: string;
    traces?: string[];
  }
  const limitVars = { ccofProjectId: "CCOFTEST01", ccofClassification: "STD", ccofGroupPeriod: "Daily", ccofPersonPeriod: "Monthly" };
  const cases: Case[] = [
    { name: "no token", error: { source: "validate-jwt", policyId: "ccof-jwt", reason: "TokenNotPresent", statusCode: 401 }, status: 401, reason: "Unauthorized", type: "authentication_error", wwwAuthenticate: "Bearer" },
    { name: "expired token", error: { source: "validate-jwt", policyId: "ccof-jwt", reason: "TokenExpired", statusCode: 401 }, status: 401, reason: "Unauthorized", type: "authentication_error", wwwAuthenticate: "Bearer" },
    { name: "per-person admission", error: { source: "rate-limit-by-key", policyId: "ccof-admission-person", reason: "RateLimitExceeded", statusCode: 429, variables: { ccofRetryAfter: 7 } }, status: 429, reason: "Too Many Requests", type: "rate_limit_error", retryAfter: "7" },
    { name: "per-person admission without a retry time", error: { source: "rate-limit-by-key", policyId: "ccof-admission-person", reason: "RateLimitExceeded", statusCode: 429 }, status: 429, reason: "Too Many Requests", type: "rate_limit_error" },
    { name: "resolver admission", error: { source: "rate-limit-by-key", policyId: "ccof-admission-resolver", reason: "RateLimitExceeded", statusCode: 429 }, status: 429, reason: "Too Many Requests", type: "rate_limit_error", retryAfter: "5" },
    { name: "resolver concurrency", error: { source: "limit-concurrency", policyId: "ccof-admission-resolver-concurrency", reason: "", statusCode: 429 }, status: 429, reason: "Too Many Requests", type: "rate_limit_error", retryAfter: "5" },
    { name: "group tokens per minute", error: { source: "llm-token-limit", policyId: "ccof-limit-group-rate-quota", reason: "TokenLimitExceeded", statusCode: 429, variables: { ...limitVars, ccofRetryAfter: 12 } }, status: 429, reason: "Too Many Requests", type: "rate_limit_error", retryAfter: "12" },
    { name: "group quota", error: { source: "llm-token-limit", policyId: "ccof-limit-group-quota", reason: "QuotaExceeded", statusCode: 403, variables: { ...limitVars, ccofRetryAfter: 3600 } }, status: 403, reason: "Forbidden", type: "permission_error", retryAfter: "3600" },
    { name: "person tokens per minute", error: { source: "llm-token-limit", policyId: "ccof-limit-person-rate", reason: "TokenLimitExceeded", statusCode: 429, variables: { ...limitVars, ccofRetryAfter: 30 } }, status: 429, reason: "Too Many Requests", type: "rate_limit_error", retryAfter: "30" },
    { name: "person quota", error: { source: "llm-token-limit", policyId: "ccof-limit-person-rate-quota", reason: "QuotaExceeded", statusCode: 403, variables: { ...limitVars, ccofRetryAfter: 86400 } }, status: 403, reason: "Forbidden", type: "permission_error", retryAfter: "86400" },
    { name: "person quota without a retry time", error: { source: "llm-token-limit", policyId: "ccof-limit-person-quota", reason: "QuotaExceeded", statusCode: 403, variables: limitVars }, status: 403, reason: "Forbidden", type: "permission_error" },
    { name: "backend credential", error: { source: "authentication-managed-identity", policyId: "ccof-backend-credential-managed-identity", reason: "", statusCode: 500, variables: { ccofResolverCalled: true, ccofResolverTraced: false, ccofResolverOutcome: "allow" } }, status: 503, reason: "Service Unavailable", type: "api_error", retryAfter: "5", traces: ["ccof.resolver.v1"] },
    { name: "backend unreachable", error: { source: "forward-request", reason: "BackendConnectionFailure", section: "backend", statusCode: 500 }, status: 502, reason: "Bad Gateway", type: "api_error" },
    { name: "backend timeout", error: { source: "forward-request", reason: "Timeout", section: "backend", statusCode: 500 }, status: 504, reason: "Gateway Timeout", type: "api_error" },
    { name: "an expression failed", error: { source: "set-variable", reason: "ExpressionValueEvaluationFailure", section: "inbound", statusCode: 500 }, status: 500, reason: "Internal Server Error", type: "api_error" },
  ];

  test("each error is answered as before: status, reason phrase, error type, Retry-After, WWW-Authenticate and traces", () => {
    for (const c of cases) {
      const a = answer(c.error);
      assert.equal(a.status, c.status, `${c.name}: status`);
      assert.equal(a.reason, c.reason, `${c.name}: reason phrase`);
      assert.equal(errorBody(a).type, c.type, `${c.name}: error type`);
      assert.equal(a.headers["retry-after"], c.retryAfter, `${c.name}: Retry-After`);
      assert.equal(a.headers["www-authenticate"], c.wwwAuthenticate, `${c.name}: WWW-Authenticate`);
      assert.equal(a.headers["content-type"], "application/json", `${c.name}: content type`);
      assert.equal(a.headers["x-ccof-request-id"], REQUEST_ID, `${c.name}: request id header`);
      assert.deepEqual(a.traces, c.traces ?? [], `${c.name}: traces`);
      for (const message of a.traceMessages) {
        const trace = JSON.parse(message);
        assert.deepEqual([trace.requestId, trace.served], [REQUEST_ID, false], `${c.name}: the resolver trace records a request that was not served`);
      }
      assert.deepEqual(a.calls, [], `${c.name}: on-error sent a request out of the gateway`);
    }
  });
});

describe("the on-error simulator", () => {
  const section = (inner: string) => parseApimXml(`<on-error>${inner}<return-response><set-status code="500" reason="x" /></return-response></on-error>`);
  const error: GatewayError = { source: "x", reason: "y", statusCode: 500 };

  test("refuses what it cannot run, so a test cannot pass on an expression it does not understand", () => {
    assert.throws(() => simulateOnError(section('<cache-store-value key="k" value="v" duration="1" />'), error, REQUEST_ID), /cannot run <cache-store-value>/);
    assert.throws(() => simulateOnError(section('<set-variable name="t" value="@(DateTime.UtcNow.ToString())" />'), error, REQUEST_ID), /DateTime/);
    assert.throws(() => simulateOnError(section('<set-variable name="t" value="@((string)context.Variables["never-set"])" />'), error, REQUEST_ID), /KeyNotFoundException/);
    assert.throws(() => simulateOnError(section('<choose><when condition="@(&quot;x&quot;)"><base /></when></choose>'), error, REQUEST_ID), /not a boolean/);
    assert.throws(() => simulateOnError(parseApimXml("<on-error><base /></on-error>"), error, REQUEST_ID), /without <return-response>/);
    // A trace is not just counted: its message runs too (council, Coder WARN).
    assert.throws(() => simulateOnError(section('<trace source="s"><message>@((string)context.Variables["never-set"])</message></trace>'), error, REQUEST_ID), /KeyNotFoundException/);
    assert.throws(() => simulateOnError(section('<trace source="s"><message>@(DateTime.UtcNow.ToString("u"))</message></trace>'), error, REQUEST_ID), /not simulated/);
  });

  test("records an outgoing call instead of skipping it", () => {
    const a = simulateOnError(section('<send-request mode="new" response-variable-name="r" />'), error, REQUEST_ID);
    assert.deepEqual(a.calls, ["send-request"]);
  });

  test("runs the C# the section uses: casts, generic reads, Ordinal prefixes and JObject bodies", () => {
    const xml = [
      '<on-error><set-variable name="k" value="@{ var p = context.LastError.PolicyId ?? &quot;&quot;; if (p.StartsWith(&quot;ccof-&quot;, StringComparison.Ordinal)) { return &quot;ours&quot;; } return &quot;other&quot;; }" />',
      '<return-response><set-status code="418" reason="@((string)context.Variables[&quot;k&quot;])" />',
      `<set-body><![CDATA[@(new JObject(new JProperty("a", context.Variables.GetValueOrDefault<string>("missing", "d"))).ToString(Newtonsoft.Json.Formatting.None))]]></set-body>`,
      "</return-response></on-error>",
    ].join("");
    const a = simulateOnError(parseApimXml(xml), { ...error, policyId: "ccof-x" }, REQUEST_ID);
    assert.deepEqual([a.status, a.reason, a.body], [418, "ours", '{"a":"d"}']);
  });
});
