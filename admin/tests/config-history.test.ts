import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createConfigHistory, withConfigHistory } from "../src/config-history.ts";
import { createMemoryConfigHistoryStore, configSnapshot, ConfigHistoryUnavailable, HISTORY_ACTIONS, historyScope } from "../src/config-history-store.ts";
import { createMemoryChangeLog } from "../src/change-log.ts";
import { createMemoryRegistryStore } from "../src/backend-routing.ts";
import type { ProjectStore, StoredProject } from "../src/api.ts";
import { canonical } from "../src/validation.ts";
import type { Doc } from "../src/validation.ts";

const actor = { oid: "00000000-0000-4000-8000-0000000000e1", canWrite: true };
const limit = { tokensPerMinute: 100, tokenQuota: 1000, tokenQuotaPeriod: "Monthly" };
const project = (): Doc => ({
  id: "PROJECT02", projectId: "PROJECT02", displayName: "Original", status: "active", backendId: "foundry-a",
  designatedSubscriptionId: "00000000-0000-4000-8000-0000000000b1", supersedes: null, retiredAt: null,
  classifications: { STD: {
    groupId: "00000000-0000-4000-8000-0000000000c1", classificationGroupDisplayName: "PROJECT02-STD",
    familyPolicy: { aggregateLimits: { person: limit, group: limit },
      families: { haiku: { models: ["claude-haiku-4-5"], person: limit, group: limit } } },
    personBudget: { amount: 10, currency: "USD", period: "monthly" }, aggregateBudget: null,
    aggregateMode: "strict", onboardingMode: "block",
  } },
});
class Projects implements ProjectStore {
  current: StoredProject = { doc: project(), etag: '"1"' };
  writes = 0;
  race = false;
  async list() { return [structuredClone(this.current)]; }
  async read(id: string) { return id === this.current.doc.projectId ? structuredClone(this.current) : null; }
  async create(doc: Doc) { this.current = { doc: structuredClone(doc), etag: '"created"' }; return this.current.etag; }
  async replace(doc: Doc, etag: string) {
    if (this.race || etag !== this.current.etag) return "precondition_failed";
    this.current = { doc: structuredClone(doc), etag: `"${++this.writes + 1}"` };
    return this.current.etag;
  }
}
function setup() {
  const projects = new Projects(), versions = createMemoryConfigHistoryStore(), changeLog = createMemoryChangeLog();
  const registry = createMemoryRegistryStore();
  const logs: Doc[] = [];
  let n = 0;
  const deps = { enabled: true, projects, versions, registry, changeLog, scope: "/dbs/ccof/colls/adminConfig", projectScope: "/dbs/ccof/colls/projects",
    now: () => new Date("2026-11-19T12:00:00Z"), newId: () => `history-${++n}`, log: (s: string) => logs.push(JSON.parse(s)) };
  return { projects, versions, changeLog, registry, logs, deps, api: createConfigHistory(deps) };
}
async function target(s: ReturnType<typeof setup>, edit: (d: Doc) => void = (d) => { d.displayName = "Restored"; }) {
  const d = project(); edit(d);
  const v = configSnapshot(d, s.deps.now());
  await s.versions.create(v);
  return v.id;
}
const request = (version: string, extra = {}) => ({ projectId: "PROJECT02", version, ifMatch: '"1"', reason: " Recover reviewed settings ", actor, ...extra });

test("content-addressed immutable versions exclude provider, retirement, usage and nested system data", async () => {
  const s = setup(), d = project();
  d._etag = "secret"; d.usage = { spend: 123 }; d.status = "retired"; d.retiredAt = "2026-10-01";
  d.failover = { enabled: false, fallbackBackendIds: [], revision: 99, active: { secret: true } };
  const c = (d.classifications as Doc).STD as Doc;
  c.audit = { secret: true }; (c.personBudget as Doc)._etag = "secret";
  const a = configSnapshot(d, s.deps.now()), b = configSnapshot({ ...d, _etag: "other", usage: 999 }, new Date());
  assert.equal(a.id, b.id);
  assert.equal(JSON.stringify(a).includes("secret"), false);
  assert.equal(Object.hasOwn(a.config, "status"), false);
  assert.equal(Object.hasOwn(a.config, "usage"), false);
  await s.versions.create(a); await s.versions.create(b);
  assert.equal((await s.versions.list("PROJECT02", 20)).length, 1);
  const read = await s.api.read("PROJECT02", a.id);
  read.config.displayName = "tampered local";
  assert.equal((await s.api.read("PROJECT02", a.id)).config.displayName, "Original");
});

