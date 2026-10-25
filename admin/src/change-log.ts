// Permanent admin change record (Cosmos `adminConfig`, append-and-complete; no deletes).
// A change is recorded BEFORE it is applied: if the record cannot be written, the change is refused
// (503 change_log_unavailable) and nothing is modified. After the write, the record is completed with
// the result. A record left "pending" means the write started but its result was not confirmed.
// The ccof.admin.audit.v1 log line is still written; refused attempts appear only in that telemetry.

import type { Container } from "@azure/cosmos";
import { ApiError } from "./auth.ts";
import type { Doc } from "./validation.ts";

export interface ChangeEntry { path: string; before: unknown; after: unknown }
export interface ChangeRecord {
  requestId: string;
  at: string;
  actorOid: string;
  operation: string;
  // pending until completed; then created, updated, retired, refused (definitely not applied) or
  // unconfirmed (the write threw; it may or may not have been applied).
  outcome: string;
  projectId: string | null;
  changes: ChangeEntry[];
  changesTruncated: boolean;
  details: Doc;
  completedAt: string | null;
}
export interface ChangeFilters { project: string; actor: string; operation: string; outcome: string; from: string; to: string; offset: number; limit: number }
export interface ChangeLog {
  append(record: ChangeRecord): Promise<void>;
  complete(record: ChangeRecord): Promise<void>;
  list(filters: ChangeFilters): Promise<{ rows: ChangeRecord[]; matched: number }>;
}
export const MAX_RECORDED_CHANGES = 100;

export interface PendingChange { finish(outcome: string, details?: Doc): Promise<void> }

// Starts the record; throws 503 when the log is configured but unwritable, so no change is applied.
export async function beginChange(
  log: ChangeLog | null | undefined,
  base: { requestId: string; at: string; actorOid: string; operation: string; projectId: string | null; changes: ChangeEntry[]; details?: Doc },
  now: () => Date, logLine: (line: string) => void,
): Promise<PendingChange> {
  if (!log) return { finish: async () => {} };
  const record: ChangeRecord = {
    ...base, outcome: "pending", details: base.details ?? {}, completedAt: null,
    changes: base.changes.slice(0, MAX_RECORDED_CHANGES), changesTruncated: base.changes.length > MAX_RECORDED_CHANGES,
  };
  try { await log.append(record); } catch {
    logLine(JSON.stringify({ schema: "ccof.admin.changelog.v1", requestId: base.requestId, code: "change_log_append_failed" }));
    throw new ApiError(503, "change_log_unavailable");
  }
  return {
    async finish(outcome, details = {}) {
      try { await log.complete({ ...record, outcome, details: { ...record.details, ...details }, completedAt: now().toISOString() }); } catch {
        // The change is already applied (or refused); the record stays "pending" and the log line says so.
        logLine(JSON.stringify({ schema: "ccof.admin.changelog.v1", requestId: base.requestId, outcome, code: "change_log_complete_failed" }));
      }
    },
  };
}

// Audit rows share one shape with the telemetry audit query, so the console renders both alike.
export function auditRow(r: ChangeRecord): Doc {
  return {
    at: r.at, requestId: r.requestId, operation: r.operation, outcome: r.outcome, projectId: r.projectId, actorOid: r.actorOid,
    d: { changes: r.changes, changesTruncated: r.changesTruncated, ...r.details, completedAt: r.completedAt }, source: "change_log",
  };
}

const PARTITION = (at: string) => `audit-${at.slice(0, 7)}`;
const FIELDS = ["requestId", "at", "actorOid", "operation", "outcome", "projectId", "changes", "changesTruncated", "details", "completedAt"] as const;
const strip = (doc: Doc): ChangeRecord => Object.fromEntries(FIELDS.map((k) => [k, doc[k] ?? null])) as unknown as ChangeRecord;

export function createCosmosChangeLog(container: Container): ChangeLog {
  const item = (r: ChangeRecord) => ({ ...r, id: r.requestId, scopeId: PARTITION(r.at), kind: "adminChange" });
  return {
    async append(r) { await container.items.create(item(r)); },
    async complete(r) { await container.item(r.requestId, PARTITION(r.at)).replace(item(r)); },
    async list(f) {
      const where = ["c.kind = 'adminChange'", "c.at >= @from", "c.at < @to"];
      const parameters: { name: string; value: string | number }[] = [{ name: "@from", value: f.from }, { name: "@to", value: f.to }];
      for (const [key, field] of [["project", "projectId"], ["actor", "actorOid"], ["operation", "operation"], ["outcome", "outcome"]] as const) {
        if (f[key]) { where.push(`c.${field} = @${key}`); parameters.push({ name: `@${key}`, value: f[key] }); }
      }
      const filter = where.join(" AND ");
      const { resources: counted } = await container.items.query<number>({ query: `SELECT VALUE COUNT(1) FROM c WHERE ${filter}`, parameters }).fetchAll();
      const { resources } = await container.items.query<Doc>({
        query: `SELECT * FROM c WHERE ${filter} ORDER BY c.at DESC OFFSET @offset LIMIT @limit`,
        parameters: [...parameters, { name: "@offset", value: f.offset }, { name: "@limit", value: f.limit }],
      }).fetchAll();
      return { rows: resources.map(strip), matched: Number(counted[0] ?? 0) };
    },
  };
}

// Demo and tests.
export function createMemoryChangeLog(): ChangeLog & { records: Map<string, ChangeRecord>; failAppend?: boolean } {
  const records = new Map<string, ChangeRecord>();
  const log = {
    records, failAppend: false,
    async append(r: ChangeRecord) { if (log.failAppend) throw new Error("append failed"); if (records.has(r.requestId)) throw new Error("conflict"); records.set(r.requestId, structuredClone(r)); },
    async complete(r: ChangeRecord) { if (!records.has(r.requestId)) throw new Error("missing"); records.set(r.requestId, structuredClone(r)); },
    async list(f: ChangeFilters) {
      const all = [...records.values()].filter((r) => r.at >= f.from && r.at < f.to && (!f.project || r.projectId === f.project) &&
        (!f.actor || r.actorOid === f.actor) && (!f.operation || r.operation === f.operation) && (!f.outcome || r.outcome === f.outcome))
        .sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
      return { rows: all.slice(f.offset, f.offset + f.limit), matched: all.length };
    },
  };
  return log;
}
