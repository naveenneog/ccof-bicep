import { test } from "node:test";
import assert from "node:assert/strict";
import { graphPermissionFromManagedIdentityToken } from "../src/operations/apply-graph.ts";
import { applyControlEnabled, createApplyControlHandler } from "../src/operations/apply-control.ts";
import { createApplyRuntime } from "../admin/src/self-service-apply-runtime.ts";
import { guardSyncDependencies, guardReconcilerDependencies } from "../src/operations/apply-guards.ts";

const now = new Date("2026-11-19T12:00:00.000Z");
const identity = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/a-sync-id";
const token = (claims: object) => ({
  token: `header.${Buffer.from(JSON.stringify({ aud: "https://graph.microsoft.com", exp: now.getTime() / 1000 + 300, ...claims })).toString("base64url")}.signature`,
  expiresOnTimestamp: now.getTime() + 300_000,
});

test("managed identity token inspection persists only the minimum GroupMember.Read.All proof", () => {
  assert.deepEqual(graphPermissionFromManagedIdentityToken(token({ roles: ["GroupMember.Read.All"] }), identity, now), { state: "granted", identityResourceId: identity });
  assert.equal(graphPermissionFromManagedIdentityToken(token({ roles: [] }), identity, now).state, "permission_required");
  assert.equal(graphPermissionFromManagedIdentityToken(token({}), identity, now).state, "permission_required");
  assert.equal(graphPermissionFromManagedIdentityToken(token({ roles: ["User.Read.All", "Application.Read.All"] }), identity, now).state, "permission_required");
  for (const value of [null, token({ aud: "different" }), token({ exp: 1 }), token({ roles: "GroupMember.Read.All" })])
    assert.equal(graphPermissionFromManagedIdentityToken(value, identity, now).state, "unknown");
  assert.equal(graphPermissionFromManagedIdentityToken(token({ roles: ["GroupMember.Read.All"] }), undefined, now).state, "unknown");
});

test("optional control is default-off, role-specific and contains malformed optional configuration failures", async () => {
  assert.equal(applyControlEnabled({}, "sync"), false);
  assert.equal(applyControlEnabled({ CCOF_APPLY_WORKER_ENABLED: "TRUE", CCOF_APP_ROLE: "sync" }, "sync"), false);
  assert.equal(applyControlEnabled({ CCOF_APPLY_WORKER_ENABLED: "true", CCOF_APP_ROLE: "sync" }, "reconcile"), false);
  const lines: string[] = [];
  let ticks = 0;
  for (const enabled of [false, true]) await createApplyControlHandler({
    env: { CCOF_APPLY_WORKER_ENABLED: String(enabled), CCOF_APP_ROLE: "sync" },
    phase: "sync", tick: async () => { ticks++; },
  })({} as any, { log: (line: string) => lines.push(line) } as any);
  assert.equal(ticks, 0, "disabled or invalid optional configuration cannot reach the Azure adapter");
  assert.equal(lines.length, 1);
  assert.deepEqual(JSON.parse(lines[0]), { schema: "ccof.apply.worker.v1", phase: "sync", state: "unavailable", reason: "apply_worker_unavailable" });
});

test("valid optional control passes validated configuration to its adapter and contains adapter failures", async () => {
  const env = {
    CCOF_APPLY_WORKER_ENABLED: "true", CCOF_APP_ROLE: "sync",
    COSMOS_ENDPOINT: "https://example.documents.azure.com:443/", COSMOS_DATABASE: "db",
    ADMIN_CONFIG_CONTAINER: "adminConfig", SYNC_PROJECTS_CONTAINER: "projects",
    SYNC_MANAGED_IDENTITY_CLIENT_ID: "00000000-0000-4000-8000-000000000001",
  };
  const lines: string[] = [];
  const context = { log: (line: string) => lines.push(line) } as any;
  let ticks = 0;
  const handler = createApplyControlHandler({
    env, phase: "sync",
    tick: async (configuration, actualContext) => {
      ticks++;
      assert.equal(actualContext, context);
      assert.deepEqual(configuration, {
        endpoint: env.COSMOS_ENDPOINT, database: "db", adminContainer: "adminConfig",
        projectsContainer: "projects", clientId: env.SYNC_MANAGED_IDENTITY_CLIENT_ID,
      });
      if (ticks === 1) throw new Error("sensitive provider failure");
    },
  });
  await handler({} as any, context);
  await handler({} as any, context);
  assert.equal(ticks, 2);
  assert.deepEqual(lines.map((line) => JSON.parse(line)), [
    { schema: "ccof.apply.worker.v1", phase: "sync", state: "unavailable", reason: "apply_worker_unavailable" },
  ]);
});

test("parent runtime factory has a persistent unavailable result when optional Cosmos is absent", async () => {
  const runtime = createApplyRuntime({ env: { ADMIN_APPLY_ENABLED: "true" }, container: null, projects: { read: async () => assert.fail() } });
  assert.equal((await runtime.capability()).reason, "apply_cosmos_unconfigured");
  assert.equal((await runtime.advance({} as any)).state, "blocked");
  assert.equal((await createApplyRuntime({ env: {}, container: null, projects: {} as any }).capability()).state, "disabled");
});

test("on-demand guards recheck authority before Graph requests and every entitlement/budget write", async () => {
  const calls: string[] = [];
  let valid = true;
  const guard = async () => { if (!valid) throw new Error("configuration_drift"); calls.push("guard"); };
  const sync = guardSyncDependencies({
    readProjects: async () => [],
    entitlements: { create: async () => { calls.push("entitlement"); }, replace: async () => { calls.push("entitlement"); } },
    readGroup: async (_id: string, before: () => Promise<void>) => { await before(); calls.push("graph"); },
  } as any, guard);
  await sync.readGroup("group", async () => { calls.push("business-lease"); });
  assert.deepEqual(calls, ["guard", "business-lease", "graph"]);
  valid = false;
  await assert.rejects(sync.entitlements.create({} as any), /configuration_drift/);
  await assert.rejects(sync.entitlements.replace({} as any, "etag"), /configuration_drift/);
  await assert.rejects(sync.readProjects(), /configuration_drift/);
  const reconciler = guardReconcilerDependencies({
    writeBudgetState: async () => { calls.push("budget"); }, writeAggregateState: async () => { calls.push("aggregate"); },
    readProjects: async () => [], readEntitlements: async () => [],
  } as any, guard);
  await assert.rejects(reconciler.writeBudgetState({} as any), /configuration_drift/);
  await assert.rejects(reconciler.writeAggregateState({} as any), /configuration_drift/);
  assert.deepEqual(calls, ["guard", "business-lease", "graph"]);
});
