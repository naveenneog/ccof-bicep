import assert from "node:assert/strict";
import test from "node:test";
import { createMemoryJobStore, enqueueOperation, processOperations } from "../src/self-service-jobs.ts";

const start = new Date("2026-11-20T12:00:00Z");
const input = {
  key: "request-key-00001", kind: "apply" as const, projectId: "PROJECT", expectedEtag: '"one"',
  actorOid: "actor", reason: "Apply reviewed configuration",
};

test("the same actor and key returns the durable job; a changed request conflicts", async () => {
  const store = createMemoryJobStore();
  const first = await enqueueOperation(store, input, start);
  const again = await enqueueOperation(store, input, start);
  assert.equal(first.id, again.id);
  assert.equal(store.jobs.size, 1);
  await assert.rejects(enqueueOperation(store, { ...input, projectId: "OTHER" }, start), /idempotency_conflict/);
  const another = await enqueueOperation(store, { ...input, actorOid: "someone-else" }, start);
  assert.notEqual(first.id, another.id);
});

test("progress survives another worker and accepted execution is not completion", async () => {
  const store = createMemoryJobStore();
  const job = await enqueueOperation(store, input, start);
  const phases: unknown[] = [];
  const executors = {
    apply: async (current: any) => {
      phases.push(current.checkpoint);
      return current.checkpoint.accepted
        ? { state: "succeeded" as const, phase: "completed", result: { fresh: true } }
        : { state: "running" as const, phase: "sync_requested", checkpoint: { accepted: true } };
    },
  };
  await processOperations(store, executors, { now: () => start, owner: "worker-A", log: () => {} });
  assert.equal((await store.read(job.id))?.job.state, "running");
  await processOperations(store, executors, { now: () => new Date(+start + 20_000), owner: "worker-B", log: () => {} });
  assert.equal((await store.read(job.id))?.job.state, "succeeded");
  assert.deepEqual(phases, [{}, { accepted: true }]);
});

test("a project lease prevents two jobs executing concurrently across regions", async () => {
  const store = createMemoryJobStore();
  await enqueueOperation(store, input, start);
  await enqueueOperation(store, { ...input, key: "request-key-00002" }, start);
  let release!: () => void;
  const wait = new Promise<void>((done) => { release = done; });
  let entered!: () => void;
  const ready = new Promise<void>((done) => { entered = done; });
  let calls = 0;
  const executors = { apply: async () => { calls++; entered(); await wait; return { state: "succeeded" as const, phase: "completed" }; } };
  const first = processOperations(store, executors, { now: () => start, owner: "A", log: () => {} });
  await ready;
  await processOperations(store, executors, { now: () => start, owner: "B", log: () => {} });
  assert.equal(calls, 1);
  release();
  await first;
});

test("a denied feature is blocked with its exact permission and unrelated jobs still run", async () => {
  const store = createMemoryJobStore();
  const denied = await enqueueOperation(store, { ...input, kind: "publish-routing" }, start);
  const apply = await enqueueOperation(store, { ...input, projectId: "SECOND", key: "request-key-00002" }, start);
  const requirements = [{ action: "Microsoft.ApiManagement/service/backends/write", scope: "/approved/apim" }];
  const executors = {
    "publish-routing": async () => ({ state: "blocked" as const, phase: "permission_required", requirements }),
    apply: async () => ({ state: "succeeded" as const, phase: "completed" }),
  };
  await processOperations(store, executors, { now: () => start, owner: "A", log: () => {} });
  await processOperations(store, executors, { now: () => start, owner: "B", log: () => {} });
  assert.equal((await store.read(denied.id))?.job.state, "blocked");
  assert.deepEqual((await store.read(denied.id))?.job.requirements, requirements);
  assert.equal((await store.read(apply.id))?.job.state, "succeeded");
});

test("expired work cannot run, and transient errors are bounded and redacted", async () => {
  const store = createMemoryJobStore();
  const old = await enqueueOperation(store, input, start);
  let calls = 0;
  const executors = { apply: async () => { calls++; throw new Error("secret-token-and-provider-response"); } };
  await processOperations(store, executors, { now: () => new Date(+start + 31 * 60_000), owner: "expired", log: () => {} });
  assert.equal(calls, 0);
  assert.equal((await store.read(old.id))?.job.reasonCode, "operation_expired");
  const fresh = await enqueueOperation(store, { ...input, key: "request-key-00002" }, start);
  const logs: string[] = [];
  for (let i = 0; i < 3; i++) {
    await processOperations(store, executors, { now: () => new Date(+start + i * 60_000), owner: `worker-${i}`, log: (line) => logs.push(line) });
  }
  assert.equal((await store.read(fresh.id))?.job.state, "failed");
  assert.ok(!JSON.stringify({ job: await store.read(fresh.id), logs }).includes("secret-token"));
});

test("a stale queue result cannot bypass another worker's persisted poll delay", async () => {
  const store = createMemoryJobStore();
  const job = await enqueueOperation(store, input, start);
  const candidate = (await store.read(job.id))!;
  await store.replace({ ...candidate.job, state: "running", nextAt: new Date(+start + 60_000).toISOString() }, candidate.etag);
  store.runnable = async () => [candidate];
  let calls = 0;
  await processOperations(store, { apply: async () => {
    calls++;
    return { state: "succeeded", phase: "completed" };
  } }, { now: () => start, owner: "late-query", log: () => {} });
  assert.equal(calls, 0);
  assert.equal((await store.read(job.id))?.job.state, "running");
});

test("checkpoint conflicts never overwrite another worker or claim completion", async () => {
  const store = createMemoryJobStore();
  const job = await enqueueOperation(store, input, start);
  const replace = store.replace.bind(store);
  store.replace = async (value, etag) => {
    if (value.state === "succeeded") await replace({ ...value, state: "running", phase: "another-worker" }, etag);
    return replace(value, etag);
  };
  const logs: string[] = [];
  await processOperations(store, { apply: async () => ({ state: "succeeded", phase: "completed" }) },
    { now: () => start, owner: "A", log: (line) => logs.push(line) });
  assert.equal((await store.read(job.id))?.job.state, "running");
  assert.equal((await store.read(job.id))?.job.phase, "another-worker");
  assert.ok(logs.some((line) => line.includes("job_checkpoint_conflict")));
  assert.ok(!logs.some((line) => line.includes('"state":"succeeded"')));
});
