import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { handleV3Request } from "../src/v3.ts";
import type { V3Dependencies } from "../src/v3.ts";
import type { ProjectStore } from "../src/api.ts";
import { QueryCache, TAG_PROJECTS_MAX, buildChargebackQuery, prepareRateCard, readChargebackFilters } from "../src/chargeback.ts";
import { buildClientFiles, readClientSettings, stableProfileId } from "../src/client-config.ts";
import type { Capability, QueryMeta } from "../src/operations.ts";
import type { Doc } from "../src/validation.ts";
// @ts-expect-error The client is plain ESM JavaScript without type declarations.
import { validateConfig } from "../../client/src/config.mjs";

const rateCard = JSON.parse(await readFile(new URL("../../config/rate-card.json", import.meta.url), "utf8")) as Doc;
const sources = {
  ledger: await readFile(new URL("../../analytics/ledger.kql", import.meta.url), "utf8"),
  pricing: await readFile(new URL("../../analytics/workbooks/pricing.kql", import.meta.url), "utf8"),
  budgets: await readFile(new URL("../../analytics/workbooks/budgets.kql", import.meta.url), "utf8"),
};
const WS = "11111111-2222-4333-8444-555555555555";
const APIM = "/subscriptions/3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim";
const NOW = new Date("2026-10-19T12:00:00Z");
const TENANT = "0f1e2d3c-4b5a-4968-8776-655443322110";
const CLIENT = "5d6e7f80-9a1b-4c2d-8e3f-405162738495";
const CLIENT_ENV = { ADMIN_TENANT_ID: TENANT, ADMIN_CLIENT_ID: CLIENT, ADMIN_GATEWAY_URL: "https://ccof-apim.azure-api.net/claude" };
const b64 = (s: string) => Buffer.from(s).toString("base64");
const disabled = async (): Promise<Capability> => ({ state: "disabled", observedAt: NOW.toISOString() });

function project(id: string, tags: string[], classes: Record<string, Record<string, string[]>>): Doc {
  return {
    projectId: id, displayName: `${id} name`, status: "active", backendId: "foundry-eus2", adminTags: tags,
    classifications: Object.fromEntries(Object.entries(classes).map(([code, fam], i) => [code, {
      groupId: `6f3a2c1e-4b5d-4e8f-9a0b-1c2d3e4f5a6${i}`, classificationGroupDisplayName: `${id}-${code}`,
      familyPolicy: { families: Object.fromEntries(Object.entries(fam).map(([f, models]) => [f, { models }])) },
    }])),
  };
}

function store(docs: Doc[], pageSize = 2): ProjectStore & { pages: number } {
  const s = {
    pages: 0,
    async list() { return docs.map((doc) => ({ doc, etag: '"e"' })); },
    async read(id: string) { const doc = docs.find((d) => d.projectId === id); return doc ? { doc, etag: '"e"' } : null; },
    async listPage(q: { tags?: string[]; cursor?: string }) {
      s.pages++;
      const match = docs.filter((d) => (q.tags ?? []).every((t) => (d.adminTags as string[]).includes(t)));
      const start = Number(q.cursor ?? 0);
      const next = start + pageSize;
      return { items: match.slice(start, next).map((doc) => ({ doc, etag: '"e"' })), cursor: next < match.length ? String(next) : undefined };
    },
    async create() { return "conflict" as const; }, async replace() { return "precondition_failed" as const; },
  };
  return s;
}

function setup(projects: ProjectStore | null, env: Record<string, string> = {}) {
  const metas: QueryMeta[] = [];
  const queries: string[] = [];
  const deps: V3Dependencies = {
    authenticate: async () => ({ oid: "reader", canWrite: false }), projects,
    catalogStore: { async read() { return null; }, async save() { return '"e"'; } },
    defaultCatalog: { schemaVersion: 1, models: [], rateCard },
    operations: { groups: disabled, inventory: disabled, deployments: disabled, logs: disabled, health: disabled, retail: disabled, billed: disabled,
      query: async (_w, query, _t, meta) => { metas.push(meta); queries.push(query); return { columns: [{ name: "requests", type: "long" }], rows: [[1]] }; } },
    env: { ADMIN_WORKSPACE_ID: WS, ADMIN_GATEWAY_RESOURCE_ID: APIM, ...env }, sources, cache: new QueryCache(),
    now: () => NOW, newId: () => "req-1", log: () => {},
  };
  const call = (path: string) => handleV3Request({ method: "GET", path: `/api/v3/${path}`, headers: () => null, body: null }, deps);
  return { call, metas, queries };
}
const body = (r: { jsonBody?: unknown }) => r.jsonBody as Doc;

