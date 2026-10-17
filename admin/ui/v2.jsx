import React, { useEffect, useId, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { createPortal } from "react-dom";

const FAMILY_KEYS = ["haiku", "sonnet", "opus", "fable", "mythos"];
const SECTIONS = { projects: "Projects", budgets: "Group budgets", inventory: "Foundry inventory", pricing: "Cost definitions", operations: "Health & operations", audit: "Audit" };
const VERSION = "v2.0.1";
const PAGE = 50;
let api;
const drafts = new Map();
export const hasV2Draft = () => [...drafts.values()].some(Boolean);
function useDraftGuard(key, dirty) {
  useEffect(() => { drafts.set(key, dirty); return () => { drafts.delete(key); }; }, [key, dirty]);
}
// Reloading the same path keeps the last result on screen until the new one arrives.
function useData(path, version = 0) {
  const [nonce, setNonce] = useState(0);
  const [value, setValue] = useState({ loading: Boolean(path), path });
  useEffect(() => {
    let active = true;
    if (!path) { setValue({ loading: false, path }); return undefined; }
    setValue((prev) => (prev.path === path && prev.data ? { ...prev, loading: true } : { loading: true, path }));
    api("GET", path).then((r) => {
      if (active) setValue(r.status === 200 ? { data: r.data, etag: r.etag, loading: false, path }
        : { error: r.data?.error ?? `http_${r.status}`, requestId: r.data?.requestId, loading: false, path });
    }).catch(() => { if (active) setValue({ error: "request_failed", loading: false, path }); });
    return () => { active = false; };
  }, [path, version, nonce]);
  return { ...value, reload: () => setNonce((n) => n + 1) };
}

/* ── Formatting ──────────────────────────────────────── */

const scalar = (v) => (v !== null && typeof v === "object" ? JSON.stringify(v) : String(v));
function text(v) {
  if (v == null || v === "") return "Unknown";
  if (React.isValidElement(v)) return v;
  if (Array.isArray(v)) return v.length ? v.map(scalar).join(", ") : "None";
  if (typeof v === "object") {
    const entries = Object.entries(v);
    return entries.length ? entries.map(([k, x]) => `${k}: ${scalar(x)}`).join(", ") : "None";
  }
  return String(v);
}
const readable = (v) => String(text(v)).replaceAll("_", " ");
const sentence = (v) => { const s = readable(v); return s.charAt(0).toUpperCase() + s.slice(1); };
const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
// Reconciler figures are exact decimal strings: regroup them as text, never round-trip through floats.
function decimal(v) {
  const m = /^(-?)(\d+)(\.\d+)?$/.exec(String(v));
  return m ? `${m[1]}${m[2].replace(/\B(?=(\d{3})+(?!\d))/g, ",")}${m[3] ?? ""}` : String(v);
}
const ccu = (v) => (v == null ? "—" : `${decimal(v)} CCU`);
const usd = (v) => (v == null ? "—" : String(v).startsWith("-") ? `-$${decimal(String(v).slice(1))}` : `$${decimal(v)}`);
const budgetText = (b) => (!b ? "No cap" : b.currency === "USD" ? `$${decimal(b.amount)} / month` : `${decimal(b.amount)} ${b.currency} / month`);
function utc(v) {
  if (typeof v !== "string") return null;
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return null;
  const iso = d.toISOString();
  return `${iso.slice(0, 10)} ${iso.slice(11, 19)} UTC`;
}
function When({ value }) {
  const shown = utc(value);
  return shown ? <time dateTime={value} title={value}>{shown}</time> : text(value);
}
const TONES = {
  failed: "danger", failure: "danger", error: "danger", endpoint_refused: "danger", unreachable: "danger", access_denied: "danger", not_found: "danger",
  partial: "warn", stale: "warn", unknown: "warn", unavailable: "warn", not_configured: "warn", permission_required: "warn", refused: "warn", canceled: "warn", cancelled: "warn",
};
function Status({ value }) {
  if (value == null || value === "") return <span className="pill pill-warn">Unknown</span>;
  const tone = TONES[String(value).toLowerCase()];
  return tone ? <span className={`pill pill-${tone}`}>{sentence(value)}</span> : <span>{sentence(value)}</span>;
}

/* ── Shared pieces ───────────────────────────────────── */

function Notice({ tone = "info", title, children, actions }) {
  return <div className={`notice notice-${tone}`} role={tone === "danger" ? "alert" : "status"}>
    {title && <p className="notice-title">{title}</p>}
    {children}
    {actions && <div className="actions">{actions}</div>}
  </div>;
}
function Skeleton({ label }) {
  return <div className="skeleton-table" role="status"><span className="visually-hidden">Loading {label}…</span><span/><span/><span/><span/></div>;
}
const STATE_TITLES = { disabled: "Disabled", permission_required: "Permission required", unavailable: "Unavailable" };
function DataState({ value, label = "this section", children }) {
  if (value.loading && !value.data) return <Skeleton label={label}/>;
  if (value.error) {
    return <Notice tone="danger" title={`Couldn't load ${label}`}
      actions={<button className="btn btn-small" type="button" onClick={value.reload}>Try again</button>}>
      <p>{sentence(value.error)}. Other features remain available.</p>
      {value.requestId && <p className="mono muted">Request ID {value.requestId}</p>}
    </Notice>;
  }
  const state = value.data?.state;
  if (state && !["available", "partial"].includes(state)) {
    return <Notice tone={state === "disabled" ? "info" : "warn"} title={STATE_TITLES[state] ?? sentence(state)}>
      <p>{sentence(value.data.reason)}.</p>
      {value.data.permission && <p>Required: {String(value.data.permission).replace(/\.\s*$/, "")}. No permissions are granted automatically.</p>}
    </Notice>;
  }
  return <>
    {state === "partial" && <Notice tone="warn" title="Partial results">
      <p>Some resources or pages could not be read; missing rows are not evidence of deletion or zero usage.</p>
    </Notice>}
    {children}
  </>;
}
function cell(v, kind) {
  if (kind === "time") return <When value={v}/>;
  if (kind === "status" && !React.isValidElement(v)) return <Status value={v}/>;
  if ((kind === "num" || kind === "note") && (v == null || v === "")) return "—";
  return text(v);
}
// Column: [key, header, kind]. Kinds: num (right-aligned figures), time (UTC), id (long identifiers), status,
// note (optional detail; a missing value means nothing was reported).
function Table({ columns, rows, caption, empty = "No observations available." }) {
  if (!rows?.length) return <p className="table-empty">{empty}</p>;
  return <div className="table-wrap"><table className="v2-table">
    {caption && <caption className="visually-hidden">{caption}</caption>}
    <thead><tr>{columns.map(([key, label, kind]) => <th key={key} scope="col" className={kind}>{label}</th>)}</tr></thead>
    <tbody>{rows.map((row, i) => <tr key={row.id ?? i}>{columns.map(([key, , kind], c) => (c === 0
      ? <th key={key} scope="row" className={kind}>{cell(row[key], kind)}</th>
      : <td key={key} className={kind}>{cell(row[key], kind)}</td>))}</tr>)}</tbody>
  </table></div>;
}
function Field({ label, hint, value, onChange, className, ...props }) {
  const id = useId();
  return <div className={className ? `field ${className}` : "field"}>
    <label htmlFor={id}>{label}</label>
    <input id={id} className="input" value={value} onChange={(e) => onChange(e.target.value)} aria-describedby={hint ? `${id}-hint` : undefined} {...props}/>
    {hint && <p className="hint" id={`${id}-hint`}>{hint}</p>}
  </div>;
}
function PageHead({ title, children, refresh, busy, observedAt }) {
  return <header className="page-head">
    <div className="page-title-row">
      <h1>{title}</h1>
      <div className="page-actions">
        {observedAt && <span className="observed">Observed <When value={observedAt}/></span>}
        <button className="btn btn-small" type="button" aria-busy={busy ? "true" : "false"} onClick={() => { if (!busy) refresh(); }}>Refresh</button>
      </div>
    </div>
    <p className="section-note">{children}</p>
  </header>;
}
function SectionHead({ id, title, value, children }) {
  return <div className="section-head">
    <h2 id={id}>{title}</h2>
    {children ?? (value?.data?.observedAt && <span className="observed">Observed <When value={value.data.observedAt}/></span>)}
  </div>;
}
function FilterBar({ children, shown, total, noun, filtered }) {
  return <div className="filter-bar">
    {children}
    <p className="filter-result" aria-live="polite">{filtered ? `${shown} of ${plural(total, noun)}` : plural(total, noun)}</p>
  </div>;
}
function DiffList({ changes }) {
  return <ul>{changes.map((c) => <li className="diff" key={c.key}>{c.label}: <span className="from">{c.from}</span> → <span className="to">{c.to}</span></li>)}</ul>;
}
function download(name, data) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }));
  const a = document.createElement("a"); a.href = url; a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
