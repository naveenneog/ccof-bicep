import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { handleV3Request, planFromRequest } from "../src/v3.ts";
import type { V3Dependencies } from "../src/v3.ts";
import { QueryCache, ROW_PAGE_MAX, readChargebackFilters, readSnapshotFilters, readAuditFilters, shapeRun, shapeSnapshot, buildAuditQuery } from "../src/chargeback.ts";
import { ProviderError } from "../src/operations.ts";
import type { Capability, LogTable, Operations, QueryMeta } from "../src/operations.ts";
import type { CatalogStore } from "../src/v2.ts";
import type { Doc } from "../src/validation.ts";
import { ApiError } from "../src/auth.ts";
import { reviewRateCard } from "../src/rate-cards.ts";

const rateCard = JSON.parse(await readFile(new URL("../../config/rate-card.json", import.meta.url), "utf8")) as Doc;
const sources = {
  ledger: await readFile(new URL("../../analytics/ledger.kql", import.meta.url), "utf8"),
  pricing: await readFile(new URL("../../analytics/workbooks/pricing.kql", import.meta.url), "utf8"),
  budgets: await readFile(new URL("../../analytics/workbooks/budgets.kql", import.meta.url), "utf8"),
};
const WS = "11111111-2222-4333-8444-555555555555";
const APIM = "/subscriptions/3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim";
const RECON = "/subscriptions/3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11/resourceGroups/rg/providers/Microsoft.Web/sites/reconciler";
const ENV = { ADMIN_WORKSPACE_ID: WS, ADMIN_GATEWAY_RESOURCE_ID: APIM, ADMIN_LOG_RESOURCE_IDS: RECON };
const NOW = new Date("2026-10-19T12:00:00Z");
const disabled = async (): Promise<Capability> => ({ state: "disabled", observedAt: NOW.toISOString() });

function setup(env: Record<string, string> = ENV, table: (meta: QueryMeta, query: string) => LogTable = () => ({ columns: [{ name: "requests", type: "long" }], rows: [[1]] })) {
  const queries: { workspace: string; query: string; timespan: string; meta: QueryMeta }[] = [];
  const operations: Operations = {
    groups: disabled, inventory: disabled, deployments: disabled, logs: disabled, health: disabled, retail: disabled, billed: disabled,
    query: async (workspace, query, timespan, meta) => { queries.push({ workspace, query, timespan, meta }); return table(meta, query); },
  };
  let saved: { doc: Doc; etag: string } | null = null;
  const catalogStore: CatalogStore = { async read() { return saved; }, async save(doc) { saved = { doc, etag: '"e"' }; return '"e"'; } };
  const lines: string[] = [];
  const deps: V3Dependencies = {
    authenticate: async () => ({ oid: "reader", canWrite: false }), projects: null, catalogStore,
    defaultCatalog: { schemaVersion: 1, models: [], rateCard }, operations, env, sources, cache: new QueryCache(),
    now: () => NOW, newId: () => "req-1", log: (l) => lines.push(l),
  };
  const call = (path: string, method = "GET", body?: unknown) => handleV3Request({ method, path: `/api/v3/${path}`, headers: () => "Bearer x", body: body === undefined ? null : JSON.stringify(body) }, deps);
  return { deps, call, queries, lines, setSaved: (doc: Doc) => { saved = { doc, etag: '"s"' }; } };
}
const data = (r: { jsonBody?: unknown }) => (r.jsonBody as Doc);

test("explicit Refresh bypasses the V3 server cache and Overview projects are ranked before paging", async () => {
  const { call, deps, queries } = setup();
  await call("chargeback/projects?period=month&limit=25");
  assert.match(queries[0].query, /knownListUsd desc nulls last/);
  await call("chargeback/projects?period=month&limit=25");
  assert.equal(queries.length, 1);
  await handleV3Request({ method: "GET", path: "/api/v3/chargeback/projects?period=month&limit=25",
    body: null, headers: (n) => n === "x-ccof-refresh" ? "true" : null }, deps);
  assert.equal(queries.length, 2);
});

