import type { ReactNode } from "react";
import { DataTable } from "./ui.tsx";
import type { Column } from "./ui.tsx";
import { day, when } from "../lib/format.ts";

export const FAMILIES = [
  { key: "sonnet", label: "Sonnet" }, { key: "haiku", label: "Haiku" }, { key: "opus", label: "Opus" },
  { key: "fable", label: "Fable" }, { key: "mythos", label: "Mythos" }, { key: "unknown", label: "Unknown" },
];
export const TOKEN_CATEGORIES = [
  { key: "input", label: "Input" }, { key: "output", label: "Output" }, { key: "cacheRead", label: "Cache read" },
  { key: "cacheWrite5m", label: "Cache write 5m" }, { key: "cacheWrite1h", label: "Cache write 1h" },
];

// Trend rows (bucket, modelFamily, knownListUsd) to stacked buckets. A bucket's family with unknown cost stays null.
export function trendBuckets(rows: Record<string, any>[]) {
  const map = new Map<string, Record<string, number | null>>();
  for (const r of rows) {
    const key = String(r.bucket ?? r.day);
    const values = map.get(key) ?? {};
    values[String(r.modelFamily)] = r.knownListUsd === null || r.knownListUsd === undefined ? null : Number(r.knownListUsd);
    map.set(key, values);
  }
  return [...map.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([key, values]) => ({ key, values }));
}
export const bucketLabel = (interval: string) => (key: string) => interval === "hour" ? when(key).replace(" UTC", "") : day(key);

// A chart and its data table, always together: the table is the accessible, exact form of the chart.
export function ChartPanel<T extends Record<string, any>>({ title, description, chart, columns, rows, caption, actions, footer }: {
  title: ReactNode; description?: ReactNode; chart: ReactNode; columns: Column<T>[]; rows: T[]; caption: string; actions?: ReactNode; footer?: ReactNode;
}) {
  return (
    <section className="panel chart-panel">
      <div className="panel-head">
        <div><h2>{title}</h2>{description && <p className="section-desc">{description}</p>}</div>
        {actions}
      </div>
      {chart}
      <details className="data-table">
        <summary>Data table <span className="muted">({rows.length} row{rows.length === 1 ? "" : "s"})</span></summary>
        <DataTable columns={columns} rows={rows} caption={caption} dense maxHeight />
      </details>
      {footer}
    </section>
  );
}
