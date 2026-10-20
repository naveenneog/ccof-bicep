import { useEffect, useMemo, useState } from "react";
import { api, qs, useQuery } from "../lib/api.ts";
import { ago, human, int, pct, usd, when } from "../lib/format.ts";
import { href, navigate } from "../lib/router.ts";
import { Button, ChoiceInput, DataTable, Empty, ErrorNote, Field, Loading, PageHeader, Review, Section, Segmented, StatePill, Tabs, diff, useToast } from "../components/ui.tsx";
import type { Change } from "../components/ui.tsx";
import { BurnDown, Meter, StackedColumns } from "../components/charts.tsx";
import { BudgetAssistant } from "../components/budget-assistant.tsx";
import type { LimitsPatch } from "../components/budget-assistant.tsx";
import { LimitsEditor } from "../components/limits.tsx";
import type { FamilyPolicy } from "../components/limits.tsx";
import { FAMILIES, bucketLabel, trendBuckets } from "../components/panels.tsx";
import { useSession } from "../components/shell.tsx";
import { OnboardingTab } from "../components/onboarding.tsx";

const TABS = [
  { id: "overview", label: "Overview" }, { id: "limits", label: "Models & limits" }, { id: "groups", label: "Access groups" },
  { id: "budgets", label: "Budgets" }, { id: "onboarding", label: "Onboarding" }, { id: "settings", label: "Settings" }, { id: "activity", label: "Activity" },
];
const ok = (cap: any) => cap && (cap.state === "available" || cap.state === "partial");

export function applyPatch(policy: FamilyPolicy, patch: LimitsPatch): FamilyPolicy {
  const next = structuredClone(policy);
  next.aggregateLimits = { ...next.aggregateLimits, ...patch.aggregateLimits };
  for (const [f, v] of Object.entries(patch.families)) if (next.families[f]) next.families[f] = { ...next.families[f], ...v };
  return next;
}

