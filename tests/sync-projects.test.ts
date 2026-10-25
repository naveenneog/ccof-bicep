// Reading `projects` documents (src/sync/projects.ts). Only onboarding Stage 3
// writes them (docs/PILOT.md C-5); the sync validates each one at the boundary
// and never guesses a missing field. An invalid document is reported with
// field paths and problem codes, never with values.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readProjectDocument } from "../src/sync/projects.ts";
import { GROUP_PRM, GROUP_STD, projectDoc, familyPolicy, tokenLimits } from "./helpers/sync-fakes.ts";

function problemsOf(doc: unknown): string[] {
  const result = readProjectDocument(doc);
  if (result.ok) assert.fail("expected the document to be refused");
  return result.problems;
}

test("a valid document yields one registration per classification with the C-4 fields", () => {
  const result = readProjectDocument(projectDoc("PILOT1"));
  if (!result.ok) assert.fail(JSON.stringify(result.problems));
  assert.equal(result.projectId, "PILOT1");
  assert.deepEqual(
    result.classifications.map((c) => [c.classification, c.groupId]),
    [
      ["PRM", GROUP_PRM],
      ["STD", GROUP_STD],
    ],
  );
  const std = result.classifications.find((c) => c.classification === "STD");
  assert.deepEqual(std, {
    projectId: "PILOT1",
    classification: "STD",
    groupId: GROUP_STD,
    familyPolicy: familyPolicy(),
    backendId: "foundry-sample-hub",
    aggregateMode: "notify",
  });
});

test("group ids are compared without case: an upper-case id is stored lower-case", () => {
  const doc = projectDoc("PILOT1");
  (doc.classifications as Record<string, Record<string, unknown>>).STD.groupId = GROUP_STD.toUpperCase();
  const result = readProjectDocument(doc);
  if (!result.ok) assert.fail(JSON.stringify(result.problems));
  assert.equal(result.classifications.find((c) => c.classification === "STD")?.groupId, GROUP_STD);
});

test("group and classification identifiers must match the entire value, not stop before a final newline", () => {
  for (const suffix of ["\n", "\r\n", " "]) {
    const doc = projectDoc("PILOT1");
    (doc.classifications as Record<string, Record<string, unknown>>).STD.groupId = `${GROUP_STD}${suffix}`;
    assert.deepEqual(problemsOf(doc), ["classifications.STD.groupId:invalid"]);
    const badCode = projectDoc("PILOT1", { classifications: { [`STD${suffix}`]: { groupId: GROUP_STD, familyPolicy: familyPolicy(), aggregateMode: "notify" } } });
    assert.deepEqual(problemsOf(badCode), ["classifications:invalid_code"]);
  }
});

test("a document without familyPolicy on a classification is refused and names the field", () => {
  const doc = projectDoc("PILOT1");
  delete (doc.classifications as Record<string, Record<string, unknown>>).STD.familyPolicy;
  assert.deepEqual(problemsOf(doc), ["classifications.STD.familyPolicy:invalid_family_policy"]);
});

test("aggregate limits retain positive integer, paired quota/period and known-period boundary validation", () => {
  const cases: [unknown, string][] = [
    [{ ...tokenLimits(), person: { tokensPerMinute: 0, tokenQuota: null, tokenQuotaPeriod: null } }, "person.tokensPerMinute:invalid"],
    [{ ...tokenLimits(), person: { tokensPerMinute: 2147483648, tokenQuota: null, tokenQuotaPeriod: null } }, "person.tokensPerMinute:invalid"],
    [{ ...tokenLimits(), person: { tokensPerMinute: 1.5, tokenQuota: null, tokenQuotaPeriod: null } }, "person.tokensPerMinute:invalid"],
    [{ ...tokenLimits(), person: { tokensPerMinute: null, tokenQuota: 5, tokenQuotaPeriod: null } }, "person:quota_period_mismatch"],
    [{ ...tokenLimits(), person: { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: "Daily" } }, "person:quota_period_mismatch"],
    [{ ...tokenLimits(), group: { tokensPerMinute: null, tokenQuota: 5, tokenQuotaPeriod: "daily" } }, "group.tokenQuotaPeriod:invalid"],
    [{ person: tokenLimits().person }, "group:missing"],
    [{ ...tokenLimits(), person: { tokensPerMinute: null, tokenQuota: null } }, "person.tokenQuotaPeriod:missing"],
    [{ ...tokenLimits(), extra: 1 }, ":unexpected_key"],
  ];
  for (const [limits, expected] of cases) {
    const doc = projectDoc("PILOT1");
    (doc.classifications as Record<string, Record<string, unknown>>).STD.familyPolicy = { ...familyPolicy(), aggregateLimits: limits };
    assert.deepEqual(problemsOf(doc), ["classifications.STD.familyPolicy:invalid_family_policy"], expected);
  }
});

