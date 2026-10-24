import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { buildWorkbook } from "../../analytics/workbooks/build.ts";
import { isMain } from "../../analytics/workbooks/main.ts";
import { compileRateCard, kqlString } from "../../analytics/workbooks/rate-card.ts";
import { rollup } from "../../analytics/workbooks/queries.ts";
import { renderQuery } from "../../analytics/workbooks/render.ts";
import { pilotRateCardText, workbookAnswers, workbookRateCard } from "./workbook-fixtures.ts";
import { usageData, usageCases, budgetData, fixturePerson, reportNow, realCardCases, realCardData, ledgerRows,
  rateCardVersionData, versionPersons } from "./workbook-kql-data.ts";
import type { UsageCase } from "./workbook-kql-data.ts";

export interface KqlCheck {
  id: string;
  query: string;
  expectedTests: string[];
  shouldPass: boolean;
  target?: string;
}

const source = (name: string) => readFileSync(new URL(`../../analytics/workbooks/${name}`, import.meta.url), "utf8");
const nowContext = () => `let ReportNow = ${reportNow}; let FromTime = datetime(2026-10-01);
let ToTime = datetime(2026-11-01); let RangeValid = true; let BudgetLookbackDays = 31;
let ProjectFilter = "*"; let ReconcilerResourceId = ${kqlString(workbookAnswers().reconcilerResourceId)};\n`;
const isUsage = (c: UsageCase) => c.status !== "no_usage";

// One named test per case: no-usage rows are absent; others carry the expected status and amount.
function expectedChecks(cases: UsageCase[]): string {
  return `let Expected = datatable(gatewayRequestId:string, wantStatus:string, wantCcu:string)[
${cases.map(c => [kqlString(c.id), kqlString(c.status), kqlString(c.cost)].join(", ")).join(",\n")}];
let Checks = Expected
| join kind=leftouter PricedUsage on gatewayRequestId
| project test = gatewayRequestId, passed = iff(wantStatus == "no_usage", isempty(gatewayRequestId1),
  isnotempty(gatewayRequestId1) and pricingStatus == wantStatus
  and ((isempty(wantCcu) and isnull(knownListCcu)) or knownListCcu == todecimal(wantCcu))
  and ((wantStatus == "priced" and listCcu == todecimal(wantCcu)) or (wantStatus != "priced" and isnull(listCcu))));
union Checks, (PricedUsage | summarize n=count() | project test="one-price-per-request", passed=n==${cases.filter(isUsage).length})`;
}

function renderParameters(query: string): string {
  return renderQuery(query.replace("let ReportNow = now();", `let ReportNow = ${reportNow};`),
    { period: "month", project: "*", from: null, to: null });
}

// With ReportNow 2026-10-11 and 31 days' retention, the previous month (from Sep 1) starts before the cut-off.
function previousMonth(query: string): string {
  return renderQuery(query.replace("let ReportNow = now();", `let ReportNow = ${reportNow};`),
    { period: "previous", project: "*", from: null, to: null });
}