const DOCS = [
  project("PAY", ["finance", "pilot"], { STD: { sonnet: ["claude-sonnet-4-5"], haiku: ["claude-haiku-4-5"] }, PRM: { opus: ["claude-opus-4-1"], sonnet: ["claude-sonnet-4-5"] } }),
  project("TAX", ["finance"], { STD: { sonnet: ["claude-sonnet-4-5"] } }),
  project("HR", ["people", "pilot"], { CYB: { opus: ["claude-opus-4-1"] } }),
  project("OPS", ["finance", "pilot"], { STD: { haiku: ["claude-haiku-4-5"] } }),
];

test("chargeback filters accept classification and tags, and reject malformed tags", () => {
  const f = readChargebackFilters(new URLSearchParams("period=month&classification=PRM&tags=pilot,finance,pilot"), NOW, 62);
  assert.equal(f.classification, "PRM");
  assert.deepEqual(f.tags, ["finance", "pilot"]);
  assert.equal(f.projectSet, null);
  for (const bad of ["tags=%3Cscript%3E", `tags=${Array.from({ length: 11 }, (_, i) => `t${i}`).join(",")}`, "classification=P%20R"]) {
    assert.throws(() => readChargebackFilters(new URLSearchParams(bad), NOW, 62), /invalid_(tags|classification)_filter/, bad);
  }
});

test("classification and tag project sets reach the query; an empty tag match selects nothing", () => {
  const prepared = prepareRateCard(rateCard);
  const settings = { workspaceId: WS, gatewayResourceId: APIM, maxQueryDays: 62, retentionDays: 90 };
  const f = readChargebackFilters(new URLSearchParams("period=month&classification=CYB"), NOW, 62);
  const plain = buildChargebackQuery("classifications", f, settings, sources, prepared, []);
  assert.ok(plain.includes(b64("CYB")));
  assert.ok(plain.includes(`base64_decode_tostring("${b64("*")}")`), "no tag filter renders the wildcard");
  assert.match(plain, /by projectLabel, classification/);
  assert.doesNotMatch(plain, /\{[A-Za-z]+:(base64|start|end)\}/);
  const empty = buildChargebackQuery("totals", { ...f, projectSet: [] }, settings, sources, prepared, []);
  assert.ok(empty.includes(b64("(none)")));
  const some = buildChargebackQuery("totals", { ...f, projectSet: ["OPS", "PAY"] }, settings, sources, prepared, []);
  assert.ok(some.includes(b64("OPS,PAY")));
});

test("tags resolve to registry projects across pages, are reported, and are part of the cache key", async () => {
  const projects = store(DOCS);
  const { call, metas } = setup(projects);
  const r = await call("chargeback/projects?period=month&tags=pilot,finance");
  assert.equal(r.status, 200);
  assert.deepEqual((metas[0].filters as Doc).projectSet, ["OPS", "PAY"]);
  assert.deepEqual((body(r).data as Doc).filters, { project: "", group: "", developer: "", model: "", backend: "", family: "", classification: "", tags: ["finance", "pilot"], tagProjects: 2 });
  await call("chargeback/projects?period=month&tags=finance,pilot");
  assert.equal(metas.length, 1, "same tags in another order hit the cache");
  await call("chargeback/projects?period=month&tags=legal");
  assert.deepEqual((metas[1].filters as Doc).projectSet, []);
  await call("chargeback/projects?period=month");
  assert.equal((metas[2].filters as Doc).projectSet, null);
});

