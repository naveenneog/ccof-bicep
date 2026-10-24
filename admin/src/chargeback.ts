// V3 chargeback, reconciler and audit queries: validated filters, server-built KQL, bounded results.
// The chargeback KQL comes from the workbook's own builder (analytics/workbooks/chargeback-queries.ts)
// and its parameters are bound by the workbook's renderer (render.ts): every filter value reaches
// KQL base64-encoded, after it has been validated here. The browser never sends KQL.

import { ApiError, isGuid } from "./auth.ts";
import { isIdentifier, isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";
import { chargebackQueries, lf, reconcilerQueryBase, reportingRateCard, sha256, usageQueryBase } from "../../analytics/workbooks/chargeback-queries.ts";
import type { GroupMetadata } from "../../analytics/workbooks/chargeback-queries.ts";
import { bounded } from "../../analytics/workbooks/queries.ts";
import { compileRateCard } from "../../analytics/workbooks/rate-card.ts";
import { renderQuery } from "../../analytics/workbooks/render.ts";
import type { RenderParameters } from "../../analytics/workbooks/render.ts";
import { ccuToUsdText, DECIMAL_TEXT } from "./units.ts";
import type { LogTable } from "./operations.ts";

export const CHARGEBACK_VIEWS = ["totals", "groups", "developers", "models", "families", "trend", "coverage", "unpriced", "diagnostics", "projects", "classifications"] as const;
export type ChargebackView = typeof CHARGEBACK_VIEWS[number];
const QUERY_KEY: Record<ChargebackView, string> = {
  totals: "totals", groups: "groups", developers: "developers", models: "models", families: "families",
  trend: "trends", coverage: "health", unpriced: "unpriced", diagnostics: "diagnostics", projects: "projects", classifications: "classifications",
};
// Tags resolve to project IDs from the registry; a larger match is refused rather than truncated.
export const TAG_PROJECTS_MAX = 2000;
export const ROW_PAGE_MAX = 500;
export const SERIES_POINTS_MAX = 2000;
export const CACHE_TTL_MS = 60_000;
const RESOURCE = (provider: string) => new RegExp(`^/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/${provider}/[A-Za-z0-9._-]+$`, "i");
const APIM_ID = RESOURCE("Microsoft\\.ApiManagement/service");
const LOG_ID = /^\/subscriptions\/[a-f0-9-]{36}\/resourceGroups\/[^/]+\/providers\/Microsoft\.[A-Za-z]+\/[A-Za-z]+\/[^/]+$/i;
const MODEL = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;
const UTC = /^\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d(?:\.\d{1,3})?)?Z$/;
const FAMILY = ["haiku", "sonnet", "opus", "fable", "mythos", "unknown"];

export interface QuerySources { ledger: string; pricing: string; budgets: string }
export type Configured<T> = { ok: true; value: T; permission: string } | { ok: false; reason: string; permission: string };
export interface ChargebackSettings { workspaceId: string; gatewayResourceId: string; maxQueryDays: number; retentionDays: number }
export interface ReconcilerSettings { workspaceId: string; resourceIds: string[]; intervalMinutes: number; lookbackDays: number }
export interface AuditSettings { workspaceId: string; resourceIds: string[] }

const ids = (v?: string) => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const intSetting = (v: string | undefined, fallback: number, min: number, max: number) => {
  const n = v === undefined || v === "" ? fallback : Number(v);
  return Number.isInteger(n) && n >= min && n <= max ? n : null;
};

