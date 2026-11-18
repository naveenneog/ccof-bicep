// ADR 0040: the admin console onboards a Foundry backend (admin/src/backend-onboarding.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleV3Request } from "../src/v3.ts";
import { QueryCache } from "../src/chargeback.ts";
import { createMemoryChangeLog } from "../src/change-log.ts";
import { createMemoryRegistryStore } from "../src/backend-routing.ts";
import { createMemoryDescriptorStore } from "../src/backend-onboarding.ts";
import type { FoundryAccount, OnboardingProvider } from "../src/backend-onboarding.ts";
import type { Doc } from "../src/validation.ts";
import { checkBackendRecord } from "../../src/resolver/backend.ts";

const NOW = new Date("2026-11-08T10:00:00.000Z");
const SUB = "00000000-0000-4000-8000-0000000000a1";
const ACCOUNT = `/subscriptions/${SUB}/resourceGroups/foundry2-rg/providers/Microsoft.CognitiveServices/accounts/foundry2`;
const APIM_A = "/subscriptions/00000000-0000-4000-8000-0000000000a2/resourceGroups/stg/providers/Microsoft.ApiManagement/service/apim-a";
const APIM_B = "/subscriptions/00000000-0000-4000-8000-0000000000a2/resourceGroups/stg/providers/Microsoft.ApiManagement/service/apim-b";
const PRINCIPAL: Record<string, string> = { [APIM_A]: "00000000-0000-4000-8000-0000000000f1", [APIM_B]: "00000000-0000-4000-8000-0000000000f2" };
const COGNITIVE_SERVICES_USER = "/subscriptions/x/providers/Microsoft.Authorization/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908";
const READER = "/subscriptions/x/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7";
const URL_2 = "https://foundry2.services.ai.azure.com/anthropic";

function fakeProvider(over: Partial<{ account: FoundryAccount | null; deployments: { name: string; provisioningState: string }[] }> = {}) {
  const calls: string[] = [];
  const apim = new Map<string, string>();
  const roles = new Map<string, { roleDefinitionId: string; scope: string }[]>([
    [PRINCIPAL[APIM_A], [{ roleDefinitionId: COGNITIVE_SERVICES_USER, scope: ACCOUNT }]],
    [PRINCIPAL[APIM_B], [{ roleDefinitionId: COGNITIVE_SERVICES_USER, scope: `/subscriptions/${SUB}/resourceGroups/foundry2-rg` }]],
  ]);
  const account: FoundryAccount | null = "account" in over ? over.account ?? null
    : { id: ACCOUNT, customSubDomainName: "foundry2", publicNetworkAccess: "Disabled", privateEndpointStatuses: ["Approved"] };
  let failPut: string | null = null;
  const provider: OnboardingProvider = {
    async account(id) { calls.push(`account ${id}`); return account; },
    async deployments(id) { calls.push(`deployments ${id}`); return over.deployments ?? [{ name: "claude-haiku-4-5", provisioningState: "Succeeded" }, { name: "claude-sonnet-4-5", provisioningState: "Succeeded" }, { name: "old", provisioningState: "Failed" }]; },
    async apimPrincipal(apimId) { calls.push(`principal ${apimId}`); return PRINCIPAL[apimId] ?? null; },
    async roleAssignments(_accountId, principalId) { calls.push(`roles ${principalId}`); return roles.get(principalId) ?? []; },
    async apimBackendUrl(apimId, backendId) { calls.push(`get-backend ${apimId}`); return apim.get(`${apimId}|${backendId}`) ?? null; },
    async putApimBackend(apimId, backendId, url) {
      calls.push(`put-backend ${apimId}`);
      if (failPut === apimId) throw new Error("arm down");
      apim.set(`${apimId}|${backendId}`, url);
    },
  };
  return { provider, calls, apim, roles, failNextPut: (id: string | null) => { failPut = id; } };
}

