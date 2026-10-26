// ADR 0034: backend registry, per-project failover, routing publication (admin/src/backend-routing.ts, v3.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleAdminRequest } from "../src/api.ts";
import type { ApiDependencies, ProjectStore, StoredProject } from "../src/api.ts";
import { handleV3Request } from "../src/v3.ts";
import { QueryCache } from "../src/chargeback.ts";
import { createMemoryChangeLog } from "../src/change-log.ts";
import { createMemoryRegistryStore } from "../src/backend-routing.ts";
import type { Doc } from "../src/validation.ts";
import { readProjectDocument } from "../../src/sync/projects.ts";

const NOW = new Date("2026-10-23T10:00:00.000Z");
const APIM = "/subscriptions/00000000-0000-4000-8000-00000000dd02/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-a";
const limit = (tpm: number, quota: number) => ({ tokensPerMinute: tpm, tokenQuota: quota, tokenQuotaPeriod: "Monthly" });
const project = (id = "PROJECT02"): Doc => ({
  id, projectId: id, displayName: "Project 02", status: "active", backendId: "foundry-a",
  designatedSubscriptionId: "00000000-0000-4000-8000-0000000000b1", supersedes: null, retiredAt: null,
  classifications: { STD: {
    groupId: "00000000-0000-4000-8000-0000000000c1", classificationGroupDisplayName: "PROJECT02-STD",
    familyPolicy: {
      aggregateLimits: { person: limit(10000, 1000000), group: limit(50000, 10000000) },
      families: { haiku: { models: ["claude-haiku-4-5"], person: limit(10000, 1000000), group: limit(50000, 10000000) } },
    },
    personBudget: { amount: 10, currency: "USD", period: "monthly" }, aggregateBudget: { amount: 100, currency: "USD", period: "monthly" },
    aggregateMode: "strict", onboardingMode: "block",
  } },
});
const breaker = { enabled: true, failureCount: 3, failureIntervalSeconds: 60, tripDurationSeconds: 60, statusCodeRanges: [{ min: 429, max: 429 }, { min: 500, max: 599 }], acceptRetryAfter: true };
const entry = (account: string, circuitBreaker: unknown = breaker, over: Doc = {}) => ({
  displayName: account, url: `https://${account}.services.ai.azure.com/anthropic`, deployments: ["claude-haiku-4-5"],
  inferenceGeo: "global", status: "active", circuitBreaker, ...over,
});

class Store implements ProjectStore {
  docs = new Map<string, StoredProject>();
  private n = 0;
  async list() { return [...this.docs.values()].map((p) => structuredClone(p)); }
  async read(id: string) { const p = this.docs.get(id); return p ? structuredClone(p) : null; }
  async create(doc: Doc) { const etag = `"e${++this.n}"`; this.docs.set(String(doc.projectId), { doc: structuredClone(doc), etag }); return etag; }
  async replace(doc: Doc, etag: string) {
    const cur = this.docs.get(String(doc.projectId));
    if (!cur || cur.etag !== etag) return "precondition_failed" as const;
    const next = `"e${++this.n}"`; this.docs.set(String(doc.projectId), { doc: structuredClone(doc), etag: next }); return next;
  }
}

function setup() {
  const store = new Store();
  const changeLog = createMemoryChangeLog();
  const registry = createMemoryRegistryStore();
  let id = 0;
  const logs: Doc[] = [];
  const base = { authenticate: async (h: string | null) => ({ oid: "00000000-0000-4000-8000-0000000000e1", canWrite: h !== "reader" }),
    now: () => NOW, newId: () => `req-${++id}`, log: (line: string) => { logs.push(JSON.parse(line) as Doc); } };
  const headers = (h: Record<string, string>) => (n: string) => h[n.toLowerCase()] ?? (n.toLowerCase() === "authorization" ? "editor" : null);
  const v1 = (method: string, path: string, body?: unknown, h: Record<string, string> = {}) => handleAdminRequest({
    method, path, headers: headers(h), body: body === undefined ? null : JSON.stringify(body) }, { ...base, store, changeLog } as ApiDependencies);
  const v3 = (method: string, path: string, body?: unknown, h: Record<string, string> = {}) => handleV3Request({
    method, path: `/api/v3/${path}`, headers: headers(h), body: body === undefined ? null : JSON.stringify(body),
  }, { ...base, projects: store, catalogStore: null, changeLog, registry, defaultCatalog: null, env: {}, sources: null, cache: new QueryCache(), operations: {} as never } as never);
  return { store, changeLog, registry, v1, v3, logs };
}
const json = (r: { jsonBody?: unknown }) => r.jsonBody as Doc;

