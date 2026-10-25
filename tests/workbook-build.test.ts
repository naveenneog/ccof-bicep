import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { workbookAnswers, workbookRateCard } from "./helpers/workbook-fixtures.ts";

const configModule = () => import("../analytics/workbooks/config.ts");
const buildModule = () => import("../analytics/workbooks/build.ts");
const fixtureLedger = `let CcofUsageLedger = (fromTime:datetime, toTime:datetime, resourceId:string) {
datatable(timestamp:datetime, personId:string, projectId:string, classification:string)[]
};`;

test("workbook configuration preserves explicit answers without deriving identities or thresholds", async () => {
  const { validateAnswers } = await configModule();
  assert.deepEqual(validateAnswers(workbookAnswers()), workbookAnswers());
});

for (const key of Object.keys(workbookAnswers())) {
  test(`workbook configuration refuses missing ${key} before deployment`, async () => {
    const { validateAnswers } = await configModule();
    const answers: Record<string, unknown> = workbookAnswers();
    delete answers[key];
    assert.throws(() => validateAnswers(answers), new RegExp(key));
  });
}

const invalidAnswers: Array<[string, unknown]> = [
  ["schemaVersion", 2], ["subscriptionId", "not-a-guid"], ["tenantId", ""],
  ["resourceGroupName", "group;Write-Error injected"], ["location", "east us"],
  ["deploymentName", "../other"], ["workbookResourceName", "not-a-guid"],
  ["workbookDisplayName", "\nforged event"], ["workspaceResourceId", "https://example.invalid"],
  ["gatewayResourceId", workbookAnswers().reconcilerResourceId],
  ["reconcilerResourceId", workbookAnswers().gatewayResourceId],
  ["rateCardPath", "\\\\untrusted\\share\\rate-card.json"],
  ["ledgerPath", "https://example.invalid/ledger.kql"],
  ["outputDirectory", "..\\outside"], ["defaultProjectId", ""],
  ["maxRows", 0], ["topUsers", 501], ["maxQueryDays", -1], ["budgetLookbackDays", 0], ["retentionDays", 0],
];
for (const [key, value] of invalidAnswers) {
  test(`workbook configuration refuses invalid ${key}`, async () => {
    const { validateAnswers } = await configModule();
    assert.throws(() => validateAnswers({ ...workbookAnswers(), [key]: value }), new RegExp(key));
  });
}

test("workbook configuration refuses UNC, device and URL paths in any separator mix", async () => {
  const { validateAnswers } = await configModule();
  for (const value of ["\\\\host\\share\\x.json", "//host/share/x.json", "\\/host/share/x.json", "/\\host\\share\\x.json",
    "\\\\?\\C:\\x.json", "\\\\.\\pipe\\x", "file://host/x.json", "https:\\\\host\\x.json"]) {
    for (const key of ["rateCardPath", "ledgerPath"]) {
      assert.throws(() => validateAnswers({ ...workbookAnswers(), [key]: value }), new RegExp(`${key}: local_file_required`), `${key} ${value}`);
    }
  }
  for (const value of ["config/rate-card.json", "C:\\repo\\config\\rate-card.json", "..\\config\\rate-card.json"]) {
    assert.equal(validateAnswers({ ...workbookAnswers(), rateCardPath: value }).rateCardPath, value);
  }
});

test("workbook configuration refuses unknown answers rather than ignoring misspelled decisions", async () => {
  const { validateAnswers } = await configModule();
  assert.throws(() => validateAnswers({ ...workbookAnswers(), unsuspected: true }), /unknown_field/);
});

const drGateway = () => workbookAnswers().gatewayResourceId.replace("fixture-apim", "fixture-dr-apim");

