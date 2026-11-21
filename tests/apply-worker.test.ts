import { test } from "node:test";
import assert from "node:assert/strict";
import { createCosmosApplyStore } from "../src/operations/apply-store.ts";
import { createApplyWorker } from "../src/operations/apply-worker.ts";
import { configurationId, requestId } from "../src/operations/apply-contracts.ts";
import type { ApplyRequest, WorkerPair } from "../src/operations/apply-contracts.ts";
import { createCosmosApplyExecutor } from "../admin/src/self-service-apply-cosmos.ts";
import { runSync } from "../src/sync/run.ts";
import { readGroupMembers } from "../src/sync/graph.ts";
import { MemoryLeases, MemoryEntitlements, response, page } from "./helpers/sync-fakes.ts";
import { runReconciler } from "../src/reconciler/run.ts";
import { readReconcilerSettings } from "../src/reconciler/settings.ts";
import { FakeAzure, LEDGER_KQL, ledgerBody } from "./helpers/reconciler-fakes.ts";
import { packagedRateCard, packagedSchedule, pilotProject, validSettings } from "./helpers/reconciler-fixtures.ts";
import { guardSyncDependencies, guardReconcilerDependencies } from "../src/operations/apply-guards.ts";
import { createMemoryJobStore, enqueueOperation, processOperations } from "../admin/src/self-service-jobs.ts";

const root = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Web/sites/";
const regionPairs: WorkerPair[] = [
  { region: "A", syncResourceId: `${root}a-sync`, reconcilerResourceId: `${root}a-rec` },
  { region: "B", syncResourceId: `${root}b-sync`, reconcilerResourceId: `${root}b-rec` },
];
const pairs = regionPairs;
const NOW = "2026-11-19T12:00:00.000Z";
const error = (code: number) => Object.assign(new Error("provider token and private contents"), { code });

function memoryContainer() {
  const docs = new Map<string, Record<string, any>>();
  let version = 0;
  const put = (value: any) => { const doc = structuredClone({ ...value, _etag: `"${++version}"` }); docs.set(value.id, doc); return { resource: doc, etag: doc._etag }; };
  return {
    docs,
    item(id: string) {
      return {
        async read() { if (!docs.has(id)) throw error(404); const doc = structuredClone(docs.get(id)!); return { resource: doc, etag: doc._etag }; },
        async replace(value: any, options: any) {
          if (!docs.has(id) || docs.get(id)!._etag !== options.accessCondition.condition) throw error(412);
          return put(value);
        },
      };
    },
    items: {
      async create(value: any) { if (docs.has(value.id)) throw error(409); return put(value); },
      query(spec: any) {
        return { async fetchAll() {
          const parameter = (name: string) => spec.parameters.find((p: any) => p.name === name)?.value;
          return { resources: [...docs.values()].filter((d) => d.recordKind === "applyRequest" && d.resourceId === parameter("@target") && d.expiresAt > parameter("@now")).map((d) => structuredClone(d)) };
        } };
      },
    },
  };
}