test("preview is nonmutating and restore requires write-ahead log and baseline plus new version before CAS", async () => {
  const s = setup(), version = await target(s);
  const preview = await s.api.preview(request(version));
  assert.equal(preview.reason, "Recover reviewed settings");
  assert.deepEqual(preview.changes, [{ path: "displayName", before: "Original", after: "Restored" }]);
  assert.equal(s.projects.writes, 0);
  const replace = s.projects.replace.bind(s.projects);
  s.projects.replace = async (doc, etag) => {
    assert.equal([...s.changeLog.records.values()][0].outcome, "pending");
    const rows = await s.versions.list("PROJECT02", 20);
    assert.equal(rows.length, 2);
    return replace(doc, etag);
  };
  const result = await s.api.restore(request(version));
  assert.deepEqual(result.changes, preview.changes);
  assert.equal(s.projects.current.doc.displayName, "Restored");
  assert.equal([...s.changeLog.records.values()][0].details.reason, preview.reason);
  assert.equal(s.logs.at(-1)?.actorOid, actor.oid);
});

test("stale etag, racing CAS, retirement and permission refusal never overwrite current data", async () => {
  for (const kind of ["stale", "race", "retired", "reader", "actor"] as const) {
    const s = setup(), version = await target(s);
    if (kind === "race") s.projects.race = true;
    if (kind === "retired") { s.projects.current.doc.status = "retired"; s.projects.current.doc.retiredAt = "2026-11-19"; }
    const args = request(version, kind === "stale" ? { ifMatch: '"old"' } :
      kind === "reader" ? { actor: { ...actor, canWrite: false } } : kind === "actor" ? { actor: null } : {});
    await assert.rejects(() => s.api.restore(args), (e: any) => e.status === (kind === "retired" ? 409 : kind === "reader" || kind === "actor" ? 403 : 412));
    assert.equal(s.projects.writes, 0);
    if (kind === "race") assert.equal([...s.changeLog.records.values()][0].outcome, "refused");
  }
});

test("missing mandatory log, unavailable history, invalid reason, snapshot tampering and foreign identity fail closed", async () => {
  for (const kind of ["log", "history", "reason", "tamper", "foreign", "identity", "groups", "classifications"] as const) {
    const s = setup(), version = await target(s, (d) => {
      const c = (d.classifications as Doc).STD as Doc;
      if (kind === "groups") c.groupId = "00000000-0000-4000-8000-0000000000c2";
      else if (kind === "classifications") (d.classifications as Doc).EXTRA = { ...structuredClone(c), groupId: "00000000-0000-4000-8000-0000000000c2" };
    });
    if (kind === "log") s.changeLog.failAppend = true;
    if (kind === "history") s.versions.create = async () => { throw new Error("forbidden document content"); };
    if (["tamper", "foreign", "identity"].includes(kind)) {
      const original = s.versions.read.bind(s.versions);
      s.versions.read = async (id, v) => {
        const row = (await original(id, v))!;
        if (kind === "foreign") row.projectId = "OTHER";
        else if (kind === "identity") row.config.projectId = "OTHER";
        else row.config.displayName = "corruption";
        return row;
      };
    }
    await assert.rejects(() => s.api.restore(request(version, kind === "reason" ? { reason: "x".repeat(501) } : {})));
    assert.equal(s.projects.writes, 0);
  }
});