test("DR: optional gatewayResourceIds widens every usage query to the listed gateways; absent, the workbook is unchanged", async () => {
  const { buildWorkbook } = await buildModule();
  const { validateAnswers } = await configModule();
  const single = workbookAnswers().gatewayResourceId;
  const listed = { ...workbookAnswers(), gatewayResourceIds: [single, drGateway()] };
  assert.deepEqual(validateAnswers(listed).gatewayResourceIds, [single, drGateway()]);
  const one = buildWorkbook(workbookAnswers(), workbookRateCard(), fixtureLedger);
  const two = buildWorkbook(listed, workbookRateCard(), fixtureLedger);
  assert.ok(one.preamble.includes(`let GatewayResourceId = "${single}";`), one.preamble);
  assert.ok(two.preamble.includes(`let GatewayResourceId = "${single},${drGateway()}";`), two.preamble);
  assert.notEqual(one.parameters.contentTags.value["ccof-answers"], two.parameters.contentTags.value["ccof-answers"]);
});

test("DR: gatewayResourceIds must be 1-4 distinct APIM ids that include gatewayResourceId", async () => {
  const { validateAnswers } = await configModule();
  const single = workbookAnswers().gatewayResourceId;
  const cases: Array<[unknown, string]> = [
    ["not-an-array", "invalid_format"],
    [[], "invalid_format"],
    [[single, workbookAnswers().reconcilerResourceId], "invalid_format"],
    [[single, `${drGateway()}"`], "invalid_format"],
    [[single, 1], "invalid_format"],
    [[single, ...[1, 2, 3, 4].map((n) => `${drGateway()}${n}`)], "too_many"],
    [[single, single.toUpperCase().replace("/SUBSCRIPTIONS/", "/subscriptions/")], "duplicate"],
    [[drGateway()], "single_not_in_list"],
  ];
  for (const [value, problem] of cases) {
    assert.throws(() => validateAnswers({ ...workbookAnswers(), gatewayResourceIds: value }), new RegExp(`gatewayResourceIds: ${problem}`), JSON.stringify(value));
  }
});

const settings = () => ({ defaultProjectId: "*", maxRows: 1000, topUsers: 25, maxQueryDays: 62, budgetLookbackDays: 31 });

test("workbook settings for WP-CORE's answers file accept exactly the report settings", async () => {
  const { validateWorkbookSettings, workbookSettingKeys } = await configModule();
  assert.deepEqual(validateWorkbookSettings(settings()), settings());
  assert.deepEqual([...workbookSettingKeys], Object.keys(settings()));
  for (const key of Object.keys(settings())) {
    const missing: Record<string, unknown> = settings();
    delete missing[key];
    assert.throws(() => validateWorkbookSettings(missing), new RegExp(`${key}: required`));
  }
  assert.throws(() => validateWorkbookSettings({ ...settings(), subscriptionId: "x" }), /unknown_field/);
  assert.throws(() => validateWorkbookSettings({ ...settings(), topUsers: 1001 }), /topUsers: exceeds_maxRows/);
  assert.throws(() => validateWorkbookSettings({ ...settings(), maxQueryDays: 1.5 }), /maxQueryDays: positive_integer_required/);
  assert.throws(() => validateWorkbookSettings({ ...settings(), maxQueryDays: 30 }), /maxQueryDays: must_cover_a_calendar_month/);
  assert.equal(validateWorkbookSettings({ ...settings(), maxQueryDays: 31 }).maxQueryDays, 31);
  assert.throws(() => validateWorkbookSettings({ ...settings(), retentionDays: 31 }), /unknown_field/,
    "retention is the workspace's, composed by WP-CORE from availability.telemetry, not a report setting");
  assert.throws(() => validateWorkbookSettings({ ...settings(), defaultProjectId: " " }), /defaultProjectId: nonempty_text_required/);
  assert.throws(() => validateWorkbookSettings([]), /settings: object_required/);
});

