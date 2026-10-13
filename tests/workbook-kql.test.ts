import { strict as assert } from "node:assert";
import { test } from "node:test";

const helper = () => import("./helpers/workbook-kql.ts");

test("workbook executed-KQL fixtures cover prices, unknowns, periods, budgets and every rendered query", async () => {
  const { kqlChecks } = await helper();
  const checks = kqlChecks();
  for (const id of ["pricing", "pricing-real-card", "pricing-reasons", "health-counts", "retention", "rollups", "budget-snapshots",
    "budget-rate-card-version", "reconciler-runs", "time-boundaries", "retention-definition-health", "retention-definition-chargeback",
    "render-health", "render-usage", "render-model-mix", "render-top-users",
    "render-budgets", "render-reconciler-runs", "render-unpriced", "render-chargeback"]) {
    const check = checks.find(c => c.id === id);
    assert.ok(check, id);
    assert.equal(check.shouldPass, true);
    assert.ok(check.expectedTests.length > 0);
    assert.match(check.query, /datatable\(/);
    assert.doesNotMatch(check.query, /\{(?:TimeRange|Project|Period)[:}]/);
  }
  for (const check of checks.filter(c => !c.shouldPass)) {
    assert.ok(check.target);
    assert.ok(check.expectedTests.includes(check.target!));
    assert.equal(new Set(check.expectedTests).size, check.expectedTests.length);
  }
  assert.ok(checks.filter(c => !c.shouldPass).length >= 10);
  for (const baseline of ["pricing-real-card", "health-counts"]) {
    assert.ok(checks.some(c => !c.shouldPass && c.query !== checks.find(b => b.id === baseline)!.query
      && c.expectedTests.join() === checks.find(b => b.id === baseline)!.expectedTests.join()), `mutation for ${baseline}`);
  }
});

test("no-usage fixtures cover refusals before the backend, measured zeros and zero input with known cache", async () => {
  const { usageCases } = await import("./helpers/workbook-kql-data.ts");
  const byId = new Map(usageCases.map(c => [c.id, c]));
  assert.equal(byId.get("no-backend-call")?.source, "no-backend-call");
  assert.equal(byId.get("no-backend-call")?.status, "no_usage");
  assert.equal(byId.get("no-backend-call-with-tokens")?.status, "no_usage");
  assert.equal(byId.get("measured-zero")?.status, "no_usage");
  assert.equal(byId.get("zero-io-unknown-cache")?.status, "no_usage");
  assert.equal(byId.get("zero-io-with-cache")?.status, "priced");
});

test("KQL response verifier requires the complete named test set, boolean outcomes and no partial API error", async () => {
  const { verifyKqlResult } = await helper();
  const good = { tables: [{ name: "PrimaryResult", columns: [{ name: "test" }, { name: "passed" }], rows: [["one", true], ["two", true]] }] };
  const check = { id: "synthetic", expectedTests: ["one", "two"], shouldPass: true, query: "" };
  assert.deepEqual(verifyKqlResult(check, good), { tests: 2, passed: 2, failed: [] });
  const rejects: unknown[] = [
    {}, { tables: [] },
    { ...good, error: { code: "PartialError" } },
    { tables: [{ ...good.tables[0], rows: [] }] },
    { tables: [{ ...good.tables[0], rows: [["one", true]] }] },
    { tables: [{ ...good.tables[0], rows: [["one", true], ["one", true]] }] },
    { tables: [{ ...good.tables[0], rows: [["one", true], ["other", true]] }] },
    { tables: [{ ...good.tables[0], rows: [["one", true], ["two", "true"]] }] },
    { tables: [{ ...good.tables[0], rows: [["one", true], ["two", false]] }] },
  ];
  for (const result of rejects) assert.throws(() => verifyKqlResult(check, result), /kql_/);
});

test("a KQL mutation only counts when all tests execute and its intended assertion fails", async () => {
  const { verifyKqlResult } = await helper();
  const check = { id: "negative", expectedTests: ["one", "two"], shouldPass: false, target: "two", query: "" };
  const response = (rows: unknown[]) => ({ tables: [{ name: "PrimaryResult", columns: [{ name: "test" }, { name: "passed" }], rows }] });
  assert.deepEqual(verifyKqlResult(check, response([["one", true], ["two", false]])), { tests: 2, passed: 1, failed: ["two"] });
  assert.throws(() => verifyKqlResult(check, response([["one", true], ["two", true]])), /kql_mutation_survived/);
  assert.throws(() => verifyKqlResult(check, response([["one", false], ["two", true]])), /kql_wrong_mutation_failure/);
  assert.throws(() => verifyKqlResult(check, response([["two", false]])), /kql_test_count/);
});