function harness(pairs: WorkerPair[] = regionPairs) {
  let clock = new Date(NOW), etag = '"1"', status = "active";
  const container = memoryContainer();
  const store = createCosmosApplyStore(container as any);
  const calls: string[] = [];
  const envs = pairs.flatMap((pair, index) => (["sync", "reconcile"] as const).map((phase) => ({
    CCOF_APPLY_WORKER_ENABLED: "true", CCOF_APPLY_WORKER_PAIRS: JSON.stringify(pairs),
    CCOF_APP_ROLE: phase === "sync" ? "sync" : "reconciler",
    CCOF_APPLY_WORKER_RESOURCE_ID: phase === "sync" ? pair.syncResourceId : pair.reconcilerResourceId,
    [phase === "sync" ? "AzureWebJobs.syncEntitlement.Disabled" : "AzureWebJobs.reconcileBudgets.Disabled"]: String(index > 0),
    SYNC_WRITE_MODE: "apply",
  })));
  let result: any = { outcome: "succeeded", source: "graph", writeMode: "apply", reasons: [], refusals: [] };
  let graphPermission: "granted" | "permission_required" | "unknown" = "granted";
  let runner: ((request: ApplyRequest, ensureCurrent: () => Promise<void>) => Promise<unknown>) | undefined;
  const workers = envs.map((env) => createApplyWorker({
    env, store, projects: { read: async () => ({ etag, status }) }, now: () => clock,
    graphPermission: async () => ({
      state: graphPermission,
      identityResourceId: env.CCOF_APPLY_WORKER_RESOURCE_ID.replace("Microsoft.Web/sites/", "Microsoft.ManagedIdentity/userAssignedIdentities/"),
    }),
    run: async (request, ensureCurrent) => {
      calls.push(request.phase);
      if (runner) return runner(request, ensureCurrent);
      return request.phase === "sync" ? result : {
        outcome: "written", reason: null, completeness: "complete", computedAt: clock.toISOString(),
        validUntil: new Date(clock.getTime() + 600_000).toISOString(),
      };
    },
  }));
  const executor = createCosmosApplyExecutor({
    env: { ADMIN_APPLY_ENABLED: "true", ADMIN_WORKER_RESOURCE_IDS: JSON.stringify(pairs) },
    container: container as any, projects: { read: async () => ({ etag }) }, now: () => clock,
  });
  const job: any = { id: "job1", kind: "apply", projectId: "P1", expectedEtag: '"1"', actorOid: "actor", createdAt: NOW, reason: "refresh", checkpoint: {} };
  const advance = async () => { const step = await executor.advance(job); if (step.checkpoint) job.checkpoint = step.checkpoint; return step; };
  const request = (phase: "sync" | "reconcile" = "sync"): ApplyRequest => ({
    jobId: job.id, projectId: job.projectId, expectedEtag: job.expectedEtag, pair: pairs[0], phase,
    resourceId: phase === "sync" ? pairs[0].syncResourceId : pairs[0].reconcilerResourceId,
    requestedAt: NOW, expiresAt: "2026-11-19T12:20:00.000Z",
  });
  return {
    container, store, workers, envs, executor, advance, job, request, calls,
    beat: async () => { for (const worker of workers) await worker.tick(); },
    setTime: (value: string) => { clock = new Date(value); },
    setProject: (value: string, state = "active") => { etag = value; status = state; },
    setResult: (value: any) => { result = value; },
    setRun: (value: NonNullable<typeof runner>) => { runner = value; },
    setGraphPermission: (value: typeof graphPermission) => { graphPermission = value; },
  };
}

test("Cosmos queue needs fresh heartbeats from both complete pairs; optional control defaults off", async () => {
  const h = harness();
  assert.notEqual((await h.executor.capability()).state, "available");
  await h.beat();
  assert.equal((await h.executor.capability()).state, "available");
  h.setTime("2026-11-19T12:01:00.000Z");
  assert.notEqual((await h.executor.capability()).state, "available");
  const disabled = createApplyWorker({ env: {}, store: null as any, projects: null as any, run: async () => assert.fail() });
  await disabled.tick();
  assert.deepEqual(h.calls, []);
});

test("a single-region deployment with one approved pair applies without a standby pair (ADR 0042)", async () => {
  const h = harness([regionPairs[0]]);
  assert.equal(h.workers.length, 2);
  assert.notEqual((await h.executor.capability()).state, "available");
  await h.beat();
  assert.equal((await h.executor.capability()).state, "available");
  assert.equal((await h.advance()).phase, "sync-ready");
  assert.equal((await h.advance()).phase, "sync-waiting");
  await h.workers[0].tick();
  assert.equal((await h.advance()).phase, "reconcile-ready");
  await h.advance(); await h.workers[1].tick();
  assert.equal((await h.advance()).state, "succeeded");
  assert.deepEqual(h.calls, ["sync", "reconcile"]);

  const fenced = harness([regionPairs[0]]);
  fenced.envs[0]["AzureWebJobs.syncEntitlement.Disabled"] = "true";
  fenced.envs[1]["AzureWebJobs.reconcileBudgets.Disabled"] = "true";
  await fenced.beat();
  assert.equal((await fenced.executor.capability()).reason, "worker_fence_unverified");
  assert.equal((await fenced.advance()).state, "blocked");
  assert.deepEqual(fenced.calls, []);
});

test("real worker results sequence correlated sync then reconcile; acceptance never completes", async () => {
  const h = harness(); await h.beat();
  assert.equal((await h.advance()).phase, "sync-ready");
  assert.equal((await h.advance()).phase, "sync-waiting");
  assert.equal((await h.advance()).state, "running");
  await h.workers[2].tick();
  assert.deepEqual(h.calls, []);
  await h.workers[0].tick();
  assert.equal((await h.advance()).phase, "reconcile-ready");
  assert.deepEqual(h.calls, ["sync"]);
  await h.advance(); await h.workers[1].tick();
  assert.equal((await h.advance()).state, "succeeded");
  assert.deepEqual(h.calls, ["sync", "reconcile"]);
  await h.beat();
  assert.deepEqual(h.calls, ["sync", "reconcile"]);
});

