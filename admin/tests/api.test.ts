import { test } from "node:test";
import assert from "node:assert/strict";
import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair } from "jose";
import { AUDIT_SCHEMA, handleAdminRequest } from "../src/api.ts";
import type { ApiDependencies, ApiRequest, ProjectStore, StoredProject } from "../src/api.ts";
import { createAuthenticator, readAuthConfig } from "../src/auth.ts";
import type { Doc } from "../src/validation.ts";

const TENANT = "00000000-0000-4000-8000-000000000001";
const AUDIENCE = "api://ccof-admin-test";
const CLIENT = "00000000-0000-4000-8000-000000000002";
const EDITOR = "00000000-0000-4000-8000-0000000000e1";
const READER = "00000000-0000-4000-8000-0000000000a1";
const STRANGER = "00000000-0000-4000-8000-0000000000f1";
const GROUP_A = "00000000-0000-4000-8000-0000000000c1";
const GROUP_B = "00000000-0000-4000-8000-0000000000c2";

const limit = (tpm: number, quota: number | null) => ({ tokensPerMinute: tpm, tokenQuota: quota, tokenQuotaPeriod: quota === null ? null : "Monthly" });

function project(id = "PROJECT02"): Doc {
  return {
    id, projectId: id, displayName: "Project 02", status: "active", backendId: "backend01",
    designatedSubscriptionId: "00000000-0000-4000-8000-0000000000b1", supersedes: null, retiredAt: null,
    classifications: {
      STD: {
        groupId: GROUP_A, classificationGroupDisplayName: "PROJECT02-STD",
        familyPolicy: {
          aggregateLimits: { person: limit(10000, 1000000), group: limit(50000, 10000000) },
          families: { sonnet: { models: ["claude-sonnet-4-5"], person: limit(10000, 1000000), group: limit(50000, 10000000) } },
        },
        personBudget: { amount: 10, currency: "USD", period: "monthly" },
        aggregateBudget: { amount: 100, currency: "USD", period: "monthly" },
        aggregateMode: "strict", onboardingMode: "block",
      },
    },
  };
}

class FakeStore implements ProjectStore {
  docs = new Map<string, StoredProject>();
  version = 0;
  writes = 0;
  private tag() { return `"etag-${++this.version}"`; }
  async list() { return [...this.docs.values()].map((p) => structuredClone(p)); }
  async read(id: string) { const p = this.docs.get(id); return p ? structuredClone(p) : null; }
  async create(doc: Doc) {
    const id = String(doc.projectId);
    if (this.docs.has(id)) return "conflict" as const;
    const etag = this.tag(); this.writes++;
    this.docs.set(id, { doc: { ...structuredClone(doc), _etag: etag, _ts: 1 }, etag });
    return etag;
  }
  async replace(doc: Doc, etag: string) {
    const id = String(doc.projectId);
    const cur = this.docs.get(id);
    if (!cur || cur.etag !== etag) return "precondition_failed" as const;
    const next = this.tag(); this.writes++;
    this.docs.set(id, { doc: { ...structuredClone(doc), _etag: next }, etag: next });
    return next;
  }
}

const { publicKey, privateKey } = await generateKeyPair("RS256");
const keys = createLocalJWKSet({ keys: [{ ...(await exportJWK(publicKey)), kid: "k1", alg: "RS256" }] });

async function token(oid: string, extra: Record<string, unknown> = {}) {
  const { aud, ...claims } = extra;
  return new SignJWT({ tid: TENANT, oid, azp: CLIENT, scp: "Projects.Manage", ...claims })
    .setProtectedHeader({ alg: "RS256", kid: "k1" })
    .setIssuer(`https://login.microsoftonline.com/${TENANT}/v2.0`)
    .setAudience(typeof aud === "string" ? aud : AUDIENCE).setIssuedAt().setExpirationTime("10m").sign(privateKey);
}

const config = readAuthConfig({
  ADMIN_TENANT_ID: TENANT, ADMIN_AUDIENCE: AUDIENCE, ADMIN_SCOPE: "Projects.Manage",
  ADMIN_ALLOWED_CLIENT_IDS: CLIENT, ADMIN_READER_IDS: READER, ADMIN_EDITOR_IDS: EDITOR,
});

