// The Azure side of ADR 0040: the ARM reads and the one APIM write, and the Cosmos descriptor store.

import { test } from "node:test";
import assert from "node:assert/strict";
import type { TokenCredential } from "@azure/identity";
import type { Container } from "@azure/cosmos";
import { createArmOnboardingProvider, createCosmosDescriptorStore, createOnboardingDependencies, readOnboardingTargets } from "../src/backend-onboarding-arm.ts";
import { ProviderError } from "../src/operations.ts";

const SUB = "/subscriptions/00000000-0000-0000-0000-000000000001";
const ACCOUNT = `${SUB}/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/foundry2`;
const APIM = `${SUB}/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-a`;
const credential: TokenCredential = { getToken: async (scope) => ({ token: `tok:${String(scope)}`, expiresOnTimestamp: Date.now() + 60_000 }) };

function transport(routes: Record<string, { status: number; body?: unknown }>) {
  const calls: { method: string; url: string; init: RequestInit }[] = [];
  const fn = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const url = String(input);
    calls.push({ method: init.method ?? "GET", url, init });
    const key = Object.keys(routes).find((k) => url.startsWith(k));
    const r = key ? routes[key] : { status: 404 };
    return new Response(r.body === undefined ? null : JSON.stringify(r.body), { status: r.status });
  }) as typeof fetch;
  return { fn, calls };
}

test("the account read maps the endpoint, network and private endpoint states; 404 is null", async () => {
  const t = transport({
    [`https://management.azure.com${ACCOUNT}?`]: { status: 200, body: { id: ACCOUNT, properties: {
      customSubDomainName: "Foundry2", publicNetworkAccess: "Disabled",
      privateEndpointConnections: [{ properties: { privateLinkServiceConnectionState: { status: "Pending" } } }],
    } } },
  });
  const provider = createArmOnboardingProvider(credential, t.fn);
  assert.deepEqual(await provider.account(ACCOUNT), { id: ACCOUNT, customSubDomainName: "Foundry2", publicNetworkAccess: "Disabled", privateEndpointStatuses: ["Pending"] });
  const call = t.calls[0];
  assert.equal(call.init.redirect, "error");
  assert.equal((call.init.headers as Record<string, string>).authorization, "Bearer tok:https://management.azure.com/.default");
  assert.equal(await provider.account(`${ACCOUNT}x`), null);
});

test("deployments, the APIM principal and the role assignments filtered by principal", async () => {
  const t = transport({
    [`https://management.azure.com${ACCOUNT}/deployments?`]: { status: 200, body: { value: [{ name: "claude-haiku-4-5", properties: { provisioningState: "Succeeded" } }] } },
    [`https://management.azure.com${APIM}?`]: { status: 200, body: { identity: { principalId: "11111111-1111-1111-1111-111111111111" } } },
    [`https://management.azure.com${ACCOUNT}/providers/Microsoft.Authorization/roleAssignments?`]: { status: 200, body: { value: [
      { properties: { roleDefinitionId: "/subscriptions/x/providers/Microsoft.Authorization/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908", scope: ACCOUNT } },
    ] } },
  });
  const provider = createArmOnboardingProvider(credential, t.fn);
  assert.deepEqual(await provider.deployments(ACCOUNT), [{ name: "claude-haiku-4-5", provisioningState: "Succeeded" }]);
  assert.equal(await provider.apimPrincipal(APIM), "11111111-1111-1111-1111-111111111111");
  const roles = await provider.roleAssignments(ACCOUNT, "11111111-1111-1111-1111-111111111111");
  assert.equal(roles.length, 1);
  assert.equal(roles[0].scope, ACCOUNT);
  const url = new URL(t.calls.at(-1)!.url);
  assert.equal(url.searchParams.get("$filter"), "principalId eq '11111111-1111-1111-1111-111111111111'");
  await assert.rejects(provider.roleAssignments(ACCOUNT, "x' or 1 eq 1"), /invalid_principal/);
});