test("Graph 403 returns a sanitized prerequisite receipt and never dispatches reconciliation", async () => {
  const h = harness(); await h.beat();
  h.setResult({ outcome: "partial", source: "graph", writeMode: "apply", reasons: ["graph_permission_missing"], refusals: ["graph_permission_missing"], secret: "token" });
  await h.advance(); await h.advance(); await h.workers[0].tick();
  const step = await h.advance();
  assert.equal(step.state, "blocked");
  assert.equal(step.reason, "sync_graph_application_permission_required");
  assert.equal(step.requirements?.[0].action, "Microsoft Graph application GroupMember.Read.All");
  assert.deepEqual(h.calls, ["sync"]);
  assert.doesNotMatch(JSON.stringify([...h.container.docs.values()]), /token|provider token|actor/);
});

test("split brain, unknown fence, stale peer, mismatched pair and changed project never execute", async () => {
  for (const scenario of ["split", "unknown", "stale", "mismatch", "project", "retired"]) {
    const h = harness(); await h.beat();
    await h.store.enqueue(h.request());
    if (scenario === "split") {
      h.envs[2]["AzureWebJobs.syncEntitlement.Disabled"] = "false"; h.envs[3]["AzureWebJobs.reconcileBudgets.Disabled"] = "false";
      await h.workers[2].tick(); await h.workers[3].tick();
    }
    if (scenario === "unknown") delete h.envs[0]["AzureWebJobs.syncEntitlement.Disabled"];
    if (scenario === "stale") h.setTime("2026-11-19T12:01:00.000Z");
    if (scenario === "mismatch") { h.envs[1]["AzureWebJobs.reconcileBudgets.Disabled"] = "true"; await h.workers[1].tick(); }
    if (scenario === "project") h.setProject('"2"');
    if (scenario === "retired") h.setProject('"1"', "retired");
    await h.workers[0].tick();
    assert.deepEqual(h.calls, [], scenario);
  }
});

test("immutable request conflicts, expired execution claims and forged correlations do not replay", async () => {
  const h = harness(); await h.beat(); const req = h.request();
  assert.equal(await h.store.enqueue(req), "created");
  assert.equal(await h.store.enqueue(req), "existing");
  await assert.rejects(h.store.enqueue({ ...req, expectedEtag: '"changed"' }));
  const claim = await h.store.claim(req, "lost-worker", new Date(NOW));
  assert.equal(typeof claim, "object");
  h.setTime("2026-11-19T12:06:00.000Z"); await h.beat(); await h.workers[0].tick();
  assert.deepEqual(h.calls, []);
  assert.equal((await h.store.readReceipt(req))?.reason, "runtime_completion_unknown");
  assert.ok(requestId(req));
  assert.equal(configurationId(pairs), configurationId([...pairs].reverse()));
});

test("reconciliation cannot be forged before a correlated real sync success; void runner is failure", async () => {
  const h = harness(); await h.beat();
  const request = { ...h.request("reconcile"), syncFinishedAt: NOW };
  await h.store.enqueue(request);
  await h.workers[1].tick();
  assert.deepEqual(h.calls, []);
  assert.equal((await h.store.readReceipt(request))?.state, "blocked");
  const other = harness(); await other.beat(); other.setResult(undefined);
  await other.store.enqueue(other.request()); await other.workers[0].tick();
  assert.equal((await other.store.readReceipt(other.request()))?.state, "failed");
});

test("sync managed-identity grant evidence is feature-local, exact-scoped, and never an admin Graph demand", async () => {
  const h = harness(); h.setGraphPermission("permission_required"); await h.beat();
  const capability = await h.executor.capability();
  assert.equal(capability.state, "permission_required");
  assert.equal(capability.requirements[0].action, "Microsoft Graph application GroupMember.Read.All");
  assert.match(capability.requirements[0].scope, /Microsoft.ManagedIdentity\/userAssignedIdentities\/a-sync$/);
  assert.doesNotMatch(JSON.stringify(capability), /Application.Read.All|config\/list|admin.*Graph/);
  await h.store.enqueue(h.request()); await h.workers[0].tick();
  assert.equal((await h.store.readReceipt(h.request()))?.reason, "sync_graph_application_permission_required");
  assert.deepEqual(h.calls, []);
});

