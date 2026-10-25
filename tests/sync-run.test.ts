// A whole run (src/sync/run.ts) against fakes for Graph and Cosmos: the lease,
// the order of reads, idempotent re-runs, dry runs, failures that change
// nothing, and the telemetry lines (ccof.sync.run.v1, ccof.sync.event.v1).

import { test } from "node:test";
import assert from "node:assert/strict";
import { runFromSettings, runSync } from "../src/sync/run.ts";
import type { RunContext, RunDependencies } from "../src/sync/run.ts";
import { readGroupMembers } from "../src/sync/graph.ts";
import type { SyncConfig } from "../src/sync/config.ts";
import { LEASE_ID } from "../src/sync/lease.ts";
import { FakeGraph, GROUP_PRM, GROUP_STD, ManualClock, MemoryEntitlements, MemoryLeases, PERSON_A, PERSON_B, PERSON_C, member, membersUrl, page, projectDoc } from "./helpers/sync-fakes.ts";

const CONFIG: SyncConfig = {
  tenantId: "00000000-0000-4000-8000-000000000111",
  cosmosEndpoint: "https://sample-pilot-cosmos.documents.azure.com:443/",
  cosmosDatabase: "ccof",
  projectsContainer: "projects",
  entitlementContainer: "entitlement",
  leaseContainer: "syncLease",
  leaseSeconds: 300,
  memberTypes: ["user"],
  maxRemovalsPerRun: 10,
  maxRemovalFraction: 0.5,
  graphMaxRetries: 2,
  graphMaxRetryAfterSeconds: 5,
  graphTimeoutSeconds: 10,
  writeMode: "apply",
};

interface Harness {
  graph: FakeGraph;
  entitlements: MemoryEntitlements;
  leases: MemoryLeases;
  projects: unknown[];
  lines: string[];
  clock: ManualClock;
  deps: RunDependencies;
  context: RunContext;
}

function harness(): Harness {
  const graph = new FakeGraph();
  const entitlements = new MemoryEntitlements();
  const leases = new MemoryLeases();
  const lines: string[] = [];
  const clock = new ManualClock("2026-10-11T12:00:00.000Z");
  const h: Harness = {
    graph,
    entitlements,
    leases,
    projects: [projectDoc("PILOT1")],
    lines,
    clock,
    deps: {
      readProjects: async () => structuredClone(h.projects),
      readEntitlements: () => entitlements.readAll(),
      entitlements,
      leases,
      readGroup: (groupId, beforeRequest) =>
        readGroupMembers(groupId, {
          fetch: graph.fetch,
          getToken: async () => "t",
          sleep: async () => {},
          maxRetries: 2,
          maxRetryAfterSeconds: 5,
          timeoutSeconds: 10,
          readServicePrincipals: false,
          beforeRequest,
        }),
    },
    context: { trigger: "timer", now: clock.now, newRunId: () => "run-1", log: (line) => lines.push(line) },
  };
  return h;
}

function runLine(lines: string[]) {
  const last = JSON.parse(lines.at(-1) ?? "{}");
  assert.equal(last.schema, "ccof.sync.run.v1", "the run line is the last line");
  return last;
}

function events(lines: string[]) {
  return lines.slice(0, -1).map((l) => JSON.parse(l));
}

test("a run reads the registered groups, writes the new memberships and reports one run line", async () => {
  const h = harness();
  h.graph.on(membersUrl(GROUP_STD), page([member(PERSON_A)])).on(membersUrl(GROUP_PRM), page([member(PERSON_B)]));
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "succeeded");
  assert.deepEqual([...h.entitlements.docs.keys()].sort(), [PERSON_A, PERSON_B]);
  const line = runLine(h.lines);
  assert.equal(line.runId, "run-1");
  assert.equal(line.trigger, "timer");
  assert.equal(line.writeMode, "apply");
  assert.equal(line.startedAt, "2026-10-11T12:00:00.000Z");
  assert.deepEqual(
    [line.counts.projectsRead, line.counts.groupsRead, line.counts.membersRead, line.counts.documentsRead, line.counts.upserted, line.counts.created, line.counts.unchanged, line.counts.removedMemberships],
    [1, 2, 2, 0, 2, 2, 0, 0],
  );
  assert.deepEqual(line.refusals, []);
  assert.equal(h.leases.docs.get(LEASE_ID)?.doc.released, true, "the lease is released");
});

