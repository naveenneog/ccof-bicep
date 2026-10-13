// Settings for the sync. Every value is an administrator's decision recorded by
// the deploy script or a settings file: there are no defaults in code, and a
// missing or invalid value refuses the run before any Azure call (ADR-0016).

import { GUID } from "./types.ts";

export type MemberType = "user" | "servicePrincipal";
export type WriteMode = "apply" | "dry-run";

export interface SyncConfig {
  tenantId: string;
  cosmosEndpoint: string;
  cosmosDatabase: string;
  projectsContainer: string;
  entitlementContainer: string;
  leaseContainer: string;
  leaseSeconds: number;
  memberTypes: MemberType[];
  maxRemovalsPerRun: number;
  maxRemovalFraction: number;
  graphMaxRetries: number;
  graphMaxRetryAfterSeconds: number;
  graphTimeoutSeconds: number;
  writeMode: WriteMode;
}

export interface ConfigProblem {
  setting: string;
  problem: string;
}

export type ConfigResult = { ok: true; config: SyncConfig } | { ok: false; problems: ConfigProblem[] };

export const SETTING_NAMES = [
  "SYNC_TENANT_ID",
  "COSMOS_ENDPOINT",
  "COSMOS_DATABASE",
  "SYNC_PROJECTS_CONTAINER",
  "SYNC_ENTITLEMENT_CONTAINER",
  "SYNC_LEASE_CONTAINER",
  "SYNC_LEASE_SECONDS",
  "SYNC_MEMBER_TYPES",
  "SYNC_MAX_REMOVALS_PER_RUN",
  "SYNC_MAX_REMOVAL_FRACTION",
  "SYNC_GRAPH_MAX_RETRIES",
  "SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS",
  "SYNC_GRAPH_TIMEOUT_SECONDS",
  "SYNC_WRITE_MODE",
] as const;

type Settings = Readonly<Record<string, string | undefined>>;

const COSMOS_NAME = /^[A-Za-z0-9][A-Za-z0-9_-]{0,254}$/;
const WHOLE_NUMBER = /^\d{1,10}$/;
// At most six decimal places, so the removal check can run in integers.
const FRACTION = /^(0(\.\d{1,6})?|1(\.0{1,6})?)$/;
const MEMBER_TYPES: readonly MemberType[] = ["servicePrincipal", "user"];

class Reader {
  readonly problems: ConfigProblem[] = [];
  private readonly settings: Settings;

  constructor(settings: Settings) {
    this.settings = settings;
  }

