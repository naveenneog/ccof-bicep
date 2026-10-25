// Rendered policy structure (AC3, AC11, AC12): the order of the inbound steps,
// the cache and counter keys, the managed-identity resources, the backend
// allow-list, header stripping and the telemetry traces, all from configuration.

import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import path from "node:path";
import { describe, test } from "node:test";
import { fileURLToPath } from "node:url";

import type { XmlElement } from "../infra/gateway/apim-xml.ts";
import { attr, descendants, parseApimXml, textOf } from "../infra/gateway/apim-xml.ts";
import type { GatewayConfig } from "../infra/gateway/config.ts";
import { loadTemplates, renderFromFile, renderPolicy, usageUrlFor } from "../infra/gateway/render.ts";
import { sampleConfig } from "./helpers/gateway-fixtures.ts";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = sampleConfig() as GatewayConfig;
const rendered = renderPolicy(config);
const root = parseApimXml(rendered.policyXml);
const section = (name: string): XmlElement => {
  const found = root.children.find((n): n is XmlElement => n.kind === "element" && n.name === name);
  assert.ok(found, `section ${name} missing`);
  return found;
};
const inbound = section("inbound");
const backend = section("backend");
const onError = section("on-error");
const outbound = section("outbound");

function byId(id: string, scope: XmlElement = root): XmlElement {
  const found = descendants(scope).filter((e) => attr(e, "id") === id);
  assert.equal(found.length, 1, `expected exactly one element with id ${id}, found ${found.length}`);
  return found[0];
}

function setVariable(name: string, scope: XmlElement = inbound): XmlElement[] {
  return descendants(scope).filter((e) => e.name === "set-variable" && attr(e, "name") === name);
}

function indexIn(list: XmlElement[], el: XmlElement): number {
  const i = list.indexOf(el);
  assert.ok(i >= 0, `${el.name} not in the inbound sequence`);
  return i;
}

// The elements from the root down to target's parent, or null when target is not below scope.
function pathTo(target: XmlElement, scope: XmlElement = root, trail: XmlElement[] = []): XmlElement[] | null {
  for (const child of scope.children) {
    if (child.kind !== "element") continue;
    if (child === target) return [...trail, scope];
    const found = pathTo(target, child, [...trail, scope]);
    if (found) return found;
  }
  return null;
}