export function readChargebackSettings(env: Readonly<Record<string, string | undefined>>): Configured<ChargebackSettings> {
  const permission = "Log Analytics Reader on the gateway telemetry workspace (ADMIN_CHARGEBACK_WORKSPACE_ID, else ADMIN_WORKSPACE_ID)";
  const workspaceId = env.ADMIN_CHARGEBACK_WORKSPACE_ID || env.ADMIN_WORKSPACE_ID || "";
  const gatewayResourceId = env.ADMIN_GATEWAY_RESOURCE_ID ?? "";
  if (!workspaceId || !gatewayResourceId) return { ok: false, reason: "chargeback_not_configured", permission };
  const maxQueryDays = intSetting(env.ADMIN_CHARGEBACK_MAX_QUERY_DAYS, 62, 31, 366);
  const retentionDays = intSetting(env.ADMIN_LOG_RETENTION_DAYS, 90, 1, 4383);
  if (!isGuid(workspaceId) || !APIM_ID.test(gatewayResourceId) || maxQueryDays === null || retentionDays === null) {
    return { ok: false, reason: "chargeback_settings_invalid", permission };
  }
  return { ok: true, value: { workspaceId, gatewayResourceId, maxQueryDays, retentionDays }, permission };
}

export function readReconcilerSettings(env: Readonly<Record<string, string | undefined>>): Configured<ReconcilerSettings> {
  const permission = "Log Analytics Reader on ADMIN_WORKSPACE_ID, with the reconciler's logs routed to it";
  const workspaceId = env.ADMIN_WORKSPACE_ID ?? "";
  const resourceIds = env.ADMIN_RECONCILER_RESOURCE_ID ? [env.ADMIN_RECONCILER_RESOURCE_ID] : ids(env.ADMIN_LOG_RESOURCE_IDS);
  if (!workspaceId || !resourceIds.length) return { ok: false, reason: "reconciler_logs_not_configured", permission };
  const intervalMinutes = intSetting(env.ADMIN_RECONCILER_INTERVAL_MINUTES, 5, 1, 1440);
  const lookbackDays = intSetting(env.ADMIN_BUDGET_LOOKBACK_DAYS, 31, 1, 93);
  if (!isGuid(workspaceId) || !resourceIds.every((id) => LOG_ID.test(id)) || intervalMinutes === null || lookbackDays === null) {
    return { ok: false, reason: "reconciler_settings_invalid", permission };
  }
  return { ok: true, value: { workspaceId, resourceIds, intervalMinutes, lookbackDays }, permission };
}

export function readAuditSettings(env: Readonly<Record<string, string | undefined>>): Configured<AuditSettings> {
  const permission = env.ADMIN_AUDIT_WORKSPACE_ID ? "Log Analytics Reader on ADMIN_AUDIT_WORKSPACE_ID (the admin app's own Application Insights workspace)" : "Log Analytics Reader on ADMIN_WORKSPACE_ID";
  const workspaceId = env.ADMIN_AUDIT_WORKSPACE_ID || env.ADMIN_WORKSPACE_ID || "";
  const resourceIds = ids(env.ADMIN_LOG_RESOURCE_IDS);
  if (!workspaceId || !resourceIds.length) return { ok: false, reason: "audit_logs_not_configured", permission };
  if (!isGuid(workspaceId) || !resourceIds.every((id) => LOG_ID.test(id))) return { ok: false, reason: "audit_settings_invalid", permission };
  return { ok: true, value: { workspaceId, resourceIds }, permission };
}

export interface Period { mode: "month" | "previous" | "custom"; from: string; to: string }
function readPeriod(params: URLSearchParams, now: Date, maxDays: number): Period {
  const mode = params.get("period") ?? "month";
  const monthStart = (offset: number) => new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + offset, 1)).toISOString();
  if (mode === "month") return { mode, from: monthStart(0), to: monthStart(1) };
  if (mode === "previous") return { mode, from: monthStart(-1), to: monthStart(0) };
  if (mode !== "custom") throw new ApiError(400, "invalid_period");
  const from = params.get("from") ?? "", to = params.get("to") ?? "";
  if (!UTC.test(from) || !UTC.test(to)) throw new ApiError(400, "custom_period_requires_utc_from_and_to");
  const a = Date.parse(from), b = Date.parse(to);
  if (!Number.isFinite(a) || !Number.isFinite(b) || a >= b) throw new ApiError(400, "invalid_custom_range");
  if (b - a > maxDays * 86_400_000) throw new ApiError(400, "range_exceeds_max_query_days");
  if (b > now.getTime() + 31 * 86_400_000 || a < now.getTime() - 4383 * 86_400_000) throw new ApiError(400, "range_out_of_bounds");
  return { mode, from: new Date(a).toISOString(), to: new Date(b).toISOString() };
}

