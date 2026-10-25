// V3 API (/api/v3/*): chargeback views, reconciler runs and budget snapshots, audit search, the
// budget-to-token plan and rate-card review. Read-only: nothing here writes enforcement or settings.
// Every optional integration reports its own capability state, so one missing permission disables
// only its own feature. Authentication and the read/write split are the same as v1/v2.

import { ApiError, isGuid } from "./auth.ts";
import type { Authenticator } from "./auth.ts";
import type { ApiRequest, ApiResponse, ProjectStore } from "./api.ts";
import { canonical, isIdentifier, isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";
import type { Capability, Operations, QueryMeta } from "./operations.ts";
import { ProviderError } from "./operations.ts";
import type { CatalogStore } from "./v2.ts";
import { ADMIN_VERSION } from "./version.ts";
import { PlanError, planBudget } from "./token-planner.ts";
import type { TrafficMix } from "./token-planner.ts";
import { FAMILIES, planModels, reviewRateCard } from "./rate-cards.ts";
import {
  buildAuditQuery, buildChargebackQuery, buildRunsQuery, buildSnapshotQuery, CHARGEBACK_VIEWS, prepareRateCard, QueryCache,
  readAuditFilters, readAuditSettings, readChargebackFilters, readChargebackSettings, readReconcilerSettings, readSnapshotFilters,
  shapeRows, shapeRun, shapeSnapshot, tableRows, TAG_PROJECTS_MAX,
} from "./chargeback.ts";
import { buildClientFiles, readClientSettings } from "./client-config.ts";
import type { ChargebackView, Configured, QuerySources } from "./chargeback.ts";
import type { GroupMetadata } from "../../analytics/workbooks/chargeback-queries.ts";
import { ccuToUsdText, DECIMAL_TEXT } from "./units.ts";
import { readUserIds } from "./user-directory.ts";
import type { UserDirectory } from "./user-directory.ts";
import { auditRow, beginChange } from "./change-log.ts";
import type { ChangeLog } from "./change-log.ts";
import { limitsFromBody, MAX_OVERRIDE_DAYS, overrideState, publicLimits } from "./sync-limits.ts";
import type { LimitsStore } from "./sync-limits.ts";
import { stripSystem, ValidationError } from "./validation.ts";
import { failoverAfterEdit, publicEntry, registryEntryFromBody, registryMap, routingPlan, routingState } from "./backend-routing.ts";
import type { RegistryStore } from "./backend-routing.ts";
import { poolBackendIdFor } from "../../src/contracts/project-routing.ts";

export const MAX_PLAN_BYTES = 16 * 1024;
export const MAX_RATE_CARD_BYTES = 1024 * 1024;
export const LIST_PRICE_BASIS = "List price at the approved rate card (100 CCU = USD 1); not an Azure invoice.";

export interface V3Dependencies {
  authenticate: Authenticator | null;
  projects: ProjectStore | null;
  catalogStore: CatalogStore | null;
  // Both live in the adminConfig container; null when ADMIN_CONFIG_CONTAINER is not set.
  changeLog?: ChangeLog | null;
  limitsStore?: LimitsStore | null;
  // ADR 0034 backend registry (adminConfig); null when ADMIN_CONFIG_CONTAINER is not set.
  registry?: RegistryStore | null;
  defaultCatalog: Doc | null;
  operations: Operations;
  directory?: UserDirectory;
  env: Readonly<Record<string, string | undefined>>;
  // The packaged KQL sources (ledger.kql, pricing.kql, budgets.kql); null when the package lacks them.
  sources: QuerySources | null;
  cache: QueryCache;
  now(): Date;
  newId(): string;
  log(line: string): void;
}

const response = (status: number, data: unknown): ApiResponse =>
  ({ status, jsonBody: data, headers: { "cache-control": "no-store", "content-type": "application/json" } });

async function currentRateCard(deps: V3Dependencies): Promise<{ rateCard: Doc; source: "admin_catalog" | "packaged_rate_card" } | null> {
  const saved = deps.catalogStore ? await deps.catalogStore.read() : null;
  if (saved && isObject(saved.doc.rateCard)) return { rateCard: saved.doc.rateCard, source: "admin_catalog" };
  if (deps.defaultCatalog && isObject(deps.defaultCatalog.rateCard)) return { rateCard: deps.defaultCatalog.rateCard, source: "packaged_rate_card" };
  return null;
}

function parseJson(body: string | null, max: number): unknown {
  if (!body) throw new ApiError(400, "body_required");
  if (Buffer.byteLength(body) > max) throw new ApiError(413, "body_too_large");
  try { return JSON.parse(body); } catch { throw new ApiError(400, "body_not_json"); }
}

const num = (v: unknown, name: string) => {
  if (typeof v !== "number" || !Number.isFinite(v)) throw new PlanError(`${name}: number required`);
  return v;
};

// Validates the plan request and resolves rates from the current rate card; pure, no writes.
export function planFromRequest(body: unknown, rateCard: Doc, now: Date) {
  if (!isObject(body)) throw new PlanError("body: object required");
  const allowed = ["budgetBasis", "monthlyBudget", "groupMonthlyBudget", "geography", "sizing", "mix", "families", "workingDaysPerMonth", "workingHoursPerDay", "burstFactor"];
  if (Object.keys(body).some((k) => !allowed.includes(k))) throw new PlanError("body: unknown field");
  if (body.budgetBasis !== "person") throw new PlanError("budgetBasis: person required; no member-count assumption");
  const budget = body.monthlyBudget;
  if (!isObject(budget) || typeof budget.amount !== "string" || !DECIMAL_TEXT.test(budget.amount) || (budget.currency !== "USD" && budget.currency !== "CCU")) {
    throw new PlanError("monthlyBudget: { amount: decimal text, currency: USD | CCU } required");
  }
  const usd = budget.currency === "CCU" ? ccuToUsdText(budget.amount) : budget.amount;
  const group = body.groupMonthlyBudget;
  if (group != null && (!isObject(group) || typeof group.amount !== "string" || !DECIMAL_TEXT.test(group.amount) ||
    group.currency !== "USD" && group.currency !== "CCU")) throw new PlanError("groupMonthlyBudget: decimal amount and USD | CCU required");
  const groupUsd = isObject(group) ? group.currency === "CCU" ? ccuToUsdText(String(group.amount)) : String(group.amount) : null;
  const geography = body.geography ?? "global";
  if (typeof geography !== "string" || !/^[a-z][a-z0-9_-]{0,19}$/.test(geography)) throw new PlanError("geography: invalid");
  if (body.sizing !== "expected" && body.sizing !== "guaranteed") throw new PlanError("sizing: expected | guaranteed required");
  const m = body.mix;
  if (!isObject(m)) throw new PlanError("mix: object required");
  const mix: TrafficMix = {
    outputPercentOfTokens: num(m.outputPercentOfTokens, "mix.outputPercentOfTokens"),
    cacheReadPercentOfInput: num(m.cacheReadPercentOfInput, "mix.cacheReadPercentOfInput"),
    cacheWrite5mPercentOfInput: num(m.cacheWrite5mPercentOfInput, "mix.cacheWrite5mPercentOfInput"),
    cacheWrite1hPercentOfInput: num(m.cacheWrite1hPercentOfInput, "mix.cacheWrite1hPercentOfInput"),
  };
  if (!Array.isArray(body.families) || body.families.length < 1 || body.families.length > FAMILIES.length) throw new PlanError("families: 1 to 5 required");
  const models = planModels(rateCard, now);
  const seen = new Set<string>();
  let geoMultiplier: number | null = null;
  const families = body.families.map((f, i) => {
    if (!isObject(f) || typeof f.family !== "string" || !(FAMILIES as readonly string[]).includes(f.family)) throw new PlanError(`families[${i}].family: invalid`);
    if (seen.has(f.family)) throw new PlanError(`families[${i}].family: duplicate`);
    seen.add(f.family);
    const candidates = models.filter((x) => x.family === f.family && (f.model === undefined || x.model === f.model));
    const chosen = candidates[0];
    if (!chosen) throw new PlanError(`families[${i}]: no in-force rate for ${String(f.model ?? f.family)}`);
    const multiplier = chosen.geos[geography];
    if (multiplier === undefined) throw new PlanError(`families[${i}]: ${chosen.model} is not priced for geography ${geography}`);
    if (geoMultiplier !== null && geoMultiplier !== Number(multiplier)) throw new PlanError("geography: models carry different multipliers; plan them separately");
    geoMultiplier = Number(multiplier);
    return { family: f.family, model: chosen.model, budgetPercent: num(f.budgetPercent, `families[${i}].budgetPercent`), rates: chosen.rates, worstRates: chosen.worstRates };
  });
  const plan = planBudget({
    personMonthlyBudgetUsd: usd, groupMonthlyBudgetUsd: groupUsd, geoMultiplier: geoMultiplier ?? 1, sizing: body.sizing, mix, families,
    workingDaysPerMonth: body.workingDaysPerMonth === undefined ? undefined : num(body.workingDaysPerMonth, "workingDaysPerMonth"),
    workingHoursPerDay: body.workingHoursPerDay === undefined ? undefined : num(body.workingHoursPerDay, "workingHoursPerDay"),
    burstFactor: body.burstFactor === undefined ? undefined : num(body.burstFactor, "burstFactor"),
  });
  return { plan, budgetBasis: "person", budgetUsd: usd, groupBudgetUsd: groupUsd, geography, geoMultiplier: String(geoMultiplier ?? 1), rates: families.map(({ family, model, rates }) => ({ family, model, rates })) };
}

async function capability(deps: V3Dependencies, cfg: Configured<unknown>, name: string, run: () => Promise<unknown>): Promise<Capability> {
  const observedAt = deps.now().toISOString();
  if (!cfg.ok) return { state: "disabled", reason: cfg.reason, permission: cfg.permission, observedAt };
  if (!deps.operations.query) return { state: "unavailable", reason: "query_runner_unavailable", observedAt };
  if (!deps.sources) return { state: "unavailable", reason: "packaged_queries_unavailable", permission: "Redeploy the admin package (kql/ folder)", observedAt };
  try {
    const data = await run();
    return { state: isObject(data) && data.truncated === true ? "partial" : "available", observedAt, data };
  } catch (err) {
    if (err instanceof ApiError) throw err;
    const status = err instanceof ProviderError ? err.status : null;
    deps.log(JSON.stringify({ schema: "ccof.admin.integration.v2", capability: name, status, code: err instanceof ProviderError ? err.code : "request_failed" }));
    return { state: status === 401 || status === 403 ? "permission_required" : "unavailable", reason: err instanceof ProviderError ? err.code : "request_failed", permission: cfg.permission, observedAt };
  }
}

async function groupMetadata(deps: V3Dependencies, projectId: string): Promise<GroupMetadata[]> {
  if (!projectId || !deps.projects) return [];
  const found = await deps.projects.read(projectId).catch(() => null);
  if (!found || !isObject(found.doc.classifications)) return [];
  return Object.entries(found.doc.classifications).filter(([, c]) => isObject(c) && isGuid(c.groupId)).map(([code, c]) => {
    const name = (c as Doc).classificationGroupDisplayName;
    return { projectId, classification: code, groupId: String((c as Doc).groupId), displayName: typeof name === "string" && name.length > 0 && name.length <= 256 ? name : null };
  });
}

// Registry tags → project IDs (all tags must match). Ledger rows carry no tags, so this is how a
// tag filter reaches the chargeback query. A larger match than TAG_PROJECTS_MAX is refused.
async function projectsForTags(deps: V3Dependencies, tags: string[]): Promise<string[]> {
  if (!deps.projects?.listPage) throw new ApiError(503, "project_store_not_configured");
  const ids: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await deps.projects.listPage({ search: "", tag: "", backendId: "", tags, limit: 100, cursor });
    for (const p of page.items) if (typeof p.doc.projectId === "string") ids.push(p.doc.projectId);
    if (ids.length > TAG_PROJECTS_MAX) throw new ApiError(400, "tag_matches_too_many_projects");
    cursor = page.cursor;
  } while (cursor);
  return [...new Set(ids)].sort();
}

