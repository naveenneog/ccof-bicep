// The project admin API, framework-free so it is tested with a fake store and fake clock.
// Phase 1 operations only: list, read, create, replace a classification's family policy (models and
// limits) and patch its limits. Project id, groups, backend, budgets and status are not editable here;
// deletion, rename, group replacement and backend moves are deliberately absent (docs/ADMIN-API.md).
// Every write requires the stored ETag (If-Match) and emits one ccof.admin.audit.v1 line.

import { ApiError } from "./auth.ts";
import type { Actor, Authenticator } from "./auth.ts";
import { ValidationError, applyLimitPatch, assertValidFamilyPolicy, assertValidProject, canonical, isIdentifier, isObject, stripSystem } from "./validation.ts";
import type { Doc } from "./validation.ts";

export const AUDIT_SCHEMA = "ccof.admin.audit.v1";
export const MAX_BODY_BYTES = 64 * 1024;

export interface StoredProject {
  doc: Doc;
  etag: string;
}

export interface ProjectStore {
  list(): Promise<StoredProject[]>;
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
  log(line: string): void;
  now(): Date;
  newId(): string;
}

type Route =
  | { op: "list" }
  | { op: "read"; projectId: string }
  | { op: "create" }
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
): Promise<{ response: ApiResponse; audit: Record<string, unknown> }> {
  const etag = requireIfMatch(request);
  const body = parseBody(request);
  const current = await store.read(r.projectId);
  if (!current) throw new ApiError(404, "project_not_found");
  if (current.etag !== etag) throw new ApiError(412, "etag_mismatch");
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
  const written = await store.replace(after, etag);
  if (written === "precondition_failed") throw new ApiError(412, "etag_mismatch");
  return {
    response: json(200, { projectId: r.projectId, changed: true, project: after }, { etag: written }),
    audit: { outcome: "updated", classification: r.code, etagBefore: etag, etagAfter: written, changes: changed },
  };
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
  try {
    if (!deps.authenticate) throw new ApiError(503, "admin_auth_not_configured");
    actor = await deps.authenticate(request.headers("authorization"));
    if (matched === null) throw new ApiError(404, "route_not_found");
    if (matched === "method_not_allowed") throw new ApiError(405, "method_not_allowed");
    operation = matched.op;
    projectId = "projectId" in matched ? matched.projectId : undefined;
    const writes = matched.op === "create" || matched.op === "familyPolicy" || matched.op === "limits";
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
        projectId = String(doc.projectId);
        const written = await store.create(doc);
        if (written === "conflict") throw new ApiError(409, "project_exists");
        audit({ outcome: "created", etagAfter: written, classifications: Object.keys(doc.classifications as Doc).sort() });
        return json(201, doc, { etag: written, location: `/api/projects/${encodeURIComponent(projectId)}` });
      }
      case "familyPolicy": {
        const result = await classificationUpdate(store, request, matched, (_policy, body) => {
          if (!isObject(body)) throw new ValidationError(["familyPolicy:invalid"]);
          return structuredClone(body);
        });
        audit(result.audit);
        return result.response;
      }
      case "limits": {
        const result = await classificationUpdate(store, request, matched, (policy, body) => applyLimitPatch(policy, body));
        audit(result.audit);
        return result.response;
      }
    }
  } catch (err) {
    if (err instanceof ApiError) {
      const isWriteAttempt = operation === "create" || operation === "familyPolicy" || operation === "limits";
      if (isWriteAttempt || err.status === 401 || err.status === 403) audit({ outcome: "refused", status: err.status, code: err.code });
      const body: Record<string, unknown> = { error: err.code, requestId };
      if (err instanceof ValidationError) body.problems = err.problems;
      return json(err.status, body);
    }
    audit({ outcome: "failed", status: 500, code: "internal_error" });
    return json(500, { error: "internal_error", requestId });
  }
}
