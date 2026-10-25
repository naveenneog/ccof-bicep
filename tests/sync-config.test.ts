// Configuration for the sync (src/sync/config.ts). Every environment value and
// every limit comes from settings an administrator chose; nothing has a
// default, and a missing or invalid value refuses the run before any Azure call.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readGraphSettings, readHostSettings, readSnapshotLimits, readSyncConfig, SETTING_NAMES } from "../src/sync/config.ts";

const complete: Record<string, string> = {
  SYNC_TENANT_ID: "00000000-0000-4000-8000-000000000111",
  COSMOS_ENDPOINT: "https://sample-pilot-cosmos.documents.azure.com:443/",
  COSMOS_DATABASE: "ccof",
  SYNC_PROJECTS_CONTAINER: "projects",
  SYNC_ENTITLEMENT_CONTAINER: "entitlement",
  SYNC_LEASE_CONTAINER: "syncLease",
  SYNC_LEASE_SECONDS: "300",
  SYNC_MEMBER_TYPES: "user",
  SYNC_MAX_REMOVALS_PER_RUN: "5",
  SYNC_MAX_REMOVAL_FRACTION: "0.1",
  SYNC_GRAPH_MAX_RETRIES: "3",
  SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS: "30",
  SYNC_GRAPH_TIMEOUT_SECONDS: "30",
  SYNC_WRITE_MODE: "apply",
};

function problemsOf(settings: Record<string, string | undefined>): string[] {
  const result = readSyncConfig(settings);
  if (result.ok) assert.fail("expected the configuration to be refused");
  return result.problems.map((p) => `${p.setting}:${p.problem}`);
}

test("a complete configuration is read into typed values", () => {
  const result = readSyncConfig(complete);
  if (!result.ok) assert.fail(JSON.stringify(result.problems));
  assert.deepEqual(result.config, {
    tenantId: "00000000-0000-4000-8000-000000000111",
    cosmosEndpoint: "https://sample-pilot-cosmos.documents.azure.com:443/",
    cosmosDatabase: "ccof",
    projectsContainer: "projects",
    entitlementContainer: "entitlement",
    leaseContainer: "syncLease",
    leaseSeconds: 300,
    memberTypes: ["user"],
    maxRemovalsPerRun: 5,
    maxRemovalFraction: 0.1,
    graphMaxRetries: 3,
    graphMaxRetryAfterSeconds: 30,
    graphTimeoutSeconds: 30,
    writeMode: "apply",
    limitsContainer: null,
  });
});

test("SYNC_LIMITS_CONTAINER is optional: when set it names the admin override container, and is checked", () => {
  const set = readSyncConfig({ ...complete, SYNC_LIMITS_CONTAINER: "adminConfig" });
  assert.equal(set.ok && set.config.limitsContainer, "adminConfig");
  const bad = readSyncConfig({ ...complete, SYNC_LIMITS_CONTAINER: "has space" });
  assert.equal(bad.ok, false);
  if (!bad.ok) assert.deepEqual(bad.problems, [{ setting: "SYNC_LIMITS_CONTAINER", problem: "invalid" }]);
  const clash = readSyncConfig({ ...complete, SYNC_LIMITS_CONTAINER: complete.SYNC_ENTITLEMENT_CONTAINER });
  assert.equal(clash.ok, false);
});

test("no setting has a default: each one missing is named, and an empty settings object names them all", () => {
  for (const name of SETTING_NAMES) {
    const settings = { ...complete };
    delete settings[name];
    assert.deepEqual(problemsOf(settings), [`${name}:missing`], name);
    assert.deepEqual(problemsOf({ ...complete, [name]: "  " }), [`${name}:missing`], `${name} blank`);
  }
  assert.equal(problemsOf({}).length, SETTING_NAMES.length);
});

test("malformed values are refused with the setting named, never coerced", () => {
  const cases: [string, string][] = [
    ["SYNC_TENANT_ID", "not-a-guid"],
    ["COSMOS_ENDPOINT", "http://sample-pilot-cosmos.documents.azure.com/"],
    ["COSMOS_ENDPOINT", "https://evil.example/"],
    ["COSMOS_ENDPOINT", "https://sample-pilot-cosmos.documents.azure.com.evil.example/"],
    ["COSMOS_DATABASE", "bad/name"],
    ["SYNC_LEASE_SECONDS", "300.5"],
    ["SYNC_LEASE_SECONDS", "-300"],
    ["SYNC_LEASE_SECONDS", "0"],
    ["SYNC_MEMBER_TYPES", "group"],
    ["SYNC_MEMBER_TYPES", "user,user"],
    ["SYNC_MEMBER_TYPES", ""],
    ["SYNC_MAX_REMOVALS_PER_RUN", "five"],
    ["SYNC_MAX_REMOVALS_PER_RUN", "1e3"],
    ["SYNC_MAX_REMOVAL_FRACTION", "1.5"],
    ["SYNC_MAX_REMOVAL_FRACTION", "-0.1"],
    ["SYNC_MAX_REMOVAL_FRACTION", "10%"],
    ["SYNC_GRAPH_MAX_RETRIES", "11"],
    ["SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS", "0"],
    ["SYNC_GRAPH_TIMEOUT_SECONDS", "301"],
    ["SYNC_WRITE_MODE", "APPLY"],
  ];
  for (const [name, value] of cases) {
    const problems = problemsOf({ ...complete, [name]: value });
    assert.ok(
      problems.some((p) => p.startsWith(`${name}:`)),
      `${name}=${JSON.stringify(value)} gave ${JSON.stringify(problems)}`,
    );
  }
});