function page(params: URLSearchParams, defaultLimit = 100): { offset: number; limit: number } {
  const offset = Number(params.get("offset") ?? "0"), limit = Number(params.get("limit") ?? String(defaultLimit));
  if (!Number.isInteger(offset) || offset < 0 || offset > 100_000 || !Number.isInteger(limit) || limit < 1 || limit > ROW_PAGE_MAX) {
    throw new ApiError(400, "invalid_page");
  }
  return { offset, limit };
}

function onlyParams(params: URLSearchParams, allowed: string[]) {
  for (const key of params.keys()) if (!allowed.includes(key)) throw new ApiError(400, `unknown_parameter`);
  for (const key of allowed) if (params.getAll(key).length > 1) throw new ApiError(400, "repeated_parameter");
}
const optional = (params: URLSearchParams, key: string, valid: (v: string) => boolean, code: string): string => {
  const v = (params.get(key) ?? "").trim();
  if (v && !valid(v)) throw new ApiError(400, code);
  return v;
};

export interface ChargebackFilters {
  period: Period; project: string; group: string; developer: string; model: string; backend: string; family: string;
  classification: string; tags: string[];
  // Resolved by the handler from `tags`; null means no tag filter.
  projectSet: string[] | null;
  interval: "hour" | "day"; offset: number; limit: number;
}
const TAG = /^[A-Za-z0-9][A-Za-z0-9 ._:@/+-]{0,59}$/;
export function readChargebackFilters(params: URLSearchParams, now: Date, maxQueryDays: number): ChargebackFilters {
  onlyParams(params, ["period", "from", "to", "project", "group", "developer", "model", "backend", "family", "classification", "tags", "interval", "offset", "limit"]);
  const interval = params.get("interval") ?? "day";
  if (interval !== "hour" && interval !== "day") throw new ApiError(400, "invalid_interval");
  const tags = [...new Set((params.get("tags") ?? "").split(",").map((t) => t.trim()).filter(Boolean))].sort();
  if (tags.length > 10 || tags.some((t) => !TAG.test(t))) throw new ApiError(400, "invalid_tags_filter");
  return {
    period: readPeriod(params, now, maxQueryDays),
    project: optional(params, "project", isIdentifier, "invalid_project_filter"),
    group: optional(params, "group", isGuid, "invalid_group_filter").toLowerCase(),
    developer: optional(params, "developer", isGuid, "invalid_developer_filter").toLowerCase(),
    model: optional(params, "model", (v) => MODEL.test(v), "invalid_model_filter"),
    backend: optional(params, "backend", isIdentifier, "invalid_backend_filter"),
    family: optional(params, "family", (v) => FAMILY.includes(v), "invalid_family_filter"),
    classification: optional(params, "classification", isIdentifier, "invalid_classification_filter"),
    tags, projectSet: null,
    interval, ...page(params),
  };
}

const renderParams = (f: { period: Period; project?: string; group?: string; developer?: string; model?: string; backend?: string; family?: string; classification?: string; projectSet?: string[] | null }): RenderParameters => ({
  period: f.period.mode, project: f.project || "*",
  from: f.period.mode === "custom" ? f.period.from : null, to: f.period.mode === "custom" ? f.period.to : null,
  group: f.group || "*", developer: f.developer || "*", model: f.model || "*", backend: f.backend || "*", family: f.family || "*",
  classification: f.classification || "*",
  // An empty tag match must select nothing, never everything: "(none)" is not a valid project ID.
  projects: f.projectSet === null || f.projectSet === undefined ? "*" : f.projectSet.length ? f.projectSet.join(",") : "(none)",
});

