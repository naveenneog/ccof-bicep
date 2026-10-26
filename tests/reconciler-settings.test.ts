// Reconciler settings (ADR-0018 decision 9): every interval, validity, timeout
// and limit is an app setting without a default; a missing or invalid one is
// named, with a problem code and never its value.

import { test } from "node:test";
import assert from "node:assert/strict";
import { SETTING_NAMES, readReconcilerSettings } from "../src/reconciler/settings.ts";
import { validSettings } from "./helpers/reconciler-fixtures.ts";

test("a complete, valid set of settings is read with every value typed", () => {
  const result = readReconcilerSettings(validSettings());
  assert.equal(result.ok, true);
  if (!result.ok) return;
  assert.deepEqual(result.settings, {
    managedIdentityClientId: "00000000-0000-4000-8000-000000000100",
    intervalMinutes: 2,
    validitySeconds: 600,
    leaseSeconds: 300,
    workspaceId: "00000000-0000-4000-8000-000001100000",
    logAnalyticsEndpoint: "https://api.loganalytics.io",
    gatewayResourceIds: ["/subscriptions/00000000-0000-4000-8000-000000000110/resourceGroups/sample-pilot-rg/providers/Microsoft.ApiManagement/service/sample-pilot-apim"],
    ledgerTimeoutSeconds: 60,
    ledgerMaxRows: 100000,
    maxStates: 10000,
    writeConcurrency: 8,
    cosmosEndpoint: "https://sample-pilot-cosmos.documents.azure.com:443/",
    cosmosDatabase: "ccof",
    pacing: null,
    continuity: null,
    containers: {
      projects: "projects",
      entitlement: "entitlement",
      budgetState: "budgetState",
      aggregateState: "aggregateBudgetState",
      lease: "reconcilerLease",
    },
  });
});

test("every setting is required: removing any one names exactly that setting as missing", () => {
  for (const name of SETTING_NAMES) {
    const settings = validSettings();
    delete settings[name];
    const result = readReconcilerSettings(settings);
    assert.equal(result.ok, false, name);
    if (result.ok) continue;
    assert.deepEqual(result.problems, [{ setting: name, problem: "missing" }], name);
  }
});

test("a blank value is missing, not a default", () => {
  const result = readReconcilerSettings(validSettings({ RECONCILER_VALIDITY_SECONDS: "   " }));
  assert.equal(result.ok, false);
  if (!result.ok) assert.deepEqual(result.problems, [{ setting: "RECONCILER_VALIDITY_SECONDS", problem: "missing" }]);
});

test("spend pacing is read only as a pair; neither means no pacing, one alone names the other as missing", () => {
  const both = readReconcilerSettings(validSettings({ RECONCILER_SOFT_LIMIT_PERCENT: "80", RECONCILER_PACING_WINDOW_MINUTES: "10" }));
  assert.equal(both.ok && JSON.stringify(both.settings.pacing), JSON.stringify({ softLimitPercent: 80, windowMinutes: 10 }));
  const neither = readReconcilerSettings(validSettings());
  assert.equal(neither.ok && neither.settings.pacing, null);
  for (const [present, absent] of [
    ["RECONCILER_SOFT_LIMIT_PERCENT", "RECONCILER_PACING_WINDOW_MINUTES"],
    ["RECONCILER_PACING_WINDOW_MINUTES", "RECONCILER_SOFT_LIMIT_PERCENT"],
  ]) {
    const result = readReconcilerSettings(validSettings({ [present]: "10" }));
    assert.equal(result.ok, false, present);
    if (!result.ok) assert.deepEqual(result.problems, [{ setting: absent, problem: "missing" }]);
  }
});

test("the soft limit is 1-99 percent and the pacing window 1-120 minutes, whole numbers only", () => {
  const pair = (percent: string, minutes: string) =>
    readReconcilerSettings(validSettings({ RECONCILER_SOFT_LIMIT_PERCENT: percent, RECONCILER_PACING_WINDOW_MINUTES: minutes }));
  for (const [percent, minutes, setting, problem] of [
    ["0", "10", "RECONCILER_SOFT_LIMIT_PERCENT", "out_of_range"],
    ["100", "10", "RECONCILER_SOFT_LIMIT_PERCENT", "out_of_range"],
    ["80.5", "10", "RECONCILER_SOFT_LIMIT_PERCENT", "invalid"],
    ["80", "0", "RECONCILER_PACING_WINDOW_MINUTES", "out_of_range"],
    ["80", "121", "RECONCILER_PACING_WINDOW_MINUTES", "out_of_range"],
    ["80", "-5", "RECONCILER_PACING_WINDOW_MINUTES", "invalid"],
  ]) {
    const result = pair(percent, minutes);
    assert.equal(result.ok, false, `${percent}/${minutes}`);
    if (!result.ok) assert.deepEqual(result.problems, [{ setting, problem }]);
  }
  for (const [percent, minutes] of [["1", "2"], ["99", "120"]]) assert.equal(pair(percent, minutes).ok, true, `${percent}/${minutes}`);
  const shorter = pair("80", "1");
  assert.equal(shorter.ok, false, "a window shorter than the reconciler interval cannot bound the spend between runs");
  if (!shorter.ok) assert.deepEqual(shorter.problems, [{ setting: "RECONCILER_PACING_WINDOW_MINUTES", problem: "shorter_than_interval" }]);
});

