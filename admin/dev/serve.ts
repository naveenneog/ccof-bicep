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
import { serveUi } from "../src/ui.ts";
import type { Doc } from "../src/validation.ts";
import { handleV2Request } from "../src/v2.ts";
import type { CatalogStore } from "../src/v2.ts";
import { createOperations } from "../src/operations.ts";

const PORT = Number(process.env.PORT ?? 7171);
const UI = fileURLToPath(new URL("../ui-dist/", import.meta.url));
const mode = process.env.DEMO_REGISTRY ?? "seeded";

const limit = (tpm: number | null, quota: number | null, period: string | null = quota === null ? null : "Monthly") =>
  ({ tokensPerMinute: tpm, tokenQuota: quota, tokenQuotaPeriod: period });

function seed(id: string, name: string, classes: Record<string, { group: string; groupName: string; families: Record<string, string[]> }>): Doc {
  return {
    id, projectId: id, displayName: name, status: "active", backendId: "foundry-eus2",
    designatedSubscriptionId: "3c1d5a0e-8f2b-4c6d-9e1a-7b2f4d8c0a11", supersedes: null, retiredAt: null,
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
  async listPage(query: { search: string; tag: string; backendId: string; limit: number; cursor?: string }) {
    const all = (await this.list()).filter((p) => `${p.doc.projectId} ${p.doc.displayName}`.toLowerCase().includes(query.search.toLowerCase()) &&
      (!query.tag || Array.isArray(p.doc.adminTags) && p.doc.adminTags.includes(query.tag)) && (!query.backendId || p.doc.backendId === query.backendId));
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
      INT: { group: "7a4b3d2f-5c6e-4f9a-8b1c-2d3e4f5a6b7c", groupName: "PROJECT01-INT", families: { sonnet: ["claude-sonnet-4-5"], opus: ["claude-opus-4-1"] } },
    }),
    seed("PROJECT02", "Customer support copilots", {
      STD: { group: "8b5c4e3a-6d7f-4a0b-9c2d-3e4f5a6b7c8d", groupName: "PROJECT02-STD", families: { sonnet: ["claude-sonnet-4-5"] } },
    }),
  ]) await store.create(doc);
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
// Demo-only synthetic reconciler group lines so the budget views render populated; never used in Azure.
const demoBudgetRows = () => {
  const now = new Date();
  const period = now.toISOString().slice(0, 7);
  const row = (projectId: string, classification: string, spentCcu: string, budgetCcu: string | null, extra: Doc = {}): Doc => ({
    scope: "group", scopeId: `${projectId}:${classification}`, projectId, classification, spentCcu, budgetCcu,
    exhausted: budgetCcu !== null && Number(spentCcu) >= Number(budgetCcu), mode: "strict", completeness: "complete",
    activeMemberCount: 6, rateCardVersion: "demo", period, computedAt: new Date(now.getTime() - 3600_000).toISOString(),
    validUntil: new Date(now.getTime() + 3600_000).toISOString(), ...extra,
  });
  return [row("PROJECT01", "STD", "112450.5", "150000"), row("PROJECT01", "INT", "151200", "150000"),
    row("PROJECT02", "STD", "38210.0004", "150000", { completeness: "partial" })];
};
const operations = mode === "seeded"
  ? { ...realOperations, logs: async (kind: "budgets" | "audit" | "runs") => kind === "budgets"
    ? { state: "available" as const, observedAt: new Date().toISOString(), data: demoBudgetRows() } : realOperations.logs(kind) }
  : realOperations;

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://127.0.0.1:${PORT}`);
  const send = (status: number, headers: Record<string, string> | undefined, body: string) => { res.writeHead(status, headers); res.end(body); };
  const sendJson = (status: number, value: unknown, headers: Record<string, string> = {}) =>
    send(status, { "content-type": "application/json", "cache-control": "no-store", ...headers }, JSON.stringify(value));

  if (url.pathname === "/" ) return send(302, { location: "/api/console" }, "");
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
  if (url.pathname.startsWith("/api/projects") || url.pathname.startsWith("/api/v2/")) {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const body = chunks.length ? Buffer.concat(chunks).toString("utf8") : null;
    const request = { method: req.method ?? "GET", path: url.pathname + url.search, headers: (n: string) => { const v = req.headers[n.toLowerCase()]; return Array.isArray(v) ? v[0] : v ?? null; }, body };
    const r = url.pathname.startsWith("/api/v2/")
      ? await handleV2Request(request, { authenticate, projects: store, catalogStore, defaultCatalog, operations, log: console.log, now: () => new Date(), newId: randomUUID })
      : await handleAdminRequest(request, { authenticate, store, log: (line) => console.log(line), now: () => new Date(), newId: randomUUID });
    return sendJson(r.status, r.jsonBody, r.headers);
  }
  send(404, { "content-type": "text/plain" }, "Not found");
});

server.listen(PORT, "127.0.0.1", () => console.log(`CCOF admin demo (${mode}) at http://127.0.0.1:${PORT}/api/console`));
