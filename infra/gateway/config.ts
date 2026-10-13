// Loads and validates a gateway configuration file (infra/gateway/config/*.json)
// against infra/gateway/gateway-config.schema.json, then applies the rules the
// schema cannot express. A configuration either validates completely or is
// refused with every problem, each naming its field: nothing is defaulted.

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import type { JsonSchema } from "./json-schema.ts";
import { assertSupportedSchema, validateAgainstSchema } from "./json-schema.ts";

export const SCHEMA_PATH = path.join(path.dirname(fileURLToPath(import.meta.url)), "gateway-config.schema.json");

export type CachingType = "internal" | "external" | "prefer-external";
export type InferenceGeo = "global" | "us";

export interface CrossTenantClientCredentials {
  type: "crossTenantClientCredentials";
  tenantId: string;
  clientId: string;
  clientSecretNamedValue: string;
  authorityHost: string;
  scope: string;
  tokenRequestTimeoutSeconds: number;
}

// A static backend: its credential needs a secret named value in the policy.
// Every other backend comes by data (the resolver's descriptor, C-8).
export interface BackendConfig {
  id: string;
  credential: CrossTenantClientCredentials;
}

export interface GatewayConfig {
  schemaVersion: 1;
  configurationId: string;
  apim: { subscriptionId: string; resourceGroup: string; serviceName: string; apiId: string; gatewayBaseUrl: string; apiPath: string };
  entra: {
    tenantId: string;
    authorityHost: string;
    v1IssuerHost: string;
    audiences: string[];
    delegatedScope: string;
    delegatedClientAppIds: string[];
    testIdentities: { allowAppOnlyTokens: boolean; clientAppIds: string[]; appRole: string | null };
  };
  admission: {
    perPerson: { calls: number; renewalPeriodSeconds: number };
    resolverMisses: { calls: number; renewalPeriodSeconds: number; maxConcurrent: number };
  };
  resolver: { url: string; tokenAudience: string; timeoutSeconds: number; projectHeaderName: string };
  entitlementCache: {
    keyVersion: number;
    cachingType: CachingType;
    allowTtlSeconds: number;
    refusalTtlSeconds: number;
    lastKnownGoodGraceSeconds: number;
    refreshBackoffSeconds: number;
    unavailableRetryAfterSeconds: number;
  };
  tokenLimits: {
    estimatePromptTokens: boolean;
    headers: {
      personRemainingQuota: string;
      personRemainingTokens: string;
      groupRemainingQuota: string;
      groupRemainingTokens: string;
      tokensConsumed: string;
    };
  };
  backends: BackendConfig[];
  inferenceGeo: Record<string, Record<string, InferenceGeo>>;
  forwarding: { defaultAnthropicVersion: string | null };
}

export type ConfigResult = { ok: true; config: GatewayConfig } | { ok: false; problems: string[] };

// Headers the gateway reads, strips or sets itself; a configured name must not
// shadow one of them. Compared case-insensitively, as HTTP header names are.
const RESERVED_HEADERS = [
  "authorization", "x-api-key", "api-key", "anthropic-version", "anthropic-beta", "content-type",
  "content-length", "host", "retry-after", "ocp-apim-subscription-key", "x-ccof-request-id", "x-ccof-entitlement",
];

let cachedSchema: JsonSchema | undefined;

export function loadSchema(): JsonSchema {
  if (!cachedSchema) {
    const schema = JSON.parse(readFileSync(SCHEMA_PATH, "utf8")) as JsonSchema;
    assertSupportedSchema(schema);
    cachedSchema = schema;
  }
  return cachedSchema;
}

export function loadGatewayConfig(filePath: string): ConfigResult {
  if (!existsSync(filePath)) return { ok: false, problems: [`configuration file not found: ${filePath}`] };
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(filePath, "utf8"));
  } catch (err: unknown) {
    const reason = err instanceof Error ? err.message : String(err);
    return { ok: false, problems: [`configuration file cannot be read as JSON: ${filePath}: ${reason}`] };
  }
  return validateGatewayConfig(raw);
}

export function validateGatewayConfig(raw: unknown): ConfigResult {
  const problems = validateAgainstSchema(loadSchema(), raw);
  if (problems.length === 0) problems.push(...crossFieldProblems(raw as GatewayConfig));
  return problems.length === 0 ? { ok: true, config: raw as GatewayConfig } : { ok: false, problems };
}

function crossFieldProblems(config: GatewayConfig): string[] {
  const problems: string[] = [];

  const ids = config.backends.map((b) => b.id);
  const duplicates = ids.filter((id, i) => ids.indexOf(id) !== i);
  if (duplicates.length > 0) problems.push(`backends: duplicate backend id(s): ${[...new Set(duplicates)].join(", ")}`);

  const cache = config.entitlementCache;
  if (cache.lastKnownGoodGraceSeconds > 0 && cache.refreshBackoffSeconds > cache.lastKnownGoodGraceSeconds) {
    problems.push("entitlementCache.refreshBackoffSeconds: must not exceed lastKnownGoodGraceSeconds");
  }

  const { allowAppOnlyTokens, clientAppIds, appRole } = config.entra.testIdentities;
  if (allowAppOnlyTokens && clientAppIds.length === 0) {
    problems.push("entra.testIdentities.clientAppIds: name at least one client application when allowAppOnlyTokens is true");
  }
  if (!allowAppOnlyTokens && clientAppIds.length > 0) {
    problems.push("entra.testIdentities.clientAppIds: must be empty when allowAppOnlyTokens is false");
  }
  if (allowAppOnlyTokens && appRole === null) {
    problems.push("entra.testIdentities.appRole: name the app role an app-only token must carry when allowAppOnlyTokens is true");
  }
  if (!allowAppOnlyTokens && appRole !== null) {
    problems.push("entra.testIdentities.appRole: must be null when allowAppOnlyTokens is false");
  }

  const headerFields: Array<[string, string]> = [
    ["resolver.projectHeaderName", config.resolver.projectHeaderName],
    ...Object.entries(config.tokenLimits.headers).map(([k, v]): [string, string] => [`tokenLimits.headers.${k}`, v]),
  ];
  const seen = new Map<string, string>();
  for (const [field, name] of headerFields) {
    const key = name.toLowerCase();
    if (RESERVED_HEADERS.includes(key)) problems.push(`${field}: "${name}" is a header the gateway reserves`);
    const earlier = seen.get(key);
    if (earlier) problems.push(`${field}: "${name}" is already used by ${earlier}`);
    else seen.set(key, field);
  }
  return problems;
}