export function kqlChecks(): KqlCheck[] {
  const card = compileRateCard(workbookRateCard()).kql + "\n";
  const pricing = source("pricing.kql");
  const budgets = source("budgets.kql");
  const pricePrefix = usageData() + card + "let RetentionTruncated = false;\n"
    + "let Ledger = union FixtureUsage, (FixtureUsage | where gatewayRequestId == \"full\");\n";
  const priceTests = [...usageCases.map(c => c.id), "one-price-per-request"];
  const priceCheck = pricePrefix + pricing + "\n" + expectedChecks(usageCases);
  const realCard = compileRateCard(JSON.parse(pilotRateCardText())).kql + "\n";
  const realCardCheck = realCardData() + realCard + "let Ledger = RealCardUsage;\n" + pricing + "\n" + expectedChecks(realCardCases);
  const realCardTests = [...realCardCases.map(c => c.id), "one-price-per-request"];
  const rollupCase = (id: string, ids: string[], assertion: string) => {
    const local = `let PricedUsage = PricedUsage | where gatewayRequestId in (${ids.map(kqlString).join(",")});\n`;
    return `let Check_${id.replaceAll("-", "_")} = () { ${local}${rollup("projectLabel")}
| project test=${kqlString(id)}, passed=${assertion} };`;
  };
  const rollupTests = ["complete-rollup", "partial-rollup", "all-unpriced-rollup", "mixed-rollup", "zero-rollup", "unattributed-rollup"];
  const rollups = [
    rollupCase("complete-rollup", ["full"], 'listCcu==decimal(4.85) and knownListCcu==decimal(4.85) and inputTokens==10 and inputStatus=="known"'),
    rollupCase("partial-rollup", ["stream"], 'isnull(listCcu) and knownListCcu==decimal(4) and isnull(cacheReadTokens) and cacheReadStatus=="unknown"'),
    rollupCase("all-unpriced-rollup", ["unknown-model", "unknown-input"], 'isnull(listCcu) and isnull(knownListCcu) and unpricedRequests==2'),
    rollupCase("mixed-rollup", ["full", "stream"], 'isnull(listCcu) and knownListCcu==decimal(8.85) and cacheReadTokens==5 and cacheReadUnknownRequests==1 and cacheReadStatus=="partial"'),
    rollupCase("zero-rollup", ["zero-io-with-cache"], 'listCcu==decimal(0.14) and inputTokens==0 and inputStatus=="known" and outputTokens==0 and outputStatus=="known"'),
    rollupCase("unattributed-rollup", ["unattributed"], 'unattributedRequests==1 and projectLabel=="(unattributed)" and isnull(listCcu)'),
  ].join("\n") + "\nunion " + rollupTests.map(id => `Check_${id.replaceAll("-", "_")}()`).join(", ");
  const budgetPrefix = nowContext() + card + budgetData();
  const budgetCheck = (id: string, filter: string, condition: string) =>
    `(BudgetSnapshots | where ${filter} | summarize n=count(), correct=countif(${condition})
      | project test=${kqlString(id)}, passed=n==1 and correct==1)`;
  const budgetExpected = "union " + [
    budgetCheck("latest-computed-not-ingested", `personId == "${fixturePerson}" and period=="2026-10"`, 'spentCcu==decimal(20.1234567890123456789) and snapshotState=="current"'),
    budgetCheck("exhausted-notify-partial", 'scope=="group" and classification=="STD"', 'exhausted and mode=="notify" and completeness=="partial" and budgetState=="exhausted"'),
    budgetCheck("null-means-no-cap", 'scope=="group" and classification=="PRM"', 'isnull(budgetCcu) and budgetState=="no_cap" and not(exhausted)'),
    budgetCheck("expired-snapshot", 'personId startswith "5555"', 'snapshotState=="expired"'),
    budgetCheck("invalid-budget-is-unknown", 'personId startswith "6666"', 'snapshotState=="invalid_event" and isnull(spentCcu) and isnull(exhausted)'),
    budgetCheck("zero-budget-exhausted", 'personId startswith "aaaa"', 'budgetState=="exhausted" and spentCcu==decimal(0) and budgetCcu==decimal(0) and snapshotState=="current"'),
    budgetCheck("missing-count-invalid", 'personId startswith "bbbb"', 'snapshotState=="invalid_event" and budgetState=="unknown" and isnull(spentCcu)'),
    budgetCheck("soft-limit-warning", 'personId startswith "cccc"', 'budgetState=="warning" and not(exhausted) and snapshotState=="current"'),
    budgetCheck("no-soft-limit-flag-is-available", 'personId startswith "5555"', 'budgetState=="available"'),
    '(BudgetSnapshots | summarize n=count() | project test="resource-and-period-isolation", passed=n==8)',
  ].join(",\n");
  const budgetTests = ["latest-computed-not-ingested", "exhausted-notify-partial", "null-means-no-cap",
    "expired-snapshot", "invalid-budget-is-unknown", "zero-budget-exhausted", "missing-count-invalid", "resource-and-period-isolation",
    "soft-limit-warning", "no-soft-limit-flag-is-available"];
  // The workbook's card version is date-shaped here, as config/rate-card.json's "2026-10-11" is (WP-E2E G5).
  const versionCard = compileRateCard({ ...workbookRateCard(), version: "2026-10-11" }).kql + "\n";
  const versionExpected = "union " + [
    budgetCheck("date-shaped-version-matches-card", `personId == "${versionPersons.sameDate}"`,
      'not(rateCardMismatch) and rateCardVersion == "2026-10-11" and snapshotState == "current"'),
    budgetCheck("date-shaped-version-mismatch-flags", `personId == "${versionPersons.olderDate}"`,
      'rateCardMismatch and rateCardVersion == "2026-10-01"'),
    budgetCheck("named-version-mismatch-flags", `personId == "${versionPersons.named}"`,
      'rateCardMismatch and rateCardVersion == "fixture-2026-10"'),
  ].join(",\n");
  const versionTests = ["date-shaped-version-matches-card", "date-shaped-version-mismatch-flags", "named-version-mismatch-flags"];
  const runCheck = (id: string, filter: string, condition: string) =>
    `(ReconcilerRuns | where ${filter} | summarize n=count(), correct=countif(${condition})
      | project test=${kqlString(id)}, passed=n==1 and correct==1)`;
  const runsExpected = "union " + [
    runCheck("runs-latest-per-outcome", 'outcome=="written"',
      'runs==2 and latestRunAt==datetime(2026-10-11T10:08:00Z) and statesWritten==4 and latestAgeSeconds==120 and maxIngestionDelaySeconds==140 and unattributedCcu==decimal(0.25)'),
    runCheck("runs-failure-visible", 'outcome=="failed"', 'reason=="ledger_query_failed" and statesWritten==0'),
    runCheck("runs-lease-skip-visible", 'outcome=="skipped_lease_held"', 'reason=="lease_held"'),
    '(ReconcilerRuns | summarize n=sum(runs), rows=count() | project test="runs-resource-and-schema-isolation", passed=n==4 and rows==3)',
  ].join(",\n");
  const runTests = ["runs-latest-per-outcome", "runs-failure-visible", "runs-lease-skip-visible", "runs-resource-and-schema-isolation"];
  // A period older than the workspace retention can only give a lower bound, never a complete total.
  const retentionCheck = usageData() + card + "let RetentionTruncated = true;\nlet Ledger = FixtureUsage;\n" + pricing
    + `\nlet Check = () { let PricedUsage = PricedUsage | where gatewayRequestId == "full";\n${rollup("projectLabel")}
| project test="retention-truncated-not-complete", passed = completeness == "retention_truncated" and isnull(listCcu)
    and knownListCcu == decimal(4.85) };\nCheck()`;
  // Two effective intervals: the in-force entry lacks the request's geography; the closed one has it.
  const twoIntervals = workbookRateCard();
  twoIntervals.entries.push({ ...structuredClone(twoIntervals.entries[0]), effectiveFrom: "2026-09-01T00:00:00Z",
    effectiveTo: "2026-10-01T00:00:00Z", inferenceGeoMultipliers: { global: "1", eu: "1" } } as never);
  const reasonCases: Array<UsageCase & { reason: string }> = [
    { id: "geo-not-in-in-force-entry", geo: "eu", cost: "", status: "unpriced", reason: "geography_not_in_rate_card" },
    { id: "geo-in-closed-entry", geo: "eu", at: "2026-09-15T00:00:00Z", cost: "4.85", status: "priced", reason: "complete_token_usage" },
    { id: "before-any-entry", at: "2026-08-01T00:00:00Z", cost: "", status: "unpriced", reason: "no_rate_in_force" },
  ];
  const reasonsCheck = ledgerRows("ReasonUsage", reasonCases) + compileRateCard(twoIntervals).kql + "\nlet Ledger = ReasonUsage;\n"
    + pricing + `\nlet Expected = datatable(gatewayRequestId:string, wantStatus:string, wantReason:string)[
${reasonCases.map(c => [kqlString(c.id), kqlString(c.status), kqlString(c.reason)].join(", ")).join(",\n")}];
Expected | join kind=leftouter PricedUsage on gatewayRequestId
| project test = gatewayRequestId, passed = isnotempty(gatewayRequestId1) and pricingStatus == wantStatus
    and pricingReason == wantReason and model == "model-a"`;
  const boundary = usageData() + `let Selected=CcofUsageLedger(datetime(2026-10-11), datetime(2026-10-12), ${kqlString(workbookAnswers().gatewayResourceId)});
union
(Selected | summarize n=countif(gatewayRequestId=="full"), excluded=countif(gatewayRequestId in ("boundary-end","no-rate-in-force")) | project test="half-open-window", passed=n==1 and excluded==0),
(CcofUsageLedger(datetime(2026-10-11), datetime(2026-10-12), "wrong-resource") | summarize n=count() | project test="gateway-isolation", passed=n==0)`;
  const artifact = buildWorkbook(workbookAnswers(), workbookRateCard(), usageData());
  const inMonth = (c: UsageCase) => (c.at ?? "2026-10-11T00:00:00Z") >= "2026-10-01T00:00:00Z";
  const checks: KqlCheck[] = [
    { id: "pricing", query: priceCheck, expectedTests: priceTests, shouldPass: true },
    { id: "pricing-real-card", query: realCardCheck, expectedTests: realCardTests, shouldPass: true },
    {
      id: "health-counts", expectedTests: ["no-usage-counted-separately"], shouldPass: true,
      query: renderParameters(artifact.queries.health) + `\n| project test="no-usage-counted-separately",
  passed = noUsageRequests == ${usageCases.filter(c => !isUsage(c) && inMonth(c)).length}
    and noBackendCallRequests == ${usageCases.filter(c => !isUsage(c) && inMonth(c) && c.source === "no-backend-call").length}
    and zeroTokenRequests == ${usageCases.filter(c => !isUsage(c) && inMonth(c) && c.source !== "no-backend-call").length}
    and observedRequests == ${usageCases.filter(c => isUsage(c) && inMonth(c)).length} and not(retentionTruncated)`,
    },
    { id: "retention", query: retentionCheck, expectedTests: ["retention-truncated-not-complete"], shouldPass: true },
    {
      id: "retention-definition-health", expectedTests: ["previous-month-truncated-health"], shouldPass: true,
      query: previousMonth(artifact.queries.health)
        + `\n| project test="previous-month-truncated-health", passed = reportState == "retention_truncated" and retentionTruncated`,
    },
    {
      id: "retention-definition-chargeback", expectedTests: ["previous-month-truncated-chargeback"], shouldPass: true,
      query: previousMonth(artifact.queries.chargeback) + `\n| summarize n=count(), bad=countif(completeness != "retention_truncated" or isnotnull(listCcu))
| project test="previous-month-truncated-chargeback", passed = n > 0 and bad == 0`,
    },
    { id: "pricing-reasons", query: reasonsCheck, expectedTests: reasonCases.map(c => c.id), shouldPass: true },
    { id: "rollups", query: pricePrefix + pricing + "\n" + rollups, expectedTests: rollupTests, shouldPass: true },
    { id: "budget-snapshots", query: budgetPrefix + budgets + "\n" + budgetExpected, expectedTests: budgetTests, shouldPass: true },
    {
      id: "budget-rate-card-version", query: nowContext() + versionCard + rateCardVersionData() + budgets + "\n" + versionExpected,
      expectedTests: versionTests, shouldPass: true,
    },
    { id: "reconciler-runs", query: budgetPrefix + budgets + "\n" + runsExpected, expectedTests: runTests, shouldPass: true },
    { id: "time-boundaries", query: boundary, expectedTests: ["half-open-window", "gateway-isolation"], shouldPass: true },
  ];
  type Baseline = "pricing" | "pricing-real-card" | "pricing-reasons" | "health-counts" | "retention" | "rollups"
    | "budget-snapshots" | "budget-rate-card-version" | "reconciler-runs" | "time-boundaries" | "retention-definition-health"
    | "retention-definition-chargeback";
  // Built from the fixture's retention (35, unlike the 31-day lookback): any other source fails the anchor check.
  const retentionCut = `FromTime < ReportNow - ${workbookAnswers().retentionDays} * 1d`;
  const mutations: Array<[string, string, string, string, Baseline]> = [
    ["zero-unpriced", "candidateCcu, decimal(null)", "candidateCcu, decimal(0)", "unknown-model", "pricing"],
    ["wrong-unit", "decimal(0.2)", "decimal(0.4)", "full", "pricing"],
    ["wrong-geo", "inference_geo == rateGeo", "true", "unsupported-geo", "pricing"],
    ["missing-model-row", "join kind=leftouter RateCard", "join kind=inner RateCard", "unknown-model", "pricing"],
    ["missing-base-count-guard", "inputTokensKnown and outputTokensKnown", "true", "flag-unknown", "pricing"],
    ["partial-as-complete", '"partial", "priced"', '"priced", "priced"', "stream", "pricing"],
    ["wrong-tier-boundary", "promptKnownTokens <= tierUpTo", "promptKnownTokens < tierUpTo", "tier-boundary", "pricing"],
    ["wrong-effective-date", "timestamp >= effectiveFrom", "true", "no-rate-in-force", "pricing"],
    ["no-date-alias", 'normalizedModel, undatedModel)', 'normalizedModel, normalizedModel)', "dated-model", "pricing"],
    ["wrong-budget-latest", "arg_max(computedAt, *)", "arg_max(TimeGenerated, *)", "latest-computed-not-ingested", "budget-snapshots"],
    ["wrong-budget-resource", "_ResourceId =~ ReconcilerResourceId", "true", "latest-computed-not-ingested", "budget-snapshots"],
    ["wrong-budget-period", "periodStart < ToTime and periodEnd > FromTime", "true", "resource-and-period-isolation", "budget-snapshots"],
    ["zero-unpriced-budget", "iff(eventValid, spentCcu, decimal(null))", "iff(eventValid, spentCcu, decimal(0))", "invalid-budget-is-unknown", "budget-snapshots"],
    ["inclusive-period-end", "timestamp < toTime", "timestamp <= toTime", "half-open-window", "time-boundaries"],
    ["unattributed-as-complete", "unattributedRequests == 0", "true", "unattributed-rollup", "rollups"],
    ["zero-all-unpriced-total", "iff(knownCostRequests > 0, knownCostSum, decimal(null))",
      "iff(knownCostRequests > 0, knownCostSum, decimal(0))", "all-unpriced-rollup", "rollups"],
    ["zero-unknown-token-total", "iff(cacheReadKnownRequests > 0, cacheReadTokens, long(null))",
      "iff(cacheReadKnownRequests > 0, cacheReadTokens, 0)", "partial-rollup", "rollups"],
    ["no-usage-priced", "| where not(noUsage)", "| where true", "no-backend-call", "pricing"],
    ["no-backend-call-ignored", 'usageSource == "no-backend-call"', "false", "no-backend-call-with-tokens", "pricing"],
    ["no-usage-ignores-cache", "coalesce(cacheReadTokens, 0) == 0", "true", "zero-io-with-cache", "pricing"],
    ["no-usage-hidden-in-health", "noUsageRequests = tolong(NoUsage.refused) + tolong(NoUsage.zeroTokens)", "noUsageRequests = 0", "no-usage-counted-separately", "health-counts"],
    ["real-card-dated-alias", "normalizedModel, undatedModel)", "normalizedModel, normalizedModel)", "real-haiku-4-5-dated", "pricing-real-card"],
    ["real-card-tier-boundary", "promptKnownTokens <= tierUpTo", "promptKnownTokens < tierUpTo", "real-haiku-5-5-boundary", "pricing-real-card"],
    ["real-card-geo-upper-bound", "arg_min(candidateCcu, *)", "arg_max(candidateCcu, *)", "real-haiku-5-5-unknown-geo", "pricing-real-card"],
    ["runs-earliest-not-latest", "arg_max(loggedAt,", "arg_min(loggedAt,", "runs-latest-per-outcome", "reconciler-runs"],
    ["runs-any-resource", "_ResourceId =~ ReconcilerResourceId", "true", "runs-resource-and-schema-isolation", "reconciler-runs"],
    ["runs-any-schema", 'tostring(payload.schema) == "ccof.reconciler.run.v1"', "true", "runs-resource-and-schema-isolation", "reconciler-runs"],
    ["budget-any-schema", 'tostring(payload.schema) == "ccof.reconciler.budget.v1"', "true", "resource-and-period-isolation", "budget-snapshots"],
    ["version-parsed-as-datetime", 'extract_json("$.rateCardVersion", Message, typeof(string))', "tostring(payload.rateCardVersion)",
      "date-shaped-version-matches-card", "budget-rate-card-version"],
    ["version-never-compared", "rateCardMismatch = rateCardVersion != RateCardVersion", "rateCardMismatch = false",
      "date-shaped-version-mismatch-flags", "budget-rate-card-version"],
    ["zero-budget-invalid", "budgetCcu >= decimal(0)", "budgetCcu > decimal(0)", "zero-budget-exhausted", "budget-snapshots"],
    ["null-validity-current", "coalesce(eventValidRaw, false)", "eventValidRaw", "missing-count-invalid", "budget-snapshots"],
    ["retention-complete", "not(RetentionTruncated) and requests > 0", "requests > 0", "retention-truncated-not-complete", "retention"],
    ["retention-unlabelled", 'RetentionTruncated, "retention_truncated", ', "", "retention-truncated-not-complete", "retention"],
    ["reason-from-one-row", "anyInForce = max(toint(inForce))", "anyInForce = min(toint(inForce))", "geo-not-in-in-force-entry", "pricing-reasons"],
    ["no-usage-split-swapped", '"refused", countif(usageSource == "no-backend-call"), "zeroTokens", countif(usageSource != "no-backend-call")',
      '"refused", countif(usageSource != "no-backend-call"), "zeroTokens", countif(usageSource == "no-backend-call")', "no-usage-counted-separately", "health-counts"],
    ["retention-from-period-end", retentionCut, retentionCut.replace("FromTime", "ToTime"), "previous-month-truncated-health", "retention-definition-health"],
    ["retention-wrong-days", retentionCut, "FromTime < ReportNow - 62 * 1d", "previous-month-truncated-chargeback", "retention-definition-chargeback"],
  ];
  for (const [id, from, to, target, baseline] of mutations) {
    const original = checks.find(c => c.id === baseline)!;
    if (!original.query.includes(from)) throw new Error(`kql_mutation_anchor_missing: ${id}`);
    checks.push({ ...original, id, query: original.query.replaceAll(from, to), shouldPass: false, target });
  }
  for (const [id, query] of Object.entries(artifact.queries)) {
    checks.push({
      id: `render-${id}`, query: budgetData() + renderParameters(query) + `\n| summarize n=count() | project test="render-${id}", passed=n>0`,
      expectedTests: [`render-${id}`], shouldPass: true,
    });
  }
  return checks;
}