const projectLink = (id) => (typeof id === "string" && id ? <a href={`#/p/${encodeURIComponent(id)}`}>{id}</a> : id);

/* ── Budgets ─────────────────────────────────────────── */

function Amount({ ccu: units, usd: dollars }) {
  const negative = String(units).startsWith("-");
  return <span className={negative ? "amount negative" : "amount"}><span>{ccu(units)}</span><span className="amount-usd">{usd(dollars)}</span></span>;
}
function UsedMeter({ percent }) {
  if (percent == null) return <span>No cap</span>;
  const value = Number(percent);
  return <span className="usage">
    <meter min="0" max="100" low="75" high="90" optimum="0" value={Math.min(value, 100)} aria-label={`${percent}% of group budget used`}/>
    <span className="usage-pct">{percent}%</span>
  </span>;
}
function Mode({ mode, exhausted }) {
  return <span className="cell-flow"><span>{mode == null ? "Unknown" : sentence(mode)}</span>{exhausted && <span className="pill pill-danger">Exhausted</span>}</span>;
}
function Coverage({ completeness, fresh }) {
  return <span className="cell-flow">
    {completeness === "complete" ? <span>Complete</span> : <span className="pill pill-warn">{completeness == null ? "Unknown" : sentence(completeness)}</span>}
    {fresh ? <span>Fresh</span> : <span className="pill pill-warn">Stale</span>}
  </span>;
}
function BudgetRows({ project, value }) {
  const rows = value.data?.data?.groups ?? [];
  return <DataState value={value} label="group consumption">
    <p className="section-note">Month-to-date reconciler calculation, not an Azure invoice. 100 CCU = USD 1. Unknown or partial usage is never treated as zero.</p>
    <Table caption={`Month-to-date group consumption for ${project.projectId}`}
      columns={[["classification", "Access group"], ["configured", "Configured group budget", "num"], ["consumed", "Consumed", "num"], ["used", "Used"], ["remaining", "Remaining", "num"], ["completeness", "Coverage"], ["freshness", "Freshness"]]}
      rows={Object.entries(project.classifications ?? {}).map(([code, c]) => {
        const row = rows.find((r) => r.projectId === project.projectId && r.classification === code);
        return {
          id: code,
          classification: <span className="cell-stack"><span>{code}</span><span className="cell-sub">{c.classificationGroupDisplayName ?? c.groupId}</span></span>,
          configured: budgetText(c.aggregateBudget),
          consumed: row ? <Amount ccu={row.spentCcu} usd={row.spentUsd}/> : "Unavailable",
          used: row ? <UsedMeter percent={row.usedPercent}/> : "Unavailable",
          remaining: row?.remainingCcu != null ? <Amount ccu={row.remainingCcu} usd={row.remainingUsd}/> : row ? "No cap" : "Unavailable",
          completeness: row ? <Status value={row.completeness}/> : "Unknown",
          freshness: !row ? "No observation" : <span className="cell-stack">
            {row.fresh ? <span>Within validity</span> : <span className="pill pill-warn">Stale / invalid validity</span>}
            {row.computedAt && <span className="cell-sub">Calculated <When value={row.computedAt}/></span>}
          </span>,
        };
      })}/>
  </DataState>;
}
function BudgetTotals({ totals }) {
  return <>
    <div role="group" aria-label="Budget totals across groups">
      <dl className="stat-strip">
        <div className="stat"><dt>Consumed, all groups</dt><dd><span className="stat-value">{usd(totals.spentUsd)}</span><span className="stat-sub">{ccu(totals.spentCcu)}</span></dd></div>
        <div className="stat"><dt>Capped group budgets</dt><dd><span className="stat-value">{usd(totals.cappedBudgetUsd)}</span><span className="stat-sub">{ccu(totals.cappedBudgetCcu)}</span></dd></div>
        <div className="stat"><dt>Used of capped budgets</dt><dd><span className="stat-value">{totals.cappedUsedPercent == null ? "—" : `${totals.cappedUsedPercent}%`}</span><span className="stat-sub">{totals.groups} groups, {totals.uncappedGroups} uncapped</span></dd></div>
        <div className="stat"><dt>Exhausted groups</dt><dd><span className={totals.exhaustedGroups > 0 ? "stat-value stat-alert" : "stat-value"}>{totals.exhaustedGroups}</span><span className="stat-sub">{totals.staleGroups} stale, {totals.partialGroups} partial</span></dd></div>
      </dl>
    </div>
    {totals.lowerBound && <Notice tone="warn" title="Totals are a lower bound">
      <p>Some observations are partial, stale or could not be read ({totals.partialGroups} partial, {totals.staleGroups} stale, {totals.rejectedRows} rejected). Missing usage is never counted as zero.</p>
    </Notice>}
  </>;
}
const BUDGET_PAGE = 100;
function useDebounced(value, ms = 300) {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => { const t = setTimeout(() => setDebounced(value), ms); return () => clearTimeout(t); }, [value, ms]);
  return debounced;
}
function Budgets({ version, refresh }) {
  const [filter, setFilter] = useState("");
  const [minUsed, setMinUsed] = useState("");
  const [attention, setAttention] = useState(false);
  const [offset, setOffset] = useState(0);
  const search = useDebounced(filter.trim());
  const min = useDebounced(minUsed.trim());
  useEffect(() => { setOffset(0); }, [search, min, attention, version]);
  const params = new URLSearchParams({ limit: String(BUDGET_PAGE), offset: String(offset) });
  if (search) params.set("search", search);
  if (min) params.set("minUsedPercent", min);
  if (attention) params.set("attention", "true");
  const value = useData(`/v2/budgets?${params}`, version);
  const totals = value.data?.data?.totals;
  const page = value.data?.data?.page;
  const groups = value.data?.data?.groups ?? [];
  const filtered = Boolean(search || min || attention);
  return <>
    <PageHead title="Group budgets" refresh={refresh} busy={value.loading} observedAt={value.data?.observedAt}>
      Every project access group's month-to-date consumption against its group budget, from the reconciler. Not an Azure invoice; 100 CCU = USD 1.
    </PageHead>
    <DataState value={value} label="group budgets">
      {totals && <BudgetTotals totals={totals}/>}
      <section className="section" aria-labelledby="budget-groups-title">
        <SectionHead id="budget-groups-title" title="Access groups"/>
        <FilterBar shown={page?.matched ?? groups.length} total={page?.total ?? groups.length} noun="group" filtered={filtered}>
          <Field type="search" label="Filter by project or group" value={filter} onChange={setFilter} autoComplete="off" maxLength={100}/>
          <Field type="number" label="Used at least (%)" value={minUsed} onChange={setMinUsed} min="0" max="10000" step="1" inputMode="numeric" className="field-narrow"/>
          <label className="check"><input type="checkbox" checked={attention} onChange={(e) => setAttention(e.target.checked)}/> Needs attention (exhausted, stale or partial)</label>
        </FilterBar>
        <Table caption="Group budget consumption, highest use first"
          columns={[["projectId", "Project"], ["classification", "Group"], ["budget", "Group budget", "num"], ["consumed", "Consumed", "num"], ["used", "Used"], ["remaining", "Remaining", "num"], ["mode", "Mode"], ["state", "Coverage / freshness"]]}
          rows={groups.map((g) => ({
            id: `${g.projectId}/${g.classification}`, projectId: projectLink(g.projectId), classification: g.classification,
            budget: g.budgetCcu == null ? "No cap" : <Amount ccu={g.budgetCcu} usd={g.budgetUsd}/>,
            consumed: <Amount ccu={g.spentCcu} usd={g.spentUsd}/>, used: <UsedMeter percent={g.usedPercent}/>,
            remaining: g.remainingCcu == null ? "—" : <Amount ccu={g.remainingCcu} usd={g.remainingUsd}/>,
            mode: <Mode mode={g.mode} exhausted={g.exhausted}/>,
            state: <Coverage completeness={g.completeness} fresh={g.fresh}/>,
          }))} empty={filtered ? "No groups match these filters." : "No group budget observations this month."}/>
        {page && page.matched > page.limit && <div className="pager">
          <span>Groups {page.matched ? page.offset + 1 : 0}–{page.offset + page.returned} of {page.matched}</span>
          <div className="toolbar">
            <button className="btn btn-small" type="button" disabled={page.offset === 0 || value.loading} onClick={() => setOffset(Math.max(0, page.offset - page.limit))}>Previous</button>
            <button className="btn btn-small" type="button" disabled={page.nextOffset == null || value.loading} onClick={() => setOffset(page.nextOffset)}>Next</button>
          </div>
        </div>}
      </section>
    </DataState>
  </>;
}