test("the schedule must be an every-N-minutes NCRONTAB, N from 1 to 59", () => {
  for (const schedule of ["0 */2 * * *", "*/2 * * * * *", "0 */0 * * * *", "0 */60 * * * *", "0 2 * * * *", "0 */2 * * * * *", "00:02:00"]) {
    const result = readReconcilerSettings(validSettings({ RECONCILER_SCHEDULE: schedule }));
    assert.equal(result.ok, false, schedule);
    if (!result.ok) assert.deepEqual(result.problems, [{ setting: "RECONCILER_SCHEDULE", problem: "invalid" }], schedule);
  }
  for (const [schedule, minutes] of [["0 */1 * * * *", 1], ["0 */59 * * * *", 59]] as const) {
    const result = readReconcilerSettings(validSettings({ RECONCILER_SCHEDULE: schedule, RECONCILER_VALIDITY_SECONDS: "7200" }));
    assert.equal(result.ok && result.settings.intervalMinutes, minutes, schedule);
  }
});

test("validity must exceed the interval plus the ledger timeout, so state cannot lapse between healthy runs", () => {
  // interval 2 min = 120 s, ledger timeout 60 s: 180 is not enough, 181 is.
  const atBound = readReconcilerSettings(validSettings({ RECONCILER_VALIDITY_SECONDS: "180" }));
  assert.equal(atBound.ok, false);
  if (!atBound.ok) assert.deepEqual(atBound.problems, [{ setting: "RECONCILER_VALIDITY_SECONDS", problem: "not_above_interval_plus_ledger_timeout" }]);
  assert.equal(readReconcilerSettings(validSettings({ RECONCILER_VALIDITY_SECONDS: "181" })).ok, true);
});

test("the lease must last at least twice the ledger timeout, so one slow query cannot lose it mid-run", () => {
  const short = readReconcilerSettings(validSettings({ RECONCILER_LEASE_SECONDS: "119" }));
  assert.equal(short.ok, false);
  if (!short.ok) assert.deepEqual(short.problems, [{ setting: "RECONCILER_LEASE_SECONDS", problem: "shorter_than_twice_ledger_timeout" }]);
  assert.equal(readReconcilerSettings(validSettings({ RECONCILER_LEASE_SECONDS: "120" })).ok, true);
});

test("numbers outside their documented or sanity range are refused, as are non-integers", () => {
  const cases: Array<[string, string, string]> = [
    ["RECONCILER_LEDGER_TIMEOUT_SECONDS", "601", "out_of_range"],
    ["RECONCILER_LEDGER_TIMEOUT_SECONDS", "0", "out_of_range"],
    ["RECONCILER_LEDGER_MAX_ROWS", "500001", "out_of_range"],
    ["RECONCILER_LEDGER_MAX_ROWS", "0", "out_of_range"],
    ["RECONCILER_MAX_STATES", "0", "out_of_range"],
    ["RECONCILER_WRITE_CONCURRENCY", "33", "out_of_range"],
    ["RECONCILER_WRITE_CONCURRENCY", "0", "out_of_range"],
    ["RECONCILER_VALIDITY_SECONDS", "86401", "out_of_range"],
    ["RECONCILER_VALIDITY_SECONDS", "600.5", "invalid"],
    ["RECONCILER_VALIDITY_SECONDS", "-600", "invalid"],
    ["RECONCILER_LEASE_SECONDS", "1e3", "invalid"],
  ];
  for (const [name, value, problem] of cases) {
    const result = readReconcilerSettings(validSettings({ [name]: value }));
    assert.equal(result.ok, false, `${name}=${value}`);
    if (!result.ok) assert.ok(result.problems.some((p) => p.setting === name && p.problem === problem), `${name}=${value}: ${JSON.stringify(result.problems)}`);
  }
});

