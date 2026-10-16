import { test } from "node:test";
import assert from "node:assert/strict";
import { createOperations } from "../src/operations.ts";
import type { Doc } from "../src/validation.ts";

const sub = "00000000-0000-4000-8000-000000000001";
const account = `/subscriptions/${sub}/resourceGroups/workload/providers/Microsoft.CognitiveServices/accounts/foundry`;
const apim = `/subscriptions/${sub}/resourceGroups/workload/providers/Microsoft.ApiManagement/service/gateway`;
const credential = { getToken: async () => ({ token: "never-return-this-token", expiresOnTimestamp: Date.now() + 60000 }) };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
test("unconfigured integrations never request tokens or network and stay individually disabled", async () => {
  const ops = createOperations({}, { getToken: async () => { throw new Error("unexpected token"); } }, () => {}, async () => { throw new Error("unexpected network"); });
  for (const cap of await Promise.all([ops.groups("team"), ops.inventory(), ops.health(), ops.retail(), ops.logs("budgets")])) assert.equal(cap.state, "disabled");
});
test("Graph query is bounded and OData-escaped; denial is capability-specific with no leaked provider body", async () => {
  const log: string[] = [];
  const calls: string[] = [];
  const ops = createOperations({ ADMIN_GRAPH_ENABLED: "true" }, credential, (line) => log.push(line), async (input) => {
    const url = new URL(String(input)); calls.push(url.href);
    assert.equal(url.searchParams.get("$top"), "25");
    assert.equal(url.searchParams.get("$filter"), "startswith(displayName,'O''Brien')");
    return json({ error: { message: "SECRET" } }, 403);
  });
  const cap = await ops.groups("O'Brien");
  assert.equal(cap.state, "permission_required");
  assert.equal((await ops.health()).state, "disabled");
  assert.equal(calls.length, 1);
  assert(!JSON.stringify(cap).includes("SECRET"));
  assert(!log.join("").includes("never-return-this-token"));
});
test("deployment lookup rejects arbitrary resource IDs before making a request", async () => {
  let called = false;
  const ops = createOperations({ ADMIN_RESOURCE_IDS: account }, credential, () => {}, async () => { called = true; return json({}); });
  const cap = await ops.deployments(account.replace("workload", "outside"));
  assert.equal(cap.state, "permission_required");
  assert.equal(called, false);
});
test("inventory matches APIM backend host to shared Foundry and strips backend credentials", async () => {
  const ops = createOperations({ ADMIN_RESOURCE_IDS: `${account},${apim}` }, credential, () => {}, async (input) => {
    const url = String(input);
    if (url.includes("/backends?")) return json({ value: [{ name: "shared-foundry", properties: { url: "https://foundry.services.ai.azure.com/anthropic?key=SECRET", credentials: "SECRET" } }] });
    if (url.includes("CognitiveServices")) return json({ id: account, name: "foundry", type: "Microsoft.CognitiveServices/accounts", properties: { customSubDomainName: "foundry", provisioningState: "Succeeded" } });
    return json({ id: apim, name: "gateway", type: "Microsoft.ApiManagement/service" });
  });
  const cap = await ops.inventory();
  assert.equal(cap.state, "available");
  assert(!JSON.stringify(cap).includes("SECRET"));
  const resources = (cap.data as { resources: Doc[] }).resources;
  assert.deepEqual(resources[0].backendIds, ["shared-foundry"]);
});
test("resource 404 means not_found, never automatic deleted or retired", async () => {
  const ops = createOperations({ ADMIN_RESOURCE_IDS: account }, credential, () => {}, async () => json({}, 404));
  const cap = await ops.inventory();
  assert.equal(((cap.data as { resources: Doc[] }).resources[0]).lifecycle, "not_found");
});
test("cross-origin ARM pagination is rejected", async () => {
  const ops = createOperations({ ADMIN_DISCOVERY_SCOPES: `/subscriptions/${sub}` }, credential, () => {}, async () =>
    json({ value: [], nextLink: "https://attacker.invalid/collect" }));
  assert.equal((await ops.inventory()).state, "unavailable");
});
test("budget query uses existing reconciler schema, current UTC month and exact configured source IDs", async () => {
  let requestBody = "";
  const ops = createOperations({ ADMIN_WORKSPACE_ID: sub, ADMIN_LOG_RESOURCE_IDS: apim }, credential, () => {}, async (_url, init) => {
    requestBody = String(init?.body);
    return json({ tables: [{ rows: [[JSON.stringify({ spentCcu: "123.45", completeness: "partial" })]] }] });
  });
  const cap = await ops.logs("budgets");
  assert.equal(cap.state, "available");
  assert(requestBody.includes("ccof.reconciler.budget.v1"));
  assert(requestBody.includes("yyyy-MM"));
  assert(requestBody.includes(apim));
  assert.equal((cap.data as Doc[])[0].completeness, "partial");
});
test("health probes use only allowlisted hosts and keys in headers, never response bodies", async () => {
  let header = "";
  const ops = createOperations({
    ADMIN_HEALTH_TARGETS: JSON.stringify([{ name: "admin", url: "https://admin.azurewebsites.net/api/health", keySetting: "ADMIN_PROBE_KEY_ADMIN" }]),
    ADMIN_PROBE_KEY_ADMIN: "key-secret",
  }, credential, () => {}, async (_url, init) => {
    header = (init?.headers as Record<string, string>)["x-functions-key"];
    return json({ status: "ready", dangerous: "body-secret" });
  });
  const cap = await ops.health();
  assert.equal(header, "key-secret");
  assert(!JSON.stringify(cap).includes("secret"));
  assert.equal((cap.data as Doc[])[0].state, "endpoint_responding");
  const bad = createOperations({ ADMIN_HEALTH_TARGETS: JSON.stringify([{ url: "https://arbitrary.invalid/" }]) }, credential, () => {}, async () => { throw new Error("must not call"); });
  assert.equal((await bad.health()).state, "unavailable");
});
test("retail discovery keeps meter units, currency, dates and incompleteness explicit", async () => {
  const ops = createOperations({ ADMIN_RETAIL_PRICES_ENABLED: "true" }, credential, () => {}, async () => json({
    Items: [{ productName: "Claude", unitOfMeasure: "100 CCU", retailPrice: 1, currencyCode: "USD", effectiveStartDate: "2026-10-16" }],
    NextPageLink: "https://prices.azure.com/api/retail/prices?skip=1000",
  }));
  const cap = await ops.retail();
  assert.equal((cap.data as Doc).truncated, true);
  assert.equal(((cap.data as { prices: Doc[] }).prices[0]).unit, "100 CCU");
});
test("billed cost is resource-level ActualCost in returned currency, not invented group allocation", async () => {
  let body: Doc = {};
  const ops = createOperations({ ADMIN_RESOURCE_IDS: account, ADMIN_COST_SCOPE: `/subscriptions/${sub}` }, credential, () => {}, async (url, init) => {
    if (String(url).includes("CostManagement/query")) {
      body = JSON.parse(String(init?.body));
      return json({ properties: { columns: [{ name: "ResourceId" }, { name: "PreTaxCost" }, { name: "Currency" }], rows: [[account, 12.50, "USD"]] } });
    }
    return json({ id: account, type: "Microsoft.CognitiveServices/accounts" });
  });
  const cap = await ops.billed();
  assert.equal(cap.state, "available");
  assert.equal(body.type, "ActualCost");
  assert.equal(body.timeframe, "MonthToDate");
  assert.deepEqual((cap.data as { costs: Doc[] }).costs, [{ ResourceId: account, PreTaxCost: 12.5, Currency: "USD" }]);
});
test("health HTTP refusal is not marked healthy and an integration denial does not disable core inventory", async () => {
  const ops = createOperations({
    ADMIN_RESOURCE_IDS: account,
    ADMIN_HEALTH_TARGETS: JSON.stringify([{ name: "resolver", url: "https://resolver.azurewebsites.net/api/health" }]),
  }, credential, () => {}, async (url) => String(url).includes("azurewebsites.net") ? json({}, 503) : json({ id: account, type: "Microsoft.CognitiveServices/accounts" }));
  const health = await ops.health();
  assert.equal((health.data as Doc[])[0].state, "endpoint_refused");
  assert.equal((await ops.inventory()).state, "available");
});
test("health probes are bounded parallel work instead of a sequential timeout chain", async () => {
  let active = 0; let peak = 0;
  const targets = Array.from({ length: 14 }, (_, i) => ({ name: `app${i}`, url: `https://app${i}.azurewebsites.net/api/health` }));
  const ops = createOperations({ ADMIN_HEALTH_TARGETS: JSON.stringify(targets) }, credential, () => {}, async () => {
    active++; peak = Math.max(peak, active);
    await new Promise((resolve) => setTimeout(resolve, 5));
    active--;
    return json({ status: "ready" });
  });
  const cap = await ops.health();
  assert.equal((cap.data as unknown[]).length, 14);
  assert(peak > 1 && peak <= 6);
});
