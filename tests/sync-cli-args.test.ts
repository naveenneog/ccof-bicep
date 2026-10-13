// Command-line arguments of the manual sync run (src/sync/cli-args.ts). The
// CLI is the fallback while the Graph application permission is missing: one
// run, from a machine inside the VNet, with an explicit credential and an
// explicit settings file (the same names as the Function App settings).

import { test } from "node:test";
import assert from "node:assert/strict";
import { exitCodeFor, parseCliArgs, parseGroupsFile, parseSettingsFile, USAGE } from "../src/sync/cli-args.ts";

test("a run needs --once, --credential and --settings", () => {
  assert.deepEqual(parseCliArgs(["--once", "--credential", "azure-cli", "--settings", "sync.json"]), {
    ok: true,
    command: "run",
    credential: "azure-cli",
    clientId: null,
    settingsPath: "sync.json",
  });
  assert.deepEqual(parseCliArgs(["--once", "--credential", "managed-identity", "--client-id", "00000000-0000-4000-8000-000000000100", "--settings", "s.json"]), {
    ok: true,
    command: "run",
    credential: "managed-identity",
    clientId: "00000000-0000-4000-8000-000000000100",
    settingsPath: "s.json",
  });
});

test("--help prints the usage", () => {
  assert.deepEqual(parseCliArgs(["--help"]), { ok: true, command: "help" });
  assert.match(USAGE, /--once --credential azure-cli\|managed-identity/);
});

test("anything missing, unknown, repeated or inconsistent is refused with a message that names it", () => {
  const cases: [string[], RegExp][] = [
    [[], /--once/],
    [["--credential", "azure-cli", "--settings", "s.json"], /--once/],
    [["--once", "--settings", "s.json"], /--credential/],
    [["--once", "--credential", "password", "--settings", "s.json"], /--credential/],
    [["--once", "--credential", "azure-cli"], /--settings/],
    [["--once", "--credential", "azure-cli", "--settings"], /--settings/],
    [["--once", "--credential", "azure-cli", "--settings", "s.json", "--force"], /--force/],
    [["--once", "--once", "--credential", "azure-cli", "--settings", "s.json"], /--once/],
    [["--once", "--credential", "azure-cli", "--client-id", "00000000-0000-4000-8000-000000000100", "--settings", "s.json"], /--client-id/],
    [["--once", "--credential", "managed-identity", "--client-id", "nope", "--settings", "s.json"], /--client-id/],
  ];
  for (const [argv, message] of cases) {
    const result = parseCliArgs(argv);
    if (result.ok) assert.fail(`accepted ${JSON.stringify(argv)}`);
    assert.match(result.error, message, JSON.stringify(argv));
  }
});

test("the settings file is a JSON object of string values, as app settings are", () => {
  assert.deepEqual(parseSettingsFile('{"SYNC_WRITE_MODE":"dry-run","COSMOS_DATABASE":"ccof"}'), {
    ok: true,
    settings: { SYNC_WRITE_MODE: "dry-run", COSMOS_DATABASE: "ccof" },
  });
  for (const text of ["not json", "[]", "null", '{"SYNC_LEASE_SECONDS":300}']) {
    const result = parseSettingsFile(text);
    assert.equal(result.ok, false, text);
  }
  const numeric = parseSettingsFile('{"SYNC_LEASE_SECONDS":300}');
  if (!numeric.ok) assert.match(numeric.error, /SYNC_LEASE_SECONDS/);
});

test("exit codes distinguish success, partial, skipped, failed and refused input", () => {
  assert.equal(exitCodeFor("succeeded"), 0);
  assert.equal(exitCodeFor("failed"), 1);
  assert.equal(exitCodeFor("partial"), 3);
  assert.equal(exitCodeFor("skipped"), 4);
});

test("snapshot: --groups, --settings, --out and --credential azure-cli are required", () => {
  assert.deepEqual(parseCliArgs(["snapshot", "--credential", "azure-cli", "--groups", "g.json", "--settings", "s.json", "--out", "snap.json"]), {
    ok: true,
    command: "snapshot",
    credential: "azure-cli",
    groupsPath: "g.json",
    settingsPath: "s.json",
    outPath: "snap.json",
  });
  for (const argv of [
    ["snapshot", "--groups", "g.json", "--settings", "s.json", "--out", "x.json"],
    ["snapshot", "--credential", "managed-identity", "--groups", "g.json", "--settings", "s.json", "--out", "x.json"],
    ["snapshot", "--credential", "azure-cli", "--settings", "s.json", "--out", "x.json"],
    ["snapshot", "--credential", "azure-cli", "--groups", "g.json", "--settings", "s.json"],
    ["snapshot", "--credential", "azure-cli", "--groups", "g.json", "--settings", "s.json", "--out", "x.json", "--once"],
  ]) {
    assert.equal(parseCliArgs(argv).ok, false, JSON.stringify(argv));
  }
});

test("apply-snapshot: --snapshot, --settings and a credential are required; --client-id only with managed-identity", () => {
  assert.deepEqual(parseCliArgs(["apply-snapshot", "--snapshot", "snap.json", "--credential", "managed-identity", "--settings", "s.json"]), {
    ok: true,
    command: "apply-snapshot",
    credential: "managed-identity",
    clientId: null,
    snapshotPath: "snap.json",
    settingsPath: "s.json",
  });
  for (const argv of [
    ["apply-snapshot", "--credential", "managed-identity", "--settings", "s.json"],
    ["apply-snapshot", "--snapshot", "snap.json", "--settings", "s.json"],
    ["apply-snapshot", "--snapshot", "snap.json", "--credential", "azure-cli", "--client-id", "00000000-0000-4000-8000-000000000100", "--settings", "s.json"],
    ["apply-snapshot", "--snapshot", "snap.json", "--credential", "managed-identity", "--settings", "s.json", "--groups", "g.json"],
  ]) {
    assert.equal(parseCliArgs(argv).ok, false, JSON.stringify(argv));
  }
});

test("the groups file is a JSON object with a non-empty groupIds array of strings", () => {
  assert.deepEqual(parseGroupsFile('{"groupIds":["11111111-1111-4111-8111-111111111111"]}'), { ok: true, groupIds: ["11111111-1111-4111-8111-111111111111"] });
  for (const text of ["[]", '{"groupIds":[]}', '{"groupIds":[1]}', '{"groups":["x"]}', "nope"]) {
    assert.equal(parseGroupsFile(text).ok, false, text);
  }
});
