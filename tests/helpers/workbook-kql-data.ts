import { kqlString } from "../../analytics/workbooks/rate-card.ts";
import { workbookAnswers } from "./workbook-fixtures.ts";

export const reportNow = "datetime(2026-10-11T10:10:00Z)";
export const fixturePerson = "44444444-4444-4444-8444-444444444444";

export interface UsageCase {
  id: string;
  model?: string;
  geo?: string;
  at?: string;
  source?: string;
  tokens?: Array<number | null>;
  cost: string;
  status: string;
}

export const usageCases: UsageCase[] = [
  { id: "full", cost: "4.85", status: "priced" },
  { id: "stream", tokens: [10, 2, null, null, null], cost: "4", status: "partial" },
  { id: "measured-zero", tokens: [0, 0, 0, 0, 0], cost: "", status: "no_usage" },
  { id: "zero-io-unknown-cache", tokens: [0, 0, null, null, null], cost: "", status: "no_usage" },
  { id: "zero-io-zero-write", tokens: [0, 0, 0, null, null], cost: "", status: "no_usage" },
  { id: "zero-io-with-cache", tokens: [0, 0, 0, 0, 7], cost: "0.14", status: "priced" },
  { id: "no-backend-call", source: "no-backend-call", tokens: [null, null, null, null, null], cost: "", status: "no_usage" },
  { id: "no-backend-call-with-tokens", source: "no-backend-call", cost: "", status: "no_usage" },
  { id: "unknown-model", model: "not-priced", cost: "", status: "unpriced" },
  { id: "unknown-geo", geo: "unknown", cost: "4.85", status: "partial" },
  { id: "unsupported-geo", geo: "unlisted", cost: "", status: "unpriced" },
  { id: "unknown-input", tokens: [null, 2, 3, 0, 5], cost: "", status: "unpriced" },
  { id: "unknown-output", tokens: [10, null, 3, 0, 5], cost: "", status: "unpriced" },
  { id: "tier-boundary", model: "model-b", tokens: [100, 1, 0, 0, 0], cost: "10.5", status: "priced" },
  { id: "higher-tier", model: "model-b", tokens: [101, 1, 0, 0, 0], cost: "21.2", status: "priced" },
  { id: "unknown-tier", model: "model-b", tokens: [90, 1, 0, 0, null], cost: "9.5", status: "partial" },
  { id: "no-rate-in-force", at: "2026-09-30T12:00:00Z", cost: "", status: "unpriced" },
  { id: "dated-model", model: "model-a-20261001", cost: "4.85", status: "priced" },
  { id: "invalid-dated-model", model: "model-a-20261301", cost: "", status: "unpriced" },
  { id: "unattributed", cost: "4.85", status: "priced" },
  { id: "geo-mismatch", cost: "", status: "unpriced" },
  { id: "flag-unknown", cost: "", status: "unpriced" },
  { id: "boundary-end", at: "2026-10-12T00:00:00Z", cost: "4.85", status: "priced" },
];

