import { strict as assert } from "node:assert";
import { rmSync, symlinkSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { workbookAnswers, workbookRateCard } from "./helpers/workbook-fixtures.ts";

const render = () => import("../analytics/workbooks/render.ts");
const build = () => import("../analytics/workbooks/build.ts");
const ledger = `let CcofUsageLedger = (fromTime:datetime, toTime:datetime, resourceId:string) {
datatable(timestamp:datetime, personId:string, projectId:string, classification:string)[]
};`;
const month = { period: "month", project: "*", from: null, to: null } as const;

test("workbook rendering substitutes every portal parameter like the portal does", async () => {
  const { renderQuery } = await render();
  const query = 'let P = base64_decode_tostring("{Period:base64}"); let J = base64_decode_tostring("{Project:base64}"); print {TimeRange:start}, {TimeRange:end}';
  assert.equal(renderQuery(query, month),
    'let P = base64_decode_tostring("bW9udGg="); let J = base64_decode_tostring("Kg=="); print datetime(null), datetime(null)');
  const custom = renderQuery(query, { period: "custom", project: "CCOFPILOT01\"", from: "2026-10-01T00:00:00Z", to: "2026-10-12T00:00:00Z" });
  assert.match(custom, /datetime\(2026-10-01T00:00:00Z\), datetime\(2026-10-12T00:00:00Z\)/);
  assert.match(custom, new RegExp(Buffer.from('CCOFPILOT01"').toString("base64")));
  assert.doesNotMatch(custom, /CCOFPILOT01"/);
});

const invalid: Array<[string, unknown, RegExp]> = [
  ["unknown period", { ...month, period: "week" }, /period/],
  ["empty project", { ...month, project: "" }, /project/],
  ["control character project", { ...month, project: "a\nb" }, /project/],
  ["custom without range", { ...month, period: "custom" }, /from: utc_instant_required/],
  ["custom with local time", { period: "custom", project: "*", from: "2026-10-01", to: "2026-10-02T00:00:00Z" }, /from/],
  ["range outside custom", { ...month, from: "2026-10-01T00:00:00Z" }, /from: custom_only/],
];
for (const [name, parameters, reason] of invalid) {
  test(`workbook rendering refuses ${name}`, async () => {
    const { renderQuery } = await render();
    assert.throws(() => renderQuery("print 1", parameters as never), reason);
  });
}

test("workbook rendering refuses a query with an unresolved portal parameter", async () => {
  const { renderQuery } = await render();
  assert.throws(() => renderQuery("print {TimeRange}", month), /unresolved_parameter/);
  assert.throws(() => renderQuery("print '{Project}'", month), /unresolved_parameter/);
});

test("every built workbook query renders with no portal parameter left", async () => {
  const { workbookQueries } = await render();
  const { buildWorkbook } = await build();
  const queries = workbookQueries(buildWorkbook(workbookAnswers(), workbookRateCard(), ledger).workbook, month);
  assert.deepEqual(Object.keys(queries), ["health", "usage", "model-mix", "top-users", "budgets", "reconciler-runs", "unpriced", "chargeback"]);
  for (const query of Object.values(queries)) assert.doesNotMatch(query, /\{(?:Period|Project|TimeRange)[:}]/);
});

test("deployed content matches only the reviewed workbook, whatever its key order or spacing", async () => {
  const { sameWorkbook } = await render();
  const { buildWorkbook } = await build();
  const workbook = buildWorkbook(workbookAnswers(), workbookRateCard(), ledger).workbook;
  assert.equal(sameWorkbook(workbook, JSON.stringify(workbook)), true);
  const reordered = JSON.stringify({ items: workbook.items, version: workbook.version, $schema: workbook.$schema,
    fallbackResourceIds: workbook.fallbackResourceIds }, null, 1);
  assert.equal(sameWorkbook(workbook, reordered), true);
  const changed = structuredClone(workbook);
  (changed.items[0].content as { json: string }).json += " ";
  assert.equal(sameWorkbook(workbook, JSON.stringify(changed)), false);
  assert.equal(sameWorkbook(workbook, null), false);
  assert.equal(sameWorkbook(workbook, "{not json"), false);
});

test("verification summaries carry counts and states, never person, scope or request ids", async () => {
  const { summarize } = await render();
  const person = "44444444-4444-4444-8444-444444444444";
  const response = { tables: [{ name: "PrimaryResult",
    columns: ["person", "scopeId", "gatewayRequestId", "requests", "unpricedRequests", "knownListCcu", "listCcu", "completeness"].map(name => ({ name })),
    rows: [[person, `${person}:P`, "req-1", 3, 1, "0.7", null, "unpriced_usage"], [person, `${person}:P`, "req-2", 2, 0, "1.5", "1.5", "complete"]] }] };
  const summary = summarize(response);
  assert.deepEqual(summary, { rows: 2, requests: 5, unpricedRequests: 1, knownListCcuNonNullRows: 2,
    knownListCcuSum: "2.2", listCcuNonNullRows: 1, listCcuSum: "1.5", completeness: ["complete", "unpriced_usage"] });
  assert.doesNotMatch(JSON.stringify(summary), new RegExp(`${person}|req-1|:P`));
  const noComplete = { tables: [{ ...response.tables[0], rows: response.tables[0].rows.map(row => row.map((v, i) => i === 6 ? null : v)) }] };
  assert.equal(summarize(noComplete).listCcuSum, null, "no complete total is missing, not zero");
  assert.equal(summarize(noComplete).listCcuNonNullRows, 0);
  const exact = { tables: [{ name: "PrimaryResult", columns: [{ name: "knownListCcu" }],
    rows: [["123456.78901234567890123"], ["0.0000000000000000000000000001"]] }] };
  assert.equal(summarize(exact).knownListCcuSum, "123456.7890123456789012300000000001");
  assert.throws(() => summarize({ error: { code: "PartialError" }, tables: response.tables }), /response_error/);
  assert.throws(() => summarize({ tables: [] }), /response_error/);
});

test("command-line entry guard runs through a junction or symlink checkout and nowhere else", async () => {
  const { isMain } = await import("../analytics/workbooks/main.ts");
  const folder = fileURLToPath(new URL("../analytics/workbooks/", import.meta.url));
  const buildUrl = new URL("../analytics/workbooks/build.ts", import.meta.url).href;
  const link = fileURLToPath(new URL(`../.env.test-link-${process.pid}`, import.meta.url));
  symlinkSync(folder, link, "junction");
  try {
    assert.equal(isMain(buildUrl, path.join(link, "build.ts")), true);
  } finally {
    rmSync(link, { force: true });
  }
  assert.equal(isMain(buildUrl, path.join(folder, "build.ts")), true);
  assert.equal(isMain(buildUrl, path.join(folder, "render.ts")), false);
  assert.equal(isMain(buildUrl, path.join(folder, "absent.ts")), false);
  assert.equal(isMain(buildUrl, undefined), false);
});
