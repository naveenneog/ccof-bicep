import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { validateAnswers, workbookSettingKeys } from "./config.ts";
import { isMain } from "./main.ts";
import { compileRateCard, kqlString } from "./rate-card.ts";
import { layout } from "./layout.ts";
import { bounded, health, rollup } from "./queries.ts";
import { usageQueryBase } from "./chargeback-queries.ts";

// Line endings depend on the checkout (core.autocrlf); LF keeps content and digests the same on every machine.
export const lf = (value: string) => value.replace(/\r\n/g, "\n");
const source = (name: string) => lf(readFileSync(new URL(name, import.meta.url), "utf8"));
const digest = (value: string) => createHash("sha256").update(value, "utf8").digest("hex");
const withoutComments = (value: string) => value.replace(/^\s*\/\/.*$/gm, "");
const forbidden = /\b(?:RequestMessages|ResponseMessages|RequestBody|ResponseBody)\b/;

export function auditTemplate(template: string, stage: "content" | "resource" = "content"): string[] {
  const code = withoutComments(template);
  const violations: string[] = [];
  if (/[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}/i.test(code)) violations.push("hardcoded_id");
  if (/^\s*param\s+\w+\s+\w+\s*=/m.test(code)) violations.push("parameter_default");
  const resources = [...code.matchAll(/^\s*resource\s+\w+\s+'([^']+)'/gm)].map(match => match[1]);
  if (resources.length !== 1 || resources[0] !== "Microsoft.Insights/workbooks@2023-06-01") violations.push("resource_boundary");
  const content = stage === "content" ? /serializedData:\s*string\(workbookContent\)/ : /serializedData:\s*string\(\{/;
  if (!content.test(code)) violations.push("serialized_content");
  if (!/sourceId:\s*workspaceResourceId\b/.test(code)) violations.push("workspace_binding");
  return violations;
}

export function auditQueries(pricing: string, budgets: string): string[] {
  const violations: string[] = [];
  const checks: Array<[string, string, RegExp]> = [
    ["leftouter", pricing, /join kind=leftouter RateCard on modelKey/],
    ["unpriced_null", pricing, /candidateCcu = iff\(inForce[^\n]+\n\s+candidateCcu, decimal\(null\)\)/],
    ["input_output_known", pricing, /baseCountsKnown = inputTokensKnown and outputTokensKnown/],
    ["partial_status", pricing, /not\(cacheKnown\).*"partial"/],
    ["no_backend_call", pricing, /noUsage = usageSource == "no-backend-call"/],
    ["no_usage_excluded", pricing, /^\|\s*where not\(noUsage\)\s*$/m],
    ["geo_mismatch_unpriced", pricing, /iff\(inForce and geoEligible and tierEligible and baseCountsKnown and not\(geoMismatch\),/],
    ["complete_only_list", pricing, /listCcu = iff\(pricingStatus == "priced", candidateCcu, decimal\(null\)\)/],
    ["reason_all_candidates", pricing, /anyInForce == 0, "no_rate_in_force", anyInForceGeo == 0, "geography_not_in_rate_card"/],
    ["latest_budget", budgets, /arg_max\(computedAt, \*\)/],
    ["budget_scope", budgets, /let BudgetSnapshots = FunctionAppLogs\s*\|\s*where _ResourceId =~ ReconcilerResourceId/],
    ["budget_decimal", budgets, /todecimal\(tostring\(payload\.spentCcu\)\)/],
    ["budget_period", budgets, /periodStart < ToTime and periodEnd > FromTime/],
    ["budget_version_typed", budgets, /rateCardVersion = extract_json\("\$\.rateCardVersion", Message, typeof\(string\)\)/],
    ["runs_scope", budgets, /let ReconcilerRuns = FunctionAppLogs\s*\|\s*where _ResourceId =~ ReconcilerResourceId/],
    ["runs_latest", budgets, /arg_max\(loggedAt, payload, eventIngestedAt\) by outcome, reason/],
    ["runs_schema", budgets, /tostring\(payload\.schema\) == "ccof\.reconciler\.run\.v1"/],
  ];
  for (const [name, code, pattern] of checks) if (!pattern.test(withoutComments(code))) violations.push(name);
  if (forbidden.test(pricing + budgets)) violations.push("content_columns_forbidden");
  return violations;
}

export function buildWorkbook(rawAnswers: unknown, rawCard: unknown, rawLedger: string) {
  const answers = validateAnswers(rawAnswers);
  const cardText = lf(typeof rawCard === "string" ? rawCard : JSON.stringify(rawCard));
  const ledger = lf(rawLedger);
  const card = compileRateCard(JSON.parse(cardText));
  if (!/\blet\s+CcofUsageLedger\s*=\s*\(/.test(withoutComments(ledger))) throw new Error("ledger_function_required");
  if (forbidden.test(withoutComments(ledger))) throw new Error("content_columns_forbidden");
  const pricing = source("pricing.kql");
  const budgets = source("budgets.kql");
  const violations = [...auditQueries(pricing, budgets), ...auditTemplate(source("../../infra/workbook/main.bicep"))];
  if (violations.length) throw new Error(`workbook_contract: ${violations.join(",")}`);
  // The shared builder (chargeback-queries.ts) also serves the admin console, so both read the same ledger base.
  const { preamble, usageBase, rateCardSha256, ledgerSha256 } = usageQueryBase(answers, card, cardText, ledger, pricing);
  const provenance = `
| extend periodStart = FromTime, periodEnd = ToTime, basis = "list price",
    rateCardVersion = RateCardVersion, rateSourceDates = tostring(RateCardSourceDates),
    rateCardSha256 = ${kqlString(rateCardSha256)}, ledgerSha256 = ${kqlString(ledgerSha256)},
    retentionTruncated = RetentionTruncated`;
  const queries = {
    health: usageBase + health(),
    usage: usageBase + bounded(rollup("projectLabel, classificationGroup, person") + provenance, answers.maxRows,
      "projectLabel asc, classificationGroup asc, person asc"),
    "model-mix": usageBase + bounded(rollup("model") + provenance, answers.maxRows, "requests desc"),
    "top-users": usageBase + bounded(rollup("projectLabel, person") + provenance, answers.topUsers, "knownListCcu desc nulls last"),
    budgets: preamble + budgets + "\n" + bounded("BudgetSnapshots", answers.maxRows, "projectId asc, classification asc, scope asc, scopeId asc"),
    "reconciler-runs": preamble + budgets + "\n" + bounded("ReconcilerRuns", answers.maxRows, "latestRunAt desc"),
    unpriced: usageBase + bounded(`PricedUsage
| where pricingStatus != "priced" or not(attributionKnown)
| project timestamp, gatewayRequestId, projectLabel, classificationGroup, person, model,
    pricingStatus, pricingReason, attributionKnown, inference_geo, inferenceGeoKnown, promptTierKnown,
    inputTokens, outputTokens, cacheWrite5mTokens, cacheWrite1hTokens, cacheReadTokens,
    inputTokensKnown, outputTokensKnown, cacheWrite5mTokensKnown, cacheWrite1hTokensKnown, cacheReadTokensKnown,
    knownListCcu, listCcu, knownListUsd = knownListCcu / decimal(100)` + provenance,
    answers.maxRows, "timestamp desc"),
    chargeback: usageBase + bounded(rollup("projectLabel") + provenance, answers.maxRows, "projectLabel asc"),
  };
  const workbook = layout(answers, card, queries);
  // Only answers that change the report; paths and deployment names differ per machine and run.
  const reportAnswers = Object.fromEntries(["workbookDisplayName", "workspaceResourceId", "gatewayResourceId",
    "reconcilerResourceId", ...workbookSettingKeys, "retentionDays"].map(key => [key, answers[key as keyof typeof answers]]));
  const contentTags = {
    "ccof-rate-card": rateCardSha256, "ccof-ledger": ledgerSha256,
    "ccof-answers": digest(JSON.stringify(reportAnswers)), "ccof-content": digest(JSON.stringify(workbook)),
  };
  const parameters = {
    workbookResourceName: { value: answers.workbookResourceName },
    workbookDisplayName: { value: answers.workbookDisplayName },
    location: { value: answers.location },
    workspaceResourceId: { value: answers.workspaceResourceId },
    workbookContent: { value: workbook },
    contentTags: { value: contentTags },
  };
  return { workbook, parameters, queries, preamble, usageBase, rateCardKql: card.kql, rateCardSha256, ledgerSha256, contentSha256: contentTags["ccof-content"] };
}

export function generateFiles(answersPath: string): { workbookResourceName: string; rateCardSha256: string; ledgerSha256: string; contentSha256: string } {
  const answers = validateAnswers(JSON.parse(readFileSync(answersPath, "utf8")));
  const artifact = buildWorkbook(answers, readFileSync(answers.rateCardPath, "utf8"), readFileSync(answers.ledgerPath, "utf8"));
  const folder = path.resolve(answers.outputDirectory);
  mkdirSync(folder, { recursive: true });
  writeFileSync(path.join(folder, "workbook.json"), JSON.stringify(artifact.workbook, null, 2) + "\n");
  writeFileSync(path.join(folder, "rate-card.kql"), artifact.rateCardKql + "\n");
  writeFileSync(path.join(folder, "parameters.json"), JSON.stringify({
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    contentVersion: "1.0.0.0", parameters: artifact.parameters,
  }, null, 2) + "\n");
  return { workbookResourceName: answers.workbookResourceName, rateCardSha256: artifact.rateCardSha256,
    ledgerSha256: artifact.ledgerSha256, contentSha256: artifact.contentSha256 };
}

if (isMain(import.meta.url)) {
  try {
    const [flag, answersPath, ...extra] = process.argv.slice(2);
    if (flag !== "--answers" || !answersPath || extra.length) throw new Error("answers: required_use_--answers");
    const result = generateFiles(answersPath);
    console.log(JSON.stringify({ schema: "ccof.workbook.build.v1", outcome: "validated", ...result }));
  } catch (error) {
    const reason = error instanceof Error && !("code" in error) && !(error instanceof SyntaxError)
      ? error.message : "input_file_unreadable_or_invalid_json";
    console.error(JSON.stringify({ schema: "ccof.workbook.build.v1", outcome: "refused", reason }));
    process.exitCode = 1;
  }
}