test("directory user names require admin authentication and a bounded POST; IDs remain in the response", async () => {
  const { deps, call } = setup();
  const objectId = "00000000-0000-4000-8000-000000000001";
  const requests: string[][] = [];
  deps.directory = { lookup: async (ids) => {
    requests.push(ids);
    return { state: "available", observedAt: NOW.toISOString(), data: { users: ids.map((id) => ({
      objectId: id, displayName: "Example User", userPrincipalName: "example@example.invalid", state: "resolved" as const,
    })) } };
  } };
  assert.equal((await call("directory/users", "POST", { objectIds: [objectId] })).status, 200);
  assert.equal((data(await call("directory/users", "POST", { objectIds: [objectId] })).data as Doc).users[0].objectId, objectId);
  assert.equal((await call("directory/users")).status, 405);
  assert.equal((await call("directory/users?extra=1", "POST", { objectIds: [objectId] })).status, 400);
  assert.equal((await call("directory/users", "POST", { objectIds: ["bad"] })).status, 400);
  assert.equal(requests.length, 2);
  deps.authenticate = async () => { throw new ApiError(401, "bearer_token_required"); };
  assert.equal((await call("directory/users", "POST", { objectIds: [objectId] })).status, 401);
  assert.equal(requests.length, 2);
});

test("a denied configured rate-card store never silently substitutes packaged prices", async () => {
  const { deps, call } = setup();
  deps.catalogStore = { read: async () => { throw new Error("permission_denied"); }, save: async () => null };
  assert.equal((await call("plan")).status, 503);
  assert.equal((await call("version")).status, 200);
});

test("v3 fails closed without authentication and reports 3.3.0", async () => {
  const { deps, call } = setup();
  const v = await call("version");
  assert.equal(data(v).version, "3.3.0");
  deps.authenticate = async () => { throw new ApiError(401, "bearer_token_required"); };
  assert.equal((await call("version")).status, 401);
  deps.authenticate = null;
  assert.equal((await call("chargeback/totals")).status, 503);
});

test("chargeback is disabled, not failed, when its settings are missing; other features keep working", async () => {
  const { call, queries } = setup({ ADMIN_WORKSPACE_ID: WS, ADMIN_LOG_RESOURCE_IDS: RECON });
  const cb = data(await call("chargeback/totals"));
  assert.equal(cb.state, "disabled");
  assert.equal(cb.reason, "chargeback_not_configured");
  assert.match(String(cb.permission), /Log Analytics Reader/);
  assert.equal(data(await call("reconciler/runs")).state, "available");
  assert.equal(queries.length, 1);
  const bad = data(await call("chargeback/totals".replace("totals", "models")));
  assert.equal(bad.state, "disabled");
  const invalid = setup({ ...ENV, ADMIN_GATEWAY_RESOURCE_ID: "not-a-resource-id" });
  assert.equal(data(await invalid.call("chargeback/totals")).reason, "chargeback_settings_invalid");
});

test("a permission denial on one workspace isolates to that capability", async () => {
  const { call } = setup(ENV, (meta) => { if (meta.kind === "chargeback") throw new ProviderError(403, "upstream_403"); return { columns: [], rows: [] }; });
  const cb = data(await call("chargeback/totals"));
  assert.equal(cb.state, "permission_required");
  assert.equal(cb.reason, "upstream_403");
  assert.equal(data(await call("reconciler/runs")).state, "available");
  assert.equal(data(await call("audit")).state, "available");
  const down = setup(ENV, () => { throw new ProviderError(502, "invalid_query_result"); });
  assert.equal(data(await down.call("chargeback/trend")).state, "unavailable");
});