test("the three containers must be distinct, so the sync can never write projects or its lease as entitlement", () => {
  assert.deepEqual(problemsOf({ ...complete, SYNC_ENTITLEMENT_CONTAINER: "projects" }), [
    "SYNC_ENTITLEMENT_CONTAINER:same_as_other_container",
  ]);
  assert.deepEqual(problemsOf({ ...complete, SYNC_LEASE_CONTAINER: "entitlement" }), [
    "SYNC_LEASE_CONTAINER:same_as_other_container",
  ]);
});

test("the lease must outlast the longest single Graph wait, so a slow page cannot let a second run in", () => {
  // 2 x (retry-after bound + request timeout) = 2 x (30 + 30) = 120 seconds.
  assert.deepEqual(problemsOf({ ...complete, SYNC_LEASE_SECONDS: "119" }), ["SYNC_LEASE_SECONDS:shorter_than_graph_wait"]);
  const ok = readSyncConfig({ ...complete, SYNC_LEASE_SECONDS: "120" });
  assert.equal(ok.ok, true);
});

test("service principals are admitted only when listed, and the list is normalised", () => {
  const result = readSyncConfig({ ...complete, SYNC_MEMBER_TYPES: " servicePrincipal , user " });
  if (!result.ok) assert.fail(JSON.stringify(result.problems));
  assert.deepEqual(result.config.memberTypes, ["servicePrincipal", "user"]);
});

test("a removal fraction of 0 and 1 are both accepted as explicit choices", () => {
  for (const value of ["0", "1", "0.25", "1.0"]) {
    assert.equal(readSyncConfig({ ...complete, SYNC_MAX_REMOVAL_FRACTION: value }).ok, true, value);
  }
});

test("host settings: the managed identity is selected by client id and the schedule is a six-field NCRONTAB", () => {
  const ok = readHostSettings({
    SYNC_MANAGED_IDENTITY_CLIENT_ID: "00000000-0000-4000-8000-000000000100",
    SYNC_SCHEDULE: "0 */1 * * * *",
  });
  assert.deepEqual(ok, { ok: true, managedIdentityClientId: "00000000-0000-4000-8000-000000000100" });

  const bad = readHostSettings({ SYNC_MANAGED_IDENTITY_CLIENT_ID: "x", SYNC_SCHEDULE: "*/1 * * * *" });
  assert.equal(bad.ok, false);
  if (!bad.ok) {
    assert.deepEqual(bad.problems.map((p) => `${p.setting}:${p.problem}`), [
      "SYNC_MANAGED_IDENTITY_CLIENT_ID:invalid",
      "SYNC_SCHEDULE:invalid",
    ]);
  }
  const missing = readHostSettings({});
  assert.equal(missing.ok, false);
});

test("snapshot settings: the Graph subset only, every value required", () => {
  const graphOnly = { SYNC_TENANT_ID: complete.SYNC_TENANT_ID, SYNC_GRAPH_MAX_RETRIES: "3", SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS: "30", SYNC_GRAPH_TIMEOUT_SECONDS: "30" };
  assert.deepEqual(readGraphSettings(graphOnly), {
    ok: true,
    settings: { tenantId: complete.SYNC_TENANT_ID, graphMaxRetries: 3, graphMaxRetryAfterSeconds: 30, graphTimeoutSeconds: 30 },
  });
  for (const name of Object.keys(graphOnly)) {
    const settings: Record<string, string> = { ...graphOnly };
    delete settings[name];
    const result = readGraphSettings(settings);
    assert.equal(result.ok, false, name);
    if (!result.ok) assert.deepEqual(result.problems.map((p) => `${p.setting}:${p.problem}`), [`${name}:missing`]);
  }
});

test("apply-snapshot limits: age, bytes, groups and members, all required, no defaults", () => {
  const limits = { SYNC_SNAPSHOT_MAX_AGE_SECONDS: "3600", SYNC_SNAPSHOT_MAX_BYTES: "1048576", SYNC_SNAPSHOT_MAX_GROUPS: "100", SYNC_SNAPSHOT_MAX_MEMBERS: "100000" };
  assert.deepEqual(readSnapshotLimits(limits), { ok: true, limits: { maxAgeSeconds: 3600, maxBytes: 1048576, maxGroups: 100, maxMembers: 100000 } });
  for (const name of Object.keys(limits)) {
    const settings: Record<string, string> = { ...limits };
    delete settings[name];
    assert.equal(readSnapshotLimits(settings).ok, false, name);
    assert.equal(readSnapshotLimits({ ...limits, [name]: "0" }).ok, false, `${name}=0`);
  }
});
