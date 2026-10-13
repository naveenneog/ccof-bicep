// The safety rules of the plan (src/sync/plan.ts, ADR-0016): a failed read or
// an invalid project document never removes access, removals beyond the
// configured limits are withheld, and classification conflicts resolve the same
// way every time.

import { test } from "node:test";
import assert from "node:assert/strict";
import { planSync, removalLimitExceeded } from "../src/sync/plan.ts";
import type { PlanInput } from "../src/sync/plan-types.ts";
import { readProjectDocument } from "../src/sync/projects.ts";
import type { GroupMember, GroupReadResult } from "../src/sync/graph.ts";
import { GROUP_PRM, GROUP_STD, PERSON_A, PERSON_B, PERSON_C, classification, projectDoc, familyPolicy } from "./helpers/sync-fakes.ts";

const NOW = new Date("2026-10-11T12:00:00.000Z");
const EARLIER = "2026-10-10T08:00:00.000Z";

function ok(groupId: string, ...ids: string[]): [string, GroupReadResult] {
  const members: GroupMember[] = ids.map((id) => ({ id, kind: "user" }));
  return [groupId, { ok: true, groupId, members, pages: 1, retries: 0 }];
}

function failed(groupId: string, reason = "graph_permission_missing"): [string, GroupReadResult] {
  return [groupId, { ok: false, groupId, reason: reason as "graph_permission_missing", httpStatus: 403, graphErrorCode: "Authorization_RequestDenied", retries: 0 }];
}

function membership(projectId: string, code: string, groupId: string) {
  return {
    projectId,
    classification: code,
    classificationGroupId: groupId,
    familyPolicy: familyPolicy(code === "STD" ? ["claude-haiku-4-5", "claude-sonnet-5"] : ["claude-haiku-4-5", "claude-opus-5"]),
    backendId: "foundry-sample-hub",
    aggregateMode: "notify",
    denormalizedAt: EARLIER,
    joinedAt: EARLIER,
    status: "active",
  };
}

function existing(personId: string, ...memberships: unknown[]) {
  return { doc: { id: personId, personId, projectMemberships: memberships, generation: 2, lastVerifiedAt: EARLIER }, etag: `"e-${personId}"` };
}

function input(overrides: Partial<PlanInput>): PlanInput {
  return {
    projects: [readProjectDocument(projectDoc("PILOT1"))],
    groups: new Map([ok(GROUP_STD), ok(GROUP_PRM)]),
    existing: [],
    memberTypes: ["user"],
    removalLimits: { maxRemovalsPerRun: 10, maxRemovalFraction: 0.5 },
    now: NOW,
    ...overrides,
  };
}

test("a failed group read leaves the whole project unchanged: no removal, no addition, no change", () => {
  const plan = planSync(
    input({
      groups: new Map([failed(GROUP_STD), ok(GROUP_PRM, PERSON_B)]),
      existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD))],
    }),
  );
  assert.deepEqual(plan.writes, [], "PERSON_A keeps STD and PERSON_B is not added while STD cannot be read");
  assert.deepEqual(plan.frozenProjects, ["PILOT1"]);
  assert.deepEqual(
    plan.events.map((e) => [e.event, e.reason, e.projectId, e.groupId, e.httpStatus, e.graphErrorCode]),
    [["refusal", "graph_permission_missing", "PILOT1", GROUP_STD, 403, "Authorization_RequestDenied"]],
  );
});

test("a failed read freezes only its own project; another project of the same person still changes", () => {
  const other = projectDoc("ALPHA2", { classifications: { CYB: classification("55555555-5555-4555-8555-555555555555") } });
  const plan = planSync(
    input({
      projects: [readProjectDocument(projectDoc("PILOT1")), readProjectDocument(other)],
      groups: new Map([failed(GROUP_STD), ok(GROUP_PRM), ok("55555555-5555-4555-8555-555555555555", PERSON_A)]),
      existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD))],
    }),
  );
  assert.equal(plan.writes.length, 1);
  assert.deepEqual(plan.writes[0].document.projectMemberships.map((m) => m.projectId), ["ALPHA2", "PILOT1"]);
  assert.deepEqual(plan.writes[0].document.projectMemberships[1], membership("PILOT1", "STD", GROUP_STD), "carried over unchanged");
});

test("a group missing from the read results is treated as failed, never as empty", () => {
  const plan = planSync(input({ groups: new Map([ok(GROUP_PRM)]), existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD))] }));
  assert.deepEqual(plan.writes, []);
  assert.deepEqual(plan.events.map((e) => [e.reason, e.groupId]), [["graph_group_not_read", GROUP_STD]]);
});

