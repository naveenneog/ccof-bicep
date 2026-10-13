import { createHash } from "node:crypto";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { buildWorkbook } from "./build.ts";
import { validateAnswers } from "./config.ts";
import { compileRateCard, fields, kqlString } from "./rate-card.ts";
import { bounded, health, rollup } from "./queries.ts";
import { chargebackLayout } from "./chargeback-layout.ts";
import { isMain } from "./main.ts";

export interface GroupMetadata {
  projectId: string;
  classification: string;
  groupId: string;
  displayName: string | null;
}

export function validateGroups(value: unknown): GroupMetadata[] {
  if (!Array.isArray(value)) throw new Error("groups: array_required");
  const seen = new Set<string>();
  return value.map(raw => {
    const group = fields(raw, "group", ["projectId", "classification", "groupId", "displayName"]);
    for (const key of ["projectId", "classification"]) {
      if (typeof group[key] !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/.test(group[key] as string)) {
        throw new Error(`group.${key}: identifier_required`);
      }
    }
    if (typeof group.groupId !== "string" || !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(group.groupId)) {
      throw new Error("group.groupId: object_id_required");
    }
    // Graph displayName is data, not code: do not trim, case-fold or strip punctuation.
    if (group.displayName !== null && (typeof group.displayName !== "string" || !group.displayName.length || group.displayName.length > 256)) {
      throw new Error("group.displayName: exact_graph_string_or_null_required");
    }
    const key = `${group.projectId}:${group.classification}`;
    if (seen.has(key)) throw new Error("group: duplicate_project_classification");
    seen.add(key);
    return group as unknown as GroupMetadata;
  });
}

function metadata(groups: GroupMetadata[]): string {
  return `let GroupMetadata = datatable(projectId:string, classification:string, mappedGroupId:string, mappedGroupName:string)[
${groups.map(g => [g.projectId, g.classification, g.groupId.toLowerCase(), g.displayName ?? ""].map(kqlString).join(", ")).join(",\n")}
];
let GroupFilter = base64_decode_tostring("{Group:base64}");
let DeveloperFilter = base64_decode_tostring("{Developer:base64}");
let ModelFilter = base64_decode_tostring("{Model:base64}");
let Ledger = RawLedger
| extend classificationGroupId = tostring(column_ifexists("classificationGroupId", "")),
    classificationGroupDisplayName = tostring(column_ifexists("classificationGroupDisplayName", "")),
    classificationGroupNameState = tostring(column_ifexists("classificationGroupNameState", "unknown")),
    admittedModelFamily = tostring(column_ifexists("admittedModelFamily", ""))
| join kind=leftouter GroupMetadata on projectId, classification
| extend groupId = iff(isnotempty(classificationGroupId), classificationGroupId, mappedGroupId),
    groupDisplayName = case(isnotempty(classificationGroupDisplayName), classificationGroupDisplayName,
      isempty(classificationGroupId) or classificationGroupId =~ mappedGroupId, mappedGroupName, ""),
    groupAttribution = case(isnotempty(classificationGroupId), "request_group_id",
      isnotempty(mappedGroupId), "current_mapping_historical_unverified", "unknown_historical_group"),
    groupNameState = case(isnotempty(classificationGroupDisplayName), classificationGroupNameState,
      isnotempty(mappedGroupName) and (isempty(classificationGroupId) or classificationGroupId =~ mappedGroupId),
      "deployment_snapshot_not_request_snapshot", "unknown")
| extend groupId = iff(isempty(groupId), "(unknown historical group id)", groupId),
    groupDisplayName = iff(isempty(groupDisplayName), "(unknown Entra group name)", groupDisplayName),
    modelFamily = coalesce(extract(@"(?i)^claude-(haiku|sonnet|opus|fable|mythos)(?:[-.]|$)", 1, model), "unknown")
| extend modelFamily = tolower(modelFamily)
| extend familyAttribution = "model-prefix-reporting",
    familyAdmissionMismatch = isnotempty(admittedModelFamily) and admittedModelFamily != modelFamily
| where (GroupFilter == "*" or groupId =~ GroupFilter)
    and (DeveloperFilter == "*" or personId =~ DeveloperFilter)
    and (ModelFilter == "*" or model == ModelFilter);
`;
}

