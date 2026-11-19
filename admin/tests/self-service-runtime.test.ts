import assert from "node:assert/strict";
import test from "node:test";
import { createMemoryChangeLog } from "../src/change-log.ts";
import { createHistoryAccess, createRoutingAudit, createSelfServiceRuntime } from "../src/self-service-runtime.ts";
import { handleSelfServiceRequest } from "../src/self-service-api.ts";
import type { OperationJob } from "../src/self-service-contracts.ts";

const now = () => new Date("2026-11-20T12:00:00Z");
const job: OperationJob = {
  id: "a".repeat(64), kind: "publish-routing", projectId: "PROJECT", expectedEtag: '"one"',
  actorOid: "actor", createdAt: now().toISOString(), reason: "Publish reviewed route", checkpoint: {},
};
const intent = { phase: "publish", revision: "r1", poolBackendId: "pool", target: "/approved/apim", backendIds: ["primary"], planHash: "plan" };

test("routing retries durably acknowledge the same intent without overwriting prior attempts", async () => {
  const changeLog = createMemoryChangeLog();
  let id = 0;
  const audit = createRoutingAudit({ changeLog, now, newId: () => `attempt-${++id}`, log() {} });
  await audit(job, intent);
  await audit(job, intent);
  assert.equal(changeLog.records.size, 2);
  const [first, retry] = [...changeLog.records.values()];
  assert.equal(first.details.intentId, retry.details.intentId);
  assert.equal(first.details.operationId, job.id);
  assert.equal(first.actorOid, job.actorOid);
  assert.equal(first.outcome, "intent_recorded");
  assert.equal(first.details.reason, job.reason);
  await audit(job, { ...intent, target: "/another/approved/apim" });
  assert.notEqual([...changeLog.records.values()][2].details.intentId, first.details.intentId);
});

test("routing cannot proceed without a durably written mandatory audit intent", async () => {
  const changeLog = createMemoryChangeLog();
  const deps = { changeLog, now, newId: () => "attempt", log() {} };
  changeLog.failAppend = true;
  await assert.rejects(createRoutingAudit(deps)(job, intent), /change_log_unavailable/);
  await assert.rejects(createRoutingAudit({ ...deps, changeLog: null })(job, intent), /change_log_not_configured/);
  assert.equal(changeLog.records.size, 0);
});

test("disabled features preserve the original project store and never contact Azure", async () => {
  const projects = { list: async () => [], read: async () => null, create: async () => '"new"', replace: async () => '"new"' };
  const runtime = createSelfServiceRuntime({
    env: {}, authenticate: async () => ({ oid: "reader", canWrite: false }), projects,
    container: null, registry: null, changeLog: null, now, newId: () => "request", log() {},
    credential: { getToken: async () => { throw new Error("must_not_contact_azure"); } },
  });

  assert.equal(runtime.projects, projects);
  const response = await handleSelfServiceRequest({
    method: "GET", path: "/api/v3/self-service/capabilities", headers: () => null, body: null,
  }, runtime.dependencies);
  assert.equal(response?.status, 200);
  assert.deepEqual(Object.values(response?.jsonBody as object).map((capability) => capability.state), ["disabled", "disabled", "disabled"]);
  await runtime.tick();
});

test("enabled Apply fails locally when its concrete transport has no store, without disabling other features", async () => {
  const runtime = createSelfServiceRuntime({
    env: { ADMIN_APPLY_ENABLED: "true" }, authenticate: async () => ({ oid: "reader", canWrite: false }),
    projects: { list: async () => [], read: async () => null, create: async () => '"new"', replace: async () => '"new"' },
    container: null, registry: null, changeLog: null, now, newId: () => "request", log() {},
    credential: { getToken: async () => { throw new Error("must_not_contact_azure"); } },
  });
  const response = await handleSelfServiceRequest({
    method: "GET", path: "/api/v3/self-service/capabilities", headers: () => null, body: null,
  }, runtime.dependencies);
  const capabilities = response?.jsonBody as Record<string, { state: string; reason?: string }>;
  assert.equal(capabilities.apply.reason, "apply_store_not_configured");
  assert.equal(capabilities.history.state, "disabled");
  assert.equal(capabilities["publish-routing"].state, "disabled");
});

test("history adapter preserves current ETag and real authenticated actor through preview and restore", async () => {
  const requests: unknown[] = [];
  const project = { projectId: "PROJECT", status: "active" };
  const service = {
    capability: async () => ({ state: "available" as const, requirements: [], prerequisites: [] }),
    list: async () => [{ id: "version", projectId: "PROJECT", hash: "hash", capturedAt: now().toISOString() }],
    preview: async (request: unknown) => {
      requests.push(request);
      return { projectId: "PROJECT", version: "version", ifMatch: '"current"', reason: "Preview configuration restore", changes: [], requiresPublication: true };
    },
    restore: async (request: unknown) => {
      requests.push(request);
      return { projectId: "PROJECT", version: "version", ifMatch: '"current"', reason: "Restore reviewed configuration", changes: [], requiresPublication: true, project, etag: '"restored"', recordedVersion: "recorded" };
    },
  };
  const history = createHistoryAccess(service, { read: async () => ({ doc: project, etag: '"current"' }) });
  assert.deepEqual(await history.list("PROJECT"), { versions: [{ versionId: "version", createdAt: now().toISOString(), sourceEtag: null }] });
  assert.deepEqual(await history.preview("PROJECT", "version", "real-actor"), { versionId: "version", etag: '"current"', changes: [], requiresPublication: true });
  const restored = await history.restore({ projectId: "PROJECT", versionId: "version", etag: '"current"', actorOid: "real-actor", reason: "Restore reviewed configuration", requestId: "request" });
  assert.equal(restored.etag, '"restored"');
  assert.deepEqual((requests[0] as { actor: unknown }).actor, { oid: "real-actor", canWrite: true });
  assert.equal((requests[1] as { requestId: string }).requestId, "request");
});