test("re-running with nothing changed writes nothing (idempotent)", async () => {
  const h = harness();
  h.graph.on(membersUrl(GROUP_STD), page([member(PERSON_A)]), page([member(PERSON_A)])).on(membersUrl(GROUP_PRM), page([]), page([]));
  await runSync(CONFIG, h.deps, h.context);
  const writesAfterFirst = h.entitlements.writes.length;
  h.clock.advance(60);
  await runSync(CONFIG, h.deps, h.context);
  assert.equal(h.entitlements.writes.length, writesAfterFirst);
  const line = runLine(h.lines);
  assert.deepEqual([line.counts.upserted, line.counts.unchanged], [0, 1]);
});

test("removing a person from the group empties their document on the next run, with generation + 1", async () => {
  const h = harness();
  h.graph.on(membersUrl(GROUP_STD), page([member(PERSON_A)]), page([])).on(membersUrl(GROUP_PRM), page([]), page([]));
  await runSync(CONFIG, h.deps, h.context);
  h.clock.advance(60);
  await runSync(CONFIG, h.deps, h.context);
  const doc = h.entitlements.docs.get(PERSON_A)?.doc;
  assert.deepEqual(doc?.projectMemberships, []);
  assert.equal(doc?.generation, 2);
  assert.equal(doc?.lastVerifiedAt, "2026-10-11T12:01:00.000Z");
  assert.equal(runLine(h.lines).counts.removedMemberships, 1);
});

test("a dry run plans and reports but writes nothing, and still takes and releases the lease", async () => {
  const h = harness();
  h.graph.on(membersUrl(GROUP_STD), page([member(PERSON_A)])).on(membersUrl(GROUP_PRM), page([]));
  const summary = await runSync({ ...CONFIG, writeMode: "dry-run" }, h.deps, h.context);
  assert.equal(h.entitlements.writes.length, 0);
  assert.equal(summary.writeMode, "dry-run");
  assert.equal(summary.counts.created, 1, "the planned creation is reported");
  assert.equal(h.leases.docs.get(LEASE_ID)?.doc.released, true);
});

test("a run that finds the lease held writes nothing and makes no Graph call", async () => {
  const h = harness();
  await h.leases.create({ id: LEASE_ID, holder: "other", acquiredAt: "", renewedAt: "", leaseExpiresAt: "2026-10-11T12:04:00.000Z", released: false, evidenceAt: null });
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "skipped");
  assert.deepEqual(summary.reasons, ["lease_held"]);
  assert.equal(h.graph.calls.length, 0);
  assert.equal(h.entitlements.writes.length, 0);
});

test("graph_permission_missing changes nothing, and with every project unreadable the run fails with that reason", async () => {
  const h = harness();
  h.entitlements.seed({ id: PERSON_A, personId: PERSON_A, projectMemberships: [], generation: 3, lastVerifiedAt: "2026-10-10T00:00:00Z", expiresAt: "2026-10-11T13:00:00Z" });
  const denied = { status: 403, body: { error: { code: "Authorization_RequestDenied", message: "Insufficient privileges" } } };
  h.graph.on(membersUrl(GROUP_STD), denied).on(membersUrl(GROUP_PRM), denied);
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "failed");
  assert.deepEqual(summary.reasons, ["graph_permission_missing"]);
  assert.deepEqual(summary.refusals, ["graph_permission_missing"]);
  assert.equal(h.entitlements.writes.length, 0);
  assert.equal(h.graph.calls.length, 2, "each group is tried once; 403 is not retried");
  const refusals = events(h.lines).filter((e) => e.reason === "graph_permission_missing");
  assert.equal(refusals.length, 2);
  assert.equal(refusals[0].schema, "ccof.sync.event.v1");
});

test("a failed read of one project's group makes the run partial while another project is synced", async () => {
  const h = harness();
  h.projects = [projectDoc("PILOT1"), projectDoc("ALPHA2", { classifications: { CYB: { ...(projectDoc().classifications as Record<string, Record<string, unknown>>).STD, groupId: "99999999-9999-4999-8999-999999999999" } } })];
  h.graph
    .on(membersUrl(GROUP_STD), { status: 503 }, { status: 503 }, { status: 503 })
    .on(membersUrl(GROUP_PRM), page([]))
    .on(membersUrl("99999999-9999-4999-8999-999999999999"), page([member(PERSON_B)]));
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "partial");
  assert.deepEqual(summary.refusals, ["graph_unavailable"]);
  assert.deepEqual([...h.entitlements.docs.keys()], [PERSON_B]);
  assert.deepEqual([summary.counts.projectsFrozen, summary.counts.groupsFailed], [1, 1]);
});

