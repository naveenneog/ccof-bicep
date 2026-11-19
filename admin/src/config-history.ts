// Framework-free SS-04 API. The host authenticates/authorizes the object; restores also verify actor.
import { ApiError, isGuid } from "./auth.ts";
import type { Actor } from "./auth.ts";
import type { ProjectStore } from "./api.ts";
import { beginChange } from "./change-log.ts";
import type { ChangeEntry, ChangeLog } from "./change-log.ts";
import { failoverAfterEdit, registryMap } from "./backend-routing.ts";
import type { RegistryStore } from "./backend-routing.ts";
import { assertValidProject, canonical, isObject, ValidationError } from "./validation.ts";
import type { Doc } from "./validation.ts";
import {
  assertSnapshot, assertVersionId, configSnapshot, ConfigHistoryUnavailable, HISTORY_ACTIONS, historyScope, projectConfig,
} from "./config-history-store.ts";
import type { ConfigHistoryStore, ConfigSnapshot, HistoryPermission } from "./config-history-store.ts";

export interface ConfigHistoryDependencies {
  enabled: boolean;
  projects: ProjectStore;
  versions: ConfigHistoryStore | null;
  registry: RegistryStore | null;
  changeLog: ChangeLog | null;
  // Exact server-configured Cosmos container resource scope, never a browser-supplied scope.
  scope: string;
  projectScope: string;
  now(): Date;
  newId(): string;
  log(line: string): void;
}
export interface ConfigRestoreRequest {
  projectId: string;
  version: string;
  ifMatch: string;
  reason: string;
  actor: Actor | null;
  requestId?: string;
}
export interface ConfigRestorePreview {
  projectId: string;
  version: string;
  ifMatch: string;
  reason: string;
  changes: ChangeEntry[];
  requiresPublication: boolean;
}
export interface ConfigRestoreResult extends ConfigRestorePreview { project: Doc; etag: string; recordedVersion: string }
export interface ConfigVersionSummary { id: string; projectId: string; hash: string; capturedAt: string }
export interface ConfigHistoryCapability {
  state: "available" | "disabled" | "permission_required" | "unavailable";
  reason?: string;
  requirements: HistoryPermission[];
  // Host-enforced foundational permissions; the optional history probe does not claim to verify them.
  prerequisites: HistoryPermission[];
}
export interface ConfigHistoryService {
  capability(): Promise<ConfigHistoryCapability>;
  capture(doc: Doc): Promise<ConfigSnapshot>;
  read(projectId: string, version: string): Promise<ConfigSnapshot>;
  list(projectId: string, limit?: number): Promise<ConfigVersionSummary[]>;
  preview(request: ConfigRestoreRequest): Promise<ConfigRestorePreview>;
  restore(request: ConfigRestoreRequest): Promise<ConfigRestoreResult>;
}
function diff(a: unknown, b: unknown, path = "", out: ChangeEntry[] = []): ChangeEntry[] {
  if (isObject(a) && isObject(b)) {
    for (const key of [...new Set([...Object.keys(a), ...Object.keys(b)])].sort()) diff(a[key], b[key], path ? `${path}.${key}` : key, out);
  } else if (canonical(a) !== canonical(b)) out.push({ path, before: a ?? null, after: b ?? null });
  return out;
}
const unavailable = (e: unknown, action: string, scope: string): ApiError =>
  e instanceof ApiError ? e : new ConfigHistoryUnavailable(action, scope);

function overlayConfig(live: unknown, before: unknown, target: unknown): unknown {
  if (isObject(live) && isObject(target)) {
    const next = structuredClone(live), old = isObject(before) ? before : {};
    for (const key of Object.keys(old)) {
      if (Object.hasOwn(target, key)) continue;
      if (canonical(live[key]) !== canonical(old[key])) throw new ApiError(409, "history_nonconfig_state_conflict");
      delete next[key];
    }
    for (const [key, value] of Object.entries(target)) {
      Object.defineProperty(next, key, { value: overlayConfig(live[key], old[key], value), enumerable: true, writable: true, configurable: true });
    }
    return next;
  }
  // Refuse to remove a configuration branch containing live state that is not in the snapshot.
  if (isObject(live) && canonical(live) !== canonical(before)) throw new ApiError(409, "history_nonconfig_state_conflict");
  return structuredClone(target);
}

