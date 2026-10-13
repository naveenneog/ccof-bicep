// Deleted and disabled members (P-9; docs/status/WP-SYNC.md, "P-9: deleted and
// disabled members"). Graph's accountEnabled changes access only on positive
// evidence: false is not admitted, so the membership is removed within the
// removal limits; true, null or no value keeps the rule for members as it was.
// null is what an app without User.Read.All or Application.Read.All receives
// (Learn "List group members", retrieved 2026-10-13), so it never reads as
// disabled. A deleted member drops out of its groups and is removed as any
// non-member; a restored one is listed, and admitted, again.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readGroupMembers } from "../src/sync/graph.ts";
import type { GraphReaderOptions, GroupMember, GroupReadResult } from "../src/sync/graph.ts";
import { planSync } from "../src/sync/plan.ts";
import type { PlanInput } from "../src/sync/plan-types.ts";
import { readProjectDocument } from "../src/sync/projects.ts";
import { runSync } from "../src/sync/run.ts";
import type { RunDependencies } from "../src/sync/run.ts";
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
  PERSON_B,
  PERSON_C,
  SP_TEST,
  TENANT,
  classification,
  member,
  membersUrl,
  page,
  projectDoc,
  familyPolicy,
} from "./helpers/sync-fakes.ts";

// The requests, as Graph returned them to the owner's read of the pilot groups on 2026-10-13.
const READ = (groupId: string) => `https://graph.microsoft.com/v1.0/groups/${groupId}/members?$select=id,accountEnabled&$top=999`;
const CAST = (groupId: string) =>
  `https://graph.microsoft.com/v1.0/groups/${groupId}/members/microsoft.graph.servicePrincipal?$select=id,accountEnabled&$top=999&$count=true`;
const CAST_CONTEXT = "https://graph.microsoft.com/v1.0/$metadata#servicePrincipals(id,accountEnabled)";
const OTHER_GROUP = "12121212-1212-4212-8212-121212121212";

function typed(id: string, accountEnabled?: unknown, type = "#microsoft.graph.user"): Record<string, unknown> {
  return accountEnabled === undefined ? { "@odata.type": type, id } : { "@odata.type": type, id, accountEnabled };
}

function castPage(items: Record<string, unknown>[]) {
  return { status: 200, body: { "@odata.context": CAST_CONTEXT, value: items } };
}

function readerOptions(graph: FakeGraph, readServicePrincipals: boolean): GraphReaderOptions {
  return { fetch: graph.fetch, getToken: async () => "t", sleep: async () => {}, maxRetries: 0, maxRetryAfterSeconds: 5, timeoutSeconds: 10, readServicePrincipals };
}

// ---- The read -------------------------------------------------------------

test("the member reads select accountEnabled with the id, and each member carries the state Graph returned", async () => {
  const graph = new FakeGraph()
    .on(READ(GROUP_STD), page([typed(PERSON_A, false), typed(PERSON_B, true), typed(PERSON_C)]))
    .on(CAST(GROUP_STD), castPage([{ id: SP_TEST, accountEnabled: false }]));
  const result = await readGroupMembers(GROUP_STD, readerOptions(graph, true));
  assert.deepEqual(
    graph.calls.map((c) => [c.url, c.consistencyLevel]),
    [
      [READ(GROUP_STD), undefined],
      [CAST(GROUP_STD), "eventual"],
    ],
  );
  assert.deepEqual(result, {
    ok: true,
    groupId: GROUP_STD,
    members: [
      { id: PERSON_A, kind: "user", accountEnabled: false },
      { id: PERSON_B, kind: "user", accountEnabled: true },
      { id: PERSON_C, kind: "user" },
      { id: SP_TEST, kind: "servicePrincipal", accountEnabled: false },
    ],
    pages: 2,
    retries: 0,
  });
});

test("accountEnabled null, what an app without the permission to read users receives, leaves the state unknown", async () => {
  const graph = new FakeGraph().on(READ(GROUP_STD), page([typed(PERSON_A, null), typed(PERSON_B, null, "#microsoft.graph.group")]));
  const result = await readGroupMembers(GROUP_STD, readerOptions(graph, false));
  assert.deepEqual(result.ok ? result.members : result.reason, [
    { id: PERSON_A, kind: "user" },
    { id: PERSON_B, kind: "group" },
  ]);
});