export function verifyKqlResult(check: KqlCheck, response: unknown): { tests: number; passed: number; failed: string[] } {
  const result = response as { error?: unknown; tables?: Array<{ name: string; columns: Array<{ name: string }>; rows: unknown[][] }> };
  if (!result || result.error || !Array.isArray(result.tables)) throw new Error("kql_response_error");
  const table = result.tables.find(t => t.name === "PrimaryResult");
  if (!table || !Array.isArray(table.rows) || table.rows.length !== check.expectedTests.length) throw new Error("kql_test_count");
  const nameIndex = table.columns.findIndex(c => c.name === "test");
  const passIndex = table.columns.findIndex(c => c.name === "passed");
  if (nameIndex < 0 || passIndex < 0) throw new Error("kql_test_columns");
  const names = table.rows.map(row => row[nameIndex]);
  if (new Set(names).size !== names.length || names.some(name => !check.expectedTests.includes(name as string))) throw new Error("kql_test_names");
  if (table.rows.some(row => typeof row[passIndex] !== "boolean")) throw new Error("kql_test_boolean");
  const failed = table.rows.filter(row => row[passIndex] === false).map(row => row[nameIndex] as string);
  if (check.shouldPass && failed.length) throw new Error(`kql_assertion_failed: ${failed.join(",")}`);
  if (!check.shouldPass && failed.length === 0) throw new Error("kql_mutation_survived");
  if (!check.shouldPass && !failed.includes(check.target ?? "")) throw new Error("kql_wrong_mutation_failure");
  return { tests: names.length, passed: names.length - failed.length, failed };
}

if (isMain(import.meta.url)) {
  try {
    const [operation, input, id, responsePath] = process.argv.slice(2);
    if (operation === "--write" && /^\.env\.[a-z0-9._-]+$/i.test(input ?? "")) {
      mkdirSync(input, { recursive: true });
      writeFileSync(path.join(input, "checks.json"), JSON.stringify(kqlChecks(), null, 2));
      console.log(JSON.stringify({ outcome: "fixtures_ready", checks: kqlChecks().length }));
    } else if (operation === "--verify" && input && id && responsePath) {
      const checks: KqlCheck[] = JSON.parse(readFileSync(input, "utf8"));
      const check = checks.find(c => c.id === id);
      if (!check) throw new Error("kql_unknown_check");
      const result = verifyKqlResult(check, JSON.parse(readFileSync(responsePath, "utf8")));
      console.log(JSON.stringify({ id, outcome: check.shouldPass ? "passed" : "mutation_caught", ...result }));
    } else throw new Error("kql_arguments_required");
  } catch (error) {
    console.error(JSON.stringify({ outcome: "failed", reason: error instanceof Error ? error.message : "kql_verification_failed" }));
    process.exitCode = 1;
  }
}
