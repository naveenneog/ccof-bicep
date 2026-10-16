import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { handleV2Request, MAX_CATALOG_BYTES, validateCatalog, validateRateHistory } from "../src/v2.ts";
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
  assert.equal(((await call("version")).jsonBody as Doc).version, "2.0.0");
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