test("an accountEnabled that is not true, false or null fails the read: the page is not trusted", async () => {
  for (const value of ["false", 0, 1, {}, []]) {
    const graph = new FakeGraph().on(READ(GROUP_STD), page([typed(PERSON_A, true), typed(PERSON_B, value)]));
    const result = await readGroupMembers(GROUP_STD, readerOptions(graph, false));
    assert.deepEqual(result.ok ? "ok" : result.reason, "graph_response_invalid", JSON.stringify(value));
  }
  const cast = new FakeGraph().on(READ(GROUP_STD), page([])).on(CAST(GROUP_STD), castPage([{ id: SP_TEST, accountEnabled: "no" }]));
  const result = await readGroupMembers(GROUP_STD, readerOptions(cast, true));
  assert.deepEqual(result.ok ? "ok" : result.reason, "graph_response_invalid");
});

test("a service principal listed by both reads is disabled when either says so, and a known state wins over an unknown one", async () => {
  const cases: [unknown, unknown, boolean | undefined][] = [
    [true, false, false],
    [false, true, false],
    [false, null, false],
    [null, false, false],
    [true, null, true],
    [null, true, true],
    [null, null, undefined],
  ];
  for (const [plain, cast, expected] of cases) {
    const graph = new FakeGraph()
      .on(READ(GROUP_STD), page([typed(SP_TEST, plain, "#microsoft.graph.servicePrincipal")]))
      .on(CAST(GROUP_STD), castPage([{ id: SP_TEST, accountEnabled: cast }]));
    const result = await readGroupMembers(GROUP_STD, readerOptions(graph, true));
    const want: GroupMember = expected === undefined ? { id: SP_TEST, kind: "servicePrincipal" } : { id: SP_TEST, kind: "servicePrincipal", accountEnabled: expected };
    assert.deepEqual(result.ok ? result.members : result.reason, [want], `plain ${plain}, cast ${cast}`);
  }
});

// ---- The plan -------------------------------------------------------------

const NOW = new Date("2026-10-13T06:00:00.000Z");
const EARLIER = "2026-10-12T08:00:00.000Z";

function groupsOf(entries: Record<string, GroupMember[]>): Map<string, GroupReadResult> {
  return new Map(Object.entries(entries).map(([groupId, members]) => [groupId, { ok: true, groupId, members, pages: 1, retries: 0 }]));
}

function input(overrides: Partial<PlanInput> = {}): PlanInput {
  return {
    projects: [readProjectDocument(projectDoc("PILOT1"))],
    groups: groupsOf({ [GROUP_STD]: [], [GROUP_PRM]: [] }),
    existing: [],
    memberTypes: ["user"],
    removalLimits: { maxRemovalsPerRun: 10, maxRemovalFraction: 0.5 },
    now: NOW,
    ...overrides,
  };
}

function stdMembership(overrides: Record<string, unknown> = {}) {
  return {
    projectId: "PILOT1",
    classification: "STD",
    classificationGroupId: GROUP_STD,
    familyPolicy: familyPolicy(),
    backendId: "foundry-sample-hub",
    aggregateMode: "notify",
    denormalizedAt: EARLIER,
    joinedAt: EARLIER,
    status: "active",
    ...overrides,
  };
}

function existingDoc(personId: string, memberships: unknown[]) {
  return { doc: { id: personId, personId, projectMemberships: memberships, generation: 4, lastVerifiedAt: EARLIER }, etag: `"etag-${personId}"` };
}

const disabledUser = (id: string): GroupMember => ({ id, kind: "user", accountEnabled: false });

test("a disabled member is not admitted: the run removes their memberships, keeps the document and reports the member", () => {
  const plan = planSync(input({ groups: groupsOf({ [GROUP_STD]: [disabledUser(PERSON_A)], [GROUP_PRM]: [] }), existing: [existingDoc(PERSON_A, [stdMembership()])] }));
  assert.deepEqual(
    plan.writes.map((w) => [w.personId, w.kind, w.document.projectMemberships, w.document.generation]),
    [[PERSON_A, "replace", [], 5]],
  );
  assert.deepEqual([plan.counts.removedMemberships, plan.counts.emptiedDocuments, plan.counts.membersAdmitted, plan.counts.membersDisabled], [1, 1, 0, 1]);
  assert.deepEqual(plan.events.map((e) => [e.event, e.reason, e.groupId, e.memberId]), [["notice", "member_account_disabled", GROUP_STD, PERSON_A]]);
});