test("a document changed by someone else between read and write is not overwritten (etag), and the next run settles it", async () => {
  const h = harness();
  h.entitlements.seed({ id: PERSON_A, personId: PERSON_A, projectMemberships: [], generation: 1, lastVerifiedAt: "2026-10-10T00:00:00Z" });
  h.graph.on(membersUrl(GROUP_STD), page([member(PERSON_A)]), page([member(PERSON_A)])).on(membersUrl(GROUP_PRM), page([]), page([]));
  const originalRead = h.deps.readEntitlements;
  h.deps.readEntitlements = async () => {
    const docs = await originalRead();
    h.entitlements.touch(PERSON_A);
    return docs;
  };
  const first = await runSync(CONFIG, h.deps, h.context);
  assert.equal(first.outcome, "partial");
  assert.equal(first.counts.writeConflicts, 1);
  assert.ok(events(h.lines).some((e) => e.reason === "entitlement_write_conflict" && e.personId === PERSON_A));

  h.deps.readEntitlements = originalRead;
  const second = await runSync(CONFIG, h.deps, h.context);
  assert.equal(second.outcome, "succeeded");
  assert.equal(h.entitlements.docs.get(PERSON_A)?.doc.generation, 2);
});

test("a write that fails for one person is reported and the others are still written", async () => {
  const h = harness();
  h.graph.on(membersUrl(GROUP_STD), page([member(PERSON_A), member(PERSON_B)])).on(membersUrl(GROUP_PRM), page([]));
  h.entitlements.failNextWriteFor.add(PERSON_A);
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "partial");
  assert.equal(summary.counts.writeFailures, 1);
  assert.deepEqual([...h.entitlements.docs.keys()], [PERSON_B]);
  assert.ok(events(h.lines).some((e) => e.reason === "entitlement_write_failed" && e.errorCode === "503"));
});

test("a lease lost before a write stops the run: nothing more is written", async () => {
  const h = harness();
  h.graph.on(membersUrl(GROUP_STD), page([member(PERSON_A), member(PERSON_B)])).on(membersUrl(GROUP_PRM), page([]));
  const originalRead = h.deps.readEntitlements;
  h.deps.readEntitlements = async () => {
    const docs = await originalRead();
    h.clock.advance(400);
    const stolen = h.leases.docs.get(LEASE_ID);
    if (stolen) stolen.etag = '"stolen"';
    return docs;
  };
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "failed");
  assert.deepEqual(summary.reasons, ["lease_lost"]);
  assert.equal(h.entitlements.writes.length, 0);
});

test("a failed projects read fails the run without writing, and releases the lease", async () => {
  const h = harness();
  h.deps.readProjects = async () => {
    throw Object.assign(new Error("boom"), { code: 503 });
  };
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "failed");
  assert.deepEqual(summary.reasons, ["projects_read_failed"]);
  assert.equal(h.entitlements.writes.length, 0);
  assert.equal(h.leases.docs.get(LEASE_ID)?.doc.released, true);
});

test("zero registered projects reads no group and writes nothing when the container is empty", async () => {
  const h = harness();
  h.projects = [];
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "succeeded");
  assert.equal(h.graph.calls.length, 0);
  assert.deepEqual([summary.counts.projectsRead, summary.counts.upserted], [0, 0]);
});

test("invalid settings refuse the run before any dependency is created (no Azure call)", async () => {
  const lines: string[] = [];
  let created = 0;
  const summary = await runFromSettings(
    { SYNC_TENANT_ID: "x" },
    () => {
      created += 1;
      throw new Error("must not be called");
    },
    { trigger: "timer", now: () => new Date("2026-10-11T12:00:00Z"), newRunId: () => "run-x", log: (l) => lines.push(l) },
  );
  assert.equal(created, 0);
  assert.equal(summary.outcome, "failed");
  assert.deepEqual(summary.reasons, ["sync_config_invalid"]);
  const line = runLine(lines);
  assert.ok(line.problems.includes("SYNC_TENANT_ID:invalid"));
  assert.ok(line.problems.includes("COSMOS_ENDPOINT:missing"));
});