function useSaver(id: string, project: any, setProject: (p: any, etag: string | null) => void) {
  const toast = useToast();
  const [review, setReview] = useState<{ changes: Change[]; send: () => Promise<any>; title: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const open = (title: string, before: unknown, after: unknown, send: () => Promise<any>) => { setError(null); setReview({ title, changes: diff(before, after), send }); };
  const confirm = async () => {
    if (!review) return;
    setBusy(true); setError(null);
    try {
      const r = await review.send();
      const doc = r.data.project ?? r.data;
      setProject(doc, r.etag);
      setReview(null);
      toast(r.data.changed === false ? "No changes to save." : `Saved. Changes reach developers after the next entitlement sync.`);
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return { review, busy, error, open, confirm, cancel: () => setReview(null) };
}

export function ProjectDetail({ id, tab }: { id: string; tab: string }) {
  const session = useSession();
  const q = useQuery(`/api/projects/${encodeURIComponent(id)}`);
  const [project, setProjectState] = useState<any>(null);
  const [etag, setEtag] = useState<string | null>(null);
  const [limitsDraft, setLimitsDraft] = useState<Record<string, FamilyPolicy>>({});
  const [assistantNote, setAssistantNote] = useState<string | null>(null);
  useEffect(() => { if (q.data) { setProjectState(q.data); setEtag(q.etag); setLimitsDraft({}); } }, [q.data, q.etag]);
  const setProject = (doc: any, tag: string | null) => { setProjectState(doc); setEtag(tag); setLimitsDraft({}); setAssistantNote(null); };
  const saver = useSaver(id, project, setProject);
  const active = TABS.some((t) => t.id === tab) ? tab : "overview";

  if (q.error) return <div className="page"><PageHeader title={id} /><ErrorNote error={q.error} retry={q.reload} /><p><a href={href("/projects")}>Back to projects</a></p></div>;
  if (!project) return <div className="page"><PageHeader title={id} /><Loading rows={8} /></div>;
  const codes = Object.keys(project.classifications ?? {}).sort();
  const readOnly = !session.canWrite;

  return (
    <div className="page">
      <PageHeader title={project.displayName} subtitle={<><span className="mono">{project.projectId}</span> · backend <code>{project.backendId}</code> · <StatePill state={project.status === "active" ? "available" : project.status} label={project.status} /></>}
        observedAt={q.observedAt} onRefresh={q.reload} busy={q.loading} />
      <Tabs label="Project sections" tabs={TABS} active={active} onChange={(t) => navigate(`/projects/${encodeURIComponent(id)}/${t}`)} />
      <div role="tabpanel" id={`panel-${active}`} aria-labelledby={`tab-${active}`} className="tab-panel">
        {saver.review ? (
          <Review title={saver.review.title} changes={saver.review.changes} busy={saver.busy} error={saver.error} onConfirm={saver.confirm} onCancel={saver.cancel}
            note="Sent with the version you loaded (If-Match). If someone changed the project meanwhile, nothing is overwritten." />
        ) : active === "overview" ? <ProjectOverview project={project} />
          : active === "limits" ? <LimitsTab project={project} codes={codes} readOnly={readOnly} drafts={limitsDraft} setDrafts={setLimitsDraft} note={assistantNote}
            onReview={(code, policy) => saver.open(`Review limits for ${code}`, project.classifications[code].familyPolicy, policy,
              () => api(`/api/projects/${encodeURIComponent(id)}/classifications/${code}/family-policy`, { method: "PUT", body: policy, ifMatch: etag }))} />
            : active === "groups" ? <GroupsTab project={project} />
              : active === "budgets" ? <BudgetsTab project={project} codes={codes} readOnly={readOnly}
                onApply={(code, patch, summary) => {
                  setLimitsDraft({ ...limitsDraft, [code]: applyPatch(limitsDraft[code] ?? project.classifications[code].familyPolicy, patch) });
                  setAssistantNote(`Limits for ${code} were filled from the budget assistant (${summary}). Review them, then save.`);
                  navigate(`/projects/${encodeURIComponent(id)}/limits?c=${code}`);
                }}
                onReview={(before, after) => saver.open("Review budgets", before, after,
                  () => api(`/api/projects/${encodeURIComponent(id)}/settings`, { method: "PUT", body: { budgets: after }, ifMatch: etag }))} />
                : active === "settings" ? <SettingsTab project={project} readOnly={readOnly}
                  onReview={(before, after) => saver.open("Review settings", before, after,
                    () => api(`/api/projects/${encodeURIComponent(id)}/settings`, { method: "PUT", body: changedOnly(before, after), ifMatch: etag }))} />
                  : active === "onboarding" ? <OnboardingTab project={project} codes={codes} />
                    : <ActivityTab id={id} />}
      </div>
    </div>
  );
}

function changedOnly(before: any, after: any) {
  const out: any = {};
  for (const k of Object.keys(after)) if (JSON.stringify(before[k]) !== JSON.stringify(after[k])) out[k] = after[k];
  if (out.backendId !== undefined) out.designatedSubscriptionId = after.designatedSubscriptionId;
  return out;
}

function ProjectOverview({ project }: { project: any }) {
  const id = project.projectId;
  const budgets = useQuery(`/api/v2/budgets${qs({ projectId: id, limit: 50 })}`);
  const trend = useQuery(`/api/v3/chargeback/trend${qs({ period: "month", project: id, interval: "day" })}`);
  const totals = useQuery(`/api/v3/chargeback/totals${qs({ period: "month", project: id })}`);
  const t = ok(totals.data) ? totals.data.data.rows[0] : null;
  const buckets = ok(trend.data) ? trendBuckets(trend.data.data.rows) : [];
  return (
    <div className="split">
      <div className="stack">
        <section className="panel">
          <div className="panel-head"><h2>Month-to-date cost</h2><a className="btn btn-quiet btn-small" href={href(`/chargeback?project=${encodeURIComponent(id)}`)}>Chargeback for this project</a></div>
          {trend.loading && !trend.data ? <Loading chart /> : !ok(trend.data) ? <p className="muted">Chargeback is {human(trend.data?.state ?? "unavailable")}.</p> : (
            <>
              <p className="lede">Known list cost <strong>{usd(t?.knownListUsd)}</strong>{t && t.listUsd === null && t.knownListUsd !== null ? <span className="muted"> · lower bound, some usage unpriced</span> : null} · {int(t?.requests)} requests</p>
              {buckets.length ? <StackedColumns buckets={buckets} categories={FAMILIES} format={(n) => usd(n, 0)} label="Daily cost by family" tickLabel={bucketLabel("day")} height={200} />
                : <p className="empty-inline">No usage this month (no data, not zero).</p>}
            </>
          )}
        </section>
        <section className="panel">
          <div className="panel-head"><h2>Budget use by access group</h2></div>
          {budgets.loading && !budgets.data ? <Loading rows={3} /> : !ok(budgets.data) ? <p className="muted">Budgets are {human(budgets.data?.state ?? "unavailable")}.</p>
            : <DataTable caption="Group budgets" dense rows={budgets.data.data.groups} empty={<p className="empty-inline">No reconciler snapshot for this project yet.</p>} columns={[
              { key: "classification", label: "Group" },
              { key: "spentUsd", label: "Spent", align: "end", render: (g: any) => usd(g.spentUsd) },
              { key: "budgetUsd", label: "Budget", align: "end", render: (g: any) => g.budgetUsd === null ? "No cap" : usd(g.budgetUsd) },
              { key: "usedPercent", label: "Used", render: (g: any) => <span className="budget-cell"><Meter value={g.usedPercent === null ? null : Number(g.usedPercent)} max={100} label={`${pct(g.usedPercent)} used`} /><span>{pct(g.usedPercent)}</span></span> },
              { key: "completeness", label: "State", render: (g: any) => <StatePill state={g.exhausted ? "exhausted" : g.completeness} /> },
            ]} />}
        </section>
      </div>
      <section className="panel">
        <div className="panel-head"><h2>Facts</h2></div>
        <dl className="facts">
          <div><dt>Project ID</dt><dd className="mono">{project.projectId}</dd></div>
          <div><dt>Backend</dt><dd><code>{project.backendId}</code></dd></div>
          <div><dt>Subscription</dt><dd className="mono wrap">{project.designatedSubscriptionId}</dd></div>
          <div><dt>Tags</dt><dd>{(project.adminTags ?? []).length ? <span className="tag-list">{project.adminTags.map((t: string) => <span key={t} className="tag">{t}</span>)}</span> : "—"}</dd></div>
          <div><dt>Access groups</dt><dd>{Object.keys(project.classifications).sort().join(", ")}</dd></div>
          <div><dt>Families</dt><dd>{[...new Set(Object.values(project.classifications).flatMap((c: any) => Object.keys(c.familyPolicy.families)))].join(", ")}</dd></div>
        </dl>
      </section>
    </div>
  );
}

function LimitsTab({ project, codes, readOnly, drafts, setDrafts, onReview, note }: { project: any; codes: string[]; readOnly: boolean; drafts: Record<string, FamilyPolicy>; setDrafts: (d: Record<string, FamilyPolicy>) => void; onReview: (code: string, p: FamilyPolicy) => void; note: string | null }) {
  const initial = new URLSearchParams(location.hash.split("?")[1] ?? "").get("c");
  const [code, setCode] = useState(initial && codes.includes(initial) ? initial : codes[0]);
  const saved: FamilyPolicy = project.classifications[code].familyPolicy;
  const draft = drafts[code] ?? saved;
  const dirty = JSON.stringify(draft) !== JSON.stringify(saved);
  return (
    <Section title="Models and token limits" description="Per access group: the admitted model families, their models, and per-person and per-group limits."
      actions={codes.length > 1 && <Segmented label="Access group" value={code} onChange={setCode} options={codes.map((c) => ({ value: c, label: c }))} />}>
      {note && <p className="notice notice-info" role="status">{note}</p>}
      <LimitsEditor policy={draft} classification={code} readOnly={readOnly} onChange={(p) => setDrafts({ ...drafts, [code]: p })} />
      {!readOnly && (
        <div className="form-actions">
          <Button variant="primary" disabled={!dirty} onClick={() => onReview(code, draft)}>Review changes</Button>
          <Button variant="quiet" disabled={!dirty} onClick={() => { const d = { ...drafts }; delete d[code]; setDrafts(d); }}>Discard</Button>
          {dirty && <span className="muted">Unsaved changes</span>}
        </div>
      )}
      {readOnly && <p className="hint">Read only. Editing needs the CCOF.Projects.Write role.</p>}
    </Section>
  );
}

function GroupsTab({ project }: { project: any }) {
  const rows = Object.entries(project.classifications).map(([code, c]: [string, any]) => ({ code, ...c }));
  return (
    <Section title="Access groups" description="Each classification maps to one Entra security group. Group IDs can't be changed here; replacing a group is a registry change.">
      <DataTable caption="Access groups" rows={rows} rowKey={(r) => r.code} columns={[
        { key: "code", label: "Classification", render: (r) => <strong>{r.code}</strong> },
        { key: "classificationGroupDisplayName", label: "Group name", render: (r) => r.classificationGroupDisplayName ?? <span className="muted">(not recorded)</span> },
        { key: "groupId", label: "Entra Object ID", render: (r) => <code className="wrap">{r.groupId}</code> },
        { key: "families", label: "Families", render: (r) => Object.keys(r.familyPolicy.families).join(", ") },
        { key: "aggregateMode", label: "Budget mode", render: (r) => <StatePill state={r.aggregateMode} /> },
        { key: "onboardingMode", label: "Onboarding", render: (r) => human(r.onboardingMode) },
      ]} />
    </Section>
  );
}

type BudgetDraft = Record<string, { personBudget: any; aggregateBudget: any; aggregateMode: string }>;
function BudgetsTab({ project, codes, readOnly, onApply, onReview }: { project: any; codes: string[]; readOnly: boolean; onApply: (code: string, patch: LimitsPatch, summary: string) => void; onReview: (before: BudgetDraft, after: BudgetDraft) => void }) {
  const saved: BudgetDraft = useMemo(() => Object.fromEntries(codes.map((c) => [c, {
    personBudget: project.classifications[c].personBudget, aggregateBudget: project.classifications[c].aggregateBudget, aggregateMode: project.classifications[c].aggregateMode,
  }])), [project]);
  const [draft, setDraft] = useState<BudgetDraft>(saved);
  useEffect(() => setDraft(saved), [saved]);
  const [code, setCode] = useState(codes[0]);
  const budgets = useQuery(`/api/v2/budgets${qs({ projectId: project.projectId, limit: 50 })}`);
  const group = project.classifications[code];
  const trend = useQuery(`/api/v3/chargeback/trend${qs({ period: "month", project: project.projectId, group: group.groupId, interval: "day" })}`);
  const set = (c: string, k: string, v: any) => setDraft({ ...draft, [c]: { ...draft[c], [k]: v } });
  const dirty = JSON.stringify(draft) !== JSON.stringify(saved);
  const snapshot = ok(budgets.data) ? budgets.data.data.groups.find((g: any) => g.classification === code) : null;
  const now = new Date();
  const daysInMonth = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 0)).getUTCDate();
  const daily = new Map<number, number>();
  if (ok(trend.data)) for (const r of trend.data.data.rows) {
    const d = new Date(r.bucket).getUTCDate();
    daily.set(d, (daily.get(d) ?? 0) + Number(r.knownListUsd ?? 0));
  }
  let cum = 0;
  const points = Array.from({ length: now.getUTCDate() }, (_, i) => { cum += daily.get(i + 1) ?? 0; return { day: i + 1, cumulative: cum }; });
  const budgetUsd = group.aggregateBudget === null ? null : group.aggregateBudget.currency === "CCU" ? group.aggregateBudget.amount / 100 : group.aggregateBudget.amount;
  const admitted = Object.entries(group.familyPolicy.families).map(([family, f]: [string, any]) => ({ family, models: f.models }));

  return (
    <div className="stack">
      <Section title="Monthly budgets" description="Person budgets are always strict. Group budgets block when exhausted (strict) or only report (notify). Amounts in USD or CCU (100 CCU = USD 1)."
        actions={codes.length > 1 && <Segmented label="Access group" value={code} onChange={setCode} options={codes.map((c) => ({ value: c, label: c }))} />}>
        <div className="row-fields">
          <BudgetInput label="Person budget" value={draft[code].personBudget} onChange={(v) => set(code, "personBudget", v)} readOnly={readOnly} />
          <BudgetInput label="Group budget" value={draft[code].aggregateBudget} onChange={(v) => set(code, "aggregateBudget", v)} readOnly={readOnly} allowNull />
          <Field label="Group mode">{(fid) => (
            <select id={fid} className="input" disabled={readOnly} value={draft[code].aggregateMode} onChange={(e) => set(code, "aggregateMode", e.target.value)}>
              <option value="strict">Strict: block when exhausted</option><option value="notify">Notify only</option>
            </select>
          )}</Field>
        </div>
        {!readOnly && <div className="form-actions"><Button variant="primary" disabled={!dirty} onClick={() => onReview(saved, draft)}>Review changes</Button>
          <Button variant="quiet" disabled={!dirty} onClick={() => setDraft(saved)}>Discard</Button></div>}
      </Section>
      <section className="panel">
        <div className="panel-head"><div><h2>Burn-down: {code}</h2><p className="section-desc">This month's known list cost for the group's Entra group, cumulative, against the group budget.</p></div>
          {snapshot && <span className="hint">Reconciler: {usd(snapshot.spentUsd)} spent · {snapshot.usedPercent === null ? "no cap" : `${pct(snapshot.usedPercent)} used`} · computed {ago(snapshot.computedAt)}</span>}</div>
        {trend.loading && !trend.data ? <Loading chart /> : !ok(trend.data) ? <p className="muted">Chargeback is {human(trend.data?.state ?? "unavailable")}.</p>
          : <BurnDown points={points} budget={budgetUsd} daysInPeriod={daysInMonth} format={(n) => usd(n, 0)} label={`Burn-down for ${code}`} />}
        <details className="data-table"><summary>Data table <span className="muted">({points.length} days)</span></summary>
          <DataTable caption="Burn-down" dense maxHeight rows={points} columns={[
            { key: "day", label: "Day" }, { key: "cumulative", label: "Spent to date", align: "end", render: (r) => usd(r.cumulative) },
            { key: "budget", label: "Budget", align: "end", render: () => budgetUsd === null ? "No cap" : usd(budgetUsd) },
          ]} />
        </details>
      </section>
      <Section title="Budget assistant" description="Turn a monthly budget into suggested token quotas and rate limits per model family, at the approved rate card.">
        <BudgetAssistant key={code} families={admitted} initialBudget={draft[code].personBudget} initialGroupBudget={draft[code].aggregateBudget} applyLabel={readOnly ? undefined : `Apply to ${code} limits`}
          onApply={readOnly ? undefined : (patch, summary) => onApply(code, patch, summary)} />
      </Section>
    </div>
  );
}

function BudgetInput({ label, value, onChange, readOnly, allowNull }: { label: string; value: any; onChange: (v: any) => void; readOnly: boolean; allowNull?: boolean }) {
  return (
    <Field label={label} hint={value === null ? "No cap: the group is never blocked by spend." : value.currency === "CCU" ? `= ${usd(value.amount / 100)}` : `= ${int(value.amount * 100)} CCU`}>{(id, d) => (
      <div className="input-group">
        <input id={id} aria-describedby={d} className="input input-num" inputMode="decimal" readOnly={readOnly} disabled={value === null}
          value={value === null ? "" : value.amount} onChange={(e) => onChange({ ...value, amount: e.target.value === "" ? 0 : Number(e.target.value) })} />
        <select className="input" aria-label={`${label} unit`} disabled={readOnly} value={value === null ? "none" : value.currency}
          onChange={(e) => onChange(e.target.value === "none" ? null : { amount: value?.amount ?? 0, currency: e.target.value, period: "monthly" })}>
          <option value="USD">USD</option><option value="CCU">CCU</option>{allowNull && <option value="none">No cap</option>}
        </select>
      </div>
    )}</Field>
  );
}

function SettingsTab({ project, readOnly, onReview }: { project: any; readOnly: boolean; onReview: (before: any, after: any) => void }) {
  const saved = useMemo(() => ({ displayName: project.displayName, adminTags: project.adminTags ?? [], backendId: project.backendId, designatedSubscriptionId: project.designatedSubscriptionId }), [project]);
  const [draft, setDraft] = useState(saved);
  const [tagText, setTagText] = useState((project.adminTags ?? []).join(", "));
  useEffect(() => { setDraft(saved); setTagText(saved.adminTags.join(", ")); }, [saved]);
  const inventory = useQuery("/api/v2/inventory");
  const backends: string[] = inventory.data?.data?.backends?.map((b: any) => b.backendId) ?? [];
  const after = { ...draft, adminTags: tagText.split(",").map((t: string) => t.trim()).filter(Boolean) };
  const dirty = JSON.stringify(after) !== JSON.stringify(saved);
  return (
    <Section title="Settings" description="Name, tags and routing. A backend change also needs the subscription that the new backend bills to.">
      <div className="form-grid">
        <Field label="Display name">{(id) => <input id={id} className="input" readOnly={readOnly} value={draft.displayName} maxLength={200} onChange={(e) => setDraft({ ...draft, displayName: e.target.value })} />}</Field>
        <Field label="Tags" hint="Comma-separated, up to 20.">{(id, d) => <input id={id} aria-describedby={d} className="input" readOnly={readOnly} value={tagText} onChange={(e) => setTagText(e.target.value)} />}</Field>
        <Field label="Foundry backend" hint={inventory.data?.state === "available" ? "From the APIM inventory." : "Inventory unavailable: type the APIM backend ID."}>{(id, d) => (
          <ChoiceInput id={id} describedBy={d} value={draft.backendId} options={backends} disabled={readOnly}
            onChange={(backendId) => setDraft({ ...draft, backendId })} />
        )}</Field>
        <Field label="Designated subscription ID">{(id) => <input id={id} className="input mono" readOnly={readOnly} value={draft.designatedSubscriptionId} onChange={(e) => setDraft({ ...draft, designatedSubscriptionId: e.target.value })} />}</Field>
      </div>
      {!readOnly && <div className="form-actions"><Button variant="primary" disabled={!dirty} onClick={() => onReview(saved, after)}>Review changes</Button>
        <Button variant="quiet" disabled={!dirty} onClick={() => { setDraft(saved); setTagText(saved.adminTags.join(", ")); }}>Discard</Button></div>}
    </Section>
  );
}

function ActivityTab({ id }: { id: string }) {
  const [offset, setOffset] = useState(0);
  const audit = useQuery(`/api/v3/audit${qs({ project: id, limit: 25, offset })}`);
  if (audit.loading && !audit.data) return <Loading rows={5} />;
  if (audit.error) return <ErrorNote error={audit.error} retry={audit.reload} />;
  if (!ok(audit.data)) return <Empty title={`Activity is ${human(audit.data?.state)}`}>{audit.data?.permission}</Empty>;
  return (
    <Section title="Activity" description="Changes and refusals for this project in the last 31 days, newest first.">
      <DataTable caption="Project activity" rows={audit.data.data.rows} empty={<Empty title="No activity in the last 31 days" />} columns={[
        { key: "at", label: "When", render: (r: any) => when(r.at) },
        { key: "operation", label: "Change", render: (r: any) => human(r.operation) },
        { key: "outcome", label: "Outcome", render: (r: any) => <StatePill state={r.outcome} /> },
        { key: "actorOid", label: "Actor", render: (r: any) => <code>{String(r.actorOid ?? "").slice(0, 8)}</code> },
        { key: "changes", label: "Before → after", render: (r: any) => <ChangeList d={r.d} /> },
      ]} />
      {audit.data.data.page && <PagerLite page={audit.data.data.page} onPage={setOffset} />}
    </Section>
  );
}

export function ChangeList({ d }: { d: any }) {
  const changes: any[] = Array.isArray(d?.changes) ? d.changes : [];
  if (!changes.length) return <span className="muted">{d?.code ? human(d.code) : "—"}</span>;
  return (
    <ul className="change-list">
      {changes.slice(0, 4).map((c, i) => <li key={i}><code>{String(c.path).split(".").slice(-3).join(".")}</code> <span className="diff-before">{JSON.stringify(c.before)}</span> → <span className="diff-after">{JSON.stringify(c.after)}</span></li>)}
      {changes.length > 4 && <li className="muted">+{changes.length - 4} more</li>}
    </ul>
  );
}

export function PagerLite({ page, onPage }: { page: any; onPage: (o: number) => void }) {
  return (
    <nav className="pager" aria-label="Pages">
      <span className="muted">{page.returned ? `${page.offset + 1}–${page.offset + page.returned}` : 0}{page.matched !== null ? ` of ${int(page.matched)}` : ""}</span>
      <div className="pager-buttons">
        <Button size="small" disabled={page.offset === 0} onClick={() => onPage(Math.max(0, page.offset - page.limit))}>Previous</Button>
        <Button size="small" disabled={page.nextOffset === null} onClick={() => onPage(page.nextOffset)}>Next</Button>
      </div>
    </nav>
  );
}