test("chargeback filters are validated; injection attempts never reach KQL", async () => {
  const { call, queries } = setup();
  for (const q of [
    "project=P1%22%29%3B%20drop", "project=P1|take", "group=not-a-guid", "developer=1%3D1", "model=claude%22%20or%201%3D1",
    "backend=b%0aunion", "family=gpt", "interval=minute", "period=forever", "period=custom&from=2026-10-01&to=2026-10-02",
    "period=custom&from=2026-10-02T00:00:00Z&to=2026-10-01T00:00:00Z", "period=custom&from=2026-01-01T00:00:00Z&to=2026-10-01T00:00:00Z",
    `limit=${ROW_PAGE_MAX + 1}`, "offset=-1", "kql=print%201", "project=A&project=B",
  ]) {
    const r = await call(`chargeback/totals?${q}`);
    assert.equal(r.status, 400, q);
  }
  assert.equal(queries.length, 0);
  assert.equal((await call("chargeback/everything")).status, 404);
  const ok = await call("chargeback/groups?project=PROJECT01&group=6F3A2C1E-4B5D-4E8F-9A0B-1C2D3E4F5A6B&model=claude-sonnet-5&backend=foundry-eus2&family=sonnet&limit=25&offset=50");
  assert.equal(ok.status, 200);
  const sent = queries[0];
  assert.equal(sent.workspace, WS);
  assert.doesNotMatch(sent.query, /\{(Period|Project|TimeRange|Group|Developer|Model|Backend|Family)[:}]/);
  assert.ok(!sent.query.includes("PROJECT01\""), "filter values are bound base64, never spliced as text");
  assert.ok(sent.query.includes(Buffer.from("PROJECT01").toString("base64")));
  assert.ok(sent.query.includes(Buffer.from("6f3a2c1e-4b5d-4e8f-9a0b-1c2d3e4f5a6b").toString("base64")), "group IDs are lower-cased");
  assert.match(sent.query, /where reportRowNumber > 50\n\| take 25/);
  assert.equal(sent.timespan, "2026-10-01T00:00:00.000Z/2026-11-01T00:00:00.000Z");
});

test("custom ranges are UTC, half-open and capped at maxQueryDays", () => {
  const p = (q: string) => readChargebackFilters(new URLSearchParams(q), NOW, 62);
  const f = p("period=custom&from=2026-09-01T00:00:00Z&to=2026-10-01T00:00:00Z");
  assert.deepEqual(f.period, { mode: "custom", from: "2026-09-01T00:00:00.000Z", to: "2026-10-01T00:00:00.000Z" });
  assert.throws(() => p("period=custom&from=2026-08-01T00:00:00Z&to=2026-10-03T00:00:01Z"), /range_exceeds_max_query_days/);
  assert.deepEqual(p("period=previous").period, { mode: "previous", from: "2026-09-01T00:00:00.000Z", to: "2026-10-01T00:00:00.000Z" });
  assert.equal(p("").limit, 100);
});

test("series are capped, row pages bounded, and identical filter sets are cached for 60 s", async () => {
  const { call, queries, deps } = setup();
  const trend = data(await call("chargeback/trend?interval=hour"));
  assert.equal((trend.data as Doc).seriesCap, 2000);
  assert.match(queries[0].query, /bucket = bin\(timestamp, 1h\)/);
  assert.match(queries[0].query, /\| take 2000\n/);
  await call("chargeback/trend?interval=hour");
  assert.equal(queries.length, 1, "second identical request is served from cache");
  assert.equal(((data(await call("chargeback/trend?interval=hour")).data) as Doc).cached, true);
  await call("chargeback/trend?interval=day");
  assert.equal(queries.length, 2);
  const later = new Date(NOW.getTime() + 61_000);
  deps.now = () => later;
  await call("chargeback/trend?interval=hour");
  assert.equal(queries.length, 3, "cache expires after 60 s");
});