// WP-COST's pilot card (tests/fixtures/workbook/pilot-rate-card.json). CCU = tokens x USD per million
// x geography multiplier x 100 / 1,000,000; each amount is derived by hand from the published rates.
export const realCardCases: UsageCase[] = [
  // 1000 x 2 + 500 x 10, per million, x 100.
  { id: "real-sonnet-5", model: "claude-sonnet-5", tokens: [1000, 500, 0, 0, 0], cost: "0.7", status: "priced" },
  // US x 1.1: 1000 x 4.4 + 100 x 22 + 200 x 5.5 + 3000 x 0.22.
  { id: "real-opus-5-5-us", model: "claude-opus-5-5", geo: "us", tokens: [1000, 100, 200, 0, 3000], cost: "0.836", status: "priced" },
  // The live ledger's model string; the dated name matches the claude-haiku-4-5 entry.
  { id: "real-haiku-4-5-dated", model: "claude-haiku-4-5-20251001", tokens: [2000, 1000, 0, 0, 0], cost: "0.7", status: "priced" },
  { id: "real-haiku-4-5-us", model: "claude-haiku-4-5", geo: "us", cost: "", status: "unpriced" },
  // Prompt 90000 + 5000 + 10000 > 100000: 90000 x 0.5 + 1000 x 2.5 + 5000 x 0.625 + 10000 x 0.05.
  { id: "real-haiku-5-5-over", model: "claude-haiku-5-5", tokens: [90000, 1000, 5000, 0, 10000], cost: "5.1125", status: "priced" },
  // Prompt exactly 100000 stays in the first tier: 100000 x 0.1 + 10 x 0.5.
  { id: "real-haiku-5-5-boundary", model: "claude-haiku-5-5", tokens: [100000, 10, 0, 0, 0], cost: "1.0005", status: "priced" },
  // Unknown geography: the smallest multiplier keeps a lower bound, 1000 x 0.1 + 100 x 0.5.
  { id: "real-haiku-5-5-unknown-geo", model: "claude-haiku-5-5", geo: "unknown", tokens: [1000, 100, 0, 0, 0], cost: "0.015", status: "partial" },
  // Streamed: cache categories unknown, known part 1000 x 5 + 200 x 25.
  { id: "real-opus-5-stream", model: "claude-opus-5", tokens: [1000, 200, null, null, null], cost: "1", status: "partial" },
  { id: "real-before-effective", model: "claude-sonnet-5", at: "2026-10-10T23:59:59Z", cost: "", status: "unpriced" },
  { id: "real-empty-model", model: "", tokens: [5, 1, 0, 0, 0], cost: "", status: "unpriced" },
];

export function ledgerRows(name: string, cases: UsageCase[]): string {
  const rows = cases.map(c => [
    kqlString(c.id), kqlString(c.model ?? "model-a"), kqlString(c.geo ?? "global"),
    `datetime(${c.at ?? "2026-10-11T00:00:00Z"})`, kqlString(c.source ?? "log"),
    ...(c.tokens ?? [10, 2, 3, 0, 5]).map(n => n === null ? "long(null)" : String(n)),
  ].join(", ")).join(",\n");
  return `let ${name} = datatable(gatewayRequestId:string, model:string, inference_geo:string,
timestamp:datetime, usageSource:string,
inputTokens:long, outputTokens:long, cacheWrite5mTokens:long, cacheWrite1hTokens:long, cacheReadTokens:long)[
${rows}]
| extend gatewayResourceId = ${kqlString(workbookAnswers().gatewayResourceId)}, ingestedAt = timestamp + 2s,
    personId = iff(gatewayRequestId == "unattributed", "", "${fixturePerson}"),
    projectId = iff(gatewayRequestId == "unattributed", "", "fixture-project"), classification = "STD",
    attributionKnown = gatewayRequestId != "unattributed", inferenceGeoKnown = inference_geo != "unknown",
    geoMismatch = gatewayRequestId == "geo-mismatch",
    inputTokensKnown = isnotnull(inputTokens) and gatewayRequestId != "flag-unknown", outputTokensKnown = isnotnull(outputTokens),
    cacheWrite5mTokensKnown = isnotnull(cacheWrite5mTokens), cacheWrite1hTokensKnown = isnotnull(cacheWrite1hTokens),
    cacheReadTokensKnown = isnotnull(cacheReadTokens);
`;
}

export function usageData(): string {
  return ledgerRows("FixtureUsage", usageCases) + `let CcofUsageLedger = (fromTime:datetime, toTime:datetime, resourceId:string) {
    FixtureUsage | where timestamp >= fromTime and timestamp < toTime | where gatewayResourceId == resourceId
};
`;
}

export function realCardData(): string {
  return ledgerRows("RealCardUsage", realCardCases);
}

