// Reconciler settings (ADR-0018 decision 9). Every value is an administrator's
// decision, written as an app setting by infra/reconciler: there are no
// defaults, and a missing or invalid value refuses the run before any Azure
// call. Problems name the setting and a code, never the value. The pacing
// pair (ADR 0035) is the one optional group: neither set means no pacing.

import { gatewayListProblem, includesGateway, splitGatewayList } from "../contracts/gateway-resource-ids.ts";
import type { SpendPacing } from "./compute-ceiling.ts";

export interface ReconcilerContainers {
  projects: string;
  entitlement: string;
  budgetState: string;
  aggregateState: string;
  lease: string;
}

export interface ReconcilerSettings {
  managedIdentityClientId: string;
  intervalMinutes: number;
  validitySeconds: number;
  leaseSeconds: number;
  workspaceId: string;
  // The query API's base URL for the workspace's cloud; the token audience
  // is the same URL (public cloud: https://api.loganalytics.io).
  logAnalyticsEndpoint: string;
  // One APIM id, or up to four (active/passive DR): the ledger counts each request once.
  gatewayResourceIds: string[];
  ledgerTimeoutSeconds: number;
  ledgerMaxRows: number;
  maxStates: number;
  writeConcurrency: number;
  cosmosEndpoint: string;
  cosmosDatabase: string;
  // ADR 0035: null unless both pacing settings are set.
  pacing: SpendPacing | null;
  containers: ReconcilerContainers;
}

export interface SettingProblem {
  setting: string;
  problem: string;
}

export type SettingsResult = { ok: true; settings: ReconcilerSettings } | { ok: false; problems: SettingProblem[] };

export const SETTING_NAMES = [
  "RECONCILER_MANAGED_IDENTITY_CLIENT_ID",
  "RECONCILER_SCHEDULE",
  "RECONCILER_VALIDITY_SECONDS",
  "RECONCILER_LEASE_SECONDS",
  "RECONCILER_LOG_ANALYTICS_WORKSPACE_ID",
  "RECONCILER_LOG_ANALYTICS_ENDPOINT",
  "RECONCILER_LEDGER_GATEWAY_RESOURCE_ID",
  "RECONCILER_LEDGER_TIMEOUT_SECONDS",
  "RECONCILER_LEDGER_MAX_ROWS",
  "RECONCILER_MAX_STATES",
  "RECONCILER_WRITE_CONCURRENCY",
  "COSMOS_ENDPOINT",
  "COSMOS_DATABASE",
  "RECONCILER_PROJECTS_CONTAINER",
  "RECONCILER_ENTITLEMENT_CONTAINER",
  "RECONCILER_BUDGET_STATE_CONTAINER",
  "RECONCILER_AGGREGATE_STATE_CONTAINER",
  "RECONCILER_LEASE_CONTAINER",
] as const;

export const GATEWAY_LIST_SETTING = "RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS";

export const PACING_SETTING_NAMES = ["RECONCILER_SOFT_LIMIT_PERCENT", "RECONCILER_PACING_WINDOW_MINUTES"] as const;

type Settings = Readonly<Record<string, string | undefined>>;

export const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
// Only "every N minutes": the interval must be known to check the validity.
const EVERY_N_MINUTES = /^0 \*\/([1-9]|[1-5][0-9]) \* \* \* \*$/;
// The APIM resource id is interpolated into KQL as a string literal, so its
// pattern admits no quote or backslash (WP-ONB's Stage 2 pattern).
const APIM_RESOURCE_ID = /^\/subscriptions\/[0-9a-fA-F-]{36}\/resourceGroups\/[A-Za-z0-9._-]+\/providers\/Microsoft\.ApiManagement\/service\/[A-Za-z0-9-]+$/;
const COSMOS_NAME = /^[A-Za-z0-9][A-Za-z0-9_-]{0,254}$/;
const WHOLE_NUMBER = /^\d{1,10}$/;

// Documented platform bounds: the query API runs a query for at most 10
// minutes and returns at most 500,000 records (Learn, "Azure Monitor service
// limits", retrieved 2026-10-11). The other upper bounds catch typos: a
// validity of more than a day would let stale state pass as fresh
// (ADR-0008, "A wrong validUntil far in the future").
const RANGES = {
  RECONCILER_VALIDITY_SECONDS: [1, 86_400],
  RECONCILER_LEASE_SECONDS: [1, 86_400],
  RECONCILER_LEDGER_TIMEOUT_SECONDS: [1, 600],
  RECONCILER_LEDGER_MAX_ROWS: [1, 500_000],
  RECONCILER_MAX_STATES: [1, 10_000_000],
  RECONCILER_WRITE_CONCURRENCY: [1, 32],
  RECONCILER_SOFT_LIMIT_PERCENT: [1, 99],
  RECONCILER_PACING_WINDOW_MINUTES: [1, 120],
} as const;

