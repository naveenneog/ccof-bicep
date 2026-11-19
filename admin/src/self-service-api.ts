import { ApiError } from "./auth.ts";
import type { Authenticator } from "./auth.ts";
import type { ApiRequest, ApiResponse, ProjectStore } from "./api.ts";
import { beginChange } from "./change-log.ts";
import type { ChangeLog } from "./change-log.ts";
import { isIdentifier, isObject, ValidationError } from "./validation.ts";
import type { Doc } from "./validation.ts";
import { enqueueOperation, findOperation } from "./self-service-jobs.ts";
import type { DurableJob, EnqueueInput, JobStore } from "./self-service-jobs.ts";
import type { FeatureCapability, OperationJob } from "./self-service-contracts.ts";

export interface HistoryAccess {
  capability(): Promise<FeatureCapability>;
  list(projectId: string): Promise<unknown>;
  preview(projectId: string, versionId: string, actorOid: string): Promise<unknown>;
  restore(input: { projectId: string; versionId: string; etag: string; actorOid: string; reason: string; requestId: string }): Promise<{ project: Doc; etag: string }>;
}
export interface SelfServiceDependencies {
  authenticate: Authenticator | null;
  projects: Pick<ProjectStore, "read"> | null;
  jobs: JobStore | null;
  changeLog: ChangeLog | null;
  storageScope: string;
  features: Partial<Record<OperationJob["kind"], { capability(): Promise<FeatureCapability> }>>;
  history?: HistoryAccess | null;
  now(): Date;
  newId(): string;
  log(line: string): void;
}
const json = (status: number, jsonBody: unknown, headers: Record<string, string> = {}): ApiResponse =>
  ({ status, jsonBody, headers: { "content-type": "application/json", "cache-control": "no-store", ...headers } });
const disabled = (): FeatureCapability => ({ state: "disabled", reason: "feature_not_configured", requirements: [] });
const unavailable = (): FeatureCapability => ({ state: "unavailable", reason: "feature_unavailable", requirements: [] });
const storagePermission = (scope: string): FeatureCapability => ({
  state: "permission_required", reason: "operation_store_permission_required",
  requirements: [
    "Microsoft.DocumentDB/databaseAccounts/readMetadata",
    ...["items/read", "items/create", "items/replace", "executeQuery"].map((action) => `Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/${action}`),
  ].map((action) => ({ action, scope })),
});
async function operationStorage(deps: SelfServiceDependencies): Promise<FeatureCapability> {
  if (!deps.jobs) return { ...unavailable(), reason: "operation_store_not_configured" };
  if (!deps.changeLog) return { ...unavailable(), reason: "change_log_not_configured" };
  try { await deps.jobs.probe?.(); return { state: "available", requirements: [] }; } catch (error) {
    return Number((error as { code?: unknown })?.code) === 403 ? storagePermission(deps.storageScope) : unavailable();
  }
}
const publicJob = (job: DurableJob) => ({
  id: job.id, kind: job.kind, projectId: job.projectId, state: job.state, phase: job.phase,
  createdAt: job.createdAt, updatedAt: job.updatedAt, expiresAt: job.expiresAt,
  reasonCode: job.reasonCode, requirements: job.requirements, result: job.result,
});
const safeCapability = async (feature: { capability(): Promise<FeatureCapability> } | null | undefined) => {
  try { return feature ? await feature.capability() : disabled(); } catch { return unavailable(); }
};

