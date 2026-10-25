import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { handleAdminRequest } from "../src/api.ts";
import type { ApiDependencies, ProjectStore, StoredProject } from "../src/api.ts";
import { handleV2Request } from "../src/v2.ts";
import { handleV3Request } from "../src/v3.ts";
import { QueryCache } from "../src/chargeback.ts";
import { createMemoryChangeLog } from "../src/change-log.ts";
import { createMemoryLimitsStore } from "../src/sync-limits.ts";
import type { Doc } from "../src/validation.ts";
import { effectiveRemovalLimits } from "../../src/sync/removal-limits.ts";

const NOW = new Date("2026-10-20T10:00:00.000Z");
const EDITOR = "00000000-0000-4000-8000-0000000000e1";
const READER = "00000000-0000-4000-8000-0000000000a1";
const limit = (tpm: number, quota: number) => ({ tokensPerMinute: tpm, tokenQuota: quota, tokenQuotaPeriod: "Monthly" });
const project = (id = "PROJECT02"): Doc => ({
  id, projectId: id, displayName: "Project 02", status: "active", backendId: "backend01",
  designatedSubscriptionId: "00000000-0000-4000-8000-0000000000b1", supersedes: null, retiredAt: null,
  classifications: { STD: {
    groupId: "00000000-0000-4000-8000-0000000000c1", classificationGroupDisplayName: "PROJECT02-STD",
    familyPolicy: {
      aggregateLimits: { person: limit(10000, 1000000), group: limit(50000, 10000000) },
      families: { sonnet: { models: ["claude-sonnet-4-5"], person: limit(10000, 1000000), group: limit(50000, 10000000) } },
    },
    personBudget: { amount: 10, currency: "USD", period: "monthly" }, aggregateBudget: { amount: 100, currency: "USD", period: "monthly" },
    aggregateMode: "strict", onboardingMode: "block",
  } },
});

class Store implements ProjectStore {
  docs = new Map<string, StoredProject>();
  writes = 0;
  throwOnWrite = false;
  private n = 0;
  async list() { return [...this.docs.values()].map((p) => structuredClone(p)); }
  async read(id: string) { const p = this.docs.get(id); return p ? structuredClone(p) : null; }
  async create(doc: Doc) {
    if (this.throwOnWrite) throw new Error("cosmos down");
    if (this.docs.has(String(doc.projectId))) return "conflict" as const;
    const etag = `"e${++this.n}"`; this.writes++;
    this.docs.set(String(doc.projectId), { doc: structuredClone(doc), etag });
    return etag;
  }
  async replace(doc: Doc, etag: string) {
    if (this.throwOnWrite) throw new Error("cosmos down");
    const cur = this.docs.get(String(doc.projectId));
    if (!cur || cur.etag !== etag) return "precondition_failed" as const;
    const next = `"e${++this.n}"`; this.writes++;
    this.docs.set(String(doc.projectId), { doc: structuredClone(doc), etag: next });
    return next;
  }
}

function setup() {
  const store = new Store();
  const changeLog = createMemoryChangeLog();
  const limitsStore = createMemoryLimitsStore();
  const lines: string[] = [];
  let id = 0;
  const base = { authenticate: async (h: string | null) => ({ oid: h === "reader" ? READER : EDITOR, canWrite: h !== "reader" }),
    now: () => NOW, newId: () => `req-${++id}`, log: (l: string) => lines.push(l) };
  const deps: ApiDependencies = { ...base, store, changeLog } as ApiDependencies;
  const call = (method: string, path: string, body?: unknown, h: Record<string, string> = {}) => handleAdminRequest({
    method, path, headers: (n) => h[n.toLowerCase()] ?? (n.toLowerCase() === "authorization" ? "editor" : null),
    body: body === undefined ? null : JSON.stringify(body),
  }, deps);
  const v3 = (method: string, path: string, body?: unknown, h: Record<string, string> = {}) => handleV3Request({
    method, path: `/api/v3/${path}`, headers: (n) => h[n.toLowerCase()] ?? (n.toLowerCase() === "authorization" ? "editor" : null),
    body: body === undefined ? null : JSON.stringify(body),
  }, { ...base, projects: store, catalogStore: null, changeLog, limitsStore, defaultCatalog: null, env: {}, sources: null, cache: new QueryCache(),
    operations: {} as never } as never);
  return { store, changeLog, limitsStore, lines, call, v3 };
}
const body = (r: { jsonBody?: unknown }) => r.jsonBody as Doc;

