import { ApiError } from "./auth.ts";
import { createHash } from "node:crypto";
import type { Authenticator } from "./auth.ts";
import type { ApiRequest, ApiResponse, ProjectStore } from "./api.ts";
import { canonical, isIdentifier, isObject, stripSystem } from "./validation.ts";
import type { Doc } from "./validation.ts";
import { parseRateCard } from "../../src/cost/rate-card.ts";
import type { Capability, Operations } from "./operations.ts";
export const MAX_CATALOG_BYTES = 1024 * 1024;

export interface CatalogStore {
  read(): Promise<{ doc: Doc; etag: string } | null>;
  save(doc: Doc, etag: string | null): Promise<string | null>;
}
export interface V2Dependencies {
  authenticate: Authenticator | null;
  projects: ProjectStore | null;
  catalogStore: CatalogStore | null;
  defaultCatalog: Doc;
  operations: Operations;
  now(): Date;
  newId(): string;
  log(line: string): void;
}
export function validateCatalog(value: unknown): Doc {
  if (!isObject(value) || value.schemaVersion !== 1 || !Array.isArray(value.models) ||
    value.models.length > 2000 || Object.keys(value).some((key) => !["schemaVersion", "models", "rateCard"].includes(key))) {
    throw new ApiError(422, "invalid_catalog");
  }
  try { parseRateCard(value.rateCard); } catch { throw new ApiError(422, "invalid_rate_card"); }
  const mappings = new Set<string>();
  for (const model of value.models) {
    if (!isObject(model) || Object.keys(model).some((key) => !["family", "model", "deployment", "backendId"].includes(key)) ||
      !isIdentifier(model.family) || typeof model.model !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/.test(model.model) ||
      typeof model.deployment !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/.test(model.deployment) ||
      typeof model.backendId !== "string" || model.backendId !== "" && !isIdentifier(model.backendId)) throw new ApiError(422, "invalid_model_mapping");
    const key = `${model.backendId}/${model.deployment}`;
    if (mappings.has(key)) throw new ApiError(422, "duplicate_deployment_mapping");
    mappings.add(key);
  }
  return structuredClone(value);
}
export function validateRateHistory(before: unknown, after: unknown): void {
  if (!isObject(before) || !isObject(after) || !Array.isArray(before.entries) || !Array.isArray(after.entries)) throw new ApiError(422, "invalid_rate_card");
  if (canonical(before) === canonical(after)) return;
  if (canonical(before.rateUnit) !== canonical(after.rateUnit)) throw new ApiError(422, "historical_rate_unit_edit_forbidden");
  if (before.version === after.version) throw new ApiError(422, "rate_card_version_must_change");
  for (const old of before.entries) {
    if (!isObject(old)) throw new ApiError(422, "invalid_rate_card");
    const next = after.entries.find((e) => isObject(e) && e.model === old.model && e.effectiveFrom === old.effectiveFrom);
    if (!isObject(next) || canonical({ ...next, effectiveTo: old.effectiveTo }) !== canonical(old) ||
      old.effectiveTo !== null && next.effectiveTo !== old.effectiveTo) throw new ApiError(422, "historical_rate_edit_forbidden");
  }
}
const response = (status: number, data: unknown, headers: Record<string, string> = {}): ApiResponse =>
  ({ status, jsonBody: data, headers: { "cache-control": "no-store", "content-type": "application/json", ...headers } });
