import { readFileSync, writeFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { Decimal } from "decimal.js";
import { isMain } from "./main.ts";

export interface RenderParameters {
  period: "month" | "previous" | "custom";
  project: string;
  from: string | null;
  to: string | null;
  group?: string;
  developer?: string;
  model?: string;
  // Admin console filters on the ledger's request-time backend and the model family (chargeback-queries.ts).
  backend?: string;
  family?: string;
}

const utc = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?Z$/;
const parameterToken = /\{(?:Period|Project|TimeRange|Group|Developer|Model|Backend|Family)[:}]/;
// Person, request and scope identifiers stay in the workspace; verification prints aggregates only.
const counted = ["requests", "pricedRequests", "partialRequests", "unpricedRequests", "unattributedRequests",
  "observedRequests", "noUsageRequests", "knownCostRequests", "runs", "statesWritten"];
const decimals = ["knownListCcu", "listCcu"];
// Exact like the rate-card compiler: KQL decimals carry up to 28 places, beyond decimal.js's default 20 digits.
const Exact = Decimal.clone({ precision: 60 });
const states = ["reportState", "completeness", "budgetState", "snapshotState", "pricingStatus", "pricingReason", "truncated",
  "outcome", "reason"];

const base64 = (value: string) => Buffer.from(value, "utf8").toString("base64");

export function validateRenderParameters(value: RenderParameters): RenderParameters {
  if (!["month", "previous", "custom"].includes(value.period)) throw new Error("period: invalid");
  if (typeof value.project !== "string" || !value.project || /[\u0000-\u001f]/.test(value.project)) throw new Error("project: required");
  for (const key of ["group", "developer", "model", "backend", "family"] as const) {
    if (value[key] !== undefined && (typeof value[key] !== "string" || !value[key] || /[\u0000-\u001f]/.test(value[key]))) {
      throw new Error(`${key}: nonempty_filter_required`);
    }
  }
  const custom = value.period === "custom";
  for (const key of ["from", "to"] as const) {
    if (custom ? !utc.test(value[key] ?? "") : value[key] !== null) throw new Error(`${key}: ${custom ? "utc_instant_required" : "custom_only"}`);
  }
  return value;
}

// The portal substitutes {TimeRange:start}/{TimeRange:end} as KQL datetime literals; the base64 forms are decoded in KQL.
export function renderQuery(query: string, parameters: RenderParameters): string {
  const p = validateRenderParameters(parameters);
  const rendered = query
    .replaceAll("{Period:base64}", base64(p.period))
    .replaceAll("{Project:base64}", base64(p.project))
    .replaceAll("{Group:base64}", base64(p.group ?? "*"))
    .replaceAll("{Developer:base64}", base64(p.developer ?? "*"))
    .replaceAll("{Model:base64}", base64(p.model ?? "*"))
    .replaceAll("{Backend:base64}", base64(p.backend ?? "*"))
    .replaceAll("{Family:base64}", base64(p.family ?? "*"))
    .replaceAll("{TimeRange:start}", `datetime(${p.from ?? "null"})`)
    .replaceAll("{TimeRange:end}", `datetime(${p.to ?? "null"})`);
  if (parameterToken.test(rendered)) throw new Error("render: unresolved_parameter");
  return rendered;
}

interface Item { type: number; name: string; content: { query?: string } }

export function workbookQueries(workbook: { items: Item[] }, parameters: RenderParameters): Record<string, string> {
  return Object.fromEntries(workbook.items.filter(item => item.type === 3)
    .map(item => [item.name, renderQuery(String(item.content.query ?? ""), parameters)]));
}

export function sameWorkbook(expected: unknown, deployedSerializedData: unknown): boolean {
  if (typeof deployedSerializedData !== "string") return false;
  try {
    return isDeepStrictEqual(expected, JSON.parse(deployedSerializedData));
  } catch {
    return false;
  }
}

export function summarize(response: unknown): Record<string, unknown> {
  const result = response as { error?: unknown; tables?: Array<{ name: string; columns: Array<{ name: string }>; rows: unknown[][] }> };
  const table = result?.tables?.find(t => t.name === "PrimaryResult");
  if (!table || result.error) throw new Error("query: response_error");
  const column = (name: string) => table.columns.findIndex(c => c.name === name);
  const summary: Record<string, unknown> = { rows: table.rows.length };
  for (const name of counted) {
    const i = column(name);
    if (i >= 0) summary[name] = table.rows.reduce((sum, row) => sum + (typeof row[i] === "number" ? row[i] as number : 0), 0);
  }
  for (const name of decimals) {
    const i = column(name);
    if (i >= 0) {
      const values = table.rows.map(row => row[i]).filter(v => v !== null && v !== "");
      summary[`${name}NonNullRows`] = values.length;
      // No amount at all is missing, not zero.
      summary[`${name}Sum`] = values.length === 0 ? null
        : values.reduce((sum: Decimal, v) => sum.plus(new Exact(String(v))), new Exact(0)).toFixed();
    }
  }
  for (const name of states) {
    const i = column(name);
    if (i >= 0) summary[name] = [...new Set(table.rows.map(row => String(row[i])))].sort();
  }
  return summary;
}

// "-" reads standard input, so deployed content and query results need not be written to disk.
const input = (file: string) => readFileSync(file === "-" ? 0 : file, "utf8");

if (isMain(import.meta.url)) {
  try {
    const [operation, ...args] = process.argv.slice(2);
    if (operation === "--render" && args.length === 6) {
      const [workbookPath, outputPath, period, projectBase64, from, to] = args;
      const parameters = { period, project: Buffer.from(projectBase64, "base64").toString("utf8"),
        from: from === "-" ? null : from, to: to === "-" ? null : to } as RenderParameters;
      const queries = workbookQueries(JSON.parse(input(workbookPath)), parameters);
      writeFileSync(outputPath, JSON.stringify(queries));
      console.log(JSON.stringify({ outcome: "rendered", queries: Object.keys(queries) }));
    } else if (operation === "--compare" && args.length === 2) {
      const match = sameWorkbook(JSON.parse(input(args[0])), input(args[1]));
      console.log(JSON.stringify({ outcome: match ? "content_matches" : "content_differs" }));
      if (!match) process.exitCode = 1;
    } else if (operation === "--summarize" && args.length === 1) {
      console.log(JSON.stringify({ outcome: "summarized", summary: summarize(JSON.parse(input(args[0]))) }));
    } else throw new Error("arguments_required");
  } catch (error) {
    console.error(JSON.stringify({ outcome: "refused", reason: error instanceof Error ? error.message : "render_failed" }));
    process.exitCode = 1;
  }
}
