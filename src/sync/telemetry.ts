// The sync's log lines (ADR-0016). One `ccof.sync.run.v1` line per run, written
// last, and one `ccof.sync.event.v1` line per refusal, conflict or notice.
// Fields are built from an allow-list: ids, reason codes, counts and timings,
// never names, UPNs or free text (WP-TEL conventions, docs/TELEMETRY.md on
// wp/tel).

import type { SyncEvent } from "./plan-types.ts";

export const RUN_SCHEMA = "ccof.sync.run.v1";
export const EVENT_SCHEMA = "ccof.sync.event.v1";

export type RunOutcome = "succeeded" | "partial" | "skipped" | "failed";

export interface RunTimings {
  leaseMs: number;
  projectsMs: number;
  groupsMs: number;
  entitlementsMs: number;
  planMs: number;
  applyMs: number;
}

export interface RunCounts {
  projectsRead: number;
  projectsValid: number;
  projectsFrozen: number;
  groupsRead: number;
  groupsFailed: number;
  membersRead: number;
  membersAdmitted: number;
  membersDisabled: number;
  membersAccountStateUnread: number;
  documentsRead: number;
  documentsIgnored: number;
  created: number;
  replaced: number;
  upserted: number;
  unchanged: number;
  removedMemberships: number;
  withheldRemovals: number;
  emptiedDocuments: number;
  writeConflicts: number;
  writeFailures: number;
  conflicts: number;
}

export interface RunSummary {
  schema: typeof RUN_SCHEMA;
  runId: string;
  trigger: "timer" | "cli";
  source: "graph" | "snapshot";
  snapshotSha256?: string;
  snapshotReadAt?: string;
  writeMode: "apply" | "dry-run" | null;
  outcome: RunOutcome;
  reasons: string[];
  refusals: string[];
  problems?: string[];
  startedAt: string;
  finishedAt: string;
  durationMs: number;
  timings: RunTimings;
  counts: RunCounts;
}

export function emptyRunCounts(): RunCounts {
  return {
    projectsRead: 0,
    projectsValid: 0,
    projectsFrozen: 0,
    groupsRead: 0,
    groupsFailed: 0,
    membersRead: 0,
    membersAdmitted: 0,
    membersDisabled: 0,
    membersAccountStateUnread: 0,
    documentsRead: 0,
    documentsIgnored: 0,
    created: 0,
    replaced: 0,
    upserted: 0,
    unchanged: 0,
    removedMemberships: 0,
    withheldRemovals: 0,
    emptiedDocuments: 0,
    writeConflicts: 0,
    writeFailures: 0,
    conflicts: 0,
  };
}

export function emptyTimings(): RunTimings {
  return { leaseMs: 0, projectsMs: 0, groupsMs: 0, entitlementsMs: 0, planMs: 0, applyMs: 0 };
}

const EVENT_FIELDS = [
  "reason",
  "projectId",
  "groupId",
  "personId",
  "memberId",
  "classifications",
  "kept",
  "problems",
  "httpStatus",
  "graphErrorCode",
  "errorCode",
  "counts",
] as const;

export function formatEvent(runId: string, event: SyncEvent): string {
  const line: Record<string, unknown> = { schema: EVENT_SCHEMA, runId, event: event.event };
  for (const field of EVENT_FIELDS) {
    if (event[field] !== undefined) line[field] = event[field];
  }
  return JSON.stringify(line);
}

export function formatRun(summary: RunSummary): string {
  const { schema, runId, trigger, source, snapshotSha256, snapshotReadAt, writeMode, outcome, reasons, refusals, problems, startedAt, finishedAt, durationMs, timings, counts } = summary;
  return JSON.stringify({ schema, runId, trigger, source, snapshotSha256, snapshotReadAt, writeMode, outcome, reasons, refusals, problems, startedAt, finishedAt, durationMs, timings, counts });
}

// The quick-start's registry seed (src/sync/registry-seed.ts): one `ccof.seed.result.v1` line per
// run, which Deploy-Quickstart.ps1 step 5 finds by seedId in the sync app's Application Insights.
// Per document: container, id (only when it matches the identifier pattern), outcome, the names of
// the fields that differ, a short code, and problems as field paths with codes, never values.
export const SEED_RESULT_SCHEMA = "ccof.seed.result.v1";

export type SeedDocumentOutcome = "created" | "present-equal" | "present-differs" | "failed";

export interface SeedDocumentResult {
  container: "projects" | "backends";
  id: string | null;
  outcome: SeedDocumentOutcome;
  fields?: string[];
  code?: string;
  problems?: string[];
}

export type SeedOutcome = "succeeded" | "differs" | "failed" | "refused";

export interface SeedCounts {
  created: number;
  presentEqual: number;
  presentDiffers: number;
  failed: number;
}

export interface SeedResult {
  schema: typeof SEED_RESULT_SCHEMA;
  seedId: string | null;
  outcome: SeedOutcome;
  reason?: string;
  problems?: string[];
  counts: SeedCounts;
  documents: SeedDocumentResult[];
  startedAt: string;
  durationMs: number;
}

export function formatSeedResult(result: SeedResult): string {
  const { schema, seedId, outcome, reason, problems, counts, startedAt, durationMs } = result;
  const documents = result.documents.map(({ container, id, outcome: documentOutcome, fields, code, problems: documentProblems }) => ({
    container,
    id,
    outcome: documentOutcome,
    fields,
    code,
    problems: documentProblems,
  }));
  return JSON.stringify({ schema, seedId, outcome, reason, problems, counts, documents, startedAt, durationMs });
}