interface CallOptions { oid?: string; body?: unknown; ifMatch?: string; auth?: string | null; tokenExtra?: Record<string, unknown> }

function setup(store: FakeStore | null = new FakeStore()) {
  const lines: string[] = [];
  const deps: ApiDependencies = { authenticate: createAuthenticator(config, keys), store, log: (l) => lines.push(l), now: () => new Date("2026-10-16T00:00:00Z"), newId: () => "req-1" };
  const call = async (method: string, path: string, opts: CallOptions = {}) => {
    const authz = opts.auth !== undefined ? opts.auth : `Bearer ${await token(opts.oid ?? EDITOR, opts.tokenExtra)}`;
    const headers: Record<string, string | null> = { authorization: authz, "if-match": opts.ifMatch ?? null };
    const body = opts.body === undefined ? null : typeof opts.body === "string" ? opts.body : JSON.stringify(opts.body);
    const req: ApiRequest = { method, path, headers: (n) => headers[n.toLowerCase()] ?? null, body };
    return handleAdminRequest(req, deps);
  };
  const audits = () => lines.map((l) => JSON.parse(l)).filter((l) => l.schema === AUDIT_SCHEMA);
  return { call, audits, store: store as FakeStore };
}

const policyOf = (doc: Doc) => ((doc.classifications as Doc).STD as Doc).familyPolicy as Doc;

test("unauthenticated, wrong audience, wrong client, wrong scope, wrong tenant and non-admin callers are refused", async () => {
  const { call, store } = setup();
  assert.equal((await call("GET", "/api/projects", { auth: null })).status, 401);
  assert.equal((await call("GET", "/api/projects", { auth: "Bearer not.a.token" })).status, 401);
  assert.equal((await call("GET", "/api/projects", { tokenExtra: { aud: "api://other" } })).status, 401);
  assert.equal((await call("GET", "/api/projects", { tokenExtra: { azp: "00000000-0000-4000-8000-00000000dead" } })).status, 403);
  assert.equal((await call("GET", "/api/projects", { tokenExtra: { scp: "User.Read" } })).status, 403);
  assert.equal((await call("GET", "/api/projects", { tokenExtra: { tid: "00000000-0000-4000-8000-000000000999" } })).status, 403);
  assert.equal((await call("GET", "/api/projects", { oid: STRANGER })).status, 403);
  assert.equal((await call("POST", "/api/projects", { oid: STRANGER, body: project() })).status, 403);
  assert.equal(store.writes, 0);
});

test("missing authentication configuration fails closed", async () => {
  const res = await handleAdminRequest({ method: "GET", path: "/api/projects", headers: () => null, body: null },
    { authenticate: null, store: new FakeStore(), log: () => {}, now: () => new Date(), newId: () => "x" });
  assert.equal(res.status, 503);
  assert.equal((res.jsonBody as Doc).error, "admin_auth_not_configured");
  assert.throws(() => readAuthConfig({ ADMIN_TENANT_ID: TENANT, ADMIN_AUDIENCE: AUDIENCE, ADMIN_SCOPE: "s", ADMIN_ALLOWED_CLIENT_IDS: "" }));
  assert.throws(() => readAuthConfig({ ADMIN_TENANT_ID: TENANT, ADMIN_AUDIENCE: AUDIENCE, ADMIN_SCOPE: "s", ADMIN_ALLOWED_CLIENT_IDS: CLIENT, ADMIN_EDITOR_IDS: "not-a-guid" }));
});

test("an app role grants access without an object-id list", async () => {
  const { call } = setup();
  assert.equal((await call("GET", "/api/projects", { oid: STRANGER, tokenExtra: { roles: ["CCOF.Projects.Read"] } })).status, 200);
  assert.equal((await call("POST", "/api/projects", { oid: STRANGER, tokenExtra: { roles: ["CCOF.Projects.Read"] }, body: project() })).status, 403);
  assert.equal((await call("POST", "/api/projects", { oid: STRANGER, tokenExtra: { roles: ["CCOF.Projects.Write"] }, body: project() })).status, 201);
});