test("chargeback uses the saved catalog rate card when present", async () => {
  const { call, queries, setSaved } = setup();
  const card = structuredClone(rateCard);
  card.version = "2026-11-01-catalog";
  setSaved({ schemaVersion: 1, models: [], rateCard: card });
  const r = data(await call("chargeback/totals"));
  assert.equal((r.data as Doc).rateCardVersion, "2026-11-01-catalog");
  assert.equal((r.data as Doc).rateCardSource, "admin_catalog");
  assert.match(queries[0].query, /let RateCardVersion = "2026-11-01-catalog";/);
  assert.equal((r.data as Doc).basis, "List price at the approved rate card (100 CCU = USD 1); not an Azure invoice.");
});

test("rows are shaped: bookkeeping columns removed, truncation and paging reported", async () => {
  const table: LogTable = {
    columns: [{ name: "groupId", type: "string" }, { name: "knownListUsd", type: "decimal" }, { name: "reportRows", type: "long" }, { name: "truncated", type: "bool" }, { name: "displayedLimit", type: "long" }],
    rows: [["g1", 1.25, 3, true, 2], ["g2", null, 3, true, 2]],
  };
  const { call } = setup(ENV, () => table);
  const r = data(await call("chargeback/groups?limit=2"));
  assert.equal(r.state, "partial");
  const d = r.data as Doc;
  assert.deepEqual(d.columns, ["groupId", "knownListUsd"]);
  assert.deepEqual(d.rows, [{ groupId: "g1", knownListUsd: "1.25" }, { groupId: "g2", knownListUsd: null }]);
  assert.deepEqual(d.page, { offset: 0, limit: 2, returned: 2, matched: 3, nextOffset: 2 });
  assert.equal(d.truncated, true);
});

test("plan route validates input and plans from the current rate card; it never writes", async () => {
  const { call, setSaved, queries } = setup();
  const body = {
    budgetBasis: "person", monthlyBudget: { amount: "100", currency: "USD" }, sizing: "guaranteed", geography: "global",
    mix: { outputPercentOfTokens: 20, cacheReadPercentOfInput: 50, cacheWrite5mPercentOfInput: 10, cacheWrite1hPercentOfInput: 0 },
    families: [{ family: "sonnet", model: "claude-sonnet-5", budgetPercent: 70 }, { family: "haiku", model: "claude-haiku-4-5", budgetPercent: 30 }],
  };
  const r = await call("plan", "POST", body);
  assert.equal(r.status, 200);
  const plan = (data(r).plan as Doc);
  assert.equal(plan.worstCaseSpendUsd, "100.00");
  const sonnet = (plan.families as Doc[])[0];
  assert.equal(sonnet.personMonthlyTokens, 7_000_000);
  assert.equal(sonnet.groupMonthlyTokens, null);
  const withGroup = data(await call("plan", "POST", { ...body, groupMonthlyBudget: { amount: "1000", currency: "USD" } }));
  assert.equal(((withGroup.plan as Doc).families as Doc[])[0].personMonthlyTokens, 7_000_000);
  assert.equal(((withGroup.plan as Doc).families as Doc[])[0].groupMonthlyTokens, 70_000_000);
  assert.equal((await call("plan", "POST", { ...body, budgetBasis: "group", members: 10 })).status, 422, "Old member-count sizing is refused rather than silently reinterpreted");
  assert.equal(sonnet.blendedUsdPerMTok, "2.9200");
  const ccu = await call("plan", "POST", { ...body, monthlyBudget: { amount: "10000", currency: "CCU" } });
  assert.equal(data(ccu).budgetUsd, "100");
  assert.equal((await call("plan", "POST", { ...body, monthlyBudget: { amount: "-1", currency: "USD" } })).status, 422);
  assert.equal((await call("plan", "POST", { ...body, families: [{ family: "gpt", budgetPercent: 100 }] })).status, 422);
  const geo = await call("plan", "POST", { ...body, geography: "us" });
  assert.equal(geo.status, 422, "Haiku 4.5 has no US multiplier in the rate card");
  assert.match(String(data(geo).detail), /not priced for geography us/);
  assert.equal((await call("plan", "POST", { ...body, extra: 1 })).status, 422);
  assert.equal((await call("plan", "PUT", body)).status, 405);
  const options = data(await call("plan"));
  assert.ok((options.models as Doc[]).some((m) => m.model === "claude-sonnet-5" && (m.rates as Doc).output === "10"));
  const card = structuredClone(rateCard);
  card.version = "catalog-v2";
  for (const e of card.entries as Doc[]) if (e.model === "claude-sonnet-5") ((e.promptTiers as Doc[])[0].rates as Doc).output = "20";
  setSaved({ schemaVersion: 1, models: [], rateCard: card });
  const fromCatalog = data(await call("plan", "POST", body));
  assert.equal(fromCatalog.rateCardVersion, "catalog-v2");
  assert.equal(fromCatalog.rateCardSource, "admin_catalog");
  assert.equal(queries.length, 0);
  assert.throws(() => planFromRequest({ ...body, sizing: "maybe" }, rateCard, NOW), /sizing/);
});

