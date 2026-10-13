// The quick-start's registry seed (src/sync/registry-seed.ts; ADR-0024, D-7 Proposed): a timer in the
// sync app creates the projects and backends documents that Deploy-Quickstart.ps1 step 5 passes in
// the app setting CCOF_SEED_DOCUMENTS, for a tenant whose policy denies marketplace VM images (no
// runner VM inside the VNet). Create only: an existing document (409) is read back and its seeded
// fields compared, never replaced. One ccof.seed.result.v1 line per run, with ids, outcomes, field
// names and short codes only. Tested with a fake Cosmos container; no Azure SDK is loaded.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { BACKENDS_CONTAINER, MAX_SEED_SETTING_LENGTH, SEED_FUNCTION_NAME, SEED_SCHEDULE, SEED_SETTING, runRegistrySeed } from "../src/sync/registry-seed.ts";
import type { SeedContainer, SeedDependencies, SeedStore } from "../src/sync/registry-seed.ts";
import type { SyncConfig } from "../src/sync/config.ts";
import { GROUP_PRM, GROUP_STD, ManualClock, TENANT } from "./helpers/sync-fakes.ts";

const SEED_ID = "0123456789abcdef0123456789abcdef";
const ENDPOINT = "https://example-sampleqs-cosmos.documents.azure.com:443/";
const CLIENT_ID = "00000000-0000-4000-8000-000001110000";
const SUBSCRIPTION = "00000000-0000-4000-8000-000001110001";

// The sync app's settings (infra/quickstart/modules/app-settings.bicep): the seed uses the sync's own
// Cosmos settings and managed identity.
const SETTINGS: Record<string, string> = {
  SYNC_TENANT_ID: TENANT,
  COSMOS_ENDPOINT: ENDPOINT,
  COSMOS_DATABASE: "ccof",
  SYNC_PROJECTS_CONTAINER: "projects",
  SYNC_ENTITLEMENT_CONTAINER: "entitlement",
  SYNC_LEASE_CONTAINER: "syncLease",
  SYNC_LEASE_SECONDS: "300",
  SYNC_MEMBER_TYPES: "user",
  SYNC_MAX_REMOVALS_PER_RUN: "5",
  SYNC_MAX_REMOVAL_FRACTION: "0.1",
  SYNC_GRAPH_MAX_RETRIES: "3",
  SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS: "30",
  SYNC_GRAPH_TIMEOUT_SECONDS: "30",
  SYNC_WRITE_MODE: "apply",
  SYNC_MANAGED_IDENTITY_CLIENT_ID: CLIENT_ID,
  SYNC_SCHEDULE: "0 */1 * * * *",
};

function aggregateLimits() {
  return {
    person: { tokensPerMinute: 1000000, tokenQuota: 500000, tokenQuotaPeriod: "Daily" },
    group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: "Daily" },
  };
}
function familyPolicy(models: string[]) {
  const families: Record<string, unknown> = {};
  for (const model of models) {
    const family = model.split("-")[1];
    const entry = families[family] as { models: string[] } | undefined;
    if (entry) entry.models.push(model);
    else families[family] = { models: [model], ...aggregateLimits() };
  }
  return { aggregateLimits: aggregateLimits(), families };
}

// The shape New-QsSeedDocuments builds (infra/quickstart/Deploy-Quickstart.ps1).
function project(projectId = "sampleqs01"): Record<string, unknown> {
  return {
    id: projectId,
    projectId,
    displayName: projectId,
    status: "active",
    backendId: "foundry-1",
    designatedSubscriptionId: SUBSCRIPTION,
    supersedes: null,
    retiredAt: null,
    classifications: {
      STD: {
        groupId: GROUP_STD,
        personBudget: { amount: 25000, currency: "CCU", period: "monthly" },
        aggregateBudget: { amount: 2000000, currency: "CCU", period: "monthly" },
        aggregateMode: "strict",
        onboardingMode: "block",
        familyPolicy: familyPolicy(["claude-haiku-4-5", "claude-sonnet-5"]),
      },
      PRM: {
        groupId: GROUP_PRM,
        personBudget: { amount: 100000, currency: "CCU", period: "monthly" },
        aggregateBudget: null,
        aggregateMode: "notify",
        onboardingMode: "warn",
        familyPolicy: familyPolicy(["claude-opus-5"]),
      },
    },
  };
}

