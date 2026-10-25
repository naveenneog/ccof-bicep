import { useEffect, useState } from "react";
import { qs, useQuery } from "../lib/api.ts";
import { human, when } from "../lib/format.ts";
import { href } from "../lib/router.ts";
import { Button, CapabilityNotice, DataTable, ErrorNote, Field, Loading, PageHeader, Segmented, StatePill } from "../components/ui.tsx";
import { ChangeList, PagerLite } from "./project-detail.tsx";
import { UserIdentity } from "../components/user-identity.tsx";

const ok = (cap: any) => cap && (cap.state === "available" || cap.state === "partial");
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const OPERATIONS = ["create", "settings", "limits", "familyPolicy", "retire", "v2/catalog", "v3/sync/removal-limits"];
const OUTCOMES = ["created", "updated", "retired", "unchanged", "refused", "unconfirmed", "failed", "pending"];
type Source = "changes" | "telemetry";
const dateToIso = (v: string, end = false) => v ? new Date(`${v}T00:00:00Z`).getTime() + (end ? 86_400_000 : 0) : null;

export function Audit({ query }: { query: URLSearchParams }) {
  const [f, setF] = useState({ project: query.get("project") ?? "", actor: "", operation: query.get("operation") ?? "", outcome: "", from: "", to: "" });
  const [source, setSource] = useState<Source>(query.get("source") === "telemetry" ? "telemetry" : "changes");
  const [actorText, setActorText] = useState("");
  const [offset, setOffset] = useState(0);
  useEffect(() => setOffset(0), [JSON.stringify(f), source]);
  const from = dateToIso(f.from), to = dateToIso(f.to, true);
  const rangeError = from !== null && to !== null && from >= to ? "The end date must be after the start date." : null;
  const q = useQuery(rangeError ? null : `/api/v3/${source === "changes" ? "audit/changes" : "audit"}${qs({
    project: f.project, actor: f.actor, operation: f.operation, outcome: f.outcome,
    from: from === null ? null : new Date(from).toISOString(), to: to === null ? null : new Date(to).toISOString(), limit: 50, offset,
  })}`);
  const active = Object.values(f).filter(Boolean).length;
  return (
    <div className="page">
      <PageHeader title="Audit" subtitle="Every change through the admin API, with before → after values. Default range: the last 31 days." observedAt={q.observedAt} onRefresh={q.reload} busy={q.loading} />
      <div className="toolbar">
        <Segmented label="Audit source" value={source} onChange={setSource} options={[{ value: "changes", label: "Change record" }, { value: "telemetry", label: "Telemetry" }]} />
        <span className="muted">{source === "changes" ? "Permanent record in Cosmos (adminConfig), written before each change is applied. Refused attempts are not included." : "Admin log lines in Log Analytics, including refused attempts. Kept for the workspace retention period."}</span>
      </div>
      <div className="filter-bar" role="search" aria-label="Audit filters">
        <Field label="Project">{(id) => <input id={id} className="input" value={f.project} placeholder="Any" onChange={(e) => setF({ ...f, project: e.target.value.trim() })} />}</Field>
        <Field label="Actor" error={actorText && !GUID.test(actorText) ? "Object ID (GUID)" : null}>{(id, d) => <input id={id} aria-describedby={d} className="input mono" placeholder="Object ID" value={actorText} onChange={(e) => { const v = e.target.value.trim(); setActorText(v); if (!v || GUID.test(v)) setF({ ...f, actor: v }); }} />}</Field>
        <Field label="Operation">{(id) => <select id={id} className="input" value={f.operation} onChange={(e) => setF({ ...f, operation: e.target.value })}><option value="">Any</option>{OPERATIONS.map((o) => <option key={o} value={o}>{human(o)}</option>)}</select>}</Field>
        <Field label="Outcome">{(id) => <select id={id} className="input" value={f.outcome} onChange={(e) => setF({ ...f, outcome: e.target.value })}><option value="">Any</option>{OUTCOMES.map((o) => <option key={o} value={o}>{human(o)}</option>)}</select>}</Field>
        <Field label="From (UTC)">{(id) => <input id={id} className="input" type="date" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} />}</Field>
        <Field label="To (UTC)" error={rangeError}>{(id, d) => <input id={id} aria-describedby={d} className="input" type="date" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} />}</Field>
        {active > 0 && <Button variant="quiet" size="small" onClick={() => { setF({ project: "", actor: "", operation: "", outcome: "", from: "", to: "" }); setActorText(""); }}>Clear filters</Button>}
      </div>
      {q.loading && !q.data ? <Loading rows={8} /> : q.error ? <ErrorNote error={q.error} retry={q.reload} /> : !q.data ? null : !ok(q.data) ? <CapabilityNotice cap={q.data} what={source === "changes" ? "The change record" : "Audit telemetry"} /> : (
        <div aria-busy={q.loading}>
          <DataTable caption="Audit log" rows={q.data.data.rows} rowKey={(r) => `${r.requestId}:${r.operation}:${r.outcome}`}
            empty={<p className="empty-inline">{active ? "No audit lines match these filters." : "No changes in the last 31 days."}</p>} columns={[
              { key: "at", label: "When", render: (r: any) => when(r.at) },
              { key: "operation", label: "Operation", render: (r: any) => human(r.operation) },
              { key: "outcome", label: "Outcome", render: (r: any) => <StatePill state={r.outcome} /> },
              { key: "projectId", label: "Project", render: (r: any) => r.projectId ? <a href={href(`/projects/${encodeURIComponent(r.projectId)}/activity`)}>{r.projectId}</a> : "—" },
              { key: "actorOid", label: "Actor", render: (r: any) => <UserIdentity objectId={r.actorOid} /> },
              { key: "d", label: "Before → after", render: (r: any) => <ChangeList d={r.d} /> },
              { key: "requestId", label: "Request", render: (r: any) => <code className="muted">{String(r.requestId).slice(0, 8)}</code> },
            ]} />
          {q.data.data.page && <PagerLite page={q.data.data.page} onPage={setOffset} />}
        </div>
      )}
    </div>
  );
}