class LimitsInvalid extends ApiError {
  readonly problems: string[];
  constructor(problems: string[]) { super(422, "invalid_removal_limits"); this.problems = problems; }
}

export async function handleV3Request(request: ApiRequest, deps: V3Dependencies): Promise<ApiResponse> {
  const requestId = deps.newId();
  const url = new URL(request.path, "https://admin.invalid");
  const path = url.pathname.replace(/^\/api\/v3\/?/, "");
  const method = request.method.toUpperCase();
  let actorOid: string | null = null;
  try {
    if (!deps.authenticate) throw new ApiError(503, "admin_auth_not_configured");
    const actor = await deps.authenticate(request.headers("authorization"));
    actorOid = actor.oid;
    if (path === "directory/users") {
      if (method !== "POST") throw new ApiError(405, "method_not_allowed");
      if ([...url.searchParams].length) throw new ApiError(400, "unknown_parameter");
      const ids = readUserIds(parseJson(request.body, MAX_PLAN_BYTES));
      if (!deps.directory) return response(200, { state: "unavailable", reason: "user_directory_unavailable", observedAt: deps.now().toISOString() });
      return response(200, await deps.directory.lookup(ids, deps.log, request.headers("x-ccof-refresh") === "true"));
    }
    if (path === "version" && method === "GET") return response(200, { version: ADMIN_VERSION, api: "v3", consoles: ["v2", "v3"], projectApi: "v1-compatible" });
    if (path === "capabilities" && method === "GET") {
      const cb = readChargebackSettings(deps.env), rec = readReconcilerSettings(deps.env), au = readAuditSettings(deps.env);
      const state = (c: Configured<unknown>) => c.ok ? "configured" : c.reason;
      return response(200, {
        canWrite: actor.canWrite, observedAt: deps.now().toISOString(),
        features: {
          projects: deps.projects ? "configured" : "project_store_not_configured",
          chargeback: state(cb), reconciler: state(rec), audit: state(au), queries: deps.sources ? "packaged" : "packaged_queries_unavailable",
          catalogStore: deps.catalogStore ? "configured" : "ADMIN_CONFIG_CONTAINER_not_set",
          changeLog: deps.changeLog ? "configured" : "ADMIN_CONFIG_CONTAINER_not_set",
          removalLimits: deps.limitsStore ? "configured" : "ADMIN_CONFIG_CONTAINER_not_set",
          backendRegistry: deps.registry ? "configured" : "ADMIN_CONFIG_CONTAINER_not_set",
          userNames: deps.env.ADMIN_USER_NAMES_ENABLED === "true" ? "configured" : "ADMIN_USER_NAMES_ENABLED_not_set",
        },
      });
    }
    if (path === "plan") {
      const card = await currentRateCard(deps);
      if (!card) throw new ApiError(503, "rate_card_unavailable");
      if (method === "GET") {
        return response(200, { rateCardVersion: card.rateCard.version ?? null, rateCardSource: card.source, models: planModels(card.rateCard, deps.now()) });
      }
      if (method !== "POST") throw new ApiError(405, "method_not_allowed");
      try {
        const result = planFromRequest(parseJson(request.body, MAX_PLAN_BYTES), card.rateCard, deps.now());
        return response(200, { ...result, rateCardVersion: card.rateCard.version ?? null, rateCardSource: card.source,
          note: "Suggested values only. Review them in the change review before saving; a token quota cannot cap dollars exactly." });
      } catch (err) {
        if (err instanceof PlanError) return response(422, { error: "invalid_plan_request", detail: err.message, requestId });
        throw err;
      }
    }
    if (path === "rate-card/review") {
      if (method !== "POST") throw new ApiError(405, "method_not_allowed");
      const candidate = parseJson(request.body, MAX_RATE_CARD_BYTES);
      const card = await currentRateCard(deps);
      const review = reviewRateCard(card?.rateCard ?? null, candidate, deps.now());
      return response(200, { review, basedOn: card ? { version: card.rateCard.version ?? null, source: card.source } : null });
    }
    if (path === "sync/removal-limits") {
      if ([...url.searchParams].length) throw new ApiError(400, "unknown_parameter");
      const current = deps.limitsStore ? await deps.limitsStore.read() : null;
      if (method === "GET") {
        return response(200, {
          limits: publicLimits(current?.doc ?? null), etag: current?.etag ?? null, state: overrideState(current?.doc ?? null, deps.now()),
          editable: Boolean(deps.limitsStore && actor.canWrite), maxOverrideDays: MAX_OVERRIDE_DAYS,
          reason: deps.limitsStore ? null : "ADMIN_CONFIG_CONTAINER and a scoped Cosmos data role are required to save removal limits.",
          fallback: "Without an enabled, unexpired override the sync uses its app settings SYNC_MAX_REMOVALS_PER_RUN and SYNC_MAX_REMOVAL_FRACTION.",
          appliesWhen: "The sync reads this document at the start of each run when SYNC_LIMITS_CONTAINER is set on the sync app.",
          observedAt: deps.now().toISOString(),
        });
      }
      if (method !== "PUT") throw new ApiError(405, "method_not_allowed");
      if (!actor.canWrite) throw new ApiError(403, "write_permission_required");
      if (!deps.limitsStore) throw new ApiError(503, "limits_store_not_configured");
      let doc: Doc;
      try { doc = limitsFromBody(parseJson(request.body, MAX_PLAN_BYTES), actor.oid, deps.now()); } catch (err) {
        throw err instanceof ValidationError ? new LimitsInvalid(err.problems) : err;
      }
      const match = request.headers("if-match");
      if (current && (!match || match === "*")) throw new ApiError(428, "if_match_required");
      if (current && current.etag !== match || !current && request.headers("if-none-match") !== "*") throw new ApiError(412, "etag_mismatch");
      const before = publicLimits(current?.doc ?? null) ?? {};
      const changed = ["enabled", "maxRemovalsPerRun", "maxRemovalFraction", "expiresAt", "reason"]
        .filter((k) => canonical(before[k] ?? null) !== canonical(doc[k] ?? null)).map((k) => ({ path: k, before: before[k] ?? null, after: doc[k] ?? null }));
      const pending = await beginChange(deps.changeLog, { requestId, at: deps.now().toISOString(), actorOid: actor.oid, operation: "v3/sync/removal-limits",
        projectId: null, changes: changed, details: { etagBefore: current?.etag ?? null } }, deps.now, deps.log);
      let etag: string | null;
      try { etag = await deps.limitsStore.save(doc, current?.etag ?? null); } catch (err) { await pending.finish("unconfirmed", { code: "write_failed" }); throw err; }
      if (!etag) { await pending.finish("refused", { code: "etag_mismatch" }); throw new ApiError(412, "etag_mismatch"); }
      await pending.finish("updated", { etagAfter: etag });
      deps.log(JSON.stringify({ schema: "ccof.admin.audit.v1", at: deps.now().toISOString(), requestId, actorOid, operation: "v3/sync/removal-limits",
        outcome: "updated", projectId: null, etagAfter: etag, changes: changed }));
      return response(200, { limits: publicLimits(doc), etag, state: overrideState(doc, deps.now()), editable: true, maxOverrideDays: MAX_OVERRIDE_DAYS, observedAt: deps.now().toISOString() });
    }
    const routed = await routingRequest(path, method, url, request, actor, requestId, deps);
    if (routed) return routed;
    if (method !== "GET") throw new ApiError(405, "method_not_allowed");
    const clientFiles = /^projects\/([^/]+)\/client-config$/.exec(path);
    if (clientFiles) {
      const projectId = decodeURIComponent(clientFiles[1]);
      if (!isIdentifier(projectId)) throw new ApiError(400, "invalid_project_id");
      if (!deps.projects) throw new ApiError(503, "project_store_not_configured");
      const found = await deps.projects.read(projectId);
      if (!found) throw new ApiError(404, "project_not_found");
      const classification = url.searchParams.get("classification") ?? "";
      const files = buildClientFiles(found.doc, classification, readClientSettings(deps.env), deps.now());
      return response(200, { projectId, classification, ...files, observedAt: deps.now().toISOString() });
    }

    const chargeback = /^chargeback\/([a-z]+)$/.exec(path);
    if (chargeback) {
      const view = chargeback[1] as ChargebackView;
      if (!(CHARGEBACK_VIEWS as readonly string[]).includes(view)) throw new ApiError(404, "view_not_found");
      const cfg = readChargebackSettings(deps.env);
      const filters = readChargebackFilters(url.searchParams, deps.now(), cfg.ok ? cfg.value.maxQueryDays : 62);
      if (filters.tags.length) filters.projectSet = await projectsForTags(deps, filters.tags);
      return response(200, await capability(deps, cfg, "chargeback", async () => {
        const card = await currentRateCard(deps);
        if (!card || !cfg.ok || !deps.sources || !deps.operations.query) throw new ProviderError(503, "rate_card_unavailable");
        const prepared = prepareRateCard(card.rateCard);
        const key = `chargeback|${view}|${canonical(filters)}|${prepared.sha}`;
        const cached = request.headers("x-ccof-refresh") === "true" ? null : deps.cache.get(key, deps.now().getTime());
        if (cached) return { ...(cached as Doc), cached: true };
        const query = buildChargebackQuery(view, filters, cfg.value, deps.sources, prepared, await groupMetadata(deps, filters.project));
        const meta: QueryMeta = { kind: "chargeback", view, filters: filters as unknown as Doc };
        const table = await deps.operations.query(cfg.value.workspaceId, query, `${filters.period.from}/${filters.period.to}`, meta);
        const shaped = shapeRows(tableRows(table));
        const isSeries = view === "trend";
        const data = {
          view, rows: shaped.rows, columns: table.columns.map((c) => c.name).filter((c) => !["reportRows", "displayedLimit", "truncated", "pageOffset", "reportRowNumber", "rateCardSha256", "ledgerSha256"].includes(c)),
          truncated: shaped.truncated,
          page: isSeries ? null : {
            offset: filters.offset, limit: filters.limit, returned: shaped.rows.length, matched: shaped.reportRows,
            nextOffset: shaped.reportRows !== null && filters.offset + shaped.rows.length < shaped.reportRows ? filters.offset + shaped.rows.length : null,
          },
          seriesCap: isSeries ? 2000 : null,
          period: filters.period, interval: filters.interval, filters: { project: filters.project, group: filters.group, developer: filters.developer, model: filters.model, backend: filters.backend, family: filters.family,
            classification: filters.classification, tags: filters.tags, tagProjects: filters.projectSet === null ? null : filters.projectSet.length },
          rateCardVersion: prepared.version, rateCardSource: card.source, basis: LIST_PRICE_BASIS,
          observedAt: deps.now().toISOString(), cached: false,
        };
        deps.cache.set(key, data, deps.now().getTime());
        return data;
      }));
    }
    const reconciler = /^reconciler\/(runs|snapshots|summary)$/.exec(path);
    if (reconciler) {
      const cfg = readReconcilerSettings(deps.env);
      const kind = reconciler[1];
      const filters = kind === "runs" ? null : readSnapshotFilters(url.searchParams, deps.now());
      if (kind === "runs" && [...url.searchParams.keys()].length) throw new ApiError(400, "unknown_parameter");
      return response(200, await capability(deps, cfg, `reconciler_${kind}`, async () => {
        const card = await currentRateCard(deps);
        if (!card || !cfg.ok || !deps.sources || !deps.operations.query) throw new ProviderError(503, "rate_card_unavailable");
        const prepared = prepareRateCard(card.rateCard);
        const key = `reconciler|${kind}|${canonical(filters)}|${prepared.sha}`;
        const cached = request.headers("x-ccof-refresh") === "true" ? null : deps.cache.get(key, deps.now().getTime());
        if (cached) return { ...(cached as Doc), cached: true };
        const query = kind === "runs" ? buildRunsQuery(cfg.value, deps.sources, prepared, deps.now())
          : buildSnapshotQuery(kind as "snapshots" | "summary", filters!, cfg.value, deps.sources, prepared);
        const timespan = filters ? `${new Date(Math.min(Date.parse(filters.period.from), deps.now().getTime() - cfg.value.lookbackDays * 86_400_000)).toISOString()}/${new Date(deps.now().getTime() + 60_000).toISOString()}`
          : `P${cfg.value.lookbackDays}D`;
        const table = await deps.operations.query(cfg.value.workspaceId, query, timespan, { kind: "reconciler", view: kind, filters: (filters ?? {}) as unknown as Doc });
        const shaped = shapeRows(tableRows(table));
        const rows = kind === "runs" ? shaped.rows.map((r) => shapeRun(r, cfg.value.intervalMinutes, deps.now()))
          : kind === "snapshots" ? shaped.rows.map(shapeSnapshot)
            : shaped.rows.map((r) => ({ ...r, spentCcu: r.spentCcu === null ? null : String(r.spentCcu), budgetCcu: r.budgetCcu === null ? null : String(r.budgetCcu) }));
        const data = {
          kind, rows, truncated: shaped.truncated, intervalMinutes: cfg.value.intervalMinutes,
          page: kind === "snapshots" && filters ? {
            offset: filters.offset, limit: filters.limit, returned: rows.length, matched: shaped.reportRows,
            nextOffset: shaped.reportRows !== null && filters.offset + rows.length < shaped.reportRows ? filters.offset + rows.length : null,
          } : null,
          period: filters?.period ?? null, rateCardVersion: prepared.version, observedAt: deps.now().toISOString(), cached: false,
          basis: "Reconciler calculation at the approved rate card (100 CCU = USD 1); not an Azure invoice.",
        };
        deps.cache.set(key, data, deps.now().getTime());
        return data;
      }));
    }
    if (path === "audit/changes") {
      const filters = readAuditFilters(url.searchParams, deps.now());
      const observedAt = deps.now().toISOString();
      if (!deps.changeLog) {
        return response(200, { state: "disabled", reason: "ADMIN_CONFIG_CONTAINER_not_set", observedAt,
          permission: "ADMIN_CONFIG_CONTAINER and a scoped Cosmos data role on the adminConfig container." });
      }
      try {
        const { rows, matched } = await deps.changeLog.list(filters);
        return response(200, { state: "available", observedAt, data: {
          source: "change_log", rows: rows.map(auditRow), truncated: false,
          page: { offset: filters.offset, limit: filters.limit, returned: rows.length, matched,
            nextOffset: filters.offset + rows.length < matched ? filters.offset + rows.length : null },
        } });
      } catch {
        deps.log(JSON.stringify({ schema: "ccof.admin.integration.v2", capability: "change_log", code: "request_failed", requestId }));
        return response(200, { state: "unavailable", reason: "change_log_unreadable", observedAt });
      }
    }
    if (path === "audit") {      const cfg = readAuditSettings(deps.env);
      const filters = readAuditFilters(url.searchParams, deps.now());
      return response(200, await capability(deps, cfg, "audit", async () => {
        if (!cfg.ok || !deps.operations.query) throw new ProviderError(503, "audit_unavailable");
        const table = await deps.operations.query(cfg.value.workspaceId, buildAuditQuery(filters, cfg.value.resourceIds), `${filters.from}/${filters.to}`,
          { kind: "audit", view: "audit", filters: filters as unknown as Doc });
        const shaped = shapeRows(tableRows(table));
        return {
          rows: shaped.rows, truncated: shaped.truncated, observedAt: deps.now().toISOString(),
          page: { offset: filters.offset, limit: filters.limit, returned: shaped.rows.length, matched: shaped.reportRows,
            nextOffset: shaped.reportRows !== null && filters.offset + shaped.rows.length < shaped.reportRows ? filters.offset + shaped.rows.length : null },
        };
      }));
    }
    throw new ApiError(404, "route_not_found");
  } catch (err) {
    const status = err instanceof ApiError ? err.status : 503;
    const code = err instanceof ApiError ? err.code : "integration_or_registry_unavailable";
    if (status === 401 || status === 403 || path === "sync/removal-limits" && method === "PUT" || ROUTING_WRITE.test(path) && method !== "GET") {
      deps.log(JSON.stringify({ schema: "ccof.admin.audit.v1", at: deps.now().toISOString(), requestId, actorOid, operation: `v3/${path}`, outcome: "refused", status, code }));
    } else deps.log(JSON.stringify({ schema: "ccof.admin.integration.v2", operation: `v3/${path}`, status, code, requestId }));
    return response(status, { error: code, requestId, ...(err instanceof LimitsInvalid || err instanceof RoutingInvalid ? { problems: err.problems } : {}) });
  }
}

