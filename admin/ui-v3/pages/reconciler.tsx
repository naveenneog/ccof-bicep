import { useEffect, useState } from "react";
import { qs, useQuery } from "../lib/api.ts";
import { ago, human, int, usd, when } from "../lib/format.ts";
import { CapabilityNotice, DataTable, ErrorNote, Field, Loading, PageHeader, Section, StatePill } from "../components/ui.tsx";
import { PagerLite } from "./project-detail.tsx";
import { SnapshotTable } from "./budgets.tsx";

const ok = (cap: any) => cap && (cap.state === "available" || cap.state === "partial");
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function Reconciler() {
  const runs = useQuery("/api/v3/reconciler/runs");
  const [f, setF] = useState({ period: "month", scope: "", project: "", classification: "", person: "", state: "", budgetState: "" });
  const [person, setPerson] = useState("");
  const [offset, setOffset] = useState(0);
  useEffect(() => setOffset(0), [JSON.stringify(f)]);
  const snaps = useQuery(`/api/v3/reconciler/snapshots${qs({ ...f, limit: 50, offset })}`);
  const written = ok(runs.data) ? runs.data.data.rows.find((r: any) => r.outcome === "written") : null;
  const interval = ok(runs.data) ? runs.data.data.intervalMinutes : null;
  const reload = () => { runs.reload(); snaps.reload(); };
  return (
    <div className="page">
      <PageHeader title="Reconciler" subtitle="Budget reconciler runs and the person and group budget state they wrote." observedAt={runs.observedAt} onRefresh={reload} busy={runs.loading} />
      {runs.loading && !runs.data ? <Loading rows={4} /> : runs.error ? <ErrorNote error={runs.error} retry={runs.reload} /> : !ok(runs.data) ? <CapabilityNotice cap={runs.data} what="Reconciler logs" /> : (
        <>
          <dl className="stats stats-band">
            <div className={`stat${written && written.freshness !== "on_schedule" ? " stat-danger" : ""}`}><dt>Last written run</dt><dd><span className="stat-value">{written ? ago(written.latestRunAt) : "none"}</span><span className="stat-sub">{written ? <><StatePill state={written.freshness} /> timer every {interval} min</> : `no 'written' run in the lookback window`}</span></dd></div>
            <div className="stat"><dt>States written</dt><dd><span className="stat-value">{int(written?.statesWritten)}</span><span className="stat-sub">{written ? `${int(written.personStates)} person · ${int(written.groupStates)} group` : ""}</span></dd></div>
            <div className="stat"><dt>Ingestion delay</dt><dd><span className="stat-value">{written?.maxIngestionDelaySeconds == null ? "—" : `${Math.round(written.maxIngestionDelaySeconds)} s`}</span><span className="stat-sub">longest during the run</span></dd></div>
            <div className={`stat${written && (written.unattributedRequests > 0 || written.unpricedRequests > 0) ? " stat-warn" : ""}`}><dt>Unattributed / unpriced</dt><dd><span className="stat-value">{written ? `${int(written.unattributedRequests)} / ${int(written.unpricedRequests)}` : "—"}</span><span className="stat-sub">{written?.unattributedCcu ? `${usd(Number(written.unattributedCcu) / 100)} unattributed` : "requests"}</span></dd></div>
          </dl>
          <Section title="Latest run per outcome" description={`Freshness compares each run's age with the timer interval (${interval} min): on schedule within 2 intervals, late within 6, stale after.`}>
            <DataTable caption="Reconciler runs" rows={runs.data.data.rows} rowKey={(r) => `${r.outcome}:${r.reason}`} empty={<p className="empty-inline">No reconciler runs in the lookback window. Check its diagnostic settings.</p>} columns={[
              { key: "outcome", label: "Outcome", render: (r: any) => <StatePill state={r.outcome} /> },
              { key: "reason", label: "Reason", render: (r: any) => r.reason ? <code>{r.reason}</code> : "—" },
              { key: "runs", label: "Runs", align: "end", render: (r: any) => int(r.runs) },
              { key: "latestRunAt", label: "Latest", render: (r: any) => <span title={when(r.latestRunAt)}>{ago(r.latestRunAt)}</span> },
              { key: "freshness", label: "Age vs interval", render: (r: any) => r.outcome === "written" ? <StatePill state={r.freshness} /> : <span className="muted">{r.ageMinutes} min</span> },
              { key: "statesWritten", label: "States", align: "end", render: (r: any) => int(r.statesWritten) },
              { key: "personStates", label: "Person / group", align: "end", render: (r: any) => r.personStates == null ? "—" : `${int(r.personStates)} / ${int(r.groupStates)}` },
              { key: "maxIngestionDelaySeconds", label: "Ingestion delay", align: "end", render: (r: any) => r.maxIngestionDelaySeconds == null ? "—" : `${Math.round(r.maxIngestionDelaySeconds)} s` },
              { key: "unpricedRequests", label: "Unattr. / unpriced", align: "end", render: (r: any) => r.unattributedRequests == null ? "—" : `${int(r.unattributedRequests)} / ${int(r.unpricedRequests)}` },
              { key: "completeness", label: "Completeness", render: (r: any) => r.completeness ? <StatePill state={r.completeness} /> : "—" },
            ]} />
          </Section>
        </>
      )}
      <Section title="Budget snapshots" description="Person and group scope, with the snapshot's own state. Filters and paging run on the server.">
        <div className="filter-bar" role="search" aria-label="Snapshot filters">
          <Field label="Period">{(id) => <select id={id} className="input" value={f.period} onChange={(e) => setF({ ...f, period: e.target.value })}><option value="month">This month</option><option value="previous">Previous month</option></select>}</Field>
          <Field label="Scope">{(id) => <select id={id} className="input" value={f.scope} onChange={(e) => setF({ ...f, scope: e.target.value })}><option value="">Person and group</option><option value="person">Person</option><option value="group">Group</option></select>}</Field>
          <Field label="Project">{(id) => <input id={id} className="input" value={f.project} placeholder="Any" onChange={(e) => setF({ ...f, project: e.target.value.trim() })} />}</Field>
          <Field label="Classification">{(id) => <input id={id} className="input input-short" value={f.classification} placeholder="Any" onChange={(e) => setF({ ...f, classification: e.target.value.trim().toUpperCase() })} />}</Field>
          <Field label="Person" error={person && !GUID.test(person) ? "Object ID (GUID)" : null}>{(id, d) => <input id={id} aria-describedby={d} className="input mono" value={person} placeholder="Object ID" onChange={(e) => { const v = e.target.value.trim(); setPerson(v); if (!v || GUID.test(v)) setF({ ...f, person: v }); }} />}</Field>
          <Field label="Snapshot state">{(id) => <select id={id} className="input" value={f.state} onChange={(e) => setF({ ...f, state: e.target.value })}><option value="">Any</option>{["current", "expired", "historical", "invalid_event"].map((s) => <option key={s} value={s}>{human(s)}</option>)}</select>}</Field>
          <Field label="Budget state">{(id) => <select id={id} className="input" value={f.budgetState} onChange={(e) => setF({ ...f, budgetState: e.target.value })}><option value="">Any</option>{["available", "exhausted", "no_cap", "unknown"].map((s) => <option key={s} value={s}>{human(s)}</option>)}</select>}</Field>
        </div>
        {snaps.loading && !snaps.data ? <Loading rows={6} /> : snaps.error ? <ErrorNote error={snaps.error} retry={snaps.reload} />
          : !ok(snaps.data) ? <CapabilityNotice cap={snaps.data} what="Budget snapshots" />
            : <div aria-busy={snaps.loading}><SnapshotTable rows={snaps.data.data.rows} scope={f.scope || "all"} />{snaps.data.data.page && <PagerLite page={snaps.data.data.page} onPage={setOffset} />}
              <p className="hint">USD equivalents are exact: 100 CCU = USD 1. Rate card {snaps.data.data.rateCardVersion}. Not an invoice.</p></div>}
      </Section>
    </div>
  );
}