test("workbook builder includes all required sections, time selectors, IDs and export provenance", async () => {
  const { buildWorkbook } = await buildModule();
  const artifact = buildWorkbook(workbookAnswers(), workbookRateCard(), fixtureLedger);
  const workbook = artifact.workbook;
  assert.equal(workbook.version, "Notebook/1.0");
  const names = workbook.items.map(item => item.name);
  for (const section of ["period", "health", "usage", "model-mix", "top-users", "budgets", "reconciler-runs", "unpriced", "chargeback"]) {
    assert.ok(names.includes(section), section);
  }
  const parameters = workbook.items.find(item => item.name === "period")!.content.parameters as any[];
  assert.equal(parameters.find(p => p.name === "Period")!.value, "month");
  assert.equal(parameters.find(p => p.name === "TimeRange")!.type, 4);
  assert.equal(parameters.find(p => p.name === "TimeRange")!.typeSettings.allowCustom, true);
  const queries = workbook.items.filter(item => item.type === 3);
  assert.equal(queries.length, 8);
  for (const item of queries) {
    assert.equal(item.content.queryType, 0);
    assert.deepEqual(item.content.crossComponentResources, [workbookAnswers().workspaceResourceId]);
    assert.equal(item.content.showExportToExcel, true);
    assert.equal(item.content.exportToExcelOptions, "all");
    assert.match(item.content.noDataMessage as string, /not evidence of zero/i);
    const query = item.content.query as string;
    assert.match(query, /base64_decode_tostring\("\{Project:base64\}"\)/);
    assert.match(query, /\{TimeRange:start\}/);
    assert.match(query, /\{TimeRange:end\}/);
    assert.match(query, /startofmonth/);
    assert.doesNotMatch(query, /\{Project\}/);
    assert.doesNotMatch(query, /\b(?:RequestMessages|ResponseMessages|RequestBody|ResponseBody)\b/);
  }
  const all = JSON.stringify(workbook);
  assert.match(all, /Entra object id/);
  assert.match(all, /list price/i);
  assert.match(all, /fixture-2026-10/);
  assert.match(all, /2026-10-02/);
  assert.match(all, /retention/i);
  const chargeback = workbook.items.find(item => item.name === "chargeback")!.content.query as string;
  assert.match(chargeback, /periodStart/);
  assert.match(chargeback, /periodEnd/);
  assert.match(chargeback, /rateCardVersion/);
  assert.match(chargeback, /rateCardSha256/);
  assert.match(chargeback, /truncated/);
  assert.match(chargeback, /retentionTruncated = RetentionTruncated/);
  assert.match(chargeback, /listCcu = iff\(not\(RetentionTruncated\) and requests > 0/);
  assert.equal(artifact.parameters.workbookResourceName.value, workbookAnswers().workbookResourceName);
  assert.equal(artifact.parameters.workspaceResourceId.value, workbookAnswers().workspaceResourceId);
  assert.deepEqual(artifact.parameters.workbookContent.value, workbook);
  assert.deepEqual(Object.keys(artifact.parameters.contentTags.value), ["ccof-rate-card", "ccof-ledger", "ccof-answers", "ccof-content"]);
  assert.equal(artifact.parameters.contentTags.value["ccof-content"], artifact.contentSha256);
  assert.match(artifact.contentSha256, /^[a-f0-9]{64}$/);
  assert.match(artifact.rateCardSha256, /^[a-f0-9]{64}$/);
  assert.match(artifact.ledgerSha256, /^[a-f0-9]{64}$/);
});

test("workbook content and digests do not depend on line endings or machine-specific paths", async () => {
  const { buildWorkbook } = await buildModule();
  const cardText = JSON.stringify(workbookRateCard(), null, 2);
  const lfBuild = buildWorkbook(workbookAnswers(), cardText, fixtureLedger);
  const crlfBuild = buildWorkbook({ ...workbookAnswers(), rateCardPath: "C:\\elsewhere\\card.json", ledgerPath: "other.kql",
    outputDirectory: ".env.other", deploymentName: "other-run" }, cardText.replace(/\n/g, "\r\n"), fixtureLedger.replace(/\n/g, "\r\n"));
  assert.deepEqual(crlfBuild.workbook, lfBuild.workbook);
  assert.deepEqual(crlfBuild.parameters.contentTags, lfBuild.parameters.contentTags);
  assert.doesNotMatch(JSON.stringify(lfBuild.workbook), /\\r\\n/);
  const renamed = buildWorkbook({ ...workbookAnswers(), workbookDisplayName: "Renamed" }, cardText, fixtureLedger);
  assert.notEqual(renamed.parameters.contentTags.value["ccof-answers"], lfBuild.parameters.contentTags.value["ccof-answers"]);
  assert.equal(renamed.contentSha256, lfBuild.contentSha256);
  const resized = buildWorkbook({ ...workbookAnswers(), maxRows: 999 }, cardText, fixtureLedger);
  assert.notEqual(resized.contentSha256, lfBuild.contentSha256);
  assert.notEqual(resized.parameters.contentTags.value["ccof-answers"], lfBuild.parameters.contentTags.value["ccof-answers"]);
});

test("workbook builder binds selected resource IDs and card changes instead of hardcoded inputs", async () => {
  const { buildWorkbook } = await buildModule();
  const answers = workbookAnswers();
  answers.gatewayResourceId = answers.gatewayResourceId.replace("fixture-apim", "changed-apim");
  answers.reconcilerResourceId = answers.reconcilerResourceId.replace("fixture-reconciler", "changed-rec");
  answers.maxRows = 123;
  answers.retentionDays = 47;
  const card = workbookRateCard();
  card.version = "changed-card";
  const artifact = buildWorkbook(answers, card, fixtureLedger);
  const all = JSON.stringify(artifact.workbook);
  assert.match(all, /changed-apim/);
  assert.match(all, /changed-rec/);
  assert.match(all, /changed-card/);
  assert.doesNotMatch(all, /fixture-apim|fixture-reconciler/);
  assert.match(all, /123/);
  assert.match(all, /FromTime < ReportNow - 47 \* 1d/);
});

test("workbook builder refuses a missing ledger function or content-bearing query", async () => {
  const { buildWorkbook } = await buildModule();
  assert.throws(() => buildWorkbook(workbookAnswers(), workbookRateCard(), ""), /ledger_function_required/);
  assert.throws(() => buildWorkbook(workbookAnswers(), workbookRateCard(),
    fixtureLedger + "\nlet bad = ResponseMessages;"), /content_columns_forbidden/);
});

test("Bicep deploys only a shared workbook and has no environment defaults or hardcoded IDs", async () => {
  const { auditTemplate } = await buildModule();
  const template = readFileSync(new URL("../infra/workbook/main.bicep", import.meta.url), "utf8");
  assert.deepEqual(auditTemplate(template), []);
  assert.match(template, /Microsoft\.Insights\/workbooks@2023-06-01/);
  assert.match(template, /serializedData:\s*string\(workbookContent\)/);
  assert.match(template, /sourceId:\s*workspaceResourceId/);
  const hardcoded = template + '\nvar accidentalId = "11111111-1111-4111-8111-111111111111"';
  assert.ok(auditTemplate(hardcoded).includes("hardcoded_id"));
  assert.ok(auditTemplate(template + "\nparam wrong string = 'default'").includes("parameter_default"));
  assert.ok(auditTemplate(template.replace("Microsoft.Insights/workbooks@", "Microsoft.Web/sites@")).includes("resource_boundary"));
  assert.ok(auditTemplate(template.replace("string(workbookContent)", "'{}'")).includes("serialized_content"));
  assert.ok(auditTemplate(template.replace("sourceId: workspaceResourceId", "sourceId: 'azure monitor'")).includes("workspace_binding"));
});

test("D1 workbook resource creation is separate from D2 report configuration and has no role assignments", async () => {
  const { auditTemplate } = await buildModule();
  const resource = readFileSync(new URL("../infra/workbook/resource.bicep", import.meta.url), "utf8");
  assert.deepEqual(auditTemplate(resource, "resource"), []);
  assert.match(resource, /D2/);
  assert.doesNotMatch(resource, /param workbookContent|roleAssignments|rateCard|CcofUsageLedger/);
  assert.match(resource, /output workbookResourceId string/);
  assert.ok(auditTemplate(resource + "\nparam wrong string = 'default'", "resource").includes("parameter_default"));
  assert.ok(auditTemplate(resource.replace("Microsoft.Insights/workbooks@", "Microsoft.Authorization/roleAssignments@"), "resource").includes("resource_boundary"));
});

test("workbook query sources guard partial costs, counts, time windows and latest budget state", async () => {
  const { auditQueries } = await buildModule();
  const pricing = readFileSync(new URL("../analytics/workbooks/pricing.kql", import.meta.url), "utf8");
  const budgets = readFileSync(new URL("../analytics/workbooks/budgets.kql", import.meta.url), "utf8");
  assert.deepEqual(auditQueries(pricing, budgets), []);
  const negatives: Array<[string, string, string]> = [
    ["leftouter", pricing.replace("join kind=leftouter", "join kind=inner"), budgets],
    ["unpriced_null", pricing.replace("candidateCcu, decimal(null)", "candidateCcu, decimal(0)"), budgets],
    ["input_output_known", pricing.replace("inputTokensKnown and outputTokensKnown", "true"), budgets],
    ["partial_status", pricing.replace('"partial"', '"priced"'), budgets],
    ["latest_budget", pricing, budgets.replace("arg_max(computedAt, *)", "arg_max(TimeGenerated, *)")],
    ["budget_scope", pricing, budgets.replace("_ResourceId =~ ReconcilerResourceId", "true")],
    ["budget_decimal", pricing, budgets.replace("todecimal(tostring(payload.spentCcu))", "todouble(payload.spentCcu)")],
    ["budget_period", pricing, budgets.replace("periodStart < ToTime and periodEnd > FromTime", "true")],
    ["no_backend_call", pricing.replace('usageSource == "no-backend-call"', "false"), budgets],
    ["no_usage_excluded", pricing.replace("| where not(noUsage)", ""), budgets],
    ["geo_mismatch_unpriced", pricing.replace(" and not(geoMismatch),", ","), budgets],
    ["complete_only_list", pricing.replace('listCcu = iff(pricingStatus == "priced", candidateCcu, decimal(null))', "listCcu = candidateCcu"), budgets],
    ["reason_all_candidates", pricing.replace("anyInForce == 0", "not(inForce)"), budgets],
    ["runs_scope", pricing, budgets.replace(/(let ReconcilerRuns = FunctionAppLogs\s*\|\s*where )_ResourceId =~ ReconcilerResourceId/, "$1true")],
    ["runs_latest", pricing, budgets.replace("arg_max(loggedAt,", "arg_min(loggedAt,")],
    ["runs_schema", pricing, budgets.replace('tostring(payload.schema) == "ccof.reconciler.run.v1"', 'tostring(payload.schema) == "ccof.reconciler.budget.v1"')],
    // parse_json reads the date-shaped "2026-10-11" as a datetime, so every snapshot looked mismatched (WP-E2E G5).
    ["budget_version_typed", pricing, budgets.replace('extract_json("$.rateCardVersion", Message, typeof(string))', "tostring(payload.rateCardVersion)")],
  ];
  for (const [expected, price, budget] of negatives) assert.ok(auditQueries(price, budget).includes(expected), expected);
});

test("workbook health counts no-usage rows separately instead of pricing them", async () => {
  const { buildWorkbook } = await buildModule();
  const health = buildWorkbook(workbookAnswers(), workbookRateCard(), fixtureLedger).queries.health;
  assert.match(health, /noBackendCallRequests = tolong\(NoUsage\.refused\), zeroTokenRequests = tolong\(NoUsage\.zeroTokens\)/);
  assert.match(health, /noUsageRequests = tolong\(NoUsage\.refused\) \+ tolong\(NoUsage\.zeroTokens\)/);
  assert.match(health, /let NoUsage = toscalar\(LedgerRows \| where noUsage/);
  assert.match(health, /RetentionTruncated, "retention_truncated"/);
});
