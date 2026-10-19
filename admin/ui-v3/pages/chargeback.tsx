import { useEffect, useMemo, useState } from "react";
import { api, qs, useQuery } from "../lib/api.ts";
import { compact, day, download, human, int, pct, toCsv, usd, when } from "../lib/format.ts";
import { href } from "../lib/router.ts";
import { Button, CapabilityNotice, DataTable, ErrorNote, Field, Loading, PageHeader, Segmented, StatePill, Tabs, useToast } from "../components/ui.tsx";
import type { Column } from "../components/ui.tsx";
import { BurnDown, HBars, SplitBar, StackedColumns } from "../components/charts.tsx";
import { ChartPanel, FAMILIES, TOKEN_CATEGORIES, bucketLabel, trendBuckets } from "../components/panels.tsx";
import { PagerLite } from "./project-detail.tsx";

const ok = (cap: any) => cap && (cap.state === "available" || cap.state === "partial");
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
interface Filters { period: string; from: string; to: string; project: string; group: string; developer: string; model: string; backend: string; family: string; interval: string }

const money = (k: string, label = "Known cost"): Column<any> => ({ key: k, label, align: "end", render: (r) => usd(r[k]) });
const common: Column<any>[] = [
  { key: "requests", label: "Requests", align: "end", render: (r) => int(r.requests) },
  { key: "tokensSpent", label: "Tokens", align: "end", render: (r) => r.tokensSpent === null ? <span title="Some token counts are unknown">—</span> : compact(r.tokensSpent) },
  money("knownListUsd"),
  { key: "listUsd", label: "Complete cost", align: "end", render: (r) => r.listUsd === null ? <span className="muted" title="Blank is not zero: some usage is unpriced or unattributed">—</span> : usd(r.listUsd) },
  { key: "unpricedRequests", label: "Unpriced", align: "end", render: (r) => int(r.unpricedRequests) },
  { key: "completeness", label: "Coverage", render: (r) => <StatePill state={r.completeness} /> },
];
const VIEWS: Record<string, { label: string; columns: Column<any>[] }> = {
  groups: { label: "Groups", columns: [{ key: "groupId", label: "Entra group", render: (r) => <><span>{(r.groupNameSnapshots ?? [])[0] ?? "(unknown name)"}</span><code className="block muted">{r.groupId}</code></> },
    { key: "groupProjects", label: "Projects", render: (r) => (r.groupProjects ?? []).join(", ") }, ...common] },
  developers: { label: "Developers", columns: [{ key: "person", label: "Entra Object ID", render: (r) => <code>{r.person}</code> }, ...common] },
  models: { label: "Models", columns: [{ key: "model", label: "Model", render: (r) => <code>{r.model}</code> }, ...common] },
  families: { label: "Families", columns: [{ key: "modelFamily", label: "Family", render: (r) => <span className="cap">{r.modelFamily}</span> }, ...common] },
  projects: { label: "Projects", columns: [{ key: "projectLabel", label: "Project", render: (r) => <a href={href(`/projects/${encodeURIComponent(r.projectLabel)}`)}>{r.projectLabel}</a> }, ...common] },
  unpriced: { label: "Unpriced", columns: [
    { key: "timestamp", label: "When", render: (r) => when(r.timestamp) }, { key: "projectLabel", label: "Project" }, { key: "model", label: "Model", render: (r) => <code>{r.model}</code> },
    { key: "pricingReason", label: "Reason", render: (r) => <StatePill state="partial" label={human(r.pricingReason)} /> },
    { key: "inputTokens", label: "Input", align: "end", render: (r) => int(r.inputTokens) }, { key: "outputTokens", label: "Output", align: "end", render: (r) => int(r.outputTokens) },
    { key: "knownListUsd", label: "Cost", align: "end", render: () => <span className="muted" title="Unpriced: blank, not zero">—</span> }] },
  diagnostics: { label: "Diagnostics", columns: [
    { key: "timestamp", label: "When", render: (r) => when(r.timestamp) }, { key: "projectId", label: "Project" }, { key: "model", label: "Model", render: (r) => <code>{r.model}</code> },
    { key: "usageSource", label: "Usage source" }, { key: "requestFailed", label: "Failed", render: (r) => r.requestFailed ? <StatePill state="failed" label="failed" /> : "no" },
    { key: "attributionKnown", label: "Attributed", render: (r) => r.attributionKnown ? "yes" : <StatePill state="partial" label="no" /> },
    { key: "gatewayRequestId", label: "Gateway request", render: (r) => <code>{String(r.gatewayRequestId).slice(0, 18)}</code> }] },
};

