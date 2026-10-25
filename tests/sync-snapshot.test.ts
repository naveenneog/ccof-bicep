// The snapshot fallback (src/sync/snapshot.ts): read the groups on a
// workstation with a person's delegated Graph sign-in, apply inside the VNet
// with the same plan, lease and removal limits as the timer. Used where the
// Graph application permission cannot be granted (docs/PILOT.md, shape A).

import { test } from "node:test";
import assert from "node:assert/strict";
import { SNAPSHOT_SCHEMA, buildSnapshot, snapshotReader, takeSnapshot, validateSnapshot } from "../src/sync/snapshot.ts";
import type { SnapshotLimits } from "../src/sync/snapshot.ts";
import { runSync } from "../src/sync/run.ts";
import type { SyncConfig } from "../src/sync/config.ts";
import type { GroupReadResult } from "../src/sync/graph.ts";
import { GROUP_PRM, GROUP_STD, ManualClock, MemoryEntitlements, MemoryLeases, PERSON_A, PERSON_B, PERSON_C, TENANT, projectDoc, familyPolicy } from "./helpers/sync-fakes.ts";

const NOW = new Date("2026-10-11T13:00:00.000Z");
const LIMITS: SnapshotLimits = { maxAgeSeconds: 3600, maxBytes: 100_000, maxGroups: 10, maxMembers: 1000 };
const UNREGISTERED = "99999999-0000-4000-8000-000000000099";

function okRead(groupId: string, ...ids: string[]): GroupReadResult {
  return { ok: true, groupId, members: ids.map((id) => ({ id, kind: "user" as const })), pages: 1, retries: 0 };
}

function snapshotText(overrides: Record<string, unknown> = {}): string {
  const snap = buildSnapshot([okRead(GROUP_STD, PERSON_A), okRead(GROUP_PRM, PERSON_B)], TENANT, new Date("2026-10-11T12:30:00.000Z"));
  return JSON.stringify({ ...snap, ...overrides });
}

function problems(text: string, limits = LIMITS, tenantId = TENANT): string[] {
  const result = validateSnapshot(text, { tenantId, now: NOW, limits });
  if (result.ok) assert.fail("expected the snapshot to be refused");
  return result.problems;
}

test("a snapshot records the schema, tenant, read time and each group's member ids and types, ids only", () => {
  const snap = buildSnapshot([okRead(GROUP_STD, PERSON_A)], TENANT, NOW);
  assert.deepEqual(snap, {
    schema: SNAPSHOT_SCHEMA,
    tenantId: TENANT,
    readAt: "2026-10-11T13:00:00.000Z",
    groups: [{ groupId: GROUP_STD, members: [{ id: PERSON_A, type: "user" }] }],
  });
});

test("taking a snapshot fails as a whole when any group read fails: a partial snapshot never exists", async () => {
  const reads: Record<string, GroupReadResult> = {
    [GROUP_STD]: okRead(GROUP_STD, PERSON_A),
    [GROUP_PRM]: { ok: false, groupId: GROUP_PRM, reason: "graph_throttled", httpStatus: 429, graphErrorCode: null, retries: 3 },
  };
  const result = await takeSnapshot([GROUP_STD, GROUP_PRM], TENANT, async (id) => reads[id], () => NOW);
  assert.deepEqual(result, { ok: false, groupId: GROUP_PRM, reason: "graph_throttled" });

  const whole = await takeSnapshot([GROUP_PRM, GROUP_STD], TENANT, async (id) => okRead(id, PERSON_C), () => NOW);
  assert.equal(whole.ok, true);
  if (whole.ok) assert.deepEqual(whole.snapshot.groups.map((g) => g.groupId), [GROUP_STD, GROUP_PRM].sort());
});

test("taking a snapshot refuses duplicate or malformed group ids before any read", async () => {
  let reads = 0;
  const read = async (id: string) => {
    reads += 1;
    return okRead(id);
  };
  assert.equal((await takeSnapshot([GROUP_STD, GROUP_STD], TENANT, read, () => NOW)).ok, false);
  assert.equal((await takeSnapshot(["not-a-guid"], TENANT, read, () => NOW)).ok, false);
  assert.equal((await takeSnapshot([], TENANT, read, () => NOW)).ok, false);
  assert.equal(reads, 0);
});

test("a valid snapshot is accepted and identified by its SHA-256", () => {
  const result = validateSnapshot(snapshotText(), { tenantId: TENANT, now: NOW, limits: LIMITS });
  if (!result.ok) assert.fail(JSON.stringify(result.problems));
  assert.match(result.sha256, /^[0-9a-f]{64}$/);
  assert.deepEqual([...result.groups.keys()], [GROUP_STD, GROUP_PRM]);
});