test("a disabled member without a document gets none", () => {
  const plan = planSync(input({ groups: groupsOf({ [GROUP_STD]: [disabledUser(PERSON_A)], [GROUP_PRM]: [] }) }));
  assert.deepEqual(plan.writes, []);
  assert.equal(plan.counts.creates, 0);
});

test("an enabled member is planned exactly as a member whose state Graph did not return (no change for enabled members)", () => {
  const scenario = (state: boolean | undefined) => {
    const members: GroupMember[] = [PERSON_A, PERSON_B].map((id) => (state === undefined ? { id, kind: "user" } : { id, kind: "user", accountEnabled: state }));
    return planSync(input({ groups: groupsOf({ [GROUP_STD]: members, [GROUP_PRM]: [] }), existing: [existingDoc(PERSON_A, [stdMembership({ familyPolicy: familyPolicy(["claude-haiku-4-5"]) })])] }));
  };
  const enabled = scenario(true);
  const unknown = scenario(undefined);
  assert.deepEqual(enabled.writes, unknown.writes);
  assert.deepEqual(enabled.events, unknown.events);
  assert.deepEqual([enabled.counts.creates, enabled.counts.replaces, enabled.counts.removedMemberships, enabled.counts.membersAdmitted], [1, 1, 0, 2]);
});

test("an account state Graph did not return admits the member as before, never as disabled, and is counted", () => {
  const plan = planSync(input({ groups: groupsOf({ [GROUP_STD]: [{ id: PERSON_A, kind: "user" }], [GROUP_PRM]: [] }), existing: [existingDoc(PERSON_A, [stdMembership()])] }));
  assert.deepEqual(plan.writes, []);
  assert.deepEqual([plan.counts.removedMemberships, plan.counts.membersDisabled, plan.counts.membersAccountStateUnread], [0, 0, 1]);
});

test("a person disabled in one read is admitted nowhere in that run, even where another read still shows the account enabled", () => {
  const other = projectDoc("ALPHA2", { classifications: { CYB: classification(OTHER_GROUP) } });
  const cyb = { projectId: "ALPHA2", classification: "CYB", classificationGroupId: OTHER_GROUP, familyPolicy: familyPolicy(["claude-haiku-4-5"]), backendId: "foundry-sample-hub", aggregateMode: "notify", denormalizedAt: EARLIER, joinedAt: EARLIER, status: "active" };
  const plan = planSync(
    input({
      projects: [readProjectDocument(projectDoc("PILOT1")), readProjectDocument(other)],
      groups: groupsOf({ [GROUP_STD]: [disabledUser(PERSON_A)], [GROUP_PRM]: [], [OTHER_GROUP]: [{ id: PERSON_A, kind: "user", accountEnabled: true }] }),
      existing: [existingDoc(PERSON_A, [cyb, stdMembership()])],
    }),
  );
  assert.deepEqual(plan.writes.map((w) => [w.personId, w.document.projectMemberships]), [[PERSON_A, []]]);
  assert.equal(plan.counts.removedMemberships, 2);
  assert.deepEqual(
    plan.events.map((e) => [e.reason, e.groupId, e.memberId]),
    [
      ["member_account_disabled", GROUP_STD, PERSON_A],
      ["member_account_disabled", OTHER_GROUP, PERSON_A],
    ],
  );
});

