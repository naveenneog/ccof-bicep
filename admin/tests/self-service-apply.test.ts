import { test } from "node:test";
import assert from "node:assert/strict";
import { ApplyPermissionError, createApplyExecutor } from "../src/self-service-apply.ts";
import type { ApplyProvider, ApplyReceipt, ApplyRequest, ApplyReceiptStore } from "../src/self-service-apply.ts";
import type { FeatureCapability, OperationJob } from "../src/self-service-contracts.ts";

const root = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Web/sites/";
const pairs = [
  { region: "A", syncResourceId: `${root}a-sync`, reconcilerResourceId: `${root}a-rec` },
  { region: "B", syncResourceId: `${root}b-sync`, reconcilerResourceId: `${root}b-rec` },
];
const NOW = "2026-11-19T12:00:00.000Z";
const job = (): OperationJob => ({
  id: "apply-1", kind: "apply", projectId: "P1", actorOid: "actor", expectedEtag: '"1"',
  createdAt: NOW, reason: "Refresh project", checkpoint: {},
});

function harness(overrides: Record<string, string | undefined> = {}) {
  let now = new Date(NOW);
  let etag = '"1"';
  const calls: string[] = [];
  const settings = new Map(pairs.flatMap((p, index) => [
    [p.syncResourceId, { CCOF_APP_ROLE: "sync", "AzureWebJobs.syncEntitlement.Disabled": String(index > 0), SYNC_WRITE_MODE: "apply" }],
    [p.reconcilerResourceId, { CCOF_APP_ROLE: "reconciler", "AzureWebJobs.reconcileBudgets.Disabled": String(index > 0) }],
  ]));
  let cap: FeatureCapability = { state: "available", requirements: [] };
  const requests = new Map<string, ApplyRequest>();
  const receipts = new Map<string, ApplyReceipt>();
  const store: ApplyReceiptStore = {
    async reserve(request) {
      const key = `${request.jobId}:${request.phase}`;
      if (requests.has(key)) return "existing";
      requests.set(key, structuredClone(request));
      return "created";
    },
    async read(request) { return receipts.get(`${request.jobId}:${request.phase}`) ?? null; },
  };
  const provider: ApplyProvider = {
    async capability() { return cap; },
    async settings(id) { calls.push(`settings:${id}`); return settings.get(id)!; },
    async invoke(id, name) { calls.push(`invoke:${id}:${name}`); return "accepted"; },
  };
  const executor = createApplyExecutor({
    env: { ADMIN_APPLY_ENABLED: "true", ADMIN_WORKER_RESOURCE_IDS: JSON.stringify(pairs), ...overrides },
    provider, receipts: store, projects: { read: async () => ({ etag }) }, now: () => now,
  });
  function finish(phase: "sync" | "reconcile", extra: Partial<ApplyReceipt> = {}) {
    const request = requests.get(`apply-1:${phase}`)!;
    receipts.set(`apply-1:${phase}`, {
      ...request, state: "succeeded", startedAt: NOW, finishedAt: NOW,
      outcome: phase === "sync" ? "succeeded" : "written",
      source: phase === "sync" ? "graph" : undefined, writeMode: phase === "sync" ? "apply" : undefined,
      guarded: false, validUntil: phase === "reconcile" ? "2026-11-19T12:15:00.000Z" : undefined,
      ...extra,
    });
  }
  async function advance(j: OperationJob) {
    const step = await executor.advance(j);
    if (step.checkpoint) j.checkpoint = step.checkpoint;
    return step;
  }
  return {
    executor, advance, calls, requests, receipts, settings, finish, provider, store,
    setCapability: (value: FeatureCapability) => { cap = value; },
    setNow: (value: string) => { now = new Date(value); }, setEtag: (value: string) => { etag = value; },
  };
}

test("Apply defaults off without provider or receipt access", async () => {
  const h = harness({ ADMIN_APPLY_ENABLED: undefined });
  assert.equal((await h.executor.capability()).state, "disabled");
  assert.equal((await h.advance(job())).state, "blocked");
  assert.deepEqual(h.calls, []);
  assert.equal(h.requests.size, 0);
});