describe("rendered policy structure", () => {
  test("the root is <policies> with inbound, backend, outbound and on-error, in that order", () => {
    assert.equal(root.name, "policies");
    const names = root.children.filter((n): n is XmlElement => n.kind === "element").map((e) => e.name);
    assert.deepEqual(names, ["inbound", "backend", "outbound", "on-error"]);
  });

  test("inbound runs its steps in the contract's order", () => {
    const all = descendants(inbound);
    const steps = [
      byId("ccof-jwt"),
      setVariable("ccofOid")[0],
      byId("ccof-admission-person"),
      descendants(inbound).find((e) => e.name === "cache-lookup-value")!,
      byId("ccof-admission-resolver"),
      byId("ccof-resolver-credential"),
      byId("ccof-admission-resolver-concurrency"),
      descendants(inbound).find((e) => e.name === "send-request" && attr(e, "response-variable-name") === "ccofResolverResponse")!,
      descendants(inbound).find((e) => e.name === "cache-store-value")!,
      setVariable("ccofModelAllowed")[0],
      byId("ccof-limit-group-rate-quota"),
      byId("ccof-limit-person-rate-quota"),
      descendants(inbound).find((e) => e.name === "set-header" && attr(e, "name") === "x-api-key")!,
      descendants(inbound).filter((e) => e.name === "set-backend-service")[0],
      descendants(inbound).filter((e) => e.name === "return-response").at(-1)!,
    ];
    const positions = steps.map((s) => indexIn(all, s));
    assert.deepEqual(positions, [...positions].sort((a, b) => a - b), "inbound steps are out of order");
  });

  test("validate-jwt pins the configured tenant's v1 and v2 issuers, audiences and tid", () => {
    const jwt = byId("ccof-jwt");
    assert.equal(jwt.name, "validate-jwt");
    assert.equal(attr(jwt, "output-token-variable-name"), "ccofJwt");
    const tenant = config.entra.tenantId;
    const openId = descendants(jwt).filter((e) => e.name === "openid-config").map((e) => attr(e, "url"));
    assert.deepEqual(openId, [`${config.entra.authorityHost}/${tenant}/v2.0/.well-known/openid-configuration`]);
    const text = (name: string) => descendants(jwt).filter((e) => e.name === name).map((e) => e.children.map((c) => ("value" in c ? c.value : "")).join("").trim());
    assert.deepEqual(text("audience"), config.entra.audiences);
    assert.deepEqual(text("issuer"), [`${config.entra.v1IssuerHost}/${tenant}/`, `${config.entra.authorityHost}/${tenant}/v2.0`]);
    const tid = descendants(jwt).find((e) => e.name === "claim" && attr(e, "name") === "tid");
    assert.ok(tid, "tid is not a required claim");
    assert.deepEqual(text("value"), [tenant]);
  });

  test("the identity check requires a GUID oid and refuses app-only tokens except the configured test clients", () => {
    const refusal = attr(setVariable("ccofRefusal")[0], "value")!;
    assert.match(refusal, /token_identity_missing/);
    assert.match(refusal, /" access_as_user "/);
    assert.match(refusal, /new string\[\] \{ "00000000-0000-0000-0000-00000000000c" \}/);
    assert.match(refusal, /app_token_not_allowed/);
    assert.match(attr(setVariable("ccofOid")[0], "value")!, /\^\[0-9a-f\]\{8\}-/);

    const noTestClients = sampleConfig();
    noTestClients.entra.testIdentities = { allowAppOnlyTokens: false, clientAppIds: [], appRole: null };
    const strict = renderPolicy(noTestClients as GatewayConfig).policyXml;
    assert.match(strict, /return false && Array\.IndexOf/);
    assert.doesNotMatch(strict, /00000000-0000-0000-0000-00000000000c/);
  });

  // WP-NET S1, AC15. Learn: app-only tokens "can be issued without a roles claim", and an API called by
  // daemon apps verifies "the roles claim and that this claim has the expected value". Jwt.Claims holds each
  // claim's values as string[]; GetValueOrDefault joins them with commas, and a role value may contain one.
  test("an app-only token also needs the configured app role, matched exactly among the roles claim's values (S1, AC15)", () => {
    const refusal = attr(setVariable("ccofRefusal")[0], "value")!;
    const appOnly = refusal.slice(refusal.indexOf("var testClients"));
    assert.match(appOnly, /string\[\] roles;\s*var hasRole = \(\(Jwt\)context\.Variables\["ccofJwt"\]\)\.Claims\.TryGetValue\("roles", out roles\) && roles != null && Array\.IndexOf\(roles, "Gateway\.Test"\) >= 0;/);
    assert.match(appOnly, /return true && Array\.IndexOf\(testClients, \(string\)context\.Variables\["ccofClientAppId"\]\) >= 0 && hasRole \? "" : "app_token_not_allowed";/);
    assert.doesNotMatch(refusal, /GetValueOrDefault\("roles"/, "a comma-joined roles value can match inside a role that contains a comma");
    assert.ok(refusal.indexOf('" access_as_user "') < refusal.indexOf("hasRole"), "a person's token is decided by its scope before the app-only checks");

    const otherRole = sampleConfig();
    otherRole.entra.testIdentities.appRole = "Gateway.Other";
    assert.match(renderPolicy(otherRole as GatewayConfig).policyXml, /Array\.IndexOf\(roles, "Gateway\.Other"\) >= 0/);
  });

  // WP-SEC A3. scp names the Gateway API's permission, not the client: any application granted the scope
  // gets tokens that carry it. A person's token must also come from a configured client (azp, or appid in
  // a v1 token), compared with the lower-cased ccofClientAppId.
  test("a person's token must carry the scope and come from a configured client application (A3)", () => {
    const refusal = attr(setVariable("ccofRefusal")[0], "value")!;
    const delegated = refusal.slice(refusal.indexOf('if (scopes != "")'), refusal.indexOf("var testClients"));
    assert.match(delegated, /" access_as_user "/);
    assert.match(delegated, /var delegatedClients = new string\[\] \{ "00000000-0000-0000-0000-00000000000f" \};/);
    assert.match(delegated, /return Array\.IndexOf\(delegatedClients, \(string\)context\.Variables\["ccofClientAppId"\]\) >= 0 \? "" : "token_client_not_allowed";/);
    assert.match(attr(setVariable("ccofRefusalStatus")[0], "value")!, /case "token_client_not_allowed":[^;]*return 403;/);
    assert.match(attr(setVariable("ccofRefusalBody")[0], "value")!, /case "token_client_not_allowed":\s*type = "permission_error";/);

    const two = sampleConfig();
    two.entra.delegatedClientAppIds = ["00000000-0000-0000-0000-00000000000f", "00000000-0000-0000-0000-000000000010"];
    assert.match(renderPolicy(two as GatewayConfig).policyXml, /var delegatedClients = new string\[\] \{ "00000000-0000-0000-0000-00000000000f", "00000000-0000-0000-0000-000000000010" \};/);
  });

  test("per-person admission runs before any resolver call, with the configured limits", () => {
    const person = byId("ccof-admission-person");
    assert.equal(attr(person, "calls"), "120");
    assert.equal(attr(person, "renewal-period"), "60");
    assert.match(attr(person, "counter-key")!, /ccofOid/);
    const misses = byId("ccof-admission-resolver");
    assert.equal(attr(misses, "calls"), "200");
    assert.equal(attr(misses, "renewal-period"), "1");
    assert.equal(attr(byId("ccof-admission-resolver-concurrency"), "max-count"), "100");
  });

  test("the entitlement cache key is versioned per tenant, person and selector", () => {
    const key = attr(setVariable("ccofCacheKey")[0], "value")!;
    // d3: the cached decision's format; v3: the configured keyVersion.
    assert.match(key, /"ccof-ent:d3:v3:00000000-0000-0000-0000-00000000000a:"/);
    assert.match(key, /ccofOid/);
    assert.match(key, /ccofSelector/);
    for (const name of ["cache-lookup-value", "cache-store-value"]) {
      const els = descendants(inbound).filter((e) => e.name === name);
      assert.equal(els.length, 1, `${name} must appear once in inbound (Learn: once per section)`);
      assert.equal(attr(els[0], "caching-type"), "internal");
      assert.match(attr(els[0], "key")!, /ccofCacheKey/);
    }
  });

  test("cache TTLs and the last-known-good grace come from configuration", () => {
    const state = setVariable("ccofCacheState").map((e) => attr(e, "value")!).find((v) => v.includes("age"))!;
    assert.match(state, /if \(age >= 120 \+ 3600\) \{ return "miss"; \}/);
    assert.match(state, /if \(age < 120\) \{ return "fresh-allow"; \}/);
    assert.match(state, /age < 30 \?/);
    const seconds = setVariable("ccofStoreSeconds").map((e) => attr(e, "value")!);
    assert.equal(seconds.length, 3);
    assert.ok(seconds.includes("@(120 + 3600)"));
    assert.ok(seconds.includes("@(30)"));
    const rewrite = seconds.find((s) => s.includes("left"))!;
    assert.match(rewrite, /var left = 120 \+ 3600 - \(DateTime\.UtcNow\.Ticks \/ 10000000 - \(long\)JObject\.Parse\(\(string\)context\.Variables\["ccofCached"\]\)\["at"\]\);/);
    assert.match(rewrite, /return left < 1 \? 1 : \(int\)left;/);
  });

  test("a failed refresh serves last-known-good and backs off: the resolver is not asked again before retry-at (B1)", () => {
    const state = setVariable("ccofCacheState").map((e) => attr(e, "value")!).find((v) => v.includes("age"))!;
    assert.match(state, /var retryAt = entry\["rt"\];/);
    assert.match(state, /retryAt != null && retryAt\.Type == JTokenType\.Integer && now < \(long\)retryAt \? "stale-allow-backoff" : "stale-allow"/);
    const whenOf = (condition: RegExp) => descendants(inbound).filter((e) => e.name === "when" && condition.test(attr(e, "condition") ?? ""));
    // In backoff the decision comes from the entry, marked last-known-good, and the resolver is not called.
    const backoff = whenOf(/ccofCacheState"\] == "stale-allow-backoff"\)$/);
    assert.equal(backoff.length, 1);
    const backoffVars = descendants(backoff[0]).filter((e) => e.name === "set-variable");
    assert.deepEqual(backoffVars.map((e) => attr(e, "name")), ["ccofDecision", "ccofEntitlementSource"]);
    assert.equal(attr(backoffVars[1], "value"), "last-known-good");
    assert.match(attr(backoffVars[0], "value")!, /ccofCached"\]\)\["d"\]/);
    const call = descendants(inbound).find((e) => e.name === "send-request" && attr(e, "response-variable-name") === "ccofResolverResponse")!;
    const gate = descendants(inbound).filter((e) => e.name === "when" && descendants(e).includes(call)).map((e) => attr(e, "condition")!);
    assert.ok(gate.some((c) => c.includes('== "miss"') && c.includes('== "stale-allow")')), "the resolver is called on a miss or a due refresh");
    assert.ok(gate.every((c) => !c.includes("backoff")), "the resolver must not be called during the backoff");
    // A refresh that fails keeps the entry's time and decision and sets retry-at from configuration.
    const stale = whenOf(/ccofCacheState"\] == "stale-allow"\)$/).find((w) => descendants(w).some((e) => e.name === "set-variable" && attr(e, "name") === "ccofStoreValue"))!;
    assert.ok(stale, "a failed refresh does not rewrite the entry");
    const store = attr(descendants(stale).find((e) => e.name === "set-variable" && attr(e, "name") === "ccofStoreValue")!, "value")!;
    assert.match(store, /new JProperty\("k", "allow"\)/);
    assert.match(store, /new JProperty\("at", \(long\)cached\["at"\]\)/);
    assert.match(store, /new JProperty\("rt", DateTime\.UtcNow\.Ticks \/ 10000000 \+ 45\)/);
    assert.match(store, /new JProperty\("d", JObject\.Parse\(\(string\)context\.Variables\["ccofDecision"\]\)\)/);
    assert.equal(attr(descendants(stale).find((e) => e.name === "set-variable" && attr(e, "name") === "ccofEntitlementSource")!, "value"), "last-known-good");
  });

  test("the gateway-wide resolver limits apply to misses only, so a due refresh still gets last-known-good (B1)", () => {
    const rate = byId("ccof-admission-resolver");
    const parent = descendants(inbound).find((e) => e.children.includes(rate))!;
    assert.equal(parent.name, "when");
    assert.equal(attr(parent, "condition"), '@((string)context.Variables["ccofCacheState"] == "miss")');
    assert.equal(
      attr(byId("ccof-admission-resolver-concurrency"), "key"),
      '@((string)context.Variables["ccofCacheState"] == "miss" ? "ccof-resolver-calls" : "ccof-resolver-refresh:" + (string)context.Variables["ccofOid"])',
    );
  });

  test("the resolver is called with APIM's managed identity, the configured URL, timeout and body", () => {
    const credential = byId("ccof-resolver-credential");
    assert.equal(credential.name, "authentication-managed-identity");
    assert.equal(attr(credential, "resource"), config.resolver.tokenAudience);
    assert.equal(attr(credential, "ignore-error"), "true");
    const call = descendants(inbound).find((e) => e.name === "send-request" && attr(e, "response-variable-name") === "ccofResolverResponse")!;
    assert.equal(attr(call, "timeout"), "10");
    assert.equal(attr(call, "ignore-error"), "true");
    const url = descendants(call).find((e) => e.name === "set-url")!;
    assert.equal(url.children.map((c) => ("value" in c ? c.value : "")).join("").trim(), config.resolver.url);
    const body = descendants(call).find((e) => e.name === "set-body")!;
    const bodyText = body.children.map((c) => ("value" in c ? c.value : "")).join("");
    for (const field of ['"personId"', '"requestId"', '"projectId"']) assert.ok(bodyText.includes(field), `resolver body lacks ${field}`);
    const parent = descendants(inbound).find((e) => e.children.includes(credential))!;
    const siblings = parent.children.filter((c): c is XmlElement => c.kind === "element");
    const next = siblings[siblings.indexOf(credential) + 1];
    assert.ok(
      next && next.name === "set-header" && attr(next, "name") === "Authorization" && attr(next, "exists-action") === "delete",
      "Authorization is not deleted right after the resolver token is taken (U-new-GW-4)",
    );
  });

  test("person and group token limits use the contract's counter keys and the resolver's values", () => {
    const limits = descendants(inbound).filter((e) => e.name === "llm-token-limit" && !attr(e, "id")!.startsWith("ccof-limit-family-"));
    assert.deepEqual(limits.map((e) => attr(e, "id")), [
      "ccof-limit-group-rate-quota", "ccof-limit-group-rate", "ccof-limit-group-quota",
      "ccof-limit-person-rate-quota", "ccof-limit-person-rate", "ccof-limit-person-quota",
    ]);
    for (const limit of limits) {
      const scope = attr(limit, "id")!.includes("group") ? "Group" : "Person";
      const key = attr(limit, "counter-key")!;
      if (scope === "Group") assert.match(key, /^@\("g:" \+ \(string\)context\.Variables\["ccofProjectId"\] \+ ":" \+ \(string\)context\.Variables\["ccofClassification"\]\)$/);
      else assert.match(key, /^@\("p:" \+ \(string\)context\.Variables\["ccofProjectId"\] \+ ":" \+ \(string\)context\.Variables\["ccofOid"\]\)$/);
      assert.equal(attr(limit, "estimate-prompt-tokens"), "false");
      const tpm = attr(limit, "tokens-per-minute");
      if (tpm !== undefined) assert.equal(tpm, `@((int)context.Variables["ccof${scope}Tpm"])`);
      const quota = attr(limit, "token-quota");
      if (quota !== undefined) {
        assert.equal(quota, `@((long)context.Variables["ccof${scope}Quota"])`);
        assert.equal(attr(limit, "token-quota-period"), `@((string)context.Variables["ccof${scope}Period"])`);
        assert.equal(attr(limit, "remaining-quota-tokens-header-name"), scope === "Group" ? "x-test-group-quota-remaining" : "x-test-person-quota-remaining");
      }
      if (tpm !== undefined) assert.equal(attr(limit, "remaining-tokens-header-name"), scope === "Group" ? "x-test-group-tokens-remaining" : "x-test-person-tokens-remaining");
      assert.equal(attr(limit, "retry-after-variable-name"), "ccofRetryAfter");
    }
    assert.ok(limits.filter((e) => attr(e, "id")!.startsWith("ccof-limit-person")).every((e) => attr(e, "tokens-consumed-header-name") === "x-test-tokens-consumed"));
  });

  test("backends: static named-value branches by id, every other backend by the descriptor's mode (C-8)", () => {
    const routes = descendants(inbound).filter((e) => e.name === "set-backend-service").map((e) => attr(e, "backend-id"));
    const dynamic = '@((string)context.Variables["ccofBackendId"])';
    assert.deepEqual(routes, ["backend-cross-tenant", dynamic, dynamic, dynamic]);
    const mi = byId("ccof-backend-credential-managed-identity");
    assert.equal(mi.name, "authentication-managed-identity");
    assert.equal(attr(mi, "resource"), '@((string)context.Variables["ccofBackendAuthResource"])');
    const cm = byId("ccof-backend-credential-credential-manager");
    assert.equal(cm.name, "get-authorization-context");
    assert.equal(attr(cm, "provider-id"), '@((string)context.Variables["ccofBackendAuthProvider"])');
    assert.equal(attr(cm, "authorization-id"), '@((string)context.Variables["ccofBackendAuthConnection"])');
    assert.equal(attr(cm, "identity-type"), "managed");
    assert.equal(attr(cm, "ignore-error"), "true");
    const secret = descendants(inbound).filter((e) => e.name === "set-variable" && attr(e, "name") === "ccofBackendSecret").map((e) => attr(e, "value"));
    assert.deepEqual(secret, ["{{test-backend-client-secret}}", ""]);
    const tokenCall = byId("ccof-backend-credential-backend-cross-tenant");
    const url = descendants(tokenCall).find((e) => e.name === "set-url")!;
    assert.equal(url.children.map((c) => ("value" in c ? c.value : "")).join("").trim(), "https://login.example.test/00000000-0000-0000-0000-0000000000f1/oauth2/v2.0/token");
    const body = descendants(tokenCall).find((e) => e.name === "set-body")!.children.map((c) => ("value" in c ? c.value : "")).join("");
    assert.ok(body.includes("client_id=00000000-0000-0000-0000-0000000000f2"));
    assert.ok(body.includes('UrlEncode("https://models.example.test/.default")'));
    assert.ok(body.includes('context.Variables["ccofBackendSecret"]'), "the secret must be bound through a variable, never spliced");
    assert.ok(rendered.policyXml.includes("backend_not_configured"));
  });

  test("a backend is routed only if it is configured or the resolver described it: no gateway-side list (C-8)", () => {
    assert.equal(setVariable("ccofBackendAllowList").length, 0, "C-8: the gateway routes only to what the resolver returns");
    const allowed = attr(setVariable("ccofBackendAllowed")[0], "value")!;
    assert.equal(allowed, '@(Array.IndexOf(new string[] { "backend-cross-tenant" }, (string)context.Variables["ccofBackendId"]) >= 0 || (string)context.Variables["ccofBackendAuthMode"] != "")');
    const classify = attr(setVariable("ccofResolverResult")[0], "value")!;
    for (const mode of ['"managed-identity"', '"credential-manager"', '"backend-entity"']) assert.ok(classify.includes(mode), `descriptor mode ${mode} is not parsed`);
    assert.match(classify, /"anthropic-messages"/);
    // The guards themselves, exactly: each failure makes the answer "unavailable".
    assert.match(classify, /\(string\)backend\["id"\] != \(string\)decision\["backendId"\]\) \{ return unavailable; \}/);
    assert.match(classify, /\} else if \(mode != "backend-entity"\) \{\s*return unavailable;/);
    // A managed-identity resource is checked for form only (an https or api URI, or a GUID); no configured list.
    assert.doesNotMatch(classify, /new string\[\] \{ "https/);
    assert.match(classify, /var resourceOk = System\.Text\.RegularExpressions\.Regex\.IsMatch\(resourceText, "\^\[0-9a-fA-F\]\{8\}-/);
    assert.match(classify, /resourceOk = resourceUri\.Scheme == Uri\.UriSchemeHttps \|\| resourceUri\.Scheme == "api";/);
    assert.match(classify, /if \(!resourceOk\) \{ return unavailable; \}/);
  });

  test("adding a backend by data changes no policy: no branch, condition or allow-list names a data backend", () => {
    const data = "backend-by-data";
    const withoutGeo = sampleConfig();
    delete withoutGeo.inferenceGeo[data];
    const policy = renderPolicy(withoutGeo as GatewayConfig).policyXml;
    assert.ok(!policy.includes(data), "a data backend appears in the policy");
    const conditions = descendants(parseApimXml(policy)).map((e) => attr(e, "condition") ?? "");
    assert.equal(conditions.filter((c) => /ccofBackendId"\] == "/.test(c)).length, 1, "only the static backend may have its own branch");
  });

  test("budget refusals are 403 permission_error naming the budget, never 429 (C-7)", () => {
    const classify = attr(setVariable("ccofResolverResult")[0], "value")!;
    assert.match(classify, /if \(outcome == "refused" && response\.StatusCode == 403 && \(error == "budget_exhausted" \|\| error == "aggregate_budget_exhausted"\)\) \{/);
    const status = attr(setVariable("ccofRefusalStatus")[0], "value")!;
    assert.match(status, /case "budget_exhausted": case "aggregate_budget_exhausted": return 403;/);
    const message = attr(setVariable("ccofRefusalBody")[0], "value")!;
    for (const code of ["budget_exhausted", "aggregate_budget_exhausted"]) {
      const at = message.indexOf(`case "${code}":`);
      assert.ok(at >= 0, `${code} has no message`);
      const branch = message.slice(at, message.indexOf("break;", at));
      assert.match(branch, /type = "permission_error";/);
      assert.match(branch, /budget/);
    }
    const cachedRefusal = attr(setVariable("ccofRefusal").find((e) => attr(e, "value")!.includes("ccofCached"))!, "value")!;
    assert.match(cachedRefusal, /"budget_exhausted"/);
    assert.match(cachedRefusal, /"aggregate_budget_exhausted"/);
  });

  test("client credentials are stripped before forwarding and anthropic headers pass through", () => {
    const all = descendants(inbound);
    // The backend branch: the <choose> whose <when> conditions select on ccofBackendId.
    const firstRoute = all.findIndex((e) => e.name === "choose" && e.children.some((c) => c.kind === "element" && c.name === "when" && /ccofBackendId"\] == "/.test(attr(c, "condition") ?? "")));
    assert.ok(firstRoute >= 0, "no backend branch found");
    // On the forwarding path itself: the resolver step's delete runs only on a cache miss.
    const routeChoose = all[firstRoute];
    const forwarding = all.find((e) => e.children.includes(routeChoose))!.children.filter((c): c is XmlElement => c.kind === "element");
    const routeAt = forwarding.indexOf(routeChoose);
    for (const name of ["Authorization", "x-api-key", "api-key", "x-test-project"]) {
      const strip = forwarding.findIndex((e) => e.name === "set-header" && attr(e, "name") === name && attr(e, "exists-action") === "delete");
      assert.ok(strip >= 0 && strip < routeAt, `${name} is not deleted on the forwarding path before the backend branch`);
    }
    assert.ok(!all.some((e) => e.name === "set-header" && /^anthropic-beta$/i.test(attr(e, "name") ?? "")), "anthropic-beta must pass through untouched");
    const version = all.filter((e) => e.name === "set-header" && attr(e, "name") === "anthropic-version");
    assert.equal(version.length, 1);
    assert.equal(attr(version[0], "exists-action"), "skip");

    const noDefault = sampleConfig();
    noDefault.forwarding.defaultAnthropicVersion = null;
    assert.doesNotMatch(renderPolicy(noDefault as GatewayConfig).policyXml, /name="anthropic-version"/);
  });

  // Owner approval (d), AC14. Learn "forward-request": buffer-response true holds chunks back (8 KB) and
  // takes no expression, so the stream decision is a choose between two forward-request policies.
  test("a streamed request is forwarded unbuffered and any other as the service scope's bare forward-request (approval (d), AC14)", () => {
    const steps = backend.children.filter((n): n is XmlElement => n.kind === "element");
    assert.deepEqual(steps.map((e) => e.name), ["choose"], "the backend section must forward by itself, not inherit the service scope through <base />");
    const branches = steps[0].children.filter((n): n is XmlElement => n.kind === "element");
    assert.deepEqual(branches.map((e) => e.name), ["when", "otherwise"]);
    assert.equal(attr(branches[0], "condition"), '@(context.Variables.GetValueOrDefault<bool>("ccofStream", false))');
    const onlyForward = (branch: XmlElement): XmlElement => {
      const inner = branch.children.filter((n): n is XmlElement => n.kind === "element");
      assert.deepEqual(inner.map((e) => e.name), ["forward-request"], `<${branch.name}> must run exactly one forward-request`);
      return inner[0];
    };
    assert.deepEqual(onlyForward(branches[0]).attributes.map((a) => [a.name, a.value]), [["buffer-response", "false"]]);
    assert.deepEqual(onlyForward(branches[1]).attributes, [], "a non-streamed request keeps the platform defaults, as the service scope's bare <forward-request />");
    assert.equal(descendants(root).filter((e) => e.name === "forward-request").length, 2, "forward-request appears only in the backend section");

    // The flag is set once on every path, before any refusal, from the body's "stream" when it is JSON true.
    const flag = setVariable("ccofStream");
    assert.equal(flag.length, 1);
    assert.ok(inbound.children.includes(flag[0]), "ccofStream must be set at the top level of inbound, not inside a stage");
    assert.match(attr(setVariable("ccofRequestFacts")[0], "value")!, /stream != null && stream\.Type == JTokenType\.Boolean && \(bool\)stream/);
  });

  // Learn "Configure API for server-sent events": avoid policies that buffer responses (validate-content),
  // request/response body logging and response caching. Live, 2026-10-12 (U-new-GW-10, request traces T and X3): a
  // policy whose expression mentions context.Response.Body makes the gateway read the whole reply before the policy
  // runs, even when the read sits behind a run-time check, so only a policy a streamed reply never reaches may do so.
  test("nothing holds back a streamed reply: only a policy a streamed reply never reaches mentions the response body, and no policy caches, validates, logs or rewrites it", () => {
    assert.equal([...rendered.policyXml.matchAll(/context\.Response\.Body/g)].length, 1, "the response body is mentioned in one place only");
    const readers = descendants(root).filter((e) => e.attributes.some((a) => a.value.includes("context.Response.Body")) || textOf(e).includes("context.Response.Body"));
    assert.deepEqual(readers.map((e) => `${e.name}:${attr(e, "name")}`), ["set-variable:ccofResponseJson"], "one policy of its own reads the response body");
    assert.equal(attr(readers[0], "value"), "@(context.Response.Body.As<string>(preserveContent: true))");
    const guard = pathTo(readers[0])!.filter((e) => e.name === "when").at(-1)!;
    assert.equal(
      attr(guard, "condition"),
      '@(!context.Variables.GetValueOrDefault<bool>("ccofStream", false) && context.Response.StatusCode == 200 && context.Response.Headers.GetValueOrDefault("Content-Type", "").Contains("application/json"))',
      "the body reader must sit in a branch that a streamed reply never enters",
    );
    assert.deepEqual(guard.children.filter((n): n is XmlElement => n.kind === "element").map((e) => e.name), ["set-variable"], "the not-streamed branch only reads the body");
    const builder = attr(setVariable("ccofUsageTrace", outbound)[0], "value")!;
    assert.doesNotMatch(builder, /context\.Response\.Body/, "the usage trace builder runs for streamed replies too, so it must not mention the response body");
    const bodyMentions = [outbound, onError]
      .flatMap((s) => descendants(s))
      .flatMap((e) => [...e.attributes.map((a) => a.value), textOf(e)])
      .filter((x) => /\.Body\b/.test(x));
    assert.deepEqual(bodyMentions, [attr(readers[0], "value")], "outbound and on-error mention a body only in the reader: a read under another name (var r = context.Response; r.Body) holds back a stream as well");
    assert.match(builder, /var text = context\.Variables\.GetValueOrDefault<string>\("ccofResponseJson", ""\);/);
    const order = descendants(outbound);
    assert.ok(order.indexOf(readers[0]) < order.indexOf(setVariable("ccofUsageTrace", outbound)[0]), "the body is read before the usage trace is built");
    for (const name of ["validate-content", "cache-lookup", "cache-store", "log-to-eventhub"]) {
      assert.ok(!descendants(root).some((e) => e.name === name), `<${name}> would hold back or copy a streamed reply`);
    }
    for (const name of ["find-and-replace", "xml-to-json", "json-to-xml"]) {
      assert.ok(!descendants(outbound).some((e) => e.name === name), `<${name}> in outbound rewrites the backend's body`);
    }
    const replacements = new Set(descendants(outbound).filter((e) => e.name === "return-response").flatMap((r) => descendants(r)));
    for (const body of descendants(outbound).filter((e) => e.name === "set-body")) {
      assert.ok(replacements.has(body), "an outbound set-body outside return-response rewrites the backend's body");
    }
  });

  test("outbound emits exactly one counts-only usage trace; the resolver trace is emitted at most once per path", () => {
    const usage = descendants(outbound).filter((e) => e.name === "trace" && attr(e, "source") === "ccof.usage.v1");
    assert.equal(usage.length, 1);
    assert.equal(attr(usage[0], "severity"), "information");
    const builder = attr(setVariable("ccofUsageTrace", outbound)[0], "value")!;
    const keys = [...builder.matchAll(/(?:JProperty\(|\[)"([A-Za-z_0-9]+)"/g)].map((m) => m[1]);
    const allowed = new Set([
      "schemaVersion", "requestId", "observedAt", "personId", "projectId", "classification", "classificationGroupId", "classificationGroupDisplayName", "modelFamily", "backendId", "deployment", "model",
      "streamed", "inferenceGeo", "inferenceGeoSource", "usageSource", "usage", "input_tokens", "output_tokens",
      "cache_read_input_tokens", "cache_creation", "ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens", "inference_geo",
      "ccofOid", "ccofProjectId", "ccofClassification", "ccofClassificationGroupId", "ccofClassificationGroupDisplayName", "ccofModelFamily", "ccofBackendId", "ccofModel", "ccofStream", "Content-Type",
    ]);
    for (const k of keys) assert.ok(allowed.has(k), `usage trace builder reads or writes a field outside the contract: ${k}`);
    const loops = [...builder.matchAll(/foreach \(var name in new string\[\] \{([^}]*)\}\)/g)];
    assert.equal(loops.length, 2, "the usage counts are copied by two field-name loops");
    for (const loop of loops) {
      for (const literal of loop[1].matchAll(/"([^"]*)"/g)) assert.ok(allowed.has(literal[1]), `usage trace builder copies a field outside the contract: ${literal[1]}`);
    }
    assert.doesNotMatch(builder, /context\.Request\.Body/, "the usage trace must not read the request body");
    assert.match(attr(setVariable("ccofResponseJson", outbound)[0], "value")!, /preserveContent: true/, "the body is read on a copy, so the reply can still be forwarded");
    const resolverTraces = descendants(root).filter((e) => e.name === "trace" && attr(e, "source") === "ccof.resolver.v1");
    assert.equal(resolverTraces.length, 3);
    assert.ok(descendants(onError).some((e) => e.name === "trace" && attr(e, "source") === "ccof.resolver.v1"));
  });

  test("a backend 401 or 403 (the gateway's own credential refused) is answered 502 api_error after the usage trace (W2)", () => {
    const forwarded = descendants(outbound).find((e) => e.name === "when" && /ccofBackendId/.test(attr(e, "condition") ?? ""))!;
    const mapped = descendants(forwarded).find((e) => e.name === "when" && attr(e, "condition") === "@(context.Response.StatusCode == 401 || context.Response.StatusCode == 403)");
    assert.ok(mapped, "a backend 401/403 is passed to the client, which would ask its user to sign in again");
    assert.equal(attr(descendants(mapped).find((e) => e.name === "set-status")!, "code"), "502");
    assert.ok(descendants(mapped).some((e) => e.name === "set-header" && attr(e, "name") === "x-ccof-request-id"));
    const body = descendants(mapped).find((e) => e.name === "set-body")!.children.map((c) => ("value" in c ? c.value : "")).join("");
    assert.match(body, /new JProperty\("type", "api_error"\)/);
    assert.match(body, /refused the gateway's credential/);
    assert.match(body, /" Request id: " \+ context\.RequestId\.ToString\(\)/);
    const all = descendants(outbound);
    const usage = all.find((e) => e.name === "trace" && attr(e, "source") === "ccof.usage.v1")!;
    assert.ok(all.indexOf(usage) < all.indexOf(mapped), "the usage trace must be written before the response is replaced");
  });

  test("a resolver 503 that carries a budget state is a refusal: it replaces last-known-good and is never served from it", () => {
    const classify = attr(setVariable("ccofResolverResult")[0], "value")!;
    assert.match(classify, /response\.StatusCode == 503 && \(budget == "stale" \|\| budget == "missing"\)/);
    assert.match(classify, /new JProperty\("c", "budget_state_unavailable"\)/);
    // The refusal branch (which stores the refusal over the cached entry) precedes the last-known-good branch.
    const decisionChoose = descendants(inbound).find((e) => e.name === "choose" && e.children.some((c) => c.kind === "element" && c.name === "when" && /"stale-allow"\)$/.test(attr(c, "condition") ?? "")))!;
    const whens = decisionChoose.children.filter((c): c is XmlElement => c.kind === "element" && c.name === "when").map((w) => attr(w, "condition")!);
    const refuseAt = whens.findIndex((c) => c.includes('== "refuse"'));
    const staleAt = whens.findIndex((c) => c.includes('"stale-allow"'));
    assert.ok(refuseAt >= 0 && refuseAt < staleAt, "a refusal must be handled before last-known-good is considered");
    const cachedRefusal = attr(setVariable("ccofRefusal").find((e) => attr(e, "value")!.includes("ccofCached"))!, "value")!;
    assert.match(cachedRefusal, /budget_state_unavailable/);
    assert.match(rendered.policyXml, /== "budget_state_unavailable"\)">\s*<return-response>\s*<set-status code="503"[\s\S]*?Retry-After/);
  });

  test("401 messages match APIM's reason strings by substring (live: TokenInvalidAudience, \"Invalid JWT.\")", () => {
    const body = attr(setVariable("ccofErrorBody", onError)[0], "value")!;
    for (const fragment of ['reason.Contains("NotPresent")', 'reason.Contains("Expired")', 'reason.Contains("Audience")', 'reason.Contains("Issuer")', 'reason.Contains("Claim")']) {
      assert.ok(body.includes(fragment), `the jwt messages do not test ${fragment}`);
    }
  });

  test("on-error answers in Anthropic's error shape and tells the limits apart by policy id", () => {
    const kind = attr(setVariable("ccofErrorKind", onError)[0], "value")!;
    for (const id of ["validate-jwt", "ccof-admission-person", "ccof-admission-resolver", "ccof-limit-group", "ccof-limit-person", "ccof-backend-credential"]) {
      assert.ok(kind.includes(`"${id}`), `on-error does not classify ${id}`);
    }
    const text = rendered.policyXml.slice(rendered.policyXml.indexOf("<on-error>"));
    for (const t of ["authentication_error", "rate_limit_error", "api_error"]) assert.ok(text.includes(`"${t}"`), `on-error never answers ${t}`);
    assert.ok(text.includes('new JProperty("type", "error")'));
    // Anthropic's taxonomy: 429 is rate_limit_error, 403 is permission_error (architect council W10).
    const body = attr(setVariable("ccofErrorBody", onError)[0], "value")!;
    for (const scope of ["person", "group"]) {
      assert.match(body, new RegExp(`case "${scope}_rate":\\s*type = "rate_limit_error";`));
      assert.match(body, new RegExp(`case "${scope}_quota":\\s*type = "permission_error";`));
    }
  });

  test("no placeholder is left and the only named values are the configured secrets", () => {
    assert.doesNotMatch(rendered.policyXml, /%%/);
    const named = [...rendered.policyXml.matchAll(/\{\{([^}]*)\}\}/g)].map((m) => m[1]);
    assert.deepEqual(named, ["test-backend-client-secret"]);
  });

  test("rendering is deterministic and stamps the configuration and template digests", () => {
    const again = renderPolicy(sampleConfig() as GatewayConfig);
    assert.equal(again.policyXml, rendered.policyXml);
    assert.equal(again.policySha256, rendered.policySha256);
    assert.match(rendered.policyXml, new RegExp(`configuration test-gateway-config \\(sha256 ${rendered.configSha256}`));
    const changed = sampleConfig();
    changed.entitlementCache.allowTtlSeconds = 121;
    assert.notEqual(renderPolicy(changed as GatewayConfig).policySha256, rendered.policySha256);
  });
});

describe("rendering from files", () => {
  const scratch = path.join(repoRoot, "infra", "gateway", "out", "test-render");

  test("an invalid configuration is refused and nothing is written", () => {
    rmSync(scratch, { recursive: true, force: true });
    assert.throws(() => renderFromFile(path.join(repoRoot, "tests", "gateway-render.test.ts"), scratch), /configuration/);
    assert.equal(existsSync(scratch), false);
  });

  test("the PoC configuration renders into the git-ignored output folder", () => {
    rmSync(scratch, { recursive: true, force: true });
    mkdirSync(scratch, { recursive: true });
    const out = renderFromFile(path.join(repoRoot, "tests", "fixtures", "gateway-public.json"), scratch);
    assert.deepEqual(readdirSync(scratch).sort(), ["claude-messages.policy.xml", "claude-messages.usage.policy.xml", "render.json"]);
    assert.match(out.result.policyXml, /\{\{foundry-crosstenant-client-secret\}\}/);
    const ignored = spawnSync("git", ["check-ignore", "-q", path.relative(repoRoot, out.policyPath)], { cwd: repoRoot });
    assert.equal(ignored.status, 0, "rendered output is not git-ignored");
    rmSync(scratch, { recursive: true, force: true });
  });
});

describe("own-usage API policy (docs/USAGE-SELF-SERVICE.md)", () => {
  const usage = parseApimXml(rendered.usagePolicyXml ?? "");
  const usageInbound = usage.children.find((c): c is XmlElement => c.kind === "element" && c.name === "inbound")!;
  const block = (xml: string, from: string, to: string) => { const s = xml.indexOf(from); return xml.slice(s, xml.indexOf(to, s)).replace(/\s+/g, " "); };
  test("is rendered with the main policy and checks the token exactly as Claude Messages does", () => {
    assert.ok(rendered.usagePolicyXml && rendered.usagePolicySha256 && rendered.usageTemplateSha256);
    assert.equal(rendered.usagePolicyXml.includes("%%"), false);
    assert.equal(block(rendered.usagePolicyXml, "<validate-jwt", "</validate-jwt>"), block(rendered.policyXml, "<validate-jwt", "</validate-jwt>"), "same validate-jwt");
    for (const name of ["ccofOid", "ccofClientAppId", "ccofRefusal"]) {
      assert.equal(textOf(setVariable(name, usageInbound)[0]) + attr(setVariable(name, usageInbound)[0], "value"),
        textOf(setVariable(name)[0]) + attr(setVariable(name)[0], "value"), name);
    }
  });
  test("refuses before any resolver call, rate-limits per person and sends only the token's oid", () => {
    const kids = usageInbound.children.filter((c): c is XmlElement => c.kind === "element").map((c) => attr(c, "id") || c.name);
    assert.ok(kids.indexOf("choose") < kids.indexOf("ccof-usage-person"), "refusal before admission");
    const refusal = usageInbound.children.find((c): c is XmlElement => c.kind === "element" && c.name === "choose")!;
    const when = descendants(refusal).find((e) => e.name === "when")!;
    assert.match(attr(when, "condition") ?? "", /ccofRefusal"\] != ""/, "a refused token (wrong scope, client or identity) is blocked");
    assert.ok(descendants(when).some((e) => e.name === "set-status" && attr(e, "code") === "403"), "blocked with 403");
    assert.ok(kids.indexOf("ccof-usage-person") < kids.indexOf("ccof-usage-resolver-credential"), "admission before the resolver");
    assert.match(attr(byId("ccof-usage-person", usage), "counter-key") ?? "", /ccof-usage:.*ccofOid/);
    const send = descendants(usage).find((e) => e.name === "send-request")!;
    assert.equal(textOf(descendants(send).find((e) => e.name === "set-url")!), usageUrlFor(config.resolver.url));
    const body = textOf(descendants(send).find((e) => e.name === "set-body")!);
    assert.match(body, /JProperty\("personId", \(string\)context\.Variables\["ccofOid"\]\)/);
    assert.doesNotMatch(body, /Request\.(Headers|Url|Body)/, "nothing from the request reaches the resolver");
    assert.doesNotMatch(rendered.usagePolicyXml ?? "", /forward-request/, "the usage API never forwards to a model backend");
  });
  test("the main policy and its digest are unchanged by the usage template", () => {
    const { usage: _u, ...withoutUsage } = loadTemplates();
    const mainOnly = renderPolicy(config, { templates: withoutUsage });
    assert.equal(mainOnly.policySha256, rendered.policySha256);
    assert.equal(mainOnly.templateSha256, rendered.templateSha256);
    assert.equal(mainOnly.usagePolicyXml, undefined);
  });
  test("the usage route is derived from the resolver URL", () => {
    assert.equal(usageUrlFor("https://r.example.net/api/resolve"), "https://r.example.net/api/me/usage");
    assert.throws(() => usageUrlFor("https://r.example.net/api/other"), /must end with \/resolve/);
  });
});
