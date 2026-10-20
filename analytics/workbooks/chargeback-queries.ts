// The one chargeback query builder. The workbook build (build.ts, chargeback.ts) and the admin
// console's server-side chargeback API (admin/src/chargeback.ts) both build their KQL here, so the
// console and the workbook cannot drift. Pure: no file or network access; callers pass the ledger,
// pricing and budget KQL sources and the rate card.
//
// Workbook parameters stay placeholders ({Period:base64}, {TimeRange:start}, ...). The portal
// substitutes them in the workbook; the admin app binds them server-side with render.ts, so the
// browser never sends KQL. Options used only by the admin app (extra filters, hourly bins, paging)
// leave the workbook text byte-for-byte unchanged when absent.

import { createHash } from "node:crypto";
import { compileRateCard, kqlString } from "./rate-card.ts";
import type { CompiledCard } from "./rate-card.ts";
import { bounded, context, health, rollup } from "./queries.ts";
import type { ReportContext } from "./queries.ts";

export interface GroupMetadata {
  projectId: string;
  classification: string;
  groupId: string;
  displayName: string | null;
}

export interface UsageQueryBase {
  preamble: string;
  usageBase: string;
  rateCardSha256: string;
  ledgerSha256: string;
}

export interface ChargebackQueryOptions {
  // Admin-only filters on the ledger's request-time backendId and on the model family.
  extendedFilters?: boolean;
  // Trend bin; the workbook's default is a daily `day` column.
  trendBin?: "1h" | "1d";
  // Row paging (admin); offset 0 gives the workbook's own bounded() text.
  offset?: number;
  // Extra admin-only views (by project).
  extraViews?: boolean;
}

// Line endings depend on the checkout (core.autocrlf); LF keeps content and digests the same on every machine.
export const lf = (value: string): string => value.replace(/\r\n/g, "\n");
export const sha256 = (value: string): string => createHash("sha256").update(value, "utf8").digest("hex");

// Keep the owner's unverified families visible as usage, never attach speculative prices.
export function reportingRateCard(cardObject: { entries: Array<{ model: string }> } & Record<string, unknown>) {
  return { ...cardObject, entries: cardObject.entries.filter((e) => !/^claude-(fable|mythos)(?:[-.]|$)/i.test(e.model)) };
}

export function usageQueryBase(settings: ReportContext, card: CompiledCard, cardText: string, ledger: string, pricing: string): UsageQueryBase {
  const preamble = context(settings) + "\n" + card.kql + "\n";
  const usageBase = preamble + ledger + `
let Ledger = CcofUsageLedger(iff(RangeValid, FromTime, ReportNow), iff(RangeValid, ToTime, ReportNow), GatewayResourceId)
| where RangeValid and (ProjectFilter == "*" or projectId == ProjectFilter);
` + pricing + "\n";
  return { preamble, usageBase, rateCardSha256: sha256(cardText), ledgerSha256: sha256(ledger) };
}