test("identifiers are validated: GUIDs, the APIM resource id, the Cosmos endpoint and names", () => {
  const cases: Array<[string, string]> = [
    ["RECONCILER_MANAGED_IDENTITY_CLIENT_ID", "not-a-guid"],
    ["RECONCILER_LOG_ANALYTICS_WORKSPACE_ID", "sample-pilot-law"],
    ["RECONCILER_LOG_ANALYTICS_ENDPOINT", "http://api.loganalytics.io"],
    ["RECONCILER_LOG_ANALYTICS_ENDPOINT", "https://api.loganalytics.io/v1/workspaces"],
    ["RECONCILER_LOG_ANALYTICS_ENDPOINT", "https://user:@api.loganalytics.io"],
    ["RECONCILER_LEDGER_GATEWAY_RESOURCE_ID", "/subscriptions/00000000-0000-4000-8000-000000000110/resourceGroups/sample-pilot-rg/providers/Microsoft.Web/sites/x"],
    ["RECONCILER_LEDGER_GATEWAY_RESOURCE_ID", "/subscriptions/00000000-0000-4000-8000-000000000110/resourceGroups/rg'|take 1/providers/Microsoft.ApiManagement/service/apim"],
    ["COSMOS_ENDPOINT", "http://sample-pilot-cosmos.documents.azure.com/"],
    ["COSMOS_ENDPOINT", "https://evil.example.com/"],
    ["COSMOS_DATABASE", "-bad"],
    ["RECONCILER_LEASE_CONTAINER", "has space"],
  ];
  for (const [name, value] of cases) {
    const result = readReconcilerSettings(validSettings({ [name]: value }));
    assert.equal(result.ok, false, `${name}=${value}`);
    if (!result.ok) assert.deepEqual(result.problems, [{ setting: name, problem: "invalid" }], `${name}=${value}`);
  }
});

const APIM_A = "/subscriptions/00000000-0000-4000-8000-000000000110/resourceGroups/sample-pilot-rg/providers/Microsoft.ApiManagement/service/sample-pilot-apim";
const APIM_B = "/subscriptions/00000000-0000-4000-8000-000000000110/resourceGroups/sample-dr-rg/providers/Microsoft.ApiManagement/service/sample-dr-apim";
const LIST = "RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS";

function withList(list: string, single?: string) {
  const settings = validSettings({ [LIST]: list });
  if (single === undefined) delete settings.RECONCILER_LEDGER_GATEWAY_RESOURCE_ID;
  else settings.RECONCILER_LEDGER_GATEWAY_RESOURCE_ID = single;
  return readReconcilerSettings(settings);
}

test("DR: a gateway id list alone is read in order, trimmed; the single setting is then optional", () => {
  const result = withList(` ${APIM_A} , ${APIM_B} `);
  assert.equal(result.ok, true, JSON.stringify(result));
  if (result.ok) assert.deepEqual(result.settings.gatewayResourceIds, [APIM_A, APIM_B]);
});

test("DR: with both settings the single id must be in the list (case-insensitively), else a named refusal", () => {
  const agree = withList(`${APIM_A},${APIM_B}`, APIM_B.replace("sample-dr-apim", "SAMPLE-DR-APIM"));
  assert.equal(agree.ok, true, JSON.stringify(agree));
  if (agree.ok) assert.deepEqual(agree.settings.gatewayResourceIds, [APIM_A, APIM_B]);
  const disagree = withList(APIM_B, APIM_A);
  assert.equal(disagree.ok, false);
  if (!disagree.ok) assert.deepEqual(disagree.problems, [{ setting: LIST, problem: "single_not_in_list" }]);
});

test("DR: each listed gateway id passes the APIM pattern; at most 4, no duplicates, no empty entries", () => {
  const ids = (n: number) => Array.from({ length: n }, (_, i) => `${APIM_A}${i}`).join(",");
  const cases: Array<[string, string]> = [
    [`${APIM_A},/subscriptions/00000000-0000-4000-8000-000000000110/resourceGroups/rg/providers/Microsoft.Web/sites/x`, "invalid"],
    [`${APIM_A},/subscriptions/00000000-0000-4000-8000-000000000110/resourceGroups/rg'|take 1/providers/Microsoft.ApiManagement/service/apim`, "invalid"],
    [`${APIM_A},,${APIM_B}`, "invalid"],
    [`${APIM_A},`, "invalid"],
    [ids(5), "too_many"],
    [`${APIM_A},${APIM_A.replace("sample-pilot-apim", "SAMPLE-PILOT-APIM")}`, "duplicate"],
  ];
  for (const [list, problem] of cases) {
    const result = withList(list);
    assert.equal(result.ok, false, list);
    if (!result.ok) assert.deepEqual(result.problems, [{ setting: LIST, problem }], list);
  }
  const four = withList(ids(4));
  assert.equal(four.ok && four.settings.gatewayResourceIds.length, 4);
});

