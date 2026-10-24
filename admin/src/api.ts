// The project admin API, framework-free so it is tested with a fake store and fake clock.
// Core project operations plus v2 reviewed settings (tags, one backend/subscription and budgets).
// Project ids and group ids are not editable. Status changes only through retire (active to retired,
// one way); deletion and group replacement remain absent.
// Every write requires the stored ETag (If-Match) and emits one ccof.admin.audit.v1 line.

import { ApiError } from "./auth.ts";
import type { Actor, Authenticator } from "./auth.ts";
import { ValidationError, applyLimitPatch, assertValidFamilyPolicy, assertValidProject, canonical, isIdentifier, isObject, stripSystem } from "./validation.ts";
import type { Doc } from "./validation.ts";
import { beginChange } from "./change-log.ts";
import type { ChangeEntry, ChangeLog, PendingChange } from "./change-log.ts";

export const AUDIT_SCHEMA = "ccof.admin.audit.v1";
export const MAX_BODY_BYTES = 64 * 1024;

export interface StoredProject {
  doc: Doc;
  etag: string;
}

export interface ProjectStore {
  list(): Promise<StoredProject[]>;
  listPage?(query: { search: string; tag: string; backendId: string; limit: number; cursor?: string; tags?: string[]; classification?: string }): Promise<{ items: StoredProject[]; cursor?: string }>;
  read(projectId: string): Promise<StoredProject | null>;
  // The new ETag, or "conflict" when a document with this id exists.
  create(doc: Doc): Promise<string | "conflict">;
  // The new ETag, or "precondition_failed" when the stored ETag differs or the document is gone.
  replace(doc: Doc, etag: string): Promise<string | "precondition_failed">;
}

export interface ApiRequest {
  method: string;
  path: string;
  headers: (name: string) => string | null;
  body: string | null;
}

export interface ApiResponse {
  status: number;
  headers?: Record<string, string>;
  jsonBody?: unknown;
}

export interface ApiDependencies {
  authenticate: Authenticator | null; // null: authentication is not configured, so every request is refused
  store: ProjectStore | null; // null: storage is not configured
  // The permanent change record (adminConfig); when configured, a change it cannot record is refused.
  changeLog?: ChangeLog | null;
  log(line: string): void;
  now(): Date;
  newId(): string;
}

type Route =
  | { op: "list" }
  | { op: "read"; projectId: string }
  | { op: "create" }
  | { op: "settings"; projectId: string }
  | { op: "retire"; projectId: string }
  | { op: "familyPolicy"; projectId: string; code: string }
  | { op: "limits"; projectId: string; code: string };

function route(method: string, path: string): Route | "method_not_allowed" | null {
  const parts = path.replace(/^\/+|\/+$/g, "").split("/");
  if (parts[0] === "api") parts.shift();
  if (parts[0] !== "projects") return null;
  const m = method.toUpperCase();
  if (parts.length === 1) return m === "GET" ? { op: "list" } : m === "POST" ? { op: "create" } : "method_not_allowed";
  const projectId = decodeURIComponent(parts[1] ?? "");
  if (!isIdentifier(projectId)) return null;
  if (parts.length === 2) return m === "GET" ? { op: "read", projectId } : "method_not_allowed";
  if (parts.length === 3 && parts[2] === "settings") return m === "PUT" ? { op: "settings", projectId } : "method_not_allowed";
  if (parts.length === 3 && parts[2] === "retire") return m === "POST" ? { op: "retire", projectId } : "method_not_allowed";
  if (parts.length === 5 && parts[2] === "classifications" && isIdentifier(parts[3])) {
    if (parts[4] === "family-policy") return m === "PUT" ? { op: "familyPolicy", projectId, code: parts[3] } : "method_not_allowed";
    if (parts[4] === "limits") return m === "PATCH" ? { op: "limits", projectId, code: parts[3] } : "method_not_allowed";
  }
  return null;
}

const json = (status: number, jsonBody: unknown, headers: Record<string, string> = {}): ApiResponse =>
  ({ status, jsonBody, headers: { "content-type": "application/json", "cache-control": "no-store", ...headers } });

