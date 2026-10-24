// One sync run (ADR-0016): lease → projects → groups → entitlement → plan →
// apply → one run line. Every dependency is injected, so the whole run is
// tested with fakes (tests/sync-run.test.ts); function-app.ts and cli.ts wire
// the real Graph and Cosmos.

import { readSyncConfig } from "./config.ts";
import type { ConfigProblem, SyncConfig } from "./config.ts";
import type { GroupReadResult } from "./graph.ts";
import { LeaseLostError, acquireLease } from "./lease.ts";
import type { Lease, LeaseStore } from "./lease.ts";
import { planSync } from "./plan.ts";
import type { EntitlementWriter, ExistingEntitlement, Plan, SyncEvent } from "./plan-types.ts";
import { readProjectDocument } from "./projects.ts";
import type { ProjectReadResult } from "./projects.ts";
import { effectiveRemovalLimits } from "./removal-limits.ts";
import { parseZonedTimestamp } from "./types.ts";
import { RUN_SCHEMA, emptyRunCounts, emptyTimings, formatEvent, formatRun } from "./telemetry.ts";
import type { RunCounts, RunOutcome, RunSummary, RunTimings } from "./telemetry.ts";

export interface RunDependencies {
  readProjects(): Promise<unknown[]>;
  readEntitlements(): Promise<ExistingEntitlement[]>;
  entitlements: EntitlementWriter;
  leases: LeaseStore;
  readGroup(groupId: string, beforeRequest: () => Promise<void>): Promise<GroupReadResult>;
  // The admin console's removal-limit override (removal-limits.ts); null when none is configured.
  // Omitted: the app settings apply.
  readRemovalLimits?(): Promise<unknown | null>;
  // Snapshot runs only: refuses a snapshot naming a group no valid project registers.
  checkGroups?(registered: ReadonlySet<string>): { reason: string; groupIds: string[] } | null;
}

export interface RunContext {
  trigger: "timer" | "cli";
  now: () => Date;
  newRunId: () => string;
  log: (line: string) => void;
  // Where the group members come from; Graph unless a snapshot is applied.
  source?: { kind: "snapshot"; sha256: string; readAt: string };
}

interface Outcome {
  outcome: RunOutcome;
  reasons: string[];
}

const ERROR_CODE = /^[A-Za-z0-9_.-]{1,32}$/;

function errorCodeOf(err: unknown): string | undefined {
  const code = typeof err === "object" && err !== null && "code" in err ? String((err as { code: unknown }).code) : undefined;
  return code !== undefined && ERROR_CODE.test(code) ? code : undefined;
}

class RunState {
  readonly runId: string;
  readonly started: Date;
  readonly timings: RunTimings = emptyTimings();
  readonly counts: RunCounts = emptyRunCounts();
  readonly refusals = new Set<string>();
  private readonly context: RunContext;

  constructor(context: RunContext) {
    this.context = context;
    this.runId = context.newRunId();
    this.started = context.now();
  }

  emit(event: SyncEvent): void {
    if (event.event === "refusal") this.refusals.add(event.reason);
    this.context.log(formatEvent(this.runId, event));
  }

  async timed<T>(key: keyof RunTimings, work: () => Promise<T>): Promise<T> {
    const start = this.context.now().getTime();
    try {
      return await work();
    } finally {
      this.timings[key] += this.context.now().getTime() - start;
    }
  }

  finish(writeMode: RunSummary["writeMode"], result: Outcome, problems?: string[]): RunSummary {
    const finished = this.context.now();
    const summary: RunSummary = {
      schema: RUN_SCHEMA,
      runId: this.runId,
      trigger: this.context.trigger,
      source: this.context.source?.kind ?? "graph",
      writeMode,
      outcome: result.outcome,
      reasons: result.reasons,
      refusals: [...this.refusals].sort(),
      startedAt: this.started.toISOString(),
      finishedAt: finished.toISOString(),
      durationMs: finished.getTime() - this.started.getTime(),
      timings: this.timings,
      counts: this.counts,
    };
    if (this.context.source) {
      summary.snapshotSha256 = this.context.source.sha256;
      summary.snapshotReadAt = this.context.source.readAt;
    }
    if (problems) summary.problems = problems;
    this.context.log(formatRun(summary));
    return summary;
  }
}

// Input refused before the run starts (no lease, no Azure call): one run line with the problems.
export function refusedBeforeRun(reason: string, problems: string[], context: RunContext): RunSummary {
  return new RunState(context).finish(null, { outcome: "failed", reasons: [reason] }, problems);
}