export interface PreparedCard { card: Doc; text: string; sha: string; version: string }
export function prepareRateCard(rateCard: unknown): PreparedCard {
  if (!isObject(rateCard) || !Array.isArray(rateCard.entries)) throw new ApiError(503, "rate_card_unavailable");
  const card = reportingRateCard(rateCard as Doc & { entries: Array<{ model: string }> }) as Doc;
  const text = lf(JSON.stringify(card));
  return { card, text, sha: sha256(text), version: String(rateCard.version ?? "") };
}

function reportSettings(cb: { gatewayResourceId: string; maxQueryDays: number; retentionDays: number }, reconcilerId = "", lookbackDays = 31) {
  return { maxQueryDays: cb.maxQueryDays, retentionDays: cb.retentionDays, gatewayResourceId: cb.gatewayResourceId, reconcilerResourceId: reconcilerId, budgetLookbackDays: lookbackDays };
}

// The bound chargeback KQL for one view: the workbook builder's text with admin options, rendered.
export function buildChargebackQuery(view: ChargebackView, filters: ChargebackFilters, settings: ChargebackSettings, sources: QuerySources, card: PreparedCard, groups: GroupMetadata[]): string {
  const compiled = compileRateCard(JSON.parse(card.text));
  const usage = usageQueryBase(reportSettings(settings), compiled, card.text, lf(sources.ledger), lf(sources.pricing));
  const isSeries = view === "trend";
  const queries = chargebackQueries(usage, isSeries ? SERIES_POINTS_MAX : filters.limit, groups, {
    extendedFilters: true, trendBin: filters.interval === "hour" ? "1h" : "1d", offset: isSeries ? 0 : filters.offset, extraViews: true,
  });
  const query = (queries as Record<string, string | undefined>)[QUERY_KEY[view]];
  if (!query) throw new ApiError(404, "view_not_found");
  return renderQuery(query, renderParams(filters));
}

// Log Analytics returns decimals as strings or numbers depending on the client; keep exact text.
export function tableRows(table: LogTable): Doc[] {
  return table.rows.map((row) => Object.fromEntries(table.columns.map((c, i) => {
    const v = row[i];
    if (c.type === "decimal" && typeof v === "number") return [c.name, String(v)];
    if ((c.type === "dynamic") && typeof v === "string") { try { return [c.name, JSON.parse(v)]; } catch { return [c.name, v]; } }
    return [c.name, v ?? null];
  })));
}

export interface ShapedRows { rows: Doc[]; reportRows: number | null; truncated: boolean }
// Removes the report's bookkeeping columns and reads its truncation flags.
export function shapeRows(rows: Doc[]): ShapedRows {
  const first = rows[0];
  const reportRows = first && typeof first.reportRows === "number" ? first.reportRows : rows.length ? null : 0;
  const truncated = rows.some((r) => r.truncated === true);
  const clean = rows.map((r) => Object.fromEntries(Object.entries(r).filter(([k]) =>
    !["reportRows", "displayedLimit", "truncated", "pageOffset", "reportRowNumber", "rateCardSha256", "ledgerSha256"].includes(k))));
  return { rows: clean, reportRows, truncated };
}

// A tiny per-filter-set cache: identical requests within 60 s reuse the result.
export class QueryCache {
  private readonly entries = new Map<string, { at: number; value: unknown }>();
  private readonly ttlMs: number;
  private readonly max: number;
  constructor(ttlMs = CACHE_TTL_MS, max = 200) { this.ttlMs = ttlMs; this.max = max; }
  get(key: string, now: number): unknown {
    const hit = this.entries.get(key);
    if (!hit) return undefined;
    if (now - hit.at > this.ttlMs) { this.entries.delete(key); return undefined; }
    return hit.value;
  }
  set(key: string, value: unknown, now: number) {
    if (this.entries.size >= this.max) this.entries.delete(this.entries.keys().next().value as string);
    this.entries.set(key, { at: now, value });
  }
}