test("an invalid project document freezes that project and is reported with its problems", () => {
  const bad = projectDoc("PILOT1");
  delete (bad.classifications as Record<string, Record<string, unknown>>).STD.familyPolicy;
  const plan = planSync(input({ projects: [readProjectDocument(bad)], existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD))] }));
  assert.deepEqual(plan.writes, []);
  assert.deepEqual(plan.frozenProjects, ["PILOT1"]);
  assert.deepEqual(
    plan.events.map((e) => [e.reason, e.projectId, e.problems]),
    [["project_document_invalid", "PILOT1", ["classifications.STD.familyPolicy:invalid_family_policy"]]],
  );
});

test("an invalid document without a readable projectId withholds every removal, but additions still apply", () => {
  const unreadable = readProjectDocument({ status: "active" });
  const plan = planSync(
    input({
      projects: [readProjectDocument(projectDoc("PILOT1")), unreadable],
      groups: new Map([ok(GROUP_STD, PERSON_B), ok(GROUP_PRM)]),
      existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD))],
    }),
  );
  assert.deepEqual(plan.writes.map((w) => w.personId), [PERSON_B]);
  assert.equal(plan.removalsWithheld, "project_document_unidentified");
  assert.equal(plan.counts.withheldRemovals, 1);
  assert.ok(plan.events.some((e) => e.reason === "project_document_unidentified" && e.event === "refusal"));
});

test("two documents for one projectId freeze that project", () => {
  const plan = planSync(
    input({
      projects: [readProjectDocument(projectDoc("PILOT1")), readProjectDocument(projectDoc("PILOT1"))],
      groups: new Map([ok(GROUP_STD), ok(GROUP_PRM)]),
      existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD))],
    }),
  );
  assert.deepEqual(plan.writes, []);
  assert.deepEqual(plan.events.map((e) => [e.reason, e.projectId]), [["project_document_duplicate", "PILOT1"]]);
});

test("conflict: a person in STD and PRM who already holds STD keeps STD, and the conflict names both codes", () => {
  const plan = planSync(
    input({ groups: new Map([ok(GROUP_STD, PERSON_A), ok(GROUP_PRM, PERSON_A)]), existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD))] }),
  );
  assert.deepEqual(plan.writes, [], "the incumbent STD membership is unchanged");
  assert.deepEqual(
    plan.events.map((e) => [e.event, e.reason, e.projectId, e.personId, e.classifications, e.kept]),
    [["conflict", "classification_conflict", "PILOT1", PERSON_A, ["PRM", "STD"], "STD"]],
  );
  assert.equal(plan.counts.conflicts, 1);
});

test("conflict: a new person in two classification groups of one project is admitted to neither", () => {
  const plan = planSync(input({ groups: new Map([ok(GROUP_STD, PERSON_A), ok(GROUP_PRM, PERSON_A)]) }));
  assert.deepEqual(plan.writes, []);
  assert.deepEqual(plan.events.map((e) => [e.reason, e.kept]), [["classification_conflict", null]]);
});

test("conflict: an incumbent outside the conflicting set is removed, and the removal is counted", () => {
  const doc = projectDoc("PILOT1", {
    classifications: { STD: classification(GROUP_STD), PRM: classification(GROUP_PRM), CYB: classification("66666666-6666-4666-8666-666666666666") },
  });
  const plan = planSync(
    input({
      projects: [readProjectDocument(doc)],
      groups: new Map([ok(GROUP_STD, PERSON_A), ok(GROUP_PRM, PERSON_A), ok("66666666-6666-4666-8666-666666666666")]),
      existing: [existing(PERSON_A, membership("PILOT1", "CYB", "66666666-6666-4666-8666-666666666666"))],
    }),
  );
  assert.deepEqual(plan.writes[0].document.projectMemberships, []);
  assert.equal(plan.counts.removedMemberships, 1);
});

test("the conflict rule is deterministic: group order and member order do not change the outcome", () => {
  const a = planSync(input({ groups: new Map([ok(GROUP_PRM, PERSON_A), ok(GROUP_STD, PERSON_A)]), existing: [existing(PERSON_A, membership("PILOT1", "PRM", GROUP_PRM))] }));
  const b = planSync(input({ groups: new Map([ok(GROUP_STD, PERSON_A), ok(GROUP_PRM, PERSON_A)]), existing: [existing(PERSON_A, membership("PILOT1", "PRM", GROUP_PRM))] }));
  assert.deepEqual(a.events, b.events);
  assert.deepEqual(a.writes, b.writes);
  assert.equal(a.events[0].kept, "PRM");
});

