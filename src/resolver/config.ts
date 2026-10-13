// The resolver's configuration (ADR-0008 decision 5; docs/PILOT.md C-3). Every
// value comes from an app setting that an administrator sets; nothing here has
// a default. A missing or invalid setting is reported by name and problem, and
// the resolver then refuses every request rather than run on a guessed value.

import type { BudgetEnforcement, BudgetStalenessPolicy } from "./freshness.ts";

export const RESOLVER_SETTINGS = {
  cosmosEndpoint: "COSMOS_ENDPOINT",
  cosmosDatabase: "COSMOS_DATABASE",
  cosmosRequestTimeoutMs: "RESOLVER_COSMOS_REQUEST_TIMEOUT_MS",
  cosmosRetryAttempts: "RESOLVER_COSMOS_RETRY_ATTEMPTS",
  cosmosRetryMaxWaitSeconds: "RESOLVER_COSMOS_RETRY_MAX_WAIT_SECONDS",
  requestDeadlineMs: "RESOLVER_REQUEST_DEADLINE_MS",
  budgetEnforcement: "RESOLVER_BUDGET_ENFORCEMENT",
  budgetStateGraceSeconds: "RESOLVER_BUDGET_STATE_GRACE_SECONDS",
  budgetStateHardLimitSeconds: "RESOLVER_BUDGET_STATE_HARD_LIMIT_SECONDS",
} as const;

// The Cosmos client's limits are availability settings (ADR-0014 decision 6):
// the resolver's worst case must stay below the gateway's resolver timeout.
export interface CosmosClientSettings {
  endpoint: string;
  databaseName: string;
  requestTimeoutMs: number;
  retryAttempts: number;
  retryMaxWaitSeconds: number;
}

export interface ResolverConfig {
  cosmos: CosmosClientSettings;
  // The longest one resolve request may take in the resolver's own code; past
  // it the resolver answers 503 and stops its reads.
  requestDeadlineMs: number;
  budgetEnforcement: BudgetEnforcement;
}

export type ConfigProblemCode =
  | "missing"
  | "not_https_url"
  | "invalid_database_name"
  | "not_whole_number"
  | "unknown_mode"
  | "not_whole_seconds"
  | "out_of_range"
  | "grace_exceeds_hard_limit";

export interface ConfigProblem {
  setting: string;
  problem: ConfigProblemCode;
}

export type ResolverConfigResult = { ok: true; config: ResolverConfig } | { ok: false; problems: ConfigProblem[] };

type Env = Readonly<Record<string, string | undefined>>;
type Parsed<T> = { value: T } | { problem: ConfigProblemCode };

// Characters that would change a Cosmos resource path, and whitespace an
// administrator is unlikely to have meant.
const DATABASE_NAME = /^[^\s/\\?#]{1,255}$/;

export function readResolverConfig(env: Env): ResolverConfigResult {
  const problems: ConfigProblem[] = [];
  const report = (setting: string, problem: ConfigProblemCode) => problems.push({ setting, problem });
  const read: Reader = (setting, parse) => {
    const raw = env[setting];
    const parsed = raw === undefined || raw === "" ? ({ problem: "missing" } as const) : parse(raw);
    if ("problem" in parsed) {
      report(setting, parsed.problem);
      return undefined;
    }
    return parsed.value;
  };

  const endpoint = read(RESOLVER_SETTINGS.cosmosEndpoint, parseHttpsUrl);
  const databaseName = read(RESOLVER_SETTINGS.cosmosDatabase, (raw) =>
    DATABASE_NAME.test(raw) ? { value: raw } : { problem: "invalid_database_name" },
  );
  const requestTimeoutMs = read(RESOLVER_SETTINGS.cosmosRequestTimeoutMs, (raw) => parseWholeNumber(raw, 1, MAX_TIMER_MS));
  const retryAttempts = read(RESOLVER_SETTINGS.cosmosRetryAttempts, (raw) => parseWholeNumber(raw, 0));
  const retryMaxWaitSeconds = read(RESOLVER_SETTINGS.cosmosRetryMaxWaitSeconds, (raw) => parseWholeNumber(raw, 0));
  const requestDeadlineMs = read(RESOLVER_SETTINGS.requestDeadlineMs, (raw) => parseWholeNumber(raw, 1, MAX_TIMER_MS));
  const mode = read(RESOLVER_SETTINGS.budgetEnforcement, parseEnforcementMode);
  // The durations matter only to budget-state; without a known mode it is not
  // yet known whether they are required.
  const staleness = mode === "budget-state" ? readStaleness(read, report) : undefined;

  if (
    problems.length > 0 ||
    endpoint === undefined ||
    databaseName === undefined ||
    requestTimeoutMs === undefined ||
    retryAttempts === undefined ||
    retryMaxWaitSeconds === undefined ||
    requestDeadlineMs === undefined ||
    mode === undefined
  ) {
    return { ok: false, problems };
  }
  const budgetEnforcement: BudgetEnforcement =
    mode === "budget-state" ? { mode, staleness: staleness as BudgetStalenessPolicy } : { mode };
  return {
    ok: true,
    config: {
      cosmos: { endpoint, databaseName, requestTimeoutMs, retryAttempts, retryMaxWaitSeconds },
      requestDeadlineMs,
      budgetEnforcement,
    },
  };
}

type Reader = <T>(setting: string, parse: (raw: string) => Parsed<T>) => T | undefined;

function readStaleness(
  read: Reader,
  report: (setting: string, problem: ConfigProblemCode) => void,
): BudgetStalenessPolicy | undefined {
  const graceSeconds = read(RESOLVER_SETTINGS.budgetStateGraceSeconds, parseWholeSeconds);
  const hardLimitSeconds = read(RESOLVER_SETTINGS.budgetStateHardLimitSeconds, parseWholeSeconds);
  if (graceSeconds === undefined || hardLimitSeconds === undefined) return undefined;
  if (graceSeconds > hardLimitSeconds) {
    report(RESOLVER_SETTINGS.budgetStateGraceSeconds, "grace_exceeds_hard_limit");
    return undefined;
  }
  return { graceSeconds, hardLimitSeconds };
}

// Exact, case-sensitive values: a near miss is reported, never interpreted.
function parseEnforcementMode(raw: string): Parsed<BudgetEnforcement["mode"]> {
  return raw === "token-limits-only" || raw === "budget-state" ? { value: raw } : { problem: "unknown_mode" };
}

function parseHttpsUrl(raw: string): Parsed<string> {
  return URL.canParse(raw) && new URL(raw).protocol === "https:" ? { value: raw } : { problem: "not_https_url" };
}

// Digits only: no sign, unit, exponent, fraction or surrounding space, so the
// value the administrator wrote is the value used.
function parseWholeSeconds(raw: string): Parsed<number> {
  if (!/^\d+$/.test(raw)) return { problem: "not_whole_seconds" };
  const seconds = Number(raw);
  return Number.isSafeInteger(seconds * 1000) ? { value: seconds } : { problem: "out_of_range" };
}

// Node runs a longer setTimeout after 1 ms, and AbortSignal.timeout throws from
// 2^32: a millisecond setting above this would refuse every request.
const MAX_TIMER_MS = 2147483647;

function parseWholeNumber(raw: string, minimum: number, maximum: number = Number.MAX_SAFE_INTEGER): Parsed<number> {
  if (!/^\d+$/.test(raw)) return { problem: "not_whole_number" };
  const value = Number(raw);
  return Number.isSafeInteger(value) && value >= minimum && value <= maximum ? { value } : { problem: "out_of_range" };
}