test("rate-card review applies the parser, the history rules and the no-past-repricing rule", async () => {
  const later = structuredClone(rateCard);
  assert.throws(() => reviewRateCard(rateCard, { ...later, entries: [] }, NOW), (e: ApiError) => e.code.startsWith("invalid_rate_card"));
  const sameVersion = structuredClone(rateCard);
  ((sameVersion.entries as Doc[])[0]).displayName = "Renamed";
  assert.throws(() => reviewRateCard(rateCard, sameVersion, NOW), (e: ApiError) => e.code === "rate_card_version_must_change");
  const repriced = structuredClone(rateCard);
  repriced.version = "next";
  (((repriced.entries as Doc[])[0].promptTiers as Doc[])[0].rates as Doc).input = "11";
  assert.throws(() => reviewRateCard(rateCard, repriced, NOW), (e: ApiError) => e.code === "historical_rate_edit_forbidden");
  const split = (at: string) => {
    const c = structuredClone(rateCard);
    c.version = "2026-10-20";
    const old = (c.entries as Doc[]).find((e) => e.model === "claude-sonnet-5") as Doc;
    old.effectiveTo = at;
    const next = structuredClone(old);
    next.effectiveFrom = at; next.effectiveTo = null;
    ((next.promptTiers as Doc[])[0].rates as Doc).output = "12";
    (c.entries as Doc[]).push(next);
    return c;
  };
  const review = reviewRateCard(rateCard, split("2026-10-20T00:00:00Z"), NOW);
  assert.equal(review.added.length, 1);
  assert.deepEqual(review.closed, [{ model: "claude-sonnet-5", effectiveFrom: "2026-10-11T00:00:00Z", effectiveTo: "2026-10-20T00:00:00Z" }]);
  assert.deepEqual(review.version, { before: "2026-10-11", after: "2026-10-20" });
  assert.throws(() => reviewRateCard(rateCard, split("2026-10-15T00:00:00Z"), NOW), (e: ApiError) => e.code === "effective_date_in_past");
  const { call } = setup();
  const r = await call("rate-card/review", "POST", split("2026-10-20T00:00:00Z"));
  assert.equal(r.status, 200);
  assert.equal(((data(r).review as Doc).added as Doc[]).length, 1);
  assert.equal((await call("rate-card/review", "POST", repriced)).status, 422);
  assert.equal((await call("rate-card/review", "GET")).status, 405);
});

