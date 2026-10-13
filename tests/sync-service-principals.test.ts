// Service principals as group members (owner approval (c), 2026-10-11;
// docs/status/WP-SYNC-SP.md). v1.0 List group members does not list service
// principals (Learn known issue, confirmed live 2026-10-12), so when they are
// admitted the reader also reads the OData cast
// members/microsoft.graph.servicePrincipal, with ConsistencyLevel: eventual on
// every page. Every guard of the direct read applies to it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { readGroupMembers, readerSettings } from "../src/sync/graph.ts";
import type { GraphReaderOptions } from "../src/sync/graph.ts";
import { runSync } from "../src/sync/run.ts";
import type { RunDependencies } from "../src/sync/run.ts";
import { readSyncConfig } from "../src/sync/config.ts";
import type { SyncConfig } from "../src/sync/config.ts";
import { snapshotGroupReader, snapshotReader, takeSnapshot, validateSnapshot } from "../src/sync/snapshot.ts";
import {
  FakeGraph,
  GROUP_PRM,
  GROUP_STD,
  ManualClock,
  MemoryEntitlements,
  MemoryLeases,
  PERSON_A,
  SP_TEST,
  TENANT,
  member,
  membersUrl,
  page,
  projectDoc,
  servicePrincipalPage,
  servicePrincipalsUrl,
} from "./helpers/sync-fakes.ts";

const SP_OTHER = "00000000-0000-4000-8000-000001110010";
const NEXT_SP = `https://graph.microsoft.com/v1.0/groups/${GROUP_STD}/members/microsoft.graph.servicePrincipal?$select=id&$top=999&$count=true&$skiptoken=abc`;

function options(graph: FakeGraph, readServicePrincipals: boolean, overrides: Partial<GraphReaderOptions> = {}) {
  const sleeps: number[] = [];
  const opts: GraphReaderOptions = {
    fetch: graph.fetch,
    getToken: async () => "token-value",
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    maxRetries: 3,
    maxRetryAfterSeconds: 30,
    timeoutSeconds: 10,
    readServicePrincipals,
    now: () => Date.parse("2026-10-12T01:00:00Z"),
    ...overrides,
  };
  return { opts, sleeps };
}

test("with service principals admitted, a group read adds the OData-cast read, because v1.0 members omits them", async () => {
  // The live shapes of 2026-10-12: the direct read is empty, the cast read holds the member with only its id.
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([])).on(servicePrincipalsUrl(GROUP_STD), servicePrincipalPage([SP_TEST]));
  const result = await readGroupMembers(GROUP_STD, options(graph, true).opts);
  assert.deepEqual(result, { ok: true, groupId: GROUP_STD, members: [{ id: SP_TEST, kind: "servicePrincipal" }], pages: 2, retries: 0 });
  assert.deepEqual(
    graph.calls.map((c) => [c.url, c.consistencyLevel]),
    [
      [membersUrl(GROUP_STD), undefined],
      [servicePrincipalsUrl(GROUP_STD), "eventual"],
    ],
  );
  assert.equal(graph.calls[1].authorization, graph.calls[0].authorization, "the cast read is authorized like the direct read");
});

test("with only users admitted, the reader makes the requests it made before: no cast read", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([member(PERSON_A)]));
  const result = await readGroupMembers(GROUP_STD, options(graph, false).opts);
  assert.deepEqual(result, { ok: true, groupId: GROUP_STD, members: [{ id: PERSON_A, kind: "user" }], pages: 1, retries: 0 });
  assert.deepEqual(graph.calls.map((c) => [c.url, c.consistencyLevel]), [[membersUrl(GROUP_STD), undefined]]);
});