test("a disabled state read in a frozen project's group still counts: other projects' memberships go, the frozen one stays", () => {
  const other = projectDoc("ALPHA2", { classifications: { CYB: classification(OTHER_GROUP) } });
  const cyb = { projectId: "ALPHA2", classification: "CYB", classificationGroupId: OTHER_GROUP, familyPolicy: familyPolicy(["claude-haiku-4-5"]), backendId: "foundry-sample-hub", aggregateMode: "notify", denormalizedAt: EARLIER, joinedAt: EARLIER, status: "active" };
  const unavailable: GroupReadResult = { ok: false, groupId: GROUP_PRM, reason: "graph_unavailable", httpStatus: 503, graphErrorCode: null, retries: 0 };
  const plan = planSync(
    input({
      projects: [readProjectDocument(projectDoc("PILOT1")), readProjectDocument(other)],
      groups: new Map([...groupsOf({ [GROUP_STD]: [disabledUser(PERSON_A)], [OTHER_GROUP]: [{ id: PERSON_A, kind: "user" }] }), [GROUP_PRM, unavailable]]),
      existing: [existingDoc(PERSON_A, [cyb, stdMembership()])],
    }),
  );
  assert.deepEqual(plan.frozenProjects, ["PILOT1"]);
  assert.deepEqual(plan.writes.map((w) => (w.document.projectMemberships as { projectId: string }[]).map((m) => m.projectId)), [["PILOT1"]]);
  assert.deepEqual(plan.events.filter((e) => e.event === "notice").map((e) => [e.reason, e.groupId, e.memberId]), [["member_account_disabled", OTHER_GROUP, PERSON_A]]);
});

test("a disabled member who holds nothing any more is counted on every run but not reported again", () => {
  const plan = planSync(input({ groups: groupsOf({ [GROUP_STD]: [disabledUser(PERSON_A)], [GROUP_PRM]: [disabledUser(PERSON_A)] }), existing: [existingDoc(PERSON_A, [])] }));
  assert.deepEqual(plan.writes, []);
  assert.deepEqual(plan.events, []);
  assert.equal(plan.counts.membersDisabled, 2);
});

test("removals of disabled members count against the removal limits: a mass disable over both limits is withheld", () => {
  const people = [PERSON_A, PERSON_B, PERSON_C];
  const plan = planSync(
    input({
      groups: groupsOf({ [GROUP_STD]: people.map(disabledUser), [GROUP_PRM]: [] }),
      existing: people.map((id) => existingDoc(id, [stdMembership()])),
      removalLimits: { maxRemovalsPerRun: 1, maxRemovalFraction: 0.5 },
    }),
  );
  assert.deepEqual(plan.writes, [], "every membership is carried over");
  assert.equal(plan.removalsWithheld, "removal_limit_exceeded");
  assert.deepEqual([plan.counts.withheldRemovals, plan.counts.removedMemberships, plan.counts.membersDisabled], [3, 0, 3]);
  const refusal = plan.events.find((e) => e.reason === "removal_limit_exceeded");
  assert.deepEqual(refusal?.counts, { removals: 3, existingMemberships: 3, maxRemovalsPerRun: 1, maxRemovalFraction: 0.5 });
  assert.equal(plan.events.filter((e) => e.reason === "member_account_disabled").length, 3, "withheld removals are reported: an administrator has to act");
});

test("a disabled member of a frozen project keeps the membership there: no change without a complete read", () => {
  const unavailable: GroupReadResult = { ok: false, groupId: GROUP_PRM, reason: "graph_unavailable", httpStatus: 503, graphErrorCode: null, retries: 0 };
  const plan = planSync(
    input({ groups: new Map([...groupsOf({ [GROUP_STD]: [disabledUser(PERSON_A)] }), [GROUP_PRM, unavailable]]), existing: [existingDoc(PERSON_A, [stdMembership()])] }),
  );
  assert.deepEqual(plan.writes, []);
  assert.deepEqual(plan.frozenProjects, ["PILOT1"]);
  assert.equal(plan.counts.removedMemberships, 0);
});

test("a disabled service principal is not admitted where service principals are", () => {
  const plan = planSync(
    input({ memberTypes: ["servicePrincipal", "user"], groups: groupsOf({ [GROUP_STD]: [{ id: SP_TEST, kind: "servicePrincipal", accountEnabled: false }], [GROUP_PRM]: [] }), existing: [existingDoc(SP_TEST, [stdMembership()])] }),
  );
  assert.deepEqual(plan.writes.map((w) => [w.personId, w.document.projectMemberships]), [[SP_TEST, []]]);
  assert.deepEqual(plan.events.map((e) => [e.reason, e.memberId]), [["member_account_disabled", SP_TEST]]);
});