test("a stale snapshot is refused, and so is one from the future", () => {
  assert.deepEqual(problems(snapshotText({ readAt: "2026-10-11T11:59:59.000Z" })), ["readAt:older_than_max_age"]);
  assert.deepEqual(problems(snapshotText({ readAt: "2026-10-11T13:00:01.000Z" })), ["readAt:in_future"]);
  assert.deepEqual(problems(snapshotText({ readAt: "2026-10-11T12:30:00" })), ["readAt:invalid"]);
});

test("a snapshot from another tenant is refused", () => {
  assert.deepEqual(problems(snapshotText({ tenantId: "00000000-0000-4000-8000-000000010001" })), ["tenantId:not_the_configured_tenant"]);
});

test("size limits: bytes are checked before parsing, then groups and members", () => {
  assert.deepEqual(problems(snapshotText(), { ...LIMITS, maxBytes: 50 }), ["snapshot:too_large"]);
  assert.deepEqual(problems(snapshotText(), { ...LIMITS, maxGroups: 1 }), ["groups:too_many"]);
  assert.deepEqual(problems(snapshotText(), { ...LIMITS, maxMembers: 1 }), ["members:too_many"]);
});

test("the schema is checked: wrong schema, duplicate groups or members, bad ids and unknown types are refused", () => {
  assert.deepEqual(problems("not json"), ["snapshot:not_json"]);
  assert.deepEqual(problems(snapshotText({ schema: "ccof.sync.snapshot.v2" })), ["schema:unsupported"]);
  const dupGroup = { groupId: GROUP_STD, members: [] };
  assert.deepEqual(problems(snapshotText({ groups: [dupGroup, dupGroup] })), ["groups:duplicate_group"]);
  assert.deepEqual(problems(snapshotText({ groups: [{ groupId: GROUP_STD, members: [{ id: PERSON_A, type: "user" }, { id: PERSON_A, type: "user" }] }] })), ["groups:duplicate_member"]);
  assert.deepEqual(problems(snapshotText({ groups: [{ groupId: "x", members: [] }] })), ["groups:invalid_group"]);
  assert.deepEqual(problems(snapshotText({ groups: [{ groupId: GROUP_STD, members: [{ id: PERSON_A, type: "person" }] }] })), ["groups:invalid_member"]);
  assert.deepEqual(problems(snapshotText({ extra: 1 })), ["snapshot:unexpected_key"]);
});

const CONFIG: SyncConfig = {
  tenantId: TENANT,
  cosmosEndpoint: "https://sample-pilot-cosmos.documents.azure.com:443/",
  cosmosDatabase: "ccof",
  projectsContainer: "projects",
  entitlementContainer: "entitlement",
  leaseContainer: "syncLease",
  limitsContainer: null,
  leaseSeconds: 300,
  memberTypes: ["user"],
  maxRemovalsPerRun: 0,
  maxRemovalFraction: 0,
  graphMaxRetries: 1,
  graphMaxRetryAfterSeconds: 5,
  graphTimeoutSeconds: 10,
  writeMode: "apply",
};

function applyHarness(snapshot: string, existing: Record<string, unknown>[] = []) {
  const validated = validateSnapshot(snapshot, { tenantId: TENANT, now: NOW, limits: LIMITS });
  if (!validated.ok) assert.fail(JSON.stringify(validated.problems));
  const entitlements = new MemoryEntitlements();
  for (const doc of existing) entitlements.seed(doc);
  const lines: string[] = [];
  const reader = snapshotReader(validated);
  const deps = {
    readProjects: async () => [projectDoc("PILOT1")],
    readEntitlements: () => entitlements.readAll(),
    entitlements,
    leases: new MemoryLeases(),
    readGroup: reader.readGroup,
    checkGroups: reader.checkGroups,
  };
  const context = { trigger: "cli" as const, now: new ManualClock(NOW.toISOString()).now, newRunId: () => "run-s", log: (l: string) => lines.push(l), source: { kind: "snapshot" as const, sha256: validated.sha256, readAt: validated.readAt } };
  return { deps, context, entitlements, lines };
}

test("apply-snapshot writes through the same plan and reports the snapshot it applied", async () => {
  const h = applyHarness(snapshotText());
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "succeeded");
  assert.deepEqual([...h.entitlements.docs.keys()].sort(), [PERSON_A, PERSON_B]);
  const line = JSON.parse(h.lines.at(-1) ?? "{}");
  assert.equal(line.source, "snapshot");
  assert.match(line.snapshotSha256, /^[0-9a-f]{64}$/);
});