function metadata(groups: GroupMetadata[], extended: boolean): string {
  const extraLets = extended ? `let BackendFilter = base64_decode_tostring("{Backend:base64}");
let FamilyFilter = base64_decode_tostring("{Family:base64}");
let ClassificationFilter = base64_decode_tostring("{Classification:base64}");
let ProjectSetFilter = base64_decode_tostring("{Projects:base64}");
let ProjectSet = split(ProjectSetFilter, ",");
` : "";
  const extraWhere = extended ? `
    and (BackendFilter == "*" or backendId =~ BackendFilter)
    and (FamilyFilter == "*" or modelFamily == FamilyFilter)
    and (ClassificationFilter == "*" or classification == ClassificationFilter)
    and (ProjectSetFilter == "*" or projectId in (ProjectSet))` : "";
  return `let GroupMetadata = datatable(projectId:string, classification:string, mappedGroupId:string, mappedGroupName:string)[
${groups.map(g => [g.projectId, g.classification, g.groupId.toLowerCase(), g.displayName ?? ""].map(kqlString).join(", ")).join(",\n")}
];
let GroupFilter = base64_decode_tostring("{Group:base64}");
let DeveloperFilter = base64_decode_tostring("{Developer:base64}");
let ModelFilter = base64_decode_tostring("{Model:base64}");
${extraLets}let Ledger = RawLedger
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
    and (ModelFilter == "*" or model == ModelFilter)${extraWhere};
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

export type ChargebackQueries = Record<"health" | "developers" | "usage" | "groups" | "models" | "families" | "totals" | "trends" | "diagnostics" | "unpriced", string> & { projects?: string; classifications?: string };

// The chargeback report queries. `usage` is the result of usageQueryBase for the same settings, rate
// card and ledger; `maxRows` bounds every row view.
export function chargebackQueries(usage: UsageQueryBase, maxRows: number, groups: GroupMetadata[], options: ChargebackQueryOptions = {}): ChargebackQueries {
  const prefix = usage.usageBase;
  if (!prefix.includes("let PricedUsage = LedgerRows")) throw new Error("workbook_source_contract_changed");
  let base = prefix.replace("let Ledger = CcofUsageLedger", "let RawLedger = CcofUsageLedger")
    .replace("let KnownModels", metadata(groups, options.extendedFilters === true) + "\nlet KnownModels")
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
    retentionTruncated = RetentionTruncated, rateCardSha256 = ${kqlString(usage.rateCardSha256)},
    ledgerSha256 = ${kqlString(usage.ledgerSha256)}`;
  const offset = options.offset ?? 0;
  const report = (by: string, sort = "knownListUsd desc nulls last", withGroupNames = false) =>
    base + bounded(reportRollup(by, withGroupNames) + provenance, maxRows, sort, offset);
  if (options.trendBin !== undefined && options.trendBin !== "1h" && options.trendBin !== "1d") throw new Error("trendBin: invalid");
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error("offset: invalid");
  const trend = options.trendBin
    ? report(`bucket = bin(timestamp, ${options.trendBin}), modelFamily`, "bucket asc, modelFamily asc")
    : report("day = bin(timestamp, 1d), modelFamily", "day asc, modelFamily asc");
  const queries: ChargebackQueries = {
    health: base + health(),
    developers: report("person"),
    usage: report("projectLabel, groupId, person", "knownListUsd desc nulls last", true),
    groups: report("groupId", "knownListUsd desc nulls last", true),
    models: report("model"),
    families: report("modelFamily"),
    totals: report("basis = \"fixed list price\""),
    trends: trend,
    diagnostics: base + bounded(`Ledger
| where requestFailed or usageSource == "no-backend-call" or not(attributionKnown) or traceConflict or llmConflict or familyAdmissionMismatch
    or not(inputTokensKnown and outputTokensKnown and cacheReadTokensKnown and cacheWrite5mTokensKnown and cacheWrite1hTokensKnown)
| project timestamp, gatewayRequestId, personId, projectId, groupId, groupDisplayName,
    groupAttribution, model, modelFamily, admittedModelFamily, familyAttribution, familyAdmissionMismatch,
    usageSource, attributionKnown, requestFailed, gatewayOutcomeKnown, traceConflict, llmConflict, llmCopies, traceCopies,
    inputTokens, outputTokens, cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens` + provenance, maxRows, "timestamp desc", offset),
    unpriced: base + bounded(`PricedUsage
| where pricingStatus != "priced" or not(attributionKnown)
| project timestamp, gatewayRequestId, person, projectLabel, groupId, groupDisplayName, model, modelFamily,
    pricingStatus, pricingReason, knownListCcu, listCcu, knownListUsd = knownListCcu / decimal(100),
    inputTokens, outputTokens, cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens` + provenance, maxRows, "timestamp desc", offset),
  };
  if (options.extraViews) {
    queries.projects = report("projectLabel");
    // Project → classification drill-down (STD, PRM, CYB, ...).
    queries.classifications = report("projectLabel, classification");
  }
  return queries;
}

// Reconciler budget snapshots and runs (budgets.kql), for the admin console. The workbook reads
// FunctionAppLogs for one reconciler resource; a Flex Consumption app can log to AppTraces instead,
// so the admin source is the union of both, scoped to the configured resource IDs.
export function reconcilerQueryBase(preamble: string, budgetsKql: string, resourceIds: string[]): string {
  const marker = /FunctionAppLogs\n\| where _ResourceId =~ ReconcilerResourceId/g;
  const matches = budgetsKql.match(marker)?.length ?? 0;
  if (matches !== 2) throw new Error("budgets_source_contract_changed");
  const ids = resourceIds.map(kqlString).join(", ");
  return preamble + `let ReconcilerLogs = union isfuzzy=true FunctionAppLogs, AppTraces
| where _ResourceId in~ (${ids});
` + budgetsKql.replace(marker, "ReconcilerLogs") + "\n";
}