/* ── Project settings (tags, backend, subscription, budgets) ── */

const MODE_LABELS = { strict: "Strict", notify: "Notify" };
const savedBudgets = (doc) => Object.fromEntries(Object.entries(doc.classifications).map(([code, c]) =>
  [code, { personBudget: c.personBudget, aggregateBudget: c.aggregateBudget, aggregateMode: c.aggregateMode }]));
const sameBudget = (a, b) => (a == null || b == null ? a == b
  : Number(a.amount) === Number(b.amount) && a.currency === b.currency && (a.period ?? "monthly") === (b.period ?? "monthly"));
function settingsChanges(before, after) {
  const out = [];
  const add = (key, label, from, to) => out.push({ key, label, from, to });
  const list = (tags) => (tags.length ? tags.join(", ") : "None");
  if (JSON.stringify(before.adminTags) !== JSON.stringify(after.adminTags)) add("tags", "Custom project tags", list(before.adminTags), list(after.adminTags));
  if (before.backendId !== after.backendId) add("backend", "APIM backend ID", before.backendId || "None", after.backendId || "None");
  if (before.designatedSubscriptionId !== after.designatedSubscriptionId) add("subscription", "Foundry subscription ID", before.designatedSubscriptionId || "None", after.designatedSubscriptionId || "None");
  for (const [code, next] of Object.entries(after.budgets)) {
    const prev = before.budgets[code] ?? {};
    if (!sameBudget(prev.personBudget, next.personBudget)) add(`${code}.person`, `${code} · per-person budget`, budgetText(prev.personBudget), budgetText(next.personBudget));
    if (!sameBudget(prev.aggregateBudget, next.aggregateBudget)) add(`${code}.group`, `${code} · whole-group budget`, budgetText(prev.aggregateBudget), budgetText(next.aggregateBudget));
    if (prev.aggregateMode !== next.aggregateMode) add(`${code}.mode`, `${code} · group budget mode`, MODE_LABELS[prev.aggregateMode] ?? text(prev.aggregateMode), MODE_LABELS[next.aggregateMode] ?? text(next.aggregateMode));
  }
  return out;
}
const SETTINGS_NOTE = "Tags organize projects only; they do not grant access. Backend and budget changes reach runtime after sync/reconciliation. Enforcement still follows the deployed gateway mode.";
function ProjectTools({ project, canWrite, saved, notify }) {
  const doc = project.doc;
  const [tags, setTags] = useState((doc.adminTags ?? []).join(", "));
  const [backend, setBackend] = useState(doc.backendId);
  const [subscription, setSubscription] = useState(doc.designatedSubscriptionId);
  const [budgets, setBudgets] = useState(() => savedBudgets(doc));
  const [review, setReview] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const listId = useId();
  const firstAction = useRef(null);
  const usage = useData(`/v2/budgets?projectId=${encodeURIComponent(doc.projectId)}&limit=50`);
  const inventory = useData("/v2/inventory");
  const backendIds = [...new Set(inventory.data?.data?.backends?.map((b) => b.backendId) ?? [])];
  const body = { adminTags: [...new Set(tags.split(",").map((t) => t.trim()).filter(Boolean))], backendId: backend, designatedSubscriptionId: subscription, budgets };
  const original = { adminTags: doc.adminTags ?? [], backendId: doc.backendId, designatedSubscriptionId: doc.designatedSubscriptionId, budgets: savedBudgets(doc) };
  const changes = settingsChanges(original, body);
  useDraftGuard("project-settings", changes.length > 0);
  useEffect(() => { if (review) firstAction.current?.focus(); }, [review]);
  const edit = (set) => (v) => { set(v); setReview(false); };
  const setBudget = (code, next) => { setReview(false); setBudgets({ ...budgets, [code]: next }); };
  function discard() {
    if (!window.confirm("Discard your unsaved changes?")) return;
    setTags(original.adminTags.join(", ")); setBackend(original.backendId); setSubscription(original.designatedSubscriptionId);
    setBudgets(savedBudgets(doc)); setReview(false); setError(null);
  }
  async function save() {
    setBusy(true); setError(null);
    try {
      const r = await api("PUT", `/projects/${encodeURIComponent(doc.projectId)}/settings`, { body, etag: project.etag });
      if (r.status === 412) setError({ stale: true, text: "Someone else changed this project. Load the latest version before saving; your draft stays here until you do." });
      else if (r.status !== 200) setError({ text: `${sentence(r.data?.error ?? `http_${r.status}`)}.`, problems: r.data?.problems ?? [], requestId: r.data?.requestId });
      else { setReview(false); notify?.("Project settings saved. Backend and budget changes reach runtime after sync and reconciliation."); saved(doc.projectId); }
    } catch { setError({ text: "Could not save. The server result is unconfirmed; reload the project before retrying." }); }
    finally { setBusy(false); }
  }
  const count = plural(changes.length, "change");
  return <section className="section" aria-labelledby="org-title">
    <h2 id="org-title">Organization & consumption</h2>
    <div className="subsection">
      <h3>Month-to-date group consumption</h3>
      <BudgetRows project={doc} value={usage}/>
    </div>
    {!canWrite ? <p className="section-note">{SETTINGS_NOTE}</p> : <div className="subsection">
      <h3>Project settings</h3>
      <p className="section-note">{SETTINGS_NOTE}</p>
      {project.editing ? <p className="section-note">Finish or cancel the limits edit above before changing these settings.</p>
        : <form className="settings-form" onSubmit={(e) => { e.preventDefault(); setError(null); setReview(true); }}>
          <div className="fields">
            <Field label="Custom project tags" hint="Comma-separated, for example team:payments." value={tags} onChange={edit(setTags)} maxLength={1200} spellCheck={false}/>
            <Field label="APIM backend ID" hint="One backend per project; several projects can share a backend." value={backend} onChange={edit(setBackend)} list={listId} required spellCheck={false}/>
            <Field label="Foundry subscription ID" hint="Subscription that pays for this project's model use." value={subscription} onChange={edit(setSubscription)} required spellCheck={false}/>
          </div>
          <datalist id={listId}>{backendIds.map((id) => <option key={id} value={id}/>)}</datalist>
          <div className="table-wrap"><table className="v2-table budget-editor">
            <caption className="visually-hidden">Monthly budgets by access group</caption>
            <thead><tr><th scope="col">Group</th><th scope="col" className="num">Per person / month</th><th scope="col" className="num">Whole group / month</th><th scope="col">Currency</th><th scope="col">Group budget mode</th></tr></thead>
            <tbody>{Object.entries(budgets).map(([code, budget]) => <tr key={code}>
              <th scope="row">{code}</th>
              {[["personBudget", "per-person budget"], ["aggregateBudget", "whole-group budget"]].map(([key, name]) => <td key={key} className="num">
                <input className="input num" aria-label={`${code} ${name}`} type="number" min="0" step="0.01" placeholder={key === "aggregateBudget" ? "No cap" : undefined}
                  value={budget[key]?.amount ?? ""} onChange={(e) => {
                    const amount = e.target.value;
                    setBudget(code, { ...budget, [key]: amount === "" && key === "aggregateBudget" ? null : { amount: Number(amount), currency: budget.personBudget.currency, period: "monthly" } });
                  }}/>
              </td>)}
              <td><select className="select" aria-label={`${code} budget currency`} value={budget.personBudget.currency} onChange={(e) => setBudget(code, {
                ...budget, personBudget: { ...budget.personBudget, currency: e.target.value }, aggregateBudget: budget.aggregateBudget ? { ...budget.aggregateBudget, currency: e.target.value } : null,
              })}><option>USD</option><option>CCU</option></select></td>
              <td><select className="select" aria-label={`${code} group budget mode`} value={budget.aggregateMode} onChange={(e) => setBudget(code, { ...budget, aggregateMode: e.target.value })}>
                <option value="strict">Strict</option><option value="notify">Notify</option></select></td>
            </tr>)}</tbody>
          </table></div>
          <p className="hint">Leave a whole-group budget empty for no cap. Changing the currency relabels both amounts; it does not convert them.</p>
          {error && <Notice tone="danger" title="Settings not saved"
            actions={error.stale && <button className="btn btn-small" type="button" onClick={() => saved(doc.projectId)}>Load latest version</button>}>
            <p>{error.text}</p>
            {error.problems?.length > 0 && <ul>{error.problems.map((p) => <li key={p}>{String(p).replace(":", ": ").replaceAll("_", " ")}</li>)}</ul>}
            {error.requestId && <p className="mono muted">Request ID {error.requestId}</p>}
          </Notice>}
          {review ? <div className="notice notice-review" role="status">
            <p className="notice-title">{changes.length ? `Review ${count} to ${doc.projectId}` : "No changes to save"}</p>
            {changes.length ? <DiffList changes={changes}/> : <p>These settings match the saved project.</p>}
            {changes.length > 0 && <p>The save is refused if someone else changed the project after you loaded it. Backend and budget changes reach runtime after sync and reconciliation.</p>}
            <div className="actions">
              {changes.length > 0 && <button ref={firstAction} className="btn btn-primary" type="button" disabled={busy} aria-busy={busy ? "true" : "false"} onClick={save}>{busy ? "Saving" : `Save ${count}`}</button>}
              <button ref={changes.length ? undefined : firstAction} className="btn" type="button" disabled={busy} onClick={() => setReview(false)}>Keep editing</button>
            </div>
          </div> : <div className="toolbar">
            <button className="btn" type="submit" disabled={busy}>Review changes</button>
            {changes.length > 0 && <button className="btn btn-quiet" type="button" onClick={discard}>Discard changes</button>}
          </div>}
        </form>}
    </div>}
  </section>;
}

