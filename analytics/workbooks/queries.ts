import type { WorkbookAnswers } from "./config.ts";
import { kqlString } from "./rate-card.ts";

export function context(answers: WorkbookAnswers): string {
  return `let ReportNow = now();
let PeriodMode = base64_decode_tostring("{Period:base64}");
let ProjectFilter = base64_decode_tostring("{Project:base64}");
let FromTime = case(PeriodMode == "month", startofmonth(ReportNow),
    PeriodMode == "previous", startofmonth(ReportNow, -1), {TimeRange:start});
let ToTime = case(PeriodMode == "month", startofmonth(ReportNow, 1),
    PeriodMode == "previous", startofmonth(ReportNow), {TimeRange:end});
let RangeValid = isnotnull(FromTime) and isnotnull(ToTime) and FromTime < ToTime
    and ToTime - FromTime <= ${answers.maxQueryDays} * 1d;
// Rows older than the workspace retention are gone: such a period can only give lower bounds.
let RetentionTruncated = RangeValid and FromTime < ReportNow - ${answers.retentionDays} * 1d;
let GatewayResourceId = ${kqlString(answers.gatewayResourceId)};
let ReconcilerResourceId = ${kqlString(answers.reconcilerResourceId)};
let BudgetLookbackDays = ${answers.budgetLookbackDays};
`;
}

const tokenColumns = ["input", "output", "cacheWrite5m", "cacheWrite1h", "cacheRead"];

export function rollup(groupBy: string): string {
  const sums = tokenColumns.map(c => `${c}Tokens = sumif(${c}Tokens, ${c}TokensKnown),
    ${c}KnownRequests = countif(${c}TokensKnown), ${c}UnknownRequests = countif(not(${c}TokensKnown))`).join(",\n    ");
  const flags = tokenColumns.map(c => `${c}Tokens = iff(${c}KnownRequests > 0, ${c}Tokens, long(null)),
    ${c}Status = case(${c}KnownRequests == 0, "unknown", ${c}UnknownRequests > 0, "partial", "known")`).join(",\n    ");
  return `PricedUsage
| summarize requests = count(), pricedRequests = countif(pricingStatus == "priced"),
    partialRequests = countif(pricingStatus == "partial"), unpricedRequests = countif(pricingStatus == "unpriced"),
    unattributedRequests = countif(not(attributionKnown)),
    knownCostRequests = countif(isnotnull(knownListCcu)), knownCostSum = sum(knownListCcu),
    ${sums}
    by ${groupBy}
| extend knownListCcu = iff(knownCostRequests > 0, knownCostSum, decimal(null)),
    listCcu = iff(not(RetentionTruncated) and requests > 0 and partialRequests == 0 and unpricedRequests == 0
      and unattributedRequests == 0, knownCostSum, decimal(null)),
    completeness = case(RetentionTruncated, "retention_truncated", unattributedRequests > 0, "unattributed",
      unpricedRequests > 0, "unpriced_usage", partialRequests > 0, "partial", "complete"),
    ${flags}
| extend knownListUsd = knownListCcu / decimal(100), listUsd = listCcu / decimal(100)
| project-away knownCostSum`;
}

export function bounded(query: string, limit: number, sort: string): string {
  return `let Report = materialize(${query});
let ReportRows = toscalar(Report | count);
Report
| order by ${sort}
| take ${limit}
| extend reportRows = ReportRows, displayedLimit = ${limit}, truncated = ReportRows > ${limit}`;
}

export function health(): string {
  return `PricedUsage
| summarize observedRequests = count(), pricedRequests = countif(pricingStatus == "priced"),
    partialRequests = countif(pricingStatus == "partial"), unpricedRequests = countif(pricingStatus == "unpriced"),
    unattributedRequests = countif(not(attributionKnown)),
    latestRequest = max(timestamp), latestIngested = max(ingestedAt),
    requestToIngestSeconds = max(datetime_diff("second", ingestedAt, timestamp))
| extend reportState = case(not(RangeValid), "invalid_range", RetentionTruncated, "retention_truncated",
    observedRequests == 0, "no_data_not_zero", unpricedRequests > 0 or partialRequests > 0 or unattributedRequests > 0,
    "incomplete", "observed_token_usage_complete"),
    noBackendCallRequests = tolong(NoUsage.refused), zeroTokenRequests = tolong(NoUsage.zeroTokens),
    noUsageRequests = tolong(NoUsage.refused) + tolong(NoUsage.zeroTokens), retentionTruncated = RetentionTruncated,
    periodStart = FromTime, periodEnd = ToTime, asOfUtc = ReportNow,
    latestRequestAgeSeconds = datetime_diff("second", ReportNow, latestRequest),
    rateCardVersion = RateCardVersion, rateSourceDates = tostring(RateCardSourceDates)`;
}
