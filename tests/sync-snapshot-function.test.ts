// The snapshot apply without a runner VM (src/sync/snapshot-function.ts): the sync Function App,
// already inside the VNet with the sync identity's Cosmos roles, applies a delegated snapshot that
// the workstation hands over as an app setting, through the same plan, lease and removal limits.
// Live run 2026-10-13: the owner's tenant allows no VM and Cosmos public access is disabled.

import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { buildSnapshot } from "../src/sync/snapshot.ts";
import { SNAPSHOT_FUNCTION_NAME, SNAPSHOT_SETTING, SNAPSHOT_SHA_SETTING, runSnapshotFunction } from "../src/sync/snapshot-function.ts";
import type { GroupReadResult } from "../src/sync/graph.ts";
import { GROUP_PRM, GROUP_STD, MemoryEntitlements, MemoryLeases, PERSON_A, PERSON_B, TENANT, projectDoc } from "./helpers/sync-fakes.ts";

const NOW = new Date("2026-10-11T13:00:00.000Z");

const SETTINGS: Record<string, string> = {
  SYNC_TENANT_ID: TENANT,
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
  SYNC_SNAPSHOT_MAX_AGE_SECONDS: "3600",
  SYNC_SNAPSHOT_MAX_BYTES: "100000",
  SYNC_SNAPSHOT_MAX_GROUPS: "10",
  SYNC_SNAPSHOT_MAX_MEMBERS: "1000",
};

function okRead(groupId: string, ...ids: string[]): GroupReadResult {
  return { ok: true, groupId, members: ids.map((id) => ({ id, kind: "user" as const })), pages: 1, retries: 0 };
}

const TEXT = JSON.stringify(buildSnapshot([okRead(GROUP_STD, PERSON_A), okRead(GROUP_PRM, PERSON_B)], TENANT, new Date("2026-10-11T12:30:00.000Z")));
const SHA = createHash("sha256").update(TEXT, "utf8").digest("hex");

function harness(env: Record<string, string | undefined>) {
  const entitlements = new MemoryEntitlements();
  const lines: string[] = [];
  let azureCalls = 0;
  const deps = {
    createDependencies: () => {
      azureCalls += 1;
      return {
        readProjects: async () => [projectDoc("PILOT1")],
        readEntitlements: () => entitlements.readAll(),
        entitlements,
        leases: new MemoryLeases(),
        readGroup: async () => assert.fail("a snapshot apply never reads Graph"),
      };
    },
    log: (line: string) => lines.push(line),
    now: () => NOW,
    newRunId: () => "run-f",
  };
  return { run: () => runSnapshotFunction(env, deps), entitlements, lines, calls: () => azureCalls };
}

const withSnapshot = (overrides: Record<string, string | undefined> = {}): Record<string, string | undefined> => ({
  ...SETTINGS,
  [SNAPSHOT_SETTING]: Buffer.from(TEXT, "utf8").toString("base64"),
  [SNAPSHOT_SHA_SETTING]: SHA,
  ...overrides,
});

test("the function is named without a hyphen, so the host can disable it on Linux", () => {
  assert.equal(SNAPSHOT_FUNCTION_NAME, "snapshotApply");
  assert.equal(SNAPSHOT_SETTING, "CCOF_SYNC_SNAPSHOT");
  assert.equal(SNAPSHOT_SHA_SETTING, "CCOF_SYNC_SNAPSHOT_SHA256");
});

test("a snapshot set as base64 with its SHA-256 is applied through the same plan and reported as a snapshot run", async () => {
  const h = harness(withSnapshot());
  const summary = await h.run();
  assert.equal(summary.outcome, "succeeded");
  assert.deepEqual([...h.entitlements.docs.keys()].sort(), [PERSON_A, PERSON_B]);
  const line = JSON.parse(h.lines.at(-1) ?? "{}");
  assert.equal(line.schema, "ccof.sync.run.v1");
  assert.equal(line.source, "snapshot");
  assert.equal(line.snapshotSha256, SHA);
  assert.equal(line.trigger, "timer");
});

test("a SHA-256 that differs from the snapshot's is refused before any Azure call", async () => {
  const h = harness(withSnapshot({ [SNAPSHOT_SHA_SETTING]: "0".repeat(64) }));
  const summary = await h.run();
  assert.equal(summary.outcome, "failed");
  assert.deepEqual(summary.reasons, ["snapshot_hash_mismatch"]);
  assert.equal(h.calls(), 0);
  assert.equal(h.entitlements.writes.length, 0);
});

test("a missing or malformed SHA-256 setting is refused before any Azure call", async () => {
  for (const sha of [undefined, "", "abc", "z".repeat(64)]) {
    const h = harness(withSnapshot({ [SNAPSHOT_SHA_SETTING]: sha }));
    const summary = await h.run();
    assert.equal(summary.outcome, "failed", String(sha));
    assert.deepEqual(summary.reasons, ["snapshot_hash_missing"], String(sha));
    assert.equal(h.calls(), 0);
  }
});

test("an invalid snapshot (another tenant) is refused before any Azure call", async () => {
  const h = harness(withSnapshot({ SYNC_TENANT_ID: "99999999-9999-4999-8999-999999999999" }));
  const summary = await h.run();
  assert.equal(summary.outcome, "failed");
  assert.deepEqual(summary.reasons, ["snapshot_invalid"]);
  assert.equal(h.calls(), 0);
});

test("missing snapshot limits are a configuration failure, with no Azure call", async () => {
  const env = withSnapshot();
  delete env.SYNC_SNAPSHOT_MAX_BYTES;
  const h = harness(env);
  const summary = await h.run();
  assert.equal(summary.outcome, "failed");
  assert.equal(h.calls(), 0);
  assert.match(h.lines.join("\n"), /SYNC_SNAPSHOT_MAX_BYTES/);
});

test("function-app.ts registers snapshotApply in the sync role block, only while the snapshot setting is set", () => {
  const source = readFileSync(new URL("../src/sync/function-app.ts", import.meta.url), "utf8");
  const start = source.indexOf('if (process.env.CCOF_APP_ROLE === "sync") {');
  assert.ok(start >= 0, "the sync role block");
  assert.match(
    source.slice(start),
    /if \(process\.env\[SNAPSHOT_SETTING\]\?\.trim\(\)\) \{\s*app\.timer\(SNAPSHOT_FUNCTION_NAME, \{ schedule: SNAPSHOT_SCHEDULE, runOnStartup: false, handler: snapshotApplyTimer \}\);/,
  );
});

test("the current snapshot operation correlates success and all early refusals", async () => {
  for (const overrides of [{}, { [SNAPSHOT_SHA_SETTING]: "" }, { SYNC_SNAPSHOT_MAX_BYTES: undefined }]) {
    const h = harness(withSnapshot({ CCOF_SYNC_SNAPSHOT_OPERATION_ID: "current-operation", ...overrides }));
    await h.run();
    const line = JSON.parse(h.lines.at(-1) ?? "{}");
    assert.equal(line.snapshotOperationId, "current-operation");
  }
  const source = readFileSync(new URL("../src/sync/function-app.ts", import.meta.url), "utf8");
  assert.match(source, /snapshotOperationLog\(process\.env,/);
});
