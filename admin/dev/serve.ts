// Local demonstration server for the admin console. NOT deployed: Build-AdminPackage.ps1 packages only
// dist/ and ui-dist/, and tsconfig compiles src/ only. It binds to 127.0.0.1, uses an in-memory
// registry and a demo authenticator ("Bearer demo-editor" / "Bearer demo-reader"), and runs the same
// request handler (src/api.ts) and asset server (src/ui.ts) as the Function App.
//
//   node dev/serve.ts                      -> http://127.0.0.1:7171/api/console
//   DEMO_REGISTRY=down node dev/serve.ts   -> every registry call fails as it does without a network path
//   DEMO_REGISTRY=empty node dev/serve.ts  -> first-run state

import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { handleAdminRequest } from "../src/api.ts";
import type { ProjectStore, StoredProject } from "../src/api.ts";
import { ApiError } from "../src/auth.ts";
import type { Authenticator } from "../src/auth.ts";
import { serveUi, serveUiV3 } from "../src/ui.ts";
import type { Doc } from "../src/validation.ts";
import { handleV2Request } from "../src/v2.ts";
import type { CatalogStore } from "../src/v2.ts";
import { createOperations } from "../src/operations.ts";
import type { Operations } from "../src/operations.ts";
import { handleV3Request } from "../src/v3.ts";
import { QueryCache } from "../src/chargeback.ts";
import { createDemoTelemetry } from "./demo-data.ts";
import type { DemoGroup } from "./demo-data.ts";

const PORT = Number(process.env.PORT ?? 7171);
const UI = fileURLToPath(new URL("../ui-dist/", import.meta.url));
const UI_V3 = fileURLToPath(new URL("../ui-dist-v3/", import.meta.url));
const mode = process.env.DEMO_REGISTRY ?? "seeded";

const limit = (tpm: number | null, quota: number | null, period: string | null = quota === null ? null : "Monthly") =>
  ({ tokensPerMinute: tpm, tokenQuota: quota, tokenQuotaPeriod: period });

function seed(id: string, name: string, classes: Record<string, { group: string; groupName: string; families: Record<string, string[]> }>, extra: Doc = {}): Doc {
  return {
    id, projectId: id, displayName: name, status: "active", backendId: "foundry-eus2",
    designatedSubscriptionId: "3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11", supersedes: null, retiredAt: null, ...extra,
    classifications: Object.fromEntries(Object.entries(classes).map(([code, c]) => [code, {
      groupId: c.group, classificationGroupDisplayName: c.groupName,
      familyPolicy: {
        aggregateLimits: { person: limit(20000, 2000000), group: limit(150000, 40000000) },
        families: Object.fromEntries(Object.entries(c.families).map(([family, models]) => [family, {
          models, person: limit(family === "opus" ? 8000 : 20000, family === "opus" ? 500000 : 2000000), group: limit(family === "opus" ? 40000 : 120000, null),
        }])),
      },
      personBudget: { amount: 25, currency: "USD", period: "monthly" },
      aggregateBudget: { amount: 1500, currency: "USD", period: "monthly" },
      aggregateMode: "strict", onboardingMode: "block",
    }])),
  };
}

class MemoryStore implements ProjectStore {
  docs = new Map<string, StoredProject>();
  n = 0;
  tag() { return `"demo-${++this.n}"`; }
  fail() { if (mode === "down") throw Object.assign(new Error("Request blocked by network rules"), { code: 403 }); }
  async list() { this.fail(); return [...this.docs.values()].map((p) => structuredClone(p)); }
  async listPage(query: { search: string; tag: string; backendId: string; limit: number; cursor?: string; tags?: string[]; classification?: string }) {
    const all = (await this.list()).filter((p) => `${p.doc.projectId} ${p.doc.displayName}`.toLowerCase().includes(query.search.toLowerCase()) &&
      (!query.tag || Array.isArray(p.doc.adminTags) && p.doc.adminTags.includes(query.tag)) && (!query.backendId || p.doc.backendId === query.backendId) &&
      (query.tags ?? []).every((t) => Array.isArray(p.doc.adminTags) && p.doc.adminTags.includes(t)) &&
      (!query.classification || Object.hasOwn(p.doc.classifications as Doc, query.classification)))
      .sort((a, b) => String(a.doc.projectId).localeCompare(String(b.doc.projectId)));
    const start = Number(query.cursor ?? 0);
    return { items: all.slice(start, start + query.limit), cursor: start + query.limit < all.length ? String(start + query.limit) : undefined };
  }
  async read(id: string) { this.fail(); const p = this.docs.get(id); return p ? structuredClone(p) : null; }
  async create(doc: Doc) {
    this.fail();
    if (this.docs.has(String(doc.projectId))) return "conflict" as const;
    const etag = this.tag();
    this.docs.set(String(doc.projectId), { doc: structuredClone(doc), etag });
    return etag;
  }
  async replace(doc: Doc, etag: string) {
    this.fail();
    const cur = this.docs.get(String(doc.projectId));
    if (!cur || cur.etag !== etag) return "precondition_failed" as const;
    const next = this.tag();
    this.docs.set(String(doc.projectId), { doc: structuredClone(doc), etag: next });
    return next;
  }
}

