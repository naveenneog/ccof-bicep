// Decides whether the live Azure integration tests run, and gives them their
// configuration.
//
// They run only when CCOF_LIVE_TESTS=1 is set. A .env file alone is not
// enough: the live tests authenticate with DefaultAzureCredential, which uses
// whatever login the machine holds (Azure CLI, Azure PowerShell or Azure
// Developer CLI), and the default suite - which the Ironclad gate runs - must
// make no credentialed Azure call. Once requested, a live test that cannot run
// fails rather than skipping, so a green live run means it actually ran.

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const LIVE_TESTS_VAR = "CCOF_LIVE_TESTS";

export const REPO_DOTENV_PATH = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", ".env");

const REQUIRED_KEYS = ["COSMOS_ENDPOINT", "COSMOS_DATABASE"] as const;

export interface LiveConfig {
  endpoint: string;
  databaseName: string;
}

export type LiveDecision =
  | { kind: "skip"; reason: string }
  | ({ kind: "run" } & LiveConfig)
  | { kind: "misconfigured"; message: string };

export function decideLiveRun(
  processEnv: Readonly<Record<string, string | undefined>>,
  dotEnv: Readonly<Record<string, string>> | null,
): LiveDecision {
  const flag = processEnv[LIVE_TESTS_VAR];
  if (flag === undefined || flag === "" || flag === "0") {
    return {
      kind: "skip",
      reason: `live Azure tests not requested; set ${LIVE_TESTS_VAR}=1 on a machine inside the VNet to run them`,
    };
  }
  if (flag !== "1") {
    return { kind: "misconfigured", message: `${LIVE_TESTS_VAR} must be 1 (run) or 0/unset (skip), not "${flag}"` };
  }
  if (dotEnv === null) {
    return {
      kind: "misconfigured",
      message: `${LIVE_TESTS_VAR}=1 but there is no .env at the repository root; it needs ${REQUIRED_KEYS.join(" and ")}`,
    };
  }
  const missing = REQUIRED_KEYS.filter((key) => !dotEnv[key]?.trim());
  if (missing.length > 0) {
    return { kind: "misconfigured", message: `${LIVE_TESTS_VAR}=1 but .env has no value for ${missing.join(" and ")}` };
  }
  const endpoint = dotEnv.COSMOS_ENDPOINT.trim();
  if (!isCosmosAccountEndpoint(endpoint)) {
    return {
      kind: "misconfigured",
      message: "COSMOS_ENDPOINT must be an https://<account>.documents.azure.com URL; the live tests send it an Entra token",
    };
  }
  return { kind: "run", endpoint, databaseName: dotEnv.COSMOS_DATABASE.trim() };
}

// A live test body calls this first. It throws the misconfiguration message so
// the test fails with it; a "skip" decision reaching a body is a wiring bug.
export function requireLiveConfig(decision: LiveDecision): LiveConfig {
  if (decision.kind === "misconfigured") throw new Error(decision.message);
  if (decision.kind === "skip") throw new Error(`a skipped live test body ran: ${decision.reason}`);
  return { endpoint: decision.endpoint, databaseName: decision.databaseName };
}

// Cosmos refuses requests from outside the VNet: this subscription's Azure
// Policy forces public network access off (docs/STATUS.md, Phase 3). Any other
// error, including a 403 for a token from the wrong tenant, is returned as is.
export function explainLiveFailure(err: unknown): unknown {
  if (!isCosmosFirewallRefusal(err)) return err;
  return new Error(
    `${LIVE_TESTS_VAR}=1 but this machine cannot reach the Cosmos account: its public network access is ` +
      "disabled by Azure Policy. Run live tests from inside the VNet (infra/poc/jumpbox-full-test.sh).",
    { cause: err },
  );
}

export function loadDotEnv(filePath: string): Record<string, string> | null {
  if (!existsSync(filePath)) return null;
  const vars: Record<string, string> = {};
  for (const line of readFileSync(filePath, "utf8").split(/\r?\n/)) {
    const match = line.match(/^([A-Z_]+)=(.*)$/);
    if (match) vars[match[1]] = match[2];
  }
  return vars;
}

function isCosmosAccountEndpoint(value: string): boolean {
  if (!URL.canParse(value)) return false;
  const url = new URL(value);
  return url.protocol === "https:" && url.hostname.endsWith(".documents.azure.com");
}

function isCosmosFirewallRefusal(err: unknown): boolean {
  return (
    typeof err === "object" &&
    err !== null &&
    "code" in err &&
    err.code === 403 &&
    JSON.stringify(err).includes("blocked by your Cosmos DB account firewall")
  );
}

// Which test files can reach Azure. The default suite stays credential-free only
// if every such file goes through decideLiveRun. A test reaches Azure when it
// imports an @azure/ package at runtime, or imports a repository adapter module
// that does (src/resolver/cosmos-reads.ts builds a DefaultAzureCredential).
// Type-only imports are erased before the code runs, so they do not count.

const STATIC_IMPORT = /^\s*(?:import|export)\s+(?!type\b)[^;]*?\bfrom\s*(["'`])([^"'`\r\n]+)\1/gm;
const SIDE_EFFECT_IMPORT = /^\s*import\s*(["'`])([^"'`\r\n]+)\1/gm;
const DYNAMIC_IMPORT = /\bimport\s*\(\s*(["'`])([^"'`\r\n]+)\1\s*\)/g;

export function runtimeImports(source: string): string[] {
  return [STATIC_IMPORT, SIDE_EFFECT_IMPORT, DYNAMIC_IMPORT].flatMap((pattern) =>
    [...source.matchAll(pattern)].map((match) => match[2]),
  );
}

// Keys are repository-relative POSIX paths; results drop the file extension.
export function azureAdapterModules(files: ReadonlyMap<string, string>): Set<string> {
  const adapters = new Set<string>();
  for (const [relPath, source] of files) {
    if (runtimeImports(source).some(isAzurePackage)) adapters.add(withoutExtension(relPath));
  }
  return adapters;
}

export function touchesAzure(relPath: string, source: string, adapters: ReadonlySet<string>): boolean {
  return runtimeImports(source).some(
    (specifier) => isAzurePackage(specifier) || adapters.has(resolveRelative(relPath, specifier)),
  );
}

export function isUngatedLiveTest(relPath: string, source: string, adapters: ReadonlySet<string>): boolean {
  return touchesAzure(relPath, source, adapters) && !/\bdecideLiveRun\(/.test(source);
}

function isAzurePackage(specifier: string): boolean {
  return specifier.startsWith("@azure/");
}

function resolveRelative(fromRelPath: string, specifier: string): string {
  if (!specifier.startsWith(".")) return specifier;
  return withoutExtension(path.posix.normalize(path.posix.join(path.posix.dirname(fromRelPath), specifier)));
}

function withoutExtension(relPath: string): string {
  return relPath.replace(/\.[cm]?[jt]s$/, "");
}