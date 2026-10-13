// Planning the projection (src/sync/plan.ts): what each person's `entitlement`
// document should hold, given the registered groups, what Graph returned and
// what Cosmos holds now. Pure: no Azure, no clock read.

import { test } from "node:test";
import assert from "node:assert/strict";
import { planSync } from "../src/sync/plan.ts";
import type { PlanInput } from "../src/sync/plan-types.ts";
import { readProjectDocument } from "../src/sync/projects.ts";
import type { GroupMember, GroupReadResult } from "../src/sync/graph.ts";
import { GROUP_CYB, GROUP_PRM, GROUP_STD, NESTED_GROUP, PERSON_A, PERSON_B, PERSON_C, SP_TEST, classification, projectDoc, familyPolicy } from "./helpers/sync-fakes.ts";

const NOW = new Date("2026-10-11T12:00:00.000Z");
const EARLIER = "2026-10-10T08:00:00.000Z";

function groupsOf(entries: Record<string, GroupMember[]>): Map<string, GroupReadResult> {
  return new Map(Object.entries(entries).map(([groupId, members]) => [groupId, { ok: true, groupId, members, pages: 1, retries: 0 }]));
}

function users(...ids: string[]): GroupMember[] {
  return ids.map((id) => ({ id, kind: "user" as const }));
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

function existingDoc(personId: string, memberships: unknown[], extra: Record<string, unknown> = {}) {
  return {
    doc: { id: personId, personId, projectMemberships: memberships, generation: 4, lastVerifiedAt: EARLIER, ...extra },
    etag: `"etag-${personId}"`,
  };
}

test("a new member gets a document with the C-4 fields, generation 1 and lastVerifiedAt set to the run time", () => {
  const plan = planSync(input({ groups: groupsOf({ [GROUP_STD]: users(PERSON_A), [GROUP_PRM]: [] }) }));
  assert.equal(plan.writes.length, 1);
  const write = plan.writes[0];
  assert.equal(write.kind, "create");
  assert.equal(write.etag, null);
  assert.deepEqual(write.document, {
    id: PERSON_A,
    personId: PERSON_A,
    projectMemberships: [stdMembership({ denormalizedAt: NOW.toISOString(), joinedAt: NOW.toISOString() })],
    generation: 1,
    lastVerifiedAt: "2026-10-11T12:00:00.000Z",
  });
  assert.equal(plan.counts.creates, 1);
});

test("a document that already matches the directory is not written (ADR-0008: records persist)", () => {
  const plan = planSync(
    input({ groups: groupsOf({ [GROUP_STD]: users(PERSON_A), [GROUP_PRM]: [] }), existing: [existingDoc(PERSON_A, [stdMembership()])] }),
  );
  assert.deepEqual(plan.writes, []);
  assert.equal(plan.counts.unchanged, 1);
});

test("a changed project setting is copied with generation + 1, a new denormalizedAt, and the original joinedAt", () => {
  const plan = planSync(
    input({
      groups: groupsOf({ [GROUP_STD]: users(PERSON_A), [GROUP_PRM]: [] }),
      existing: [existingDoc(PERSON_A, [stdMembership({ familyPolicy: familyPolicy(["claude-haiku-4-5"]) })])],
    }),
  );
  assert.equal(plan.writes.length, 1);
  const write = plan.writes[0];
  assert.equal(write.kind, "replace");
  assert.equal(write.etag, `"etag-${PERSON_A}"`);
  assert.equal(write.document.generation, 5);
  assert.equal(write.document.lastVerifiedAt, NOW.toISOString());
  assert.deepEqual(write.document.projectMemberships, [stdMembership({ denormalizedAt: NOW.toISOString() })]);
});

test("a person removed from every group keeps a document with an empty membership list", () => {
  const plan = planSync(input({ existing: [existingDoc(PERSON_A, [stdMembership()])] }));
  assert.equal(plan.writes.length, 1);
  assert.deepEqual(plan.writes[0].document.projectMemberships, []);
  assert.equal(plan.writes[0].document.generation, 5);
  assert.equal(plan.counts.removedMemberships, 1);
  assert.equal(plan.counts.emptiedDocuments, 1);
});

test("a person with no document and no group gets nothing written", () => {
  const plan = planSync(input());
  assert.deepEqual(plan.writes, []);
  assert.equal(plan.counts.unchanged, 0);
});

test("moving from STD to PRM changes the classification: not a removal, and joinedAt restarts", () => {
  const plan = planSync(
    input({ groups: groupsOf({ [GROUP_STD]: [], [GROUP_PRM]: users(PERSON_A) }), existing: [existingDoc(PERSON_A, [stdMembership()])] }),
  );
  const memberships = plan.writes[0].document.projectMemberships;
  assert.deepEqual(memberships.map((m) => [m.classification, m.classificationGroupId, m.joinedAt]), [["PRM", GROUP_PRM, NOW.toISOString()]]);
  assert.equal(plan.counts.removedMemberships, 0);
});

test("a membership whose project has no document is kept and reported: only directory evidence removes access", () => {
  const plan = planSync(
    input({
      groups: groupsOf({ [GROUP_STD]: users(PERSON_A), [GROUP_PRM]: [] }),
      existing: [existingDoc(PERSON_A, [stdMembership(), stdMembership({ projectId: "GONE9" })])],
    }),
  );
  assert.deepEqual(plan.writes, [], "nothing changes for PERSON_A");
  assert.equal(plan.counts.removedMemberships, 0);
  assert.deepEqual(plan.events.map((e) => [e.event, e.reason, e.projectId]), [["refusal", "project_document_missing", "GONE9"]]);
  assert.deepEqual(plan.frozenProjects, ["GONE9"]);
});

test("a document whose id is not a GUID is not the sync's: ignored, never rewritten or logged", () => {
  const seeded = { doc: { id: "itest-person-1", personId: "itest-person-1", projectMemberships: [], generation: 1, lastVerifiedAt: EARLIER }, etag: '"s"' };
  const plan = planSync(input({ existing: [seeded] }));
  assert.deepEqual(plan.writes, []);
  assert.equal(plan.counts.documentsIgnored, 1);
});

test("an expired legacy record grants nothing, so its memberships are never carried over (resolver: no record)", () => {
  const expired = existingDoc(PERSON_A, [stdMembership()], { expiresAt: "2026-10-11T11:00:00Z" });
  const denied: GroupReadResult = { ok: false, groupId: GROUP_STD, reason: "graph_permission_missing", httpStatus: 403, graphErrorCode: null, retries: 0 };
  const frozen = planSync(input({ groups: new Map([[GROUP_STD, denied], ...groupsOf({ [GROUP_PRM]: [] })]), existing: [expired] }));
  for (const write of frozen.writes) {
    assert.deepEqual(write.document.projectMemberships, [], "a frozen project does not revive an expired record");
  }
  const unparseable = planSync(input({ existing: [existingDoc(PERSON_A, [stdMembership()], { expiresAt: "soon" })] }));
  assert.deepEqual(unparseable.writes.map((w) => w.document.projectMemberships), [[]]);
  assert.equal(unparseable.counts.removedMemberships, 0, "an unusable record held no access to remove");
});

test("a future legacy expiry is kept while an unverified membership is carried over, and dropped once all are verified", () => {
  const live = existingDoc(PERSON_A, [stdMembership()], { expiresAt: "2026-10-11T13:00:00Z" });
  const otherGroup = "12121212-1212-4212-8212-121212121212";
  const other = projectDoc("ALPHA2", { classifications: { CYB: classification(otherGroup) } });
  const unavailable: GroupReadResult = { ok: false, groupId: GROUP_STD, reason: "graph_unavailable", httpStatus: 503, graphErrorCode: null, retries: 0 };
  const frozenStd = planSync(
    input({
      projects: [readProjectDocument(projectDoc("PILOT1")), readProjectDocument(other)],
      groups: new Map([[GROUP_STD, unavailable], ...groupsOf({ [GROUP_PRM]: [], [otherGroup]: users(PERSON_A) })]),
      existing: [live],
    }),
  );
  assert.equal(frozenStd.writes[0].document.expiresAt, "2026-10-11T13:00:00Z", "the carried STD membership keeps its old expiry");
  const verified = planSync(input({ groups: groupsOf({ [GROUP_STD]: users(PERSON_A), [GROUP_PRM]: [] }), existing: [live] }));
  assert.equal("expiresAt" in verified.writes[0].document, false);
});

test("writes are ordered by person id, and duplicate members of one group count once", () => {
  const plan = planSync(input({ groups: groupsOf({ [GROUP_STD]: users(PERSON_C, PERSON_A, PERSON_A), [GROUP_PRM]: users(PERSON_B) }) }));
  assert.deepEqual(plan.writes.map((w) => w.personId), [PERSON_A, PERSON_B, PERSON_C]);
  assert.equal(plan.counts.membersAdmitted, 3);
});

test("service principals are admitted only when configured; nested groups and unknown types never are", () => {
  const members: GroupMember[] = [
    { id: PERSON_A, kind: "user" },
    { id: SP_TEST, kind: "servicePrincipal" },
    { id: NESTED_GROUP, kind: "group" },
    { id: PERSON_B, kind: "unknown" },
  ];
  const usersOnly = planSync(input({ groups: groupsOf({ [GROUP_STD]: members, [GROUP_PRM]: [] }) }));
  assert.deepEqual(usersOnly.writes.map((w) => w.personId), [PERSON_A]);
  assert.deepEqual(
    usersOnly.events.map((e) => [e.reason, e.groupId, e.memberId]),
    [
      ["member_type_not_admitted", GROUP_STD, SP_TEST],
      ["nested_group_not_expanded", GROUP_STD, NESTED_GROUP],
      ["member_type_unknown", GROUP_STD, PERSON_B],
    ],
  );

  const withSp = planSync(input({ memberTypes: ["servicePrincipal", "user"], groups: groupsOf({ [GROUP_STD]: members, [GROUP_PRM]: [] }) }));
  assert.deepEqual(withSp.writes.map((w) => w.personId), [PERSON_A, SP_TEST]);
});

test("a legacy expiresAt is dropped by rewriting the document, even when its memberships match (ADR-0008)", () => {
  const plan = planSync(
    input({
      groups: groupsOf({ [GROUP_STD]: users(PERSON_A), [GROUP_PRM]: [] }),
      existing: [existingDoc(PERSON_A, [stdMembership()], { expiresAt: "2026-10-11T13:00:00Z" })],
    }),
  );
  assert.equal(plan.writes.length, 1);
  assert.equal("expiresAt" in plan.writes[0].document, false);
  assert.equal(plan.writes[0].document.generation, 5);
});

test("a record the resolver would refuse is repaired: invalid generation restarts at 1, a future lastVerifiedAt is replaced", () => {
  const badGeneration = planSync(
    input({
      groups: groupsOf({ [GROUP_STD]: users(PERSON_A), [GROUP_PRM]: [] }),
      existing: [existingDoc(PERSON_A, [stdMembership()], { generation: "7" })],
    }),
  );
  assert.equal(badGeneration.writes[0].document.generation, 1);
  assert.deepEqual(
    badGeneration.events.map((e) => [e.reason, e.personId, e.problems]),
    [["entitlement_record_repaired", PERSON_A, ["generation:invalid"]]],
  );

  const future = planSync(
    input({
      groups: groupsOf({ [GROUP_STD]: users(PERSON_A), [GROUP_PRM]: [] }),
      existing: [existingDoc(PERSON_A, [stdMembership()], { lastVerifiedAt: "2026-10-12T00:00:00Z" })],
    }),
  );
  assert.equal(future.writes[0].document.lastVerifiedAt, NOW.toISOString());
  assert.equal(future.writes[0].document.generation, 5);
});

test("a document whose id is not its personId is ignored and counted, never rewritten", () => {
  const odd = { doc: { id: "seed-1", personId: PERSON_A, projectMemberships: [], generation: 1, lastVerifiedAt: EARLIER }, etag: '"x"' };
  const plan = planSync(input({ existing: [odd] }));
  assert.deepEqual(plan.writes, []);
  assert.equal(plan.counts.documentsIgnored, 1);
});

test("an existing subscriptionId on an unchanged membership is preserved (C-4: optional)", () => {
  const withKey = stdMembership({ subscriptionId: "sub-123" });
  const plan = planSync(input({ groups: groupsOf({ [GROUP_STD]: users(PERSON_A), [GROUP_PRM]: [] }), existing: [existingDoc(PERSON_A, [withKey])] }));
  assert.deepEqual(plan.writes, []);
});

test("CYB-only projects and three classifications plan independently per project", () => {
  const doc = projectDoc("PILOT1", {
    classifications: {
      STD: classification(GROUP_STD),
      PRM: classification(GROUP_PRM),
      CYB: classification(GROUP_CYB),
    },
  });
  const plan = planSync(
    input({ projects: [readProjectDocument(doc)], groups: groupsOf({ [GROUP_STD]: users(PERSON_A), [GROUP_PRM]: users(PERSON_B), [GROUP_CYB]: users(PERSON_C) }) }),
  );
  assert.deepEqual(
    plan.writes.map((w) => [w.personId, w.document.projectMemberships[0].classification]),
    [
      [PERSON_A, "STD"],
      [PERSON_B, "PRM"],
      [PERSON_C, "CYB"],
    ],
  );
});