test("every page of the cast read carries ConsistencyLevel, and its nextLink is followed to the last page", async () => {
  const graph = new FakeGraph()
    .on(membersUrl(GROUP_STD), page([member(PERSON_A)]))
    .on(servicePrincipalsUrl(GROUP_STD), servicePrincipalPage([SP_TEST], NEXT_SP))
    .on(NEXT_SP, servicePrincipalPage([SP_OTHER]));
  const result = await readGroupMembers(GROUP_STD, options(graph, true).opts);
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.members, [
      { id: PERSON_A, kind: "user" },
      { id: SP_TEST, kind: "servicePrincipal" },
      { id: SP_OTHER, kind: "servicePrincipal" },
    ]);
    assert.equal(result.pages, 3);
  }
  assert.deepEqual(graph.calls.map((c) => c.consistencyLevel), [undefined, "eventual", "eventual"]);
});

test("cast ids are lower-cased like direct ids, and a service principal returned by both reads counts once", async () => {
  // As if Graph fixed the known issue: the direct read lists the service principal too.
  const graph = new FakeGraph()
    .on(membersUrl(GROUP_STD), page([member(SP_TEST, "#microsoft.graph.servicePrincipal")]))
    .on(servicePrincipalsUrl(GROUP_STD), servicePrincipalPage([SP_TEST.toUpperCase()]));
  const result = await readGroupMembers(GROUP_STD, options(graph, true).opts);
  assert.equal(result.ok, true);
  if (result.ok) assert.deepEqual(result.members, [{ id: SP_TEST, kind: "servicePrincipal" }]);
});

test("one id returned as a user by the direct read and as a service principal by the cast fails the read", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([member(SP_TEST)])).on(servicePrincipalsUrl(GROUP_STD), servicePrincipalPage([SP_TEST]));
  const result = await readGroupMembers(GROUP_STD, options(graph, true).opts);
  assert.equal(result.ok, false);
  if (!result.ok) assert.equal(result.reason, "graph_response_invalid");
});

test("a cast item typed as anything but a service principal fails the read", async () => {
  const body = { "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#servicePrincipals(id)", value: [{ "@odata.type": "#microsoft.graph.user", id: PERSON_A }] };
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([])).on(servicePrincipalsUrl(GROUP_STD), { status: 200, body });
  const result = await readGroupMembers(GROUP_STD, options(graph, true).opts);
  assert.equal(result.ok, false);
  if (!result.ok) assert.equal(result.reason, "graph_response_invalid");
});

test("an untyped cast item counts as a service principal only in a servicePrincipals collection", async () => {
  for (const context of ["https://graph.microsoft.com/v1.0/$metadata#directoryObjects(id)", "https://graph.microsoft.com/v1.0/$metadata#servicePrincipalsX", null]) {
    const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([])).on(servicePrincipalsUrl(GROUP_STD), servicePrincipalPage([SP_TEST], undefined, context));
    const result = await readGroupMembers(GROUP_STD, options(graph, true).opts);
    assert.equal(result.ok, false, `context ${context}`);
    if (!result.ok) assert.equal(result.reason, "graph_response_invalid");
  }
  const typed = { value: [{ "@odata.type": "#microsoft.graph.servicePrincipal", id: SP_TEST }] };
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([])).on(servicePrincipalsUrl(GROUP_STD), { status: 200, body: typed });
  const result = await readGroupMembers(GROUP_STD, options(graph, true).opts);
  assert.equal(result.ok, true, "an item that names its type needs no collection context");
});

test("a cast item without a GUID id, or a cast page without a value array, fails the read", async () => {
  for (const body of [{ "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#servicePrincipals(id)", value: [{ id: "not-a-guid" }] }, { "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#servicePrincipals(id)" }]) {
    const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([])).on(servicePrincipalsUrl(GROUP_STD), { status: 200, body });
    const result = await readGroupMembers(GROUP_STD, options(graph, true).opts);
    assert.equal(result.ok, false);
    if (!result.ok) assert.equal(result.reason, "graph_response_invalid");
  }
});

test("a failed cast read fails the whole group read, although the direct read succeeded", async () => {
  const denied = { status: 403, body: { error: { code: "Authorization_RequestDenied" } } };
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([member(PERSON_A)])).on(servicePrincipalsUrl(GROUP_STD), denied);
  const result = await readGroupMembers(GROUP_STD, options(graph, true).opts);
  assert.deepEqual(result, { ok: false, groupId: GROUP_STD, reason: "graph_permission_missing", httpStatus: 403, graphErrorCode: "Authorization_RequestDenied", retries: 0 });
});

