import { useState } from "react";
import { api, useQuery } from "../lib/api.ts";
import { Button, CapabilityNotice, DataTable, Empty, ErrorNote, Field, Loading, PageHeader, Review, Section, StatePill, diff, useToast } from "../components/ui.tsx";
import { useSession } from "../components/shell.tsx";
import { href } from "../lib/router.ts";

// ADR 0034. A registered backend names one approved Foundry Anthropic endpoint. Registration authorizes no
// project; an editor picks fallbacks per project (project Settings > Backend failover).

interface Breaker { enabled: boolean; failureCount: string; failureIntervalSeconds: string; tripDurationSeconds: string; ranges: string; acceptRetryAfter: boolean }
interface Draft { backendId: string; displayName: string; url: string; deployments: string; inferenceGeo: string; status: string; breakerOn: boolean; breaker: Breaker }

const DEFAULT_BREAKER: Breaker = { enabled: true, failureCount: "3", failureIntervalSeconds: "60", tripDurationSeconds: "60", ranges: "429, 500-599", acceptRetryAfter: true };
const EMPTY: Draft = { backendId: "", displayName: "", url: "", deployments: "", inferenceGeo: "global", status: "active", breakerOn: false, breaker: DEFAULT_BREAKER };
const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
const URL_RE = /^https:\/\/[a-z0-9][a-z0-9-]{1,62}\.(services\.ai\.azure\.com|cognitiveservices\.azure\.com|openai\.azure\.com)\/anthropic$/;

function parseRanges(text: string): { min: number; max: number }[] | null {
  const parts = text.split(",").map((p) => p.trim()).filter(Boolean);
  if (!parts.length || parts.length > 5) return null;
  const out = parts.map((p) => { const m = /^(\d{3})(?:-(\d{3}))?$/.exec(p); return m ? { min: Number(m[1]), max: Number(m[2] ?? m[1]) } : null; });
  return out.every((r) => r && r.min >= 400 && r.max <= 599 && r.min <= r.max) ? out as { min: number; max: number }[] : null;
}

const breakerText = (b: any) => !b ? "None" : `${b.enabled ? "On" : "Off"}: ${b.failureCount} failures in ${b.failureIntervalSeconds}s opens for ${b.tripDurationSeconds}s (${b.statusCodeRanges.map((r: any) => r.min === r.max ? r.min : `${r.min}-${r.max}`).join(", ")})`;

function toDraft(b: any): Draft {
  return {
    backendId: b.backendId, displayName: b.displayName, url: b.url, deployments: b.deployments.join(", "), inferenceGeo: b.inferenceGeo, status: b.status,
    breakerOn: Boolean(b.circuitBreaker),
    breaker: b.circuitBreaker ? { enabled: b.circuitBreaker.enabled, failureCount: String(b.circuitBreaker.failureCount), failureIntervalSeconds: String(b.circuitBreaker.failureIntervalSeconds),
      tripDurationSeconds: String(b.circuitBreaker.tripDurationSeconds), acceptRetryAfter: b.circuitBreaker.acceptRetryAfter,
      ranges: b.circuitBreaker.statusCodeRanges.map((r: any) => r.min === r.max ? String(r.min) : `${r.min}-${r.max}`).join(", ") } : DEFAULT_BREAKER,
  };
}