test("a snapshot naming a group no active project registers is refused before anything is written", async () => {
  const text = JSON.stringify(buildSnapshot([okRead(GROUP_STD, PERSON_A), okRead(UNREGISTERED, PERSON_C)], TENANT, NOW));
  const h = applyHarness(text);
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "failed");
  assert.deepEqual(summary.reasons, ["snapshot_group_unregistered"]);
  assert.equal(h.entitlements.writes.length, 0);
});

test("a registered group missing from the snapshot freezes its project, never reads as empty", async () => {
  const text = JSON.stringify(buildSnapshot([okRead(GROUP_STD, PERSON_A)], TENANT, NOW));
  const existing = { id: PERSON_B, personId: PERSON_B, generation: 1, lastVerifiedAt: "2026-10-11T00:00:00Z", projectMemberships: [{ projectId: "PILOT1", classification: "PRM", classificationGroupId: GROUP_PRM, familyPolicy: familyPolicy(["claude-haiku-4-5"]), backendId: "foundry-sample-hub", aggregateMode: "notify", denormalizedAt: "2026-10-11T00:00:00Z", joinedAt: "2026-10-11T00:00:00Z", status: "active" }] };
  const h = applyHarness(text, [existing]);
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "failed");
  assert.deepEqual(summary.refusals, ["snapshot_group_missing"]);
  assert.equal(h.entitlements.writes.length, 0, "PERSON_B keeps PRM and PERSON_A is not added while PRM is unknown");
});

test("apply-snapshot keeps the removal limits: an over-limit removal is withheld", async () => {
  const text = JSON.stringify(buildSnapshot([okRead(GROUP_STD), okRead(GROUP_PRM)], TENANT, NOW));
  const member = { projectId: "PILOT1", classification: "STD", classificationGroupId: GROUP_STD, familyPolicy: familyPolicy(), backendId: "foundry-sample-hub", aggregateMode: "notify", denormalizedAt: "2026-10-11T00:00:00Z", joinedAt: "2026-10-11T00:00:00Z", status: "active" };
  const h = applyHarness(text, [{ id: PERSON_A, personId: PERSON_A, generation: 1, lastVerifiedAt: "2026-10-11T00:00:00Z", projectMemberships: [member] }]);
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.deepEqual(summary.refusals, ["removal_limit_exceeded"]);
  assert.equal(h.entitlements.writes.length, 0);
});

test("an older snapshot cannot undo a newer one: it is refused once newer evidence was applied", async () => {
  const leases = new MemoryLeases();
  const entitlements = new MemoryEntitlements();
  const lines: string[] = [];
  const apply = async (readAt: string, members: string[], at: string) => {
    const text = JSON.stringify(buildSnapshot([okRead(GROUP_STD, ...members), okRead(GROUP_PRM)], TENANT, new Date(readAt)));
    const validated = validateSnapshot(text, { tenantId: TENANT, now: new Date(at), limits: LIMITS });
    if (!validated.ok) assert.fail(JSON.stringify(validated.problems));
    const reader = snapshotReader(validated);
    const deps = { readProjects: async () => [projectDoc("PILOT1")], readEntitlements: () => entitlements.readAll(), entitlements, leases, readGroup: reader.readGroup, checkGroups: reader.checkGroups };
    const context = { trigger: "cli" as const, now: () => new Date(at), newRunId: () => `run-${at}`, log: (l: string) => lines.push(l), source: { kind: "snapshot" as const, sha256: validated.sha256, readAt: validated.readAt } };
    return runSync({ ...CONFIG, maxRemovalsPerRun: 10, maxRemovalFraction: 1 }, deps, context);
  };
  assert.equal((await apply("2026-10-11T12:00:00.000Z", [PERSON_A], "2026-10-11T12:05:00.000Z")).outcome, "succeeded");
  assert.equal((await apply("2026-10-11T12:20:00.000Z", [], "2026-10-11T12:21:00.000Z")).outcome, "succeeded");
  assert.deepEqual(entitlements.docs.get(PERSON_A)?.doc.projectMemberships, [], "the newer snapshot removed PERSON_A");
  const replay = await apply("2026-10-11T12:00:00.000Z", [PERSON_A], "2026-10-11T12:40:00.000Z");
  assert.equal(replay.outcome, "failed");
  assert.deepEqual(replay.reasons, ["snapshot_older_than_applied"]);
  assert.deepEqual(entitlements.docs.get(PERSON_A)?.doc.projectMemberships, [], "the replay changed nothing");
  assert.equal(JSON.parse(lines.at(-1) ?? "{}").snapshotReadAt, "2026-10-11T12:00:00.000Z");
});
