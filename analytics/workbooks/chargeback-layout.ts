import type { WorkbookAnswers } from "./config.ts";
import type { CompiledCard } from "./rate-card.ts";
import { layout } from "./layout.ts";

export function chargebackLayout(answers: WorkbookAnswers, card: CompiledCard, queries: Record<string, string>) {
  const workbook = layout(answers, card, queries);
  const period = workbook.items.find(i => i.name === "period")!;
  const parameters = period.content.parameters as Record<string, unknown>[];
  parameters.push(...[
    ["Group", "Entra group object ID (* = all)"], ["Developer", "Developer object ID (* = all)"], ["Model", "Exact model ID (* = all)"],
  ].map(([name, label]) => ({ id: `chargeback-${name}`, name, label, type: 1, isRequired: true, value: "*" })));
  const table = (name: string, title: string, visualization = "table") => ({
    type: 3, name, content: {
      version: "KqlItem/1.0", query: queries[name], title, size: 0, queryType: 0,
      resourceType: "microsoft.operationalinsights/workspaces", crossComponentResources: [answers.workspaceResourceId],
      visualization, timeContext: { durationMs: 0 }, showExportToExcel: true, exportToExcelOptions: "all",
      gridSettings: { filter: true }, noDataMessage: "No matching observations; not evidence of zero spend. Check filters, access and telemetry.",
      noDataMessageStyle: 3,
    },
  });
  const note = (name: string, json: string) => ({ type: 1, name, content: { json } });
  workbook.items = [
    note("intro", `# Token chargeback · USD
Fixed list-price rate card **${card.version}**, source dates **${card.sourceDates.join(", ")}**.
**Not an Azure invoice, negotiated bill, or dollar-budget enforcement.** No reconciler is required.
Exact Entra group names are directory snapshots alongside authoritative object IDs, never tier labels.
Developer keys are authorized Entra object IDs; no user display names are invented.`),
    period,
    note("coverage-help", `Complete totals stay blank when any counts/prices/attribution are unknown.
Known subtotals are lower bounds, not zero-filled totals. Streaming has no cache usage in deployed
telemetry and remains partial. Fable/Mythos rates and exact Foundry IDs are unverified: usage is unpriced.
Filters are display-only, not authorization. Periods are UTC [start, end); retention may truncate results.`),
    table("health", "Coverage · missing usage and pricing"),
    table("totals", "Selected-period totals · tokens and USD"),
    table("developers", "Per developer · selected-period costs and tokens"),
    table("usage", "Per developer · project / Entra group object ID and exact name"),
    table("groups", "Per Entra group · all projects / exact name snapshots and object ID"),
    table("models", "By model · token categories and costs"),
    table("families", "By model family · prefix-derived, independent of quotas"),
    table("trends", "Daily cost and token trend · model family"),
    note("cache-help", `## Cache read and cache write costs
Input means **uncached input**. Cache reads, 5-minute writes and 1-hour writes are disjoint
categories, priced separately; the creation aggregate is never added again.
\`observedCacheHitRequestPercent\` = requests with known positive reads / requests with known reads.
Unknown read counts are excluded, so this is not a fleet-wide hit rate.
\`knownCacheReadSavingsUsd\` = known reads × (uncached input rate − read rate), a counterfactual
read-only saving, excluding write premiums and unobserved calls. Each category has known/unknown counters.
Download to Excel exports object IDs; restrict exports like workspace access. Truncated grids are not full exports.`),
    note("names-help", `## Attribution limitations
Request-time group IDs/names, when present, win. Older baseline telemetry contains classification
but no group ID: \`current_mapping_historical_unverified\` is a deployment-time Graph mapping,
not proof of historical membership. Never use it as settled historical chargeback.
Names stamped in a request survive later renames/deletions; otherwise the deployed snapshot is labelled,
or the name/ID is explicitly unknown. Group totals stay keyed by stable object ID across renames;
exact names are retained in \`groupNameSnapshots\` (up to 32 values).
No per-request Graph calls or user lookup is performed.`),
    table("unpriced", "Unpriced, partial and unattributed usage · reasons"),
    table("diagnostics", "Failure, duplicate, conflict and missing-usage diagnostics"),
    note("limits", "Native Azure Monitor loading/error/filter/export controls apply. A query error means unavailable, not zero. Additional tool charges and billing settlement are outside this report."),
  ];
  return workbook;
}