test("the production default refuses unverified transport without Azure calls", async () => {
  const executor = createApplyExecutor({
    env: { ADMIN_APPLY_ENABLED: "true", ADMIN_WORKER_RESOURCE_IDS: JSON.stringify(pairs) },
    projects: { read: async () => assert.fail("transport refusal must precede project/data reads") },
  });
  assert.deepEqual(await executor.capability(), { state: "unavailable", reason: "apply_transport_unverified", requirements: [] });
  assert.equal((await executor.advance(job())).reason, "apply_transport_unverified");
});

test("verified missing worker Graph grants are exposed before unavailable transport", async () => {
  const requirements = [{
    action: "Microsoft Graph application GroupMember.Read.All (tenant-wide)",
    scope: `${root.replace("Microsoft.Web/sites/", "Microsoft.ManagedIdentity/userAssignedIdentities/")}a-sync-id`,
  }];
  const executor = createApplyExecutor({
    env: { ADMIN_APPLY_ENABLED: "true", ADMIN_WORKER_RESOURCE_IDS: JSON.stringify(pairs) },
    projects: { read: async () => assert.fail("a missing worker grant must never read project state or dispatch") },
    prerequisites: async (workers) => {
      assert.deepEqual(workers, pairs);
      return { state: "permission_required", reason: "sync_graph_application_permission_required", requirements };
    },
  });
  assert.deepEqual((await executor.capability()).requirements, requirements);
  const step = await executor.advance(job());
  assert.equal(step.state, "blocked");
  assert.equal(step.reason, "sync_graph_application_permission_required");
  assert.deepEqual(step.requirements, requirements);
});

test("a satisfied prerequisite does not turn unverified transport into an available feature", async () => {
  let probes = 0;
  const setup = {
    env: { ADMIN_APPLY_ENABLED: "true", ADMIN_WORKER_RESOURCE_IDS: JSON.stringify(pairs) },
    projects: { read: async () => assert.fail("transport is unavailable") },
    prerequisites: async () => { probes++; return { state: "available" as const, requirements: [] }; },
  };
  assert.equal((await createApplyExecutor(setup).capability()).reason, "apply_transport_unverified");
  assert.equal(probes, 1);
  assert.equal((await createApplyExecutor({ ...setup, env: {} }).capability()).state, "disabled");
  assert.equal(probes, 1);
});

test("permission denial is feature-local and names exact permission and scope", async () => {
  const h = harness();
  const requirements = [{ action: "Microsoft.Web/sites/config/list/action", scope: pairs[0].syncResourceId }];
  h.setCapability({ state: "permission_required", requirements });
  assert.deepEqual((await h.advance(job())).requirements, requirements);
  assert.deepEqual(h.calls, []);
});

test("invalid or duplicate configured worker targets fail closed", async () => {
  for (const value of ["[]", "not-json", JSON.stringify([pairs[0], pairs[0]]),
    JSON.stringify([{ ...pairs[0], syncResourceId: `${root}a-sync?url=evil` }])]) {
    const h = harness({ ADMIN_WORKER_RESOURCE_IDS: value });
    assert.equal((await h.executor.capability()).state, "unavailable");
    assert.equal((await h.advance(job())).state, "blocked");
    assert.deepEqual(h.calls, []);
  }
});

test("all configured regions are read before any dispatch; standby never runs", async () => {
  const h = harness();
  const j = job();
  assert.equal((await h.advance(j)).phase, "sync-ready");
  assert.equal((await h.advance(j)).phase, "sync-waiting");
  const invokes = h.calls.filter((c) => c.startsWith("invoke:"));
  assert.deepEqual(invokes, [`invoke:${pairs[0].syncResourceId}:syncEntitlement`]);
  assert.equal(new Set(h.calls.filter((c) => c.startsWith("settings:"))).size, 4);
});

