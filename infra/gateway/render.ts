// Renders the claude-messages policy from a validated gateway configuration.
//
//   node infra/gateway/render.ts --config infra/gateway/config/<env>.json [--out <dir>]
//
// The template (policy/claude-messages.template.xml) and the backend fragments
// carry no environment value: this module derives every value from the
// configuration, refuses a template that carries a literal (template.ts), and
// checks the result is a well-formed policy with no placeholder left and no
// named value other than the configured backend secrets. Output goes to
// infra/gateway/out/ (git-ignored) as <apiId>.policy.xml plus render.json with
// the configuration, template and policy digests the deploy script records.

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { parseApimXml } from "./apim-xml.ts";
import type { BackendConfig, GatewayConfig } from "./config.ts";
import { loadGatewayConfig, validateGatewayConfig } from "./config.ts";
import type { TemplateValue } from "./template.ts";
import { fillPlaceholders, findTemplateLiterals, placeholdersIn } from "./template.ts";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const POLICY_DIR = path.join(HERE, "policy");
export const DEFAULT_OUT_DIR = path.join(HERE, "out");

export interface Templates {
  main: string;
  fragments: Record<string, string>;
}

export interface RenderResult {
  configurationId: string;
  apiId: string;
  policyXml: string;
  policySha256: string;
  configSha256: string;
  templateSha256: string;
}

// Static backends need a secret named value in the policy; every other
// backend is routed by data (C-8) through the template's generic branches.
const FRAGMENT_FOR: Record<BackendConfig["credential"]["type"], string> = {
  crossTenantClientCredentials: "backend-cross-tenant-client-credentials",
};

export function loadTemplates(): Templates {
  const read = (name: string) => readFileSync(path.join(POLICY_DIR, name), "utf8");
  return {
    main: read("claude-messages.template.xml"),
    fragments: Object.fromEntries(Object.values(FRAGMENT_FOR).map((name) => [name, read(`${name}.xml`)])),
  };
}

const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");

// Key order does not change the digest: the same settings give the same stamp.
function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>).filter(([k]) => k !== "$schema").sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

const csharpStrings = (items: string[]) => ({ xml: items.map((s) => `"${s}"`).join(", ") });

function backendValues(backend: BackendConfig): Record<string, TemplateValue> {
  const credential = backend.credential;
  return {
    BACKEND_ID: backend.id,
    CLIENT_SECRET_NAMED_VALUE: credential.clientSecretNamedValue,
    TOKEN_URL: `${credential.authorityHost}/${credential.tenantId}/oauth2/v2.0/token`,
    CLIENT_ID: credential.clientId,
    SCOPE: credential.scope,
    TOKEN_TIMEOUT: String(credential.tokenRequestTimeoutSeconds),
  };
}

function mainValues(config: GatewayConfig, backendBranches: string, digests: { config: string; template: string }): Record<string, TemplateValue> {
  const { entra, admission, resolver, entitlementCache: cache, tokenLimits, forwarding } = config;
  const tenant = entra.tenantId;
  const geoEntries = Object.entries(config.inferenceGeo).flatMap(([backendId, map]) => Object.entries(map).map(([deployment, geo]) => `${backendId}|${deployment}=${geo}`));
  return {
    CONFIGURATION_ID: config.configurationId,
    CONFIG_SHA256: digests.config,
    TEMPLATE_SHA256: digests.template,
    TENANT_ID: tenant,
    OPENID_CONFIG_URL: `${entra.authorityHost}/${tenant}/v2.0/.well-known/openid-configuration`,
    ISSUER_V1: `${entra.v1IssuerHost}/${tenant}/`,
    ISSUER_V2: `${entra.authorityHost}/${tenant}/v2.0`,
    AUDIENCE_ELEMENTS: { xml: entra.audiences.map((a) => `<audience>${a}</audience>`).join("\n        ") },
    DELEGATED_SCOPE: entra.delegatedScope,
    DELEGATED_CLIENT_IDS: csharpStrings(entra.delegatedClientAppIds),
    ALLOW_APP_ONLY: String(entra.testIdentities.allowAppOnlyTokens),
    APP_ONLY_CLIENT_IDS: csharpStrings(entra.testIdentities.clientAppIds),
    APP_ONLY_ROLE: entra.testIdentities.appRole ?? "",
    PERSON_CALLS: String(admission.perPerson.calls),
    PERSON_PERIOD: String(admission.perPerson.renewalPeriodSeconds),
    MISS_CALLS: String(admission.resolverMisses.calls),
    MISS_PERIOD: String(admission.resolverMisses.renewalPeriodSeconds),
    MISS_CONCURRENCY: String(admission.resolverMisses.maxConcurrent),
    RESOLVER_URL: resolver.url,
    RESOLVER_AUDIENCE: resolver.tokenAudience,
    RESOLVER_TIMEOUT: String(resolver.timeoutSeconds),
    PROJECT_HEADER: resolver.projectHeaderName,
    CACHE_KEY_VERSION: String(cache.keyVersion),
    CACHING_TYPE: cache.cachingType,
    ALLOW_TTL: String(cache.allowTtlSeconds),
    REFUSAL_TTL: String(cache.refusalTtlSeconds),
    LKG_GRACE: String(cache.lastKnownGoodGraceSeconds),
    REFRESH_BACKOFF: String(cache.refreshBackoffSeconds),
    RETRY_AFTER: String(cache.unavailableRetryAfterSeconds),
    ESTIMATE_PROMPT_TOKENS: String(tokenLimits.estimatePromptTokens),
    H_PERSON_QUOTA: tokenLimits.headers.personRemainingQuota,
    H_PERSON_TOKENS: tokenLimits.headers.personRemainingTokens,
    H_GROUP_QUOTA: tokenLimits.headers.groupRemainingQuota,
    H_GROUP_TOKENS: tokenLimits.headers.groupRemainingTokens,
    H_TOKENS_CONSUMED: tokenLimits.headers.tokensConsumed,
    BACKEND_IDS: csharpStrings(config.backends.map((b) => b.id)),
    INFERENCE_GEO_ENTRIES: csharpStrings(geoEntries),
    BACKEND_BRANCHES: { xml: backendBranches },
    ANTHROPIC_VERSION_DEFAULT: {
      xml: forwarding.defaultAnthropicVersion === null
        ? ""
        : `<set-header name="anthropic-version" exists-action="skip">\n          <value>${forwarding.defaultAnthropicVersion}</value>\n        </set-header>`,
    },
  };
}