test("restore rejects self-consistently hashed invalid budget/model snapshots, not only hash corruption", async () => {
  for (const kind of ["budget", "model"] as const) {
    const s = setup(), v = structuredClone(configSnapshot(project(), s.deps.now()));
    const c = (v.config.classifications as Doc).STD as Doc;
    if (kind === "budget") (c.personBudget as Doc).amount = -1;
    else ((c.familyPolicy as Doc).families as Doc).haiku = { models: [], person: limit, group: limit };
    v.hash = createHash("sha256").update(canonical({ schema: 1, config: v.config })).digest("hex");
    v.id = `config:${v.hash}`;
    s.versions.read = async () => structuredClone(v);
    await assert.rejects(() => s.api.restore(request(v.id)), (e: any) => e.code === "history_snapshot_invalid");
    assert.equal(s.projects.writes, 0);
    assert.equal(s.changeLog.records.size, 0);
  }
});

test("all writes through wrapper capture unchanged baseline and new configs; optional failure stays local", async () => {
  const s = setup(), failures: unknown[] = [];
  const wrapped = withConfigHistory(s.projects, { enabled: true, versions: s.versions, now: s.deps.now, onUnavailable: (e) => failures.push(e), scope: s.deps.scope, projectScope: "projects-scope" });
  const d = project(); d.displayName = "Edited";
  await wrapped.replace(d, '"1"');
  assert.equal((await s.versions.list("PROJECT02", 20)).length, 2);
  s.versions.create = async () => { throw Object.assign(new Error("denied"), { code: 403 }); };
  d.displayName = "Still editable";
  await wrapped.replace(d, s.projects.current.etag);
  assert.equal(s.projects.current.doc.displayName, "Still editable");
  assert.ok(failures.length > 0);
  const failure = failures[0] as any;
  assert.equal(failure.required[0].action, "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create");
  assert.equal(failure.required[0].scope, s.deps.scope);
  const off = withConfigHistory(s.projects, { enabled: false, versions: s.versions, now: s.deps.now, onUnavailable: () => { throw Error("not called"); }, scope: s.deps.scope, projectScope: "projects-scope" });
  await off.create(project());
});

test("list/read are project bounded and feature disabled does no I/O", async () => {
  const s = setup(), v = await target(s);
  assert.equal((await s.api.list("PROJECT02")).length, 1);
  assert.equal((await s.api.list("OTHER")).length, 0);
  await assert.rejects(() => s.api.read("OTHER", v), (e: any) => e.status === 404);
  assert.equal(historyScope("PROJECT02"), "history:PROJECT02");
  const off = createConfigHistory({ ...s.deps, enabled: false });
  await assert.rejects(() => off.restore(request(v)), (e: any) => e.status === 404);
  assert.equal(s.projects.writes, 0);
});

test("restoring desired routing uses current revision, preserves current active and demands fresh publication", async () => {
  const s = setup();
  for (const id of ["foundry-a", "foundry-b"]) await s.registry.save({
    backendId: id, displayName: id, url: `https://${id}.services.ai.azure.com/anthropic`,
    deployments: ["claude-haiku-4-5"], inferenceGeo: "global", status: "active",
    circuitBreaker: id === "foundry-a" ? { enabled: true, failureCount: 3, failureIntervalSeconds: 60, tripDurationSeconds: 60,
      statusCodeRanges: [{ min: 429, max: 429 }], acceptRetryAfter: true } : null,
  }, null);
  const active = { revision: 12, poolBackendId: "ccof-pool-project02-r12", verifiedAt: "2026-11-18T12:00:00Z" };
  s.projects.current.doc.failover = { enabled: true, fallbackBackendIds: ["foundry-b"], revision: 12, active };
  const v = await target(s, (d) => { d.failover = { enabled: true, fallbackBackendIds: ["foundry-b"], revision: 1, active: { stolen: true } }; });
  await s.api.restore(request(v));
  const f = s.projects.current.doc.failover as Doc;
  assert.equal(f.revision, 13);
  assert.deepEqual(f.active, active);
  assert.notEqual((f.active as Doc).revision, f.revision);
});