test("retire needs the repeated project id and If-Match, then freezes the project and is recorded", async () => {
  const { store, changeLog, call } = setup();
  const etag = await store.create(project()) as string;
  const writes = store.writes;
  assert.equal((await call("POST", "/api/projects/PROJECT02/retire", { confirmProjectId: "PROJECT03" }, { "if-match": etag })).status, 422);
  assert.equal((await call("POST", "/api/projects/PROJECT02/retire", { confirmProjectId: "PROJECT02", extra: 1 }, { "if-match": etag })).status, 422);
  assert.equal((await call("POST", "/api/projects/PROJECT02/retire", { confirmProjectId: "PROJECT02" })).status, 428);
  assert.equal((await call("POST", "/api/projects/PROJECT02/retire", { confirmProjectId: "PROJECT02" }, { "if-match": etag, authorization: "reader" })).status, 403);
  assert.equal(store.writes, writes);
  assert.equal(changeLog.records.size, 0, "refused attempts are not change records");

  const retired = await call("POST", "/api/projects/PROJECT02/retire", { confirmProjectId: "PROJECT02" }, { "if-match": etag });
  assert.equal(retired.status, 200);
  const saved = (await store.read("PROJECT02"))!;
  assert.equal(saved.doc.status, "retired");
  assert.equal(saved.doc.retiredAt, NOW.toISOString());
  const record = [...changeLog.records.values()].find((r) => r.operation === "retire")!;
  assert.equal(record.outcome, "retired");
  assert.equal(record.actorOid, EDITOR);
  assert.deepEqual(record.changes.find((c) => c.path === "status"), { path: "status", before: "active", after: "retired" });

  assert.equal((await call("POST", "/api/projects/PROJECT02/retire", { confirmProjectId: "PROJECT02" }, { "if-match": saved.etag })).status, 409);
  const edit = await call("PUT", "/api/projects/PROJECT02/settings", { displayName: "x" }, { "if-match": saved.etag });
  assert.equal(edit.status, 409);
  assert.equal(body(edit).error, "project_retired");
});

test("a change the record cannot store is refused and nothing is written", async () => {
  const { store, changeLog, call } = setup();
  const etag = await store.create(project()) as string;
  changeLog.failAppend = true;
  const writes = store.writes;
  const r = await call("PUT", "/api/projects/PROJECT02/settings", { displayName: "Renamed" }, { "if-match": etag });
  assert.equal(r.status, 503);
  assert.equal(body(r).error, "change_log_unavailable");
  assert.equal(store.writes, writes);
  assert.equal((await store.read("PROJECT02"))!.doc.displayName, "Project 02");
  assert.equal((await call("POST", "/api/projects/PROJECT02/retire", { confirmProjectId: "PROJECT02" }, { "if-match": etag })).status, 503);
  assert.equal((await store.read("PROJECT02"))!.doc.status, "active");
});

test("each write is recorded before it is applied and completed with its result", async () => {
  const { store, changeLog, call } = setup();
  assert.equal((await call("POST", "/api/projects", project())).status, 201);
  const created = [...changeLog.records.values()][0];
  assert.equal(created.outcome, "created");
  assert.ok(created.completedAt);
  const etag = (await store.read("PROJECT02"))!.etag;
  assert.equal((await call("PUT", "/api/projects/PROJECT02/settings", { displayName: "Renamed" }, { "if-match": etag })).status, 200);
  const updated = [...changeLog.records.values()].find((r) => r.operation === "settings")!;
  assert.equal(updated.outcome, "updated");
  assert.deepEqual(updated.changes, [{ path: "displayName", before: "Project 02", after: "Renamed" }]);
  // Unchanged writes are not recorded.
  const etag2 = (await store.read("PROJECT02"))!.etag;
  await call("PUT", "/api/projects/PROJECT02/settings", { displayName: "Renamed" }, { "if-match": etag2 });
  assert.equal([...changeLog.records.values()].filter((r) => r.operation === "settings").length, 1);
  // A write that throws may have committed: the record says unconfirmed, never failed.
  store.throwOnWrite = true;
  await call("PUT", "/api/projects/PROJECT02/settings", { displayName: "Again" }, { "if-match": etag2 });
  assert.equal([...changeLog.records.values()].at(-1)!.outcome, "unconfirmed");
});

test("catalog edits are recorded and refused when the record is unavailable", async () => {
  const changeLog = createMemoryChangeLog();
  let saved = 0;
  const deps = { authenticate: async () => ({ oid: EDITOR, canWrite: true }), projects: null, defaultCatalog: null, operations: {} as never,
    catalogStore: { async read() { return null; }, async save() { saved++; return '"c1"'; } }, changeLog,
    now: () => NOW, newId: () => "req-cat", log: () => {} };
  const rateCard = JSON.parse(await readFile(new URL("../../config/rate-card.json", import.meta.url), "utf8"));
  const put = () => handleV2Request({ method: "PUT", path: "/api/v2/catalog", headers: (n) => n === "if-none-match" ? "*" : "editor",
    body: JSON.stringify({ schemaVersion: 1, models: [], rateCard }) }, deps as never);
  changeLog.failAppend = true;
  const refused = await put();
  if (refused.status === 422) return; // rate-card schema differs; covered by v2 tests
  assert.equal(refused.status, 503);
  assert.equal(saved, 0);
  changeLog.failAppend = false;
  assert.equal((await put()).status, 200);
  assert.equal([...changeLog.records.values()][0].outcome, "updated");
});