test("reconciler runs and snapshots: filters validated, freshness against the interval, exact USD", async () => {
  const runs: LogTable = { columns: [{ name: "outcome", type: "string" }, { name: "latestRunAt", type: "datetime" }, { name: "statesWritten", type: "long" }],
    rows: [["written", "2026-10-19T11:52:00Z", 12], ["failed", "2026-10-18T11:00:00Z", 0]] };
  const { call, queries } = setup({ ...ENV, ADMIN_RECONCILER_INTERVAL_MINUTES: "5" }, (meta) => meta.view === "runs" ? runs : { columns: [], rows: [] });
  const r = data(await call("reconciler/runs"));
  const rows = (r.data as Doc).rows as Doc[];
  assert.equal(rows[0].freshness, "on_schedule");
  assert.equal(rows[1].freshness, "stale");
  assert.match(queries[0].query, /let ReconcilerLogs = union isfuzzy=true FunctionAppLogs, AppTraces/);
  assert.ok(queries[0].query.includes(JSON.stringify(RECON)));
  assert.doesNotMatch(queries[0].query, /FunctionAppLogs\n\| where _ResourceId =~ ReconcilerResourceId/);
  assert.equal((await call("reconciler/runs?x=1")).status, 400);
  assert.equal((await call("reconciler/snapshots?scope=team")).status, 400);
  assert.equal((await call("reconciler/snapshots?person=%27or%271")).status, 400);
  assert.equal((await call("reconciler/snapshots?state=current&scope=person&project=PROJECT01&limit=10&offset=10")).status, 200);
  assert.ok(queries.at(-1)?.query.includes(Buffer.from("person").toString("base64")));
  assert.match(String(queries.at(-1)?.query), /where reportRowNumber > 10/);
  assert.deepEqual(shapeSnapshot({ spentCcu: "12345.6789", budgetCcu: "2500" }), { spentCcu: "12345.6789", budgetCcu: "2500", spentUsd: "123.456789", budgetUsd: "25", usedPercent: "493.8" });
  assert.equal(shapeSnapshot({ spentCcu: "1", budgetCcu: null }).budgetUsd, null);
  assert.equal(shapeRun({ latestRunAt: "2026-10-19T11:30:00Z" }, 5, NOW).freshness, "late");
  assert.throws(() => readSnapshotFilters(new URLSearchParams("budgetState=open"), NOW), /invalid_budget_state_filter/);
  assert.equal(readSnapshotFilters(new URLSearchParams("budgetState=warning"), NOW).budgetState, "warning", "the soft-limit state is filterable (ADR 0035)");
});

test("reconciler logs report their own capability state", async () => {
  const { call } = setup({ ADMIN_WORKSPACE_ID: WS, ADMIN_GATEWAY_RESOURCE_ID: APIM });
  const r = data(await call("reconciler/summary"));
  assert.equal(r.state, "disabled");
  assert.equal(r.reason, "reconciler_logs_not_configured");
  const missingSources = setup();
  missingSources.deps.sources = null;
  assert.equal(data(await missingSources.call("reconciler/summary")).reason, "packaged_queries_unavailable");
});

test("audit search binds filters, bounds the range and pages", async () => {
  const f = readAuditFilters(new URLSearchParams("project=PROJECT01&operation=limits&outcome=updated&limit=10&offset=20"), NOW);
  const q = buildAuditQuery(f, [RECON]);
  assert.ok(q.includes(Buffer.from("PROJECT01").toString("base64")));
  assert.match(q, /where reportRowNumber > 20\n\| take 10/);
  assert.match(q, /at >= datetime\(2026-09-18T12:00:00.000Z\) and at < datetime\(2026-10-19T12:01:00.000Z\)/);
  assert.throws(() => readAuditFilters(new URLSearchParams("operation=limits%22%7C"), NOW), /invalid_operation_filter/);
  assert.throws(() => readAuditFilters(new URLSearchParams("from=2026-01-01T00:00:00Z&to=2026-10-01T00:00:00Z"), NOW), /invalid_audit_range/);
  const { call } = setup();
  assert.equal((await call("audit?actor=me")).status, 400);
  assert.equal(data(await call("audit?project=PROJECT01")).state, "available");
});

test("reads only: writes and unknown routes are refused", async () => {
  const { call } = setup();
  assert.equal((await call("chargeback/totals", "POST", {})).status, 405);
  assert.equal((await call("projects")).status, 404);
  const caps = data(await call("capabilities"));
  assert.equal(caps.canWrite, false);
  assert.equal((caps.features as Doc).chargeback, "configured");
});