test("primary change while current failover enabled is rejected even when target disables it", async () => {
  const s = setup();
  s.projects.current.doc.failover = { enabled: true, fallbackBackendIds: ["foundry-b"], revision: 3, active: null };
  const v = await target(s, (d) => { d.backendId = "foundry-c"; });
  await assert.rejects(() => s.api.restore(request(v)), (e: any) => e.problems.includes("backendId:disable_failover_first"));
  assert.equal(s.projects.writes, 0);
});

test("restore leaves current usage/spend/audit/counters untouched at every configuration level", async () => {
  const s = setup(), version = await target(s, (d) => {
    ((d.classifications as Doc).STD as Doc).personBudget = { amount: 25, currency: "USD", period: "monthly" };
  });
  s.projects.current.doc.usage = { spend: 400 };
  s.projects.current.doc.audit = ["current-only"];
  const c = (s.projects.current.doc.classifications as Doc).STD as Doc;
  c.counters = { members: 42 };
  (c.personBudget as Doc).spend = 123;
  (c.familyPolicy as Doc).usage = { tokens: 900 };
  await s.api.restore(request(version));
  assert.deepEqual(s.projects.current.doc.usage, { spend: 400 });
  assert.deepEqual(s.projects.current.doc.audit, ["current-only"]);
  const next = (s.projects.current.doc.classifications as Doc).STD as Doc;
  assert.deepEqual(next.counters, { members: 42 });
  assert.equal((next.personBudget as Doc).spend, 123);
  assert.deepEqual((next.familyPolicy as Doc).usage, { tokens: 900 });
  assert.equal((next.personBudget as Doc).amount, 25);
});

test("mandatory audit failure reports exact action/scope and records no config mutation", async () => {
  for (const absent of [false, true]) {
    const s = setup(), version = await target(s);
    s.changeLog.failAppend = true;
    const api = absent ? createConfigHistory({ ...s.deps, changeLog: null }) : s.api;
    await assert.rejects(() => api.restore(request(version)), (e: any) =>
      e.code === "change_log_unavailable" && e.required[0].action.endsWith("/items/create") && e.required[0].scope === s.deps.scope);
    assert.equal(s.projects.writes, 0);
  }
});

test("snapshot write refusal is local, fail-closed for restore and identifies data action", async () => {
  const s = setup(), version = await target(s);
  s.versions.create = async () => { throw Object.assign(new Error("provider secret"), { code: 403 }); };
  await assert.rejects(() => s.api.restore(request(version)), (e: any) =>
    e.code === "history_unavailable" && !e.message.includes("secret") &&
    e.required[0].action.endsWith("/items/create") && e.required[0].scope === s.deps.scope);
  assert.equal([...s.changeLog.records.values()][0].outcome, "refused");
  assert.equal(s.projects.writes, 0);
});

test("retry of committed restore with original ETag is refused deterministically, no duplicate versions", async () => {
  const s = setup(), version = await target(s);
  const first = await s.api.restore(request(version));
  await assert.rejects(() => s.api.restore(request(version)), (e: any) => e.status === 412);
  assert.equal((await s.versions.list("PROJECT02", 20)).length, 2);
  assert.equal(first.recordedVersion, version);
  assert.equal(s.projects.writes, 1);
});

test("optional capture validation/diagnostic failures cannot turn an already committed old create into failure", async () => {
  const s = setup(), failures: any[] = [];
  const wrapped = withConfigHistory(s.projects, { enabled: true, versions: s.versions, scope: s.deps.scope, projectScope: "projects-scope", now: s.deps.now,
    onUnavailable: (e) => { failures.push(e); throw new Error("diagnostic unavailable"); } });
  const d = project(); delete d.displayName;
  assert.equal(await wrapped.create(d), '"created"');
  assert.equal(failures[0].required[0].action.endsWith("/items/create"), true);
  assert.equal(failures[0].required[0].scope, s.deps.scope);
});