class Reader {
  readonly problems: SettingProblem[] = [];
  private readonly settings: Settings;

  constructor(settings: Settings) {
    this.settings = settings;
  }

  raw(name: string): string | undefined {
    const value = this.settings[name]?.trim();
    if (!value) return this.fail(name, "missing");
    return value;
  }

  fail(name: string, problem: string): undefined {
    this.problems.push({ setting: name, problem });
    return undefined;
  }

  matching(name: string, pattern: RegExp): string | undefined {
    const value = this.raw(name);
    if (value === undefined) return undefined;
    return pattern.test(value) ? value : this.fail(name, "invalid");
  }

  integer(name: keyof typeof RANGES): number | undefined {
    const value = this.raw(name);
    if (value === undefined) return undefined;
    if (!WHOLE_NUMBER.test(value)) return this.fail(name, "invalid");
    const n = Number(value);
    const [min, max] = RANGES[name];
    return n >= min && n <= max ? n : this.fail(name, "out_of_range");
  }
}

function isCosmosEndpoint(value: string): boolean {
  if (!URL.canParse(value)) return false;
  const url = new URL(value);
  return url.protocol === "https:" && url.hostname.endsWith(".documents.azure.com") && url.pathname === "/" && !url.search && !url.username;
}

// An https origin only: the client appends /v1/workspaces/<id>/query, and the
// token is requested for this origin.
function isHttpsOrigin(value: string): boolean {
  if (!URL.canParse(value)) return false;
  const url = new URL(value);
  return url.protocol === "https:" && url.pathname === "/" && !url.search && !url.hash && !url.username && !url.password && !value.endsWith("/");
}

function readContainers(r: Reader): Partial<ReconcilerContainers> {
  const containers = {
    projects: r.matching("RECONCILER_PROJECTS_CONTAINER", COSMOS_NAME),
    entitlement: r.matching("RECONCILER_ENTITLEMENT_CONTAINER", COSMOS_NAME),
    budgetState: r.matching("RECONCILER_BUDGET_STATE_CONTAINER", COSMOS_NAME),
    aggregateState: r.matching("RECONCILER_AGGREGATE_STATE_CONTAINER", COSMOS_NAME),
    lease: r.matching("RECONCILER_LEASE_CONTAINER", COSMOS_NAME),
  };
  // Each container the reconciler writes must differ from every other one it
  // uses: it must never write into what it reads, or its lease into state.
  const settingOf: Record<keyof ReconcilerContainers, string> = {
    projects: "RECONCILER_PROJECTS_CONTAINER",
    entitlement: "RECONCILER_ENTITLEMENT_CONTAINER",
    budgetState: "RECONCILER_BUDGET_STATE_CONTAINER",
    aggregateState: "RECONCILER_AGGREGATE_STATE_CONTAINER",
    lease: "RECONCILER_LEASE_CONTAINER",
  };
  const order: Array<keyof ReconcilerContainers> = ["projects", "entitlement", "budgetState", "aggregateState", "lease"];
  order.forEach((key, index) => {
    const name = containers[key];
    if (index < 2 || name === undefined) return;
    if (order.slice(0, index).some((earlier) => containers[earlier] === name)) r.fail(settingOf[key], "same_as_other_container");
  });
  return containers;
}

// Both pacing settings or neither: one alone names the other as missing. A
// window shorter than the timer interval cannot bound spend between runs.
function readPacing(r: Reader, settings: Settings, intervalMinutes: number | undefined): SpendPacing | undefined {
  if (!PACING_SETTING_NAMES.some((name) => settings[name]?.trim())) return undefined;
  const softLimitPercent = r.integer("RECONCILER_SOFT_LIMIT_PERCENT");
  const windowMinutes = r.integer("RECONCILER_PACING_WINDOW_MINUTES");
  if (softLimitPercent === undefined || windowMinutes === undefined) return undefined;
  if (intervalMinutes !== undefined && windowMinutes < intervalMinutes) {
    return r.fail("RECONCILER_PACING_WINDOW_MINUTES", "shorter_than_interval");
  }
  return { softLimitPercent, windowMinutes };
}

// RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS (DR) is optional; without it the single id is required.
// With both, the single id must be one of the list, so two settings cannot name different gateways.
function readGateways(r: Reader, settings: Settings): string[] | undefined {
  const list = settings[GATEWAY_LIST_SETTING]?.trim();
  if (!list) {
    const single = r.matching("RECONCILER_LEDGER_GATEWAY_RESOURCE_ID", APIM_RESOURCE_ID);
    return single === undefined ? undefined : [single];
  }
  const ids = splitGatewayList(list);
  const problem = gatewayListProblem(ids, APIM_RESOURCE_ID);
  if (problem !== undefined) return r.fail(GATEWAY_LIST_SETTING, problem);
  const single = settings.RECONCILER_LEDGER_GATEWAY_RESOURCE_ID?.trim();
  if (single && !includesGateway(ids, single)) return r.fail(GATEWAY_LIST_SETTING, "single_not_in_list");
  return ids;
}

export function readReconcilerSettings(settings: Settings): SettingsResult {
  const r = new Reader(settings);
  const managedIdentityClientId = r.matching("RECONCILER_MANAGED_IDENTITY_CLIENT_ID", GUID)?.toLowerCase();
  const schedule = r.matching("RECONCILER_SCHEDULE", EVERY_N_MINUTES);
  const intervalMinutes = schedule === undefined ? undefined : Number(EVERY_N_MINUTES.exec(schedule)?.[1]);
  const validitySeconds = r.integer("RECONCILER_VALIDITY_SECONDS");
  const leaseSeconds = r.integer("RECONCILER_LEASE_SECONDS");
  const workspaceId = r.matching("RECONCILER_LOG_ANALYTICS_WORKSPACE_ID", GUID)?.toLowerCase();
  const endpointLa = r.raw("RECONCILER_LOG_ANALYTICS_ENDPOINT");
  const logAnalyticsEndpoint =
    endpointLa === undefined ? undefined : isHttpsOrigin(endpointLa) ? endpointLa : r.fail("RECONCILER_LOG_ANALYTICS_ENDPOINT", "invalid");
  const gatewayResourceIds = readGateways(r, settings);
  const ledgerTimeoutSeconds = r.integer("RECONCILER_LEDGER_TIMEOUT_SECONDS");
  const ledgerMaxRows = r.integer("RECONCILER_LEDGER_MAX_ROWS");
  const maxStates = r.integer("RECONCILER_MAX_STATES");
  const writeConcurrency = r.integer("RECONCILER_WRITE_CONCURRENCY");
  const endpointRaw = r.raw("COSMOS_ENDPOINT");
  const cosmosEndpoint = endpointRaw === undefined ? undefined : isCosmosEndpoint(endpointRaw) ? endpointRaw : r.fail("COSMOS_ENDPOINT", "invalid");
  const cosmosDatabase = r.matching("COSMOS_DATABASE", COSMOS_NAME);
  const containers = readContainers(r);
  const pacing = readPacing(r, settings, intervalMinutes);

  // A healthy run renews state before the previous run's state lapses only if
  // the validity outlasts the interval plus the longest ledger read.
  if (validitySeconds !== undefined && intervalMinutes !== undefined && ledgerTimeoutSeconds !== undefined) {
    if (validitySeconds <= intervalMinutes * 60 + ledgerTimeoutSeconds) {
      r.fail("RECONCILER_VALIDITY_SECONDS", "not_above_interval_plus_ledger_timeout");
    }
  }
  // The lease is renewed before the writes; one ledger read must not outlast it.
  if (leaseSeconds !== undefined && ledgerTimeoutSeconds !== undefined && leaseSeconds < 2 * ledgerTimeoutSeconds) {
    r.fail("RECONCILER_LEASE_SECONDS", "shorter_than_twice_ledger_timeout");
  }

  if (r.problems.length > 0) return { ok: false, problems: r.problems };
  return {
    ok: true,
    settings: {
      managedIdentityClientId: managedIdentityClientId as string,
      intervalMinutes: intervalMinutes as number,
      validitySeconds: validitySeconds as number,
      leaseSeconds: leaseSeconds as number,
      workspaceId: workspaceId as string,
      logAnalyticsEndpoint: logAnalyticsEndpoint as string,
      gatewayResourceIds: gatewayResourceIds as string[],
      ledgerTimeoutSeconds: ledgerTimeoutSeconds as number,
      ledgerMaxRows: ledgerMaxRows as number,
      maxStates: maxStates as number,
      writeConcurrency: writeConcurrency as number,
      cosmosEndpoint: cosmosEndpoint as string,
      cosmosDatabase: cosmosDatabase as string,
      pacing: pacing ?? null,
      containers: containers as ReconcilerContainers,
    },
  };
}
