import assert from "node:assert/strict";
import test from "node:test";
import { handleSelfServiceRequest } from "../src/self-service-api.ts";
import { createMemoryJobStore } from "../src/self-service-jobs.ts";
import { createMemoryChangeLog } from "../src/change-log.ts";
import { ApiError } from "../src/auth.ts";

const now = new Date("2026-11-20T12:00:00Z");
function fixture() {
  const jobs = createMemoryJobStore();
  const changeLog = createMemoryChangeLog();
  let version = '"v1"';
  let sequence = 0;
  const available = async () => ({ state: "available" as const, requirements: [] });
  const deps = {
    authenticate: async () => ({ oid: "editor", canWrite: true }),
    projects: { read: async () => ({ doc: { projectId: "PROJECT", status: "active" }, etag: version }) },
    jobs, changeLog, storageScope: "/dbs/ccof/colls/adminConfig",
    features: { "publish-routing": { capability: available }, apply: { capability: available } },
    now: () => now, newId: () => `audit-${++sequence}`, log: () => {},
  };
  const request = (path: string, method = "GET", body: unknown = undefined, headers: Record<string, string> = {}) =>
    ({ path, method, body: body === undefined ? null : JSON.stringify(body), headers: (name: string) => headers[name.toLowerCase()] ?? null });
  return { deps, request, setVersion: (value: string) => { version = value; } };
}
const payload = { kind: "apply", reason: "Apply reviewed settings" };
const writeHeaders = { "if-match": '"v1"', "idempotency-key": "request-00001" };

test("reader cannot enqueue or restore; missing authorization cannot read job metadata", async () => {
  const { deps, request } = fixture();
  deps.authenticate = async () => ({ oid: "reader", canWrite: false });
  const result = await handleSelfServiceRequest(request("/api/v3/projects/PROJECT/operations", "POST", payload, writeHeaders), deps);
  assert.equal(result?.status, 403);
  assert.equal(deps.jobs.jobs.size, 0);
  const restore = await handleSelfServiceRequest(request("/api/v3/projects/PROJECT/history/version/restore", "POST", { reason: payload.reason }, writeHeaders), deps);
  assert.equal(restore?.status, 403);
  deps.authenticate = null as any;
  const anonymous = await handleSelfServiceRequest(request(`/api/v3/self-service/jobs/${"a".repeat(64)}`), deps);
  assert.equal(anonymous?.status, 503);
});

test("each failed capability is isolated and reports permission scope", async () => {
  const { deps, request } = fixture();
  const requirements = [{ action: "Microsoft.ApiManagement/service/backends/write", scope: "/approved/apim" }];
  deps.features["publish-routing"].capability = async () => ({ state: "permission_required", requirements } as any);
  const result = await handleSelfServiceRequest(request("/api/v3/self-service/capabilities"), deps);
  assert.equal(result?.status, 200);
  const body: any = result?.jsonBody;
  assert.equal(body["publish-routing"].state, "permission_required");
  assert.deepEqual(body["publish-routing"].requirements, requirements);
  assert.equal(body.apply.state, "available");
});

test("missing durable write rights disable operations without disabling configuration history", async () => {
  const { deps, request } = fixture();
  Object.assign(deps.jobs, { async probe() { throw Object.assign(new Error("provider-secret"), { code: 403 }); } });
  Object.assign(deps, { history: { capability: async () => ({ state: "available", requirements: [] }) } });
  const result = await handleSelfServiceRequest(request("/api/v3/self-service/capabilities"), deps);
  const body: any = result?.jsonBody;
  assert.equal(body.apply.state, "permission_required");
  assert.equal(body["publish-routing"].state, "permission_required");
  assert.ok(body.apply.requirements.some((requirement: any) => requirement.action.endsWith("/items/create")));
  assert.ok(body.apply.requirements.some((requirement: any) => requirement.action.endsWith("/executeQuery")));
  assert.equal(body.history.state, "available");
  assert.doesNotMatch(JSON.stringify(body), /provider-secret/);
});

test("a request needs a current ETag, a reason, an idempotency key and an allowlisted operation", async () => {
  const { deps, request } = fixture();
  const path = "/api/v3/projects/PROJECT/operations";
  for (const [body, headers, expected] of [
    [payload, {}, 428],
    [payload, { "if-match": '"v1"' }, 400],
    [{ kind: "run-script", reason: payload.reason }, writeHeaders, 400],
    [{ ...payload, resourceId: "/other/app" }, writeHeaders, 400],
    [{ ...payload, reason: "" }, writeHeaders, 400],
    [payload, { ...writeHeaders, "if-match": '"old"' }, 412],
  ] as const) {
    const result = await handleSelfServiceRequest(request(path, "POST", body, headers), deps);
    assert.equal(result?.status, expected, JSON.stringify({ body, headers }));
  }
  assert.equal(deps.jobs.jobs.size, 0);
});

test("enqueue returns 202, replay survives project changes, and changed requests conflict", async () => {
  const { deps, request, setVersion } = fixture();
  const path = "/api/v3/projects/PROJECT/operations";
  const first = await handleSelfServiceRequest(request(path, "POST", payload, writeHeaders), deps);
  assert.equal(first?.status, 202);
  setVersion('"changed"');
  const replay = await handleSelfServiceRequest(request(path, "POST", payload, writeHeaders), deps);
  assert.equal(replay?.status, 202);
  assert.deepEqual(replay?.jsonBody, first?.jsonBody);
  const conflict = await handleSelfServiceRequest(request(path, "POST", { ...payload, reason: "Different request reason" }, writeHeaders), deps);
  assert.equal(conflict?.status, 409);
  assert.equal(deps.jobs.jobs.size, 1);
});

test("failed mandatory audit prevents queueing and unknown routes remain with the existing API", async () => {
  const { deps, request } = fixture();
  deps.changeLog.failAppend = true;
  const denied = await handleSelfServiceRequest(request("/api/v3/projects/PROJECT/operations", "POST", payload, writeHeaders), deps);
  assert.equal(denied?.status, 503);
  assert.equal(deps.jobs.jobs.size, 0);
  assert.equal(await handleSelfServiceRequest(request("/api/v3/health"), deps), null);
});

test("native history permission refusals report history scope rather than operation-store grants", async () => {
  const { deps, request } = fixture();
  const requirements = [{ action: "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create", scope: "/dbs/ccof/colls/history" }];
  Object.assign(deps, { history: {
    capability: async () => ({ state: "available", requirements: [] }),
    preview: async (_projectId: string, _versionId: string, actorOid: string) => {
      assert.equal(actorOid, "editor");
      throw Object.assign(new ApiError(403, "history_permission_required"), { requirements });
    },
  } });
  const response = await handleSelfServiceRequest(request("/api/v3/projects/PROJECT/history/version/preview", "POST", {}), deps);
  assert.equal(response?.status, 403);
  assert.deepEqual((response?.jsonBody as any).capability?.requirements, requirements);
  assert.equal((response?.jsonBody as any).capability?.reason, "history_permission_required");
});
