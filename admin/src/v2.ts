import { ApiError } from "./auth.ts";
import { createHash } from "node:crypto";
import type { Authenticator } from "./auth.ts";
import type { ApiRequest, ApiResponse, ProjectStore } from "./api.ts";
import { canonical, isIdentifier, isObject, stripSystem } from "./validation.ts";
import type { Doc } from "./validation.ts";
import { parseRateCard } from "../../src/cost/rate-card.ts";
import { ccuToUsd } from "../../src/cost/budget-units.ts";
import { Money } from "../../src/cost/money.ts";
import type { Capability, Operations } from "./operations.ts";
import { ADMIN_VERSION } from "./version.ts";
export const MAX_CATALOG_BYTES = 1024 * 1024;
const DECIMAL_TEXT = /^\d{1,30}(\.\d{1,30})?$/;

// Group budget roll-up from the reconciler's own ccof.reconciler.budget.v1 group lines.
// Exact decimals; 100 CCU = USD 1 (src/cost/budget-units.ts). Rows that are malformed are
// counted, never guessed. Totals are lower bounds whenever any group is partial or stale.
export function summarizeGroupBudgets(rows: unknown[], now: Date): Doc {
  const groups: Doc[] = [];
  let rejected = 0;
  let spent = new Money(0);
  let cappedBudget = new Money(0);
  let cappedSpent = new Money(0);
  let uncapped = 0, stale = 0, partial = 0, exhausted = 0;
  for (const row of rows) {
    if (!isObject(row) || row.scope !== "group" || typeof row.projectId !== "string" || typeof row.classification !== "string" ||
      typeof row.spentCcu !== "string" || !DECIMAL_TEXT.test(row.spentCcu) ||
      row.budgetCcu !== null && (typeof row.budgetCcu !== "string" || !DECIMAL_TEXT.test(row.budgetCcu))) { rejected++; continue; }
    const s = new Money(row.spentCcu);
    const b = row.budgetCcu === null ? null : new Money(row.budgetCcu);
    const validUntil = typeof row.validUntil === "string" ? Date.parse(row.validUntil) : NaN;
    const fresh = Number.isFinite(validUntil) && validUntil > now.getTime();
    const complete = row.completeness === "complete";
    spent = spent.plus(s);
    if (b) { cappedBudget = cappedBudget.plus(b); cappedSpent = cappedSpent.plus(s); } else uncapped++;
    if (!fresh) stale++;
    if (!complete) partial++;
    if (row.exhausted === true) exhausted++;
    groups.push({
      projectId: row.projectId, classification: row.classification, scopeId: row.scopeId ?? null, mode: row.mode ?? null,
      spentCcu: s.toFixed(), spentUsd: ccuToUsd(s).toFixed(2),
      budgetCcu: b ? b.toFixed() : null, budgetUsd: b ? ccuToUsd(b).toFixed(2) : null,
      remainingCcu: b ? b.minus(s).toFixed() : null, remainingUsd: b ? ccuToUsd(b.minus(s)).toFixed(2) : null,
      usedPercent: b && b.gt(0) ? s.dividedBy(b).times(100).toFixed(1) : null,
      exhausted: row.exhausted === true, completeness: complete ? "complete" : "partial", fresh,
      activeMemberCount: typeof row.activeMemberCount === "number" ? row.activeMemberCount : null,
      rateCardVersion: row.rateCardVersion ?? null, period: row.period ?? null,
      computedAt: row.computedAt ?? null, validUntil: row.validUntil ?? null, observedAt: row.observedAt ?? null,
    });
  }
  groups.sort((a, b) => Number(b.usedPercent ?? -1) - Number(a.usedPercent ?? -1) || String(a.projectId).localeCompare(String(b.projectId)));
  return {
    groups,
    totals: {
      groups: groups.length, spentCcu: spent.toFixed(), spentUsd: ccuToUsd(spent).toFixed(2),
      cappedBudgetCcu: cappedBudget.toFixed(), cappedBudgetUsd: ccuToUsd(cappedBudget).toFixed(2),
      cappedSpentCcu: cappedSpent.toFixed(),
      cappedUsedPercent: cappedBudget.gt(0) ? cappedSpent.dividedBy(cappedBudget).times(100).toFixed(1) : null,
      uncappedGroups: uncapped, staleGroups: stale, partialGroups: partial, exhaustedGroups: exhausted, rejectedRows: rejected,
      lowerBound: stale > 0 || partial > 0 || rejected > 0,
    },
    basis: "Reconciler month-to-date calculation at the approved rate card (100 CCU = USD 1); not an Azure invoice. Partial, stale or rejected observations make totals a lower bound.",
  };
}