test("a member of a type that is not admitted is reported as such, whatever its account state", () => {
  const plan = planSync(input({ groups: groupsOf({ [GROUP_STD]: [{ id: SP_TEST, kind: "servicePrincipal", accountEnabled: false }], [GROUP_PRM]: [] }) }));
  assert.deepEqual(plan.events.map((e) => [e.reason, e.memberId]), [["member_type_not_admitted", SP_TEST]]);
  assert.deepEqual([plan.counts.membersDisabled, plan.counts.membersAccountStateUnread], [0, 0]);
});

// ---- Runs -----------------------------------------------------------------

const CONFIG: SyncConfig = {
  tenantId: TENANT,
  cosmosEndpoint: "https://sample-pilot-cosmos.documents.azure.com:443/",
  cosmosDatabase: "ccof",
  projectsContainer: "projects",
  entitlementContainer: "entitlement",
  leaseContainer: "syncLease",
  leaseSeconds: 300,
  memberTypes: ["user"],
  maxRemovalsPerRun: 5,
  maxRemovalFraction: 0.1,
  graphMaxRetries: 0,
  graphMaxRetryAfterSeconds: 5,
  graphTimeoutSeconds: 10,
  writeMode: "apply",
};

function harness(readGroup?: RunDependencies["readGroup"]) {
  const graph = new FakeGraph();
  const entitlements = new MemoryEntitlements();
  const lines: string[] = [];
  const clock = new ManualClock("2026-10-13T06:00:00.000Z");
  const deps: RunDependencies = {
    readProjects: async () => [projectDoc("PILOT1")],
    readEntitlements: () => entitlements.readAll(),
    entitlements,
    leases: new MemoryLeases(),
    readGroup: readGroup ?? ((groupId, beforeRequest) => readGroupMembers(groupId, { ...readerOptions(graph, false), beforeRequest })),
  };
  const context = { trigger: "timer" as const, now: clock.now, newRunId: () => "run-p9", log: (line: string) => lines.push(line) };
  const runLine = () => JSON.parse(lines.at(-1) ?? "{}");
  return { graph, entitlements, lines, clock, deps, context, runLine };
}

test("a disabled member loses the entitlement on the next run and regains it on the run after re-enabling", async () => {
  const h = harness();
  h.graph.on(READ(GROUP_STD), page([typed(PERSON_A, true)]), page([typed(PERSON_A, false)]), page([typed(PERSON_A, true)]));
  h.graph.on(READ(GROUP_PRM), page([]), page([]), page([]));
  assert.equal((await runSync(CONFIG, h.deps, h.context)).outcome, "succeeded");

  h.clock.advance(60);
  assert.equal((await runSync(CONFIG, h.deps, h.context)).outcome, "succeeded");
  const disabled = h.entitlements.docs.get(PERSON_A)?.doc;
  assert.deepEqual([disabled?.projectMemberships, disabled?.generation], [[], 2]);
  assert.deepEqual([h.runLine().counts.membersDisabled, h.runLine().counts.removedMemberships], [1, 1]);

  h.clock.advance(60);
  assert.equal((await runSync(CONFIG, h.deps, h.context)).outcome, "succeeded");
  const enabled = h.entitlements.docs.get(PERSON_A)?.doc as Record<string, unknown>;
  const memberships = enabled.projectMemberships as Record<string, unknown>[];
  assert.deepEqual(
    memberships.map((m) => [m.projectId, m.classification, m.status, m.joinedAt]),
    [["PILOT1", "STD", "active", "2026-10-13T06:02:00.000Z"]],
  );
  assert.equal(enabled.generation, 3);
});

test("a deleted member, no longer listed by Graph, loses the entitlement on the next run; restored, it is admitted again", async () => {
  const h = harness();
  h.graph.on(membersUrl(GROUP_STD), page([member(PERSON_A), member(PERSON_B)]), page([member(PERSON_B)]), page([member(PERSON_A), member(PERSON_B)]));
  h.graph.on(membersUrl(GROUP_PRM), page([]), page([]), page([]));
  await runSync(CONFIG, h.deps, h.context);
  h.clock.advance(60);
  await runSync(CONFIG, h.deps, h.context);
  assert.deepEqual(h.entitlements.docs.get(PERSON_A)?.doc.projectMemberships, [], "deleted: the document is kept, empty");
  assert.equal(h.runLine().counts.removedMemberships, 1);
  assert.equal((h.entitlements.docs.get(PERSON_B)?.doc.projectMemberships as unknown[]).length, 1, "the other member is untouched");
  h.clock.advance(60);
  await runSync(CONFIG, h.deps, h.context);
  assert.equal((h.entitlements.docs.get(PERSON_A)?.doc.projectMemberships as unknown[]).length, 1, "restored: admitted again");
});