const costColumns = ["input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h"] as const;
export function reportRollup(groupBy: string, withGroupNames = false): string {
  const money = costColumns.map(c =>
    `${c}CostSum = sum(${c}CostUsd), ${c}CostKnownRequests = countif(isnotnull(${c}CostUsd))`).join(",\n    ");
  const moneyFlags = costColumns.map(c =>
    `${c}CostUsd = iff(${c}CostKnownRequests > 0, ${c}CostSum, decimal(null))`).join(",\n    ");
  const names = withGroupNames ? `groupNameSnapshots = make_set(groupDisplayName, 32),
    groupProjects = make_set(projectLabel, 32),
    groupNameStates = make_set(groupNameState, 8), groupAttributionStates = make_set(groupAttribution, 8),
    groupUnverifiedRequests = countif(groupAttribution != "request_group_id"),` : "";
  const groupCompleteness = withGroupNames ? `
| extend listUsd = iff(groupUnverifiedRequests == 0, listUsd, decimal(null)),
    listCcu = iff(groupUnverifiedRequests == 0, listCcu, decimal(null)),
    completeness = iff(groupUnverifiedRequests > 0, "historical_group_unverified", completeness),
    groupNamesMayBeTruncated = array_length(groupNameSnapshots) == 32` : "";
  return rollup(groupBy).replace("knownCostRequests =", `${names}
    failedRequests = countif(requestFailed),
    duplicateLlmCopies = sum(iff(llmCopies > 1, llmCopies - 1, 0)),
    duplicateTraceCopies = sum(iff(traceCopies > 1, traceCopies - 1, 0)),
    traceMismatchRequests = countif(traceConflict), llmMismatchRequests = countif(llmConflict),
    familyMismatchRequests = countif(familyAdmissionMismatch),
    cacheHitRequests = countif(cacheReadTokensKnown and cacheReadTokens > 0),
    cacheReadObservedRequests = countif(cacheReadTokensKnown),
    cacheReadSavingsSum = sum(cacheReadSavingsUsd), cacheSavingsKnownRequests = countif(isnotnull(cacheReadSavingsUsd)),
    ${money},
    knownCostRequests =`) + groupCompleteness + `
| extend ${moneyFlags},
    totalCostUsd = listUsd, knownTokenCostUsd = knownListUsd,
    knownCacheReadSavingsUsd = iff(cacheSavingsKnownRequests > 0, cacheReadSavingsSum, decimal(null)),
    observedCacheHitRequestPercent = iff(cacheReadObservedRequests > 0,
      100.0 * cacheHitRequests / cacheReadObservedRequests, real(null)),
    knownTokensSpent = coalesce(inputTokens, 0) + coalesce(outputTokens, 0)
      + coalesce(cacheReadTokens, 0) + coalesce(cacheWrite5mTokens, 0) + coalesce(cacheWrite1hTokens, 0)
| extend tokensSpent = iff(inputUnknownRequests + outputUnknownRequests + cacheReadUnknownRequests
    + cacheWrite5mUnknownRequests + cacheWrite1hUnknownRequests == 0, knownTokensSpent, long(null)),
    currency = "USD"
| project-away ${costColumns.map(c => `${c}CostSum`).join(", ")}, cacheReadSavingsSum`;
}

export function buildChargebackWorkbook(rawAnswers: unknown, rawCard: unknown, ledger: string, rawGroups: unknown) {
  const answers = validateAnswers(rawAnswers);
  const groups = validateGroups(rawGroups);
  const cardObject = typeof rawCard === "string" ? JSON.parse(rawCard) : rawCard;
  // Keep the owner's unverified families visible as usage, never attach speculative prices.
  const card = { ...cardObject, entries: cardObject.entries.filter((e: { model: string }) => !/^claude-(fable|mythos)(?:[-.]|$)/i.test(e.model)) };
  const rateCard = compileRateCard(card);
  const legacy = buildWorkbook(answers, card, ledger);
  const prefix = legacy.queries.usage.slice(0, legacy.queries.usage.indexOf("let Report = materialize("));
  if (!prefix.includes("let PricedUsage = LedgerRows")) throw new Error("workbook_source_contract_changed");
  let base = prefix.replace("let Ledger = CcofUsageLedger", "let RawLedger = CcofUsageLedger")
    .replace("let KnownModels", metadata(groups) + "\nlet KnownModels")
    .replace("let PricedUsage = LedgerRows", "let BasePricedUsage = LedgerRows")
    .replace('classificationGroup = iff(isempty(classification), "(unknown)", classification)', "classificationLabel = classification");
  for (const category of ["cacheWrite5m", "cacheWrite1h", "cacheRead"]) {
    base = base.replace(`coalesce(${category}Tokens, 0) == 0`, `${category}TokensKnown and ${category}Tokens == 0`);
  }
  base += `let PricedUsage = BasePricedUsage
| extend requestFailed = tobool(column_ifexists("requestFailed", false)),
    llmCopies = tolong(column_ifexists("llmCopies", 1)), traceCopies = tolong(column_ifexists("traceCopies", 1)),
    traceConflict = tobool(column_ifexists("traceConflict", false)), llmConflict = tobool(column_ifexists("llmConflict", false))
| extend ${costColumns.map(c => `${c}CostUsd = iff(isnotnull(knownListCcu) and ${c}TokensKnown,
      todecimal(${c}Tokens) * ${c}Rate / decimal(100), decimal(null))`).join(",\n    ")},
    cacheReadSavingsUsd = iff(isnotnull(knownListCcu) and cacheReadTokensKnown,
      todecimal(cacheReadTokens) * (inputRate - cacheReadRate) / decimal(100), decimal(null));
`;
  const provenance = `\n| extend periodStart = FromTime, periodEnd = ToTime, basis = "fixed list price, not invoice",
    rateCardVersion = RateCardVersion, rateSourceDates = tostring(RateCardSourceDates),
    retentionTruncated = RetentionTruncated, rateCardSha256 = ${kqlString(legacy.rateCardSha256)},
    ledgerSha256 = ${kqlString(legacy.ledgerSha256)}`;
  const report = (by: string, sort = "knownListUsd desc nulls last", withGroupNames = false) =>
    base + bounded(reportRollup(by, withGroupNames) + provenance, answers.maxRows, sort);
  const queries = {
    health: base + health(),
    developers: report("person"),
    usage: report("projectLabel, groupId, person", "knownListUsd desc nulls last", true),
    groups: report("groupId", "knownListUsd desc nulls last", true),
    models: report("model"),
    families: report("modelFamily"),
    totals: report("basis = \"fixed list price\""),
    trends: report("day = bin(timestamp, 1d), modelFamily", "day asc, modelFamily asc"),
    diagnostics: base + bounded(`Ledger
| where requestFailed or usageSource == "no-backend-call" or not(attributionKnown) or traceConflict or llmConflict or familyAdmissionMismatch
    or not(inputTokensKnown and outputTokensKnown and cacheReadTokensKnown and cacheWrite5mTokensKnown and cacheWrite1hTokensKnown)
| project timestamp, gatewayRequestId, personId, projectId, groupId, groupDisplayName,
    groupAttribution, model, modelFamily, admittedModelFamily, familyAttribution, familyAdmissionMismatch,
    usageSource, attributionKnown, requestFailed, gatewayOutcomeKnown, traceConflict, llmConflict, llmCopies, traceCopies,
    inputTokens, outputTokens, cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens` + provenance, answers.maxRows, "timestamp desc"),
    unpriced: base + bounded(`PricedUsage
| where pricingStatus != "priced" or not(attributionKnown)
| project timestamp, gatewayRequestId, person, projectLabel, groupId, groupDisplayName, model, modelFamily,
    pricingStatus, pricingReason, knownListCcu, listCcu, knownListUsd = knownListCcu / decimal(100),
    inputTokens, outputTokens, cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens` + provenance, answers.maxRows, "timestamp desc"),
  };
  const workbook = chargebackLayout(answers, rateCard, queries);
  const hash = (s: string) => createHash("sha256").update(s).digest("hex");
  const contentSha256 = hash(JSON.stringify(workbook));
  const parameters = { ...legacy.parameters, workbookContent: { value: workbook },
    contentTags: { value: { ...legacy.parameters.contentTags.value, "ccof-content": contentSha256,
      "ccof-groups": hash(JSON.stringify(groups)), "ccof-report": "fixed-price-v1" } } };
  return { groups, rateCard, queries, workbook, parameters, contentSha256 };
}