function backend(backendId = "foundry-1"): Record<string, unknown> {
  return { id: backendId, backendId, status: "active", apiFormat: "anthropic-messages", auth: { mode: "managed-identity", resource: "https://cognitiveservices.azure.com" } };
}

function encode(payload: unknown): string {
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64");
}

function seedSettings(payload: unknown = { seedId: SEED_ID, projects: [project()], backends: [backend()] }): Record<string, string> {
  return { ...SETTINGS, [SEED_SETTING]: encode(payload) };
}

type Call = { op: "create" | "read"; container: SeedContainer; id: string; partitionKey: string };

// A fake Cosmos database with the two containers and their partition keys (/projectId, /backendId).
class FakeCosmos implements SeedStore {
  readonly docs = new Map<string, Record<string, unknown>>();
  readonly calls: Call[] = [];
  readonly failCreate = new Map<string, number | Error>();
  readonly failRead = new Map<string, number | Error>();
  // container/id answered 409 on create, and gone when read back (deleted in between).
  readonly vanished = new Set<string>();
  private static readonly PARTITION_KEY: Record<SeedContainer, string> = { projects: "projectId", backends: "backendId" };

  put(container: SeedContainer, doc: Record<string, unknown>): void {
    const partitionKey = String(doc[FakeCosmos.PARTITION_KEY[container]]);
    this.docs.set(`${container}/${partitionKey}/${String(doc.id)}`, { ...structuredClone(doc), _rid: "rid", _self: "self", _etag: '"etag"', _attachments: "attachments/", _ts: 1760000000 });
  }

  async create(container: SeedContainer, doc: Record<string, unknown>): Promise<"created" | "conflict"> {
    const partitionKey = String(doc[FakeCosmos.PARTITION_KEY[container]]);
    this.calls.push({ op: "create", container, id: String(doc.id), partitionKey });
    const fail = this.failCreate.get(`${container}/${String(doc.id)}`);
    if (fail !== undefined) throw typeof fail === "number" ? Object.assign(new Error("fake cosmos error"), { code: fail }) : fail;
    if (this.vanished.has(`${container}/${String(doc.id)}`)) return "conflict";
    if (this.docs.has(`${container}/${partitionKey}/${String(doc.id)}`)) return "conflict";
    this.put(container, doc);
    return "created";
  }

  async read(container: SeedContainer, id: string, partitionKey: string): Promise<Record<string, unknown> | null> {
    this.calls.push({ op: "read", container, id, partitionKey });
    const fail = this.failRead.get(`${container}/${id}`);
    if (fail !== undefined) throw typeof fail === "number" ? Object.assign(new Error("fake cosmos error"), { statusCode: fail }) : fail;
    const doc = this.docs.get(`${container}/${partitionKey}/${id}`);
    return doc ? structuredClone(doc) : null;
  }
}

function harness(store = new FakeCosmos()) {
  const lines: string[] = [];
  const opened: { config: SyncConfig; clientId: string }[] = [];
  const clock = new ManualClock("2026-10-13T13:00:00.000Z");
  const deps: SeedDependencies = {
    openStore: (config, clientId) => {
      opened.push({ config, clientId });
      clock.advance(2);
      return store;
    },
    log: (line) => lines.push(line),
    now: clock.now,
  };
  const parsed = () => lines.map((l) => JSON.parse(l) as Record<string, unknown>);
  return { store, lines, opened, deps, parsed };
}

function onlyLine(h: ReturnType<typeof harness>): Record<string, any> {
  assert.equal(h.lines.length, 1, `expected one log line, got ${h.lines.length}`);
  return h.parsed()[0] as Record<string, any>;
}

test("absent setting: no Cosmos call and no log line", async () => {
  const h = harness();
  const result = await runRegistrySeed({ ...SETTINGS }, h.deps);
  assert.equal(result, null);
  assert.equal(h.opened.length, 0);
  assert.equal(h.store.calls.length, 0);
  assert.equal(h.lines.length, 0);
});

test("empty or blank setting: no Cosmos call and no log line", async () => {
  for (const value of ["", "   ", "\n"]) {
    const h = harness();
    assert.equal(await runRegistrySeed({ ...SETTINGS, [SEED_SETTING]: value }, h.deps), null, JSON.stringify(value));
    assert.equal(h.opened.length + h.store.calls.length + h.lines.length, 0, JSON.stringify(value));
  }
});