/* ── Foundry inventory ───────────────────────────────── */

function Deployments({ id }) {
  const value = useData(`/v2/deployments?resourceId=${encodeURIComponent(id)}`);
  return <DataState value={value} label="deployments">
    <Table caption="Deployed models" columns={[["name", "Deployment name"], ["model", "Model"], ["state", "Provisioning state", "status"]]}
      rows={value.data?.data?.deployments} empty="No deployments were returned for this resource."/>
    {value.data?.data?.truncated && <p className="section-note">The deployment list is truncated; not every deployment is shown.</p>}
  </DataState>;
}
function Inventory({ projects, version, refresh }) {
  const value = useData("/v2/inventory", version);
  const [search, setSearch] = useState("");
  const [tag, setTag] = useState("");
  const [selected, setSelected] = useState(null);
  const foundries = (value.data?.data?.resources ?? []).filter((r) => r.type === "Microsoft.CognitiveServices/accounts");
  const filtered = foundries.filter((r) => `${r.name} ${r.id}`.toLowerCase().includes(search.trim().toLowerCase()) &&
    JSON.stringify(r.tags ?? {}).toLowerCase().includes(tag.trim().toLowerCase()));
  const observed = filtered.filter((r) => r.lifecycle === "observed");
  return <>
    <PageHead title="Foundry inventory" refresh={refresh} busy={value.loading} observedAt={value.data?.observedAt}>
      One backend per project; a backend can serve many projects. Resource existence is not inference health.
    </PageHead>
    <DataState value={value} label="the Foundry inventory">
      <section className="section" aria-labelledby="foundry-title">
        <SectionHead id="foundry-title" title="Foundry resources"/>
        <FilterBar shown={filtered.length} total={foundries.length} noun="resource" filtered={Boolean(search.trim() || tag.trim())}>
          <Field type="search" label="Find Foundry" value={search} onChange={setSearch} autoComplete="off"/>
          <Field type="search" label="Filter resource tags" value={tag} onChange={setTag} autoComplete="off"/>
        </FilterBar>
        <Table caption="Foundry resources"
          columns={[["name", "Foundry"], ["region", "Region"], ["tags", "Azure tags"], ["backendIds", "APIM backend IDs"], ["projects", "Linked projects in loaded page"], ["lifecycle", "Lifecycle", "status"], ["provisioningState", "Control plane", "status"]]}
          rows={filtered.map((r) => ({ ...r, projects: r.lifecycle !== "observed" ? "Unverified; review known backend assignments" : projects.filter((p) => (r.backendIds ?? []).includes(p.backendId)).map((p) => p.projectId).join(", ") || "None in loaded page" }))}/>
      </section>
      {observed.length > 0 && <section className="section" aria-labelledby="deployments-title">
        <SectionHead id="deployments-title" title="Deployed models"/>
        <div className="toolbar" role="group" aria-label="Show deployments for">
          {observed.map((r) => <button key={r.id} className="btn btn-small" type="button" aria-pressed={selected === r.id} onClick={() => setSelected(r.id)}>{r.name}</button>)}
        </div>
        {selected ? <Deployments id={selected}/> : <p className="section-note">Choose an observed Foundry resource to list its deployments.</p>}
      </section>}
      <section className="section" aria-labelledby="backends-title">
        <SectionHead id="backends-title" title="APIM backends"/>
        <Table caption="APIM backends" columns={[["backendId", "APIM backend"], ["host", "Backend hostname", "id"], ["apimId", "APIM resource", "id"]]} rows={value.data?.data?.backends}/>
      </section>
    </DataState>
  </>;
}