test("the cast read honours Retry-After within the bound and renews the lease before every request", async () => {
  let renewals = 0;
  const graph = new FakeGraph()
    .on(membersUrl(GROUP_STD), page([]))
    .on(servicePrincipalsUrl(GROUP_STD), { status: 429, headers: { "Retry-After": "2" } }, servicePrincipalPage([SP_TEST]));
  const { opts, sleeps } = options(graph, true, { beforeRequest: async () => void (renewals += 1) });
  const result = await readGroupMembers(GROUP_STD, opts);
  assert.equal(result.ok, true);
  if (result.ok) assert.equal(result.retries, 1);
  assert.deepEqual(sleeps, [2000]);
  assert.equal(renewals, 3, "one renewal per request: the direct read and both cast attempts");

  const tooLong = new FakeGraph().on(membersUrl(GROUP_STD), page([])).on(servicePrincipalsUrl(GROUP_STD), { status: 429, headers: { "Retry-After": "31" } });
  const refused = await readGroupMembers(GROUP_STD, options(tooLong, true).opts);
  assert.equal(refused.ok, false);
  if (!refused.ok) assert.equal(refused.reason, "graph_throttled");
});

test("a cast nextLink off Microsoft Graph v1.0 fails the read: the token is never sent there", async () => {
  const beta = `https://graph.microsoft.com/beta/groups/${GROUP_STD}/members/microsoft.graph.servicePrincipal?$skiptoken=abc`;
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([])).on(servicePrincipalsUrl(GROUP_STD), servicePrincipalPage([SP_TEST], beta));
  const result = await readGroupMembers(GROUP_STD, options(graph, true).opts);
  assert.equal(result.ok, false);
  if (!result.ok) assert.equal(result.reason, "graph_response_invalid");
  assert.equal(graph.calls.length, 2);
});

const CONFIG: SyncConfig = {
  tenantId: TENANT,
  cosmosEndpoint: "https://sample-pilot-cosmos.documents.azure.com:443/",
  cosmosDatabase: "ccof",
  projectsContainer: "projects",
  entitlementContainer: "entitlement",
  leaseContainer: "syncLease",
  leaseSeconds: 300,
  memberTypes: ["servicePrincipal", "user"],
  maxRemovalsPerRun: 5,
  maxRemovalFraction: 0.1,
  graphMaxRetries: 2,
  graphMaxRetryAfterSeconds: 5,
  graphTimeoutSeconds: 10,
  writeMode: "apply",
};

function harness(readGroup: RunDependencies["readGroup"]) {
  const entitlements = new MemoryEntitlements();
  const lines: string[] = [];
  const clock = new ManualClock("2026-10-12T01:00:00.000Z");
  const deps: RunDependencies = {
    readProjects: async () => [projectDoc("PILOT1")],
    readEntitlements: () => entitlements.readAll(),
    entitlements,
    leases: new MemoryLeases(),
    readGroup,
  };
  const context = { trigger: "timer" as const, now: clock.now, newRunId: () => "run-sp", log: (line: string) => lines.push(line) };
  return { entitlements, lines, deps, context, clock };
}

function graphWithTestPrincipal(): FakeGraph {
  return new FakeGraph()
    .on(membersUrl(GROUP_STD), page([]))
    .on(servicePrincipalsUrl(GROUP_STD), servicePrincipalPage([SP_TEST.toUpperCase()]))
    .on(membersUrl(GROUP_PRM), page([]))
    .on(servicePrincipalsUrl(GROUP_PRM), servicePrincipalPage([]));
}

test("a run reads service principals exactly when SYNC_MEMBER_TYPES lists them", () => {
  assert.deepEqual(readerSettings(CONFIG), { maxRetries: 2, maxRetryAfterSeconds: 5, timeoutSeconds: 10, readServicePrincipals: true });
  assert.deepEqual(readerSettings({ ...CONFIG, memberTypes: ["user"] }), { maxRetries: 2, maxRetryAfterSeconds: 5, timeoutSeconds: 10, readServicePrincipals: false });
});