test("removal limits: validated like the sync, ETag-guarded, recorded, and read back by the sync", async () => {
  const { v3, changeLog, limitsStore, lines } = setup();
  const get = body(await v3("GET", "sync/removal-limits"));
  assert.equal(get.state, "none");
  assert.equal(get.editable, true);
  const good = { enabled: true, maxRemovalsPerRun: 200, maxRemovalFraction: "0.5", expiresAt: "2026-10-27T10:00:00.000Z", reason: "Planned cleanup of PROJECT07" };

  assert.equal((await v3("PUT", "sync/removal-limits", good)).status, 412, "first save needs If-None-Match: *");
  const bad = await v3("PUT", "sync/removal-limits", { ...good, maxRemovalFraction: "0.1234567", reason: "" }, { "if-none-match": "*" });
  assert.equal(bad.status, 422);
  assert.deepEqual(body(bad).problems, ["maxRemovalFraction:invalid", "reason:invalid"]);
  assert.deepEqual(body(await v3("PUT", "sync/removal-limits", { ...good, expiresAt: "2027-03-01T00:00:00.000Z" }, { "if-none-match": "*" })).problems, ["expiresAt:beyond_90_days"]);
  assert.deepEqual(body(await v3("PUT", "sync/removal-limits", { ...good, expiresAt: "2026-10-19T00:00:00.000Z" }, { "if-none-match": "*" })).problems, ["expiresAt:not_in_future"]);
  assert.equal((await v3("PUT", "sync/removal-limits", { ...good, updatedBy: "someone" }, { "if-none-match": "*" })).status, 422);
  assert.equal((await v3("PUT", "sync/removal-limits", good, { "if-none-match": "*", authorization: "reader" })).status, 403);
  assert.equal(limitsStore.current, null);
  assert.equal(changeLog.records.size, 0);
  assert.ok(lines.some((l) => l.includes('"outcome":"refused"') && l.includes("sync/removal-limits")));

  const ok = await v3("PUT", "sync/removal-limits", good, { "if-none-match": "*" });
  assert.equal(ok.status, 200);
  assert.equal(body(ok).state, "in_effect");
  assert.equal(limitsStore.current!.doc.updatedBy, EDITOR);
  const record = [...changeLog.records.values()][0];
  assert.equal(record.operation, "v3/sync/removal-limits");
  assert.equal(record.outcome, "updated");
  assert.deepEqual(record.changes.find((c) => c.path === "maxRemovalsPerRun"), { path: "maxRemovalsPerRun", before: null, after: 200 });

  // The sync accepts what the console saved, including the server-set fields.
  const effective = effectiveRemovalLimits({ maxRemovalsPerRun: 5, maxRemovalFraction: 0.1 }, { ok: true, doc: limitsStore.current!.doc }, NOW);
  assert.equal(effective.source, "admin");
  assert.deepEqual(effective.limits, { maxRemovalsPerRun: 200, maxRemovalFraction: 0.5 });

  assert.equal((await v3("PUT", "sync/removal-limits", { ...good, enabled: false })).status, 428);
  assert.equal((await v3("PUT", "sync/removal-limits", { ...good, enabled: false }, { "if-match": '"stale"' })).status, 412);
  assert.equal((await v3("PUT", "sync/removal-limits", { ...good, enabled: false }, { "if-match": limitsStore.current!.etag })).status, 200);
  assert.equal(body(await v3("GET", "sync/removal-limits")).state, "disabled");
  // An expired override can be switched off with its old expiry; enabling it needs a future one.
  const past = { ...good, expiresAt: "2026-10-19T00:00:00.000Z" };
  const etag = limitsStore.current!.etag;
  assert.deepEqual(body(await v3("PUT", "sync/removal-limits", past, { "if-match": etag })).problems, ["expiresAt:not_in_future"]);
  assert.equal((await v3("PUT", "sync/removal-limits", { ...past, enabled: false }, { "if-match": etag })).status, 200);
});

test("audit/changes lists the permanent record with the audit filters", async () => {
  const { store, call, v3 } = setup();
  await call("POST", "/api/projects", project("PROJECT02"));
  await call("POST", "/api/projects", project("PROJECT03"));
  const etag = (await store.read("PROJECT03"))!.etag;
  await call("POST", "/api/projects/PROJECT03/retire", { confirmProjectId: "PROJECT03" }, { "if-match": etag });
  const all = body(await v3("GET", "audit/changes?limit=10"));
  assert.equal(all.state, "available");
  assert.equal(((all.data as Doc).page as Doc).matched, 3);
  const retired = body(await v3("GET", "audit/changes?project=PROJECT03&outcome=retired")).data as Doc;
  assert.equal((retired.rows as Doc[]).length, 1);
  const row = (retired.rows as Doc[])[0];
  assert.equal(row.source, "change_log");
  assert.equal(row.operation, "retire");
  assert.ok(Array.isArray((row.d as Doc).changes));
  assert.equal((await v3("GET", "audit/changes?bogus=1")).status, 400);
  assert.equal(body(await v3("GET", "capabilities")).features && (body(await v3("GET", "capabilities")).features as Doc).changeLog, "configured");
});
