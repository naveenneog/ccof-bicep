// The registry the reconciler reads (docs/PILOT.md C-4, C-5): `projects`
// budgets per classification and the active memberships in `entitlement`.
// Problems name ids, fields and codes only.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readRegistry } from "../src/reconciler/registry.ts";
import { PERSON_A, PERSON_B, PERSON_C, entitlementDoc, pilotProject } from "./helpers/reconciler-fixtures.ts";

test("a pilot project registers one scope per classification, with budgets in CCU and the aggregate mode", () => {
  const registry = readRegistry([pilotProject()], []);
  assert.deepEqual(registry.problems, []);
  assert.deepEqual([...registry.scopes.keys()].sort(), ["CCOFPILOT01:CYB", "CCOFPILOT01:PRM", "CCOFPILOT01:STD"]);
  const std = registry.scopes.get("CCOFPILOT01:STD");
  assert.equal(std?.personBudgetCcu.toString(), "25000");
  assert.equal(std?.aggregateBudgetCcu?.toString(), "2000000");
  assert.equal(std?.aggregateMode, "strict");
  assert.deepEqual(std?.modelAllowList, ["claude-haiku-4-5", "claude-sonnet-5"]);
  const cyb = registry.scopes.get("CCOFPILOT01:CYB");
  assert.equal(cyb?.aggregateBudgetCcu, null);
  assert.equal(cyb?.aggregateMode, "notify");
});

test("a budget set in USD is converted to CCU at 100 CCU per USD, exactly", () => {
  const project = pilotProject();
  const classifications = project.classifications as Record<string, Record<string, unknown>>;
  classifications.STD.personBudget = { amount: "250.01", currency: "USD", period: "monthly" };
  const registry = readRegistry([project], []);
  assert.equal(registry.scopes.get("CCOFPILOT01:STD")?.personBudgetCcu.toString(), "25001");
});

test("a project that is not active registers nothing and is not a problem", () => {
  const registry = readRegistry([pilotProject({ status: "retired" })], []);
  assert.equal(registry.scopes.size, 0);
  assert.deepEqual(registry.problems, []);
});

test("an invalid classification is skipped with a named problem; its siblings stay registered", () => {
  const breakages: Array<[string, (c: Record<string, unknown>) => void, string]> = [
    ["personBudget", (c) => delete c.personBudget, "personBudget"],
    ["aggregateBudget absent is not 'no cap'", (c) => delete c.aggregateBudget, "aggregateBudget"],
    ["aggregateMode", (c) => (c.aggregateMode = "lenient"), "aggregateMode"],
    ["empty registered family models", (c) => {
      ((c.familyPolicy as { families: { haiku: { models: string[] } } }).families.haiku.models) = [];
    }, "familyPolicy"],
    ["budget period", (c) => (c.personBudget = { amount: 1, currency: "CCU", period: "weekly" }), "personBudget"],
    ["negative budget", (c) => (c.personBudget = { amount: -1, currency: "CCU", period: "monthly" }), "personBudget"],
  ];
  for (const [label, breakIt, field] of breakages) {
    const project = pilotProject();
    breakIt((project.classifications as Record<string, Record<string, unknown>>).PRM);
    const registry = readRegistry([project], []);
    assert.equal(registry.scopes.has("CCOFPILOT01:PRM"), false, label);
    assert.equal(registry.scopes.has("CCOFPILOT01:STD"), true, label);
    assert.deepEqual(registry.problems, [{ code: "classification_invalid", projectId: "CCOFPILOT01", classification: "PRM", field }], label);
  }
});

test("a malformed project document is one problem, and no value from it is echoed", () => {
  const registry = readRegistry([{ id: "x", projectId: "bad id with spaces", status: "active", displayName: "Secret Programme" }, "not-an-object"], []);
  assert.equal(registry.scopes.size, 0);
  assert.deepEqual(registry.problems, [{ code: "project_invalid" }, { code: "project_invalid" }]);
  assert.equal(JSON.stringify(registry.problems).includes("Secret"), false);
});

test("active memberships of registered scopes are members; inactive ones are not", () => {
  const registry = readRegistry(
    [pilotProject()],
    [
      entitlementDoc(PERSON_A, [{ projectId: "CCOFPILOT01", classification: "STD" }]),
      entitlementDoc(PERSON_B, [{ projectId: "CCOFPILOT01", classification: "PRM" }]),
      entitlementDoc(PERSON_C, [{ projectId: "CCOFPILOT01", classification: "STD", status: "removed" }]),
    ],
  );
  assert.deepEqual(registry.problems, []);
  assert.deepEqual(registry.members, [
    { personId: PERSON_A, projectId: "CCOFPILOT01", classification: "STD", scopeId: "CCOFPILOT01:STD" },
    { personId: PERSON_B, projectId: "CCOFPILOT01", classification: "PRM", scopeId: "CCOFPILOT01:PRM" },
  ]);
});

test("a person with no memberships left (removed from every group) is not a member", () => {
  const registry = readRegistry([pilotProject()], [entitlementDoc(PERSON_A, [])]);
  assert.deepEqual(registry.members, []);
  assert.deepEqual(registry.problems, []);
});

test("a membership of an unregistered scope is a problem, not a member", () => {
  const registry = readRegistry([pilotProject()], [entitlementDoc(PERSON_A, [{ projectId: "CCOFPILOT01", classification: "GOLD" }, { projectId: "OTHER", classification: "STD" }])]);
  assert.deepEqual(registry.members, []);
  assert.deepEqual(registry.problems, [
    { code: "membership_scope_not_registered", personId: PERSON_A, projectId: "CCOFPILOT01", classification: "GOLD" },
    { code: "membership_scope_not_registered", personId: PERSON_A, projectId: "OTHER", classification: "STD" },
  ]);
});

test("two active memberships of one person in one project are a conflict: neither counts", () => {
  const registry = readRegistry(
    [pilotProject()],
    [entitlementDoc(PERSON_A, [{ projectId: "CCOFPILOT01", classification: "STD" }, { projectId: "CCOFPILOT01", classification: "PRM" }])],
  );
  assert.deepEqual(registry.members, []);
  assert.deepEqual(registry.problems, [{ code: "duplicate_membership", personId: PERSON_A, projectId: "CCOFPILOT01" }]);
});

test("a malformed entitlement document is a problem that echoes no invalid value", () => {
  const registry = readRegistry([pilotProject()], [
    { id: "x", personId: "alice-at-example.com", projectMemberships: [] },
    { id: PERSON_A, personId: PERSON_A, projectMemberships: "nope" },
    { id: PERSON_B, personId: PERSON_B, projectMemberships: [{ projectId: "CCOFPILOT01", classification: "STD; drop", status: "active" }] },
  ]);
  assert.deepEqual(registry.members, []);
  assert.deepEqual(registry.problems, [
    { code: "entitlement_invalid" },
    { code: "entitlement_invalid", personId: PERSON_A },
    { code: "entitlement_invalid", personId: PERSON_B },
  ]);
  assert.equal(JSON.stringify(registry.problems).includes("alice"), false);
});