test("removalLimitExceeded: refuse only when removals exceed both the count and the fraction", () => {
  const limits = { maxRemovalsPerRun: 10, maxRemovalFraction: 0.1 };
  assert.equal(removalLimitExceeded(10, 20, limits), false, "at the count limit");
  assert.equal(removalLimitExceeded(11, 20, limits), true, "over the count and over 10% of 20");
  assert.equal(removalLimitExceeded(11, 200, limits), false, "over the count, within 10% of 200 = 20");
  assert.equal(removalLimitExceeded(21, 200, limits), true);
  assert.equal(removalLimitExceeded(0, 0, { maxRemovalsPerRun: 0, maxRemovalFraction: 0 }), false, "nothing to remove");
  assert.equal(removalLimitExceeded(1, 1, { maxRemovalsPerRun: 0, maxRemovalFraction: 0 }), true, "zero limits withhold every removal");
  assert.equal(removalLimitExceeded(3, 3, { maxRemovalsPerRun: 0, maxRemovalFraction: 1 }), false, "fraction 1 allows a full removal");
});

test("removals over the limits are withheld, while additions and changes still apply, with one alertable event", () => {
  const plan = planSync(
    input({
      groups: new Map([ok(GROUP_STD, PERSON_C), ok(GROUP_PRM)]),
      existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD)), existing(PERSON_B, membership("PILOT1", "PRM", GROUP_PRM))],
      removalLimits: { maxRemovalsPerRun: 1, maxRemovalFraction: 0.5 },
    }),
  );
  assert.deepEqual(plan.writes.map((w) => w.personId), [PERSON_C], "only the addition is written");
  assert.equal(plan.removalsWithheld, "removal_limit_exceeded");
  assert.equal(plan.counts.withheldRemovals, 2);
  assert.equal(plan.counts.removedMemberships, 0);
  const refusal = plan.events.find((e) => e.reason === "removal_limit_exceeded");
  assert.deepEqual(refusal?.counts, { removals: 2, existingMemberships: 2, maxRemovalsPerRun: 1, maxRemovalFraction: 0.5 });
  assert.equal(refusal?.event, "refusal");
});

test("removals within the limits apply", () => {
  const plan = planSync(
    input({
      existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD)), existing(PERSON_B, membership("PILOT1", "PRM", GROUP_PRM))],
      removalLimits: { maxRemovalsPerRun: 2, maxRemovalFraction: 0 },
    }),
  );
  assert.equal(plan.removalsWithheld, null);
  assert.deepEqual(plan.writes.map((w) => w.document.projectMemberships.length), [0, 0]);
  assert.equal(plan.counts.removedMemberships, 2);
});

test("a person moving between projects while removals are withheld keeps the old project and gains the new one", () => {
  const other = projectDoc("ALPHA2", { classifications: { STD: classification("77777777-7777-4777-8777-777777777777") } });
  const plan = planSync(
    input({
      projects: [readProjectDocument(projectDoc("PILOT1")), readProjectDocument(other)],
      groups: new Map([ok(GROUP_STD), ok(GROUP_PRM), ok("77777777-7777-4777-8777-777777777777", PERSON_A)]),
      existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD))],
      removalLimits: { maxRemovalsPerRun: 0, maxRemovalFraction: 0 },
    }),
  );
  assert.deepEqual(plan.writes[0].document.projectMemberships.map((m) => m.projectId), ["ALPHA2", "PILOT1"]);
});

test("a written document never holds two active memberships of one project; an unservable record carries nothing unverified", () => {
  const other = projectDoc("ALPHA2", { classifications: { STD: classification("88888888-8888-4888-8888-888888888888") } });
  const plan = planSync(
    input({
      projects: [readProjectDocument(projectDoc("PILOT1")), readProjectDocument(other)],
      groups: new Map([failed(GROUP_STD), ok(GROUP_PRM), ok("88888888-8888-4888-8888-888888888888", PERSON_A)]),
      existing: [existing(PERSON_A, membership("PILOT1", "STD", GROUP_STD), membership("PILOT1", "PRM", GROUP_PRM))],
    }),
  );
  // The resolver refuses a record with a duplicate (503), so it grants nothing today, and the
  // frozen PILOT1 memberships are not carried forward without a successful read.
  const written = plan.writes[0].document.projectMemberships;
  assert.deepEqual(written.map((m) => `${m.projectId}:${m.classification}`), ["ALPHA2:STD"]);
  assert.deepEqual(
    plan.events.filter((e) => e.reason === "entitlement_record_repaired").map((e) => e.problems),
    [["projectMemberships:duplicate_active_project"]],
  );
});
