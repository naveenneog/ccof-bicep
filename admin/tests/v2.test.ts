import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { BUDGET_PAGE_DEFAULT, BUDGET_PAGE_MAX, handleV2Request, MAX_CATALOG_BYTES, pageGroupBudgets, readBudgetQuery, summarizeGroupBudgets, validateCatalog, validateRateHistory } from "../src/v2.ts";
import type { CatalogStore, V2Dependencies } from "../src/v2.ts";
import type { Doc } from "../src/validation.ts";
import type { Capability, Operations } from "../src/operations.ts";

const rateCard: unknown = JSON.parse(await readFile(new URL("../../config/rate-card.json", import.meta.url), "utf8"));
const baseline: Doc = { schemaVersion: 1, rateCard, models: [{ model: "claude-sonnet-5", deployment: "claude-sonnet-5", family: "sonnet", backendId: "" }] };
const disabled = async (): Promise<Capability> => ({ state: "disabled", reason: "not_configured", observedAt: "2026-10-16T00:00:00Z" });
const operations: Operations = { groups: disabled, inventory: disabled, deployments: disabled, logs: disabled, health: disabled, retail: disabled, billed: disabled };
function setup() {
  let saved: { doc: Doc; etag: string } | null = null;
  const catalogStore: CatalogStore = {
    async read() { return saved ? structuredClone(saved) : null; },
    async save(doc, etag) { if (saved && saved.etag !== etag) return null; saved = { doc: structuredClone(doc), etag: `"catalog-${Date.now()}"` }; return saved.etag; },
  };
  const lines: string[] = [];
  const deps: V2Dependencies = {
    authenticate: async () => ({ oid: "editor-id", canWrite: true }), projects: null,
    catalogStore, defaultCatalog: baseline, operations, now: () => new Date(), newId: () => "request-1", log: (line) => lines.push(line),
  };
  const call = (path: string, method = "GET", body?: unknown, headers: Record<string, string> = {}) => handleV2Request({
    method, path: `/api/v2/${path}`, body: body === undefined ? null : JSON.stringify(body), headers: (name) => headers[name] ?? null,
  }, deps);
  return { deps, call, lines };
}
test("v2 fails closed and optional capabilities are independently disabled", async () => {
  const { deps, call } = setup();
  assert.equal((await call("groups?q=Payment")).status, 200);
  assert.equal(((await call("groups?q=Payment")).jsonBody as Capability).state, "disabled");
  assert.equal(((await call("version")).jsonBody as Doc).version, "3.2.0");
  deps.authenticate = null;
  assert.equal((await call("catalog")).status, 503);
});
test("catalog default remains readable without optional store; saves disabled", async () => {
  const { deps, call } = setup();
  deps.catalogStore = null;
  const r = await call("catalog");
  assert.equal((r.jsonBody as Doc).source, "packaged_rate_card");
  assert.equal((r.jsonBody as Doc).editable, false);
  assert.equal((await call("catalog", "PUT", baseline)).status, 503);
});
test("catalog creation requires If-None-Match and subsequent saves require exact ETag", async () => {
  const { call, lines } = setup();
  assert.equal((await call("catalog", "PUT", baseline)).status, 412);
  const created = await call("catalog", "PUT", baseline, { "if-none-match": "*" });
  assert.equal(created.status, 200);
  assert.equal((await call("catalog", "PUT", baseline)).status, 428);
  assert.equal((await call("catalog", "PUT", baseline, { "if-match": '"stale"' })).status, 412);
  assert.equal((await call("catalog", "PUT", baseline, { "if-match": created.headers?.etag ?? "" })).status, 200);
  assert(lines.some((line) => JSON.parse(line).operation === "v2/catalog"));
});
test("reader cannot edit cost definitions", async () => {
  const { deps, call } = setup();
  deps.authenticate = async () => ({ oid: "reader", canWrite: false });
  assert.equal((await call("catalog", "PUT", baseline)).status, 403);
  assert.equal((await call("catalog")).status, 200);
});
test("cost catalog has an independent bounded 1 MiB limit", async () => {
  const { call } = setup();
  const r = await call("catalog", "PUT", { padding: "x".repeat(MAX_CATALOG_BYTES) }, { "if-none-match": "*" });
  assert.equal(r.status, 413);
});
test("catalog validates rates, duplicate deployments and supported mapping shape", () => {
  assert.doesNotThrow(() => validateCatalog(baseline));
  assert.throws(() => validateCatalog({ ...baseline, rateCard: {} }), /invalid_rate_card/);
  assert.throws(() => validateCatalog({ ...baseline, models: [...baseline.models as unknown[], ...baseline.models as unknown[]] }), /duplicate_deployment_mapping/);
});
test("historical rate edits require a new version and preserve original prices", () => {
  const before = structuredClone(rateCard) as Doc;
  const changed = structuredClone(before);
  changed.notes = ["changed"];
  assert.throws(() => validateRateHistory(before, changed), /version_must_change/);
  changed.version = "new-version";
  const entry = (changed.entries as Doc[])[0];
  entry.model = "changed-model";
  assert.throws(() => validateRateHistory(before, changed), /historical_rate_edit_forbidden/);
});
test("paged project listing preserves query values and never calls unbounded legacy list", async () => {
  const { deps, call } = setup();
  const seen: unknown[] = [];
  deps.projects = {
    list: async () => { throw new Error("unbounded"); }, read: async () => null, create: async () => "etag", replace: async () => "etag",
    listPage: async (query) => { seen.push(query); return { items: [], cursor: "next" }; },
  };
  const r = await call("projects?search=Pay&tag=team%3Afinance&backendId=backend1&limit=25");
  assert.equal(r.status, 200);
  assert.equal((r.jsonBody as Doc).cursor, "next");
  assert.deepEqual(seen[0], { search: "Pay", tag: "team:finance", backendId: "backend1", limit: 25, cursor: undefined });
  assert.equal((await call("projects?limit=10000")).status, 400);
});