test("an unexpected key is reported without its name, so free text from a document never reaches the log", () => {
  const doc = projectDoc("PILOT1");
  (doc.classifications as Record<string, Record<string, unknown>>).STD.familyPolicy = { ...familyPolicy(), aggregateLimits: { ...tokenLimits(), "someone-at-example.com": 1 } };
  const person = { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null, "free text": 1 };
  (doc.classifications as Record<string, Record<string, unknown>>).PRM.familyPolicy = { ...familyPolicy(), aggregateLimits: { ...tokenLimits(), person } };
  const problems = problemsOf(doc);
  assert.deepEqual(problems, ["classifications.PRM.familyPolicy:invalid_family_policy", "classifications.STD.familyPolicy:invalid_family_policy"]);
  assert.doesNotMatch(problems.join(" "), /example|free text/);
});

test("project-level fields are required and checked", () => {
  assert.deepEqual(problemsOf(projectDoc("PILOT1", { id: "OTHER" })), ["id:not_equal_to_projectId"]);
  assert.deepEqual(problemsOf(projectDoc("PILOT1", { status: "suspended" })), ["status:not_active"]);
  assert.deepEqual(problemsOf(projectDoc("PILOT1", { status: "retired" })), ["retiredAt:invalid"]);
  assert.deepEqual(problemsOf(projectDoc("PILOT1", { status: "retired", retiredAt: "yesterday" })), ["retiredAt:invalid"]);
  assert.deepEqual(problemsOf(projectDoc("PILOT1", { backendId: "" })), ["backendId:invalid"]);
  assert.deepEqual(problemsOf(projectDoc("PILOT1", { classifications: {} })), ["classifications:empty"]);
  assert.deepEqual(problemsOf(null), ["document:not_an_object"]);
});

test("an unreadable projectId is reported as null, so the caller cannot attribute the document to a project", () => {
  const result = readProjectDocument(projectDoc("PILOT1", { projectId: "has space" }));
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.equal(result.projectId, null);
    assert.ok(result.problems.includes("projectId:invalid"));
  }
});

test("one group registered for two classifications of a project is refused: every member would be a conflict", () => {
  const doc = projectDoc("PILOT1");
  (doc.classifications as Record<string, Record<string, unknown>>).PRM.groupId = GROUP_STD;
  assert.deepEqual(problemsOf(doc), ["classifications:group_reused"]);
});

test("classification fields are checked, and an invalid classification code is not echoed", () => {
  const cases: [string, unknown, string][] = [
    ["groupId", "not-a-guid", "classifications.STD.groupId:invalid"],
    ["familyPolicy", { ...familyPolicy(), families: { haiku: { ...familyPolicy().families.haiku, models: [] } } }, "classifications.STD.familyPolicy:invalid_family_policy"],
    ["familyPolicy", { ...familyPolicy(), families: { haiku: { ...familyPolicy().families.haiku, models: ["a", "a"] } } }, "classifications.STD.familyPolicy:invalid_family_policy"],
    ["familyPolicy", { ...familyPolicy(), families: { haiku: { ...familyPolicy().families.haiku, models: ["bad model"] } } }, "classifications.STD.familyPolicy:invalid_family_policy"],
    ["aggregateMode", "maybe", "classifications.STD.aggregateMode:invalid"],
  ];
  for (const [field, value, expected] of cases) {
    const doc = projectDoc("PILOT1");
    (doc.classifications as Record<string, Record<string, unknown>>).STD[field] = value;
    assert.deepEqual(problemsOf(doc), [expected], field);
  }
  const badCode = projectDoc("PILOT1");
  (badCode.classifications as Record<string, unknown>)["bad code!"] = {};
  assert.deepEqual(problemsOf(badCode), ["classifications:invalid_code"]);
});

test("a retired project with retiredAt is a valid document marked retired, and keeps its classifications", () => {
  const result = readProjectDocument(projectDoc("PILOT1", { status: "retired", retiredAt: "2026-10-22T10:00:00.000Z" }));
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.retired, true);
    assert.ok(result.classifications.length > 0, "classifications are still parsed, so a snapshot of the old groups stays valid");
  }
  const active = readProjectDocument(projectDoc("PILOT1"));
  assert.equal(active.ok && active.retired, false);
});