function parseBody(request: ApiRequest): unknown {
  if (request.body === null || request.body === "") throw new ApiError(400, "body_required");
  if (Buffer.byteLength(request.body, "utf8") > MAX_BODY_BYTES) throw new ApiError(413, "body_too_large");
  try {
    return JSON.parse(request.body);
  } catch {
    throw new ApiError(400, "body_not_json");
  }
}

function requireIfMatch(request: ApiRequest): string {
  const value = request.headers("if-match")?.trim();
  if (!value || value === "*") throw new ApiError(428, "if_match_required");
  return value;
}

function summary(p: StoredProject) {
  const d = p.doc;
  return {
    projectId: d.projectId,
    displayName: d.displayName,
    status: d.status,
    backendId: d.backendId,
    adminTags: d.adminTags ?? [],
    classifications: isObject(d.classifications) ? Object.keys(d.classifications).sort() : [],
    etag: p.etag,
  };
}

// Changed leaf paths with before and after values; limits and model names are configuration, not secrets.
function changes(before: unknown, after: unknown, path: string, out: { path: string; before: unknown; after: unknown }[]) {
  if (isObject(before) && isObject(after)) {
    for (const key of [...new Set([...Object.keys(before), ...Object.keys(after)])].sort()) changes(before[key], after[key], path ? `${path}.${key}` : key, out);
    return out;
  }
  if (canonical(before) !== canonical(after)) out.push({ path, before: before ?? null, after: after ?? null });
  return out;
}

async function classificationUpdate(
  store: ProjectStore,
  request: ApiRequest,
  r: { projectId: string; code: string },
  update: (currentPolicy: Doc, body: unknown) => Doc,
  begin: (changed: ChangeEntry[], details: Doc) => Promise<PendingChange>,
): Promise<{ response: ApiResponse; audit: Record<string, unknown> }> {
  const etag = requireIfMatch(request);
  const body = parseBody(request);
  const current = await store.read(r.projectId);
  if (!current) throw new ApiError(404, "project_not_found");
  if (current.etag !== etag) throw new ApiError(412, "etag_mismatch");
  if (current.doc.status === "retired") throw new ApiError(409, "project_retired");
  const before = stripSystem(current.doc);
  const classifications = before.classifications;
  if (!isObject(classifications) || !isObject(classifications[r.code])) throw new ApiError(404, "classification_not_found");
  const beforePolicy = (classifications[r.code] as Doc).familyPolicy as Doc;
  const nextPolicy = update(structuredClone(beforePolicy), body);
  assertValidFamilyPolicy(nextPolicy, r.code);
  const after = structuredClone(before);
  ((after.classifications as Doc)[r.code] as Doc).familyPolicy = nextPolicy;
  assertValidProject(after);
  const changed = changes(beforePolicy, nextPolicy, `classifications.${r.code}.familyPolicy`, []);
  if (changed.length === 0) {
    return { response: json(200, { projectId: r.projectId, changed: false, project: before }, { etag: current.etag }), audit: { outcome: "unchanged" } };
  }
  const pending = await begin(changed, { classification: r.code, etagBefore: etag });
  const written = await recorded(pending, () => store.replace(after, etag));
  if (written === "precondition_failed") { await pending.finish("refused", { code: "etag_mismatch" }); throw new ApiError(412, "etag_mismatch"); }
  await pending.finish("updated", { etagAfter: written });
  return {
    response: json(200, { projectId: r.projectId, changed: true, project: after }, { etag: written }),
    audit: { outcome: "updated", classification: r.code, etagBefore: etag, etagAfter: written, changes: changed },
  };
}

// A write that throws (timeout, lost connection, 503) may still have committed in Cosmos, so the record
// says "unconfirmed", never "failed". Definite refusals (ETag, conflict) are recorded as "refused".
async function recorded<T>(pending: PendingChange, write: () => Promise<T>): Promise<T> {
  try { return await write(); } catch (err) {
    await pending.finish("unconfirmed", { code: err instanceof ApiError ? err.code : "write_failed" });
    throw err;
  }
}

// A registry failure (no network path, missing data role, Cosmos outage) is reported as 503
// registry_unavailable with no provider detail; the cause belongs in the app's own logs.
function guardStore(store: ProjectStore): ProjectStore {
  const guard = <A extends unknown[], R>(work: (...args: A) => Promise<R>) => async (...args: A): Promise<R> => {
    try {
      return await work(...args);
    } catch (err) {
      if (err instanceof ApiError) throw err;
      throw new ApiError(503, "registry_unavailable");
    }
  };
  return {
    list: guard(() => store.list()),
    read: guard((id: string) => store.read(id)),
    create: guard((doc: Doc) => store.create(doc)),
    replace: guard((doc: Doc, etag: string) => store.replace(doc, etag)),
  };
}

