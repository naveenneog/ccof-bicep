// Live test (opt-in): the reconciler's real adapters against the live
// environment. Runs only with CCOF_LIVE_TESTS=1 and a git-ignored .env that
// holds COSMOS_ENDPOINT and COSMOS_DATABASE (tests/helpers/live-azure.ts)
// plus RECONCILER_LOG_ANALYTICS_WORKSPACE_ID, RECONCILER_LOG_ANALYTICS_ENDPOINT
// and RECONCILER_LEDGER_GATEWAY_RESOURCE_ID. The default suite skips it and
// makes no Azure call.
//
// The ledger test reaches the workspace's public query endpoint, so it runs
// from a workstation with an Azure CLI login that holds Log Analytics Reader.
// The registry test reaches Cosmos, whose public access is disabled by policy:
// it runs only from inside the VNet and fails with that explanation elsewhere.
// Both are read-only.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { REPO_DOTENV_PATH, decideLiveRun, explainLiveFailure, loadDotEnv, requireLiveConfig } from "./helpers/live-azure.ts";

const dotEnv = loadDotEnv(REPO_DOTENV_PATH);
const live = decideLiveRun(process.env, dotEnv);

function reconcilerEnv(): Record<string, string> {
  const needed = ["RECONCILER_LOG_ANALYTICS_WORKSPACE_ID", "RECONCILER_LOG_ANALYTICS_ENDPOINT", "RECONCILER_LEDGER_GATEWAY_RESOURCE_ID"];
  const missing = needed.filter((key) => !dotEnv?.[key]?.trim());
  if (missing.length > 0) throw new Error(`CCOF_LIVE_TESTS=1 but .env has no value for ${missing.join(" and ")}`);
  return Object.fromEntries(needed.map((key) => [key, (dotEnv as Record<string, string>)[key].trim()]));
}

test("live: the ledger read for the current UTC month succeeds and every row prices or is reported", { skip: live.kind === "skip" && live.reason }, async () => {
  requireLiveConfig(live);
  const env = reconcilerEnv();
  const { AzureCliCredential } = await import("@azure/identity");
  const { loadRunAssets } = await import("../src/reconciler/assets.ts");
  const { buildLedgerQuery, parseLedgerResponse } = await import("../src/reconciler/ledger.ts");
  const { createLedgerQuery, logAnalyticsScope } = await import("../src/reconciler/log-analytics.ts");
  const { budgetPeriodAt } = await import("../src/reconciler/period.ts");
  const { classifyRow } = await import("../src/reconciler/price-rows.ts");

  const loaded = await loadRunAssets((path) => readFile(new URL(`../${path}`, import.meta.url), "utf8"));
  assert.equal(loaded.ok, true);
  if (!loaded.ok) return;
  const credential = new AzureCliCredential();
  const period = budgetPeriodAt(new Date());
  const query = createLedgerQuery({
    endpoint: env.RECONCILER_LOG_ANALYTICS_ENDPOINT,
    workspaceId: env.RECONCILER_LOG_ANALYTICS_WORKSPACE_ID,
    timeoutSeconds: 60,
    getToken: async () => (await credential.getToken(logAnalyticsScope(env.RECONCILER_LOG_ANALYTICS_ENDPOINT))).token,
    fetch: (url, init) => fetch(url, init),
  });
  const { body } = await query(buildLedgerQuery(loaded.assets.ledgerKql, period, [env.RECONCILER_LEDGER_GATEWAY_RESOURCE_ID]), `${period.start.toISOString()}/${period.end.toISOString()}`);
  const rows = parseLedgerResponse(body, 500_000).map((row) => classifyRow(row, period, loaded.assets.rateCard, loaded.assets.schedule));
  const kinds = rows.reduce<Record<string, number>>((acc, row) => ({ ...acc, [row.outcome.kind]: (acc[row.outcome.kind] ?? 0) + 1 }), {});
  console.log(JSON.stringify({ liveLedgerRows: rows.length, kinds, attributed: rows.filter((r) => r.attribution !== null).length }));
});

test("live: the registry reads from Cosmos (inside the VNet only)", { skip: live.kind === "skip" && live.reason }, async () => {
  const { endpoint, databaseName } = requireLiveConfig(live);
  const { CosmosClient } = await import("@azure/cosmos");
  const { DefaultAzureCredential } = await import("@azure/identity");
  const { readRegistry } = await import("../src/reconciler/registry.ts");
  const database = new CosmosClient({ endpoint, aadCredentials: new DefaultAzureCredential() }).database(databaseName);
  try {
    const [projects, entitlements] = await Promise.all(
      ["projects", "entitlement"].map(async (name) => (await database.container(name).items.query("SELECT * FROM c").fetchAll()).resources),
    );
    const registry = readRegistry(projects, entitlements);
    console.log(JSON.stringify({ scopes: registry.scopes.size, members: registry.members.length, problems: registry.problems.map((p) => p.code) }));
  } catch (err) {
    throw explainLiveFailure(err);
  }
});

// AC15 (inside the VNet only): one run wrote a fresh state for every registered
// member and every registered group. Read-only.
test("live: every registered member and group has a fresh state from one run (AC15)", { skip: live.kind === "skip" && live.reason }, async () => {
  const { endpoint, databaseName } = requireLiveConfig(live);
  const { CosmosClient } = await import("@azure/cosmos");
  const { DefaultAzureCredential } = await import("@azure/identity");
  const { readRegistry } = await import("../src/reconciler/registry.ts");
  const database = new CosmosClient({ endpoint, aadCredentials: new DefaultAzureCredential() }).database(databaseName);
  try {
    const all = async (name: string) => (await database.container(name).items.query("SELECT * FROM c").fetchAll()).resources as Array<Record<string, unknown>>;
    const [projects, entitlements, persons, groups] = await Promise.all(["projects", "entitlement", "budgetState", "aggregateBudgetState"].map(all));
    const registry = readRegistry(projects, entitlements);
    assert.ok(registry.scopes.size > 0, "no registered group: run onboarding Stage 3 first");
    const byId = new Map([...persons, ...groups].map((doc) => [String(doc.id), doc]));
    const required = [...registry.members.map((m) => `${m.personId}:${m.projectId}`), ...registry.scopes.keys()];
    const missing = required.filter((id) => !byId.has(id));
    assert.deepEqual(missing, [], "every registered member and group has a document");
    const now = Date.now();
    const docs = required.map((id) => byId.get(id) as Record<string, unknown>);
    const stale = docs.filter((doc) => Date.parse(String(doc.validUntil)) <= now).map((doc) => doc.id);
    assert.deepEqual(stale, [], "every document is fresh");
    const runs = new Set(docs.map((doc) => doc.computedAt));
    assert.equal(runs.size, 1, `one run wrote them all: ${[...runs].join(", ")}`);
    console.log(JSON.stringify({ members: registry.members.length, groups: registry.scopes.size, computedAt: [...runs][0], exhausted: docs.filter((d) => d.exhausted === true).length }));
  } catch (err) {
    throw explainLiveFailure(err);
  }
});