const toLocalInput = (iso: string) => iso ? iso.slice(0, 16) : "";
const fromLocalInput = (v: string) => v ? `${v}:00Z` : "";

export function Chargeback({ query }: { query: URLSearchParams }) {
  const toast = useToast();
  const now = new Date();
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
  const [f, setF] = useState<Filters>({
    period: query.get("period") ?? "month", from: monthStart, to: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1)).toISOString(),
    project: query.get("project") ?? "", group: "", developer: "", model: "", backend: "", family: "", interval: "day",
  });
  const [draftText, setDraftText] = useState({ group: "", developer: "" });
  const [view, setView] = useState("groups");
  const [top, setTop] = useState<"groups" | "projects">("groups");
  const [offset, setOffset] = useState(0);
  const filterQs = (extra: Record<string, string | number> = {}) => qs({
    period: f.period, from: f.period === "custom" ? f.from : null, to: f.period === "custom" ? f.to : null,
    project: f.project, group: f.group, developer: f.developer, model: f.model, backend: f.backend, family: f.family, ...extra,
  });
  useEffect(() => setOffset(0), [JSON.stringify(f), view]);
  const totals = useQuery(`/api/v3/chargeback/totals${filterQs()}`);
  const coverage = useQuery(`/api/v3/chargeback/coverage${filterQs()}`);
  const trend = useQuery(`/api/v3/chargeback/trend${filterQs({ interval: f.interval })}`);
  const topQ = useQuery(`/api/v3/chargeback/${top}${filterQs({ limit: 10 })}`);
  const table = useQuery(`/api/v3/chargeback/${view}${filterQs({ limit: 50, offset })}`);
  const budgets = useQuery(`/api/v2/budgets${qs({ projectId: f.project, limit: 500 })}`);
  const projects = useQuery("/api/v2/projects?limit=100");
  const catalog = useQuery("/api/v2/catalog");
  const inventory = useQuery("/api/v2/inventory");
  const [exporting, setExporting] = useState(false);

  const t = ok(totals.data) ? totals.data.data.rows[0] ?? null : null;
  const cov = ok(coverage.data) ? coverage.data.data.rows[0] ?? null : null;
  const meta = ok(totals.data) ? totals.data.data : null;
  const buckets = ok(trend.data) ? trendBuckets(trend.data.data.rows) : [];
  const models: string[] = catalog.data?.catalog?.models?.map((m: any) => m.model) ?? [];
  const backends: string[] = [...new Set([...(inventory.data?.data?.backends ?? []).map((b: any) => b.backendId), ...((projects.data?.projects ?? []).map((p: any) => p.backendId))])].sort() as string[];
  const reload = () => [totals, coverage, trend, topQ, table, budgets].forEach((q) => q.reload());
  const capFail = totals.data && !ok(totals.data) ? totals.data : null;

  // Burn-down: cumulative daily known cost against the summed monthly group budgets in scope.
  const burn = useMemo(() => {
    if (f.period === "custom" || !ok(trend.data) || f.interval !== "day") return null;
    const start = new Date(trend.data.data.period.from);
    const end = new Date(trend.data.data.period.to);
    const days = Math.round((end.getTime() - start.getTime()) / 86_400_000);
    const daily = new Map<number, number>();
    for (const r of trend.data.data.rows) {
      const d = Math.floor((Date.parse(r.bucket) - start.getTime()) / 86_400_000) + 1;
      daily.set(d, (daily.get(d) ?? 0) + Number(r.knownListUsd ?? 0));
    }
    const elapsed = f.period === "previous" ? days : Math.min(days, Math.floor((Date.now() - start.getTime()) / 86_400_000) + 1);
    let cum = 0;
    const points = Array.from({ length: elapsed }, (_, i) => { cum += daily.get(i + 1) ?? 0; return { day: i + 1, cumulative: cum }; });
    const groups = ok(budgets.data) ? budgets.data.data.groups : [];
    const capped = groups.filter((g: any) => g.budgetUsd !== null);
    const budget = capped.length ? capped.reduce((s: number, g: any) => s + Number(g.budgetUsd), 0) : null;
    return { points, budget, days };
  }, [trend.data, budgets.data, f.period, f.interval]);

  const exportRows = async () => {
    setExporting(true);
    try {
      const r = await api(`/api/v3/chargeback/${view}${filterQs({ limit: 500, offset: 0 })}`);
      if (!ok(r.data)) throw new Error(`Export unavailable: ${r.data.state}`);
      const d = r.data.data;
      download(`ccof-chargeback-${view}-${d.period.from.slice(0, 10)}.csv`, toCsv(d.columns, d.rows, {
        view, periodStart: d.period.from, periodEnd: d.period.to, rateCardVersion: d.rateCardVersion, basis: d.basis,
        rows: d.rows.length, matched: d.page?.matched ?? d.rows.length, truncated: d.truncated, observedAt: d.observedAt,
      }));
      toast(d.truncated ? `Exported ${d.rows.length} rows (truncated: more rows exist).` : `Exported ${d.rows.length} rows.`);
    } catch (e) { toast(e instanceof Error ? e.message : "Export failed", "danger"); } finally { setExporting(false); }
  };

  return (
    <div className="page">
      <PageHeader title="Chargeback" subtitle="The workbook's figures, computed on the server from the same ledger, pricing and rate card." observedAt={totals.observedAt} onRefresh={reload} busy={totals.loading} />
      <div className="filter-bar filter-bar-sticky" role="search" aria-label="Chargeback filters">
        <Field label="Period">{(id) => (
          <select id={id} className="input" value={f.period} onChange={(e) => setF({ ...f, period: e.target.value })}>
            <option value="month">This month</option><option value="previous">Previous month</option><option value="custom">Custom (UTC)</option>
          </select>
        )}</Field>
        {f.period === "custom" && <>
          <Field label="From (UTC)">{(id) => <input id={id} className="input" type="datetime-local" value={toLocalInput(f.from)} onChange={(e) => setF({ ...f, from: fromLocalInput(e.target.value) })} />}</Field>
          <Field label="To (UTC, excluded)">{(id) => <input id={id} className="input" type="datetime-local" value={toLocalInput(f.to)} onChange={(e) => setF({ ...f, to: fromLocalInput(e.target.value) })} />}</Field>
        </>}
        <Field label="Project">{(id) => (
          <><input id={id} className="input" list={`${id}-l`} value={f.project} placeholder="All projects" onChange={(e) => setF({ ...f, project: e.target.value.trim() })} autoComplete="off" spellCheck={false} />
            <datalist id={`${id}-l`}>{(projects.data?.projects ?? []).map((p: any) => <option key={p.projectId} value={p.projectId}>{p.displayName}</option>)}</datalist></>
        )}</Field>
        <Field label="Foundry backend">{(id) => (
          <select id={id} className="input" value={f.backend} onChange={(e) => setF({ ...f, backend: e.target.value })}>
            <option value="">All backends</option>{backends.map((b) => <option key={b}>{b}</option>)}
          </select>
        )}</Field>
        <Field label="Model family">{(id) => (
          <select id={id} className="input" value={f.family} onChange={(e) => setF({ ...f, family: e.target.value })}>
            <option value="">All families</option>{FAMILIES.map((x) => <option key={x.key} value={x.key}>{x.label}</option>)}
          </select>
        )}</Field>
        <Field label="Model">{(id) => (
          <select id={id} className="input" value={f.model} onChange={(e) => setF({ ...f, model: e.target.value })}>
            <option value="">All models</option>{models.map((m) => <option key={m}>{m}</option>)}
          </select>
        )}</Field>
        <Field label="Entra group" error={draftText.group && !GUID.test(draftText.group) ? "Object ID (GUID)" : null}>{(id, d) => (
          <input id={id} aria-describedby={d} className="input mono" placeholder="Object ID" value={draftText.group}
            onChange={(e) => { const v = e.target.value.trim(); setDraftText({ ...draftText, group: v }); if (!v || GUID.test(v)) setF({ ...f, group: v.toLowerCase() }); }} />
        )}</Field>
        <Field label="Developer" error={draftText.developer && !GUID.test(draftText.developer) ? "Object ID (GUID)" : null}>{(id, d) => (
          <input id={id} aria-describedby={d} className="input mono" placeholder="Object ID" value={draftText.developer}
            onChange={(e) => { const v = e.target.value.trim(); setDraftText({ ...draftText, developer: v }); if (!v || GUID.test(v)) setF({ ...f, developer: v.toLowerCase() }); }} />
        )}</Field>
      </div>

      {capFail ? <CapabilityNotice cap={capFail} what="Chargeback" /> : totals.error ? <ErrorNote error={totals.error} retry={reload} /> : (
        <>
          <section className="summary-strip" aria-label="Totals" aria-busy={totals.loading}>
            {totals.loading && !t ? <Loading rows={2} /> : <dl className="stats">
              <div className="stat"><dt>Known list cost</dt><dd><span className="stat-value" data-testid="known-cost">{usd(t?.knownListUsd)}</span><span className="stat-sub">{t?.knownListCcu ? `${int(t.knownListCcu)} CCU` : ""}</span></dd></div>
              <div className="stat"><dt>Complete cost</dt><dd><span className="stat-value">{t?.listUsd === null || !t ? "—" : usd(t.listUsd)}</span><span className="stat-sub">{t && t.listUsd === null ? "blank: not all usage priced" : ""}</span></dd></div>
              <div className="stat"><dt>Requests</dt><dd><span className="stat-value">{int(t?.requests)}</span><span className="stat-sub">{t ? `${int(t.unpricedRequests)} unpriced · ${int(t.unattributedRequests)} unattributed` : ""}</span></dd></div>
              <div className="stat"><dt>Tokens</dt><dd><span className="stat-value">{t?.tokensSpent === null ? "—" : compact(t?.tokensSpent)}</span><span className="stat-sub">{t?.observedCacheHitRequestPercent != null ? `cache hits on ${pct(t.observedCacheHitRequestPercent, 0)} of requests` : ""}</span></dd></div>
              <div className="stat"><dt>Coverage</dt><dd><span className="stat-value">{cov ? <StatePill state={cov.reportState} /> : "—"}</span><span className="stat-sub">{cov?.latestRequest ? `latest request ${when(cov.latestRequest)}` : ""}</span></dd></div>
            </dl>}
            {meta && <p className="provenance">
              {day(meta.period.from)} – {day(new Date(Date.parse(meta.period.to) - 1).toISOString())} UTC · rate card <strong>{meta.rateCardVersion}</strong> ({human(meta.rateCardSource)}) · read {when(meta.observedAt)}{meta.cached ? " (cached)" : ""} · <strong>List price, not an invoice.</strong>
            </p>}
          </section>

          <div className="chart-grid">
            <ChartPanel title="Cost over time by model family" caption="Known list cost by period and family"
              description={`Known list cost per ${f.interval}. Hover a bar for its value.`}
              actions={<Segmented label="Interval" value={f.interval} onChange={(v) => setF({ ...f, interval: v })} options={[{ value: "hour", label: "Hour" }, { value: "day", label: "Day" }]} />}
              chart={trend.loading && !trend.data ? <Loading chart /> : !ok(trend.data) ? <CapabilityNotice cap={trend.data ?? { state: "unavailable" }} what="Trend" />
                : buckets.length ? <StackedColumns buckets={buckets} categories={FAMILIES} format={(n) => usd(n, n < 10 ? 2 : 0)} label="Cost over time by model family" tickLabel={bucketLabel(f.interval)} />
                  : <p className="empty-inline">No usage in this period: no data, not zero.</p>}
              rows={ok(trend.data) ? trend.data.data.rows : []} footer={ok(trend.data) && trend.data.data.truncated ? <p className="hint">Series capped at {trend.data.data.seriesCap} points; narrow the range or use daily bins.</p> : null}
              columns={[{ key: "bucket", label: f.interval === "hour" ? "Hour" : "Day", render: (r: any) => bucketLabel(f.interval)(r.bucket) }, { key: "modelFamily", label: "Family" }, ...common]} />
            <ChartPanel title="Cost by token category" caption="Known list cost by token category" description="Input, output and cache categories at their own rates."
              chart={!t ? <Loading rows={2} /> : <SplitBar label="Cost by token category" format={(n) => usd(n)} parts={TOKEN_CATEGORIES.map((c) => ({ key: c.key, label: c.label, value: t[`${c.key}CostUsd`] === null ? null : Number(t[`${c.key}CostUsd`]) }))} />}
              rows={t ? TOKEN_CATEGORIES.map((c) => ({ category: c.label, tokens: t[`${c.key}Tokens`], cost: t[`${c.key}CostUsd`] })) : []}
              footer={t?.knownCacheReadSavingsUsd ? <p className="hint">Cache reads saved {usd(t.knownCacheReadSavingsUsd)} against the uncached input rate.</p> : null}
              columns={[{ key: "category", label: "Category" }, { key: "tokens", label: "Tokens", align: "end", render: (r: any) => int(r.tokens) }, { key: "cost", label: "Known cost", align: "end", render: (r: any) => usd(r.cost) }]} />
            <ChartPanel title={top === "groups" ? "Top access groups" : "Top projects"} caption="Top 10 by known list cost"
              actions={<Segmented label="Rank" value={top} onChange={setTop} options={[{ value: "groups", label: "Groups" }, { value: "projects", label: "Projects" }]} />}
              chart={topQ.loading && !topQ.data ? <Loading rows={5} /> : !ok(topQ.data) ? <CapabilityNotice cap={topQ.data ?? { state: "unavailable" }} what="Ranking" />
                : topQ.data.data.rows.length ? <HBars label="Top by cost" format={(n) => usd(n)} items={topQ.data.data.rows.map((r: any) => ({
                  key: r.groupId ?? r.projectLabel, value: r.knownListUsd === null ? null : Number(r.knownListUsd),
                  label: top === "groups" ? <>{(r.groupNameSnapshots ?? [])[0] ?? "(unknown)"}</> : <a href={href(`/projects/${encodeURIComponent(r.projectLabel)}`)}>{r.projectLabel}</a>,
                  note: r.listUsd === null && r.knownListUsd !== null ? "lower bound" : undefined,
                }))} /> : <p className="empty-inline">No usage in this period.</p>}
              rows={ok(topQ.data) ? topQ.data.data.rows : []} columns={top === "groups" ? VIEWS.groups.columns : VIEWS.projects.columns} />
            <ChartPanel title="Budget burn-down" caption="Cumulative known cost against monthly budgets"
              description={f.project ? `Group budgets of ${f.project}, summed.` : "All capped group budgets, summed. Filter by project for one project."}
              chart={f.period === "custom" ? <p className="empty-inline">Burn-down follows calendar months; choose This month or Previous month.</p>
                : f.interval !== "day" ? <p className="empty-inline">Burn-down uses daily bins; switch the interval to Day.</p>
                  : !burn ? <Loading chart /> : <BurnDown points={burn.points} budget={burn.budget} daysInPeriod={burn.days} format={(n) => usd(n, 0)} label="Budget burn-down" />}
              rows={burn?.points ?? []} columns={[{ key: "day", label: "Day" }, { key: "cumulative", label: "Spent to date", align: "end", render: (r: any) => usd(r.cumulative) },
                { key: "b", label: "Budget", align: "end", render: () => burn?.budget === null ? "No cap" : usd(burn?.budget) }]} />
          </div>

          <section className="panel">
            <div className="panel-head">
              <h2>Breakdown</h2>
              <Button icon="download" onClick={exportRows} busy={exporting}>Export CSV</Button>
            </div>
            <Tabs label="Breakdown" active={view} onChange={setView} tabs={Object.entries(VIEWS).map(([id, v]) => ({ id, label: v.label }))} />
            <div role="tabpanel" id={`panel-${view}`} aria-labelledby={`tab-${view}`} className="tab-panel" aria-busy={table.loading}>
              {table.loading && !table.data ? <Loading rows={6} /> : table.error ? <ErrorNote error={table.error} retry={table.reload} />
                : !ok(table.data) ? <CapabilityNotice cap={table.data} what="This view" /> : (
                  <>
                    <DataTable caption={VIEWS[view].label} rows={table.data.data.rows} columns={VIEWS[view].columns}
                      empty={<p className="empty-inline">{view === "unpriced" ? "Every request in this period was priced and attributed." : view === "diagnostics" ? "No failed, refused or incomplete requests in this period." : "No usage in this period: no data, not zero."}</p>} />
                    {table.data.data.page && <PagerLite page={table.data.data.page} onPage={setOffset} />}
                    {table.data.data.truncated && <p className="hint">More rows exist than this page shows (truncated); use paging or export.</p>}
                  </>
                )}
            </div>
          </section>
        </>
      )}
    </div>
  );
}