export async function handleAdminRequest(request: ApiRequest, deps: ApiDependencies): Promise<ApiResponse> {
  const requestId = deps.newId();
  const matched = route(request.method, request.path);
  let actor: Actor | null = null;
  let operation = "unknown";
  let projectId: string | undefined;
  const audit = (fields: Record<string, unknown>) =>
    deps.log(JSON.stringify({ schema: AUDIT_SCHEMA, at: deps.now().toISOString(), requestId, operation, actorOid: actor?.oid ?? null, projectId: projectId ?? null, ...fields }));
  const begin = (changed: ChangeEntry[], details: Doc = {}) => beginChange(deps.changeLog, {
    requestId, at: deps.now().toISOString(), actorOid: actor?.oid ?? "", operation, projectId: projectId ?? null, changes: changed, details,
  }, deps.now, deps.log);
  try {
    if (!deps.authenticate) throw new ApiError(503, "admin_auth_not_configured");
    actor = await deps.authenticate(request.headers("authorization"));
    if (matched === null) throw new ApiError(404, "route_not_found");
    if (matched === "method_not_allowed") throw new ApiError(405, "method_not_allowed");
    operation = matched.op;
    projectId = "projectId" in matched ? matched.projectId : undefined;
    const writes = matched.op === "create" || matched.op === "familyPolicy" || matched.op === "limits" || matched.op === "settings" || matched.op === "retire";
    if (writes && !actor.canWrite) throw new ApiError(403, "write_permission_required");
    if (!deps.store) throw new ApiError(503, "project_store_not_configured");
    const store = guardStore(deps.store);

    switch (matched.op) {
      case "list": {
        const items = (await store.list()).map(summary).sort((a, b) => String(a.projectId).localeCompare(String(b.projectId)));
        return json(200, { projects: items });
      }
      case "read": {
        const found = await store.read(matched.projectId);
        if (!found) throw new ApiError(404, "project_not_found");
        return json(200, stripSystem(found.doc), { etag: found.etag });
      }
      case "create": {
        const doc = assertValidProject(parseBody(request));
        if (doc.status !== "active") throw new ValidationError(["status:not_active"]);
        // ADR 0034: failover is set only through PUT /api/v3/projects/{id}/failover and verified publication.
        if (Object.hasOwn(doc, "failover")) throw new ValidationError(["failover:use_failover_endpoint"]);
        projectId = String(doc.projectId);
        const pending = await begin(changes({}, doc, "", []));
        const written = await recorded(pending, () => store.create(doc));
        if (written === "conflict") { await pending.finish("refused", { code: "project_exists" }); throw new ApiError(409, "project_exists"); }
        await pending.finish("created", { etagAfter: written });
        audit({ outcome: "created", etagAfter: written, classifications: Object.keys(doc.classifications as Doc).sort() });
        return json(201, doc, { etag: written, location: `/api/projects/${encodeURIComponent(projectId)}` });
      }
      case "settings": {
        const etag = requireIfMatch(request);
        const body = parseBody(request);
        if (!isObject(body) || Object.keys(body).some((key) => !["adminTags", "displayName", "backendId", "designatedSubscriptionId", "budgets"].includes(key)) ||
          Object.keys(body).length === 0) throw new ValidationError(["settings:invalid"]);
        const current = await store.read(matched.projectId);
        if (!current) throw new ApiError(404, "project_not_found");
        if (current.etag !== etag) throw new ApiError(412, "etag_mismatch");
        if (current.doc.status === "retired") throw new ApiError(409, "project_retired");
        const before = stripSystem(current.doc);
        const after = structuredClone(before);
        if (body.backendId !== undefined && body.backendId !== before.backendId && !Object.hasOwn(body, "designatedSubscriptionId")) {
          throw new ValidationError(["designatedSubscriptionId:required_for_backend_change"]);
        }
        for (const key of ["adminTags", "displayName", "backendId", "designatedSubscriptionId"]) if (Object.hasOwn(body, key)) after[key] = body[key];
        // ADR 0034: a verified pool names the old primary, so a primary change while failover is on is
        // refused; with failover off the pool is forgotten and a later enable needs a new publication.
        if (after.backendId !== before.backendId && isObject(before.failover)) {
          if (before.failover.enabled === true) throw new ValidationError(["backendId:disable_failover_first"]);
          after.failover = { ...before.failover, revision: Number(before.failover.revision) + 1, active: null };
        }
        if (body.adminTags === null || Array.isArray(body.adminTags) && body.adminTags.length === 0) delete after.adminTags;
        if (body.budgets !== undefined) {
          if (!isObject(body.budgets) || !isObject(after.classifications)) throw new ValidationError(["budgets:invalid"]);
          for (const [code, budget] of Object.entries(body.budgets)) {
            const classification = after.classifications[code];
            if (!isObject(classification) || !isObject(budget) ||
              Object.keys(budget).some((key) => !["personBudget", "aggregateBudget", "aggregateMode"].includes(key))) {
              throw new ValidationError(["budgets:invalid"]);
            }
            Object.assign(classification, budget);
          }
        }
        assertValidProject(after);
        const changed = changes(before, after, "", []);
        if (!changed.length) return json(200, { changed: false, project: before }, { etag });
        const pending = await begin(changed, { etagBefore: etag });
        const written = await recorded(pending, () => store.replace(after, etag));
        if (written === "precondition_failed") { await pending.finish("refused", { code: "etag_mismatch" }); throw new ApiError(412, "etag_mismatch"); }
        await pending.finish("updated", { etagAfter: written });
        audit({ outcome: "updated", etagBefore: etag, etagAfter: written, changes: changed });
        return json(200, { changed: true, project: after }, { etag: written });
      }
      case "retire": {
        // One-way: the sync then removes every membership of the project at its next run. The body must
        // repeat the project id, so a stale or mistaken click cannot retire another project.
        const etag = requireIfMatch(request);
        const body = parseBody(request);
        if (!isObject(body) || Object.keys(body).length !== 1 || body.confirmProjectId !== matched.projectId) {
          throw new ValidationError(["confirmProjectId:must_equal_projectId"]);
        }
        const current = await store.read(matched.projectId);
        if (!current) throw new ApiError(404, "project_not_found");
        if (current.etag !== etag) throw new ApiError(412, "etag_mismatch");
        if (current.doc.status === "retired") throw new ApiError(409, "project_retired");
        const before = stripSystem(current.doc);
        const after = { ...structuredClone(before), status: "retired", retiredAt: deps.now().toISOString() };
        assertValidProject(after);
        const pending = await begin(changes(before, after, "", []), { etagBefore: etag });
        const written = await recorded(pending, () => store.replace(after, etag));
        if (written === "precondition_failed") { await pending.finish("refused", { code: "etag_mismatch" }); throw new ApiError(412, "etag_mismatch"); }
        await pending.finish("retired", { etagAfter: written });
        audit({ outcome: "retired", etagBefore: etag, etagAfter: written, changes: changes(before, after, "", []) });
        return json(200, { changed: true, project: after }, { etag: written });
      }
      case "familyPolicy": {
        const result = await classificationUpdate(store, request, matched, (_policy, body) => {
          if (!isObject(body)) throw new ValidationError(["familyPolicy:invalid"]);
          return structuredClone(body);
        }, begin);
        audit(result.audit);
        return result.response;
      }
      case "limits": {
        const result = await classificationUpdate(store, request, matched, (policy, body) => applyLimitPatch(policy, body), begin);
        audit(result.audit);
        return result.response;
      }
    }
  } catch (err) {
    if (err instanceof ApiError) {
      const isWriteAttempt = operation === "create" || operation === "familyPolicy" || operation === "limits" || operation === "settings" || operation === "retire";
      if (isWriteAttempt || err.status === 401 || err.status === 403) audit({ outcome: "refused", status: err.status, code: err.code });
      const body: Record<string, unknown> = { error: err.code, requestId };
      if (err instanceof ValidationError) body.problems = err.problems;
      return json(err.status, body);
    }
    audit({ outcome: "failed", status: 500, code: "internal_error" });
    return json(500, { error: "internal_error", requestId });
  }
}