test("failed baseline read is local to optional history and does not change original replacement behavior", async () => {
  const s = setup(), failures: any[] = [];
  s.projects.read = async () => { throw new Error("project provider secret"); };
  const wrapped = withConfigHistory(s.projects, { enabled: true, versions: s.versions, scope: s.deps.scope, projectScope: "projects-scope", now: s.deps.now,
    onUnavailable: (e) => failures.push(e) });
  const d = project(); d.displayName = "Edit still works";
  await wrapped.replace(d, '"1"');
  assert.equal(s.projects.current.doc.displayName, "Edit still works");
  assert.equal(failures[0].required[0].action.endsWith("/items/read"), true);
  assert.equal(failures[0].required[0].scope, "projects-scope");
});

test("disabled desired routing needs no optional registry read; primary change forgets obsolete verification", async () => {
  const s = setup();
  s.projects.current.doc.failover = { enabled: false, fallbackBackendIds: ["foundry-b"], revision: 8,
    active: { revision: 7, poolBackendId: "ccof-pool-project02-r7", verifiedAt: "2026-11-18T12:00:00Z" } };
  s.registry.list = async () => { throw new Error("registry unavailable"); };
  const v = await target(s, (d) => { d.backendId = "foundry-c"; });
  const result = await s.api.restore(request(v));
  assert.equal(result.requiresPublication, false);
  const next = s.projects.current.doc.failover as Doc;
  assert.ok(Number(next.revision) > 8);
  assert.equal(next.active, null);
  assert.equal(next.enabled, false);
});

test("unconfigured history reports the exact requested operation action independently", async () => {
  const s = setup(), api = createConfigHistory({ ...s.deps, versions: null });
  for (const [run, action] of [
    [() => api.capture(project()), "create"],
    [() => api.list("PROJECT02"), "executeQuery"],
    [() => api.read("PROJECT02", `config:${"0".repeat(64)}`), "read"],
  ] as const) {
    await assert.rejects(run, (e: any) => e.status === 503 && e.requirements[0].action.endsWith(`/${action}`));
  }
});

test("restore returns exactly the committed project/ETag and preserves parent request correlation", async () => {
  const s = setup(), version = await target(s);
  const result = await s.api.restore({ ...request(version), requestId: "parent-request-42" });
  assert.deepEqual(result.project, s.projects.current.doc);
  assert.equal(result.etag, s.projects.current.etag);
  assert.equal([...s.changeLog.records.values()][0].requestId, "parent-request-42");
  assert.equal(s.logs.at(-1)?.requestId, "parent-request-42");
});

test("history capability proves optional access but reports project read/replace as unprobed prerequisites", async () => {
  const s = setup();
  let probes = 0;
  s.versions.probe = async () => { ++probes; };
  const c = await s.api.capability();
  assert.equal(c.state, "available");
  assert.equal(probes, 1);
  assert.deepEqual(c.requirements, []);
  assert.deepEqual(c.prerequisites, [
    { action: HISTORY_ACTIONS.read, scope: s.deps.projectScope },
    { action: "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace", scope: s.deps.projectScope },
  ]);
  assert.equal(s.projects.writes, 0);
  assert.equal(s.changeLog.records.size, 0);
  assert.equal((await s.versions.list("PROJECT02", 20)).length, 0);
});

test("capability isolates disabled, missing-log, permission-denied and unavailable states without project writes", async () => {
  const s = setup();
  let probes = 0;
  s.versions.probe = async () => { ++probes; throw new ConfigHistoryUnavailable(HISTORY_ACTIONS.create, s.deps.scope, "history_unavailable", true); };
  assert.equal((await createConfigHistory({ ...s.deps, enabled: false }).capability()).state, "disabled");
  assert.equal(probes, 0);
  assert.equal((await createConfigHistory({ ...s.deps, changeLog: null }).capability()).reason, "change_log_unavailable");
  assert.equal(probes, 0);
  const denied = await s.api.capability();
  assert.equal(denied.state, "permission_required");
  assert.deepEqual(denied.requirements, [{ action: HISTORY_ACTIONS.create, scope: s.deps.scope }]);
  s.versions.probe = async () => { throw new Error("provider secret"); };
  const down = await s.api.capability();
  assert.equal(down.state, "unavailable");
  assert.equal(JSON.stringify(down).includes("secret"), false);
  assert.equal(s.projects.writes, 0);
});