test("the public synthetic answers pass the app's validator and make the run read service principals", () => {
  const answers = JSON.parse(readFileSync(new URL("./fixtures/sync-public.json", import.meta.url), "utf8"));
  // The settings the app sees, as Get-SyncAppSettings (infra/sync/SyncDeploy.psm1) builds them.
  const settings = {
    COSMOS_ENDPOINT: `https://${answers.cosmosAccountName}.documents.azure.com:443/`,
    COSMOS_DATABASE: answers.cosmosDatabaseName,
    SYNC_PROJECTS_CONTAINER: answers.projectsContainerName,
    SYNC_ENTITLEMENT_CONTAINER: answers.entitlementContainerName,
    SYNC_LEASE_CONTAINER: answers.leaseContainerName,
    ...answers.syncSettings,
  };
  const result = readSyncConfig(settings);
  assert.equal(result.ok, true, JSON.stringify(result));
  if (!result.ok) return;
  assert.deepEqual(result.config.memberTypes, ["servicePrincipal", "user"]);
  assert.equal(readerSettings(result.config).readServicePrincipals, true);
});

test("a run gives a service principal in a registered group an entitlement keyed by its object id, the oid of its token", async () => {
  const graph = graphWithTestPrincipal();
  // Wired as src/sync/azure.ts wires the timer and the CLI run.
  const io = { fetch: graph.fetch, getToken: async () => "token-value", sleep: async () => {} };
  const h = harness((groupId, beforeRequest) => readGroupMembers(groupId, { ...io, ...readerSettings(CONFIG), beforeRequest }));
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "succeeded");
  assert.deepEqual([...h.entitlements.docs.keys()], [SP_TEST]);
  const doc = h.entitlements.docs.get(SP_TEST)?.doc as Record<string, unknown>;
  assert.equal(doc.id, SP_TEST);
  assert.equal(doc.personId, SP_TEST, "the resolver point-reads entitlement by the token's oid");
  const memberships = doc.projectMemberships as Record<string, unknown>[];
  assert.deepEqual(
    memberships.map((m) => [m.projectId, m.classification, m.classificationGroupId, m.status]),
    [["PILOT1", "STD", GROUP_STD, "active"]],
  );
  const run = JSON.parse(h.lines.at(-1) ?? "{}");
  assert.deepEqual([run.counts.membersRead, run.counts.membersAdmitted, run.counts.created], [1, 1, 1]);
  assert.deepEqual(run.refusals, []);
});

test("the snapshot command reads service principals whatever a later apply admits", async () => {
  const graph = graphWithTestPrincipal();
  const settings = { tenantId: TENANT, graphMaxRetries: 1, graphMaxRetryAfterSeconds: 5, graphTimeoutSeconds: 10 };
  const read = snapshotGroupReader(settings, { fetch: graph.fetch, getToken: async () => "token-value", sleep: async () => {} });
  const result = await read(GROUP_STD);
  assert.deepEqual(result, { ok: true, groupId: GROUP_STD, members: [{ id: SP_TEST, kind: "servicePrincipal" }], pages: 2, retries: 0 });
  assert.deepEqual(graph.calls.map((c) => [c.url, c.consistencyLevel]), [
    [membersUrl(GROUP_STD), undefined],
    [servicePrincipalsUrl(GROUP_STD), "eventual"],
  ]);
});