export function createConfigHistory(deps: ConfigHistoryDependencies): ConfigHistoryService {
  const store = (action: string = HISTORY_ACTIONS.read): ConfigHistoryStore => {
    if (!deps.enabled) throw new ApiError(404, "history_disabled");
    if (!deps.versions) throw new ConfigHistoryUnavailable(action, deps.scope);
    return deps.versions;
  };
  const read = async (projectId: string, version: string): Promise<ConfigSnapshot> => {
    const versions = store(); historyScope(projectId); assertVersionId(version);
    let found;
    try { found = await versions.read(projectId, version); } catch (e) { throw unavailable(e, HISTORY_ACTIONS.read, deps.scope); }
    if (!found) throw new ApiError(404, "history_version_not_found");
    return assertSnapshot(found, projectId, version);
  };
  const capture = async (doc: Doc): Promise<ConfigSnapshot> => {
    const versions = store(HISTORY_ACTIONS.create), v = configSnapshot(doc, deps.now());
    try { await versions.create(v); } catch (e) { throw unavailable(e, HISTORY_ACTIONS.create, deps.scope); }
    return v;
  };
  const prepare = async (r: ConfigRestoreRequest) => {
    store();
    if (!r.actor || !isGuid(r.actor.oid) || r.actor.canWrite !== true) throw new ApiError(403, "write_permission_required");
    historyScope(r.projectId); assertVersionId(r.version);
    if (typeof r.ifMatch !== "string" || !r.ifMatch.trim() || r.ifMatch.trim() === "*") throw new ApiError(428, "if_match_required");
    if (typeof r.reason !== "string" || !r.reason.trim() || r.reason.length > 500 || /[\u0000-\u001f\u007f]/.test(r.reason)) {
      throw new ApiError(400, "history_reason_invalid");
    }
    const current = await deps.projects.read(r.projectId);
    if (!current) throw new ApiError(404, "project_not_found");
    if (current.doc.projectId !== r.projectId || current.doc.id !== r.projectId) throw new ApiError(409, "project_identity_mismatch");
    if (current.etag !== r.ifMatch) throw new ApiError(412, "etag_mismatch");
    if (current.doc.status !== "active" || current.doc.retiredAt !== null) throw new ApiError(409, "project_retired");
    const snapshot = await read(r.projectId, r.version), beforeConfig = projectConfig(current.doc);
    const target = snapshot.config;
    const beforeClasses = beforeConfig.classifications as Doc, targetClasses = target.classifications as Doc;
    if (canonical(Object.keys(beforeClasses).sort()) !== canonical(Object.keys(targetClasses).sort()) ||
      Object.keys(beforeClasses).some((k) => (beforeClasses[k] as Doc).groupId !== (targetClasses[k] as Doc).groupId ||
        (beforeClasses[k] as Doc).classificationGroupDisplayName !== (targetClasses[k] as Doc).classificationGroupDisplayName)) {
      throw new ApiError(409, "history_classification_identity_mismatch");
    }
    // Merge reviewed configuration only; live non-configuration state is never copied from history.
    const beforeEditable = { ...beforeConfig }, targetEditable = { ...target };
    delete beforeEditable.failover; delete targetEditable.failover;
    const after = overlayConfig(current.doc, beforeEditable, targetEditable) as Doc;
    const primaryChanged = after.backendId !== current.doc.backendId;
    const prior = isObject(current.doc.failover) ? current.doc.failover : null;
    if (primaryChanged && prior?.enabled === true) throw new ValidationError(["backendId:disable_failover_first"]);
    const desired = isObject(target.failover) ? target.failover : { enabled: false, fallbackBackendIds: [] };
    let requiresPublication = false;
    if (prior || isObject(target.failover)) {
      if (desired.enabled && !deps.registry) throw new ApiError(503, "registry_unavailable");
      const base = structuredClone(after);
      if (primaryChanged && prior) base.failover = { ...prior, revision: Number(prior.revision) + 1, active: null };
      let registry;
      try { registry = desired.enabled === true && deps.registry ? await registryMap(deps.registry) : new Map(); }
      catch (e) { throw unavailable(e, HISTORY_ACTIONS.query, deps.scope); }
      const next = failoverAfterEdit(base, desired, registry);
      // Unlike ordinary enable/disable, a restore may never reuse a verification as fresh approval.
      if (desired.enabled && prior && Number(next.revision) <= Number(prior.revision)) next.revision = Number(prior.revision) + 1;
      after.failover = next;
      requiresPublication = desired.enabled === true;
    }
    // Validate the entire configuration through the existing project/settings/model-budget contract.
    const validation: Doc = { ...projectConfig(after), status: after.status, supersedes: after.supersedes, retiredAt: after.retiredAt };
    if (after.failover !== undefined) validation.failover = after.failover;
    assertValidProject(validation);
    const preview: ConfigRestorePreview = { projectId: r.projectId, version: r.version, ifMatch: current.etag,
      reason: r.reason.trim(), changes: diff(beforeConfig, projectConfig(after)), requiresPublication };
    // Revision is live configuration too: show the publication invalidation even when desired fields match.
    preview.changes.push(...diff(current.doc.failover, after.failover, "failover").filter((d) => d.path === "failover.revision"));
    return { current, after, preview };
  };
  return {
    async capability() {
      const prerequisites = [
        { action: HISTORY_ACTIONS.read, scope: deps.projectScope },
        { action: "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace", scope: deps.projectScope },
      ];
      if (!deps.enabled) return { state: "disabled", requirements: [], prerequisites };
      if (!deps.scope || !deps.projectScope) return { state: "unavailable", reason: "history_scope_not_configured", requirements: [], prerequisites: [] };
      if (!deps.changeLog) return { state: "unavailable", reason: "change_log_unavailable",
        requirements: [{ action: HISTORY_ACTIONS.create, scope: deps.scope }], prerequisites };
      try {
        await store(HISTORY_ACTIONS.create).probe();
        return { state: "available", requirements: [], prerequisites };
      } catch (e) {
        const failure = unavailable(e, HISTORY_ACTIONS.create, deps.scope);
        const denied = failure instanceof ConfigHistoryUnavailable && failure.permissionRequired ||
          (e as { code?: number; statusCode?: number })?.code === 403 || (e as { statusCode?: number })?.statusCode === 403;
        return { state: denied ? "permission_required" : "unavailable", reason: failure.code,
          requirements: failure instanceof ConfigHistoryUnavailable ? failure.requirements : [], prerequisites };
      }
    },
    capture,
    read,
    async list(projectId: string, limit = 20) {
      const versions = store(HISTORY_ACTIONS.query); historyScope(projectId);
      if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new ApiError(400, "invalid_history_limit");
      let rows;
      try { rows = await versions.list(projectId, limit); } catch (e) { throw unavailable(e, HISTORY_ACTIONS.query, deps.scope); }
      return rows.map((r) => {
        const v = assertSnapshot(r, projectId);
        return { id: v.id, projectId: v.projectId, hash: v.hash, capturedAt: v.capturedAt };
      });
    },
    async preview(r: ConfigRestoreRequest): Promise<ConfigRestorePreview> { return (await prepare(r)).preview; },
    async restore(r: ConfigRestoreRequest): Promise<ConfigRestoreResult> {
      const requestId = r.requestId ?? deps.newId();
      if (typeof requestId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(requestId)) throw new ApiError(400, "history_request_id_invalid");
      let outcome = "refused", code: string | undefined;
      try {
        const { current, after, preview } = await prepare(r);
        if (!deps.changeLog) throw new ConfigHistoryUnavailable(HISTORY_ACTIONS.create, deps.scope, "change_log_unavailable");
        const pending = await beginChange(deps.changeLog, { requestId, at: deps.now().toISOString(), actorOid: r.actor!.oid,
          operation: "v3/projects/history/restore", projectId: r.projectId, changes: preview.changes,
          details: { reason: preview.reason, version: r.version, etagBefore: current.etag } }, deps.now, deps.log)
          .catch(() => { throw new ConfigHistoryUnavailable(HISTORY_ACTIONS.create, deps.scope, "change_log_unavailable"); });
        try {
          await capture(current.doc);
          const recorded = await capture(after);
          let etag: string;
          try { etag = await deps.projects.replace(after, current.etag); } catch (e) {
            outcome = "unconfirmed"; await pending.finish(outcome, { code: "project_write_unconfirmed" }); throw e;
          }
          if (etag === "precondition_failed") {
            await pending.finish("refused", { code: "etag_mismatch" }); throw new ApiError(412, "etag_mismatch");
          }
          outcome = "updated";
          await pending.finish(outcome, { etagAfter: etag, recordedVersion: recorded.id });
          return { ...preview, project: structuredClone(after), etag, recordedVersion: recorded.id };
        } catch (e) {
          if (outcome === "refused") await pending.finish("refused", { code: e instanceof ApiError ? e.code : "history_capture_failed" });
          throw e;
        }
      } catch (e) {
        code = e instanceof ApiError ? e.code : "history_restore_unavailable";
        throw e;
      } finally {
        deps.log(JSON.stringify({ schema: "ccof.admin.audit.v1", at: deps.now().toISOString(), requestId,
          operation: "v3/projects/history/restore", actorOid: r.actor?.oid ?? null, projectId: r.projectId,
          outcome, ...(code ? { code } : {}) }));
      }
    },
  };
}