export function configFailure(problems: ConfigProblem[], context: RunContext): RunSummary {
  return new RunState(context).finish(null, { outcome: "failed", reasons: ["sync_config_invalid"] }, problems.map((p) => `${p.setting}:${p.problem}`));
}

async function readGroups(projects: ProjectReadResult[], deps: RunDependencies, lease: Lease, state: RunState): Promise<Map<string, GroupReadResult>> {
  // A retired project's groups are not read: its memberships are removed whatever they hold.
  const groupIds = [...new Set(projects.flatMap((p) => (p.ok && !p.retired ? p.classifications.map((c) => c.groupId) : [])))].sort();
  const groups = new Map<string, GroupReadResult>();
  for (const groupId of groupIds) {
    let result: GroupReadResult;
    try {
      result = await deps.readGroup(groupId, () => lease.ensure());
    } catch (err) {
      if (err instanceof LeaseLostError) throw err;
      result = { ok: false, groupId, reason: "graph_request_failed", httpStatus: null, graphErrorCode: null, retries: 0 };
    }
    groups.set(groupId, result);
    state.counts.groupsRead += 1;
    if (!result.ok) state.counts.groupsFailed += 1;
  }
  return groups;
}

async function applyPlan(plan: Plan, deps: RunDependencies, lease: Lease, state: RunState): Promise<void> {
  for (const write of plan.writes) {
    await lease.ensure();
    try {
      const result = write.kind === "create" ? await deps.entitlements.create(write.document) : await deps.entitlements.replace(write.document, write.etag ?? "");
      if (result === "conflict") {
        state.counts.writeConflicts += 1;
        state.emit({ event: "refusal", reason: "entitlement_write_conflict", personId: write.personId });
      } else if (result === "created") state.counts.created += 1;
      else state.counts.replaced += 1;
    } catch (err) {
      state.counts.writeFailures += 1;
      state.emit({ event: "refusal", reason: "entitlement_write_failed", personId: write.personId, errorCode: errorCodeOf(err) });
    }
  }
}

function copyPlanCounts(plan: Plan, counts: RunCounts): void {
  const p = plan.counts;
  Object.assign(counts, {
    projectsRead: p.projectsRead,
    projectsValid: p.projectsValid,
    projectsFrozen: p.projectsFrozen,
    membersRead: p.membersRead,
    membersAdmitted: p.membersAdmitted,
    membersDisabled: p.membersDisabled,
    membersAccountStateUnread: p.membersAccountStateUnread,
    documentsRead: p.documentsRead,
    documentsIgnored: p.documentsIgnored,
    unchanged: p.unchanged,
    removedMemberships: p.removedMemberships,
    withheldRemovals: p.withheldRemovals,
    emptiedDocuments: p.emptiedDocuments,
    conflicts: p.conflicts,
  });
}