test("201: every document is created with its partition key, backends first, and one result line names each", async () => {
  const h = harness();
  const result = await runRegistrySeed(seedSettings({ seedId: SEED_ID, projects: [project("sampleqs01"), project("sampleqs02")], backends: [backend()] }), h.deps);
  assert.equal(result?.outcome, "succeeded");
  assert.deepEqual(h.store.calls, [
    { op: "create", container: "backends", id: "foundry-1", partitionKey: "foundry-1" },
    { op: "create", container: "projects", id: "sampleqs01", partitionKey: "sampleqs01" },
    { op: "create", container: "projects", id: "sampleqs02", partitionKey: "sampleqs02" },
  ]);
  const line = onlyLine(h);
  assert.equal(line.schema, "ccof.seed.result.v1");
  assert.equal(line.seedId, SEED_ID);
  assert.equal(line.outcome, "succeeded");
  assert.deepEqual(line.documents, [
    { container: "backends", id: "foundry-1", outcome: "created" },
    { container: "projects", id: "sampleqs01", outcome: "created" },
    { container: "projects", id: "sampleqs02", outcome: "created" },
  ]);
  assert.deepEqual(line.counts, { created: 3, presentEqual: 0, presentDiffers: 0, failed: 0 });
  assert.equal(line.startedAt, "2026-10-13T13:00:00.000Z");
  assert.equal(line.durationMs, 2000);
  // The stored documents are exactly the seeded ones.
  const { _rid, _self, _etag, _attachments, _ts, ...stored } = h.store.docs.get("projects/sampleqs01/sampleqs01") as Record<string, unknown>;
  assert.deepEqual(stored, project("sampleqs01"));
});

test("the store is opened with the sync's own Cosmos settings and managed identity", async () => {
  const h = harness();
  await runRegistrySeed(seedSettings(), h.deps);
  assert.equal(h.opened.length, 1);
  assert.equal(h.opened[0].clientId, CLIENT_ID.toLowerCase());
  assert.equal(h.opened[0].config.cosmosEndpoint, ENDPOINT);
  assert.equal(h.opened[0].config.cosmosDatabase, "ccof");
  assert.equal(h.opened[0].config.projectsContainer, "projects");
  assert.equal(BACKENDS_CONTAINER, "backends");
});

test("409 equal: the document is read back with its partition key, compared, never replaced: present-equal", async () => {
  const h = harness();
  h.store.put("backends", backend());
  h.store.put("projects", project());
  const before = structuredClone([...h.store.docs.entries()]);
  const result = await runRegistrySeed(seedSettings(), h.deps);
  assert.equal(result?.outcome, "succeeded");
  assert.deepEqual(h.store.calls, [
    { op: "create", container: "backends", id: "foundry-1", partitionKey: "foundry-1" },
    { op: "read", container: "backends", id: "foundry-1", partitionKey: "foundry-1" },
    { op: "create", container: "projects", id: "sampleqs01", partitionKey: "sampleqs01" },
    { op: "read", container: "projects", id: "sampleqs01", partitionKey: "sampleqs01" },
  ]);
  assert.deepEqual([...h.store.docs.entries()], before);
  const line = onlyLine(h);
  assert.deepEqual(line.documents, [
    { container: "backends", id: "foundry-1", outcome: "present-equal" },
    { container: "projects", id: "sampleqs01", outcome: "present-equal" },
  ]);
  assert.deepEqual(line.counts, { created: 0, presentEqual: 2, presentDiffers: 0, failed: 0 });
});

test("409 equal is canonical: key order does not matter, and a stored field the seed does not write is not a difference", async () => {
  const h = harness();
  const reordered = Object.fromEntries(Object.entries(project()).reverse());
  h.store.put("projects", { ...reordered, notes: "added by an operator" });
  h.store.put("backends", backend());
  await runRegistrySeed(seedSettings(), h.deps);
  assert.deepEqual(onlyLine(h).documents.map((d: { outcome: string }) => d.outcome), ["present-equal", "present-equal"]);
});