export interface OptionalConfigHistory {
  enabled: boolean;
  versions: ConfigHistoryStore | null;
  scope: string;
  projectScope: string;
  now(): Date;
  onUnavailable(error: ConfigHistoryUnavailable): void;
}
// Wrap the ONE ProjectStore injected into all API versions, including routing publication/retirement.
// Best-effort capture has no authority to block an existing mandatory-audit-protected write.
export function withConfigHistory(projects: ProjectStore, options: OptionalConfigHistory): ProjectStore {
  if (!options.enabled) return projects;
  const report = (error: unknown, action: string, scope = options.scope) => {
    try { options.onUnavailable(error instanceof ConfigHistoryUnavailable ? error : new ConfigHistoryUnavailable(action, scope)); }
    catch { /* Optional diagnostics cannot break old writes. */ }
  };
  const capture = async (doc: Doc) => {
    try {
      if (!options.versions) throw new ConfigHistoryUnavailable(HISTORY_ACTIONS.create, options.scope);
      await options.versions.create(configSnapshot(doc, options.now()));
    } catch (e) { report(e, HISTORY_ACTIONS.create); }
  };
  return {
    list: () => projects.list(),
    ...(projects.listPage ? { listPage: (q: Parameters<NonNullable<ProjectStore["listPage"]>>[0]) => projects.listPage!(q) } : {}),
    read: (id) => projects.read(id),
    async create(doc) {
      const result = await projects.create(doc);
      if (result !== "conflict") await capture(doc);
      return result;
    },
    async replace(doc, etag) {
      try {
        const before = await projects.read(String(doc.projectId));
        if (before && before.etag === etag) await capture(before.doc);
      } catch (e) { report(e, HISTORY_ACTIONS.read, options.projectScope); }
      const result = await projects.replace(doc, etag);
      if (result !== "precondition_failed") await capture(doc);
      return result;
    },
  };
}
