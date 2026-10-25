import { useEffect, useState } from "react";
import { qs, useQuery } from "../lib/api.ts";
import { ago, human, int, pct, usd, when } from "../lib/format.ts";
import { href } from "../lib/router.ts";
import { CapabilityNotice, DataTable, ErrorNote, Field, Loading, PageHeader, Section, Segmented, StatePill } from "../components/ui.tsx";
import { BurnDown, Meter } from "../components/charts.tsx";
import { PagerLite } from "./project-detail.tsx";
import { UserIdentity } from "../components/user-identity.tsx";

const ok = (cap: any) => cap && (cap.state === "available" || cap.state === "partial");

export function SnapshotTable({ rows, scope }: { rows: any[]; scope: string }) {
  return (
    <DataTable caption={`${scope} budget snapshots`} rows={rows} rowKey={(r) => `${r.scope}:${r.scopeId}:${r.periodStart}`}
      empty={<p className="empty-inline">No snapshots match. The reconciler writes them on its timer; none means no state yet, not zero spend.</p>}
      columns={[
        { key: "projectId", label: "Project", render: (r) => <a href={href(`/projects/${encodeURIComponent(r.projectId)}/budgets`)}>{r.projectId}</a> },
        { key: "classification", label: "Group" },
        ...(scope !== "group" ? [{ key: "personId", label: "Person", render: (r: any) => r.personId ? <UserIdentity objectId={r.personId} /> : <span className="muted">group</span> }] : []),
        { key: "spentCcu", label: "Spent", align: "end", render: (r) => <span title={`${r.spentCcu ?? "—"} CCU`}>{usd(r.spentUsd)}</span> },
        { key: "budgetCcu", label: "Budget", align: "end", render: (r) => r.budgetCcu === null ? <span className="muted">no cap</span> : <span title={`${r.budgetCcu} CCU`}>{usd(r.budgetUsd)}</span> },
        { key: "usedPercent", label: "Used", render: (r) => <span className="budget-cell"><Meter value={r.usedPercent === null ? null : Number(r.usedPercent)} max={100} label={`${pct(r.usedPercent)} used`} /><span>{pct(r.usedPercent)}</span></span> },
        { key: "budgetState", label: "State", render: (r) => <StatePill state={r.budgetState} /> },
        { key: "mode", label: "Mode", render: (r) => human(r.mode) },
        { key: "completeness", label: "Completeness", render: (r) => <StatePill state={r.completeness} /> },
        { key: "snapshotState", label: "Snapshot", render: (r) => <StatePill state={r.snapshotState} /> },
        { key: "computedAt", label: "Computed", render: (r) => <span title={`valid until ${when(r.validUntil)}`}>{ago(r.computedAt)}</span> },
      ]} />
  );
}

