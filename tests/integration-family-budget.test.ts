import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { readRegistry } from "../src/reconciler/registry.ts";
import type { FamilyPolicy } from "../src/contracts/model-families.ts";
import { STD_FAMILY_POLICY } from "./helpers/resolver-fixtures.ts";
import { pilotProject } from "./helpers/reconciler-fixtures.ts";

function projectWithPolicy() {
  const project = pilotProject();
  const std = (project.classifications as Record<string, Record<string, unknown>>).STD;
  delete std.modelAllowList;
  delete std.tokenLimits;
  std.familyPolicy = structuredClone(STD_FAMILY_POLICY);
  return { project, std };
}

test("family project policies retain registered exact models and original CCU budget inputs", () => {
  const { project } = projectWithPolicy();
  const registry = readRegistry([project], []);
  const std = registry.scopes.get("CCOFPILOT01:STD");
  assert.ok(std, JSON.stringify(registry.problems));
  assert.deepEqual(std.modelAllowList, Object.values(STD_FAMILY_POLICY.families).flatMap((family) => family!.models));
  assert.equal(std.personBudgetCcu.toString(), "25000");
  assert.equal(std.aggregateBudgetCcu?.toString(), "2000000");
});

test("family budget registry refuses missing, mixed, malformed and restricted policy without poisoning sibling scopes", () => {
  for (const mutate of [
    (std: Record<string, unknown>) => { delete std.familyPolicy; },
    (std: Record<string, unknown>) => { std.modelAllowList = ["claude-haiku-4-5"]; },
    (std: Record<string, unknown>) => { std.tokenLimits = {}; },
    (std: Record<string, unknown>) => { std.familyPolicy = {}; },
    (std: Record<string, unknown>) => {
      const policy = std.familyPolicy as FamilyPolicy;
      policy.families.fable = { ...structuredClone(policy.families.haiku!), models: ["approved-restricted-alias"] };
    },
  ]) {
    const { project, std } = projectWithPolicy();
    mutate(std);
    const registry = readRegistry([project], []);
    assert.equal(registry.scopes.has("CCOFPILOT01:STD"), false);
    assert.equal(registry.scopes.has("CCOFPILOT01:PRM"), true);
    assert.equal(registry.problems.find((problem) => problem.classification === "STD")?.field, "familyPolicy");
  }
});

test("both opt-in live resolver seed fixtures supply the mandatory boolean exhausted field", () => {
  for (const name of ["resolver-cosmos-integration.test.ts", "resolver-cross-project-integration.test.ts"]) {
    const source = readFileSync(new URL(name, import.meta.url), "utf8");
    const match = source.match(/container\("budgetState"\)\.items\.upsert\(([\s\S]*?)\);/);
    assert.ok(match, `${name} must seed the budget state`);
    const state = runInNewContext(`(${match[1]})`, {
      budgetId: "synthetic-budget", budgetIdA: "synthetic-budget-a",
      personId: "synthetic-person", projectId: "synthetic-project", projectA: "synthetic-project-a",
    });
    assert.equal(state.exhausted, false, `${name} must represent a non-exhausted budget explicitly`);
  }
});