test("telemetry lines carry ids, codes and counts only: no free text, names or UPNs", async () => {
  const h = harness();
  h.graph
    .on(membersUrl(GROUP_STD), page([member(PERSON_A), member("00000000-0000-4000-8000-000001101010", "#microsoft.graph.group")]))
    .on(membersUrl(GROUP_PRM), page([member(PERSON_A)]));
  await runSync(CONFIG, h.deps, h.context);
  const allowedEventKeys = new Set(["schema", "runId", "event", "reason", "projectId", "groupId", "personId", "memberId", "classifications", "kept", "problems", "httpStatus", "graphErrorCode", "errorCode", "counts"]);
  for (const line of h.lines) {
    const parsed = JSON.parse(line);
    assert.ok(["ccof.sync.run.v1", "ccof.sync.event.v1"].includes(parsed.schema), line);
    if (parsed.schema === "ccof.sync.event.v1") {
      for (const key of Object.keys(parsed)) assert.ok(allowedEventKeys.has(key), `unexpected event key ${key}`);
    }
    assert.doesNotMatch(line, /@[A-Za-z]/, "no UPN or e-mail shaped values");
    assert.doesNotMatch(line, /Insufficient|message/i, "no free text from Graph");
  }
  const kinds = events(h.lines).map((e) => e.reason).sort();
  assert.deepEqual(kinds, ["classification_conflict", "nested_group_not_expanded"]);
});

test("no project document at all but entitlement documents present: nothing is written, the run fails", async () => {
  const h = harness();
  h.projects = [];
  h.entitlements.seed({ id: PERSON_A, personId: PERSON_A, projectMemberships: [], generation: 2.5, lastVerifiedAt: "2026-10-10T00:00:00Z" });
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "failed");
  assert.equal(h.entitlements.writes.length, 0);
});

test("retiring a project removes its memberships on the next run without reading its groups", async () => {
  const h = harness();
  h.graph.on(membersUrl(GROUP_STD), page([member(PERSON_A)])).on(membersUrl(GROUP_PRM), page([]));
  await runSync(CONFIG, h.deps, h.context);
  assert.equal((h.entitlements.docs.get(PERSON_A)?.doc.projectMemberships as unknown[]).length, 1);
  h.projects = [projectDoc("PILOT1", { status: "retired", retiredAt: "2026-10-11T12:00:30.000Z" })];
  h.clock.advance(60);
  const summary = await runSync(CONFIG, h.deps, h.context);
  assert.equal(summary.outcome, "succeeded");
  assert.deepEqual(h.entitlements.docs.get(PERSON_A)?.doc.projectMemberships, []);
  const line = runLine(h.lines);
  assert.deepEqual([line.counts.groupsRead, line.counts.removedMemberships], [0, 1], "no Graph read for a retired project");
});
test("an admin removal-limit override lets a large directory removal through; without it the removal is withheld", async () => {
  const people = [PERSON_A, PERSON_B, PERSON_C];
  const tight = { ...CONFIG, maxRemovalsPerRun: 1, maxRemovalFraction: 0.1 };
  const seed = async () => {
    const h = harness();
    h.graph.on(membersUrl(GROUP_STD), page(people.map((p) => member(p))), page([])).on(membersUrl(GROUP_PRM), page([]), page([]));
    await runSync(CONFIG, h.deps, h.context);
    h.clock.advance(60);
    return h;
  };
  const withheld = await seed();
  await runSync(tight, withheld.deps, withheld.context);
  assert.equal(runLine(withheld.lines).counts.withheldRemovals, 3);

  const allowed = await seed();
  allowed.deps.readRemovalLimits = async () => ({ schemaVersion: 1, enabled: true, maxRemovalsPerRun: 10, maxRemovalFraction: "1", expiresAt: null, reason: "Planned reorganisation" });
  await runSync(tight, allowed.deps, allowed.context);
  assert.deepEqual([runLine(allowed.lines).counts.removedMemberships, runLine(allowed.lines).counts.withheldRemovals], [3, 0]);
  assert.ok(events(allowed.lines).some((e) => e.reason === "removal_limits_from_admin"));

  const unreadable = await seed();
  unreadable.deps.readRemovalLimits = async () => { throw Object.assign(new Error("forbidden"), { code: 403 }); };
  await runSync(tight, unreadable.deps, unreadable.context);
  assert.equal(runLine(unreadable.lines).counts.withheldRemovals, 3, "a failed read never raises the limits");
  assert.ok(events(unreadable.lines).some((e) => e.reason === "override_unreadable"));
});