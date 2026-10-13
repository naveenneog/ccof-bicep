import { test } from "node:test";
import assert from "node:assert/strict";
import type { FamilyPolicy } from "../src/contracts/model-families.ts";
import type { ProjectMembership } from "../src/sync/types.ts";
import { canonical } from "../src/sync/membership.ts";
import { planSync } from "../src/sync/plan.ts";
import type { PlanInput } from "../src/sync/plan-types.ts";
import { readProjectDocument } from "../src/sync/projects.ts";
import { GROUP_STD, PERSON_A, projectDoc } from "./helpers/sync-fakes.ts";

const now = new Date("2026-10-13T12:00:00Z");
const before = "2026-10-12T12:00:00Z";
const unlimited = () => ({ tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null });
function policy(): FamilyPolicy {
  return {
    aggregateLimits: {
      person: { tokensPerMinute: 1000000, tokenQuota: 500000, tokenQuotaPeriod: "Daily" },
      group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: "Daily" },
    },
    families: { haiku: { models: ["claude-haiku-4-5", "claude-haiku-4-5-20251001"], person: unlimited(), group: unlimited() } },
  };
}
function project(p: unknown, extra: Record<string, unknown> = {}) {
  return projectDoc("PILOT1", { classifications: { STD: { groupId: GROUP_STD, aggregateMode: "notify", familyPolicy: p, ...extra } } });
}
function prior(p: unknown = policy(), extra: Record<string, unknown> = {}) {
  return {
    projectId: "PILOT1", classification: "STD", classificationGroupId: GROUP_STD, backendId: "foundry-sample-hub",
    aggregateMode: "notify", familyPolicy: p, status: "active", joinedAt: before, denormalizedAt: before, ...extra,
  };
}
function input(doc: unknown, membership?: Record<string, unknown>): PlanInput {
  return {
    projects: [readProjectDocument(doc)],
    groups: new Map([[GROUP_STD, { ok: true, groupId: GROUP_STD, members: [{ id: PERSON_A, kind: "user" }], pages: 1, retries: 0 }]]),
    existing: membership ? [{ doc: { id: PERSON_A, personId: PERSON_A, projectMemberships: [membership], generation: 7, lastVerifiedAt: before }, etag: '"original"' }] : [],
    memberTypes: ["user"], removalLimits: { maxRemovalsPerRun: 10, maxRemovalFraction: 0.5 }, now,
  };
}

test("sync copies the full family policy and original aggregate limits, without legacy fields", () => {
  const p = policy();
  const result = readProjectDocument(project(p));
  assert.equal(result.ok, true);
  const plan = planSync(input(project(p)));
  assert.equal(plan.writes.length, 1);
  const membership = plan.writes[0].document.projectMemberships[0];
  // A compile-time assignment binds the projection field to the one shared policy type.
  const compatible: FamilyPolicy = (membership as ProjectMembership).familyPolicy;
  assert.equal(canonical(compatible), canonical(p));
  assert.equal(canonical(compatible.aggregateLimits), canonical(p.aggregateLimits));
  assert.equal("modelAllowList" in membership, false);
  assert.equal("tokenLimits" in membership, false);
});

test("model, family, aggregate and family-limit changes each increment generation without changing joinedAt", () => {
  const changes = [
    (p: FamilyPolicy) => { p.families.haiku!.models.push("exact-alias"); },
    (p: FamilyPolicy) => { p.families.sonnet = { models: ["claude-sonnet-5"], person: unlimited(), group: unlimited() }; },
    (p: FamilyPolicy) => { p.families.haiku!.person.tokensPerMinute = 1; },
    (p: FamilyPolicy) => { p.families.haiku!.group.tokenQuota = 1; p.families.haiku!.group.tokenQuotaPeriod = "Hourly"; },
    (p: FamilyPolicy) => { p.aggregateLimits.person.tokensPerMinute = 2; },
    (p: FamilyPolicy) => { p.families.haiku!.models.pop(); },
  ];
  for (const change of changes) {
    const changed = policy();
    change(changed);
    const plan = planSync(input(project(changed), prior()));
    assert.equal(plan.writes.length, 1);
    const write = plan.writes[0];
    assert.equal(write.kind, "replace");
    assert.equal(write.etag, '"original"');
    assert.equal(write.document.generation, 8);
    assert.equal(write.document.projectMemberships[0].joinedAt, before);
    assert.equal(write.document.projectMemberships[0].denormalizedAt, now.toISOString());
    assert.equal(canonical(write.document.projectMemberships[0].familyPolicy), canonical(changed));
  }
});