test("no writer, unknown fence, mismatched pair and split brain are blocked before requests", async () => {
  const variants = [
    (h: ReturnType<typeof harness>) => { h.settings.get(pairs[0].syncResourceId)!["AzureWebJobs.syncEntitlement.Disabled"] = "true"; },
    (h: ReturnType<typeof harness>) => { h.settings.get(pairs[0].reconcilerResourceId)!["AzureWebJobs.reconcileBudgets.Disabled"] = "true"; },
    (h: ReturnType<typeof harness>) => { delete h.settings.get(pairs[1].syncResourceId)!["AzureWebJobs.syncEntitlement.Disabled"]; },
    (h: ReturnType<typeof harness>) => { for (const s of h.settings.values()) for (const k of Object.keys(s)) if (k.endsWith(".Disabled")) s[k] = "false"; },
    (h: ReturnType<typeof harness>) => { for (const s of h.settings.values()) for (const k of Object.keys(s)) if (k.endsWith(".Disabled")) s[k] = "true"; },
    (h: ReturnType<typeof harness>) => { h.settings.get(pairs[0].syncResourceId)!.SYNC_WRITE_MODE = "dry-run"; },
  ];
  for (const change of variants) {
    const h = harness(); change(h);
    assert.equal((await h.advance(job())).state, "blocked");
    assert.equal(h.requests.size, 0);
    assert.ok(!h.calls.some((c) => c.startsWith("invoke:")));
  }
});

test("HTTP acceptance alone stays running and times out honestly without reconciliation", async () => {
  const h = harness(), j = job();
  await h.advance(j); await h.advance(j);
  assert.equal((await h.advance(j)).state, "running");
  h.setNow("2026-11-19T12:21:00.000Z");
  const timedOut = await h.advance(j);
  assert.equal(timedOut.state, "failed");
  assert.equal(timedOut.reason, "runtime_completion_unknown");
  assert.equal(h.requests.size, 1);
});

test("only a correlated real Graph apply success allows sequential reconciliation", async () => {
  const h = harness(), j = job();
  await h.advance(j); await h.advance(j); h.finish("sync");
  assert.equal((await h.advance(j)).phase, "reconcile-ready");
  assert.equal(h.calls.filter((c) => c.startsWith("invoke:")).length, 1);
  assert.equal((await h.advance(j)).phase, "reconcile-waiting");
  h.finish("reconcile");
  const done = await h.advance(j);
  assert.equal(done.state, "succeeded");
  assert.equal(done.result?.syncFinishedAt, NOW);
  assert.equal(done.result?.reconciledAt, NOW);
  assert.deepEqual(h.calls.filter((c) => c.startsWith("invoke:")), [
    `invoke:${pairs[0].syncResourceId}:syncEntitlement`, `invoke:${pairs[0].reconcilerResourceId}:reconcileBudgets`,
  ]);
});

test("failed, guarded, snapshot, dry-run, uncorrelated or stale sync never reconciles", async () => {
  const variants: Partial<ApplyReceipt>[] = [
    { state: "failed" }, { guarded: true }, { source: "snapshot" }, { writeMode: "dry-run" },
    { jobId: "other" }, { startedAt: "2026-11-19T11:59:59.000Z" }, { outcome: "partial" },
    { resourceId: pairs[1].syncResourceId }, { finishedAt: "2026-11-19T12:01:00.000Z" },
  ];
  for (const variant of variants) {
    const h = harness(), j = job();
    await h.advance(j); await h.advance(j); h.finish("sync", variant);
    assert.notEqual((await h.advance(j)).phase, "reconcile-ready");
    assert.equal(h.requests.size, 1);
  }
});

test("durable retries never re-dispatch an existing request, including lost acceptance", async () => {
  const h = harness(), j = job();
  await h.advance(j);
  const persisted = structuredClone(j.checkpoint);
  await h.advance(j);
  j.checkpoint = persisted;
  await h.advance(j); await h.advance(j);
  assert.equal(h.calls.filter((c) => c.startsWith("invoke:")).length, 1);
});

test("an ambiguous invoke failure never leaks provider content or re-dispatches", async () => {
  const h = harness(), j = job();
  h.provider.invoke = async () => { throw new Error("secret-token-and-provider-content"); };
  await h.advance(j);
  const waiting = await h.advance(j);
  assert.equal(waiting.phase, "sync-waiting");
  assert.ok(!JSON.stringify(waiting).includes("secret-token"));
  h.provider.invoke = async () => assert.fail("an ambiguous request must not be repeated");
  assert.equal((await h.advance(j)).state, "running");
});

