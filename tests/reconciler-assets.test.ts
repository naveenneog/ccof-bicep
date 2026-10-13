// The files packaged with the reconciler (docs/PILOT.md C-7, "read once"):
// WP-COST's rate card and contract schedule and WP-TEL's ledger function. A
// missing or invalid file refuses every run, with the file named, before any
// Azure call.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { ASSET_FILES, loadRunAssets } from "../src/reconciler/assets.ts";

const repo = (path: string) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("the packaged files load: rate card, contract schedule and ledger function", async () => {
  const loaded = await loadRunAssets(repo);
  assert.equal(loaded.ok, true);
  if (!loaded.ok) return;
  assert.equal(loaded.assets.rateCard.version, JSON.parse(await repo(ASSET_FILES.rateCard)).version);
  assert.equal(loaded.assets.schedule.version, JSON.parse(await repo(ASSET_FILES.contractSchedule)).version);
  assert.match(loaded.assets.ledgerKql, /let CcofUsageLedger/);
});

test("the package paths are fixed: config/ and analytics/ at the package root", () => {
  assert.deepEqual(ASSET_FILES, {
    rateCard: "config/rate-card.json",
    contractSchedule: "config/contract-schedule.json",
    ledgerKql: "analytics/ledger.kql",
  });
});

test("a missing file is named, with code unreadable", async () => {
  const loaded = await loadRunAssets(async (path) => {
    if (path === ASSET_FILES.contractSchedule) throw Object.assign(new Error("ENOENT"), { code: "ENOENT" });
    return repo(path);
  });
  assert.deepEqual(loaded, { ok: false, problem: { setting: "package:config/contract-schedule.json", problem: "unreadable" } });
});

test("an invalid rate card, schedule or ledger function is named, with code invalid", async () => {
  const cases: Array<[string, string]> = [
    [ASSET_FILES.rateCard, '{"schemaVersion":1}'],
    [ASSET_FILES.contractSchedule, "not json"],
    [ASSET_FILES.ledgerKql, "ApiManagementGatewayLlmLog | take 10"],
  ];
  for (const [broken, content] of cases) {
    const loaded = await loadRunAssets(async (path) => (path === broken ? content : repo(path)));
    assert.deepEqual(loaded, { ok: false, problem: { setting: `package:${broken}`, problem: "invalid" } }, broken);
  }
});