function setup(opts: { enabled?: boolean; provider?: ReturnType<typeof fakeProvider>; scopes?: string[]; ids?: string[] } = {}) {
  const fake = opts.provider ?? fakeProvider();
  const changeLog = createMemoryChangeLog();
  const registry = createMemoryRegistryStore();
  const descriptors = createMemoryDescriptorStore();
  const logs: Doc[] = [];
  let id = 0;
  const onboarding = opts.enabled === false ? null : {
    provider: fake.provider, descriptors, targets: [APIM_A, APIM_B],
    resourceIds: opts.ids ?? [], discoveryScopes: opts.scopes ?? [`/subscriptions/${SUB}`],
  };
  const headers = (h: Record<string, string>) => (n: string) => h[n.toLowerCase()] ?? (n.toLowerCase() === "authorization" ? "editor" : null);
  const v3 = (method: string, path: string, body?: unknown, h: Record<string, string> = {}) => handleV3Request({
    method, path: `/api/v3/${path}`, headers: headers(h), body: body === undefined ? null : JSON.stringify(body),
  }, {
    authenticate: async (a: string | null) => ({ oid: "00000000-0000-4000-8000-0000000000e1", canWrite: a !== "reader" }),
    now: () => NOW, newId: () => `req-${++id}`, log: (line: string) => { logs.push(JSON.parse(line) as Doc); },
    projects: null, catalogStore: null, changeLog, registry, defaultCatalog: null, env: {}, sources: null, cache: new QueryCache(),
    operations: {} as never, onboarding,
  } as never);
  return { v3, fake, changeLog, registry, descriptors, logs };
}
const json = (r: { jsonBody?: unknown }) => r.jsonBody as Doc;
const body = (over: Doc = {}) => ({ backendId: "foundry2", foundryResourceId: ACCOUNT, ...over });
const check = (r: { jsonBody?: unknown }, id: string) => ((json(r).checks ?? (json(r).preflight as Doc).checks) as Doc[]).find((c) => c.id === id);

test("the feature is off unless configured, and it needs an editor", async () => {
  assert.equal((await setup({ enabled: false }).v3("POST", "backend-onboarding/preflight", body())).status, 404);
  assert.equal(json(await setup({ enabled: false }).v3("GET", "backend-onboarding")).error, "route_not_found");
  const { v3, fake } = setup();
  const r = await v3("POST", "backend-onboarding", body(), { authorization: "reader" });
  assert.equal(r.status, 403);
  assert.equal(json(r).error, "write_permission_required");
  assert.equal((await v3("POST", "backend-onboarding/preflight", body(), { authorization: "reader" })).status, 403);
  assert.equal(fake.calls.length, 0);
  const info = await v3("GET", "backend-onboarding");
  assert.equal(info.status, 200);
  assert.deepEqual(json(info).targets, [APIM_A, APIM_B]);
});

test("an account outside the console's scope is refused before any Azure read", async () => {
  const { v3, fake, logs } = setup({ scopes: ["/subscriptions/00000000-0000-4000-8000-0000000000ff"] });
  const r = await v3("POST", "backend-onboarding/preflight", body());
  assert.equal(r.status, 403);
  assert.equal(json(r).error, "resource_out_of_scope");
  assert.equal(fake.calls.length, 0);
  assert.ok(logs.some((l) => l.schema === "ccof.admin.audit.v1" && l.outcome === "refused"));
  // A scope prefix must end at a path boundary; an exact resource ID is allowed.
  const near = setup({ scopes: [`/subscriptions/${SUB}/resourceGroups/foundry`] });
  assert.equal((await near.v3("POST", "backend-onboarding/preflight", body())).status, 403);
  const exact = setup({ scopes: [], ids: [ACCOUNT.toUpperCase()] });
  assert.equal((await exact.v3("POST", "backend-onboarding/preflight", body())).status, 200);
});

test("the body is validated: required fields, no unknown keys, a valid backend ID and account ID", async () => {
  const { v3, fake } = setup();
  for (const [b, problem] of [
    [{ foundryResourceId: ACCOUNT }, "backendId:invalid"],
    [body({ backendId: "ccof-reserved" }), "backendId:invalid"],
    [body({ foundryResourceId: "/subscriptions/x/resourceGroups/r/providers/Microsoft.Storage/storageAccounts/s" }), "foundryResourceId:invalid"],
    [body({ extra: 1 }), "body:unexpected_key"],
    [body({ inferenceGeo: "mars" }), "inferenceGeo:invalid"],
  ] as [Doc, string][]) {
    const r = await v3("POST", "backend-onboarding/preflight", b);
    assert.equal(r.status, 422, JSON.stringify(b));
    assert.ok((json(r).problems as string[]).includes(problem), `${problem} in ${JSON.stringify(json(r).problems)}`);
  }
  assert.equal(fake.calls.length, 0);
});

test("preflight reports every check; defaults take the succeeded deployments and the account endpoint", async () => {
  const { v3 } = setup();
  const r = await v3("POST", "backend-onboarding/preflight", body());
  assert.equal(r.status, 200);
  assert.equal(json(r).ok, true);
  assert.equal(json(r).endpoint, URL_2);
  assert.deepEqual((json(r).plan as Doc).deployments, ["claude-haiku-4-5", "claude-sonnet-4-5"]);
  assert.equal((json(r).plan as Doc).displayName, "foundry2");
  for (const id of ["account_found", "deployments", "network", `roles:${APIM_A}`, `roles:${APIM_B}`, "id_free"]) assert.equal(check(r, id)?.status, "pass", id);
});