test("preflight and receipt-store failures are sanitized and block without reconciliation", async () => {
  const h = harness(), j = job();
  h.provider.settings = async () => { throw new Error("sensitive-connection-string"); };
  const failed = await h.advance(j);
  assert.equal(failed.reason, "apply_dependency_unavailable");
  assert.ok(!JSON.stringify(failed).includes("connection-string"));
  assert.equal(h.requests.size, 0);

  const receiptFailure = harness(), next = job();
  await receiptFailure.advance(next); await receiptFailure.advance(next);
  receiptFailure.store.read = async () => { throw new Error("sensitive-cosmos-diagnostic"); };
  const unavailable = await receiptFailure.advance(next);
  assert.equal(unavailable.state, "blocked");
  assert.ok(!JSON.stringify(unavailable).includes("cosmos-diagnostic"));
  assert.equal(receiptFailure.requests.size, 1);
});

test("promotion, project edits and expired budget freshness block progression", async () => {
  const h = harness(), j = job();
  await h.advance(j); await h.advance(j); h.finish("sync");
  h.setEtag('"2"');
  assert.equal((await h.advance(j)).reason, "project_changed");
  h.setEtag('"1"'); await h.advance(j);
  h.settings.get(pairs[0].syncResourceId)!["AzureWebJobs.syncEntitlement.Disabled"] = "true";
  assert.equal((await h.advance(j)).state, "blocked");
  assert.equal(h.requests.size, 1);

  const fresh = harness(), second = job();
  await fresh.advance(second); await fresh.advance(second); fresh.finish("sync");
  await fresh.advance(second); await fresh.advance(second);
  fresh.finish("reconcile", { validUntil: "2026-11-19T11:59:59.000Z" });
  assert.notEqual((await fresh.advance(second)).state, "succeeded");
});

test("transient receipt failures preserve the exact waiting request for durable retry", async () => {
  for (const fields of [
    { code: 429 }, { code: 503 }, { statusCode: 504 }, { status: 408 },
    { code: "ETIMEDOUT" }, { name: "TimeoutError" }, { cause: { code: "ESOCKETTIMEDOUT" } },
  ]) {
    const h = harness(), j = job();
    await h.advance(j); await h.advance(j); h.finish("sync");
    const checkpoint = structuredClone(j.checkpoint), read = h.store.read;
    h.store.read = async () => { throw Object.assign(new Error("private-provider-details"), fields); };
    await assert.rejects(h.advance(j), { message: "apply_dependency_unavailable" });
    assert.deepEqual(j.checkpoint, checkpoint);
    h.store.read = read;
    assert.equal((await h.advance(j)).phase, "reconcile-ready");
    assert.equal(h.calls.filter((call) => call.startsWith("invoke:")).length, 1);
  }
});

test("transient preflight and fence reads retry but capability remains safely unavailable", async () => {
  const h = harness(), j = job(), capability = h.provider.capability, settings = h.provider.settings;
  h.provider.capability = async () => { throw Object.assign(new Error("private-provider-details"), { code: 503 }); };
  assert.equal((await h.executor.capability()).state, "unavailable");
  await assert.rejects(h.advance(j), { message: "apply_dependency_unavailable" });
  h.provider.capability = capability;
  h.provider.settings = async () => { throw Object.assign(new Error("private-provider-details"), { code: 429 }); };
  await assert.rejects(h.advance(j), { message: "apply_dependency_unavailable" });
  h.provider.settings = settings;
  assert.equal((await h.advance(j)).phase, "sync-ready");
  assert.equal(h.requests.size, 0);
});

test("receipt permission failures remain terminal and scoped rather than retried", async () => {
  const h = harness(), j = job();
  await h.advance(j); await h.advance(j);
  const requirements = [{ action: "items/read", scope: "configured-adminConfig" }];
  h.store.read = async () => { throw new ApplyPermissionError(requirements); };
  const step = await h.advance(j);
  assert.equal(step.state, "blocked");
  assert.equal(step.reason, "apply_cosmos_permission_required");
  assert.deepEqual(step.requirements, requirements);
  assert.equal(h.requests.size, 1);
});
