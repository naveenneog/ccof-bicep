import { useState } from "react";
import { useQuery } from "../lib/api.ts";
import { ago, compact, human, int, pct, usd, when } from "../lib/format.ts";
import { href } from "../lib/router.ts";
import { CapabilityNotice, DataTable, ErrorNote, Loading, PageHeader, StatePill } from "../components/ui.tsx";
import { CostBreakdown } from "../components/cost-breakdown.tsx";
import { StackedColumns } from "../components/charts.tsx";
import { ChartPanel, FAMILIES, bucketLabel, trendBuckets } from "../components/panels.tsx";

const ok = (cap: any) => cap && (cap.state === "available" || cap.state === "partial");

export function Overview() {
  const [refresh, setRefresh] = useState(0);
  const trend = useQuery("/api/v3/chargeback/trend?period=month&interval=day");
  const totals = useQuery("/api/v3/chargeback/totals?period=month");
  const coverage = useQuery("/api/v3/chargeback/coverage?period=month");
  const budgets = useQuery("/api/v2/budgets?minUsedPercent=80&limit=8");
  const runs = useQuery("/api/v3/reconciler/runs");
  const health = useQuery("/api/v2/health");
  const audit = useQuery("/api/v3/audit?limit=6");
  const reload = () => { [trend, totals, coverage, budgets, runs, health, audit].forEach((q) => q.reload()); setRefresh((n) => n + 1); };
  const loading = [trend, totals, coverage].some((q) => q.loading);

  const t = ok(totals.data) ? totals.data.data.rows[0] : null;
  const cov = ok(coverage.data) ? coverage.data.data.rows[0] : null;
  const buckets = ok(trend.data) ? trendBuckets(trend.data.data.rows) : [];
  const written = ok(runs.data) ? runs.data.data.rows.find((r: any) => r.outcome === "written") : null;
  const confirmed = ok(budgets.data) && budgets.data.data.groups?.length > 0 &&
    cov?.reportState === "observed_token_usage_complete" && written?.freshness === "on_schedule" &&
    ok(health.data) && Array.isArray(health.data.data) && health.data.data.length > 0;
  const attention: { key: string; tone: string; text: React.ReactNode; to: string }[] = [];
  if (ok(budgets.data)) for (const g of budgets.data.data.groups) {
    attention.push({ key: `b-${g.projectId}-${g.classification}`, tone: g.exhausted ? "danger" : "warn", to: `/projects/${g.projectId}/budgets`,
      text: <><strong>{g.projectId} · {g.classification}</strong> at {pct(g.usedPercent)} of its monthly budget{g.exhausted ? " — exhausted" : ""}</> });
  }
  if (cov && cov.reportState !== "observed_token_usage_complete") attention.push({ key: "coverage", tone: "warn", to: "/chargeback", text: <>Telemetry coverage is <strong>{human(cov.reportState)}</strong>: {int(cov.unpricedRequests)} unpriced, {int(cov.unattributedRequests)} unattributed requests</> });
  if (written && written.freshness !== "on_schedule") attention.push({ key: "rec", tone: "danger", to: "/reconciler", text: <>The reconciler's last written run was {ago(written.latestRunAt)} ({human(written.freshness)})</> });
  if (ok(health.data) && Array.isArray(health.data.data)) for (const p of health.data.data.filter((p: any) => p.state !== "endpoint_responding")) {
    attention.push({ key: `h-${p.name}`, tone: "danger", to: "/health", text: <><strong>{p.name}</strong>: {human(p.state)}</> });
  }

  return (
    <div className="page">
      <PageHeader title="Overview" subtitle="This month at list price, what needs attention, and the latest changes." observedAt={totals.observedAt} onRefresh={reload} busy={loading} />
      <CostBreakdown refresh={refresh} />
      <div className="overview-grid">
        <div className="overview-main">
          {trend.loading && !trend.data ? <section className="panel"><Loading chart /></section>
            : trend.error ? <ErrorNote error={trend.error} retry={trend.reload} />
              : !ok(trend.data) ? <CapabilityNotice cap={trend.data} what="Chargeback" />
                : (
                  <ChartPanel title="Month-to-date cost by model family" caption="Daily known list cost by model family"
                    description={<>Known list cost {t ? <strong>{usd(t.knownListUsd)}</strong> : "—"}{t?.listUsd === null ? " (lower bound: some usage is unpriced)" : ""} · rate card {trend.data.data.rateCardVersion} · list price, not an invoice</>}
                    actions={<a className="btn btn-quiet btn-small" href={href("/chargeback")}>Open chargeback</a>}
                    chart={buckets.length ? <StackedColumns buckets={buckets} categories={FAMILIES} format={(n) => usd(n, 0)} label="Month-to-date cost by model family" tickLabel={bucketLabel("day")} />
                      : <p className="empty-inline">No usage recorded this month yet. That is no data, not zero cost.</p>}
                    rows={trend.data.data.rows} columns={[
                      { key: "bucket", label: "Day", render: (r: any) => bucketLabel("day")(r.bucket) },
                      { key: "modelFamily", label: "Family" },
                      { key: "requests", label: "Requests", align: "end", render: (r: any) => int(r.requests) },
                      { key: "knownListUsd", label: "Known cost", align: "end", render: (r: any) => usd(r.knownListUsd) },
                    ]} />
                )}
          <section className="panel">
            <div className="panel-head"><h2>Recent changes</h2><a className="btn btn-quiet btn-small" href={href("/audit")}>All activity</a></div>
            {audit.loading && !audit.data ? <Loading rows={4} /> : audit.error ? <ErrorNote error={audit.error} retry={audit.reload} />
              : !ok(audit.data) ? <CapabilityNotice cap={audit.data} what="Audit" />
                : <DataTable caption="Recent changes" dense rows={audit.data.data.rows} empty={<p className="empty-inline">No changes in the last 31 days.</p>} columns={[
                  { key: "at", label: "When", render: (r: any) => ago(r.at) },
                  { key: "operation", label: "Change", render: (r: any) => human(r.operation) },
                  { key: "projectId", label: "Project", render: (r: any) => r.projectId ? <a href={href(`/projects/${r.projectId}`)}>{r.projectId}</a> : "—" },
                  { key: "outcome", label: "Outcome", render: (r: any) => <StatePill state={r.outcome} /> },
                ]} />}
          </section>
        </div>
        <aside className="overview-side">
          <section className="panel">
            <div className="panel-head"><h2>Needs attention</h2></div>
            {budgets.loading && !budgets.data ? <Loading rows={3} /> : attention.length === 0
              ? <p className="empty-inline">{confirmed ? <><span className="ok-text">Nothing needs attention.</span> The available observations show no concerns.</>
                : "No confirmed alerts from available observations. Some checks have no data or are not configured; overall health is unverified."}</p>
              : <ul className="attention">{attention.map((a) => <li key={a.key} className={`attention-${a.tone}`}><a href={href(a.to)}>{a.text}</a></li>)}</ul>}
            {budgets.data && !ok(budgets.data) && <CapabilityNotice cap={budgets.data} what="Budgets" />}
          </section>
          <section className="panel">
            <div className="panel-head"><h2>Telemetry and reconciler</h2></div>
            <dl className="facts">
              <div><dt>Coverage</dt><dd>{cov ? <StatePill state={cov.reportState} /> : "—"}</dd></div>
              <div><dt>Requests this month</dt><dd>{cov ? int(cov.observedRequests) : "—"}</dd></div>
              <div><dt>Tokens this month</dt><dd>{t ? compact(t.tokensSpent ?? null) : "—"}</dd></div>
              <div><dt>Latest request</dt><dd>{cov ? ago(cov.latestRequest) : "—"}</dd></div>
              <div><dt>Reconciler last wrote</dt><dd>{written ? <>{ago(written.latestRunAt)} <StatePill state={written.freshness} /></> : ok(runs.data) ? "no written run" : "—"}</dd></div>
              <div><dt>Budget states written</dt><dd>{written ? `${int(written.personStates)} person · ${int(written.groupStates)} group` : "—"}</dd></div>
            </dl>
            {runs.data && !ok(runs.data) && <CapabilityNotice cap={runs.data} what="Reconciler" />}
            {coverage.data && !ok(coverage.data) && <p className="hint">Coverage needs the chargeback workspace (see Help).</p>}
            <p className="hint">Read at {cov ? when(coverage.data.data.observedAt) : "—"}.</p>
          </section>
        </aside>
      </div>
    </div>
  );
}