// Every value offered to a template must be used by it: a renamed or deleted
// placeholder must not silently drop a configured setting.
function fill(text: string, values: Record<string, TemplateValue>, name: string): string {
  const used = new Set(placeholdersIn(text));
  const unused = Object.keys(values).filter((k) => !used.has(k));
  if (unused.length > 0) throw new Error(`${name}: value(s) never used by the template: ${unused.join(", ")}`);
  return fillPlaceholders(text, values, name);
}

export function renderPolicy(input: GatewayConfig, options: { templates?: Templates } = {}): RenderResult {
  const validation = validateGatewayConfig(input);
  if (!validation.ok) throw new Error(`the configuration is invalid:\n - ${validation.problems.join("\n - ")}`);
  const config = validation.config;
  // A Windows checkout has CRLF and CI has LF: both must give the same policy and digests.
  const lf = (text: string) => text.replace(/\r\n/g, "\n");
  const given = options.templates ?? loadTemplates();
  const templates: Templates = {
    main: lf(given.main),
    fragments: Object.fromEntries(Object.entries(given.fragments).map(([name, text]) => [name, lf(text)])),
  };

  const literals = [["main", templates.main], ...Object.entries(templates.fragments)].flatMap(([name, text]) => findTemplateLiterals(text, name));
  if (literals.length > 0) throw new Error(`the template carries a literal environment value:\n - ${literals.join("\n - ")}`);

  const digests = {
    config: sha256(canonicalJson(config)),
    template: sha256([templates.main, ...Object.keys(templates.fragments).sort().map((k) => `${k}\n${templates.fragments[k]}`)].join("\n--\n")),
  };
  const branches = config.backends
    .map((backend) => {
      const fragment = FRAGMENT_FOR[backend.credential.type];
      return fill(templates.fragments[fragment], backendValues(backend), `${fragment} (${backend.id})`).trim();
    })
    .join("\n");
  const policyXml = fill(templates.main, mainValues(config, branches, digests), "main");
  checkRendered(policyXml, config);
  return {
    configurationId: config.configurationId,
    apiId: config.apim.apiId,
    policyXml,
    policySha256: sha256(policyXml),
    configSha256: digests.config,
    templateSha256: digests.template,
  };
}

function checkRendered(policyXml: string, config: GatewayConfig): void {
  if (policyXml.includes("%%")) throw new Error("the rendered policy still contains a placeholder");
  const root = parseApimXml(policyXml);
  if (root.name !== "policies") throw new Error("the rendered policy's root is not <policies>");
  const allowed = new Set(config.backends.map((b) => b.credential.clientSecretNamedValue));
  for (const match of policyXml.matchAll(/\{\{([^}]*)\}\}/g)) {
    if (!allowed.has(match[1])) throw new Error(`the rendered policy references named value "${match[1]}", which is not a configured backend secret`);
  }
}

export function renderFromFile(configPath: string, outDir: string): { result: RenderResult; policyPath: string; manifestPath: string } {
  const loaded = loadGatewayConfig(configPath);
  if (!loaded.ok) throw new Error(`configuration ${configPath} is invalid:\n - ${loaded.problems.join("\n - ")}`);
  const result = renderPolicy(loaded.config);
  mkdirSync(outDir, { recursive: true });
  const policyPath = path.join(outDir, `${result.apiId}.policy.xml`);
  const manifestPath = path.join(outDir, "render.json");
  writeFileSync(policyPath, result.policyXml, "utf8");
  const { policyXml: _omitted, ...manifest } = result;
  writeFileSync(manifestPath, `${JSON.stringify({ ...manifest, policyFile: path.basename(policyPath) }, null, 2)}\n`, "utf8");
  return { result, policyPath, manifestPath };
}

function main(argv: string[]): number {
  const args = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i].startsWith("--") || argv[i + 1] === undefined) {
      process.stderr.write("usage: node infra/gateway/render.ts --config <file> [--out <dir>]\n");
      return 2;
    }
    args.set(argv[i].slice(2), argv[i + 1]);
  }
  const configPath = args.get("config");
  if (!configPath) {
    process.stderr.write("usage: node infra/gateway/render.ts --config <file> [--out <dir>]\n");
    return 2;
  }
  try {
    const loaded = loadGatewayConfig(configPath);
    const outDir = args.get("out") ?? path.join(DEFAULT_OUT_DIR, loaded.ok ? loaded.config.configurationId : "invalid");
    const { result, policyPath, manifestPath } = renderFromFile(configPath, outDir);
    const { policyXml: _omitted, ...summary } = result;
    process.stdout.write(`${JSON.stringify({ ...summary, policyPath, manifestPath })}\n`);
    return 0;
  } catch (err: unknown) {
    process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  process.exitCode = main(process.argv.slice(2));
}