async function execute(config: SyncConfig, deps: RunDependencies, lease: Lease, state: RunState, now: () => Date): Promise<Outcome> {
  let docs: unknown[];
  try {
    docs = await state.timed("projectsMs", () => deps.readProjects());
  } catch {
    return { outcome: "failed", reasons: ["projects_read_failed"] };
  }
  const projects = docs.map(readProjectDocument);
  if (deps.checkGroups) {
    const registered = new Set(projects.flatMap((p) => (p.ok ? p.classifications.map((c) => c.groupId) : [])));
    const refused = deps.checkGroups(registered);
    if (refused) {
      for (const groupId of refused.groupIds) state.emit({ event: "refusal", reason: refused.reason, groupId });
      return { outcome: "failed", reasons: [refused.reason] };
    }
  }
  const groups = await state.timed("groupsMs", () => readGroups(projects, deps, lease, state));

  await lease.ensure();
  let existing: ExistingEntitlement[];
  try {
    existing = await state.timed("entitlementsMs", () => deps.readEntitlements());
  } catch {
    return { outcome: "failed", reasons: ["entitlements_read_failed"] };
  }

  const settingsLimits = { maxRemovalsPerRun: config.maxRemovalsPerRun, maxRemovalFraction: config.maxRemovalFraction };
  let limits = effectiveRemovalLimits(settingsLimits, { ok: true, doc: null }, now());
  if (deps.readRemovalLimits) {
    let read: { ok: true; doc: unknown | null } | { ok: false };
    try { read = { ok: true, doc: await deps.readRemovalLimits() }; } catch { read = { ok: false }; }
    limits = effectiveRemovalLimits(settingsLimits, read, now());
    const counts = { maxRemovalsPerRun: limits.limits.maxRemovalsPerRun, maxRemovalFractionPpm: Math.round(limits.limits.maxRemovalFraction * 1_000_000) };
    if (limits.source === "admin") state.emit({ event: "notice", reason: "removal_limits_from_admin", counts });
    else if (limits.reason !== "override_absent" && limits.reason !== "override_disabled") state.emit({ event: "notice", reason: limits.reason ?? "removal_limits_from_settings", counts });
  }
  const planStart = now().getTime();
  const plan = planSync({
    projects,
    groups,
    existing,
    memberTypes: config.memberTypes,
    removalLimits: limits.limits,
    now: now(),
  });
  state.timings.planMs = now().getTime() - planStart;
  for (const event of plan.events) state.emit(event);
  copyPlanCounts(plan, state.counts);

  // No project could be evaluated while there is something to change: write
  // nothing at all, not even repairs (also when the projects container is empty).
  const nothingEvaluated = plan.evaluatedProjects === 0 && (projects.length > 0 || existing.length > 0);
  if (config.writeMode === "apply" && !nothingEvaluated) {
    await state.timed("applyMs", () => applyPlan(plan, deps, lease, state));
  } else if (config.writeMode === "dry-run" && !nothingEvaluated) {
    state.counts.created = plan.counts.creates;
    state.counts.replaced = plan.counts.replaces;
  }
  state.counts.upserted = state.counts.created + state.counts.replaced;

  const refusals = [...state.refusals].sort();
  if (nothingEvaluated) return { outcome: "failed", reasons: refusals };
  if (refusals.length > 0) return { outcome: "partial", reasons: refusals };
  return { outcome: "succeeded", reasons: [] };
}

export async function runSync(config: SyncConfig, deps: RunDependencies, context: RunContext): Promise<RunSummary> {
  const state = new RunState(context);
  let lease: Lease;
  let previousEvidenceAt: string | null;
  try {
    const acquired = await state.timed("leaseMs", () => acquireLease(deps.leases, { holder: state.runId, leaseSeconds: config.leaseSeconds, now: context.now }));
    if (!acquired.acquired) return state.finish(config.writeMode, { outcome: "skipped", reasons: ["lease_held"] });
    lease = acquired.lease;
    previousEvidenceAt = acquired.previousEvidenceAt;
  } catch (err) {
    state.emit({ event: "refusal", reason: "lease_store_failed", errorCode: errorCodeOf(err) });
    return state.finish(config.writeMode, { outcome: "failed", reasons: ["lease_store_failed"] });
  }

  // A snapshot no newer than evidence already applied would undo later
  // removals: refuse it before reading anything.
  const evidenceAt = context.source?.readAt ?? state.started.toISOString();
  const previous = parseZonedTimestamp(previousEvidenceAt);
  const current = parseZonedTimestamp(evidenceAt);
  let result: Outcome;
  try {
    if (context.source && previous !== null && (current === null || current <= previous)) {
      state.emit({ event: "refusal", reason: "snapshot_older_than_applied" });
      result = { outcome: "failed", reasons: ["snapshot_older_than_applied"] };
    } else {
      result = await execute(config, deps, lease, state, context.now);
    }
  } catch (err) {
    if (err instanceof LeaseLostError) result = { outcome: "failed", reasons: ["lease_lost"] };
    else {
      state.emit({ event: "refusal", reason: "sync_run_failed", errorCode: errorCodeOf(err) });
      result = { outcome: "failed", reasons: ["sync_run_failed"] };
    }
  }
  const applied = config.writeMode === "apply" && (result.outcome === "succeeded" || result.outcome === "partial");
  try {
    await lease.release(applied ? evidenceAt : null);
  } catch {
    // The lease expires by itself; the next run takes it over then.
  }
  return state.finish(config.writeMode, result);
}

// Validates the settings first: invalid settings make no Azure call, because
// the dependencies are created only after validation.
export async function runFromSettings(
  settings: Readonly<Record<string, string | undefined>>,
  createDependencies: (config: SyncConfig) => RunDependencies,
  context: RunContext,
): Promise<RunSummary> {
  const result = readSyncConfig(settings);
  if (!result.ok) return configFailure(result.problems, context);
  return runSync(result.config, createDependencies(result.config), context);
}