const store = new MemoryStore();
if (mode === "seeded") {
  for (const doc of [
    seed("PROJECT01", "Payments platform", {
      STD: { group: "6f3a2c1e-4b5d-4e8f-9a0b-1c2d3e4f5a6b", groupName: "PROJECT01-STD", families: { sonnet: ["claude-sonnet-4-5"], haiku: ["claude-haiku-4-5"] } },
      PRM: { group: "7a4b3d2f-5c6e-4f9a-8b1c-2d3e4f5a6b7c", groupName: "PROJECT01-PRM", families: { sonnet: ["claude-sonnet-4-5"], opus: ["claude-opus-4-1"] } },
      CYB: { group: "9c6d5f4b-7e8a-4b1c-8d3e-4f5a6b7c8d9e", groupName: "PROJECT01-CYB", families: { opus: ["claude-opus-4-1"], sonnet: ["claude-sonnet-4-5"] } },
    }),
    seed("PROJECT02", "Customer support copilots", {
      STD: { group: "8b5c4e3a-6d7f-4a0b-9c2d-3e4f5a6b7c8d", groupName: "PROJECT02-STD", families: { sonnet: ["claude-sonnet-4-5"] } },
    }),
  ]) await store.create(doc);
  // V3 demo: enough projects to page, filter by tag/backend/classification and chart by project.
  const names = ["Claims automation", "Developer portal", "Fraud analytics", "HR assistant", "Legal review", "Marketing studio", "Network ops",
    "Procurement", "Quality engineering", "Risk models", "Sales enablement", "Security research", "Supply chain", "Tax engine", "Treasury",
    "Underwriting", "Vendor onboarding", "Warehouse robotics", "Data platform", "Mobile banking", "Observability", "Pricing service", "Search relevance", "Voice bots"];
  const hex = (n: number, width: number) => n.toString(16).padStart(width, "0");
  for (const [i, name] of names.entries()) {
    const id = `PROJECT${String(i + 3).padStart(2, "0")}`;
    const classes: Record<string, { group: string; groupName: string; families: Record<string, string[]> }> = {
      STD: { group: `${hex(0x1a2b0000 + i, 8)}-0000-4000-8000-${hex(i + 1, 12)}`, groupName: `${id}-STD`, families: { sonnet: ["claude-sonnet-4-5"], haiku: ["claude-haiku-4-5"] } },
    };
    if (i % 3 === 0) classes.PRM = { group: `${hex(0x2b3c0000 + i, 8)}-0000-4000-8000-${hex(i + 1, 12)}`, groupName: `${id}-PRM`, families: { sonnet: ["claude-sonnet-4-5"], opus: ["claude-opus-4-1"] } };
    if (i % 4 === 1) classes.CYB = { group: `${hex(0x3c4d0000 + i, 8)}-0000-4000-8000-${hex(i + 1, 12)}`, groupName: `${id}-CYB`, families: { opus: ["claude-opus-4-1"], sonnet: ["claude-sonnet-4-5"] } };
    await store.create(seed(id, name, classes, {
      backendId: i === names.length - 1 ? "foundry-wus3" : i % 4 === 0 ? "foundry-swc" : "foundry-eus2",
      adminTags: [["finance", "pilot"], ["platform"], ["finance"], ["people", "pilot"], ["legal"], ["growth"]][i % 6],
    }));
  }
  // Demo budgets sized to the synthetic usage, so the burn-down and "near limit" views have something to show.
  for (const p of await store.list()) {
    const doc = structuredClone(p.doc);
    for (const [code, c] of Object.entries(doc.classifications as Record<string, Doc>)) {
      const n = Number(String(doc.projectId).slice(-2));
      (c.aggregateBudget as Doc).amount = doc.projectId === "PROJECT01" && code === "PRM" ? 40 : 80 + (n % 5) * 40;
    }
    await store.replace(doc, p.etag);
  }
}