test("create validates with the sync's own rules, refuses duplicates and audits", async () => {
  const { call, audits, store } = setup();
  const res = await call("POST", "/api/projects", { body: project() });
  assert.equal(res.status, 201);
  assert.ok(res.headers?.etag);
  assert.equal((await call("POST", "/api/projects", { body: project() })).status, 409);
  const bad = project("BAD01");
  policyOf(bad).aggregateLimits = { person: limit(0, 5), group: limit(1, 5) };
  const refused = await call("POST", "/api/projects", { body: bad });
  assert.equal(refused.status, 422);
  assert.ok(((refused.jsonBody as Doc).problems as string[]).some((p) => p.includes("familyPolicy")));
  assert.equal((await call("POST", "/api/projects", { body: { ...project("RET01"), status: "retired" } })).status, 422);
  assert.equal((await call("POST", "/api/projects", { body: { ...project("EXTRA01"), owner: "x" } })).status, 422);
  assert.equal((await call("POST", "/api/projects", { body: { ...project("ID01"), id: "ID02" } })).status, 422);
  assert.equal((await call("POST", "/api/projects", { body: { ...project("SUB01"), designatedSubscriptionId: "x" } })).status, 422);
  assert.equal(store.writes, 1);
  const created = audits().find((x) => x.outcome === "created");
  assert.equal(created.actorOid, EDITOR);
  assert.equal(created.projectId, "PROJECT02");
  assert.ok(audits().some((x) => x.outcome === "refused" && x.status === 409));
});

test("a reader can list and read but cannot write", async () => {
  const { call, store } = setup();
  await call("POST", "/api/projects", { body: project() });
  const list = await call("GET", "/api/projects", { oid: READER });
  assert.equal(list.status, 200);
  assert.deepEqual(((list.jsonBody as Doc).projects as Doc[]).map((p) => p.projectId), ["PROJECT02"]);
  const read = await call("GET", "/api/projects/PROJECT02", { oid: READER });
  assert.equal(read.status, 200);
  assert.ok(!Object.keys(read.jsonBody as Doc).some((k) => k.startsWith("_")));
  const etag = read.headers!.etag;
  const patch = { aggregateLimits: { person: limit(20000, 2000000) } };
  assert.equal((await call("PATCH", "/api/projects/PROJECT02/classifications/STD/limits", { oid: READER, ifMatch: etag, body: patch })).status, 403);
  assert.equal((await call("POST", "/api/projects", { oid: READER, body: project("P3") })).status, 403);
  assert.equal(store.writes, 1);
  assert.equal((await call("GET", "/api/projects/NOPE", { oid: READER })).status, 404);
});

test("limits patch requires If-Match, rejects stale ETags and records before/after", async () => {
  const { call, audits } = setup();
  const etag = (await call("POST", "/api/projects", { body: project() })).headers!.etag;
  const path = "/api/projects/PROJECT02/classifications/STD/limits";
  const patch = { aggregateLimits: { person: { tokensPerMinute: 20000, tokenQuota: 2000000 } } };
  assert.equal((await call("PATCH", path, { body: patch })).status, 428);
  assert.equal((await call("PATCH", path, { body: patch, ifMatch: "*" })).status, 428);
  assert.equal((await call("PATCH", path, { body: patch, ifMatch: '"stale"' })).status, 412);
  const ok = await call("PATCH", path, { body: patch, ifMatch: etag });
  assert.equal(ok.status, 200);
  assert.notEqual(ok.headers!.etag, etag);
  assert.deepEqual((policyOf((ok.jsonBody as Doc).project as Doc).aggregateLimits as Doc).person,
    { tokensPerMinute: 20000, tokenQuota: 2000000, tokenQuotaPeriod: "Monthly" });
  assert.equal((await call("PATCH", path, { body: patch, ifMatch: etag })).status, 412, "the old ETag is now stale");
  const updated = audits().find((x) => x.outcome === "updated");
  assert.deepEqual(updated.changes.map((c: Doc) => c.path).sort(), [
    "classifications.STD.familyPolicy.aggregateLimits.person.tokenQuota",
    "classifications.STD.familyPolicy.aggregateLimits.person.tokensPerMinute",
  ]);
  assert.equal(updated.changes.find((c: Doc) => String(c.path).endsWith("tokensPerMinute")).before, 10000);
  assert.equal(updated.etagBefore, etag);
});