// ---- ADR 0034: backend registry, per-project failover, routing publication ----

const ROUTING_WRITE = /^(backends\/[^/]+|projects\/[^/]+\/failover|routing\/[^/]+\/publication)$/;

class RoutingInvalid extends ApiError {
  readonly problems: string[];
  constructor(code: string, problems: string[]) { super(422, code); this.problems = problems; }
}

async function routingRequest(path: string, method: string, url: URL, request: ApiRequest, actor: { oid: string; canWrite: boolean },
  requestId: string, deps: V3Dependencies): Promise<ApiResponse | null> {
  const backend = /^backends\/([^/]+)$/.exec(path);
  const failover = /^projects\/([^/]+)\/failover$/.exec(path);
  const publication = /^routing\/([^/]+)\/publication$/.exec(path);
  if (path !== "backends" && path !== "routing/pending" && !backend && !failover && !publication) return null;
  if ([...url.searchParams].length) throw new ApiError(400, "unknown_parameter");
  const begin = (operation: string, projectId: string | null, changed: { path: string; before: unknown; after: unknown }[], details: Doc) =>
    beginChange(deps.changeLog, { requestId, at: deps.now().toISOString(), actorOid: actor.oid, operation, projectId, changes: changed, details }, deps.now, deps.log);
  const diff = (before: Doc, after: Doc, prefix = "") => [...new Set([...Object.keys(before), ...Object.keys(after)])].sort()
    .filter((k) => canonical(before[k] ?? null) !== canonical(after[k] ?? null))
    .map((k) => ({ path: prefix + k, before: before[k] ?? null, after: after[k] ?? null }));
  const audit = (operation: string, fields: Doc) => deps.log(JSON.stringify({ schema: "ccof.admin.audit.v1", at: deps.now().toISOString(), requestId,
    actorOid: actor.oid, operation, ...fields }));

  if (path === "backends") {
    if (method !== "GET") throw new ApiError(405, "method_not_allowed");
    const entries = deps.registry ? await deps.registry.list() : [];
    return response(200, { backends: entries.map(publicEntry), editable: Boolean(deps.registry && actor.canWrite),
      reason: deps.registry ? null : "ADMIN_CONFIG_CONTAINER and a scoped Cosmos data role are required to register backends.",
      observedAt: deps.now().toISOString() });
  }
  if (backend) {
    if (method !== "PUT") throw new ApiError(405, "method_not_allowed");
    if (!actor.canWrite) throw new ApiError(403, "write_permission_required");
    if (!deps.registry) throw new ApiError(503, "backend_registry_not_configured");
    const backendId = decodeURIComponent(backend[1]);
    let doc;
    try { doc = registryEntryFromBody(backendId, parseJson(request.body, MAX_PLAN_BYTES)); } catch (err) {
      throw err instanceof ValidationError ? new RoutingInvalid("invalid_backend", err.problems) : err;
    }
    const current = await deps.registry.read(backendId);
    const match = request.headers("if-match");
    if (current && (!match || match === "*")) throw new ApiError(428, "if_match_required");
    if (current && current.etag !== match || !current && request.headers("if-none-match") !== "*") throw new ApiError(412, "etag_mismatch");
    const changed = diff((current?.doc ?? {}) as unknown as Doc, doc as unknown as Doc);
    if (current && !changed.length) return response(200, { backend: publicEntry(current), changed: false });
    const operation = "v3/backends";
    const pending = await begin(operation, null, changed, { backendId, etagBefore: current?.etag ?? null });
    let etag: string | null;
    try { etag = await deps.registry.save(doc, current?.etag ?? null); } catch (err) { await pending.finish("unconfirmed", { code: "write_failed" }); throw err; }
    if (!etag) { await pending.finish("refused", { code: "etag_mismatch" }); throw new ApiError(412, "etag_mismatch"); }
    await pending.finish(current ? "updated" : "created", { etagAfter: etag });
    audit(operation, { outcome: current ? "updated" : "created", backendId, etagAfter: etag, changes: changed });
    return response(current ? 200 : 201, { backend: { ...doc, etag }, changed: true });
  }
  if (!deps.projects) throw new ApiError(503, "project_store_not_configured");
  if (failover) {
    if (method !== "PUT") throw new ApiError(405, "method_not_allowed");
    if (!actor.canWrite) throw new ApiError(403, "write_permission_required");
    if (!deps.registry) throw new ApiError(503, "backend_registry_not_configured");
    const projectId = decodeURIComponent(failover[1]);
    const match = request.headers("if-match")?.trim();
    if (!match || match === "*") throw new ApiError(428, "if_match_required");
    const body = parseJson(request.body, MAX_PLAN_BYTES);
    const current = await deps.projects.read(projectId);
    if (!current) throw new ApiError(404, "project_not_found");
    if (current.etag !== match) throw new ApiError(412, "etag_mismatch");
    if (current.doc.status === "retired") throw new ApiError(409, "project_retired");
    let next: Doc;
    try { next = failoverAfterEdit(current.doc, body, await registryMap(deps.registry)); } catch (err) {
      throw err instanceof ValidationError ? new RoutingInvalid("invalid_failover", err.problems) : err;
    }
    const before = isObject(current.doc.failover) ? current.doc.failover : {};
    const changed = diff(before, next, "failover.");
    if (!changed.length) return { ...response(200, { projectId, changed: false, project: stripSystem(current.doc), failover: next, state: routingState(next) }), headers: { "cache-control": "no-store", "content-type": "application/json", etag: current.etag } };
    const after = { ...stripSystem(current.doc), failover: next };
    const operation = "v3/projects/failover";
    const pending = await begin(operation, projectId, changed, { etagBefore: current.etag });
    let written: string;
    try { written = await deps.projects.replace(after, current.etag); } catch (err) { await pending.finish("unconfirmed", { code: "write_failed" }); throw err; }
    if (written === "precondition_failed") { await pending.finish("refused", { code: "etag_mismatch" }); throw new ApiError(412, "etag_mismatch"); }
    await pending.finish("updated", { etagAfter: written });
    audit(operation, { outcome: "updated", projectId, etagBefore: current.etag, etagAfter: written, changes: changed });
    return { ...response(200, { projectId, changed: true, project: after, failover: next, state: routingState(next) }), headers: { "cache-control": "no-store", "content-type": "application/json", etag: written } };
  }
  if (path === "routing/pending") {
    if (method !== "GET") throw new ApiError(405, "method_not_allowed");
    if (!deps.registry) throw new ApiError(503, "backend_registry_not_configured");
    const registry = await registryMap(deps.registry);
    const projects = (await deps.projects.list()).map((p) => p.doc)
      .filter((d) => d.status === "active" && routingState(d.failover) === "pending_publication")
      .sort((a, b) => String(a.projectId).localeCompare(String(b.projectId)));
    return response(200, { pending: projects.map((d) => routingPlan(d, registry)), observedAt: deps.now().toISOString() });
  }
  if (publication) {
    if (method !== "POST") throw new ApiError(405, "method_not_allowed");
    if (!actor.canWrite) throw new ApiError(403, "write_permission_required");
    const projectId = decodeURIComponent(publication[1]);
    const body = parseJson(request.body, MAX_PLAN_BYTES);
    if (!isObject(body) || Object.keys(body).some((k) => !["revision", "poolBackendId", "verifiedTargets"].includes(k)) ||
      !Array.isArray(body.verifiedTargets) || body.verifiedTargets.length < 1 || body.verifiedTargets.length > 10 ||
      body.verifiedTargets.some((t) => typeof t !== "string" || !/^\/subscriptions\/[0-9a-fA-F-]{36}\/resourceGroups\/[^/]{1,90}\/providers\/Microsoft\.ApiManagement\/service\/[A-Za-z0-9-]{1,50}$/.test(t))) {
      throw new RoutingInvalid("invalid_publication", ["publication:invalid"]);
    }
    const current = await deps.projects.read(projectId);
    if (!current) throw new ApiError(404, "project_not_found");
    const f = isObject(current.doc.failover) ? current.doc.failover : null;
    if (!f) throw new ApiError(409, "failover_not_configured");
    if (body.revision !== f.revision) throw new ApiError(409, "revision_superseded");
    if (body.poolBackendId !== poolBackendIdFor(projectId, Number(f.revision))) throw new RoutingInvalid("invalid_publication", ["poolBackendId:not_the_revision_pool"]);
    const active = { revision: f.revision, poolBackendId: body.poolBackendId, verifiedAt: deps.now().toISOString().replace(/\.\d{3}Z$/, "Z") };
    if (isObject(f.active) && f.active.revision === active.revision && f.active.poolBackendId === active.poolBackendId) {
      return response(200, { projectId, changed: false, failover: f, state: routingState(f) });
    }
    const next = { ...f, active };
    const after = { ...stripSystem(current.doc), failover: next };
    const changed = diff(isObject(f.active) ? f.active : {}, active, "failover.active.");
    const operation = "v3/routing/publication";
    const pending = await begin(operation, projectId, changed, { etagBefore: current.etag, verifiedTargets: body.verifiedTargets });
    let written: string;
    try { written = await deps.projects.replace(after, current.etag); } catch (err) { await pending.finish("unconfirmed", { code: "write_failed" }); throw err; }
    if (written === "precondition_failed") { await pending.finish("refused", { code: "etag_mismatch" }); throw new ApiError(412, "etag_mismatch"); }
    await pending.finish("published", { etagAfter: written });
    audit(operation, { outcome: "published", projectId, etagAfter: written, changes: changed, verifiedTargets: body.verifiedTargets });
    return response(200, { projectId, changed: true, failover: next, state: routingState(next) });
  }
  return null;
}