test("the APIM backend read and write; an upstream error is a ProviderError with its status", async () => {
  const t = transport({
    [`https://management.azure.com${APIM}/backends/foundry2?`]: { status: 200, body: { properties: { url: "https://foundry2.services.ai.azure.com/anthropic" } } },
    [`https://management.azure.com${APIM}/backends/pool1?`]: { status: 200, body: { properties: { type: "Pool", pool: { services: [] } } } },
    [`https://management.azure.com${APIM}/backends/missing?`]: { status: 404 },
    [`https://management.azure.com${APIM}/backends/denied?`]: { status: 403 },
  });
  const provider = createArmOnboardingProvider(credential, t.fn);
  assert.deepEqual(await provider.apimBackend(APIM, "foundry2"), { url: "https://foundry2.services.ai.azure.com/anthropic", type: null });
  assert.deepEqual(await provider.apimBackend(APIM, "pool1"), { url: null, type: "Pool" });
  assert.equal(await provider.apimBackend(APIM, "missing"), null);
  await assert.rejects(provider.apimBackend(APIM, "denied"), (err) => err instanceof ProviderError && err.status === 403);
  await provider.putApimBackend(APIM, "foundry2", "https://foundry2.services.ai.azure.com/anthropic");
  const put = t.calls.at(-1)!;
  assert.equal(put.method, "PUT");
  assert.match(put.url, /\/backends\/foundry2\?api-version=2024-05-01$/);
  assert.deepEqual(JSON.parse(String(put.init.body)), { properties: {
    url: "https://foundry2.services.ai.azure.com/anthropic", protocol: "http",
    tls: { validateCertificateChain: true, validateCertificateName: true },
  } });
});

test("the Cosmos descriptor store reads by partition key and creates without upsert", async () => {
  // Keyed by id and partition key, as Cosmos is.
  const docs = new Map<string, unknown>([["foundry-team01|foundry-team01", { id: "foundry-team01", backendId: "foundry-team01" }]]);
  const container = {
    item: (id: string, pk: string) => ({ read: async () => ({ statusCode: docs.has(`${id}|${pk}`) ? 200 : 404, resource: docs.get(`${id}|${pk}`) }) }),
    items: { create: async (doc: { id: string; backendId: string }) => {
      const key = `${doc.id}|${doc.backendId}`;
      if (docs.has(key)) throw Object.assign(new Error("conflict"), { code: 409 });
      docs.set(key, doc);
      return {};
    } },
  } as unknown as Container;
  const store = createCosmosDescriptorStore(container);
  assert.deepEqual(await store.read("foundry-team01"), { id: "foundry-team01", backendId: "foundry-team01" });
  assert.equal(await store.read("none"), null);
  assert.equal(await store.create({ id: "new", backendId: "new" }), "created");
  assert.equal(await store.create({ id: "new", backendId: "new" }), "conflict");
  // The reservation is a separate document in the backend's partition; the first endpoint keeps it.
  assert.equal(await store.readClaim("new"), null);
  assert.equal(await store.claim("new", "https://a.services.ai.azure.com/anthropic"), "https://a.services.ai.azure.com/anthropic");
  assert.equal(await store.claim("new", "https://b.services.ai.azure.com/anthropic"), "https://a.services.ai.azure.com/anthropic");
  assert.equal(await store.readClaim("new"), "https://a.services.ai.azure.com/anthropic");
  assert.deepEqual(await store.read("new"), { id: "new", backendId: "new" });
  assert.deepEqual(docs.get("onboarding-claim|new"), { id: "onboarding-claim", backendId: "new", kind: "onboarding-claim", url: "https://a.services.ai.azure.com/anthropic" });
  // An existing claim without a readable owner is refused, never treated as this caller's claim.
  docs.set("onboarding-claim|broken", { id: "onboarding-claim", backendId: "broken" });
  await assert.rejects(store.claim("broken", "https://a.services.ai.azure.com/anthropic"), (e: { status?: number; message?: string; code?: string }) =>
    e.status === 503 && /claim_unreadable/.test(`${e.message} ${e.code}`));
});