test("long runs refresh their heartbeat and lease without losing correlation", async (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const h = harness(); await h.beat(); await h.store.enqueue(h.request());
  let finish!: () => void;
  const deferred = new Promise<void>((resolve) => { finish = resolve; });
  h.setRun(async () => { await deferred; return { outcome: "succeeded", source: "graph", writeMode: "apply", reasons: [], refusals: [] }; });
  const pending = h.workers[0].tick();
  await new Promise(setImmediate);
  h.setTime("2026-11-19T12:04:00.000Z");
  for (const worker of h.workers.slice(1)) await worker.tick();
  t.mock.timers.tick(10_000);
  await new Promise(setImmediate);
  finish(); await pending;
  assert.equal((await h.store.readReceipt(h.request()))?.state, "succeeded");
});

test("a project edit during a real run is recorded as drift and never rewinds the project", async () => {
  const h = harness(); await h.beat(); await h.store.enqueue(h.request());
  h.setRun(async () => {
    h.setProject('"2"');
    return { outcome: "succeeded", source: "graph", writeMode: "apply", reasons: [], refusals: [] };
  });
  await h.workers[0].tick();
  assert.equal((await h.store.readReceipt(h.request()))?.reason, "configuration_drift");
  assert.deepEqual(h.calls, ["sync"]);
});

test("actual runSync and runReconciler summaries drive receipts; actual Graph 403 cannot reconcile", async () => {
  for (const denied of [false, true]) {
    const h = harness(); await h.beat();
    const project = pilotProject({ id: "P1", projectId: "P1", _etag: '"1"' });
    const entitlement = new MemoryEntitlements(), leases = new MemoryLeases();
    const card = packagedRateCard();
    const reconciler = new FakeAzure({ projects: [project], entitlements: [], ledger: ledgerBody([]) });
    const settings = readReconcilerSettings(validSettings());
    assert.equal(settings.ok, true);
    h.setRun(async (request, ensureCurrent) => request.phase === "sync" ? runSync({
      tenantId: "00000000-0000-4000-8000-000000000111", cosmosEndpoint: "https://sample.documents.azure.com",
      cosmosDatabase: "ccof", projectsContainer: "projects", entitlementContainer: "entitlement", leaseContainer: "syncLease",
      limitsContainer: null, leaseSeconds: 300, memberTypes: ["user"], maxRemovalsPerRun: 10, maxRemovalFraction: 0.5,
      graphMaxRetries: 0, graphMaxRetryAfterSeconds: 5, graphTimeoutSeconds: 10, writeMode: "apply",
    }, guardSyncDependencies({
      readProjects: async () => [project], readEntitlements: () => entitlement.readAll(), entitlements: entitlement, leases,
      readGroup: (groupId, beforeRequest) => readGroupMembers(groupId, {
        fetch: async () => response(denied ? { status: 403, body: { error: { code: "Authorization_RequestDenied", message: "provider private content" } } } : page([])),
        getToken: async () => "never-stored", sleep: async () => {}, maxRetries: 0, maxRetryAfterSeconds: 5, timeoutSeconds: 10,
        readServicePrincipals: false, beforeRequest,
      }),
    }, ensureCurrent, request), { trigger: "timer", now: () => new Date(NOW), newRunId: () => "real-sync", log: () => {} }) :
      runReconciler(settings.ok ? settings.settings : assert.fail(), { rateCard: card, schedule: packagedSchedule(card), ledgerKql: LEDGER_KQL },
        guardReconcilerDependencies(reconciler.deps(), ensureCurrent, request), { now: () => new Date(NOW), newRunId: () => "real-reconcile", log: () => {} }));
    await h.advance(); await h.advance(); await h.workers[0].tick();
    if (denied) {
      assert.equal((await h.advance()).reason, "sync_graph_application_permission_required");
      assert.deepEqual(h.calls, ["sync"]);
    } else {
      assert.equal((await h.advance()).phase, "reconcile-ready");
      await h.advance(); await h.workers[1].tick();
      assert.equal((await h.advance()).state, "succeeded");
      assert.ok(reconciler.aggregateStates.length > 0);
    }
    assert.doesNotMatch(JSON.stringify([...h.container.docs.values()]), /provider private content|never-stored|real-sync/);
  }
});

test("a Cosmos request-create denial is sanitized and reports only its exact data permission", async () => {
  const h = harness(); await h.beat(); await h.advance();
  h.container.items.create = async () => { throw error(403); };
  const step = await h.advance();
  assert.equal(step.reason, "apply_cosmos_permission_required");
  assert.match(step.requirements?.[0].action ?? "", /items\/create$/);
  assert.doesNotMatch(JSON.stringify(step), /provider token|private contents/);
});