async function registered() {
  const s = setup();
  assert.equal((await s.v3("PUT", "backends/foundry-a", entry("acct-a"), { "if-none-match": "*" })).status, 201);
  assert.equal((await s.v3("PUT", "backends/foundry-b", entry("acct-b", null), { "if-none-match": "*" })).status, 201);
  await s.store.create(project());
  return s;
}

test("registering a backend: the circuit breaker is optional, writes need an editor, a precondition and valid fields", async () => {
  const { v3, registry, changeLog } = setup();
  assert.equal((await v3("PUT", "backends/foundry-a", entry("acct-a"), { "if-none-match": "*", authorization: "reader" })).status, 403);
  assert.equal((await v3("PUT", "backends/foundry-a", entry("acct-a"))).status, 412);
  const bad = await v3("PUT", "backends/foundry-a", entry("acct-a", { ...breaker, failureCount: 0 }, { url: "https://evil.example.com/anthropic" }), { "if-none-match": "*" });
  assert.equal(bad.status, 422);
  assert.deepEqual(json(bad).problems, ["url:invalid", "circuitBreaker.failureCount:invalid"]);
  assert.equal((await v3("PUT", "backends/ccof-pool-x", entry("acct-a"), { "if-none-match": "*" })).status, 422);
  assert.equal(registry.entries.size, 0);
  assert.equal((await v3("PUT", "backends/foundry-b", entry("acct-b", null), { "if-none-match": "*" })).status, 201);
  const created = await v3("PUT", "backends/foundry-a", entry("acct-a"), { "if-none-match": "*" });
  assert.equal(created.status, 201);
  assert.equal((await v3("PUT", "backends/foundry-a", entry("acct-a", null))).status, 428);
  const etag = String((json(created).backend as Doc).etag);
  const updated = await v3("PUT", "backends/foundry-a", entry("acct-a", null), { "if-match": etag });
  assert.equal(updated.status, 200);
  assert.equal(registry.entries.get("foundry-a")!.doc.circuitBreaker, null);
  const listed = json(await v3("GET", "backends")).backends as Doc[];
  assert.deepEqual(listed.map((b) => [b.backendId, b.circuitBreaker === null]), [["foundry-a", true], ["foundry-b", true]]);
  const records = [...changeLog.records.values()].filter((r) => r.operation === "v3/backends");
  assert.equal(records.length, 3);
  assert.ok(records.some((r) => r.changes.some((c) => c.path === "circuitBreaker" && c.after === null)));
});