const NOW = new Date("2026-10-16T12:00:00Z");
const groupRow = (over: Doc = {}): Doc => ({
  scope: "group", scopeId: "P1:STD", projectId: "P1", classification: "STD", spentCcu: "1500.25", budgetCcu: "2000",
  exhausted: false, mode: "strict", completeness: "complete", activeMemberCount: 4, rateCardVersion: "2026-10-11",
  period: "2026-10", computedAt: "2026-10-16T11:00:00Z", validUntil: "2026-10-16T13:00:00Z", ...over,
});
test("group budget roll-up is exact: 100 CCU = USD 1, percent, remaining and totals across groups", () => {
  const out = summarizeGroupBudgets([
    groupRow(),
    groupRow({ scopeId: "P2:PRM", projectId: "P2", classification: "PRM", spentCcu: "0.0002", budgetCcu: null }),
    groupRow({ scopeId: "P3:CYB", projectId: "P3", classification: "CYB", spentCcu: "2500", budgetCcu: "2000", exhausted: true }),
  ], NOW);
  const groups = out.groups as Doc[];
  const p1 = groups.find((g) => g.projectId === "P1")!;
  assert.equal(p1.spentUsd, "15.00");
  assert.equal(p1.budgetUsd, "20.00");
  assert.equal(p1.remainingCcu, "499.75");
  assert.equal(p1.usedPercent, "75.0");
  assert.equal(p1.fresh, true);
  assert.equal(groups[0].projectId, "P3", "highest utilisation sorts first");
  assert.equal(groups[0].remainingCcu, "-500", "overspend is shown, not clamped");
  const uncapped = groups.find((g) => g.projectId === "P2")!;
  assert.equal(uncapped.usedPercent, null);
  assert.equal(uncapped.remainingCcu, null);
  const totals = out.totals as Doc;
  assert.equal(totals.spentCcu, "4000.2502");
  assert.equal(totals.cappedBudgetCcu, "4000");
  assert.equal(totals.cappedUsedPercent, "100.0");
  assert.equal(totals.uncappedGroups, 1);
  assert.equal(totals.exhaustedGroups, 1);
  assert.equal(totals.lowerBound, false);
});
test("partial, stale and malformed budget observations make totals a lower bound, never zero-filled", () => {
  const out = summarizeGroupBudgets([
    groupRow({ completeness: "partial" }),
    groupRow({ scopeId: "P2:STD", projectId: "P2", validUntil: "2026-10-16T11:30:00Z" }),
    groupRow({ scopeId: "P3:STD", projectId: "P3", spentCcu: 12 }),
    groupRow({ scope: "person" }),
  ], NOW);
  const totals = out.totals as Doc;
  assert.equal(totals.groups, 2);
  assert.equal(totals.partialGroups, 1);
  assert.equal(totals.staleGroups, 1);
  assert.equal(totals.rejectedRows, 2);
  assert.equal(totals.lowerBound, true);
});
test("budgets endpoint returns the roll-up; a denied workspace stays a scoped permission state", async () => {
  const { deps, call } = setup();
  deps.now = () => NOW;
  deps.operations = { ...operations, logs: async () => ({ state: "available", observedAt: NOW.toISOString(), data: [groupRow()] }) };
  const ok = (await call("budgets")).jsonBody as Capability;
  assert.equal(ok.state, "available");
  assert.equal(((ok.data as Doc).totals as Doc).spentUsd, "15.00");
  deps.operations = { ...operations, logs: async () => ({ state: "permission_required", reason: "upstream_403", permission: "Log Analytics Reader", observedAt: NOW.toISOString() }) };
  const denied = await call("budgets");
  assert.equal(denied.status, 200);
  assert.equal((denied.jsonBody as Capability).state, "permission_required");
  assert.equal((await call("version")).status, 200, "other features keep working");
});
test("a missing packaged rate card degrades only cost definitions; other features and saves continue", async () => {
  const { deps, call } = setup();
  deps.defaultCatalog = null;
  const catalog = await call("catalog");
  assert.equal(catalog.status, 200);
  assert.equal((catalog.jsonBody as Capability).state, "unavailable");
  assert.equal((catalog.jsonBody as Capability).reason, "packaged_rate_card_unavailable");
  assert.equal((await call("groups?q=Payment")).status, 200);
  assert.equal((await call("version")).status, 200);
  const saved = await call("catalog", "PUT", baseline, { "if-none-match": "*" });
  assert.equal(saved.status, 200, "an editor can still save a first catalog");
});
test("budgets endpoint pages and filters on the server; totals still cover every group", async () => {
  const { deps, call } = setup();
  deps.now = () => NOW;
  const rows = Array.from({ length: 250 }, (_, i) => groupRow({ scopeId: `P${i}:STD`, projectId: `P${i}`, spentCcu: String(i * 10), budgetCcu: "2000" }));
  deps.operations = { ...operations, logs: async () => ({ state: "available", observedAt: NOW.toISOString(), data: rows }) };
  const first = ((await call("budgets")).jsonBody as Capability).data as Doc;
  assert.equal((first.groups as Doc[]).length, BUDGET_PAGE_DEFAULT, "default page, never every group");
  assert.deepEqual(first.page, { offset: 0, limit: 100, returned: 100, matched: 250, total: 250, nextOffset: 100 });
  assert.equal((first.totals as Doc).groups, 250, "totals cover every group, not the page");
  const last = ((await call("budgets?offset=200&limit=100")).jsonBody as Capability).data as Doc;
  assert.equal((last.page as Doc).returned, 50);
  assert.equal((last.page as Doc).nextOffset, null);
  const hot = ((await call("budgets?minUsedPercent=90")).jsonBody as Capability).data as Doc;
  assert.ok((hot.groups as Doc[]).every((g) => Number(g.usedPercent) >= 90));
  assert.equal((hot.page as Doc).matched, 70, "spent 1800..2490 of 2000");
  const one = ((await call("budgets?projectId=P7")).jsonBody as Capability).data as Doc;
  assert.deepEqual((one.groups as Doc[]).map((g) => g.projectId), ["P7"], "exact project match, not P70..P79");
  for (const bad of ["limit=0", `limit=${BUDGET_PAGE_MAX + 1}`, "offset=-1", "limit=1.5", "minUsedPercent=abc", `search=${"x".repeat(101)}`]) {
    const r = await call(`budgets?${bad}`);
    assert.equal(r.status, 400, bad);
    assert.equal((r.jsonBody as Doc).error, "invalid_budget_query");
  }
});
test("attention filter keeps exhausted, stale and partial groups only", () => {
  const summary = summarizeGroupBudgets([
    groupRow(), groupRow({ scopeId: "P2:STD", projectId: "P2", exhausted: true }),
    groupRow({ scopeId: "P3:STD", projectId: "P3", validUntil: "2026-10-16T11:00:00Z" }), groupRow({ scopeId: "P4:STD", projectId: "P4", completeness: "partial" }),
  ], NOW);
  const page = pageGroupBudgets(summary, readBudgetQuery(new URLSearchParams("attention=true")));
  assert.deepEqual((page.groups as Doc[]).map((g) => g.projectId).sort(), ["P2", "P3", "P4"]);
});
test("scale: 30,000 access groups roll up and page server-side within a bounded response", () => {
  const rows = Array.from({ length: 30000 }, (_, i) => groupRow({
    scopeId: `PRJ${i}:STD`, projectId: `PRJ${String(i).padStart(5, "0")}`, spentCcu: `${i % 3000}.25`, budgetCcu: i % 7 === 0 ? null : "2500",
  }));
  const started = performance.now();
  const summary = summarizeGroupBudgets(rows, NOW);
  const page = pageGroupBudgets(summary, readBudgetQuery(new URLSearchParams("limit=100&minUsedPercent=80")));
  const elapsed = performance.now() - started;
  assert.equal((summary.totals as Doc).groups, 30000);
  assert.equal((page.groups as Doc[]).length, 100);
  assert.ok(Buffer.byteLength(JSON.stringify(page.groups)) < 100_000, "one page stays well under 100 KB");
  assert.ok(elapsed < 5000, `30K roll-up + page took ${elapsed.toFixed(0)} ms`);
});