test("a tag matching more than the cap is refused, not truncated", async () => {
  const many = Array.from({ length: TAG_PROJECTS_MAX + 1 }, (_, i) => project(`P${i}`, ["all"], { STD: { sonnet: ["claude-sonnet-4-5"] } }));
  const { call, metas } = setup(store(many, 100));
  const r = await call("chargeback/totals?tags=all");
  assert.equal(r.status, 400);
  assert.equal(body(r).error, "tag_matches_too_many_projects");
  assert.equal(metas.length, 0);
});

test("client-config builds a config.json the CCOF client accepts, per project and classification", async () => {
  const { call } = setup(store(DOCS), CLIENT_ENV);
  const r = await call("projects/PAY/client-config?classification=PRM");
  assert.equal(r.status, 200);
  const d = body(r);
  assert.equal(d.complete, true);
  assert.deepEqual(d.missing, []);
  const config = d.config as Doc;
  assert.doesNotThrow(() => validateConfig(config));
  assert.equal(config.tenantId, TENANT);
  assert.equal(config.scope, `api://${CLIENT}/access_as_user`);
  assert.deepEqual(config.project, { id: "PAY", selectorHeader: "x-ccof-project" });
  assert.deepEqual((config.models as Doc).available, ["claude-sonnet-4-5", "claude-opus-4-1"]);
  assert.equal((config.models as Doc).haiku, "claude-sonnet-4-5", "a missing family falls back to the default model");
  assert.equal((config.desktop as Doc).profileId, stableProfileId([TENANT, "PAY", "PRM"]));
  const onboarding = d.onboarding as Doc;
  assert.equal((onboarding.entraGroup as Doc).displayName, "PAY-PRM");
  assert.deepEqual(onboarding.models, { sonnet: ["claude-sonnet-4-5"], opus: ["claude-opus-4-1"] });
  assert.doesNotMatch(JSON.stringify(d), /secret|password|key=|Bearer/i);
});

test("client-config marks missing admin settings with placeholders the client refuses", async () => {
  const { call } = setup(store(DOCS));
  const d = body(await call("projects/HR/client-config?classification=CYB"));
  assert.equal(d.complete, false);
  assert.deepEqual(d.missing, ["ADMIN_CLIENT_TENANT_ID", "ADMIN_CLIENT_ID", "ADMIN_CLIENT_SCOPE", "ADMIN_GATEWAY_URL"]);
  assert.match(String((d.config as Doc).clientId), /^REPLACE-/);
  assert.throws(() => validateConfig(d.config));
  assert.equal((d.onboarding as Doc).complete, false);
});

test("client-config validates its inputs", async () => {
  const noModels = project("EMPTY", [], { STD: {} });
  const { call } = setup(store([...DOCS, noModels]), CLIENT_ENV);
  assert.equal((await call("projects/PAY/client-config")).status, 400);
  assert.equal((await call("projects/PAY/client-config?classification=CYB")).status, 404);
  assert.equal((await call("projects/NOPE/client-config?classification=STD")).status, 404);
  assert.equal((await call("projects/b%20ad/client-config?classification=STD")).status, 400);
  assert.equal((await call("projects/EMPTY/client-config?classification=STD")).status, 409);
  assert.equal((await setup(null, CLIENT_ENV).call("projects/PAY/client-config?classification=STD")).status, 503);
});

test("client settings reject unsafe gateway URLs and headers", () => {
  const s = readClientSettings({ ...CLIENT_ENV, ADMIN_GATEWAY_URL: "https://gw.example/claude/v1", ADMIN_PROJECT_HEADER: "bad header" });
  assert.equal(s.gatewayUrl, null);
  assert.ok(s.missing.includes("ADMIN_GATEWAY_URL"));
  assert.equal(s.selectorHeader, "x-ccof-project");
  assert.equal(readClientSettings({ ...CLIENT_ENV, ADMIN_GATEWAY_URL: "http://gw.example/claude" }).gatewayUrl, null);
  const doc = DOCS[0];
  const files = buildClientFiles(doc, "STD", readClientSettings(CLIENT_ENV), NOW);
  assert.equal((files.config.models as Doc).default, "claude-sonnet-4-5");
  assert.equal((files.onboarding as Doc).generatedAt, NOW.toISOString());
});