test("preflight fails on a missing deployment, a pending private endpoint and a missing role, and onboarding then writes nothing", async () => {
  const fake = fakeProvider({ account: { id: ACCOUNT, customSubDomainName: "foundry2", publicNetworkAccess: "Disabled", privateEndpointStatuses: ["Pending"] } });
  fake.roles.set(PRINCIPAL[APIM_B], [{ roleDefinitionId: READER, scope: ACCOUNT }]);
  const { v3, registry, descriptors, changeLog } = setup({ provider: fake });
  const r = await v3("POST", "backend-onboarding/preflight", body({ deployments: ["claude-haiku-4-5", "claude-opus-4-1"] }));
  assert.equal(json(r).ok, false);
  assert.equal(check(r, "deployments")?.status, "fail");
  assert.match(String(check(r, "deployments")?.detail), /claude-opus-4-1/);
  assert.equal(check(r, "network")?.status, "fail");
  assert.match(String(check(r, "network")?.detail), /Pending/);
  assert.equal(check(r, `roles:${APIM_A}`)?.status, "pass");
  assert.equal(check(r, `roles:${APIM_B}`)?.status, "fail");
  const o = await v3("POST", "backend-onboarding", body({ deployments: ["claude-haiku-4-5", "claude-opus-4-1"] }));
  assert.equal(o.status, 422);
  assert.equal(json(o).error, "preflight_failed");
  assert.equal(fake.calls.filter((c) => c.startsWith("put-")).length, 0);
  assert.equal(registry.entries.size, 0);
  assert.equal(descriptors.docs.size, 0);
  assert.equal(changeLog.records.size, 0);
});

test("a public account with no approved private endpoint is a warning, a missing account a failure", async () => {
  const pub = setup({ provider: fakeProvider({ account: { id: ACCOUNT, customSubDomainName: "foundry2", publicNetworkAccess: "Enabled", privateEndpointStatuses: [] } }) });
  const r = await pub.v3("POST", "backend-onboarding/preflight", body());
  assert.equal(check(r, "network")?.status, "warn");
  assert.equal(json(r).ok, true);
  const gone = setup({ provider: fakeProvider({ account: null }) });
  const g = await gone.v3("POST", "backend-onboarding/preflight", body());
  assert.equal(json(g).ok, false);
  assert.equal(check(g, "account_found")?.status, "fail");
});

test("onboarding writes both APIM backends, the descriptor and the registry entry, and records the change", async () => {
  const { v3, fake, registry, descriptors, changeLog, logs } = setup();
  const r = await v3("POST", "backend-onboarding", body({ deployments: ["claude-haiku-4-5"], displayName: "Foundry 2" }));
  assert.equal(r.status, 201, JSON.stringify(json(r)));
  assert.deepEqual(json(r).steps, [
    { step: `apim:${APIM_A}`, result: "created" }, { step: `apim:${APIM_B}`, result: "created" },
    { step: "descriptor", result: "created" }, { step: "registry", result: "created" },
  ]);
  assert.equal(fake.apim.get(`${APIM_A}|foundry2`), URL_2);
  assert.equal(fake.apim.get(`${APIM_B}|foundry2`), URL_2);
  const descriptor = descriptors.docs.get("foundry2")!;
  assert.equal(checkBackendRecord(descriptor, "foundry2").kind, "active");
  assert.deepEqual(registry.entries.get("foundry2")!.doc, {
    backendId: "foundry2", displayName: "Foundry 2", url: URL_2, deployments: ["claude-haiku-4-5"], inferenceGeo: "global", status: "active", circuitBreaker: null,
  });
  const records = [...changeLog.records.values()];
  assert.equal(records.length, 1);
  assert.equal(records[0].operation, "v3/backend-onboarding");
  assert.equal(records[0].outcome, "created");
  assert.ok(logs.some((l) => l.schema === "ccof.admin.audit.v1" && l.operation === "v3/backend-onboarding" && l.outcome === "created"));
  // Rerun with the same values: every step already exists, nothing is written again.
  const again = await v3("POST", "backend-onboarding", body({ deployments: ["claude-haiku-4-5"], displayName: "Foundry 2" }));
  assert.equal(again.status, 200);
  assert.ok((json(again).steps as Doc[]).every((s) => s.result === "exists"));
  assert.equal(fake.calls.filter((c) => c.startsWith("put-")).length, 2);
});