function bodyOf(request: ApiRequest): Doc {
  if (!request.body) throw new ApiError(400, "body_required");
  if (Buffer.byteLength(request.body) > 4096) throw new ApiError(413, "body_too_large");
  let value: unknown;
  try { value = JSON.parse(request.body); } catch { throw new ApiError(400, "body_not_json"); }
  if (!isObject(value)) throw new ApiError(400, "invalid_operation_request");
  return value;
}
function etagOf(request: ApiRequest) {
  const value = request.headers("if-match")?.trim();
  if (!value || value === "*" || value.length > 256 || /[\r\n]/.test(value)) throw new ApiError(428, "if_match_required");
  return value;
}
function reasonOf(body: Doc) {
  if (typeof body.reason !== "string" || body.reason.trim().length < 5 || body.reason.length > 500 || /[\x00-\x1f\x7f]/.test(body.reason)) {
    throw new ApiError(400, "operation_reason_required");
  }
  return body.reason.trim();
}

// Separate from the existing V3 dispatcher: a missing optional module cannot change unrelated routes.
export async function handleSelfServiceRequest(request: ApiRequest, deps: SelfServiceDependencies): Promise<ApiResponse | null> {
  const path = request.path.split("?")[0];
  const root = path === "/api/v3/self-service/capabilities";
  const jobMatch = /^\/api\/v3\/self-service\/jobs\/([a-f0-9]{64})$/.exec(path);
  const projectMatch = /^\/api\/v3\/projects\/([^/]+)\/(operations|history)(?:\/([^/]+)\/(preview|restore))?$/.exec(path);
  if (!root && !jobMatch && !projectMatch) return null;
  const requestId = deps.newId();
  let operation = "self_service_read";
  try {
    if (!deps.authenticate) throw new ApiError(503, "admin_auth_not_configured");
    const actor = await deps.authenticate(request.headers("authorization"));
    const method = request.method.toUpperCase();
    if (method !== "GET" && !actor.canWrite) throw new ApiError(403, "write_permission_required");
    if (root) {
      if (method !== "GET") throw new ApiError(405, "method_not_allowed");
      const [routing, apply, history] = await Promise.all([
        safeCapability(deps.features["publish-routing"]), safeCapability(deps.features.apply), safeCapability(deps.history),
      ]);
      const storage = routing.state === "available" || apply.state === "available" ? await operationStorage(deps) : null;
      return json(200, {
        "publish-routing": storage && storage.state !== "available" && routing.state === "available" ? storage : routing,
        apply: storage && storage.state !== "available" && apply.state === "available" ? storage : apply,
        history,
      });
    }
    if (jobMatch) {
      if (method !== "GET") throw new ApiError(405, "method_not_allowed");
      if (!deps.jobs) throw new ApiError(503, "operation_store_not_configured");
      const stored = await deps.jobs.read(jobMatch[1]);
      if (!stored) throw new ApiError(404, "operation_not_found");
      return json(200, publicJob(stored.job));
    }
    const [, encodedId, section, versionId, action] = projectMatch!;
    let projectId: string;
    try { projectId = decodeURIComponent(encodedId); } catch { throw new ApiError(400, "invalid_project_id"); }
    if (!isIdentifier(projectId)) throw new ApiError(400, "invalid_project_id");
    if (section === "operations") {
      operation = "self_service_enqueue";
      if (versionId || method !== "POST") throw new ApiError(405, "method_not_allowed");
      const expectedEtag = etagOf(request);
      const body = bodyOf(request);
      if (Object.keys(body).some((key) => key !== "kind" && key !== "reason") || body.kind !== "apply" && body.kind !== "publish-routing") {
        throw new ApiError(400, "invalid_operation_request");
      }
      const reason = reasonOf(body);
      const key = request.headers("idempotency-key")?.trim();
      if (!key || !/^[a-zA-Z0-9._:-]{8,128}$/.test(key)) throw new ApiError(400, "idempotency_key_required");
      if (!deps.jobs) throw new ApiError(503, "operation_store_not_configured");
      const input: EnqueueInput = { kind: body.kind, projectId, expectedEtag, actorOid: actor.oid, reason, key };
      const replay = await findOperation(deps.jobs, input);
      if (replay) return json(202, publicJob(replay), { location: `/api/v3/self-service/jobs/${replay.id}` });
      const capability = await safeCapability(deps.features[body.kind]);
      if (capability.state !== "available") return json(capability.state === "permission_required" ? 403 : 409, { error: "feature_unavailable", capability, requestId });
      const storage = await operationStorage(deps);
      if (storage.state !== "available") return json(storage.state === "permission_required" ? 403 : 503, { error: "feature_unavailable", capability: storage, requestId });
      if (!deps.projects) throw new ApiError(503, "project_store_not_configured");
      const current = await deps.projects.read(projectId);
      if (!current) throw new ApiError(404, "project_not_found");
      if (current.etag !== expectedEtag) throw new ApiError(412, "etag_mismatch");
      if (current.doc.status === "retired") throw new ApiError(409, "project_retired");
      if (!deps.changeLog) throw new ApiError(503, "change_log_not_configured");
      const pending = await beginChange(deps.changeLog, {
        requestId, at: deps.now().toISOString(), actorOid: actor.oid, operation, projectId, changes: [],
        details: { kind: body.kind, reason, etagBefore: expectedEtag },
      }, deps.now, deps.log);
      try {
        const job = await enqueueOperation(deps.jobs, input, deps.now());
        await pending.finish("queued", { operationId: job.id });
        return json(202, publicJob(job), { location: `/api/v3/self-service/jobs/${job.id}` });
      } catch (error) {
        await pending.finish("unconfirmed", { code: "operation_enqueue_unconfirmed" });
        throw error;
      }
    }
    if (!deps.history) throw new ApiError(404, "feature_not_configured");
    const capability = await safeCapability(deps.history);
    if (capability.state !== "available") return json(capability.state === "permission_required" ? 403 : 409, { error: "feature_unavailable", capability, requestId });
    if (!versionId) {
      if (method !== "GET") throw new ApiError(405, "method_not_allowed");
      return json(200, await deps.history.list(projectId));
    }
    if (!/^[a-zA-Z0-9._:-]{1,128}$/.test(versionId)) throw new ApiError(400, "invalid_version_id");
    if (method !== "POST") throw new ApiError(405, "method_not_allowed");
    if (action === "preview") return json(200, await deps.history.preview(projectId, versionId, actor.oid));
    operation = "configuration_restore";
    const etag = etagOf(request);
    const body = bodyOf(request);
    if (Object.keys(body).some((key) => key !== "reason")) throw new ApiError(400, "invalid_operation_request");
    const result = await deps.history.restore({ projectId, versionId, etag, actorOid: actor.oid, reason: reasonOf(body), requestId });
    return json(200, { project: result.project }, { etag: result.etag });
  } catch (error) {
    const statusCode = Number((error as { code?: unknown; statusCode?: unknown })?.statusCode ?? (error as { code?: unknown })?.code);
    const conflict = error instanceof Error && error.message === "idempotency_conflict";
    const permissionDenied = (error as { permissionRequired?: unknown })?.permissionRequired === true;
    const status = permissionDenied ? 403 : error instanceof ApiError ? error.status : error instanceof ValidationError ? 400 : conflict ? 409 : statusCode === 403 ? 403 : 503;
    const code = error instanceof ApiError ? error.code : error instanceof ValidationError ? "invalid_configuration" : conflict ? "idempotency_conflict" : "self_service_unavailable";
    const required = (error as { requirements?: unknown })?.requirements;
    const requirements = Array.isArray(required) ? required.filter((item) =>
      isObject(item) && typeof item.action === "string" && typeof item.scope === "string",
    ) : [];
    const capability = status === 403 && requirements.length
      ? { state: "permission_required", reason: code, requirements }
      : statusCode === 403 ? storagePermission(deps.storageScope) : null;
    deps.log(JSON.stringify({ schema: "ccof.admin.operation.api.v1", requestId, operation, status, code }));
    return json(status, {
      error: code, requestId,
      ...(capability ? { capability } : {}),
    });
  }
}