  raw(name: string): string | undefined {
    const value = this.settings[name]?.trim();
    if (!value) {
      this.problems.push({ setting: name, problem: "missing" });
      return undefined;
    }
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

  integer(name: string, min: number, max: number): number | undefined {
    const value = this.raw(name);
    if (value === undefined) return undefined;
    if (!WHOLE_NUMBER.test(value)) return this.fail(name, "invalid");
    const n = Number(value);
    return n >= min && n <= max ? n : this.fail(name, "out_of_range");
  }
}

function isCosmosEndpoint(value: string): boolean {
  if (!URL.canParse(value)) return false;
  const url = new URL(value);
  return url.protocol === "https:" && url.hostname.endsWith(".documents.azure.com") && url.pathname === "/";
}

function readMemberTypes(r: Reader): MemberType[] | undefined {
  const value = r.raw("SYNC_MEMBER_TYPES");
  if (value === undefined) return undefined;
  const parts = value.split(",").map((p) => p.trim());
  const valid = parts.every((p): p is MemberType => (MEMBER_TYPES as readonly string[]).includes(p));
  if (!valid || new Set(parts).size !== parts.length) return r.fail("SYNC_MEMBER_TYPES", "invalid");
  return [...parts].sort() as MemberType[];
}

export function readSyncConfig(settings: Settings): ConfigResult {
  const r = new Reader(settings);
  const tenantId = r.matching("SYNC_TENANT_ID", GUID)?.toLowerCase();
  const endpointRaw = r.raw("COSMOS_ENDPOINT");
  const cosmosEndpoint = endpointRaw === undefined ? undefined : isCosmosEndpoint(endpointRaw) ? endpointRaw : r.fail("COSMOS_ENDPOINT", "invalid");
  const cosmosDatabase = r.matching("COSMOS_DATABASE", COSMOS_NAME);
  const projectsContainer = r.matching("SYNC_PROJECTS_CONTAINER", COSMOS_NAME);
  const entitlementContainer = r.matching("SYNC_ENTITLEMENT_CONTAINER", COSMOS_NAME);
  const leaseContainer = r.matching("SYNC_LEASE_CONTAINER", COSMOS_NAME);
  const leaseSeconds = r.integer("SYNC_LEASE_SECONDS", 1, 86400);
  const memberTypes = readMemberTypes(r);
  const maxRemovalsPerRun = r.integer("SYNC_MAX_REMOVALS_PER_RUN", 0, 10_000_000);
  const fractionRaw = r.matching("SYNC_MAX_REMOVAL_FRACTION", FRACTION);
  const graphMaxRetries = r.integer("SYNC_GRAPH_MAX_RETRIES", 0, 10);
  const graphMaxRetryAfterSeconds = r.integer("SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS", 1, 3600);
  const graphTimeoutSeconds = r.integer("SYNC_GRAPH_TIMEOUT_SECONDS", 1, 300);
  const modeRaw = r.raw("SYNC_WRITE_MODE");
  const writeMode = modeRaw === undefined ? undefined : modeRaw === "apply" || modeRaw === "dry-run" ? modeRaw : r.fail("SYNC_WRITE_MODE", "invalid");

  // Three distinct containers: the sync must never treat projects or its own
  // lease as entitlement.
  if (projectsContainer && entitlementContainer && projectsContainer === entitlementContainer) {
    r.fail("SYNC_ENTITLEMENT_CONTAINER", "same_as_other_container");
  }
  if (leaseContainer && (leaseContainer === entitlementContainer || leaseContainer === projectsContainer)) {
    r.fail("SYNC_LEASE_CONTAINER", "same_as_other_container");
  }
  // The longest gap between lease renewals is one Graph request plus one
  // Retry-After wait; the lease must outlast twice that.
  if (leaseSeconds !== undefined && graphMaxRetryAfterSeconds !== undefined && graphTimeoutSeconds !== undefined) {
    if (leaseSeconds < 2 * (graphMaxRetryAfterSeconds + graphTimeoutSeconds)) r.fail("SYNC_LEASE_SECONDS", "shorter_than_graph_wait");
  }

  if (r.problems.length > 0) return { ok: false, problems: r.problems };
  return {
    ok: true,
    config: {
      tenantId: tenantId as string,
      cosmosEndpoint: cosmosEndpoint as string,
      cosmosDatabase: cosmosDatabase as string,
      projectsContainer: projectsContainer as string,
      entitlementContainer: entitlementContainer as string,
      leaseContainer: leaseContainer as string,
      leaseSeconds: leaseSeconds as number,
      memberTypes: memberTypes as MemberType[],
      maxRemovalsPerRun: maxRemovalsPerRun as number,
      maxRemovalFraction: Number(fractionRaw),
      graphMaxRetries: graphMaxRetries as number,
      graphMaxRetryAfterSeconds: graphMaxRetryAfterSeconds as number,
      graphTimeoutSeconds: graphTimeoutSeconds as number,
      writeMode: writeMode as WriteMode,
    },
  };
}

// Settings only the Function App host reads: which managed identity to use,
// and the timer schedule (NCRONTAB, six fields, read by the Functions host as
// %SYNC_SCHEDULE%).
export type HostSettings = { ok: true; managedIdentityClientId: string } | { ok: false; problems: ConfigProblem[] };

const NCRONTAB = /^\S+( \S+){5}$/;

export function readHostSettings(settings: Settings): HostSettings {
  const r = new Reader(settings);
  const clientId = r.matching("SYNC_MANAGED_IDENTITY_CLIENT_ID", GUID);
  r.matching("SYNC_SCHEDULE", NCRONTAB);
  if (r.problems.length > 0) return { ok: false, problems: r.problems };
  return { ok: true, managedIdentityClientId: (clientId as string).toLowerCase() };
}

// The workstation snapshot reads Graph only: tenant and the Graph retry budget.
export interface GraphSettings {
  tenantId: string;
  graphMaxRetries: number;
  graphMaxRetryAfterSeconds: number;
  graphTimeoutSeconds: number;
}

export function readGraphSettings(settings: Settings): { ok: true; settings: GraphSettings } | { ok: false; problems: ConfigProblem[] } {
  const r = new Reader(settings);
  const tenantId = r.matching("SYNC_TENANT_ID", GUID)?.toLowerCase();
  const graphMaxRetries = r.integer("SYNC_GRAPH_MAX_RETRIES", 0, 10);
  const graphMaxRetryAfterSeconds = r.integer("SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS", 1, 3600);
  const graphTimeoutSeconds = r.integer("SYNC_GRAPH_TIMEOUT_SECONDS", 1, 300);
  if (r.problems.length > 0) return { ok: false, problems: r.problems };
  return {
    ok: true,
    settings: {
      tenantId: tenantId as string,
      graphMaxRetries: graphMaxRetries as number,
      graphMaxRetryAfterSeconds: graphMaxRetryAfterSeconds as number,
      graphTimeoutSeconds: graphTimeoutSeconds as number,
    },
  };
}

// Limits apply-snapshot checks before anything is written.
export interface SnapshotLimitSettings {
  maxAgeSeconds: number;
  maxBytes: number;
  maxGroups: number;
  maxMembers: number;
}

export function readSnapshotLimits(settings: Settings): { ok: true; limits: SnapshotLimitSettings } | { ok: false; problems: ConfigProblem[] } {
  const r = new Reader(settings);
  const maxAgeSeconds = r.integer("SYNC_SNAPSHOT_MAX_AGE_SECONDS", 1, 86400);
  const maxBytes = r.integer("SYNC_SNAPSHOT_MAX_BYTES", 1, 64 * 1024 * 1024);
  const maxGroups = r.integer("SYNC_SNAPSHOT_MAX_GROUPS", 1, 100_000);
  const maxMembers = r.integer("SYNC_SNAPSHOT_MAX_MEMBERS", 1, 10_000_000);
  if (r.problems.length > 0) return { ok: false, problems: r.problems };
  return { ok: true, limits: { maxAgeSeconds: maxAgeSeconds as number, maxBytes: maxBytes as number, maxGroups: maxGroups as number, maxMembers: maxMembers as number } };
}