test("an ID already used for a different endpoint is a conflict, and nothing is written", async () => {
  const fake = fakeProvider();
  const { v3, registry } = setup({ provider: fake });
  await fake.provider.putApimBackend(APIM_B, "foundry2", "https://other.services.ai.azure.com/anthropic");
  fake.calls.length = 0;
  const p = await v3("POST", "backend-onboarding/preflight", body());
  assert.equal(check(p, "id_free")?.status, "fail");
  assert.match(String(check(p, "id_free")?.detail), /apim-b/);
  const r = await v3("POST", "backend-onboarding", body());
  assert.equal(r.status, 409);
  assert.equal(json(r).error, "backend_id_conflict");
  assert.equal(fake.calls.filter((c) => c.startsWith("put-")).length, 0);
  assert.equal(registry.entries.size, 0);
});

test("a failure part-way is reported as incomplete, and a rerun finishes the remaining steps", async () => {
  const fake = fakeProvider();
  const { v3, registry, changeLog } = setup({ provider: fake });
  fake.failNextPut(APIM_B);
  const r = await v3("POST", "backend-onboarding", body());
  assert.equal(r.status, 502);
  assert.equal(json(r).error, "onboarding_incomplete");
  assert.deepEqual(json(r).steps, [{ step: `apim:${APIM_A}`, result: "created" }]);
  assert.equal(registry.entries.size, 0);
  assert.equal([...changeLog.records.values()][0].outcome, "unconfirmed");
  fake.failNextPut(null);
  const again = await v3("POST", "backend-onboarding", body());
  assert.equal(again.status, 201);
  assert.deepEqual((json(again).steps as Doc[]).map((s) => s.result), ["exists", "created", "created", "created"]);
  assert.deepEqual(fake.calls.filter((c) => c.startsWith("put-")), [`put-backend ${APIM_A}`, `put-backend ${APIM_B}`, `put-backend ${APIM_B}`]);
  assert.ok(registry.entries.has("foundry2"));
});

test("a descriptor with another token audience is a conflict, not 'exists'", async () => {
  const { v3, descriptors, registry } = setup();
  await descriptors.create({ id: "foundry2", backendId: "foundry2", status: "active", apiFormat: "anthropic-messages",
    auth: { mode: "managed-identity", resource: "https://management.azure.com" } });
  const pre = await v3("POST", "backend-onboarding/preflight", body());
  assert.equal(check(pre, "id_free")?.status, "fail");
  const r = await v3("POST", "backend-onboarding", body());
  assert.equal(r.status, 409);
  assert.equal(json(r).error, "backend_id_conflict");
  assert.equal(await registry.read("foundry2"), null);
});

test("an APIM backend claimed for another URL after preflight stops the write", async () => {
  const fake = fakeProvider();
  const real = fake.provider.apimBackendUrl;
  let reads = 0;
  fake.provider.apimBackendUrl = async (apimId, id) => (++reads > 2 && apimId === APIM_B ? "https://other.services.ai.azure.com/anthropic" : real(apimId, id));
  const { v3, registry, descriptors } = setup({ provider: fake });
  const r = await v3("POST", "backend-onboarding", body());
  assert.equal(r.status, 409);
  assert.equal(json(r).error, "backend_id_conflict");
  assert.equal(await registry.read("foundry2"), null);
  assert.equal(await descriptors.read("foundry2"), null);
});

test("a registry entry claimed for another URL after preflight stops the write", async () => {
  const fake = fakeProvider();
  const { v3, registry } = setup({ provider: fake });
  const real = fake.provider.apimBackendUrl;
  let reads = 0;
  fake.provider.apimBackendUrl = async (apimId, id) => {
    if (++reads === 2) await registry.save({ ...((await v3("POST", "backend-onboarding/preflight", body())).jsonBody as Doc).plan as never, url: "https://other.services.ai.azure.com/anthropic" } as never, null);
    return real(apimId, id);
  };
  const r = await v3("POST", "backend-onboarding", body());
  assert.equal(r.status, 409);
  assert.equal(fake.apim.size, 0);
});

test("an APIM backend that does not read back with the URL is reported incomplete", async () => {
  const fake = fakeProvider();
  fake.provider.putApimBackend = async () => {};
  const { v3, registry } = setup({ provider: fake });
  const r = await v3("POST", "backend-onboarding", body());
  assert.equal(r.status, 502);
  assert.equal(json(r).error, "onboarding_incomplete");
  assert.equal(await registry.read("foundry2"), null);
});

test("a rerun with nothing to change is still audited", async () => {
  const { v3, logs } = setup();
  assert.equal((await v3("POST", "backend-onboarding", body())).status, 201);
  const before = logs.filter((l) => l.operation === "v3/backend-onboarding").length;
  const again = await v3("POST", "backend-onboarding", body());
  assert.equal(again.status, 200);
  const audits = logs.filter((l) => l.operation === "v3/backend-onboarding");
  assert.equal(audits.length, before + 1);
  assert.equal(audits.at(-1)?.outcome, "unchanged");
});