export function Backends() {
  const session = useSession();
  const toast = useToast();
  const q = useQuery("/api/v3/backends");
  const [draft, setDraft] = useState<Draft | null>(null);
  const [editing, setEditing] = useState<any>(null);
  const [review, setReview] = useState<{ before: any; body: any } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  if (q.loading && !q.data) return <div className="page"><PageHeader title="Backends" /><Loading rows={6} /></div>;
  if (q.error) return <div className="page"><PageHeader title="Backends" /><ErrorNote error={q.error} retry={q.reload} /></div>;
  const rows: any[] = q.data?.backends ?? [];
  const editable = Boolean(q.data?.editable && session.canWrite);

  const d = draft ?? EMPTY;
  const ranges = parseRanges(d.breaker.ranges);
  const intIn = (v: string, min: number, max: number) => /^\d+$/.test(v) && Number(v) >= min && Number(v) <= max;
  const problems = {
    backendId: ID.test(d.backendId) && !d.backendId.startsWith("ccof-") ? null : "Letters, digits, - and _, up to 80; not starting with ccof-.",
    displayName: d.displayName.trim() && d.displayName.length <= 120 ? null : "Required, up to 120 characters.",
    url: URL_RE.test(d.url) ? null : "https://<account>.services.ai.azure.com/anthropic",
    deployments: d.deployments.split(",").map((s) => s.trim()).filter(Boolean).length ? null : "At least one deployment name.",
    failureCount: !d.breakerOn || intIn(d.breaker.failureCount, 1, 10000) ? null : "1 to 10,000.",
    failureIntervalSeconds: !d.breakerOn || intIn(d.breaker.failureIntervalSeconds, 10, 3600) ? null : "10 to 3600 seconds.",
    tripDurationSeconds: !d.breakerOn || intIn(d.breaker.tripDurationSeconds, 10, 3600) ? null : "10 to 3600 seconds.",
    ranges: !d.breakerOn || ranges ? null : "Status codes 400-599, for example 429, 500-599 (up to 5 ranges).",
  };
  const valid = !Object.values(problems).some(Boolean);
  const body = {
    displayName: d.displayName.trim(), url: d.url, deployments: d.deployments.split(",").map((s) => s.trim()).filter(Boolean), inferenceGeo: d.inferenceGeo, status: d.status,
    circuitBreaker: d.breakerOn ? { enabled: d.breaker.enabled, failureCount: Number(d.breaker.failureCount), failureIntervalSeconds: Number(d.breaker.failureIntervalSeconds),
      tripDurationSeconds: Number(d.breaker.tripDurationSeconds), statusCodeRanges: ranges ?? [], acceptRetryAfter: d.breaker.acceptRetryAfter } : null,
  };
  const set = (patch: Partial<Draft>) => setDraft({ ...d, ...patch });
  const setB = (patch: Partial<Breaker>) => setDraft({ ...d, breaker: { ...d.breaker, ...patch } });

  const confirm = async () => {
    if (!review) return;
    setBusy(true); setError(null);
    try {
      await api(`/api/v3/backends/${encodeURIComponent(d.backendId)}`, { method: "PUT", body: review.body, ...(editing ? { ifMatch: editing.etag } : { ifNoneMatch: "*" }) });
      toast(editing ? "Backend updated. Pools that use it change at the next routing publication." : "Backend registered. No project uses it until an editor selects it.");
      setReview(null); setDraft(null); setEditing(null); q.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  return (
    <div className="page">
      <PageHeader title="Backends" subtitle="Approved Foundry endpoints that projects can use as failover targets. The circuit breaker is optional per backend."
        observedAt={q.observedAt} onRefresh={q.reload} busy={q.loading}
        actions={editable && !draft && !review ? <Button variant="primary" icon="plus" onClick={() => { setEditing(null); setDraft(EMPTY); }}>Register backend</Button> : undefined} />
      {review ? (
        <Review title={editing ? `Review ${d.backendId}` : `Register ${d.backendId}`} changes={diff(review.before, review.body)} busy={busy} error={error} onConfirm={confirm} onCancel={() => setReview(null)}
          note="Written to the permanent change record before it is saved. Registration does not route any project." />
      ) : draft ? (
        <Section title={editing ? `Edit ${d.backendId}` : "Register backend"} description="A project's primary needs an enabled circuit breaker before failover can be switched on; fallbacks may have none.">
          <div className="form-grid">
            <Field label="Backend ID" error={d.backendId ? problems.backendId : null} hint="For a primary, the APIM backend ID the project already uses.">{(id, h) => <input id={id} aria-describedby={h} className="input mono" readOnly={Boolean(editing)} value={d.backendId} onChange={(e) => set({ backendId: e.target.value.trim() })} />}</Field>
            <Field label="Display name" error={d.displayName ? problems.displayName : null}>{(id, h) => <input id={id} aria-describedby={h} className="input" maxLength={120} value={d.displayName} onChange={(e) => set({ displayName: e.target.value })} />}</Field>
            <Field label="Foundry Anthropic URL" error={d.url ? problems.url : null}>{(id, h) => <input id={id} aria-describedby={h} className="input mono" value={d.url} placeholder="https://account.services.ai.azure.com/anthropic" onChange={(e) => set({ url: e.target.value.trim() })} />}</Field>
            <Field label="Deployments" hint="Comma-separated deployment names this endpoint serves." error={d.deployments ? problems.deployments : null}>{(id, h) => <input id={id} aria-describedby={h} className="input mono" value={d.deployments} onChange={(e) => set({ deployments: e.target.value })} />}</Field>
            <Field label="Inference geography" hint="Fallbacks must match the primary.">{(id) => <select id={id} className="input" value={d.inferenceGeo} onChange={(e) => set({ inferenceGeo: e.target.value })}>
              {["global", "us", "eu"].map((g) => <option key={g} value={g}>{g}</option>)}</select>}</Field>
            <Field label="Status">{(id) => <select id={id} className="input" value={d.status} onChange={(e) => set({ status: e.target.value })}>
              <option value="active">active</option><option value="disabled">disabled</option></select>}</Field>
            <Field label="Circuit breaker">{(id) => <label className="check-inline"><input id={id} type="checkbox" checked={d.breakerOn} onChange={(e) => set({ breakerOn: e.target.checked })} /> Configure a circuit breaker for this backend</label>}</Field>
          </div>
          {d.breakerOn && <div className="form-grid">
            <Field label="Breaker enabled">{(id) => <label className="check-inline"><input id={id} type="checkbox" checked={d.breaker.enabled} onChange={(e) => setB({ enabled: e.target.checked })} /> Open the breaker on failures</label>}</Field>
            <Field label="Failures" error={problems.failureCount}>{(id, h) => <input id={id} aria-describedby={h} className="input" inputMode="numeric" value={d.breaker.failureCount} onChange={(e) => setB({ failureCount: e.target.value.trim() })} />}</Field>
            <Field label="Within (seconds)" error={problems.failureIntervalSeconds}>{(id, h) => <input id={id} aria-describedby={h} className="input" inputMode="numeric" value={d.breaker.failureIntervalSeconds} onChange={(e) => setB({ failureIntervalSeconds: e.target.value.trim() })} />}</Field>
            <Field label="Open for (seconds)" error={problems.tripDurationSeconds}>{(id, h) => <input id={id} aria-describedby={h} className="input" inputMode="numeric" value={d.breaker.tripDurationSeconds} onChange={(e) => setB({ tripDurationSeconds: e.target.value.trim() })} />}</Field>
            <Field label="Status codes" hint="Counted as failures." error={problems.ranges}>{(id, h) => <input id={id} aria-describedby={h} className="input mono" value={d.breaker.ranges} onChange={(e) => setB({ ranges: e.target.value })} />}</Field>
            <Field label="Retry-After">{(id) => <label className="check-inline"><input id={id} type="checkbox" checked={d.breaker.acceptRetryAfter} onChange={(e) => setB({ acceptRetryAfter: e.target.checked })} /> Use the backend's Retry-After as the open time</label>}</Field>
          </div>}
          <div className="form-actions">
            <Button variant="primary" disabled={!valid} onClick={() => { setError(null); setReview({ before: editing ? { ...editing, etag: undefined, backendId: undefined } : {}, body }); }}>Review</Button>
            <Button variant="quiet" onClick={() => { setDraft(null); setEditing(null); }}>Cancel</Button>
          </div>
        </Section>
      ) : (<>
        {!q.data?.editable && q.data?.reason && <CapabilityNotice cap={{ state: "disabled", permission: q.data.reason }} what="Registering backends" />}
        <Section title="Registered backends" description={<>Failover is set per project under the project's Settings tab. <a href={href("/audit?operation=v3/backends")}>Change history</a></>}>
          <DataTable caption="Registered backends" rows={rows} rowKey={(r) => r.backendId}
            empty={<Empty title="No backends registered">Register the primary backend of a project (with a circuit breaker) and at least one fallback.</Empty>}
            onRowClick={editable ? (r) => { setEditing(r); setDraft(toDraft(r)); } : undefined}
            columns={[
              { key: "backendId", label: "Backend", render: (r: any) => <code>{r.backendId}</code> },
              { key: "displayName", label: "Name" },
              { key: "url", label: "Endpoint", render: (r: any) => <span className="mono">{r.url.replace(/^https:\/\//, "")}</span> },
              { key: "inferenceGeo", label: "Geography" },
              { key: "deployments", label: "Deployments", render: (r: any) => r.deployments.join(", ") },
              { key: "circuitBreaker", label: "Circuit breaker", render: (r: any) => breakerText(r.circuitBreaker) },
              { key: "status", label: "Status", render: (r: any) => <StatePill state={r.status === "active" ? "available" : "disabled"} label={r.status} /> },
            ]} />
        </Section>
      </>)}
    </div>
  );
}
