import type { WorkbookAnswers } from "./config.ts";
import type { CompiledCard } from "./rate-card.ts";

export interface WorkbookItem {
  type: number;
  name: string;
  content: Record<string, unknown>;
}

export interface Workbook {
  version: string;
  items: WorkbookItem[];
  fallbackResourceIds: string[];
  "$schema": string;
}

// The portal sends timeContext as ?timespan=; durationMs 0 becomes PT0S and clips every row.
// Queries retain their own UTC periods and the supported retention guards.
export const QUERY_TIME_CONTEXT = { durationMs: 730 * 86_400_000 };

export function layout(answers: WorkbookAnswers, card: CompiledCard, queries: Record<string, string>): Workbook {
  const note = (name: string, json: string): WorkbookItem => ({ type: 1, name, content: { json } });
  const query = (name: string, title: string): WorkbookItem => ({
    type: 3, name,
    content: {
      version: "KqlItem/1.0", query: queries[name], title, size: 0,
      queryType: 0, resourceType: "microsoft.operationalinsights/workspaces",
      crossComponentResources: [answers.workspaceResourceId],
      visualization: "table", timeContext: QUERY_TIME_CONTEXT,
      showExportToExcel: true, exportToExcelOptions: "all",
      gridSettings: { filter: true },
      noDataMessage: "No matching observations. This is not evidence of zero usage or a zero budget. Check the period, project, diagnostics and workspace access.",
      noDataMessageStyle: 3,
    },
  });
  return {
    version: "Notebook/1.0",
    "$schema": "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json",
    fallbackResourceIds: [answers.workspaceResourceId],
    items: [
      note("intro", `# Chargeback · list price
Operational token costs, not an invoice. **100 CCU = USD 1.**
Rate card **${card.version}**, source dates **${card.sourceDates.join(", ")}**; embedded at deployment.
Complete totals stay blank when any usage is partial or unpriced. **Known list CCU/USD is only the known subtotal.**
Person columns contain the **Entra object id**, not a directory name.`),
      {
        type: 9, name: "period", content: {
          version: "KqlParameterItem/1.0", style: "above",
          parameters: [
            {
              id: "period-mode", name: "Period", label: "Period (UTC)", type: 2, isRequired: true,
              value: "month", jsonData: JSON.stringify([
                { value: "month", label: "Current calendar month" },
                { value: "previous", label: "Previous calendar month" },
                { value: "custom", label: "Custom range" },
              ]),
            },
            {
              id: "time-range", name: "TimeRange", label: "Custom range (used only in Custom mode)",
              type: 4, isRequired: true, value: { durationMs: answers.maxQueryDays * 86400000 },
              typeSettings: { allowCustom: true, selectableValues: [{ durationMs: answers.maxQueryDays * 86400000 }] },
            },
            {
              id: "project-filter", name: "Project", label: "Project id (* = all observed projects)",
              type: 1, isRequired: true, value: answers.defaultProjectId,
              description: "Exact, case-sensitive project id. This is a display filter, not an authorization boundary.",
            },
          ],
        },
      },
      note("period-help", `Periods are **[start, end)** in UTC. The custom end is excluded.
Maximum query range: **${answers.maxQueryDays} days**. An invalid range is shown below and reads no usage.
Choose a project before investigating a large fleet. Missing rows can mean delayed or missing telemetry.
\`noUsageRequests\` counts requests refused before any backend call, or with zero measured tokens. They are not priced.
Workspace retention can remove older rows; this workbook does not extend it.`),
      query("health", "Coverage and observed delivery lag"),
      note("usage-help", `## Usage by project, classification and person
Each token category has a count, a known-request count, an unknown-request count and a status.
A measured zero is **known**; a blank count is **unknown**. Rows marked \`truncated\` are not a complete export.
Narrow the project or period before exporting a truncated table.`),
      query("usage", "Usage · project → classification group → person (Entra object id)"),
      query("model-mix", "Model mix · request counts and known list-price cost"),
      query("top-users", `Top ${answers.topUsers} people · ranked by known list CCU (not complete spend)`),
      note("budget-help", `## Budgets and reconciler spend
These are the latest **monthly budget snapshots overlapping the selected range**, not custom-range spend.
The snapshot's own period, rate-card version, completeness, \`computedAt\` and \`validUntil\` are retained.
\`no_cap\` means no group cap; blank or invalid values are not zero. \`expired\` is not current budget evidence.
\`warning\` is a person past the reconciler's soft limit: spend is paced, not blocked (ADR 0035).
\`exhausted\` + \`strict\` is enforcement; \`notify\` is an exhausted-but-not-blocking group.
Event lookback: **${answers.budgetLookbackDays} days**. Reconciler and ingestion lag allow overshoot.`),
      query("budgets", "Budget versus spend · per person and per classification group"),
      note("runs-help", `### Reconciler runs
The latest run for each outcome. \`latestAgeSeconds\` well above the reconciler's timer interval means budget
state is stale. \`maxIngestionDelaySeconds\` is the ledger delay that run saw; enforcement lags spend by that
delay plus the interval, the run time and the gateway's cache. No rows means no run line was received,
not that the reconciler is healthy. Runs are not filtered by project.`),
      query("reconciler-runs", "Reconciler runs · latest run per outcome"),
      note("unpriced-help", `## Usage that cannot be fully priced
Unpriced rows remain here with no complete amount. Partial rows show only known token cost.
Streamed cache categories, unsupported model/geography, absent counts and missing attribution remain visible.
Additional tool/feature charges are outside this five-token-category report.`),
      query("unpriced", "Unpriced, partial or unattributed usage"),
      note("chargeback-help", `## Project chargeback export · list price
Use the grid's **Download to Excel** action. The export includes the selected period, completeness,
rate-card and ledger digests, and the truncation flag. Do not distribute a truncated or incomplete export
as a complete chargeback. Exports contain object ids: restrict access like the workspace.
This is **not** settled Azure billing or the immutable archive in \`docs/CHARGEBACK-RETENTION.md\`.`),
      query("chargeback", "Chargeback · project and selected period"),
      note("limits", `### Limits and failure states
Loading, errors, filtering and export use native Azure Monitor controls. A query error means unavailable,
not zero. Empty results do not prove zero usage. Cache gaps, ingestion delay, ledger retention and
reconciler lag remain visible limitations. No directory lookup, contract discounts, billing settlement,
immutable archive or automatic price refresh is performed. Workbook access is not project-scoped RBAC.

Sources: [Telemetry contract](https://github.com/naveenneog/ccof-bicep/blob/main/docs/TELEMETRY.md),
[chargeback guide](https://github.com/naveenneog/ccof-bicep/blob/main/docs/CHARGEBACK.md),
[Azure Monitor workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview).`),
    ],
  };
}