/* ── Cost definitions ────────────────────────────────── */

const MAPPING_FIELDS = [["family", "family"], ["model", "model"], ["deployment", "deployment name"], ["backendId", "APIM backend ID"]];
const RATE_COLUMNS = [
  ["model", "Model"], ["input", "Input", "num"], ["output", "Output", "num"], ["cacheWrite5m", "Cache write 5m", "num"],
  ["cacheWrite1h", "Cache write 1h", "num"], ["cacheRead", "Cache read", "num"], ["tier", "Prompt tokens"],
  ["geography", "Geo multipliers"], ["from", "Effective from", "time"], ["to", "Effective to", "time"], ["source", "Source", "id"],
];
const mappingKey = (m) => `${m.backendId}/${m.deployment}`;
const mappingName = (m) => `${m.deployment || "(no deployment name)"} · ${m.backendId || "template"}`;
const mappingTarget = (m) => `${m.family || "(no family)"} / ${m.model || "(no model)"}`;
const rateSummary = (card) => `version ${text(card?.version)}, ${plural(Array.isArray(card?.entries) ? card.entries.length : 0, "entry", "entries")}`;
function catalogChanges(loaded, models, rates) {
  const before = new Map((loaded?.models ?? []).map((m) => [mappingKey(m), m]));
  const after = new Map(models.map((m) => [mappingKey(m), m]));
  const out = [];
  for (const [key, m] of after) {
    const old = before.get(key);
    if (!old) out.push({ key: `add:${key}`, label: `Add ${mappingName(m)}`, from: "Not mapped", to: mappingTarget(m) });
    else if (old.family !== m.family || old.model !== m.model) out.push({ key: `change:${key}`, label: mappingName(m), from: mappingTarget(old), to: mappingTarget(m) });
  }
  for (const [key, old] of before) if (!after.has(key)) out.push({ key: `remove:${key}`, label: `Remove ${mappingName(old)}`, from: mappingTarget(old), to: "Not mapped" });
  let next = null;
  try { next = JSON.parse(rates); } catch { next = null; }
  if (!next) out.push({ key: "rates", label: "Rate card", from: rateSummary(loaded?.rateCard), to: "Invalid JSON" });
  else if (JSON.stringify(next) !== JSON.stringify(loaded?.rateCard)) {
    const from = rateSummary(loaded?.rateCard);
    const to = rateSummary(next);
    out.push({ key: "rates", label: "Rate card", from, to: to === from ? `${to}, entries edited` : to });
  }
  return out;
}
// Mirrors server rules so problems show before saving; the server still validates everything.
function catalogProblems(loaded, models, rates) {
  const problems = [];
  const counts = new Map();
  for (const m of models) counts.set(mappingKey(m), (counts.get(mappingKey(m)) ?? 0) + 1);
  for (const [key, n] of counts) if (n > 1) problems.push(`Duplicate deployment mapping: ${mappingName(models.find((m) => mappingKey(m) === key))}.`);
  const incomplete = models.flatMap((m, i) => (!m.family || !m.model || !m.deployment ? [i + 1] : []));
  if (incomplete.length) problems.push(`${incomplete.length === 1 ? `Mapping ${incomplete[0]} needs` : `Mappings ${incomplete.join(", ")} need`} a family, model and deployment name.`);
  let next = null;
  try { next = JSON.parse(rates); } catch { problems.push("The rate-card JSON is invalid."); }
  if (next && loaded?.rateCard && JSON.stringify(next) !== JSON.stringify(loaded.rateCard) && next.version === loaded.rateCard.version) {
    problems.push("Rate card entries changed but its version did not. Give the edited rate card a new version.");
  }
  return problems;
}
function CatalogReview({ loaded, catalog, rates, busy, onSave, onCancel }) {
  const first = useRef(null);
  useEffect(() => { first.current?.focus(); }, []);
  const changes = catalogChanges(loaded, catalog.models, rates);
  const problems = catalogProblems(loaded, catalog.models, rates);
  return <>
    {problems.length > 0 && <Notice tone="warn" title="The server will reject this catalog">
      <ul>{problems.map((p) => <li key={p}>{p}</li>)}</ul>
    </Notice>}
    <div className="notice notice-review" role="status">
      <p className="notice-title">{changes.length ? `Review ${plural(changes.length, "catalog change")}` : "No changes from the loaded catalog"}</p>
      {changes.length > 0 && <DiffList changes={changes}/>}
      <p>Saving does not change deployed reconciler prices. Export the approved rate card to update reconciler pricing.</p>
      <details className="review-raw"><summary>All mappings as JSON</summary><pre>{JSON.stringify(catalog.models, null, 2)}</pre></details>
      <div className="actions">
        <button ref={first} className="btn btn-primary" type="button" disabled={busy} aria-busy={busy ? "true" : "false"} onClick={onSave}>{busy ? "Saving" : "Save reviewed catalog"}</button>
        <button className="btn" type="button" disabled={busy} onClick={onCancel}>Keep editing</button>
      </div>
    </div>
  </>;
}
function Pricing({ canWrite, version, refresh }) {
  const [modelPage, setModelPage] = useState(0);
  const value = useData("/v2/catalog", version);
  const [catalog, setCatalog] = useState(null);
  const [rates, setRates] = useState("");
  const [review, setReview] = useState(false);
  const [message, setMessage] = useState(null);
  const [busy, setBusy] = useState(false);
  const retail = useData("/v2/prices", version);
  const billed = useData("/v2/billed-cost", version);
  const ratesId = useId();
  const loaded = value.data?.catalog;
  useDraftGuard("catalog", Boolean(catalog && loaded &&
    (JSON.stringify(catalog.models) !== JSON.stringify(loaded.models) || rates !== JSON.stringify(loaded.rateCard, null, 2))));
  useEffect(() => { if (value.data?.catalog) { setModelPage(0); setCatalog(structuredClone(value.data.catalog)); setRates(JSON.stringify(value.data.catalog.rateCard, null, 2)); setReview(false); } }, [value.data]);
  // An explicit refresh starts clean; the reload after a successful save keeps its confirmation.
  useEffect(() => { setMessage(null); }, [version]);
  const editable = canWrite && value.data?.editable;
  let rateRows = [];
  let ratePreviewProblem = "";
  try {
    const parsed = JSON.parse(rates);
    if (!Array.isArray(parsed.entries)) throw new Error("entries");
    rateRows = parsed.entries.flatMap((entry) => (entry.promptTiers ?? []).map((tier) => ({
      model: entry.model, from: entry.effectiveFrom, to: entry.effectiveTo ?? "Open",
      tier: `${tier.promptTokensOver != null ? `over ${decimal(tier.promptTokensOver)}` : "from 0"}${tier.promptTokensUpTo != null ? `, up to ${decimal(tier.promptTokensUpTo)}` : ""}`,
      ...tier.rates, geography: entry.inferenceGeoMultipliers, source: entry.source?.url,
    })));
  } catch { ratePreviewProblem = "The rate-card JSON is incomplete or invalid; the table preview cannot be shown."; }
  async function save() {
    setBusy(true);
    try {
      const body = { ...catalog, rateCard: JSON.parse(rates) };
      const r = await api("PUT", "/v2/catalog", { body, etag: value.etag, ifNoneMatch: value.etag ? undefined : "*" });
      if (r.status === 412) setMessage({ tone: "danger", title: "Catalog not saved", text: "Someone else changed the cost definitions. Refresh to load the latest version; your edits are discarded when you do." });
      else if (r.status !== 200) setMessage({ tone: "danger", title: "Catalog not saved", text: `${sentence(r.data?.error ?? `http_${r.status}`)}.`, requestId: r.data?.requestId });
      else {
        setMessage({ tone: "info", title: "Catalog saved", text: "The definitions below are reloaded from the server. Export the approved rate card before updating reconciler pricing." });
        setReview(false); setCatalog(null); window.dispatchEvent(new Event("ccof:catalog-updated")); value.reload();
      }
    } catch { setMessage({ tone: "danger", title: "Catalog not saved", text: "Invalid JSON or request failed. Nothing is confirmed saved; check the catalog before retrying." }); }
    finally { setBusy(false); }
  }
  const exportRates = () => {
    try { download("rate-card.admin-v2.json", JSON.parse(rates)); }
    catch { setMessage({ tone: "danger", title: "Rate card not exported", text: "Fix the rate-card JSON before exporting." }); }
  };
  const addMapping = () => {
    setModelPage(Math.floor(catalog.models.length / PAGE));
    setCatalog({ ...catalog, models: [...catalog.models, { family: "sonnet", model: "", deployment: "", backendId: "" }] }); setReview(false);
  };
  const total = catalog?.models.length ?? 0;
  const start = modelPage * PAGE;
  return <>
    <PageHead title="Cost definitions" refresh={refresh} busy={value.loading || retail.loading || billed.loading}>
      Versioned model catalog and USD token rates. 100 CCU = USD 1; CCU is a billing unit, not a token rate.
    </PageHead>
    <DataState value={value} label="cost definitions">
      {value.data?.reason && <Notice title="Saving is disabled"><p>{value.data.reason}</p></Notice>}
      <p className="section-note">Source: {readable(value.data?.source)}. {value.data?.enforcement}</p>
      {catalog && <>
        <section className="section" aria-labelledby="catalog-title">
          <SectionHead id="catalog-title" title="Model catalog"><span className="observed">{plural(total, "configured mapping")}</span></SectionHead>
          <div className="table-wrap"><table className="v2-table catalog-table">
            <caption className="visually-hidden">Model family and deployment mappings</caption>
            <thead><tr><th scope="col">Family</th><th scope="col">Model</th><th scope="col">Deployment name</th><th scope="col">APIM backend ID (blank = template)</th></tr></thead>
            <tbody>{catalog.models.slice(start, start + PAGE).map((m, i) => <tr key={start + i}>{MAPPING_FIELDS.map(([key, label]) => <td key={key}>{editable
              ? <input className="input" aria-label={`Mapping ${start + i + 1} ${label}`} value={m[key]} spellCheck={false} onChange={(e) => {
                const models = [...catalog.models]; models[start + i] = { ...m, [key]: e.target.value }; setCatalog({ ...catalog, models }); setReview(false);
              }}/>
              : key === "backendId" && !m[key] ? <span className="muted">Template</span> : text(m[key])}</td>)}</tr>)}</tbody>
          </table></div>
          {total > PAGE && <div className="pager">
            <span>Mappings {start + 1}–{Math.min(start + PAGE, total)} of {total}</span>
            <div className="toolbar">
              <button className="btn btn-small" type="button" disabled={modelPage === 0} onClick={() => setModelPage(modelPage - 1)}>Previous</button>
              <button className="btn btn-small" type="button" disabled={start + PAGE >= total} onClick={() => setModelPage(modelPage + 1)}>Next</button>
            </div>
          </div>}
          {editable && <div className="toolbar"><button className="btn btn-small" type="button" onClick={addMapping}>Add model / deployment</button></div>}
          {catalog.models.some((m) => !FAMILY_KEYS.includes(m.family)) && <Notice tone="warn" title="Unsupported family labels">
            <p>Custom family labels can be stored for pricing, but the deployed sync/gateway only enforce the supported families. Unsupported families are not offered as allowed-model choices.</p>
          </Notice>}
        </section>
        <details className="disclosure">
          <summary>Versioned rate card<span className="summary-note">Token categories, effective intervals and sources</span></summary>
          <div className="disclosure-body">
            <p className="section-note">Rates are USD per million tokens, not USD per CCU. Preserve historical entries; close an interval and append a new one. No automatic retail-to-token conversion.</p>
            {ratePreviewProblem ? <Notice tone="danger" title="Preview unavailable"><p>{ratePreviewProblem}</p></Notice>
              : <Table caption="Rate card entries, USD per million tokens" columns={RATE_COLUMNS} rows={rateRows}/>}
            <div className="field">
              <label htmlFor={ratesId}>Rate card JSON</label>
              <textarea id={ratesId} className="input v2-json" value={rates} readOnly={!editable} spellCheck={false} onChange={(e) => { setRates(e.target.value); setReview(false); }}/>
            </div>
          </div>
        </details>
        <div className="toolbar">
          <button className="btn" type="button" onClick={exportRates}>Export rate card</button>
          {editable && !review && <button className="btn" type="button" onClick={() => setReview(true)}>Review catalog</button>}
        </div>
        {review && <CatalogReview loaded={loaded} catalog={catalog} rates={rates} busy={busy} onSave={save} onCancel={() => setReview(false)}/>}
      </>}
      {message && <Notice tone={message.tone} title={message.title}>
        <p>{message.text}</p>
        {message.requestId && <p className="mono muted">Request ID {message.requestId}</p>}
      </Notice>}
    </DataState>
    <section className="section" aria-labelledby="retail-title">
      <SectionHead id="retail-title" title="Published live retail meters" value={retail}/>
      <p className="section-note">These are discovery results, not guaranteed Claude token rates or customer contract prices. An empty result is not a free model. New releases require explicit catalog mapping.</p>
      <DataState value={retail} label="retail meters">
        <Table caption="Published live retail meters" columns={[["product", "Product"], ["sku", "SKU"], ["meter", "Meter"], ["region", "Region"], ["unit", "Unit"], ["retailPrice", "Retail rate", "num"], ["currency", "Currency"]]}
          rows={retail.data?.data?.prices} empty="No published meters matched. This does not mean the model is free."/>
      </DataState>
    </section>
    <section className="section" aria-labelledby="billed-title">
      <SectionHead id="billed-title" title="Azure billed resource cost" value={billed}/>
      <p className="section-note">Month-to-date ActualCost, with Azure ingestion delay. A shared Foundry bill is not automatically a group's bill; do not add this to the calculated usage figures.</p>
      <DataState value={billed} label="billed cost">
        <Table caption="Azure billed resource cost, month to date" columns={[["ResourceId", "Resource", "id"], ["PreTaxCost", "ActualCost before tax", "num"], ["Currency", "Billing currency"]]} rows={billed.data?.data?.costs}/>
      </DataState>
    </section>
  </>;
}