const authenticate: Authenticator = async (authorization) => {
  if (authorization === "Bearer demo-editor") return { oid: "00000000-0000-4000-8000-0000000000e1", canWrite: true };
  if (authorization === "Bearer demo-reader") return { oid: "00000000-0000-4000-8000-0000000000a1", canWrite: false };
  throw new ApiError(401, "bearer_token_required");
};
const rateCard = JSON.parse(await readFile(new URL("../ui-dist/rate-card.json", import.meta.url), "utf8"));
const defaultCatalog = { schemaVersion: 1, rateCard, models: rateCard.entries.map((entry: Doc) => ({
  family: String(entry.model).split("-")[1], model: entry.model, deployment: entry.model, backendId: "",
})) };
let catalog: { doc: Doc; etag: string } | null = null;
const catalogStore: CatalogStore = {
  async read() { return catalog ? structuredClone(catalog) : null; },
  async save(doc, etag) {
    if (catalog && catalog.etag !== etag || !catalog && etag) return null;
    catalog = { doc: structuredClone(doc), etag: `"catalog-${randomUUID()}"` };
    return catalog.etag;
  },
};
const realOperations = createOperations({}, { getToken: async () => { throw new Error("Demo must not acquire real tokens"); } }, console.log);

// ---- Demo-only synthetic telemetry (dev/demo-data.ts); never used in Azure. ----
const familyModel: Record<string, string> = { sonnet: "claude-sonnet-5", haiku: "claude-haiku-4-5", opus: "claude-opus-5-5" };
const demoGroups: DemoGroup[] = mode === "seeded" ? (await store.list()).flatMap((p) => Object.entries(p.doc.classifications as Record<string, Doc>).map(([code, c], i) => ({
  projectId: String(p.doc.projectId), classification: code, groupId: String(c.groupId), groupName: String(c.classificationGroupDisplayName ?? code),
  members: 3 + (String(p.doc.projectId).charCodeAt(8) + i) % 6, personBudgetUsd: Number((c.personBudget as Doc).amount),
  groupBudgetUsd: c.aggregateBudget === null ? null : Number((c.aggregateBudget as Doc).amount),
  backendId: String(p.doc.backendId), models: Object.keys((c.familyPolicy as Doc).families as Doc).map((f) => familyModel[f]).filter(Boolean),
}))) : [];
const telemetry = createDemoTelemetry(rateCard, demoGroups);
const auditLines: Doc[] = [];
const at = (minutes: number) => new Date(Date.now() - minutes * 60_000).toISOString();
const editorOid = "00000000-0000-4000-8000-0000000000e1";
if (mode === "seeded") {
  auditLines.push(
    { at: at(60 * 26), requestId: randomUUID(), operation: "create", outcome: "created", projectId: "PROJECT02", actorOid: editorOid, d: { classifications: ["STD"] } },
    { at: at(60 * 5), requestId: randomUUID(), operation: "limits", outcome: "updated", projectId: "PROJECT01", actorOid: editorOid,
      d: { classification: "STD", changes: [{ path: "classifications.STD.familyPolicy.families.sonnet.person.tokensPerMinute", before: 15000, after: 20000 }] } },
    { at: at(60 * 3), requestId: randomUUID(), operation: "settings", outcome: "updated", projectId: "PROJECT01", actorOid: editorOid,
      d: { changes: [{ path: "adminTags", before: null, after: ["finance"] }] } },
    { at: at(50), requestId: randomUUID(), operation: "limits", outcome: "refused", projectId: "PROJECT02", actorOid: "00000000-0000-4000-8000-0000000000a1",
      d: { status: 403, code: "write_permission_required" } },
  );
}
// Captures the demo server's own audit lines, so changes made in the browser appear in Audit and Activity.
const demoLog = (line: string) => {
  console.log(line);
  try {
    const d = JSON.parse(line) as Doc;
    if (d.schema === "ccof.admin.audit.v1") auditLines.push({ at: d.at, requestId: d.requestId, operation: d.operation, outcome: d.outcome, projectId: d.projectId ?? "", actorOid: d.actorOid ?? "", d });
  } catch { /* not JSON */ }
};
const now = () => new Date().toISOString();
const operations: Operations = mode === "seeded" ? {
  ...realOperations,
  logs: async (kind) => kind === "budgets" ? { state: "available", observedAt: now(), data: telemetry.groupBudgetLines() }
    : kind === "runs" ? { state: "available", observedAt: now(), data: [{ schema: "ccof.reconciler.run.v1", runId: randomUUID(), outcome: "written", reason: null, statesWritten: 120, observedAt: at(4) }] }
      : { state: "available", observedAt: now(), data: auditLines.map((a) => ({ ...(a.d as Doc), observedAt: a.at })) },
  inventory: async () => ({ state: "available", observedAt: now(), data: {
    resources: [
      { id: "/subscriptions/3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11/resourceGroups/ccof-rg/providers/Microsoft.ApiManagement/service/ccof-apim", name: "ccof-apim", type: "Microsoft.ApiManagement/service", region: "eastus2", provisioningState: "Succeeded", runtimeState: "unknown", lifecycle: "observed", publicNetworkAccess: "Disabled", backendIds: [] },
      { id: "/subscriptions/3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11/resourceGroups/ccof-rg/providers/Microsoft.CognitiveServices/accounts/foundry-eus2", name: "foundry-eus2", type: "Microsoft.CognitiveServices/accounts", region: "eastus2", provisioningState: "Succeeded", runtimeState: "unknown", lifecycle: "observed", publicNetworkAccess: "Disabled", backendIds: ["foundry-eus2"] },
      { id: "/subscriptions/3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11/resourceGroups/ccof-rg/providers/Microsoft.CognitiveServices/accounts/foundry-swc", name: "foundry-swc", type: "Microsoft.CognitiveServices/accounts", region: "swedencentral", provisioningState: "Succeeded", runtimeState: "unknown", lifecycle: "observed", publicNetworkAccess: "Disabled", backendIds: ["foundry-swc"] },
      { id: "/subscriptions/3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11/resourceGroups/ccof-old/providers/Microsoft.CognitiveServices/accounts/foundry-wus3", name: "foundry-wus3", type: "Microsoft.CognitiveServices/accounts", region: "westus3", provisioningState: "unknown", runtimeState: "unknown", lifecycle: "not_found", publicNetworkAccess: "unknown", backendIds: [] },
    ],
    backends: [{ backendId: "foundry-eus2", apimId: "ccof-apim", host: "foundry-eus2.services.ai.azure.com" }, { backendId: "foundry-swc", apimId: "ccof-apim", host: "foundry-swc.services.ai.azure.com" }, { backendId: "foundry-wus3", apimId: "ccof-apim", host: "foundry-wus3.services.ai.azure.com" }],
    truncated: false, warnings: [],
  } }),
  deployments: async (id) => ({ state: "available", observedAt: now(), data: { truncated: false, deployments: id.endsWith("foundry-swc")
    ? [{ name: "claude-sonnet-5", model: "claude-sonnet-5", state: "Succeeded" }, { name: "claude-haiku-4-5", model: "claude-haiku-4-5", state: "Succeeded" }]
    : [{ name: "claude-sonnet-5", model: "claude-sonnet-5", state: "Succeeded" }, { name: "claude-haiku-4-5", model: "claude-haiku-4-5", state: "Succeeded" }, { name: "claude-opus-5-5", model: "claude-opus-5-5", state: "Succeeded" }] } }),
  health: async () => ({ state: "available", observedAt: now(), data: [
    { name: "Gateway (APIM)", state: "endpoint_responding", httpStatus: 200, observedAt: now(), evidence: "HTTP response only; not model inference, billing or timer freshness" },
    { name: "Resolver function", state: "endpoint_responding", httpStatus: 200, observedAt: now(), evidence: "HTTP response only; not model inference, billing or timer freshness" },
    { name: "Foundry westus3", state: "unreachable", reason: "dns_network_tls_or_timeout", observedAt: now() },
  ] }),
  query: async (_workspaceId, _query, _timespan, meta) => telemetry.query(meta, auditLines),
} : realOperations;
const demoEnv = mode === "seeded" ? {
  ADMIN_WORKSPACE_ID: "11111111-2222-4333-8444-555555555555",
  ADMIN_GATEWAY_RESOURCE_ID: "/subscriptions/3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11/resourceGroups/ccof-rg/providers/Microsoft.ApiManagement/service/ccof-apim",
  ADMIN_LOG_RESOURCE_IDS: "/subscriptions/3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11/resourceGroups/ccof-rg/providers/Microsoft.Web/sites/ccof-reconciler",
  ADMIN_RECONCILER_INTERVAL_MINUTES: "5",
  // Client onboarding downloads (V3 project → Onboarding). Demo values, not a real tenant.
  ADMIN_TENANT_ID: "0f1e2d3c-4b5a-4968-8776-655443322110",
  ADMIN_CLIENT_ID: "5d6e7f80-9a1b-4c2d-8e3f-405162738495",
  ADMIN_GATEWAY_URL: "https://ccof-apim.azure-api.net/claude",
} : {};
const kql = (name: string) => readFile(new URL(`../kql/${name}`, import.meta.url), "utf8");
const sources = await Promise.all([kql("ledger.kql"), kql("pricing.kql"), kql("budgets.kql")]).then(([ledger, pricing, budgets]) => ({ ledger, pricing, budgets })).catch(() => null);
const v3Cache = new QueryCache();
const V3_ENABLED = process.env.ADMIN_V3_ENABLED !== "false";

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://127.0.0.1:${PORT}`);
  const send = (status: number, headers: Record<string, string> | undefined, body: string) => { res.writeHead(status, headers); res.end(body); };
  const sendJson = (status: number, value: unknown, headers: Record<string, string> = {}) =>
    send(status, { "content-type": "application/json", "cache-control": "no-store", ...headers }, JSON.stringify(value));

  if (url.pathname === "/" ) return send(302, { location: V3_ENABLED ? "/api/console-v3#/overview" : "/api/console", "cache-control": "no-store" }, "");
  const ui = /^\/api\/console(?:\/([^/]*))?$/.exec(url.pathname);
  if (ui) {
    const asset = ui[1] ?? "";
    if (asset === "config") return sendJson(200, { configured: true, demo: true });
    if (asset === "me") {
      try { const actor = await authenticate(req.headers.authorization ?? null); return sendJson(200, { canWrite: actor.canWrite }); }
      catch (err) { return sendJson((err as ApiError).status ?? 500, { error: (err as ApiError).code ?? "internal_error" }); }
    }
    const r = await serveUi(asset, UI);
    return send(r.status, r.headers, r.body);
  }
  const uiV3 = /^\/api\/console-v3(?:\/([^/]*))?$/.exec(url.pathname);
  if (uiV3) {
    const asset = uiV3[1] ?? "";
    if (!V3_ENABLED) return send(404, { "content-type": "text/plain" }, "Not found");
    if (asset === "config") return sendJson(200, { configured: true, demo: true });
    const r = await serveUiV3(asset, V3_ENABLED, UI_V3);
    return send(r.status, r.headers, r.body);
  }
  if (url.pathname.startsWith("/api/projects") || url.pathname.startsWith("/api/v2/") || url.pathname.startsWith("/api/v3/")) {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const body = chunks.length ? Buffer.concat(chunks).toString("utf8") : null;
    const request = { method: req.method ?? "GET", path: url.pathname + url.search, headers: (n: string) => { const v = req.headers[n.toLowerCase()]; return Array.isArray(v) ? v[0] : v ?? null; }, body };
    if (url.pathname.startsWith("/api/v3/") && !V3_ENABLED) return sendJson(404, { error: "route_not_found" });
    const r = url.pathname.startsWith("/api/v3/")
      ? await handleV3Request(request, { authenticate, projects: store, catalogStore, defaultCatalog, operations, env: demoEnv, sources, cache: v3Cache, log: demoLog, now: () => new Date(), newId: randomUUID })
      : url.pathname.startsWith("/api/v2/")
        ? await handleV2Request(request, { authenticate, projects: store, catalogStore, defaultCatalog, operations, log: demoLog, now: () => new Date(), newId: randomUUID })
        : await handleAdminRequest(request, { authenticate, store, log: demoLog, now: () => new Date(), newId: randomUUID });
    return sendJson(r.status, r.jsonBody, r.headers);
  }
  send(404, { "content-type": "text/plain" }, "Not found");
});

server.listen(PORT, "127.0.0.1", () => console.log(`CCOF admin demo (${mode}) at http://127.0.0.1:${PORT}/api/console and /api/console-v3`));