test("targets come from ADMIN_GATEWAY_RESOURCE_IDS, else the single gateway ID; only APIM IDs are kept", () => {
  assert.deepEqual(readOnboardingTargets({ ADMIN_GATEWAY_RESOURCE_IDS: ` ${APIM} , ${APIM}b `, ADMIN_GATEWAY_RESOURCE_ID: "ignored" }), [APIM, `${APIM}b`]);
  assert.deepEqual(readOnboardingTargets({ ADMIN_GATEWAY_RESOURCE_ID: APIM }), [APIM]);
  assert.throws(() => readOnboardingTargets({ ADMIN_GATEWAY_RESOURCE_IDS: ACCOUNT }), /gateway/);
  assert.deepEqual(readOnboardingTargets({}), []);
});

test("onboarding dependencies are built only when the flag is exactly true and the config is complete", () => {
  const opened: string[] = [];
  const open = (name: string) => { opened.push(name); return {} as Container; };
  const env = { ADMIN_BACKEND_ONBOARDING: "true", ADMIN_GATEWAY_RESOURCE_IDS: `${APIM},${APIM}-b`, ADMIN_RESOURCE_IDS: ` ${ACCOUNT} ,`, ADMIN_DISCOVERY_SCOPES: SUB };
  const deps = createOnboardingDependencies(env, credential, open);
  assert.ok(deps);
  assert.deepEqual(deps.targets, [APIM, `${APIM}-b`]);
  assert.deepEqual(deps.resourceIds, [ACCOUNT]);
  assert.deepEqual(deps.discoveryScopes, [SUB]);
  assert.deepEqual(opened, ["backends"]);
  for (const flag of [undefined, "", "TRUE", "1", "false"]) {
    assert.equal(createOnboardingDependencies({ ...env, ADMIN_BACKEND_ONBOARDING: flag }, credential, open), null, `flag ${flag}`);
  }
  // Flag on but incomplete: the routes answer 503 and name the setting, rather than disappearing.
  assert.deepEqual(createOnboardingDependencies(env, credential, () => null), { misconfigured: "COSMOS_ENDPOINT" }, "no Cosmos");
  assert.deepEqual(createOnboardingDependencies({ ...env, ADMIN_GATEWAY_RESOURCE_IDS: "bogus", ADMIN_GATEWAY_RESOURCE_ID: "" }, credential, open),
    { misconfigured: "ADMIN_GATEWAY_RESOURCE_IDS" }, "bad targets");
  assert.deepEqual(createOnboardingDependencies({ ...env, ADMIN_GATEWAY_RESOURCE_IDS: "", ADMIN_GATEWAY_RESOURCE_ID: "" }, credential, open),
    { misconfigured: "ADMIN_GATEWAY_RESOURCE_IDS" }, "no targets");
  assert.deepEqual(createOnboardingDependencies({ ...env, ADMIN_RESOURCE_IDS: "", ADMIN_DISCOVERY_SCOPES: "" }, credential, open),
    { misconfigured: "ADMIN_RESOURCE_IDS" }, "no scope");
});

test("list reads follow nextLink on management.azure.com and refuse any other host", async () => {
  const page2 = `https://management.azure.com${ACCOUNT}/deployments?api-version=2024-10-01&$skiptoken=p2`;
  const t = transport({
    [page2]: { status: 200, body: { value: [{ name: "claude-sonnet-4-5", properties: { provisioningState: "Succeeded" } }] } },
    [`https://management.azure.com${ACCOUNT}/deployments?`]: { status: 200, body: { value: [{ name: "claude-haiku-4-5", properties: { provisioningState: "Succeeded" } }], nextLink: page2 } },
  });
  const provider = createArmOnboardingProvider(credential, t.fn);
  assert.deepEqual((await provider.deployments(ACCOUNT)).map((d) => d.name), ["claude-haiku-4-5", "claude-sonnet-4-5"]);
  assert.equal(t.calls.length, 2);
  assert.equal((t.calls[1].init.headers as Record<string, string>).authorization, "Bearer tok:https://management.azure.com/.default");

  const evil = transport({
    [`https://management.azure.com${ACCOUNT}/deployments?`]: { status: 200, body: { value: [], nextLink: "https://attacker.example/steal" } },
  });
  await assert.rejects(createArmOnboardingProvider(credential, evil.fn).deployments(ACCOUNT), (e: unknown) => e instanceof ProviderError && /invalid_next_link/.test(e.message));
  assert.equal(evil.calls.length, 1);
});