// ---- Reconciler (budgets.kql) ----
export const SNAPSHOT_STATES = ["current", "expired", "historical", "invalid_event"];
export const BUDGET_STATES = ["available", "warning", "exhausted", "no_cap", "unknown"];
export interface SnapshotFilters { period: Period; scope: string; project: string; classification: string; person: string; state: string; budgetState: string; offset: number; limit: number }
export function readSnapshotFilters(params: URLSearchParams, now: Date): SnapshotFilters {
  onlyParams(params, ["period", "from", "to", "scope", "project", "classification", "person", "state", "budgetState", "offset", "limit"]);
  return {
    period: readPeriod(params, now, 93),
    scope: optional(params, "scope", (v) => v === "person" || v === "group", "invalid_scope_filter"),
    project: optional(params, "project", isIdentifier, "invalid_project_filter"),
    classification: optional(params, "classification", isIdentifier, "invalid_classification_filter"),
    person: optional(params, "person", isGuid, "invalid_person_filter").toLowerCase(),
    state: optional(params, "state", (v) => SNAPSHOT_STATES.includes(v), "invalid_state_filter"),
    budgetState: optional(params, "budgetState", (v) => BUDGET_STATES.includes(v), "invalid_budget_state_filter"),
    ...page(params),
  };
}
const b64 = (v: string) => `base64_decode_tostring(${JSON.stringify(Buffer.from(v || "*", "utf8").toString("base64"))})`;

function reconcilerBase(settings: ReconcilerSettings, sources: QuerySources, card: PreparedCard): string {
  const compiled = compileRateCard(JSON.parse(card.text));
  const preamble = usageQueryBase(reportSettings({ gatewayResourceId: "", maxQueryDays: 93, retentionDays: 4383 }, settings.resourceIds[0], settings.lookbackDays),
    compiled, card.text, "", "").preamble;
  return reconcilerQueryBase(preamble, lf(sources.budgets), settings.resourceIds);
}

export function buildSnapshotQuery(kind: "snapshots" | "summary", f: SnapshotFilters, settings: ReconcilerSettings, sources: QuerySources, card: PreparedCard): string {
  const filters = `let ScopeFilter = ${b64(f.scope)};
let ClassificationFilter = ${b64(f.classification)};
let PersonFilter = ${b64(f.person)};
let StateFilter = ${b64(f.state)};
let BudgetStateFilter = ${b64(f.budgetState)};
let Snapshots = BudgetSnapshots
| where (ScopeFilter == "*" or scope == ScopeFilter) and (ClassificationFilter == "*" or classification == ClassificationFilter)
    and (PersonFilter == "*" or personId =~ PersonFilter) and (StateFilter == "*" or snapshotState == StateFilter)
    and (BudgetStateFilter == "*" or budgetState == BudgetStateFilter);
`;
  const tail = kind === "summary"
    ? `Snapshots
| summarize snapshots = count(), exhausted = countif(budgetState == "exhausted"), warning = countif(budgetState == "warning"), partial = countif(completeness == "partial"),
    spentCcu = sum(spentCcu), budgetCcu = sum(budgetCcu), uncapped = countif(budgetState == "no_cap"),
    latestComputedAt = max(computedAt) by scope, snapshotState
| order by scope asc, snapshotState asc`
    : bounded("Snapshots", f.limit, "projectId asc, classification asc, scope asc, scopeId asc", f.offset);
  return renderQuery(reconcilerBase(settings, sources, card) + filters + tail, renderParams({ period: f.period, project: f.project }));
}

export function buildRunsQuery(settings: ReconcilerSettings, sources: QuerySources, card: PreparedCard, now: Date): string {
  const period: Period = { mode: "month", from: now.toISOString(), to: now.toISOString() };
  return renderQuery(reconcilerBase(settings, sources, card) + "ReconcilerRuns\n| order by latestRunAt desc\n| take 50", renderParams({ period }));
}

