import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { buildWorkbook } from "../../analytics/workbooks/build.ts";
import { buildChargebackWorkbook } from "../../analytics/workbooks/chargeback.ts";
import { chargebackQueries, reconcilerQueryBase } from "../../analytics/workbooks/chargeback-queries.ts";
import { workbookAnswers } from "../../tests/helpers/workbook-fixtures.ts";
import { buildChargebackQuery, prepareRateCard, readChargebackFilters } from "../src/chargeback.ts";

const card = JSON.parse(await readFile(new URL("../../config/rate-card.json", import.meta.url), "utf8"));
const ledger = await readFile(new URL("../../analytics/ledger.kql", import.meta.url), "utf8");
const pricing = await readFile(new URL("../../analytics/workbooks/pricing.kql", import.meta.url), "utf8");
const budgets = (await readFile(new URL("../../analytics/workbooks/budgets.kql", import.meta.url), "utf8")).replace(/\r\n/g, "\n");
const groups = [{ projectId: "P1", classification: "STD", groupId: "6f3a2c1e-4b5d-4e8f-9a0b-1c2d3e4f5a6b", displayName: "P1 std" }];
const answers = workbookAnswers();
const NOW = new Date("2026-10-19T12:00:00Z");

test("the console builds the workbook's own queries: no options gives the workbook text byte for byte", () => {
  const workbook = buildChargebackWorkbook(answers, card, ledger, groups);
  const legacy = buildWorkbook(answers, { ...card, entries: card.entries.filter((e: { model: string }) => !/^claude-(fable|mythos)/.test(e.model)) }, ledger);
  const shared = chargebackQueries(legacy, answers.maxRows, groups);
  for (const key of Object.keys(workbook.queries) as (keyof typeof workbook.queries)[]) assert.equal(shared[key], workbook.queries[key], key);
  assert.equal(shared.projects, undefined, "admin-only views are absent from the workbook");
});

test("admin options only add filter lines, bins and paging to the workbook text", () => {
  const legacy = buildWorkbook(answers, { ...card, entries: card.entries.filter((e: { model: string }) => !/^claude-(fable|mythos)/.test(e.model)) }, ledger);
  const base = chargebackQueries(legacy, 500, groups);
  const extended = chargebackQueries(legacy, 500, groups, { extendedFilters: true, trendBin: "1h", offset: 100, extraViews: true });
  const strip = (q: string) => q
    .replace('let BackendFilter = base64_decode_tostring("{Backend:base64}");\nlet FamilyFilter = base64_decode_tostring("{Family:base64}");\n', "")
    .replace('\n    and (BackendFilter == "*" or backendId =~ BackendFilter)\n    and (FamilyFilter == "*" or modelFamily == FamilyFilter)', "")
    .replace("| extend reportRowNumber = row_number()\n| where reportRowNumber > 100\n", "")
    .replace("pageOffset = 100, truncated = ReportRows > 600", "truncated = ReportRows > 500");
  for (const key of ["totals", "groups", "developers", "models", "families", "unpriced", "diagnostics", "health"] as const) {
    assert.equal(strip(extended[key]), base[key], key);
  }
  assert.match(extended.trends, /bucket = bin\(timestamp, 1h\), modelFamily/);
  assert.ok(extended.projects?.includes("by projectLabel"));
  assert.throws(() => chargebackQueries(legacy, 500, groups, { trendBin: "1m" as "1h" }), /trendBin/);
});

test("server binding resolves every workbook parameter and encodes values", () => {
  const prepared = prepareRateCard(card);
  const settings = { workspaceId: "11111111-2222-4333-8444-555555555555", gatewayResourceId: answers.gatewayResourceId, maxQueryDays: 62, retentionDays: 90 };
  for (const view of ["totals", "groups", "developers", "models", "families", "trend", "coverage", "unpriced", "diagnostics", "projects"] as const) {
    const f = readChargebackFilters(new URLSearchParams("period=custom&from=2026-10-01T00:00:00Z&to=2026-10-15T00:00:00Z&backend=foundry-eus2&family=opus"), NOW, 62);
    const q = buildChargebackQuery(view, f, settings, { ledger, pricing, budgets }, prepared, []);
    assert.doesNotMatch(q, /\{[A-Za-z]+:(base64|start|end)\}/, view);
    assert.match(q, /datetime\(2026-10-01T00:00:00.000Z\)/);
    assert.ok(q.includes(Buffer.from("foundry-eus2").toString("base64")), view);
  }
});

test("reconciler source contract: both FunctionAppLogs reads become the scoped union", () => {
  const q = reconcilerQueryBase("let X = 1;\n", budgets, ["/subscriptions/a/resourceGroups/b/providers/Microsoft.Web/sites/c"]);
  assert.equal(q.match(/ReconcilerLogs\n\| where TimeGenerated/g)?.length, 2);
  assert.throws(() => reconcilerQueryBase("", budgets.replace(/FunctionAppLogs\n\| where _ResourceId =~ ReconcilerResourceId/, "X"), []), /budgets_source_contract_changed/);
});

test("packaged KQL copies are identical to the workbook sources", async () => {
  for (const [packaged, source] of [["../kql/ledger.kql", "../../analytics/ledger.kql"], ["../kql/pricing.kql", "../../analytics/workbooks/pricing.kql"], ["../kql/budgets.kql", "../../analytics/workbooks/budgets.kql"]]) {
    let copy: string;
    try { copy = await readFile(new URL(packaged, import.meta.url), "utf8"); } catch { continue; } // built by npm run build
    assert.equal(copy, await readFile(new URL(source, import.meta.url), "utf8"), packaged);
  }
});