export function Budgets() {
  const [scope, setScope] = useState<"group" | "person">("group");
  const [project, setProject] = useState("");
  const [offset, setOffset] = useState(0);
  useEffect(() => setOffset(0), [scope, project]);
  const summary = useQuery("/api/v3/reconciler/summary?period=month");
  const snaps = useQuery(`/api/v3/reconciler/snapshots${qs({ period: "month", scope, project, limit: 50, offset })}`);
  const groups = useQuery(`/api/v2/budgets${qs({ limit: 100, projectId: project })}`);
  const [selected, setSelected] = useState<string>("");
  const groupRows: any[] = ok(groups.data) ? groups.data.data.groups : [];
  const chosen = groupRows.find((g) => `${g.projectId}:${g.classification}` === selected) ?? groupRows[0];
  const project1 = useQuery(chosen ? `/api/projects/${encodeURIComponent(chosen.projectId)}` : null);
  const groupId = project1.data?.classifications?.[chosen?.classification]?.groupId;
  const trend = useQuery(chosen && groupId ? `/api/v3/chargeback/trend${qs({ period: "month", project: chosen.projectId, group: groupId, interval: "day" })}` : null);
  const reload = () => [summary, snaps, groups, trend].forEach((q) => q.reload());
  const now = new Date();
  const daysInMonth = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 0)).getUTCDate();
  const daily = new Map<number, number>();
  if (ok(trend.data)) for (const r of trend.data.data.rows) daily.set(new Date(r.bucket).getUTCDate(), (daily.get(new Date(r.bucket).getUTCDate()) ?? 0) + Number(r.knownListUsd ?? 0));
  let cum = 0;
  const points = Array.from({ length: now.getUTCDate() }, (_, i) => { cum += daily.get(i + 1) ?? 0; return { day: i + 1, cumulative: cum }; });
  const totals = ok(groups.data) ? groups.data.data.totals : null;
  const sum: any[] = ok(summary.data) ? summary.data.data.rows : [];
  const count = (s: string, st?: string) => sum.filter((r) => r.scope === s && (!st || r.snapshotState === st)).reduce((a, r) => a + Number(r.snapshots), 0);
  const exhausted = (s: string) => sum.filter((r) => r.scope === s).reduce((a, r) => a + Number(r.exhausted), 0);
  // Person budgets past the reconciler's soft limit (ADR 0035): paced, not blocked.
  const warned = sum.filter((r) => r.scope === "person").reduce((a, r) => a + Number(r.warning ?? 0), 0);

  return (
    <div className="page">
      <PageHeader title="Budgets" subtitle="Today's group and person budgets from the reconciler, and each group's burn-down." observedAt={summary.observedAt} onRefresh={reload} busy={summary.loading} />
      {summary.data && !ok(summary.data) ? <CapabilityNotice cap={summary.data} what="Budget snapshots" /> : (
        <dl className="stats stats-band" aria-busy={summary.loading}>
          <div className="stat"><dt>Group budgets</dt><dd><span className="stat-value">{int(count("group"))}</span><span className="stat-sub">{int(exhausted("group"))} exhausted · {int(count("group", "expired"))} expired</span></dd></div>
          <div className="stat"><dt>Person budgets</dt><dd><span className="stat-value">{int(count("person"))}</span><span className="stat-sub">{int(warned)} past soft limit · {int(exhausted("person"))} exhausted · {int(count("person", "expired"))} expired</span></dd></div>
          <div className="stat"><dt>Spent this month</dt><dd><span className="stat-value">{totals ? usd(totals.spentUsd) : "—"}</span><span className="stat-sub">{totals ? `${int(totals.spentCcu)} CCU${totals.lowerBound ? " · lower bound" : ""}` : ""}</span></dd></div>
          <div className="stat"><dt>Of capped budgets</dt><dd><span className="stat-value">{totals ? pct(totals.cappedUsedPercent) : "—"}</span><span className="stat-sub">{totals ? `${usd(totals.cappedBudgetUsd)} capped · ${int(totals.uncappedGroups)} uncapped` : ""}</span></dd></div>
        </dl>
      )}
      <section className="panel">
        <div className="panel-head">
          <div><h2>Burn-down</h2><p className="section-desc">Cumulative known list cost of one access group this month against its group budget.</p></div>
          {groupRows.length > 0 && (
            <Field label="Access group">{(id) => (
              <select id={id} className="input" value={chosen ? `${chosen.projectId}:${chosen.classification}` : ""} onChange={(e) => setSelected(e.target.value)}>
                {groupRows.map((g) => <option key={`${g.projectId}:${g.classification}`} value={`${g.projectId}:${g.classification}`}>{g.projectId} · {g.classification} ({pct(g.usedPercent)})</option>)}
              </select>
            )}</Field>
          )}
        </div>
        {groups.loading && !groups.data ? <Loading chart /> : !chosen ? <p className="empty-inline">No group budgets yet.</p>
          : trend.loading && !trend.data ? <Loading chart /> : trend.data && !ok(trend.data) ? <CapabilityNotice cap={trend.data} what="Chargeback trend" />
            : <BurnDown points={points} budget={chosen.budgetUsd === null ? null : Number(chosen.budgetUsd)} daysInPeriod={daysInMonth} format={(n) => usd(n, 0)} label={`Burn-down for ${chosen.projectId} ${chosen.classification}`} />}
        {chosen && <p className="hint">Reconciler figure: {usd(chosen.spentUsd)} spent{chosen.budgetUsd ? ` of ${usd(chosen.budgetUsd)}` : ""}, computed {ago(chosen.computedAt)}. The line uses chargeback's known list cost, which can run ahead of the reconciler's last run.</p>}
        <details className="data-table"><summary>Data table <span className="muted">({points.length} days)</span></summary>
          <DataTable caption="Burn-down" dense maxHeight rows={points} columns={[{ key: "day", label: "Day" }, { key: "cumulative", label: "Spent to date", align: "end", render: (r) => usd(r.cumulative) }]} />
        </details>
      </section>
      <Section title="Snapshots" description="The reconciler's latest state per budget, this month. Server-side paging, 50 a page."
        actions={<>
          <Segmented label="Scope" value={scope} onChange={setScope} options={[{ value: "group", label: "Groups" }, { value: "person", label: "People" }]} />
          <Field label={<span className="visually-hidden">Project</span>}>{(id) => <input id={id} className="input input-compact" placeholder="Project ID" value={project} onChange={(e) => setProject(e.target.value.trim())} />}</Field>
        </>}>
        {snaps.loading && !snaps.data ? <Loading rows={6} /> : snaps.error ? <ErrorNote error={snaps.error} retry={snaps.reload} />
          : !ok(snaps.data) ? <CapabilityNotice cap={snaps.data} what="Budget snapshots" />
            : <><SnapshotTable rows={snaps.data.data.rows} scope={scope} />{snaps.data.data.page && <PagerLite page={snaps.data.data.page} onPage={setOffset} />}</>}
      </Section>
    </div>
  );
}