test("DR continuity gate requires a verified UTC coverage start when enabled", () => {
  const read = (overrides: Record<string, string>) => readReconcilerSettings(validSettings(overrides));
  const absent = read({});
  assert.equal(absent.ok && absent.settings.continuity, null);
  const off = read({ RECONCILER_CONTINUITY_GATE: "off" });
  assert.equal(off.ok && off.settings.continuity, null);
  const staged = read({ RECONCILER_CONTINUITY_GATE: "off", RECONCILER_LEDGER_COVERAGE_START_AT: "2026-10-01T00:00:00.000Z" });
  assert.equal(staged.ok && staged.settings.continuity, null, "a valid coverage time can be staged before turning the gate on");
  const missing = read({ RECONCILER_CONTINUITY_GATE: "on" });
  assert.equal(missing.ok, false);
  if (!missing.ok) assert.deepEqual(missing.problems, [{ setting: "RECONCILER_LEDGER_COVERAGE_START_AT", problem: "missing" }]);
  const on = read({ RECONCILER_CONTINUITY_GATE: "on", RECONCILER_LEDGER_COVERAGE_START_AT: "2026-10-01T00:00:00.000Z" });
  assert.deepEqual(on.ok && on.settings.continuity, { coverageStartAt: "2026-10-01T00:00:00.000Z" });
});

test("DR continuity gate: invalid coverage starts and gate values are refused", () => {
  const cases: Array<[Record<string, string>, string, string]> = [
    [{ RECONCILER_CONTINUITY_GATE: "ON" }, "RECONCILER_CONTINUITY_GATE", "invalid"],
    [{ RECONCILER_CONTINUITY_GATE: "true" }, "RECONCILER_CONTINUITY_GATE", "invalid"],
    [{ RECONCILER_CONTINUITY_GATE: "on", RECONCILER_LEDGER_COVERAGE_START_AT: "2026-10-01" }, "RECONCILER_LEDGER_COVERAGE_START_AT", "invalid"],
    [{ RECONCILER_CONTINUITY_GATE: "on", RECONCILER_LEDGER_COVERAGE_START_AT: "2026-10-01T00:00:00+00:00" }, "RECONCILER_LEDGER_COVERAGE_START_AT", "invalid"],
    [{ RECONCILER_CONTINUITY_GATE: "on", RECONCILER_LEDGER_COVERAGE_START_AT: "2026-02-30T00:00:00.000Z" }, "RECONCILER_LEDGER_COVERAGE_START_AT", "invalid"],
    [{ RECONCILER_CONTINUITY_GATE: "off", RECONCILER_LEDGER_COVERAGE_START_AT: "not-a-date" }, "RECONCILER_LEDGER_COVERAGE_START_AT", "invalid"],
  ];
  for (const [overrides, setting, problem] of cases) {
    const result = readReconcilerSettings(validSettings(overrides));
    assert.equal(result.ok, false, JSON.stringify(overrides));
    if (!result.ok) assert.deepEqual(result.problems, [{ setting, problem }], JSON.stringify(overrides));
  }
});

test("the reconciler never writes into a container it reads or another writer's container", () => {
  const writesProjects = readReconcilerSettings(validSettings({ RECONCILER_BUDGET_STATE_CONTAINER: "projects" }));
  assert.equal(writesProjects.ok, false);
  if (!writesProjects.ok) assert.deepEqual(writesProjects.problems, [{ setting: "RECONCILER_BUDGET_STATE_CONTAINER", problem: "same_as_other_container" }]);
  const leaseInState = readReconcilerSettings(validSettings({ RECONCILER_LEASE_CONTAINER: "aggregateBudgetState" }));
  assert.equal(leaseInState.ok, false);
  if (!leaseInState.ok) assert.deepEqual(leaseInState.problems, [{ setting: "RECONCILER_LEASE_CONTAINER", problem: "same_as_other_container" }]);
});

test("problems carry setting names and codes only, never the offending value", () => {
  const secretish = "Bearer abc.def.ghi";
  const result = readReconcilerSettings(validSettings({ RECONCILER_LOG_ANALYTICS_WORKSPACE_ID: secretish }));
  assert.equal(result.ok, false);
  assert.equal(JSON.stringify(result).includes(secretish), false);
});