test("409 differs: present-differs with the field names, never their values, and the stored document is unchanged", async () => {
  const h = harness();
  const other = project();
  ((other.classifications as Record<string, any>).STD.familyPolicy.families.haiku).models = ["secret-model-name"];
  other.displayName = "Another display name";
  h.store.put("projects", other);
  h.store.put("backends", backend());
  const before = structuredClone(h.store.docs.get("projects/sampleqs01/sampleqs01"));
  const result = await runRegistrySeed(seedSettings(), h.deps);
  assert.equal(result?.outcome, "differs");
  const line = onlyLine(h);
  assert.deepEqual(line.documents, [
    { container: "backends", id: "foundry-1", outcome: "present-equal" },
    { container: "projects", id: "sampleqs01", outcome: "present-differs", fields: ["classifications", "displayName"] },
  ]);
  assert.deepEqual(line.counts, { created: 0, presentEqual: 1, presentDiffers: 1, failed: 0 });
  assert.ok(!h.lines[0].includes("secret-model-name") && !h.lines[0].includes("Another display name"), h.lines[0]);
  assert.deepEqual(h.store.docs.get("projects/sampleqs01/sampleqs01"), before);
  assert.equal(h.store.calls.filter((c) => c.op === "create").length, 2);
});

test("a stored document without a seeded field differs in that field", async () => {
  const h = harness();
  const { retiredAt, ...withoutRetiredAt } = project();
  h.store.put("projects", withoutRetiredAt);
  h.store.put("backends", backend());
  await runRegistrySeed(seedSettings(), h.deps);
  assert.deepEqual(onlyLine(h).documents[1], { container: "projects", id: "sampleqs01", outcome: "present-differs", fields: ["retiredAt"] });
});

test("409 changing only a family quota reports present-differs without changing aggregate allowance or stored policy", async () => {
  const h = harness();
  const original = project() as Record<string, any>;
  h.store.put("projects", original);
  h.store.put("backends", backend());
  const wanted = structuredClone(original);
  wanted.classifications.STD.familyPolicy.families.haiku.person.tokenQuota = 123;
  const before = structuredClone([...h.store.docs.entries()]);
  const result = await runRegistrySeed(seedSettings({ seedId: SEED_ID, projects: [wanted], backends: [backend()] }), h.deps);
  assert.equal(result?.outcome, "differs");
  assert.deepEqual(onlyLine(h).documents[1], { container: "projects", id: "sampleqs01", outcome: "present-differs", fields: ["classifications"] });
  assert.deepEqual([...h.store.docs.entries()], before);
  assert.deepEqual(wanted.classifications.STD.familyPolicy.aggregateLimits, original.classifications.STD.familyPolicy.aggregateLimits);
});

test("a failed create fails that document with a short code, the others are still written", async () => {
  const h = harness();
  h.store.failCreate.set("backends/foundry-1", 403);
  const result = await runRegistrySeed(seedSettings(), h.deps);
  assert.equal(result?.outcome, "failed");
  const line = onlyLine(h);
  assert.deepEqual(line.documents, [
    { container: "backends", id: "foundry-1", outcome: "failed", code: "create_http_403" },
    { container: "projects", id: "sampleqs01", outcome: "created" },
  ]);
  assert.deepEqual(line.counts, { created: 1, presentEqual: 0, presentDiffers: 0, failed: 1 });
  assert.ok(!h.lines[0].includes("fake cosmos error"), "no error text in the line");
});

test("a failed read-back after 409, a vanished document and a non-HTTP error each fail with their own code", async () => {
  const h = harness();
  h.store.put("backends", backend());
  h.store.put("projects", project("sampleqs01"));
  h.store.failRead.set("backends/foundry-1", 503);
  h.store.failCreate.set("projects/sampleqs02", new Error("socket hang up"));
  h.store.vanished.add("projects/sampleqs03");
  await runRegistrySeed(seedSettings({ seedId: SEED_ID, projects: [project("sampleqs01"), project("sampleqs02"), project("sampleqs03")], backends: [backend()] }), h.deps);
  assert.deepEqual(onlyLine(h).documents, [
    { container: "backends", id: "foundry-1", outcome: "failed", code: "read_http_503" },
    { container: "projects", id: "sampleqs01", outcome: "present-equal" },
    { container: "projects", id: "sampleqs02", outcome: "failed", code: "create_error" },
    { container: "projects", id: "sampleqs03", outcome: "failed", code: "read_not_found" },
  ]);
  assert.ok(!h.lines[0].includes("socket hang up"));
});