export function verifyChargebackArtifact(raw: unknown): string {
  const artifact = raw as { parameters?: { workbookContent?: { value?: { version?: string; items?: unknown[] } };
    contentTags?: { value?: Record<string, string> } } };
  const content = artifact?.parameters?.workbookContent?.value;
  const tags = artifact?.parameters?.contentTags?.value;
  if (content?.version !== "Notebook/1.0" || !Array.isArray(content.items) || content.items.length < 10
    || tags?.["ccof-report"] !== "fixed-price-v1") throw new Error("workbook_content_required");
  const digest = createHash("sha256").update(JSON.stringify(content)).digest("hex");
  if (tags["ccof-content"] !== digest) throw new Error("content_digest_mismatch");
  return digest;
}

export function generateChargebackFiles(answersPath: string, groupsPath: string) {
  const answers = validateAnswers(JSON.parse(readFileSync(answersPath, "utf8")));
  const artifact = buildChargebackWorkbook(answers, readFileSync(answers.rateCardPath, "utf8"),
    readFileSync(answers.ledgerPath, "utf8"), JSON.parse(readFileSync(groupsPath, "utf8")));
  mkdirSync(answers.outputDirectory, { recursive: true });
  writeFileSync(path.join(answers.outputDirectory, "workbook.json"), JSON.stringify(artifact.workbook, null, 2) + "\n");
  writeFileSync(path.join(answers.outputDirectory, "parameters.json"), JSON.stringify({
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    contentVersion: "1.0.0.0", parameters: artifact.parameters,
  }, null, 2) + "\n");
  return { contentSha256: artifact.contentSha256 };
}

if (isMain(import.meta.url)) {
  try {
    if (process.argv[2] === "--verify" && process.argv.length === 4) {
      console.log(JSON.stringify({ schema: "ccof.chargeback.build.v1", outcome: "validated",
        contentSha256: verifyChargebackArtifact(JSON.parse(readFileSync(process.argv[3], "utf8"))) }));
    } else {
      const [flag, answers, groupFlag, groups, ...extra] = process.argv.slice(2);
      if (flag !== "--answers" || !answers || groupFlag !== "--groups" || !groups || extra.length) throw new Error("use --answers PATH --groups PATH");
      console.log(JSON.stringify({ schema: "ccof.chargeback.build.v1", outcome: "validated", ...generateChargebackFiles(answers, groups) }));
    }
  } catch {
    console.error(JSON.stringify({ schema: "ccof.chargeback.build.v1", outcome: "refused", reason: "reporting_input_invalid" }));
    process.exitCode = 1;
  }
}