/* ── Health & operations, audit ──────────────────────── */

function Operations({ version, refresh }) {
  const health = useData("/v2/health", version);
  const runs = useData("/v2/runs", version);
  const inventory = useData("/v2/inventory", version);
  return <>
    <PageHead title="Health & operations" refresh={refresh} busy={health.loading || runs.loading || inventory.loading}>
      Unknown is not healthy. Control-plane state, live endpoint reachability and reconciler freshness are separate signals. No paid model requests are made.
    </PageHead>
    <section className="section" aria-labelledby="ops-resources">
      <SectionHead id="ops-resources" title="Resource observations" value={inventory}/>
      <DataState value={inventory} label="resource observations">
        <Table caption="Resource observations" columns={[["name", "Resource"], ["type", "Type", "id"], ["provisioningState", "Provisioning", "status"], ["runtimeState", "Reported runtime", "status"], ["lifecycle", "Visibility", "status"]]} rows={inventory.data?.data?.resources}/>
      </DataState>
    </section>
    <section className="section" aria-labelledby="ops-probes">
      <SectionHead id="ops-probes" title="Live endpoint probes" value={health}/>
      <DataState value={health} label="endpoint probes">
        <Table caption="Live endpoint probes" columns={[["name", "Endpoint"], ["state", "Observation", "status"], ["httpStatus", "HTTP", "num"], ["reason", "Concern", "note"], ["observedAt", "Observed at", "time"]]} rows={health.data?.data}/>
      </DataState>
    </section>
    <section className="section" aria-labelledby="ops-runs">
      <SectionHead id="ops-runs" title="Recent reconciler runs" value={runs}/>
      <DataState value={runs} label="reconciler runs">
        <Table caption="Recent reconciler runs" columns={[["runId", "Run", "id"], ["outcome", "Outcome", "status"], ["reason", "Reason", "note"], ["observedAt", "Observed at", "time"]]} rows={runs.data?.data}/>
      </DataState>
    </section>
  </>;
}
const shown = (v) => (v == null ? "none" : v === "" ? "empty" : typeof v === "object" ? String(text(v)) : String(v));
function ChangeList({ changes, truncated }) {
  if (!Array.isArray(changes) || changes.length === 0) return <span className="muted">None recorded</span>;
  return <ul className="change-list">
    {changes.map((c, i) => <li className="diff" key={i}><span className="change-path">{c?.path ?? "value"}</span>: <span className="from">{shown(c?.before)}</span> → <span className="to">{shown(c?.after)}</span></li>)}
    {truncated && <li className="muted">More changes were not recorded in this event.</li>}
  </ul>;
}
function Audit({ version, refresh }) {
  const value = useData("/v2/audit", version);
  const [filter, setFilter] = useState("");
  const all = Array.isArray(value.data?.data) ? value.data.data : [];
  const query = filter.trim().toLowerCase();
  const rows = all.filter((r) => JSON.stringify(r).toLowerCase().includes(query));
  return <>
    <PageHead title="Audit activity" refresh={refresh} busy={value.loading} observedAt={value.data?.observedAt}>
      Latest 200 admin events within 31 days from configured telemetry resources. Telemetry is not an immutable audit store; retention is configured in Azure.
    </PageHead>
    <DataState value={value} label="audit activity">
      <section className="section" aria-label="Audit events">
        <FilterBar shown={rows.length} total={all.length} noun="event" filtered={Boolean(query)}>
          <Field type="search" label="Filter returned events" value={filter} onChange={setFilter} autoComplete="off"/>
        </FilterBar>
        <Table caption="Audit events, newest first"
          columns={[["at", "Time", "time"], ["actorOid", "Actor Object ID", "id"], ["operation", "Action"], ["projectId", "Project", "note"], ["outcome", "Outcome", "status"], ["requestId", "Correlation", "id"], ["changes", "Changes"]]}
          rows={rows.map((r) => ({ ...r, id: undefined, projectId: projectLink(r.projectId), changes: <ChangeList changes={r.changes} truncated={r.changesTruncated}/> }))}
          empty={query ? "No events match this filter." : "No admin events were returned for the last 31 days."}/>
      </section>
    </DataState>
  </>;
}