const invalidProjects: [string, (p: Record<string, any>) => void, string][] = [
  ["projectId outside the identifier pattern", (p) => { p.projectId = "bad id!"; p.id = "bad id!"; }, "projectId:invalid"],
  ["id not equal to projectId", (p) => { p.id = "OTHER"; }, "id:not_equal_to_projectId"],
  ["a model outside the model pattern", (p) => { p.classifications.STD.familyPolicy.families.haiku.models = ["claude sonnet"]; }, "classifications.STD.familyPolicy:invalid_family_policy"],
  ["old project missing policy", (p) => { delete p.classifications.STD.familyPolicy; }, "classifications.STD.familyPolicy:invalid_family_policy"],
  ["canonical family mismatch", (p) => { p.classifications.STD.familyPolicy.families.haiku.models = ["claude-opus-5"]; }, "classifications.STD.familyPolicy:invalid_family_policy"],
  ["duplicate model across families", (p) => { p.classifications.STD.familyPolicy.families.sonnet.models = ["claude-haiku-4-5"]; }, "classifications.STD.familyPolicy:invalid_family_policy"],
  ["forbidden empty Fable", (p) => { p.classifications.STD.familyPolicy.families.fable = {}; }, "classifications.STD.familyPolicy:family_classification_forbidden"],
  ["forbidden Mythos", (p) => { p.classifications.PRM.familyPolicy.families.mythos = {}; }, "classifications.PRM.familyPolicy:family_classification_forbidden"],
  ["overflow family TPM", (p) => { p.classifications.STD.familyPolicy.families.haiku.person.tokensPerMinute = 2147483648; }, "classifications.STD.familyPolicy:invalid_family_policy"],
  ["overflow aggregate quota", (p) => { p.classifications.STD.familyPolicy.aggregateLimits.group.tokenQuota = 9007199254740992; }, "classifications.STD.familyPolicy:invalid_family_policy"],
  ["incomplete family limit", (p) => { delete p.classifications.STD.familyPolicy.families.haiku.person.tokenQuotaPeriod; }, "classifications.STD.familyPolicy:invalid_family_policy"],
  ["a group id that is not a GUID", (p) => { p.classifications.STD.groupId = "not-a-guid"; }, "classifications.STD.groupId:invalid"],
  ["a backendId outside the identifier pattern", (p) => { p.backendId = "-x"; }, "backendId:invalid"],
  ["a status other than active", (p) => { p.status = "retired"; }, "status:not_active"],
  ["an unexpected top-level key", (p) => { p._etag = "x"; }, "document:unexpected_key"],
  ["an unexpected classification key", (p) => { p.classifications.STD.extra = 1; }, "classifications.STD:unexpected_key"],
  ["a missing seeded key", (p) => { delete p.supersedes; }, "supersedes:invalid"],
  ["a display name that is not a string", (p) => { p.displayName = 7; }, "displayName:invalid"],
  ["a designated subscription that is not a GUID", (p) => { p.designatedSubscriptionId = "sub"; }, "designatedSubscriptionId:invalid"],
  ["a person budget that is not a budget", (p) => { p.classifications.STD.personBudget = { amount: -1, currency: "CCU", period: "monthly" }; }, "classifications.STD.personBudget:invalid"],
  ["an onboarding mode outside block and warn", (p) => { p.classifications.STD.onboardingMode = "allow"; }, "classifications.STD.onboardingMode:invalid"],
];

for (const [name, mutate, problem] of invalidProjects) {
  test(`invalid projects document (${name}) refuses the whole seed before any Cosmos call`, async () => {
    const h = harness();
    const bad = project("sampleqs02") as Record<string, any>;
    mutate(bad);
    const result = await runRegistrySeed(seedSettings({ seedId: SEED_ID, projects: [project("sampleqs01"), bad], backends: [backend()] }), h.deps);
    assert.equal(result?.outcome, "refused");
    assert.equal(h.opened.length, 0);
    assert.equal(h.store.calls.length, 0);
    const line = onlyLine(h);
    assert.equal(line.outcome, "refused");
    assert.equal(line.reason, "seed_documents_invalid");
    assert.equal(line.seedId, SEED_ID);
    const refused = line.documents.find((d: { code?: string }) => d.code === "invalid_document");
    assert.ok(refused, JSON.stringify(line.documents));
    assert.ok(refused.problems.includes(problem), `${JSON.stringify(refused.problems)} lacks ${problem}`);
    assert.deepEqual(
      line.documents.filter((d: { code?: string }) => d.code !== "invalid_document").map((d: { container: string; id: string; outcome: string; code: string }) => `${d.container}/${d.id}:${d.outcome}:${d.code}`),
      ["backends/foundry-1:failed:batch_refused", "projects/sampleqs01:failed:batch_refused"],
    );
  });
}

