// Unit tests for tests/helpers/live-azure.ts, the gate that decides whether the
// live Azure integration tests run.
//
// The default suite (scripts/run-tests.ps1, and so the Ironclad gate) must make
// no credentialed Azure call. A .env file alone used to be enough to run the
// live Cosmos tests, and those tests authenticate with DefaultAzureCredential,
// which uses whatever login the machine holds: measured 2026-10-11, with the
// Azure CLI isolated and logged out it fell through to an Azure Developer CLI
// login in an unrelated tenant. Only an explicit CCOF_LIVE_TESTS=1 runs them.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  azureAdapterModules,
  decideLiveRun,
  explainLiveFailure,
  isUngatedLiveTest,
  loadDotEnv,
  requireLiveConfig,
  runtimeImports,
  touchesAzure,
  type LiveDecision,
} from "./helpers/live-azure.ts";

const completeDotEnv = {
  COSMOS_ENDPOINT: "https://sample-pilot-cosmos.documents.azure.com:443/",
  COSMOS_DATABASE: "ccof",
};

function expectSkip(decision: LiveDecision): string {
  if (decision.kind !== "skip") assert.fail(`expected skip, got ${decision.kind}`);
  return decision.reason;
}

function expectMisconfigured(decision: LiveDecision): string {
  if (decision.kind !== "misconfigured") assert.fail(`expected misconfigured, got ${decision.kind}`);
  return decision.message;
}

test("a .env alone does not run live tests: without CCOF_LIVE_TESTS they skip and name the opt-in", () => {
  const reason = expectSkip(decideLiveRun({}, completeDotEnv));
  assert.match(reason, /CCOF_LIVE_TESTS=1/);
});

test("without CCOF_LIVE_TESTS and without a .env, live tests skip", () => {
  expectSkip(decideLiveRun({}, null));
});

test("CCOF_LIVE_TESTS=0 and an empty CCOF_LIVE_TESTS both mean skip", () => {
  expectSkip(decideLiveRun({ CCOF_LIVE_TESTS: "0" }, completeDotEnv));
  expectSkip(decideLiveRun({ CCOF_LIVE_TESTS: "" }, completeDotEnv));
});

test("CCOF_LIVE_TESTS=1 with a complete .env runs against the configured account and database", () => {
  assert.deepEqual(decideLiveRun({ CCOF_LIVE_TESTS: "1" }, completeDotEnv), {
    kind: "run",
    endpoint: "https://sample-pilot-cosmos.documents.azure.com:443/",
    databaseName: "ccof",
  });
});

test("an unrecognised CCOF_LIVE_TESTS value fails instead of silently skipping", () => {
  const message = expectMisconfigured(decideLiveRun({ CCOF_LIVE_TESTS: "true" }, completeDotEnv));
  assert.match(message, /CCOF_LIVE_TESTS/);
  assert.match(message, /"true"/);
});

test("CCOF_LIVE_TESTS=1 without a .env fails and names the file and both keys", () => {
  const message = expectMisconfigured(decideLiveRun({ CCOF_LIVE_TESTS: "1" }, null));
  assert.match(message, /\.env/);
  assert.match(message, /COSMOS_ENDPOINT/);
  assert.match(message, /COSMOS_DATABASE/);
});

test("CCOF_LIVE_TESTS=1 with a .env missing a key fails and names only the missing key", () => {
  const noDatabase = expectMisconfigured(
    decideLiveRun({ CCOF_LIVE_TESTS: "1" }, { COSMOS_ENDPOINT: completeDotEnv.COSMOS_ENDPOINT }),
  );
  assert.match(noDatabase, /COSMOS_DATABASE/);
  assert.doesNotMatch(noDatabase, /COSMOS_ENDPOINT/);

  const blankEndpoint = expectMisconfigured(
    decideLiveRun({ CCOF_LIVE_TESTS: "1" }, { ...completeDotEnv, COSMOS_ENDPOINT: "   " }),
  );
  assert.match(blankEndpoint, /COSMOS_ENDPOINT/);

  const blankDatabase = expectMisconfigured(
    decideLiveRun({ CCOF_LIVE_TESTS: "1" }, { ...completeDotEnv, COSMOS_DATABASE: "  " }),
  );
  assert.match(blankDatabase, /COSMOS_DATABASE/);
});

test("CCOF_LIVE_TESTS=1 refuses an endpoint that is not an https Cosmos account URL", () => {
  for (const endpoint of [
    "http://sample-pilot-cosmos.documents.azure.com:443/",
    "https://example.com/",
    "https://sample-pilot-cosmos.documents.azure.com.evil.example/",
    "https://documents.azure.com/",
    "not a url",
  ]) {
    const message = expectMisconfigured(
      decideLiveRun({ CCOF_LIVE_TESTS: "1" }, { ...completeDotEnv, COSMOS_ENDPOINT: endpoint }),
    );
    assert.match(message, /documents\.azure\.com/, `endpoint ${endpoint}`);
  }
});

test("requireLiveConfig returns the run configuration and throws for anything else", () => {
  assert.deepEqual(
    requireLiveConfig({ kind: "run", endpoint: "https://example-a.documents.azure.com/", databaseName: "db" }),
    { endpoint: "https://example-a.documents.azure.com/", databaseName: "db" },
  );
  assert.throws(() => requireLiveConfig({ kind: "misconfigured", message: "no .env here" }), /no \.env here/);
  assert.throws(() => requireLiveConfig({ kind: "skip", reason: "not requested" }), /skipped/);
});