test("enabling failover needs a primary with an enabled breaker; the registry then checks every fallback", async () => {
  const { v3, store, registry } = await registered();
  const etag = (await store.read("PROJECT02"))!.etag;
  assert.equal((await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-b"] })).status, 428);
  registry.entries.get("foundry-a")!.doc.circuitBreaker = null;
  const noBreaker = await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-b"] }, { "if-match": etag });
  assert.equal(noBreaker.status, 422);
  assert.deepEqual(json(noBreaker).problems, ["primary:circuit_breaker_required"]);
  registry.entries.get("foundry-a")!.doc.circuitBreaker = breaker as never;
  registry.entries.get("foundry-b")!.doc.deployments = ["claude-sonnet-5"];
  const models = await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-b"] }, { "if-match": etag });
  assert.deepEqual(json(models).problems, ["fallbackBackendIds.0:models_missing"]);
  registry.entries.get("foundry-b")!.doc.deployments = ["claude-haiku-4-5"];
  assert.deepEqual(json(await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-a"] }, { "if-match": etag })).problems,
    ["failover.fallbackBackendIds:includes_primary"]);
  assert.equal((await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-b"] }, { "if-match": etag, authorization: "reader" })).status, 403);
  assert.equal((await store.read("PROJECT02"))!.etag, etag, "refused requests write nothing");
  const ok = await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-b"] }, { "if-match": etag });
  assert.equal(ok.status, 200);
  assert.equal(json(ok).state, "pending_publication");
  assert.deepEqual((await store.read("PROJECT02"))!.doc.failover, { enabled: true, fallbackBackendIds: ["foundry-b"], revision: 1, active: null });
});

test("pending lists the pool plan; publication of the current revision activates the route the sync copies", async () => {
  const { v3, store, changeLog } = await registered();
  await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-b"] }, { "if-match": (await store.read("PROJECT02"))!.etag });
  const pending = json(await v3("GET", "routing/pending")).pending as Doc[];
  assert.equal(pending.length, 1);
  const plan = pending[0];
  assert.equal(plan.revision, 1);
  assert.match(String(plan.poolBackendId), /^ccof-pool-project02-[0-9a-f]{8}-r1$/);
  assert.deepEqual((plan.members as Doc[]).map((m) => [m.backendId, m.priority, m.url, m.circuitBreaker === null]), [
    ["foundry-a", 1, "https://acct-a.services.ai.azure.com/anthropic", false],
    ["foundry-b", 2, "https://acct-b.services.ai.azure.com/anthropic", true],
  ]);
  assert.deepEqual(plan.problems, []);
  assert.equal(readProjectDocument((await store.read("PROJECT02"))!.doc).ok && (readProjectDocument((await store.read("PROJECT02"))!.doc) as { classifications: Doc[] }).classifications[0].routeBackendId, undefined);

  const publish = (b: Doc) => v3("POST", "routing/PROJECT02/publication", { verifiedTargets: [APIM], ...b });
  assert.equal((await publish({ revision: 2, poolBackendId: plan.poolBackendId })).status, 409);
  assert.equal((await publish({ revision: 1, poolBackendId: "ccof-pool-other-r1" })).status, 422);
  assert.equal((await publish({ revision: 1, poolBackendId: plan.poolBackendId, verifiedTargets: [] })).status, 422);
  assert.equal((await v3("POST", "routing/PROJECT02/publication", { revision: 1, poolBackendId: plan.poolBackendId, verifiedTargets: [APIM] }, { authorization: "reader" })).status, 403);
  const done = await publish({ revision: 1, poolBackendId: plan.poolBackendId });
  assert.equal(done.status, 200);
  assert.equal(json(done).state, "verified");
  const saved = (await store.read("PROJECT02"))!.doc;
  assert.deepEqual((saved.failover as Doc).active, { revision: 1, poolBackendId: plan.poolBackendId, verifiedAt: "2026-10-23T10:00:00Z" });
  const read = readProjectDocument(saved);
  if (!read.ok) assert.fail(JSON.stringify(read.problems));
  assert.equal(read.classifications[0].routeBackendId, plan.poolBackendId);
  assert.deepEqual(json(await v3("GET", "routing/pending")).pending, []);
  assert.ok([...changeLog.records.values()].some((r) => r.operation === "v3/routing/publication" && r.outcome === "published"));
});

test("toggling keeps the revision and the verified pool; a new fallback list is a new revision that keeps routing on the old pool", async () => {
  const { v3, store, registry } = await registered();
  await registry.save({ backendId: "foundry-c", ...entry("acct-c", null) } as never, null);
  await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-b"] }, { "if-match": (await store.read("PROJECT02"))!.etag });
  const pool = String((json(await v3("GET", "routing/pending")).pending as Doc[])[0].poolBackendId);
  await v3("POST", "routing/PROJECT02/publication", { revision: 1, poolBackendId: pool, verifiedTargets: [APIM] });
  const off = await v3("PUT", "projects/PROJECT02/failover", { enabled: false, fallbackBackendIds: ["foundry-b"] }, { "if-match": (await store.read("PROJECT02"))!.etag });
  assert.equal(json(off).state, "disabled_with_pool");
  const offDoc = readProjectDocument((await store.read("PROJECT02"))!.doc) as { ok: true; classifications: Doc[] };
  assert.equal(offDoc.classifications[0].routeBackendId, undefined, "disabled failover routes direct");
  const on = await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-b"] }, { "if-match": (await store.read("PROJECT02"))!.etag });
  assert.equal(json(on).state, "verified");
  assert.equal((json(on).failover as Doc).revision, 1);
  const changed = await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-c", "foundry-b"] }, { "if-match": (await store.read("PROJECT02"))!.etag });
  assert.equal(json(changed).state, "pending_publication");
  assert.equal((json(changed).failover as Doc).revision, 2);
  const still = readProjectDocument((await store.read("PROJECT02"))!.doc) as { ok: true; classifications: Doc[] };
  assert.equal(still.classifications[0].routeBackendId, pool, "the verified pool keeps serving until the new revision is published");
  assert.equal((await v3("POST", "routing/PROJECT02/publication", { revision: 1, poolBackendId: pool, verifiedTargets: [APIM] })).status, 409);
});

test("v1: create refuses failover; a primary change is refused while failover is on and forgets the pool when off", async () => {
  const { v1, v3, store } = await registered();
  assert.deepEqual(json(await v1("POST", "/api/projects", { ...project("PROJECT09"), failover: { enabled: false, fallbackBackendIds: [], revision: 1, active: null } })).problems,
    ["failover:use_failover_endpoint"]);
  await v3("PUT", "projects/PROJECT02/failover", { enabled: true, fallbackBackendIds: ["foundry-b"] }, { "if-match": (await store.read("PROJECT02"))!.etag });
  const pool = String((json(await v3("GET", "routing/pending")).pending as Doc[])[0].poolBackendId);
  await v3("POST", "routing/PROJECT02/publication", { revision: 1, poolBackendId: pool, verifiedTargets: [APIM] });
  const move = { backendId: "foundry-c", designatedSubscriptionId: "00000000-0000-4000-8000-0000000000b1" };
  const refused = await v1("PUT", "/api/projects/PROJECT02/settings", move, { "if-match": (await store.read("PROJECT02"))!.etag });
  assert.deepEqual(json(refused).problems, ["backendId:disable_failover_first"]);
  await v3("PUT", "projects/PROJECT02/failover", { enabled: false, fallbackBackendIds: ["foundry-b"] }, { "if-match": (await store.read("PROJECT02"))!.etag });
  const moved = await v1("PUT", "/api/projects/PROJECT02/settings", move, { "if-match": (await store.read("PROJECT02"))!.etag });
  assert.equal(moved.status, 200);
  assert.deepEqual((await store.read("PROJECT02"))!.doc.failover, { enabled: false, fallbackBackendIds: ["foundry-b"], revision: 2, active: null });
  const read = await v1("GET", "/api/projects/PROJECT02");
  assert.equal(read.status, 200);
});

// PROJECT02 verified on foundry-a > foundry-b; PROJECT03 published then switched off; PROJECT04 never
// configured; PROJECT05 verified on foundry-c > foundry-a.
async function verifiedPools() {
  const s = await registered();
  await s.registry.save({ backendId: "foundry-c", ...entry("acct-c") } as never, null);
  await s.store.create(project("PROJECT03"));
  await s.store.create(project("PROJECT04"));
  await s.store.create({ ...project("PROJECT05"), backendId: "foundry-c" });
  const enable = async (id: string, fallbackBackendIds: string[], enabled = true) =>
    s.v3("PUT", `projects/${id}/failover`, { enabled, fallbackBackendIds }, { "if-match": (await s.store.read(id))!.etag });
  await enable("PROJECT02", ["foundry-b"]);
  await enable("PROJECT03", ["foundry-b"]);
  await enable("PROJECT05", ["foundry-a"]);
  for (const plan of json(await s.v3("GET", "routing/pending")).pending as Doc[]) {
    assert.equal((await s.v3("POST", `routing/${plan.projectId}/publication`, { revision: plan.revision, poolBackendId: plan.poolBackendId, verifiedTargets: [APIM] })).status, 200);
  }
  await enable("PROJECT03", ["foundry-b"], false);
  const etags = async () => Object.fromEntries(await Promise.all(["PROJECT02", "PROJECT03", "PROJECT04", "PROJECT05"].map(async (id) => [id, (await s.store.read(id))!.etag])));
  const putBackend = async (backendId: string, body: Doc) =>
    s.v3("PUT", `backends/${backendId}`, body, { "if-match": (await s.registry.read(backendId))!.etag });
  return { ...s, etags, putBackend };
}
const requeues = (changeLog: ReturnType<typeof createMemoryChangeLog>) =>
  [...changeLog.records.values()].filter((r) => r.operation === "v3/backends/routing-revision");

test("a breaker change queues a new revision for each verified project whose pool uses the backend", async () => {
  const { v3, store, changeLog, logs, etags, putBackend } = await verifiedPools();
  const before = await etags();
  const tightened = { ...breaker, failureCount: 1, tripDurationSeconds: 120 };
  const changed = await putBackend("foundry-b", entry("acct-b", tightened));
  assert.equal(changed.status, 200);
  assert.deepEqual(json(changed).routing, { queued: [{ projectId: "PROJECT02", revision: 2 }], failed: [] });
  const failover = (await store.read("PROJECT02"))!.doc.failover as Doc;
  assert.equal(failover.revision, 2);
  assert.equal((failover.active as Doc).revision, 1, "the verified pool keeps serving until revision 2 is published");
  const after = await etags();
  assert.notEqual(after.PROJECT02, before.PROJECT02);
  assert.deepEqual([after.PROJECT03, after.PROJECT04, after.PROJECT05], [before.PROJECT03, before.PROJECT04, before.PROJECT05],
    "failover off, never configured and pools without the backend are untouched");
  const pending = json(await v3("GET", "routing/pending")).pending as Doc[];
  assert.deepEqual(pending.map((p) => [p.projectId, p.revision]), [["PROJECT02", 2]]);
  assert.match(String(pending[0].poolBackendId), /-r2$/);
  assert.deepEqual((pending[0].members as Doc[])[1].circuitBreaker, tightened);
  const records = requeues(changeLog);
  assert.equal(records.length, 1);
  assert.equal(records[0].projectId, "PROJECT02");
  assert.equal(records[0].outcome, "updated");
  assert.deepEqual(records[0].changes, [{ path: "failover.revision", before: 1, after: 2 }]);
  assert.equal(records[0].details.backendId, "foundry-b");
  assert.ok(logs.some((l) => l.schema === "ccof.admin.audit.v1" && l.operation === "v3/backends/routing-revision" && l.projectId === "PROJECT02" && l.outcome === "updated"));

  // A primary's breaker reaches PROJECT05, where foundry-a is a fallback; PROJECT02 is already pending
  // and its publication reads the current registry, so it is not moved again.
  const primary = await putBackend("foundry-a", entry("acct-a", { ...breaker, acceptRetryAfter: false }));
  assert.deepEqual(json(primary).routing, { queued: [{ projectId: "PROJECT05", revision: 2 }], failed: [] });
  assert.equal(((await store.read("PROJECT02"))!.doc.failover as Doc).revision, 2);
  assert.equal(((await store.read("PROJECT03"))!.doc.failover as Doc).revision, 1);
});

test("a backend edit that leaves the breaker unchanged queues no revision", async () => {
  const { v3, changeLog, etags, putBackend } = await verifiedPools();
  const before = await etags();
  const renamed = await putBackend("foundry-a", entry("acct-a", breaker, { displayName: "renamed" }));
  assert.equal(renamed.status, 200);
  assert.equal(json(renamed).changed, true);
  assert.deepEqual(json(renamed).routing, { queued: [], failed: [] });
  assert.deepEqual(await etags(), before);
  assert.deepEqual(json(await v3("GET", "routing/pending")).pending, []);
  assert.equal(requeues(changeLog).length, 0);
});

test("a breaker requeue re-reads a project changed concurrently and keeps that change", async () => {
  const { store, putBackend } = await verifiedPools();
  const replace = store.replace.bind(store);
  let raced = false;
  store.replace = async (doc: Doc, etag: string) => {
    if (!raced) { raced = true; const cur = (await store.read("PROJECT02"))!; await replace({ ...cur.doc, displayName: "edited meanwhile" }, cur.etag); }
    return replace(doc, etag);
  };
  const changed = await putBackend("foundry-b", entry("acct-b", breaker));
  assert.deepEqual(json(changed).routing, { queued: [{ projectId: "PROJECT02", revision: 2 }], failed: [] });
  const saved = (await store.read("PROJECT02"))!.doc;
  assert.equal(saved.displayName, "edited meanwhile");
  assert.equal((saved.failover as Doc).revision, 2);
});