test("a snapshot records service principals read through the cast; apply admits them only when configured", async () => {
  const graph = graphWithTestPrincipal();
  const clock = new ManualClock("2026-10-12T01:00:00.000Z");
  const settings = { tenantId: TENANT, graphMaxRetries: 1, graphMaxRetryAfterSeconds: 5, graphTimeoutSeconds: 10 };
  const read = snapshotGroupReader(settings, { fetch: graph.fetch, getToken: async () => "token-value", sleep: async () => {} });
  const taken = await takeSnapshot([GROUP_STD, GROUP_PRM], TENANT, read, clock.now);
  assert.equal(taken.ok, true);
  if (!taken.ok) return;
  const std = taken.snapshot.groups.find((g) => g.groupId === GROUP_STD);
  assert.deepEqual(std?.members, [{ id: SP_TEST, type: "servicePrincipal" }]);

  const limits = { maxAgeSeconds: 3600, maxBytes: 1024 * 1024, maxGroups: 100, maxMembers: 100 };
  const validated = validateSnapshot(JSON.stringify(taken.snapshot), { tenantId: TENANT, now: clock.now(), limits });
  assert.equal(validated.ok, true);
  if (!validated.ok) return;

  const admitted = harness(snapshotReader(validated).readGroup);
  await runSync(CONFIG, admitted.deps, { ...admitted.context, source: { kind: "snapshot", sha256: validated.sha256, readAt: validated.readAt } });
  assert.deepEqual([...admitted.entitlements.docs.keys()], [SP_TEST]);

  const usersOnly = harness(snapshotReader(validated).readGroup);
  await runSync({ ...CONFIG, memberTypes: ["user"] }, usersOnly.deps, { ...usersOnly.context, source: { kind: "snapshot", sha256: validated.sha256, readAt: validated.readAt } });
  assert.deepEqual([...usersOnly.entitlements.docs.keys()], []);
  const notices = usersOnly.lines.slice(0, -1).map((l) => JSON.parse(l)).filter((e) => e.reason === "member_type_not_admitted");
  assert.deepEqual(notices.map((e) => [e.groupId, e.memberId]), [[GROUP_STD, SP_TEST]]);
});

test("a failed service-principal read changes no one's access: the project is frozen and the record is kept", async () => {
  const denied = { status: 403, body: { error: { code: "Authorization_RequestDenied" } } };
  const graph = new FakeGraph()
    .on(membersUrl(GROUP_STD), page([]), page([]))
    .on(servicePrincipalsUrl(GROUP_STD), servicePrincipalPage([SP_TEST]), denied)
    .on(membersUrl(GROUP_PRM), page([]), page([]))
    .on(servicePrincipalsUrl(GROUP_PRM), servicePrincipalPage([]), servicePrincipalPage([]));
  const io = { fetch: graph.fetch, getToken: async () => "token-value", sleep: async () => {} };
  const h = harness((groupId, beforeRequest) => readGroupMembers(groupId, { ...io, ...readerSettings(CONFIG), beforeRequest }));
  assert.equal((await runSync(CONFIG, h.deps, h.context)).outcome, "succeeded");
  const before = structuredClone(h.entitlements.docs.get(SP_TEST));
  h.lines.length = 0;
  h.clock.advance(60);

  const second = await runSync(CONFIG, h.deps, h.context);
  // The only project is frozen, so no project is evaluated and nothing is written (ADR-0016).
  assert.equal(second.outcome, "failed");
  assert.deepEqual(h.entitlements.docs.get(SP_TEST), before, "the service principal keeps its membership");
  const refusals = h.lines.slice(0, -1).map((l) => JSON.parse(l)).filter((e) => e.event === "refusal");
  assert.deepEqual(refusals.map((e) => [e.reason, e.groupId, e.httpStatus]), [["graph_permission_missing", GROUP_STD, 403]]);
});

test("a failed service-principal read fails a snapshot as a whole: no file is written", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([])).on(servicePrincipalsUrl(GROUP_STD), { status: 503 });
  const settings = { tenantId: TENANT, graphMaxRetries: 0, graphMaxRetryAfterSeconds: 5, graphTimeoutSeconds: 10 };
  const read = snapshotGroupReader(settings, { fetch: graph.fetch, getToken: async () => "token-value", sleep: async () => {} });
  const taken = await takeSnapshot([GROUP_STD, GROUP_PRM], TENANT, read, () => new Date("2026-10-12T01:00:00.000Z"));
  assert.deepEqual(taken, { ok: false, groupId: GROUP_STD, reason: "graph_unavailable" });
});