test("concurrent polling cannot replay an immutable phase request", async () => {
  const h = harness(); await h.beat(); await h.store.enqueue(h.request());
  await Promise.all([h.workers[0].tick(), h.workers[0].tick()]);
  assert.deepEqual(h.calls, ["sync"]);
  assert.equal((await h.store.readReceipt(h.request()))?.state, "succeeded");
});

test("phase expiry never outlives the parent operation's overall deadline", async () => {
  const h = harness(); await h.beat();
  h.job.createdAt = "2026-11-19T11:35:00.000Z";
  await h.advance(); await h.advance();
  const request = await h.store.readRequest(h.job.id, "sync");
  assert.equal(request?.expiresAt, "2026-11-19T12:05:00.000Z");
  await h.workers[0].tick();
  assert.equal((await h.store.readReceipt(request!))?.state, "succeeded");
});

test("a lost Cosmos enqueue response retries the same immutable request without repeating business work", async () => {
  const h = harness(); await h.beat(); await h.advance();
  const create = h.container.items.create;
  let lost = false;
  h.container.items.create = async (value) => {
    const response = await create(value);
    if (value.recordKind === "applyRequest" && !lost) { lost = true; throw error(503); }
    return response;
  };
  const checkpoint = structuredClone(h.job.checkpoint);
  await assert.rejects(h.advance(), { message: "apply_dependency_unavailable" });
  assert.deepEqual(h.job.checkpoint, checkpoint);
  await h.workers[0].tick();
  await h.advance();
  assert.equal((await h.advance()).phase, "reconcile-ready");
  assert.deepEqual(h.calls, ["sync"]);
});

test("durable Apply recovers a transient receipt read outage without redispatching completed sync", async () => {
  const h = harness(); await h.beat();
  const jobs = createMemoryJobStore();
  let clock = new Date(NOW);
  const job = await enqueueOperation(jobs, {
    key: "qa-transient-receipt", kind: "apply", projectId: "P1", expectedEtag: '"1"',
    actorOid: "actor", reason: "Recover a transient receipt read",
  }, clock);
  Object.assign(h.job, job);
  const tick = () => processOperations(jobs, { apply: h.executor.advance }, { now: () => clock, owner: "qa", log() {} });
  await tick();
  clock = new Date("2026-11-19T12:00:15.000Z"); h.setTime(clock.toISOString());
  await h.beat(); await tick(); await h.workers[0].tick();
  assert.deepEqual(h.calls, ["sync"]);
  const item = h.container.item.bind(h.container);
  h.container.item = (id: string) => id.startsWith("apply-receipt-")
    ? { ...item(id), async read() { throw error(503); } }
    : item(id);
  clock = new Date("2026-11-19T12:00:30.000Z"); h.setTime(clock.toISOString());
  await tick();
  const outage = (await jobs.read(job.id))!.job;
  h.container.item = item;
  clock = new Date("2026-11-19T12:01:30.000Z"); h.setTime(clock.toISOString());
  await h.beat(); await tick();
  const recovered = (await jobs.read(job.id))!.job;
  assert.deepEqual(h.calls, ["sync"]);
  assert.deepEqual(
    { duringOutage: outage.state, afterRecovery: recovered.phase },
    { duringOutage: "running", afterRecovery: "reconcile-ready" },
  );
});

test("Cosmos heartbeat outages retry without dispatch while authorization failures remain blocked", async () => {
  for (const code of [429, 503, 401, 403]) {
    const h = harness(); await h.beat();
    const item = h.container.item.bind(h.container);
    h.container.item = (id: string) => id.startsWith("apply-worker-")
      ? { ...item(id), async read() { throw error(code); } }
      : item(id);
    if (code === 429 || code === 503) {
      assert.equal((await h.executor.capability()).state, "unavailable");
      await assert.rejects(h.advance(), { message: "apply_dependency_unavailable" });
    } else {
      assert.equal((await h.executor.capability()).state, "permission_required");
      const step = await h.advance();
      assert.equal(step.state, "blocked");
      assert.equal(step.reason, "apply_cosmos_permission_required");
    }
    assert.deepEqual(h.job.checkpoint, {});
    assert.deepEqual(h.calls, []);
    h.container.item = item;
    assert.equal((await h.advance()).phase, "sync-ready");
  }
});