test("a concurrent writer that loses the ETag race gets 412 and does not overwrite", async () => {
  const store = new FakeStore();
  const { call } = setup(store);
  const etag = (await call("POST", "/api/projects", { body: project() })).headers!.etag;
  const path = "/api/projects/PROJECT02/classifications/STD/limits";
  const realReplace = store.replace.bind(store);
  let raced = false;
  store.replace = async (doc, tag) => {
    if (!raced) { raced = true; const other = structuredClone(store.docs.get("PROJECT02")!.doc); await realReplace(other, tag); }
    return realReplace(doc, tag);
  };
  const res = await call("PATCH", path, { body: { aggregateLimits: { person: { tokensPerMinute: 30000 } } }, ifMatch: etag });
  assert.equal(res.status, 412);
  assert.equal(((policyOf(store.docs.get("PROJECT02")!.doc).aggregateLimits as Doc).person as Doc).tokensPerMinute, 10000);
});

test("invalid limit values are refused and nothing is written", async () => {
  const { call, store } = setup();
  const etag = (await call("POST", "/api/projects", { body: project() })).headers!.etag;
  const path = "/api/projects/PROJECT02/classifications/STD/limits";
  for (const body of [
    { aggregateLimits: { person: { tokensPerMinute: 0 } } },
    { aggregateLimits: { person: { tokenQuota: null } } },
    { aggregateLimits: { person: { tokenQuotaPeriod: "monthly" } } },
    { aggregateLimits: { person: { tokensPerMinute: 1.5 } } },
    { aggregateLimits: { person: { tokensPerMinute: "10" } } },
    { families: { opus: { person: { tokensPerMinute: 10 } } } },
    { aggregateLimits: { person: { extra: 1 } } },
    {},
  ]) {
    assert.equal((await call("PATCH", path, { body, ifMatch: etag })).status, 422, JSON.stringify(body));
  }
  assert.equal(store.writes, 1);
  const ok = await call("PATCH", path, { body: { aggregateLimits: { person: { tokenQuota: null, tokenQuotaPeriod: null } } }, ifMatch: etag });
  assert.equal(ok.status, 200, "disabling a quota sets both values to null");
  assert.equal(store.writes, 2);
});

test("family-policy replace changes models and limits only; ids, groups and backend are untouched", async () => {
  const { call, store } = setup();
  const etag = (await call("POST", "/api/projects", { body: project() })).headers!.etag;
  const path = "/api/projects/PROJECT02/classifications/STD/family-policy";
  const policy = structuredClone(policyOf(project()));
  ((policy.families as Doc).sonnet as Doc).models = ["claude-sonnet-4-5", "claude-sonnet-4-6"];
  const ok = await call("PUT", path, { body: policy, ifMatch: etag });
  assert.equal(ok.status, 200);
  assert.deepEqual(((policyOf(store.docs.get("PROJECT02")!.doc).families as Doc).sonnet as Doc).models, ["claude-sonnet-4-5", "claude-sonnet-4-6"]);
  const unchanged = await call("PUT", path, { body: policy, ifMatch: ok.headers!.etag });
  assert.equal(unchanged.status, 200);
  assert.equal((unchanged.jsonBody as Doc).changed, false);
  const misfiled = structuredClone(policy);
  ((misfiled.families as Doc).sonnet as Doc).models = ["claude-opus-4-1"];
  assert.equal((await call("PUT", path, { body: misfiled, ifMatch: ok.headers!.etag })).status, 422);
  assert.equal((await call("PUT", "/api/projects/PROJECT02/classifications/NOPE/family-policy", { body: policy, ifMatch: ok.headers!.etag })).status, 404);
  const stored = store.docs.get("PROJECT02")!.doc;
  assert.equal(stored.backendId, "backend01");
  assert.equal(((stored.classifications as Doc).STD as Doc).groupId, GROUP_A);
});

