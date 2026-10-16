import type { TokenCredential } from "@azure/identity";
import { isGuid } from "./auth.ts";
import { isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";

export interface Capability {
  state: "available" | "disabled" | "permission_required" | "unavailable" | "partial";
  reason?: string;
  permission?: string;
  observedAt: string;
  data?: unknown;
}
export interface Operations {
  groups(query: string): Promise<Capability>;
  inventory(): Promise<Capability>;
  deployments(id: string): Promise<Capability>;
  logs(kind: "budgets" | "audit" | "runs"): Promise<Capability>;
  health(): Promise<Capability>;
  retail(): Promise<Capability>;
  billed(): Promise<Capability>;
}
class ProviderError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string) { super(code); this.status = status; this.code = code; }
}
const ARM = "https://management.azure.com";
const ARM_SCOPE = `${ARM}/.default`;
const RESOURCE_ID = /^\/subscriptions\/[a-f0-9-]{36}\/resourceGroups\/[^/]+\/providers\/Microsoft\.(ApiManagement\/service|CognitiveServices\/accounts|Web\/sites)\/[^/]+$/i;
const DISCOVERY_SCOPE = /^\/subscriptions\/[a-f0-9-]{36}(\/resourceGroups\/[^/]+)?$/i;
const ids = (v?: string) => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const object = (v: unknown): Doc => isObject(v) ? v : {};
const stamp = () => new Date().toISOString();
const messages = (logIds: string[]) => {
  const scope = logIds.map((id) => JSON.stringify(id)).join(",");
  return `union isfuzzy=true (FunctionAppLogs | project at=TimeGenerated, message=Message, resourceId=_ResourceId), (AppTraces | project at=TimeGenerated, message=Message, resourceId=_ResourceId)
| where at > ago(31d) and resourceId in~ (${scope})
| extend d=parse_json(message)`;
};
export function createOperations(
  env: Readonly<Record<string, string | undefined>>, credential: TokenCredential,
  log: (line: string) => void, transport: typeof fetch = fetch,
): Operations {
  const configuredIds = ids(env.ADMIN_RESOURCE_IDS);
  const scopes = ids(env.ADMIN_DISCOVERY_SCOPES);
  const logIds = ids(env.ADMIN_LOG_RESOURCE_IDS);
  const validIds = configuredIds.every((id) => RESOURCE_ID.test(id));
  const validScopes = scopes.every((id) => DISCOVERY_SCOPE.test(id));
  const result = (state: Capability["state"], data?: unknown, reason?: string, permission?: string): Capability =>
    ({ state, observedAt: stamp(), ...(data === undefined ? {} : { data }), ...(reason ? { reason } : {}), ...(permission ? { permission } : {}) });
  async function request(url: string, scope: string | null, init: RequestInit = {}): Promise<Doc> {
    const token = scope ? await credential.getToken(scope) : null;
    if (scope && !token) throw new ProviderError(401, "managed_identity_token_unavailable");
    const response = await transport(url, {
      ...init, redirect: "error", signal: AbortSignal.timeout(12000),
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token.token}` } : {}), ...init.headers },
    });
    if (!response.ok) throw new ProviderError(response.status, `upstream_${response.status}`);
    const data: unknown = await response.json();
    if (!isObject(data)) throw new ProviderError(502, "invalid_provider_response");
    if (data.error || data.partialError) throw new ProviderError(502, "provider_partial_error");
    return data;
  }
  async function list(url: string, scope = ARM_SCOPE): Promise<{ items: Doc[]; truncated: boolean }> {
    const items: Doc[] = [];
    const host = new URL(url).origin;
    for (let page = 0; page < 30; page++) {
      const body = await request(url, scope);
      if (!Array.isArray(body.value)) throw new ProviderError(502, "invalid_provider_list");
      items.push(...body.value.filter(isObject));
      const next = body.nextLink ?? body["@odata.nextLink"];
      if (!next) return { items, truncated: false };
      if (typeof next !== "string" || new URL(next).origin !== host) throw new ProviderError(502, "invalid_pagination_origin");
      url = next;
    }
    return { items, truncated: true };
  }
  async function optional(name: string, enabled: boolean, permission: string, action: () => Promise<unknown>): Promise<Capability> {
    if (!enabled) return result("disabled", undefined, `${name}_not_configured`, permission);
    try { const data = await action(); return result(isObject(data) && data.truncated ? "partial" : "available", data); }
    catch (err) {
      const status = err instanceof ProviderError ? err.status : null;
      log(JSON.stringify({ schema: "ccof.admin.integration.v2", capability: name, status, code: err instanceof ProviderError ? err.code : "request_failed" }));
      return result(status === 401 || status === 403 ? "permission_required" : "unavailable", undefined,
        err instanceof ProviderError ? err.code : "request_failed", permission);
    }
  }
  async function resources(): Promise<{ items: Doc[]; truncated: boolean }> {
    if (!validIds || !validScopes) throw new ProviderError(400, "invalid_resource_configuration");
    const items: Doc[] = [];
    let truncated = false;
    for (const scope of scopes) {
      const page = await list(`${ARM}${scope}/resources?api-version=2021-04-01`);
      items.push(...page.items.filter((item) => typeof item.id === "string" && RESOURCE_ID.test(item.id)));
      truncated ||= page.truncated;
    }
    for (const id of configuredIds) items.push({ id, name: id.split("/").at(-1), type: id.split("/providers/")[1]?.split("/").slice(0, 2).join("/") });
    const unique = [...new Map(items.map((item) => [String(item.id).toLowerCase(), item])).values()];
    const hydrated: Doc[] = [];
    for (let start = 0; start < unique.length; start += 8) {
      hydrated.push(...await Promise.all(unique.slice(start, start + 8).map(async (item) => {
        const id = String(item.id);
        const version = /Microsoft.Web\/sites\//i.test(id) ? "2024-04-01" : /CognitiveServices/i.test(id) ? "2025-06-01" : "2024-05-01";
        try { return await request(`${ARM}${id}?api-version=${version}`, ARM_SCOPE); }
        catch (err) {
          const status = err instanceof ProviderError ? err.status : 0;
          truncated = true;
          log(JSON.stringify({ schema: "ccof.admin.integration.v2", capability: "resource_detail", resourceId: id, status }));
          return { ...item, lifecycle: status === 404 ? "not_found" : [401, 403].includes(status) ? "access_denied" : "unavailable" };
        }
      })));
    }
    return { items: hydrated, truncated };
  }
  async function inventoryData() {
    const found = await resources();
    const backends: Doc[] = [];
    const warnings: string[] = [];
    for (const item of found.items.filter((r) => r.type === "Microsoft.ApiManagement/service" && !r.lifecycle)) {
      try {
        const page = await list(`${ARM}${item.id}/backends?api-version=2024-05-01`);
        found.truncated ||= page.truncated;
        for (const backend of page.items) {
          const props = object(backend.properties);
          let host: string | null = null;
          try { host = typeof props.url === "string" ? new URL(props.url).hostname : null; }
          catch { warnings.push(`Invalid backend URL on ${item.id}/${backend.name}`); }
          backends.push({ backendId: backend.name, apimId: item.id, host });
        }
      } catch (err) {
        found.truncated = true;
        warnings.push(`Backend inventory unavailable for ${item.id}`);
        log(JSON.stringify({ schema: "ccof.admin.integration.v2", capability: "backends", status: err instanceof ProviderError ? err.status : null }));
      }
    }
    return {
      resources: found.items.map((r) => {
        const p = object(r.properties);
        const domain = typeof p.customSubDomainName === "string" ? p.customSubDomainName : null;
        return {
          id: r.id, name: r.name, type: r.type, region: r.location, tags: r.tags ?? {},
          provisioningState: p.provisioningState ?? "unknown", runtimeState: p.state ?? "unknown",
          lifecycle: r.lifecycle ?? "observed", publicNetworkAccess: p.publicNetworkAccess ?? "unknown",
          backendIds: domain ? backends.filter((b) => typeof b.host === "string" && b.host.split(".")[0] === domain).map((b) => b.backendId) : [],
        };
      }), backends, truncated: found.truncated, warnings,
    };
  }
  async function logData(kind: "budgets" | "audit" | "runs") {
    if (!logIds.every((id) => /^\/subscriptions\/[a-f0-9-]{36}\/resourceGroups\/[^/]+\/providers\/Microsoft\.[A-Za-z]+\/[A-Za-z]+\/[^/]+$/i.test(id))) {
      throw new ProviderError(400, "invalid_log_resource_ids");
    }
    const schema = kind === "budgets" ? "ccof.reconciler.budget.v1" : kind === "audit" ? "ccof.admin.audit.v1" : "ccof.reconciler.run.v1";
    const tail = kind === "budgets"
      ? '| where tostring(d.scope) == "group" and tostring(d.period) == format_datetime(now(), "yyyy-MM") | summarize arg_max(at, d) by scopeId=tostring(d.scopeId)'
      : kind === "audit"
        ? "| summarize arg_max(at, d) by requestId=tostring(d.requestId), operation=tostring(d.operation), outcome=tostring(d.outcome) | top 200 by at desc"
        : "| summarize arg_max(at, d) by runId=tostring(d.runId), outcome=tostring(d.outcome) | top 200 by at desc";
    const query = `${messages(logIds)} | where tostring(d.schema) == "${schema}" ${tail} | project d=bag_merge(d, bag_pack("observedAt", at))`;
    const body = await request(`https://api.loganalytics.azure.com/v1/workspaces/${env.ADMIN_WORKSPACE_ID}/query`,
      "https://api.loganalytics.io/.default", { method: "POST", body: JSON.stringify({ query, timespan: "P31D" }) });
    if (!Array.isArray(body.tables)) throw new ProviderError(502, "invalid_query_result");
    const table = object(body.tables[0]);
    if (!Array.isArray(table.rows)) throw new ProviderError(502, "invalid_query_rows");
    return table.rows.map((row) => {
      const value = Array.isArray(row) ? row[0] : null;
      if (typeof value === "string") { const parsed: unknown = JSON.parse(value); return object(parsed); }
      return object(value);
    });
  }
  return {
    groups: (query) => optional("directory_search", env.ADMIN_GRAPH_ENABLED === "true", "Microsoft Graph application GroupMember.Read.All; tenant-admin consent", async () => {
      if (query.length < 2 || query.length > 80) throw new ProviderError(400, "search_length_2_to_80");
      const params = new URLSearchParams({ "$select": "id,displayName,securityEnabled", "$filter": `startswith(displayName,'${query.replaceAll("'", "''")}')`, "$top": "25" });
      const body = await request(`https://graph.microsoft.com/v1.0/groups?${params}`, "https://graph.microsoft.com/.default");
      if (!Array.isArray(body.value)) throw new ProviderError(502, "invalid_group_results");
      return { groups: body.value.filter(isObject).map((g) => ({ id: g.id, displayName: g.displayName, securityEnabled: g.securityEnabled })), more: Boolean(body["@odata.nextLink"]) };
    }),
    inventory: async () => {
      const cap = await optional("resource_inventory", configuredIds.length + scopes.length > 0, "Reader on configured resources/discovery scopes", inventoryData);
      if (cap.state === "available" && object(cap.data).truncated) cap.state = "partial";
      return cap;
    },
    deployments: (id) => optional("deployments", configuredIds.length + scopes.length > 0, "Microsoft.CognitiveServices/accounts/deployments/read", async () => {
      if (!RESOURCE_ID.test(id) || !/\/Microsoft.CognitiveServices\/accounts\//i.test(id) ||
        !configuredIds.some((allowed) => allowed.toLowerCase() === id.toLowerCase()) &&
        !scopes.some((scope) => id.toLowerCase().startsWith(`${scope.toLowerCase()}/`))) throw new ProviderError(403, "resource_outside_configured_scopes");
      const page = await list(`${ARM}${id}/deployments?api-version=2025-06-01`);
      return { deployments: page.items.map((d) => ({ name: d.name, model: object(object(d.properties).model).name, state: object(d.properties).provisioningState })), truncated: page.truncated };
    }),
    logs: (kind) => optional(kind, isGuid(env.ADMIN_WORKSPACE_ID) && logIds.length > 0, "Log Analytics Reader on configured workspace; diagnostics routed to it", () => logData(kind)),
    health: () => optional("health", Boolean(env.ADMIN_HEALTH_TARGETS), "Private DNS/network path; optional function key via app-setting reference", async () => {
      const raw: unknown = JSON.parse(env.ADMIN_HEALTH_TARGETS ?? "[]");
      if (!Array.isArray(raw) || raw.length > 30) throw new ProviderError(400, "invalid_health_targets");
      const values: unknown[] = [];
      const probes = raw.map((entry) => async () => {
        const target = object(entry);
        const url = new URL(String(target.url));
        if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash ||
          url.port && url.port !== "443" || !/\.(azurewebsites\.net|azure-api\.net|services\.ai\.azure\.com|cognitiveservices\.azure\.com)$/.test(url.hostname)) {
          throw new ProviderError(400, "invalid_health_target");
        }
        const headers: Record<string, string> = {};
        if (target.keySetting) {
          if (typeof target.keySetting !== "string" || !/^ADMIN_PROBE_KEY_[A-Z0-9_]+$/.test(target.keySetting)) throw new ProviderError(400, "invalid_probe_key_setting");
          const key = env[target.keySetting];
          if (!key) return { name: target.name, state: "not_configured", reason: "probe_key_setting_missing" };
          headers["x-functions-key"] = key;
        }
        try {
          const response = await transport(url, { headers, redirect: "error", signal: AbortSignal.timeout(8000) });
          await response.body?.cancel();
          return { name: target.name, state: response.ok ? "endpoint_responding" : "endpoint_refused", httpStatus: response.status, observedAt: stamp(), evidence: "HTTP response only; not model inference, billing or timer freshness" };
        } catch {
          log(JSON.stringify({ schema: "ccof.admin.integration.v2", capability: "health_probe", outcome: "network_or_tls_failure" }));
          return { name: target.name, state: "unreachable", reason: "dns_network_tls_or_timeout", observedAt: stamp() };
        }
      });
      for (let start = 0; start < probes.length; start += 6) values.push(...await Promise.all(probes.slice(start, start + 6).map((probe) => probe())));
      return values;
    }),
    billed: () => optional("billed_cost", Boolean(env.ADMIN_COST_SCOPE), "Cost Management Reader on ADMIN_COST_SCOPE; billing availability depends on agreement", async () => {
      const scope = env.ADMIN_COST_SCOPE ?? "";
      if (!DISCOVERY_SCOPE.test(scope)) throw new ProviderError(400, "invalid_cost_scope");
      const inventory = await resources();
      const accounts = inventory.items.filter((r) => r.type === "Microsoft.CognitiveServices/accounts").map((r) => r.id);
      if (!accounts.length) throw new ProviderError(400, "no_foundry_accounts_in_inventory");
      const body = await request(`${ARM}${scope}/providers/Microsoft.CostManagement/query?api-version=2023-11-01`, ARM_SCOPE, {
        method: "POST", body: JSON.stringify({
          type: "ActualCost", timeframe: "MonthToDate", dataset: {
            granularity: "None", aggregation: { totalCost: { name: "PreTaxCost", function: "Sum" } },
            grouping: [{ type: "Dimension", name: "ResourceId" }],
            filter: { dimensions: { name: "ResourceId", operator: "In", values: accounts } },
          },
        }),
      });
      const props = object(body.properties);
      if (!Array.isArray(props.columns) || !Array.isArray(props.rows)) throw new ProviderError(502, "invalid_cost_response");
      const columns = props.columns.filter(isObject).map((c) => String(c.name));
      return { costs: props.rows.filter(Array.isArray).map((row) => Object.fromEntries(columns.map((name, i) => [name, row[i]]))),
        truncated: inventory.truncated || Boolean(props.nextLink), basis: "Azure ActualCost month-to-date at resource scope, delayed and unallocated to projects; currency as returned." };
    }),
    retail: () => optional("retail_prices", env.ADMIN_RETAIL_PRICES_ENABLED === "true", "No Azure role; outbound HTTPS to prices.azure.com", async () => {
      const url = new URL("https://prices.azure.com/api/retail/prices");
      url.searchParams.set("$filter", "contains(productName,'Claude')");
      const body = await request(url.href, null);
      if (!Array.isArray(body.Items)) throw new ProviderError(502, "invalid_retail_response");
      return {
        source: url.href, basis: "Published retail meters, not a private offer or guaranteed per-model token price. Explicit mapping and approval required.",
        prices: body.Items.filter(isObject).map((p) => ({
          product: p.productName, sku: p.skuName, meter: p.meterName, region: p.armRegionName,
          unit: p.unitOfMeasure, retailPrice: p.retailPrice, currency: p.currencyCode, effectiveFrom: p.effectiveStartDate,
        })), truncated: Boolean(body.NextPageLink),
      };
    }),
  };
}