const invalidBackends: [string, (b: Record<string, any>) => void, string][] = [
  ["backendId outside the identifier pattern", (b) => { b.backendId = "a/b"; b.id = "a/b"; }, "backendId:invalid"],
  ["id not equal to backendId", (b) => { b.id = "foundry-3"; }, "backend_id_mismatch"],
  ["status disabled", (b) => { b.status = "disabled"; }, "status:not_active"],
  ["an unknown status", (b) => { b.status = "paused"; }, "invalid_status"],
  ["another api format", (b) => { b.apiFormat = "openai"; }, "invalid_api_format"],
  ["an auth resource outside the resource forms", (b) => { b.auth.resource = "https://evil.example.com/\"x"; }, "invalid_auth"],
  ["an extra auth field", (b) => { b.auth.secret = "s3cr3t-value"; }, "auth:unexpected_key"],
  ["an unexpected top-level key", (b) => { b.url = "https://x"; }, "document:unexpected_key"],
];

for (const [name, mutate, problem] of invalidBackends) {
  test(`invalid backends document (${name}) refuses the whole seed before any Cosmos call`, async () => {
    const h = harness();
    const bad = backend("foundry-2") as Record<string, any>;
    mutate(bad);
    await runRegistrySeed(seedSettings({ seedId: SEED_ID, projects: [project()], backends: [backend(), bad] }), h.deps);
    assert.equal(h.opened.length + h.store.calls.length, 0);
    const line = onlyLine(h);
    assert.equal(line.reason, "seed_documents_invalid");
    const refused = line.documents.find((d: { code?: string }) => d.code === "invalid_document");
    assert.ok(refused && refused.container === "backends" && refused.problems.includes(problem), JSON.stringify(line.documents));
    assert.ok(!h.lines[0].includes("s3cr3t-value") && !h.lines[0].includes("evil.example.com"), h.lines[0]);
  });
}

test("an id outside the identifier pattern is logged as null, never echoed", async () => {
  const h = harness();
  const bad = project() as Record<string, any>;
  bad.projectId = "<script>"; bad.id = "<script>";
  await runRegistrySeed(seedSettings({ seedId: SEED_ID, projects: [bad], backends: [backend()] }), h.deps);
  const line = onlyLine(h);
  assert.equal(line.documents.find((d: { code?: string }) => d.code === "invalid_document").id, null);
  assert.ok(!h.lines[0].includes("<script>"));
});

test("a document id seeded twice in one container refuses the seed before any Cosmos call", async () => {
  const h = harness();
  await runRegistrySeed(seedSettings({ seedId: SEED_ID, projects: [project(), project()], backends: [backend()] }), h.deps);
  assert.equal(h.opened.length + h.store.calls.length, 0);
  const line = onlyLine(h);
  assert.equal(line.reason, "seed_documents_invalid");
  assert.ok(line.documents.some((d: { code?: string; problems?: string[] }) => d.code === "invalid_document" && d.problems?.includes("id:duplicate")), JSON.stringify(line.documents));
});

const malformed: [string, string, string | null][] = [
  ["not base64", "this is not base64!", null],
  ["base64 with a bad length", "YWJjZA=", null],
  ["base64 of text that is not JSON", Buffer.from("seed please").toString("base64"), null],
  ["base64 of invalid UTF-8", Buffer.from([0xff, 0xfe, 0xfd, 0x7b]).toString("base64"), null],
  ["a JSON array", encode([project()]), null],
  ["no seedId", encode({ projects: [project()], backends: [backend()] }), null],
  ["a seedId outside the pattern", encode({ seedId: "SEED-1; drop", projects: [project()], backends: [backend()] }), null],
  ["projects not an array", encode({ seedId: SEED_ID, projects: project(), backends: [backend()] }), SEED_ID],
  ["no backends key", encode({ seedId: SEED_ID, projects: [project()] }), SEED_ID],
  ["an extra key", encode({ seedId: SEED_ID, projects: [project()], backends: [backend()], upsert: true }), SEED_ID],
  ["no document at all", encode({ seedId: SEED_ID, projects: [], backends: [] }), SEED_ID],
];