test("canonical JSON equality avoids rewriting unchanged policies despite object key order", () => {
  const p = policy();
  const reordered = { families: p.families, aggregateLimits: { group: p.aggregateLimits.group, person: p.aggregateLimits.person } };
  const plan = planSync(input(project(reordered), prior(p)));
  assert.deepEqual(plan.writes, []);
  assert.equal(plan.counts.unchanged, 1);
});

test("removing a family revokes only that family and preserves aggregate ceilings", () => {
  const original = policy();
  original.families.sonnet = { models: ["claude-sonnet-5"], person: unlimited(), group: unlimited() };
  const changed = policy();
  const plan = planSync(input(project(changed), prior(original)));
  assert.equal(plan.writes[0].document.generation, 8);
  const copied = plan.writes[0].document.projectMemberships[0].familyPolicy;
  assert.deepEqual(Object.keys(copied.families), ["haiku"]);
  assert.deepEqual(copied.aggregateLimits, original.aggregateLimits);
});

test("verified old memberships are replaced, never expanded from legacy prefixes", () => {
  const legacy: Record<string, unknown> = prior();
  delete legacy.familyPolicy;
  Object.assign(legacy, { modelAllowList: ["claude-haiku-unknown"], tokenLimits: { person: unlimited(), group: unlimited() } });
  const plan = planSync(input(project(policy()), legacy));
  assert.equal(plan.writes[0].document.generation, 8);
  const copied = plan.writes[0].document.projectMemberships[0];
  assert.equal("modelAllowList" in copied, false);
  assert.equal("tokenLimits" in copied, false);
  assert.deepEqual(copied.familyPolicy, policy());
  assert.equal(copied.denormalizedAt, now.toISOString());
});

test("mixed old and new project policy fields are not accepted as a dual-format migration", () => {
  for (const extra of [{ modelAllowList: ["claude-haiku-4-5"] }, { tokenLimits: { person: unlimited(), group: unlimited() } }]) {
    const result = readProjectDocument(project(policy(), extra));
    assert.deepEqual(result, { ok: false, projectId: "PILOT1", problems: ["classifications.STD:legacy_policy_fields"] });
  }
});

test("copied policy is independent of project input mutation", () => {
  const p = policy();
  const source = project(p);
  const configured = input(source);
  const result = planSync(configured);
  assert.equal(configured.projects[0].ok, true);
  if (!configured.projects[0].ok) assert.fail("valid project");
  configured.projects[0].classifications[0].familyPolicy.families.haiku!.models.push("late-alias");
  p.aggregateLimits.person.tokenQuota = 1;
  assert.deepEqual(result.writes[0].document.projectMemberships[0].familyPolicy, policy());
});

test("old project documents fail closed and invalid family policies freeze existing memberships", () => {
  const old = project(undefined);
  assert.equal(readProjectDocument(old).ok, false);
  const p = policy();
  p.families.fable = { models: ["claude-fable-configured"], person: unlimited(), group: unlimited() };
  const bad = readProjectDocument(project(p));
  assert.deepEqual(bad, { ok: false, projectId: "PILOT1", problems: ["classifications.STD.familyPolicy:family_classification_forbidden"] });
  const plan = planSync(input(project(p), prior()));
  assert.deepEqual(plan.frozenProjects, ["PILOT1"]);
  assert.deepEqual(plan.writes, []);
});

test("classification display name is an exact optional informational snapshot, not classification authority", () => {
  const name = '  CYB Approved "Équipe"  ';
  const plan = planSync(input(project(policy(), { classificationGroupDisplayName: name })));
  assert.equal(plan.writes[0].document.projectMemberships[0].classificationGroupDisplayName, name);
  assert.equal(plan.writes[0].document.projectMemberships[0].classification, "STD");
  const changed = planSync(input(project(policy(), { classificationGroupDisplayName: name }), prior(policy(), { classificationGroupDisplayName: "Old name" })));
  assert.equal(changed.writes[0].document.generation, 8);
  const unchanged = planSync(input(project(policy(), { classificationGroupDisplayName: name }), prior(policy(), { classificationGroupDisplayName: name })));
  assert.deepEqual(unchanged.writes, []);
  for (const invalid of ["", "x".repeat(257), 1, null]) {
    const result = readProjectDocument(project(policy(), { classificationGroupDisplayName: invalid }));
    assert.equal(result.ok, false);
  }
});