/* ── Shell: section navigation and portals ───────────── */

export function mountV2({ call, state, saved, notify }) {
  api = call;
  function Shell() {
    const [route, setRoute] = useState(location.hash);
    const [project, setProject] = useState(null);
    const [version, setVersion] = useState(0);
    const [, setListVersion] = useState(0);
    const navRef = useRef(null);
    const content = document.getElementById("v2-content");
    const extras = document.getElementById("project-extras");
    useEffect(() => {
      const onHash = () => { setRoute(location.hash); setProject(null); };
      const onProject = (e) => { setProject(e.detail); };
      // Inventory links Foundry resources to the loaded project page; re-render when that list changes.
      const onList = () => setListVersion((n) => n + 1);
      window.addEventListener("hashchange", onHash);
      document.addEventListener("ccof:project", onProject);
      document.addEventListener("ccof:projects", onList);
      return () => {
        window.removeEventListener("hashchange", onHash);
        document.removeEventListener("ccof:project", onProject);
        document.removeEventListener("ccof:projects", onList);
      };
    }, []);
    const key = route.replace("#/", "");
    const active = Object.hasOwn(SECTIONS, key) ? key : "projects";
    useEffect(() => {
      document.title = `${SECTIONS[active]} · CCOF Admin console v2`;
      // On narrow screens the section tabs scroll sideways; keep the current one in view.
      const nav = navRef.current;
      const link = nav?.querySelector('[aria-current="page"]');
      if (link && (link.offsetLeft < nav.scrollLeft || link.offsetLeft + link.offsetWidth > nav.scrollLeft + nav.clientWidth)) nav.scrollLeft = Math.max(0, link.offsetLeft - 16);
      if (active !== "projects") { content.scrollTop = 0; document.getElementById("main").scrollTop = 0; }
    }, [active]);
    const refresh = () => { if (!hasV2Draft() || window.confirm("Discard unsaved changes and reload?")) setVersion((v) => v + 1); };
    const page = { version, refresh };
    return <>
      <nav className="v2-nav" aria-label="Console sections" ref={navRef}>
        <ul>{Object.entries(SECTIONS).map(([id, label]) => <li key={id}>
          <a aria-current={active === id ? "page" : undefined} href={id === "projects" ? "#/" : `#/${id}`}>{label}</a>
        </li>)}</ul>
        <span className="nav-version">Console {VERSION}</span>
      </nav>
      {active !== "projects" && createPortal(<div className="detail-inner detail-enter" key={active}>
        {active === "budgets" && <Budgets {...page}/>}
        {active === "inventory" && <Inventory projects={state.projects} {...page}/>}
        {active === "pricing" && <Pricing canWrite={state.canWrite} {...page}/>}
        {active === "operations" && <Operations {...page}/>}
        {active === "audit" && <Audit {...page}/>}
      </div>, content)}
      {project && extras && active === "projects" && createPortal(<ProjectTools key={`${project.doc.projectId}/${project.etag}`} project={project} canWrite={state.canWrite} saved={saved} notify={notify}/>, extras)}
    </>;
  }
  createRoot(document.getElementById("console-navigation")).render(<Shell/>);
}