for (const [name, value, seedId] of malformed) {
  test(`malformed setting (${name}) is refused without any Cosmos call`, async () => {
    const h = harness();
    const result = await runRegistrySeed({ ...SETTINGS, [SEED_SETTING]: value }, h.deps);
    assert.equal(result?.outcome, "refused");
    assert.equal(h.opened.length + h.store.calls.length, 0);
    const line = onlyLine(h);
    assert.equal(line.schema, "ccof.seed.result.v1");
    assert.equal(line.reason, "seed_documents_malformed");
    assert.equal(line.seedId, seedId);
    assert.deepEqual(line.documents, []);
  });
}

test("a setting longer than the cap is refused without decoding it or any Cosmos call", async () => {
  const h = harness();
  await runRegistrySeed({ ...SETTINGS, [SEED_SETTING]: "A".repeat(MAX_SEED_SETTING_LENGTH + 4) }, h.deps);
  assert.equal(h.opened.length + h.store.calls.length, 0);
  assert.equal(onlyLine(h).reason, "seed_documents_too_large");
});

test("an invalid sync configuration refuses the seed by setting name, without any Cosmos call", async () => {
  const h = harness();
  const settings = seedSettings();
  delete settings.COSMOS_ENDPOINT;
  settings.SYNC_MANAGED_IDENTITY_CLIENT_ID = "not-a-guid";
  await runRegistrySeed(settings, h.deps);
  assert.equal(h.opened.length + h.store.calls.length, 0);
  const line = onlyLine(h);
  assert.equal(line.reason, "seed_config_invalid");
  assert.deepEqual([...line.problems].sort(), ["COSMOS_ENDPOINT:missing", "SYNC_MANAGED_IDENTITY_CLIENT_ID:invalid"]);
  assert.deepEqual(line.documents.map((d: { code: string }) => d.code), ["batch_refused", "batch_refused"]);
});

test("a store that cannot be opened fails every document with store_unavailable", async () => {
  const h = harness();
  h.deps.openStore = () => {
    throw new Error("no credential");
  };
  const result = await runRegistrySeed(seedSettings(), h.deps);
  assert.equal(result?.outcome, "failed");
  assert.deepEqual(onlyLine(h).documents.map((d: { code: string }) => d.code), ["store_unavailable", "store_unavailable"]);
});

test("the result line carries only ids, outcomes, field names and codes: no group, tenant, endpoint or budget value", async () => {
  const h = harness();
  const other = project();
  (other.classifications as Record<string, Record<string, unknown>>).PRM.groupId = "99999999-9999-4999-8999-999999999999";
  h.store.put("projects", other);
  await runRegistrySeed(seedSettings(), h.deps);
  const text = h.lines[0];
  for (const value of [GROUP_STD, GROUP_PRM, "99999999-9999-4999-8999-999999999999", TENANT, ENDPOINT, CLIENT_ID, CLIENT_ID.toLowerCase(), SUBSCRIPTION, "cognitiveservices", "25000"]) {
    assert.ok(!text.includes(value), `the line contains ${value}`);
  }
  const line = onlyLine(h);
  assert.deepEqual(Object.keys(line).sort(), ["counts", "documents", "durationMs", "outcome", "schema", "seedId", "startedAt"]);
});

test("function-app.ts registers registrySeed next to the sync timer: sync role only, every minute, only while the seed setting is set", () => {
  const source = readFileSync(new URL("../src/sync/function-app.ts", import.meta.url), "utf8");
  const start = source.indexOf('if (process.env.CCOF_APP_ROLE === "sync") {');
  assert.ok(start >= 0, "the sync role block");
  const block = source.slice(start);
  assert.match(block, /app\.timer\(FUNCTION_NAME, \{/);
  assert.match(block, /if \(process\.env\[SEED_SETTING\]\?\.trim\(\)\) \{\s*app\.timer\(SEED_FUNCTION_NAME, \{ schedule: SEED_SCHEDULE, runOnStartup: false, handler: registrySeedTimer \}\);/);
  assert.equal(SEED_FUNCTION_NAME, "registrySeed");
  // A function whose name has a hyphen cannot be disabled on Linux (Learn, "How to disable functions").
  assert.match(SEED_FUNCTION_NAME, /^[A-Za-z0-9_]+$/);
  assert.equal(SEED_SCHEDULE, "0 */1 * * * *");
  assert.equal(SEED_SETTING, "CCOF_SEED_DOCUMENTS");
});