export const BUDGET_PAGE_DEFAULT = 100;
export const BUDGET_PAGE_MAX = 500;
export interface BudgetQuery { search: string; projectId: string; minUsedPercent: number | null; onlyAttention: boolean; limit: number; offset: number }
// Bounded, validated query so tens of thousands of access groups never reach the browser at once.
export function readBudgetQuery(params: URLSearchParams): BudgetQuery {
  const search = (params.get("search") ?? "").trim();
  const projectId = (params.get("projectId") ?? "").trim();
  const minRaw = params.get("minUsedPercent");
  const limitRaw = params.get("limit");
  const offsetRaw = params.get("offset");
  const minUsedPercent = minRaw === null || minRaw === "" ? null : Number(minRaw);
  const limit = limitRaw === null || limitRaw === "" ? BUDGET_PAGE_DEFAULT : Number(limitRaw);
  const offset = offsetRaw === null || offsetRaw === "" ? 0 : Number(offsetRaw);
  if (search.length > 100 || projectId.length > 80 ||
    minUsedPercent !== null && (!Number.isFinite(minUsedPercent) || minUsedPercent < 0 || minUsedPercent > 10000) ||
    !Number.isInteger(limit) || limit < 1 || limit > BUDGET_PAGE_MAX || !Number.isInteger(offset) || offset < 0 || offset > 1_000_000) {
    throw new ApiError(400, "invalid_budget_query");
  }
  return { search: search.toLowerCase(), projectId, minUsedPercent, onlyAttention: params.get("attention") === "true", limit, offset };
}
// Totals always cover every group; `matched` and the page reflect the filter. Rows keep the roll-up's order (highest use first).
export function pageGroupBudgets(summary: Doc, query: BudgetQuery): Doc {
  const all = Array.isArray(summary.groups) ? summary.groups as Doc[] : [];
  const matched = all.filter((g) =>
    (!query.projectId || g.projectId === query.projectId) &&
    (!query.search || `${g.projectId} ${g.classification}`.toLowerCase().includes(query.search)) &&
    (query.minUsedPercent === null || g.usedPercent !== null && Number(g.usedPercent) >= query.minUsedPercent) &&
    (!query.onlyAttention || g.exhausted === true || g.fresh !== true || g.completeness !== "complete"));
  const groups = matched.slice(query.offset, query.offset + query.limit);
  const next = query.offset + groups.length;
  return {
    ...summary, groups,
    page: { offset: query.offset, limit: query.limit, returned: groups.length, matched: matched.length, total: all.length, nextOffset: next < matched.length ? next : null },
  };
}

export interface CatalogStore {
  read(): Promise<{ doc: Doc; etag: string } | null>;
  save(doc: Doc, etag: string | null): Promise<string | null>;
}
export interface V2Dependencies {
  authenticate: Authenticator | null;
  projects: ProjectStore | null;
  catalogStore: CatalogStore | null;
  // Null when the packaged rate card could not be read; only cost definitions degrade.
  defaultCatalog: Doc | null;
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
      const history = current?.doc.rateCard ?? deps.defaultCatalog?.rateCard;
      if (history !== undefined) validateRateHistory(history, doc.rateCard);
      const match = request.headers("if-match");
      if (current && (!match || match === "*")) throw new ApiError(428, "if_match_required");
      if (current && current.etag !== match || !current && request.headers("if-none-match") !== "*") throw new ApiError(412, "etag_mismatch");
      const etag = await deps.catalogStore.save(doc, current?.etag ?? null);
      if (!etag) throw new ApiError(412, "etag_mismatch");
      const before = current?.doc ?? deps.defaultCatalog ?? { models: [] };
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
      // V3 filters: every listed tag must be present (comma-separated, up to 10) and the classification must exist.
      const tags = (url.searchParams.get("tags") ?? "").split(",").map((t) => t.trim()).filter(Boolean);
      const classification = url.searchParams.get("classification") ?? "";
      if (tags.length > 10 || tags.some((t) => t.length > 60) || classification && !isIdentifier(classification)) throw new ApiError(400, "invalid_project_query");
      if (search.length > 200 || tag.length > 60 || backendId.length > 80 || !Number.isInteger(limit) || limit < 1 || limit > 100 ||
        cursor && cursor.length > 24000) throw new ApiError(400, "invalid_project_query");
      if (!deps.projects.listPage) throw new ApiError(503, "paged_project_store_required");
      const page = await deps.projects.listPage({ search, tag, backendId, limit, cursor, ...(tags.length ? { tags } : {}), ...(classification ? { classification } : {}) });
      return response(200, { projects: page.items.map((p) => ({ ...stripSystem(p.doc), etag: p.etag })), cursor: page.cursor ?? null });
    }
    if (path === "catalog") {
      const current = deps.catalogStore ? await deps.catalogStore.read() : null;
      if (!current && !deps.defaultCatalog) {
        return response(200, { state: "unavailable", reason: "packaged_rate_card_unavailable", observedAt: deps.now().toISOString(),
          permission: "Redeploy the admin package (ui-dist/rate-card.json) or save a catalog with ADMIN_CONFIG_CONTAINER configured." });
      }
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
      case "budgets": {
        const query = readBudgetQuery(url.searchParams);
        cap = await deps.operations.logs("budgets");
        if ((cap.state === "available" || cap.state === "partial") && Array.isArray(cap.data)) {
          cap = { ...cap, data: pageGroupBudgets(summarizeGroupBudgets(cap.data, deps.now()), query) };
        }
        break;
      }
      case "audit": cap = await deps.operations.logs("audit"); break;
      case "runs": cap = await deps.operations.logs("runs"); break;
      case "health": cap = await deps.operations.health(); break;
      case "prices": cap = await deps.operations.retail(); break;
      case "billed-cost": cap = await deps.operations.billed(); break;
      case "version": return response(200, { version: ADMIN_VERSION, api: "v2", projectApi: "v1-compatible" });
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