test("STD, PRM and CYB are created together and keep independent limits", async () => {
  const { call, store } = setup();
  const doc = project("THREE01");
  const classifications = doc.classifications as Doc;
  for (const [code, groupId, tpm] of [
    ["PRM", GROUP_B, 25000],
    ["CYB", "00000000-0000-4000-8000-0000000000c3", 40000],
  ] as const) {
    const classification = structuredClone(classifications.STD as Doc);
    classification.groupId = groupId;
    classification.classificationGroupDisplayName = `THREE01-${code}`;
    (((classification.familyPolicy as Doc).aggregateLimits as Doc).person as Doc).tokensPerMinute = tpm;
    classifications[code] = classification;
  }
  assert.equal((await call("POST", "/api/projects", { body: doc })).status, 201);
  const saved = await call("GET", "/api/projects/THREE01");
  assert.equal(saved.status, 200);
  assert.deepEqual((saved.jsonBody as Doc).classifications, classifications);
  const updated = await call("PATCH", "/api/projects/THREE01/classifications/PRM/limits", {
    ifMatch: saved.headers!.etag,
    body: { aggregateLimits: { person: { tokensPerMinute: 35000 } } },
  });
  assert.equal(updated.status, 200);
  const stored = store.docs.get("THREE01")!.doc.classifications as Doc;
  assert.deepEqual(stored.STD, classifications.STD);
  assert.deepEqual(stored.CYB, classifications.CYB);
  assert.equal(((((stored.PRM as Doc).familyPolicy as Doc).aggregateLimits as Doc).person as Doc).tokensPerMinute, 35000);
});

test("duplicate groups across classifications are refused", async () => {
  const { call } = setup();
  const doc = project("DUP01");
  (doc.classifications as Doc).INT = { ...structuredClone((doc.classifications as Doc).STD as Doc), groupId: GROUP_A };
  assert.equal((await call("POST", "/api/projects", { body: doc })).status, 422);
  ((doc.classifications as Doc).INT as Doc).groupId = GROUP_B;
  assert.equal((await call("POST", "/api/projects", { body: doc })).status, 201);
});

test("unsupported operations and oversized or malformed bodies are refused", async () => {
  const { call } = setup();
  assert.equal((await call("DELETE", "/api/projects/PROJECT02")).status, 405);
  assert.equal((await call("PUT", "/api/projects/PROJECT02")).status, 405);
  assert.equal((await call("GET", "/api/other")).status, 404);
  assert.equal((await call("POST", "/api/projects", { body: "{not json" })).status, 400);
  assert.equal((await call("POST", "/api/projects", { body: "x".repeat(70 * 1024) })).status, 413);
});

test("store not configured is reported as unavailable, after authentication", async () => {
  const { call } = setup(null);
  const res = await call("GET", "/api/projects");
  assert.equal(res.status, 503);
  assert.equal((res.jsonBody as Doc).error, "project_store_not_configured");
  assert.equal((await call("GET", "/api/projects", { auth: null })).status, 401);
});

test("a registry failure is reported as 503 registry_unavailable without provider detail", async () => {
  const store = new FakeStore();
  store.list = async () => { throw Object.assign(new Error("Request originated from IP 203.0.113.9 through public internet"), { code: 403 }); };
  const { call } = setup(store);
  const res = await call("GET", "/api/projects");
  assert.equal(res.status, 503);
  assert.equal((res.jsonBody as Doc).error, "registry_unavailable");
  assert.ok(!JSON.stringify(res.jsonBody).includes("203.0.113.9"));
});

test("the UI server serves only known assets with a strict CSP and public-only configuration", async () => {
  const { serveUi, publicUiConfig } = await import("../src/ui.ts");
  const base = new URL("../ui/", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
  const page = await serveUi("", base);
  assert.equal(page.status, 200);
  assert.match(page.headers["content-security-policy"], /default-src 'none'/);
  assert.match(page.headers["content-security-policy"], /frame-ancestors 'none'/);
  assert.equal((await serveUi("../package.json", base)).status, 404);
  assert.equal((await serveUi("secrets.txt", base)).status, 404);
  assert.deepEqual(publicUiConfig({}), { configured: false });
  const cfg = publicUiConfig({ ADMIN_TENANT_ID: TENANT, ADMIN_UI_CLIENT_ID: CLIENT, ADMIN_UI_SCOPE: "api://x/Projects.Manage", ADMIN_EDITOR_IDS: EDITOR });
  assert.deepEqual(Object.keys(cfg).sort(), ["clientId", "configured", "scope", "tenantId"]);
});