// One ccof.reconciler.budget.v1 line as src/reconciler/telemetry.ts writes it, for the fixture person by default.
function budgetEvent(changes: Record<string, unknown>) {
  return {
    schema: "ccof.reconciler.budget.v1", runId: "77777777-7777-4777-8777-777777777777",
    scope: "person", scopeId: `${fixturePerson}:fixture-project`, personId: fixturePerson,
    projectId: "fixture-project", classification: "STD", period: "2026-10",
    periodStart: "2026-10-01T00:00:00.000Z", periodEnd: "2026-11-01T00:00:00.000Z",
    spentCcu: "10", budgetCcu: "100", exhausted: false, mode: "strict", completeness: "complete",
    pricedRequests: 1, partialRequests: 0, unpricedRequests: 0, activeMemberCount: null,
    rateCardVersion: "fixture-2026-10", computedAt: "2026-10-11T10:00:00Z", validUntil: "2026-10-11T10:15:00Z",
    ...changes,
  };
}

export function budgetData(): string {
  const answers = workbookAnswers();
  const event = budgetEvent;
  const second = "55555555-5555-4555-8555-555555555555";
  const third = "66666666-6666-4666-8666-666666666666";
  const zero = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const missing = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const events: Array<[string, string, Record<string, unknown>]> = [
    ["2026-10-11T10:08:00Z", answers.reconcilerResourceId, event({})],
    ["2026-10-11T10:06:00Z", answers.reconcilerResourceId, event({ spentCcu: "20.1234567890123456789", computedAt: "2026-10-11T10:05:00Z" })],
    ["2026-10-11T10:09:00Z", answers.reconcilerResourceId + "-other", event({ spentCcu: "999", exhausted: true, computedAt: "2026-10-11T10:09:00Z" })],
    ["2026-10-11T10:07:00Z", answers.reconcilerResourceId, event({
      period: "2026-09", periodStart: "2026-09-01T00:00:00Z", periodEnd: "2026-10-01T00:00:00Z", computedAt: "2026-10-11T10:07:00Z",
    })],
    ["2026-10-11T10:06:00Z", answers.reconcilerResourceId, event({
      scope: "group", scopeId: "fixture-project:STD", personId: null, spentCcu: "200",
      exhausted: true, mode: "notify", completeness: "partial", partialRequests: 1, unpricedRequests: 1, activeMemberCount: 2,
    })],
    ["2026-10-11T10:06:00Z", answers.reconcilerResourceId, event({
      scope: "group", scopeId: "fixture-project:PRM", classification: "PRM", personId: null,
      spentCcu: "2", budgetCcu: null, mode: "notify", activeMemberCount: 1,
    })],
    ["2026-10-11T10:02:00Z", answers.reconcilerResourceId, event({
      scopeId: `${second}:fixture-project`, personId: second, validUntil: "2026-10-11T10:04:00Z", spentCcu: "5",
    })],
    ["2026-10-11T10:02:00Z", answers.reconcilerResourceId, event({
      scopeId: `${third}:fixture-project`, personId: third, spentCcu: "not-a-decimal",
    })],
    // A zero budget is valid and exhausted (WP-ONB allows 0; WP-REC writes exhausted = spent >= budget).
    ["2026-10-11T10:03:00Z", answers.reconcilerResourceId, event({
      scopeId: `${zero}:fixture-project`, personId: zero, spentCcu: "0", budgetCcu: "0", exhausted: true,
    })],
    // A line without its request counts must stay invalid, not fall through as current.
    ["2026-10-11T10:03:00Z", answers.reconcilerResourceId, event({
      scopeId: `${missing}:fixture-project`, personId: missing, pricedRequests: undefined,
    })],
  ];
  // ccof.reconciler.run.v1 lines (WP-REC src/reconciler/telemetry.ts): codes, counts and times only.
  const run = (changes: Record<string, unknown>) => ({
    schema: "ccof.reconciler.run.v1", runId: "88888888-8888-4888-8888-888888888888", outcome: "written", reason: null,
    statesWritten: 3, personStates: 2, groupStates: 1, completeness: "complete", maxIngestionDelaySeconds: 95,
    unattributedRequests: 0, unattributedCcu: "0", unpricedRequests: 0,
    computedAt: "2026-10-11T10:04:00Z", validUntil: "2026-10-11T10:19:00Z", ...changes,
  });
  const lines: Array<[string, string, string]> = [
    ...events.map(([at, resource, payload]) => [at, resource, JSON.stringify(payload)] as [string, string, string]),
    ["2026-10-11T10:04:00Z", answers.reconcilerResourceId, JSON.stringify(run({}))],
    ["2026-10-11T10:08:00Z", answers.reconcilerResourceId, JSON.stringify(run({
      runId: "99999999-9999-4999-8999-999999999999", statesWritten: 4, maxIngestionDelaySeconds: 140,
      unattributedRequests: 2, unattributedCcu: "0.25", computedAt: "2026-10-11T10:08:00Z", validUntil: "2026-10-11T10:23:00Z",
    }))],
    ["2026-10-11T10:06:00Z", answers.reconcilerResourceId, JSON.stringify(run({ outcome: "skipped_lease_held", reason: "lease_held", statesWritten: 0 }))],
    ["2026-10-11T10:05:00Z", answers.reconcilerResourceId, JSON.stringify(run({ outcome: "failed", reason: "ledger_query_failed", statesWritten: 0 }))],
    ["2026-10-11T10:09:00Z", answers.reconcilerResourceId + "-other", JSON.stringify(run({ statesWritten: 99 }))],
    ["2026-10-11T10:03:00Z", answers.reconcilerResourceId, "Executing 'Functions.reconcile' (not a JSON line)"],
    // Mentions of a schema name are not events: the exact schema check must still reject them.
    ["2026-10-11T10:07:30Z", answers.reconcilerResourceId, "Could not write a ccof.reconciler.run.v1 line"],
    // A later schema version that mentions v1 and has valid fields must not be read as a v1 budget line.
    ["2026-10-11T10:07:30Z", answers.reconcilerResourceId, JSON.stringify(event({
      schema: "ccof.reconciler.budget.v2", supersedes: "ccof.reconciler.budget.v1",
      scopeId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc:fixture-project", personId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    }))],
  ];
  return `let FunctionAppLogs = datatable(TimeGenerated:datetime, _ResourceId:string, Message:string)[
${lines.map(([at, resource, message]) => `datetime(${at}), ${kqlString(resource)}, ${kqlString(message)}`).join(",\n")}
];\n`;
}

// config/rate-card.json's version is the date-shaped "2026-10-11", which parse_json reads as a datetime: every
// live snapshot then showed rateCardMismatch although both sides used 2026-10-11 (WP-E2E G5, 2026-10-12).
export const versionPersons = {
  sameDate: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
  olderDate: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
  named: "ffffffff-ffff-4fff-8fff-ffffffffffff",
} as const;

export function rateCardVersionData(): string {
  const answers = workbookAnswers();
  const line = (personId: string, rateCardVersion: string) =>
    JSON.stringify(budgetEvent({ scopeId: `${personId}:fixture-project`, personId, rateCardVersion }));
  const lines = [
    line(versionPersons.sameDate, "2026-10-11"),
    line(versionPersons.olderDate, "2026-10-01"),
    line(versionPersons.named, "fixture-2026-10"),
  ];
  return `let FunctionAppLogs = datatable(TimeGenerated:datetime, _ResourceId:string, Message:string)[
${lines.map(message => `datetime(2026-10-11T10:08:00Z), ${kqlString(answers.reconcilerResourceId)}, ${kqlString(message)}`).join(",\n")}
];\n`;
}