test("the run line counts disabled members and members whose account state Graph did not return", async () => {
  const h = harness();
  h.graph.on(READ(GROUP_STD), page([typed(PERSON_A), typed(PERSON_B, false), typed(PERSON_C, null)])).on(READ(GROUP_PRM), page([]));
  await runSync(CONFIG, h.deps, h.context);
  const counts = h.runLine().counts;
  assert.deepEqual([counts.membersRead, counts.membersAdmitted, counts.membersDisabled, counts.membersAccountStateUnread], [3, 2, 1, 2]);
});

// ---- Snapshots --------------------------------------------------------------

const SNAPSHOT_LIMITS = { maxAgeSeconds: 3600, maxBytes: 1024 * 1024, maxGroups: 100, maxMembers: 100 };

test("a snapshot records accountEnabled where Graph returned it, and leaves it out where Graph did not", async () => {
  const graph = new FakeGraph()
    .on(READ(GROUP_STD), page([typed(PERSON_A, false), typed(PERSON_B, null), typed(PERSON_C, true)]))
    .on(CAST(GROUP_STD), castPage([{ id: SP_TEST }]));
  const settings = { tenantId: TENANT, graphMaxRetries: 0, graphMaxRetryAfterSeconds: 5, graphTimeoutSeconds: 10 };
  const read = snapshotGroupReader(settings, { fetch: graph.fetch, getToken: async () => "t", sleep: async () => {} });
  const taken = await takeSnapshot([GROUP_STD], TENANT, read, () => NOW);
  assert.deepEqual(taken.ok ? taken.snapshot.groups[0].members : taken.reason, [
    { id: PERSON_A, type: "user", accountEnabled: false },
    { id: PERSON_B, type: "user" },
    { id: PERSON_C, type: "user", accountEnabled: true },
    { id: SP_TEST, type: "servicePrincipal" },
  ]);
});

function snapshotText(members: Record<string, unknown>[]): string {
  return JSON.stringify({ schema: "ccof.sync.snapshot.v1", tenantId: TENANT, readAt: NOW.toISOString(), groups: [{ groupId: GROUP_STD, members }, { groupId: GROUP_PRM, members: [] }] });
}

test("a snapshot member whose accountEnabled is not a boolean is refused before anything is written", () => {
  for (const value of [null, "false", 0]) {
    const result = validateSnapshot(snapshotText([{ id: PERSON_A, type: "user", accountEnabled: value }]), { tenantId: TENANT, now: NOW, limits: SNAPSHOT_LIMITS });
    assert.deepEqual(result.ok ? "ok" : result.problems, ["groups:invalid_member"], JSON.stringify(value));
  }
});

test("apply-snapshot does not admit a member recorded as disabled, and admits one recorded without a state", async () => {
  const text = snapshotText([
    { id: PERSON_A, type: "user", accountEnabled: false },
    { id: PERSON_B, type: "user" },
  ]);
  const validated = validateSnapshot(text, { tenantId: TENANT, now: NOW, limits: SNAPSHOT_LIMITS });
  assert.equal(validated.ok, true);
  if (!validated.ok) return;
  const h = harness(snapshotReader(validated).readGroup);
  h.entitlements.seed({ id: PERSON_A, personId: PERSON_A, projectMemberships: [stdMembership()], generation: 4, lastVerifiedAt: EARLIER });
  await runSync(CONFIG, h.deps, { ...h.context, source: { kind: "snapshot", sha256: validated.sha256, readAt: validated.readAt } });
  assert.deepEqual(h.entitlements.docs.get(PERSON_A)?.doc.projectMemberships, []);
  assert.equal((h.entitlements.docs.get(PERSON_B)?.doc.projectMemberships as unknown[]).length, 1);
  assert.deepEqual([h.runLine().source, h.runLine().counts.membersDisabled], ["snapshot", 1]);
});