// Exact USD equivalents of CCU fields, and the run's age against the timer interval.
export function shapeSnapshot(row: Doc): Doc {
  const usd = (v: unknown) => typeof v === "string" && DECIMAL_TEXT.test(v) ? ccuToUsdText(v) : null;
  const spent = typeof row.spentCcu === "number" ? String(row.spentCcu) : row.spentCcu;
  const budget = typeof row.budgetCcu === "number" ? String(row.budgetCcu) : row.budgetCcu;
  return {
    ...row, spentCcu: spent ?? null, budgetCcu: budget ?? null, spentUsd: usd(spent), budgetUsd: usd(budget),
    usedPercent: typeof spent === "string" && typeof budget === "string" && Number(budget) > 0 ? (Number(spent) / Number(budget) * 100).toFixed(1) : null,
  };
}
export function shapeRun(row: Doc, intervalMinutes: number, now: Date): Doc {
  const at = typeof row.latestRunAt === "string" ? Date.parse(row.latestRunAt) : NaN;
  const ageMinutes = Number.isFinite(at) ? Math.max(0, Math.round((now.getTime() - at) / 60_000)) : null;
  return {
    ...row, ageMinutes, intervalMinutes,
    freshness: ageMinutes === null ? "unknown" : ageMinutes <= intervalMinutes * 2 ? "on_schedule" : ageMinutes <= intervalMinutes * 6 ? "late" : "stale",
  };
}

// ---- Audit (ccof.admin.audit.v1) ----
export interface AuditFilters { project: string; actor: string; operation: string; outcome: string; from: string; to: string; offset: number; limit: number }
export function readAuditFilters(params: URLSearchParams, now: Date): AuditFilters {
  onlyParams(params, ["project", "actor", "operation", "outcome", "from", "to", "offset", "limit"]);
  const from = optional(params, "from", (v) => UTC.test(v), "invalid_from");
  const to = optional(params, "to", (v) => UTC.test(v), "invalid_to");
  const a = from ? Date.parse(from) : now.getTime() - 31 * 86_400_000;
  const b = to ? Date.parse(to) : now.getTime() + 60_000;
  if (!(a < b) || b - a > 93 * 86_400_000) throw new ApiError(400, "invalid_audit_range");
  return {
    project: optional(params, "project", isIdentifier, "invalid_project_filter"),
    actor: optional(params, "actor", isGuid, "invalid_actor_filter").toLowerCase(),
    operation: optional(params, "operation", (v) => /^[A-Za-z0-9/_-]{1,60}$/.test(v), "invalid_operation_filter"),
    outcome: optional(params, "outcome", (v) => /^[a-z_]{1,30}$/.test(v), "invalid_outcome_filter"),
    from: new Date(a).toISOString(), to: new Date(b).toISOString(), ...page(params, 50),
  };
}
export function buildAuditQuery(f: AuditFilters, resourceIds: string[]): string {
  const scope = resourceIds.map((id) => JSON.stringify(id)).join(", ");
  return `let ProjectFilter = ${b64(f.project)};
let ActorFilter = ${b64(f.actor)};
let OperationFilter = ${b64(f.operation)};
let OutcomeFilter = ${b64(f.outcome)};
let Audit = union isfuzzy=true (FunctionAppLogs | project at=TimeGenerated, message=Message, resourceId=_ResourceId), (AppTraces | project at=TimeGenerated, message=Message, resourceId=_ResourceId)
| where at >= datetime(${f.from}) and at < datetime(${f.to}) and resourceId in~ (${scope})
| where message has "ccof.admin.audit.v1"
| extend d = parse_json(message)
| where tostring(d.schema) == "ccof.admin.audit.v1"
| summarize arg_max(at, d) by requestId = tostring(d.requestId), operation = tostring(d.operation), outcome = tostring(d.outcome)
| extend projectId = tostring(d.projectId), actorOid = tostring(d.actorOid)
| where (ProjectFilter == "*" or projectId == ProjectFilter) and (ActorFilter == "*" or actorOid =~ ActorFilter)
    and (OperationFilter == "*" or operation == OperationFilter) and (OutcomeFilter == "*" or outcome == OutcomeFilter)
| project at, requestId, operation, outcome, projectId, actorOid, d;
` + bounded("Audit", f.limit, "at desc", f.offset);
}