test("explainLiveFailure turns the Cosmos firewall refusal into an actionable failure", () => {
  const firewall = {
    code: 403,
    body: {
      code: "Forbidden",
      message:
        "Request originated from IP 203.0.113.7 through public internet. This is blocked by your Cosmos DB account firewall settings.",
    },
  };
  const explained = explainLiveFailure(firewall);
  assert.ok(explained instanceof Error, "expected an Error");
  assert.match(explained.message, /CCOF_LIVE_TESTS=1/);
  assert.match(explained.message, /inside the VNet/);
  assert.equal(explained.cause, firewall);
});

test("explainLiveFailure passes every other error through unchanged, including other 403s", () => {
  const wrongTenant = {
    code: 403,
    body: { message: "Request blocked by Auth sample-pilot-cosmos : Provided AAD token was issued by the authority [x]" },
  };
  assert.equal(explainLiveFailure(wrongTenant), wrongTenant);
  const plain = new Error("boom");
  assert.equal(explainLiveFailure(plain), plain);
});

test("loadDotEnv returns null for a missing file and parses only KEY=VALUE lines", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "ccof-dotenv-"));
  try {
    assert.equal(loadDotEnv(path.join(dir, "absent.env")), null);
    const file = path.join(dir, ".env");
    writeFileSync(file, "# comment\r\nCOSMOS_ENDPOINT=https://example-a.documents.azure.com/\r\n\r\nlower=x\r\nCOSMOS_DATABASE=ccof\r\n");
    assert.deepEqual(loadDotEnv(file), {
      COSMOS_ENDPOINT: "https://example-a.documents.azure.com/",
      COSMOS_DATABASE: "ccof",
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("runtimeImports lists static, side-effect and dynamic imports, but not type-only ones", () => {
  const source = [
    'import { a } from "pkg-a";',
    "import {",
    "  b,",
    "} from './multi-line.ts';",
    'import type { T } from "types-only";',
    'export { c } from "re-exported";',
    'export type { U } from "types-only-too";',
    'import "side-effect";',
    "const d = await import(`backtick-dynamic`);",
    "const e = await import('quoted-dynamic');",
  ].join("\n");
  assert.deepEqual(runtimeImports(source).sort(), [
    "./multi-line.ts",
    "backtick-dynamic",
    "pkg-a",
    "quoted-dynamic",
    "re-exported",
    "side-effect",
  ]);
});

test("azureAdapterModules finds repository modules that load an Azure SDK at runtime", () => {
  const files = new Map([
    ["src/resolver/cosmos-reads.ts", 'import { CosmosClient } from "@azure/cosmos";'],
    ["src/resolver/types-only.ts", 'import type { HttpRequest } from "@azure/functions";'],
    ["src/resolver/pure.ts", 'import { resolveRequest } from "./decide.ts";'],
  ]);
  assert.deepEqual([...azureAdapterModules(files)], ["src/resolver/cosmos-reads"]);
});

test("isUngatedLiveTest flags Azure access without decideLiveRun, directly or through an adapter", () => {
  const adapters = new Set(["src/resolver/cosmos-reads"]);
  const flagged = (source: string) => isUngatedLiveTest("tests/x.test.ts", source, adapters);
  assert.equal(flagged('import { DefaultAzureCredential } from "@azure/identity";'), true);
  assert.equal(flagged("const { CosmosClient } = await import(`@azure/cosmos`);"), true);
  assert.equal(flagged('import { createCosmosReads } from "../src/resolver/cosmos-reads.ts";'), true);
  assert.equal(flagged('const m = await import("../src/resolver/cosmos-reads.js");'), true);
  assert.equal(
    flagged('import { DefaultAzureCredential } from "@azure/identity";\nconst live = decideLiveRun(process.env, null);'),
    false,
  );
  assert.equal(flagged('import type { HttpRequest } from "@azure/functions";'), false);
  assert.equal(flagged('import { resolveRequest } from "../src/resolver/decide.ts";'), false);
});

test("every repository test that reaches Azure is gated by decideLiveRun, and the scan finds the live tests", () => {
  const testsDir = path.dirname(fileURLToPath(import.meta.url));
  const repoRoot = path.dirname(testsDir);
  const srcFiles = new Map(
    readdirSync(path.join(repoRoot, "src"), { recursive: true, encoding: "utf8" })
      .filter((rel) => rel.endsWith(".ts"))
      .map((rel) => [`src/${rel.split(path.sep).join("/")}`, readFileSync(path.join(repoRoot, "src", rel), "utf8")]),
  );
  const adapters = azureAdapterModules(srcFiles);
  assert.ok(adapters.has("src/resolver/cosmos-reads"), "the scan must find the known Cosmos adapter");

  // This file's own fixtures quote Azure imports inside strings, so it is not scanned.
  const ownName = path.basename(fileURLToPath(import.meta.url));
  const testFiles = readdirSync(testsDir).filter((name) => name.endsWith(".test.ts") && name !== ownName);
  const sourceOf = (name: string) => readFileSync(path.join(testsDir, name), "utf8");
  const reachingAzure = testFiles.filter((name) => touchesAzure(`tests/${name}`, sourceOf(name), adapters));
  for (const liveTest of ["resolver-cosmos-integration.test.ts", "resolver-cross-project-integration.test.ts"]) {
    assert.ok(reachingAzure.includes(liveTest), `the scan must find ${liveTest}`);
  }
  assert.deepEqual(
    testFiles.filter((name) => isUngatedLiveTest(`tests/${name}`, sourceOf(name), adapters)),
    [],
  );
});