export async function handleV2Request(request: ApiRequest, deps: V2Dependencies): Promise<ApiResponse> {
  const requestId = deps.newId();
  let actorOid: string | null = null;
  const url = new URL(request.path, "https://admin.invalid");
  const path = url.pathname.replace(/^\/api\/v2\/?/, "");
  const audit = (outcome: string, fields: Doc = {}) => deps.log(JSON.stringify({
    schema: "ccof.admin.audit.v1", at: deps.now().toISOString(), requestId, actorOid,
    operation: `v2/${path}`, outcome, ...fields,
  }));
  try {
    if (!deps.authenticate) throw new ApiError(503, "admin_auth_not_configured");
    const actor = await deps.authenticate(request.headers("authorization"));
    actorOid = actor.oid;
    if (path === "catalog" && request.method === "PUT") {
      if (!actor.canWrite) throw new ApiError(403, "write_permission_required");
      if (!deps.catalogStore) throw new ApiError(503, "catalog_store_not_configured");
      if (!request.body || Buffer.byteLength(request.body) > MAX_CATALOG_BYTES) throw new ApiError(413, "catalog_body_required_or_too_large");
      let value: unknown;
      try { value = JSON.parse(request.body); } catch { throw new ApiError(400, "body_not_json"); }
      const doc = validateCatalog(value);
      const current = await deps.catalogStore.read();
      validateRateHistory(current?.doc.rateCard ?? deps.defaultCatalog.rateCard, doc.rateCard);
      const match = request.headers("if-match");
      if (current && (!match || match === "*")) throw new ApiError(428, "if_match_required");
      if (current && current.etag !== match || !current && request.headers("if-none-match") !== "*") throw new ApiError(412, "etag_mismatch");
      const etag = await deps.catalogStore.save(doc, current?.etag ?? null);
      if (!etag) throw new ApiError(412, "etag_mismatch");
      const before = current?.doc ?? deps.defaultCatalog;
      const oldModels = new Map((Array.isArray(before.models) ? before.models : []).filter(isObject).map((m) => [`${m.backendId}/${m.deployment}`, m]));
      const newModels = new Map((doc.models as Doc[]).map((m) => [`${m.backendId}/${m.deployment}`, m]));
      const mappingChanges = [...new Set([...oldModels.keys(), ...newModels.keys()])].filter((key) => canonical(oldModels.get(key)) !== canonical(newModels.get(key)))
        .map((key) => ({ path: `models.${key}`, before: oldModels.get(key) ?? null, after: newModels.get(key) ?? null }));
      audit("updated", {
        version: isObject(doc.rateCard) ? doc.rateCard.version : null, modelCount: (doc.models as unknown[]).length,
        changes: mappingChanges.slice(0, 20), changesTruncated: mappingChanges.length > 20,
        contentDigestBefore: createHash("sha256").update(canonical(before)).digest("hex"),
        contentDigestAfter: createHash("sha256").update(canonical(doc)).digest("hex"),
      });
      return response(200, { catalog: doc, editable: true, source: "admin_catalog", enforcement: "Export the rate card to update reconciler pricing; catalog edits do not change deployed enforcement." }, { etag });
    }
    if (request.method !== "GET") throw new ApiError(405, "method_not_allowed");
    if (path === "projects") {
      if (!deps.projects) throw new ApiError(503, "project_store_not_configured");
      const search = url.searchParams.get("search") ?? "";
      const tag = url.searchParams.get("tag") ?? "";
      const backendId = url.searchParams.get("backendId") ?? "";
      const limit = Number(url.searchParams.get("limit") ?? "50");
      const cursor = url.searchParams.get("cursor") ?? undefined;
      if (search.length > 200 || tag.length > 60 || backendId.length > 80 || !Number.isInteger(limit) || limit < 1 || limit > 100 ||
        cursor && cursor.length > 24000) throw new ApiError(400, "invalid_project_query");
      if (!deps.projects.listPage) throw new ApiError(503, "paged_project_store_required");
      const page = await deps.projects.listPage({ search, tag, backendId, limit, cursor });
      return response(200, { projects: page.items.map((p) => ({ ...stripSystem(p.doc), etag: p.etag })), cursor: page.cursor ?? null });
    }
    if (path === "catalog") {
      const current = deps.catalogStore ? await deps.catalogStore.read() : null;
      return response(200, {
        catalog: current ? { schemaVersion: current.doc.schemaVersion, models: current.doc.models, rateCard: current.doc.rateCard } : deps.defaultCatalog,
        editable: Boolean(deps.catalogStore && actor.canWrite),
        source: current ? "admin_catalog" : "packaged_rate_card",
        reason: deps.catalogStore ? null : "ADMIN_CONFIG_CONTAINER and a scoped Cosmos data role are required to save cost definitions.",
        enforcement: "Catalog definitions drive console dropdowns. Reconciler pricing remains separately versioned; export and deploy the approved rate card.",
      }, current ? { etag: current.etag } : {});
    }
    let cap: Capability;
    switch (path) {
      case "groups": cap = await deps.operations.groups(url.searchParams.get("q") ?? ""); break;
      case "inventory": cap = await deps.operations.inventory(); break;
      case "deployments": cap = await deps.operations.deployments(url.searchParams.get("resourceId") ?? ""); break;
      case "budgets": cap = await deps.operations.logs("budgets"); break;
      case "audit": cap = await deps.operations.logs("audit"); break;
      case "runs": cap = await deps.operations.logs("runs"); break;
      case "health": cap = await deps.operations.health(); break;
      case "prices": cap = await deps.operations.retail(); break;
      case "billed-cost": cap = await deps.operations.billed(); break;
      case "version": return response(200, { version: "2.0.0", api: "v2", projectApi: "v1-compatible" });
      default: throw new ApiError(404, "route_not_found");
    }
    return response(200, cap);
  } catch (err) {
    const status = err instanceof ApiError ? err.status : 503;
    const code = err instanceof ApiError ? err.code : "integration_or_registry_unavailable";
    if (request.method !== "GET" || status === 401 || status === 403) audit("refused", { status, code });
    else deps.log(JSON.stringify({ schema: "ccof.admin.integration.v2", operation: path, status, code, requestId }));
    return response(status, { error: code, requestId });
  }
}
