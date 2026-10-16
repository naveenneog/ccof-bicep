import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { createPortal } from "react-dom";

const FAMILY_KEYS = ["haiku", "sonnet", "opus", "fable", "mythos"];
const SECTIONS = { projects: "Projects", budgets: "Group budgets", inventory: "Foundry inventory", pricing: "Cost definitions", operations: "Health & operations", audit: "Audit" };
let api;
const drafts = new Map();
export const hasV2Draft = () => [...drafts.values()].some(Boolean);
function useDraftGuard(key, dirty) {
  useEffect(() => { drafts.set(key, dirty); return () => { drafts.delete(key); }; }, [key, dirty]);
}
function useData(path, version = 0) {
  const [value, setValue] = useState({ loading: true });
  useEffect(() => {
    let active = true;
    if (!path) { setValue({ loading: false }); return; }
    setValue({ loading: true });
    api("GET", path).then((r) => {
      if (active) setValue(r.status === 200 ? { data: r.data, etag: r.etag, loading: false } : { error: r.data?.error ?? `http_${r.status}`, loading: false });
    }).catch(() => { if (active) setValue({ error: "request_failed", loading: false }); });
    return () => { active = false; };
  }, [path, version]);
  return value;
}
const text = (v) => v == null || v === "" ? "Unknown" : React.isValidElement(v) ? v : typeof v === "object" ? JSON.stringify(v) : String(v);
const readable = (v) => text(v).replaceAll("_", " ");
function Notice({ children, danger = false }) {
  return <div className={`notice notice-${danger ? "danger" : "info"}`} role={danger ? "alert" : "status"}>{children}</div>;
}
function DataState({ value, children }) {
  if (value.loading) return <p role="status">Loading…</p>;
  if (value.error) return <Notice danger>Could not load this section: {readable(value.error)}. Other features remain available.</Notice>;
  if (value.data?.state && !["available", "partial"].includes(value.data.state)) return <Notice>
    <strong>{readable(value.data.state)}</strong> — {readable(value.data.reason)}.
    {value.data.permission && <p>Required: {value.data.permission}. No permissions are granted automatically.</p>}
  </Notice>;
  return <>{value.data?.state === "partial" && <Notice>Partial results. Some resources or pages could not be read; missing rows are not evidence of deletion or zero usage.</Notice>}{children}</>;
}
function Table({ columns, rows, empty = "No observations available." }) {
  if (!rows?.length) return <p className="section-note">{empty}</p>;
  return <div className="table-wrap"><table className="v2-table">
    <thead><tr>{columns.map(([key, label]) => <th key={key} scope="col">{label}</th>)}</tr></thead>
    <tbody>{rows.map((row, i) => <tr key={row.id ?? i}>{columns.map(([key]) => <td key={key}>{text(row[key])}</td>)}</tr>)}</tbody>
  </table></div>;
}
function Field({ label, value, onChange, ...props }) {
  return <label className="field">{label}<input className="input" value={value} onChange={(e) => onChange(e.target.value)} {...props}/></label>;
}
function download(name, data) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }));
  const a = document.createElement("a"); a.href = url; a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function Deployments({ id }) {
  const value = useData(`/v2/deployments?resourceId=${encodeURIComponent(id)}`);
  return <DataState value={value}><Table columns={[["name", "Deployment name"], ["model", "Model"], ["state", "Provisioning state"]]} rows={value.data?.data?.deployments}/></DataState>;
}
function Inventory({ projects, version }) {
  const value = useData("/v2/inventory", version);
  const [search, setSearch] = useState("");
  const [tag, setTag] = useState("");
  const [selected, setSelected] = useState(null);
  const rows = value.data?.data?.resources ?? [];
  const filtered = rows.filter((r) => r.type === "Microsoft.CognitiveServices/accounts" &&
    `${r.name} ${r.id}`.toLowerCase().includes(search.toLowerCase()) &&
    JSON.stringify(r.tags).toLowerCase().includes(tag.toLowerCase()));
  return <><h1>Foundry inventory</h1><p className="section-note">One backend per project; a backend can serve many projects. Resource existence is not inference health.</p>
    <div className="fields"><Field label="Find Foundry" value={search} onChange={setSearch}/><Field label="Filter resource tags" value={tag} onChange={setTag}/></div>
    <DataState value={value}>
      <Table columns={[["name", "Foundry"], ["region", "Region"], ["tags", "Azure tags"], ["backendIds", "APIM backend IDs"], ["projects", "Linked projects in loaded page"], ["lifecycle", "Lifecycle"], ["provisioningState", "Control plane"]]}
        rows={filtered.map((r) => ({ ...r, projects: r.lifecycle !== "observed" ? "Unverified; review known backend assignments" : projects.filter((p) => r.backendIds.includes(p.backendId)).map((p) => p.projectId).join(", ") || "None in loaded page" }))}/>
      <div className="toolbar">{filtered.filter((r) => r.lifecycle === "observed").map((r) => <button key={r.id} className="btn btn-small" onClick={() => setSelected(r.id)}>Deployments: {r.name}</button>)}</div>
      {selected && <section className="section"><h2>Deployed models</h2><Deployments id={selected}/></section>}
      <Table columns={[["backendId", "APIM backend"], ["host", "Backend hostname"], ["apimId", "APIM resource"]]} rows={value.data?.data?.backends}/>
    </DataState>
  </>;
}
const usd = (v) => v == null ? "—" : String(v).startsWith("-") ? `-$${String(v).slice(1)}` : `$${v}`;
function UsedMeter({ percent }) {
  if (percent == null) return <span>No cap</span>;
  const value = Number(percent);
  return <span className="usage"><meter min="0" max="100" low="75" high="90" optimum="0" value={Math.min(value, 100)} aria-label={`${percent}% of group budget used`}/> {percent}%</span>;
}
function BudgetRows({ project, value }) {
  const rows = value.data?.data?.groups ?? [];
  return <DataState value={value}>
    <p className="section-note">Month-to-date reconciler calculation, not an Azure invoice. 100 CCU = USD 1. Unknown or partial usage is never treated as zero.</p>
    <Table columns={[["classification", "Access group"], ["configured", "Configured group budget"], ["consumed", "Consumed (CCU / USD)"], ["used", "Used"], ["remaining", "Remaining"], ["completeness", "Coverage"], ["freshness", "Freshness"]]}
      rows={Object.entries(project.classifications ?? {}).map(([code, c]) => {
        const row = rows.find((r) => r.projectId === project.projectId && r.classification === code);
        return {
          classification: `${code} / ${c.classificationGroupDisplayName ?? c.groupId}`,
          configured: c.aggregateBudget ? `${c.aggregateBudget.amount} ${c.aggregateBudget.currency} / month` : "No cap",
          consumed: row ? `${row.spentCcu} CCU / ${usd(row.spentUsd)}` : "Unavailable",
          used: row ? <UsedMeter percent={row.usedPercent}/> : "Unavailable",
          remaining: row?.remainingCcu != null ? `${row.remainingCcu} CCU / ${usd(row.remainingUsd)}` : row ? "No cap" : "Unavailable",
          completeness: row?.completeness ?? "Unknown",
          freshness: !row ? "No observation" : row.fresh ? `Within validity (calculated ${row.computedAt})` : "Stale / invalid validity",
        };
      })}/>
  </DataState>;
}
function Budgets({ version }) {
  const value = useData("/v2/budgets", version);
  const [filter, setFilter] = useState("");
  const totals = value.data?.data?.totals;
  const groups = (value.data?.data?.groups ?? []).filter((g) => `${g.projectId} ${g.classification}`.toLowerCase().includes(filter.toLowerCase()));
  return <><h1>Group budgets</h1><p className="section-note">Every project access group's month-to-date consumption against its group budget, from the reconciler. Not an Azure invoice.</p>
    <DataState value={value}>
      {totals && <div className="v2-summary" role="group" aria-label="Budget totals across groups">
        <div><span className="muted">Consumed, all groups</span><strong>{usd(totals.spentUsd)}</strong><span className="muted">{totals.spentCcu} CCU</span></div>
        <div><span className="muted">Capped group budgets</span><strong>{usd(totals.cappedBudgetUsd)}</strong><span className="muted">{totals.cappedBudgetCcu} CCU</span></div>
        <div><span className="muted">Used of capped budgets</span><strong>{totals.cappedUsedPercent == null ? "—" : `${totals.cappedUsedPercent}%`}</strong><span className="muted">{totals.groups} groups, {totals.uncappedGroups} uncapped</span></div>
        <div><span className="muted">Exhausted</span><strong>{totals.exhaustedGroups}</strong><span className="muted">{totals.staleGroups} stale, {totals.partialGroups} partial</span></div>
      </div>}
      {totals?.lowerBound && <Notice>Totals are a lower bound: some observations are partial, stale or could not be read.</Notice>}
      <Field label="Filter by project or group" value={filter} onChange={setFilter}/>
      <Table columns={[["projectId", "Project"], ["classification", "Group"], ["budget", "Group budget"], ["consumed", "Consumed"], ["used", "Used"], ["remaining", "Remaining"], ["mode", "Mode"], ["state", "Coverage / freshness"]]}
        rows={groups.map((g) => ({
          id: `${g.projectId}/${g.classification}`, projectId: g.projectId, classification: g.classification,
          budget: g.budgetCcu == null ? "No cap" : `${g.budgetCcu} CCU / ${usd(g.budgetUsd)}`,
          consumed: `${g.spentCcu} CCU / ${usd(g.spentUsd)}`, used: <UsedMeter percent={g.usedPercent}/>,
          remaining: g.remainingCcu == null ? "—" : `${g.remainingCcu} CCU / ${usd(g.remainingUsd)}`,
          mode: g.exhausted ? `${g.mode} — exhausted` : g.mode,
          state: `${g.completeness}, ${g.fresh ? "fresh" : "stale"}`,
        }))} empty="No group budget observations this month."/>
    </DataState>
  </>;
}
function ProjectTools({ project, canWrite, saved }) {
  const [tags, setTags] = useState((project.doc.adminTags ?? []).join(", "));
  const [backend, setBackend] = useState(project.doc.backendId);
  const [subscription, setSubscription] = useState(project.doc.designatedSubscriptionId);
  const [budgets, setBudgets] = useState(() => Object.fromEntries(Object.entries(project.doc.classifications).map(([code, c]) =>
    [code, { personBudget: c.personBudget, aggregateBudget: c.aggregateBudget, aggregateMode: c.aggregateMode }])));
  const [review, setReview] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const usage = useData("/v2/budgets");
  const inventory = useData("/v2/inventory");
  const backendIds = inventory.data?.data?.backends?.map((b) => b.backendId) ?? [];
  const body = { adminTags: [...new Set(tags.split(",").map((t) => t.trim()).filter(Boolean))], backendId: backend, designatedSubscriptionId: subscription, budgets };
  const original = {
    adminTags: project.doc.adminTags ?? [], backendId: project.doc.backendId,
    designatedSubscriptionId: project.doc.designatedSubscriptionId,
    budgets: Object.fromEntries(Object.entries(project.doc.classifications).map(([code, c]) => [code, { personBudget: c.personBudget, aggregateBudget: c.aggregateBudget, aggregateMode: c.aggregateMode }])),
  };
  useDraftGuard("project-settings", JSON.stringify(body) !== JSON.stringify(original));
  async function save() {
    setBusy(true); setError("");
    try {
      const r = await api("PUT", `/projects/${encodeURIComponent(project.doc.projectId)}/settings`, { body, etag: project.etag });
      if (r.status !== 200) setError(r.status === 412 ? "Someone else changed this project. Reload before saving; your draft is retained." : readable(r.data?.error));
      else { setReview(false); saved(project.doc.projectId); }
    } catch { setError("Could not save. The server result is unconfirmed; reload the project before retrying."); }
    finally { setBusy(false); }
  }
  return <section className="section"><h2>Organization & consumption</h2>
    <BudgetRows project={project.doc} value={usage}/>
    <p className="section-note">Tags organize projects only; they do not grant access. Backend and budget changes reach runtime after sync/reconciliation. Enforcement still follows the deployed gateway mode.</p>
    {canWrite && !project.editing && <form onSubmit={(e) => { e.preventDefault(); setReview(true); }}>
      <div className="fields">
        <Field label="Custom project tags (comma-separated)" value={tags} onChange={(v) => { setTags(v); setReview(false); }} maxLength={1200}/>
        <Field label="Single APIM backend ID" value={backend} onChange={(v) => { setBackend(v); setReview(false); }} list="v2-backend-ids" required/>
        <Field label="Foundry subscription ID" value={subscription} onChange={(v) => { setSubscription(v); setReview(false); }} required/>
        <datalist id="v2-backend-ids">{[...new Set(backendIds)].map((id) => <option key={id} value={id}/>)}</datalist>
      </div>
      <div className="table-wrap"><table className="v2-table"><thead><tr><th>Group</th><th>Person budget</th><th>Group budget</th><th>Currency</th><th>Group mode</th></tr></thead><tbody>
        {Object.entries(budgets).map(([code, budget]) => <tr key={code}><th scope="row">{code}</th>
          {["personBudget", "aggregateBudget"].map((key) => <td key={key}><input className="input" aria-label={`${code} ${key}`} type="number" min="0" step="0.01"
            value={budget[key]?.amount ?? ""} onChange={(e) => { setReview(false); const amount = e.target.value; setBudgets({ ...budgets, [code]: { ...budget, [key]: amount === "" && key === "aggregateBudget" ? null : { amount: Number(amount), currency: budget.personBudget.currency, period: "monthly" } } }); }}/></td>)}
          <td><select className="select" aria-label={`${code} budget currency`} value={budget.personBudget.currency} onChange={(e) => { setReview(false); setBudgets({ ...budgets, [code]: { ...budget, personBudget: { ...budget.personBudget, currency: e.target.value }, aggregateBudget: budget.aggregateBudget ? { ...budget.aggregateBudget, currency: e.target.value } : null } }); }}><option>USD</option><option>CCU</option></select></td>
          <td><select className="select" aria-label={`${code} aggregate mode`} value={budget.aggregateMode} onChange={(e) => { setReview(false); setBudgets({ ...budgets, [code]: { ...budget, aggregateMode: e.target.value } }); }}><option value="strict">Strict</option><option value="notify">Notify</option></select></td>
        </tr>)}
      </tbody></table></div>
      {error && <Notice danger>{error}</Notice>}
      {review && <><h3>Review proposed settings</h3><details open><summary>Before</summary><pre>{JSON.stringify({ adminTags: project.doc.adminTags ?? [], backendId: project.doc.backendId, budgets: Object.fromEntries(Object.entries(project.doc.classifications).map(([k, c]) => [k, { personBudget: c.personBudget, aggregateBudget: c.aggregateBudget, aggregateMode: c.aggregateMode }])) }, null, 2)}</pre></details><details open><summary>After</summary><pre>{JSON.stringify(body, null, 2)}</pre></details></>}
      <div className="toolbar"><button className="btn" type="submit" disabled={busy}>Review settings</button>{review && <button className="btn btn-primary" type="button" disabled={busy} onClick={save}>{busy ? "Saving…" : "Save reviewed settings"}</button>}</div>
    </form>}
  </section>;
}
function Pricing({ canWrite, version }) {
  const [modelPage, setModelPage] = useState(0);
  const value = useData("/v2/catalog", version);
  const [catalog, setCatalog] = useState(null);
  const [rates, setRates] = useState("");
  const [review, setReview] = useState(false);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const retail = useData("/v2/prices", version);
  const billed = useData("/v2/billed-cost", version);
  useDraftGuard("catalog", Boolean(catalog && value.data?.catalog &&
    (JSON.stringify(catalog.models) !== JSON.stringify(value.data.catalog.models) || rates !== JSON.stringify(value.data.catalog.rateCard, null, 2))));
  useEffect(() => { if (value.data?.catalog) { setModelPage(0); setCatalog(structuredClone(value.data.catalog)); setRates(JSON.stringify(value.data.catalog.rateCard, null, 2)); setReview(false); } }, [value.data]);
  const editable = canWrite && value.data?.editable;
  let rateRows = [];
  let ratePreviewProblem = "";
  try {
    const parsed = JSON.parse(rates);
    if (!Array.isArray(parsed.entries)) throw new Error("entries");
    rateRows = parsed.entries.flatMap((entry) => (entry.promptTiers ?? []).map((tier) => ({
      model: entry.model, from: entry.effectiveFrom, to: entry.effectiveTo ?? "Open",
      tier: `${tier.promptTokensOver != null ? `over ${tier.promptTokensOver}` : "from 0"}${tier.promptTokensUpTo != null ? `, up to ${tier.promptTokensUpTo}` : ""}`,
      ...tier.rates, geography: entry.inferenceGeoMultipliers, source: entry.source?.url,
    })));
  } catch { ratePreviewProblem = "The rate-card JSON is incomplete or invalid; the table preview cannot be shown."; }
  async function save() {
    setBusy(true);
    try {
      const body = { ...catalog, rateCard: JSON.parse(rates) };
      const r = await api("PUT", "/v2/catalog", { body, etag: value.etag, ifNoneMatch: value.etag ? undefined : "*" });
      if (r.status !== 200) setMessage(readable(r.data?.error));
      else { setMessage("Saved. Export the approved rate card before updating reconciler pricing. Reload to edit the new version."); setReview(false); setCatalog(null); window.dispatchEvent(new Event("ccof:catalog-updated")); }
    } catch { setMessage("Invalid JSON or request failed. Nothing is confirmed saved; check the catalog before retrying."); }
    finally { setBusy(false); }
  }
  return <><h1>Cost definitions</h1><p className="section-note">Versioned model catalog and USD token rates. 100 CCU = USD 1; CCU is a billing unit, not a token rate.</p>
    <DataState value={value}>{value.data?.reason && <Notice>{value.data.reason}</Notice>}
      <p className="section-note">Source: {text(value.data?.source)}. {value.data?.enforcement}</p>
      {catalog && <><div className="table-wrap"><table className="v2-table"><thead><tr><th>Family</th><th>Model</th><th>Deployment name</th><th>APIM backend ID (blank = template)</th></tr></thead><tbody>
        {catalog.models.slice(modelPage * 50, (modelPage + 1) * 50).map((m, i) => <tr key={modelPage * 50 + i}>{["family", "model", "deployment", "backendId"].map((key) => <td key={key}><input className="input" aria-label={`Model ${modelPage * 50 + i + 1} ${key}`} value={m[key]} disabled={!editable} onChange={(e) => {
          const models = [...catalog.models]; models[modelPage * 50 + i] = { ...m, [key]: e.target.value }; setCatalog({ ...catalog, models }); setReview(false);
        }}/></td>)}</tr>)}
      </tbody></table></div>
      <div className="toolbar"><button className="btn btn-small" disabled={modelPage === 0} onClick={() => setModelPage(modelPage - 1)}>Previous models</button>
        <span>{catalog.models.length} configured mappings; page {modelPage + 1}</span>
        <button className="btn btn-small" disabled={(modelPage + 1) * 50 >= catalog.models.length} onClick={() => setModelPage(modelPage + 1)}>Next models</button></div>
      {catalog.models.some((m) => !FAMILY_KEYS.includes(m.family)) && <Notice>Custom family labels can be stored for pricing, but the deployed sync/gateway only enforce the supported families. Unsupported families are not offered as allowed-model choices.</Notice>}
      {editable && <button className="btn" onClick={() => { setModelPage(Math.floor(catalog.models.length / 50)); setCatalog({ ...catalog, models: [...catalog.models, { family: "sonnet", model: "", deployment: "", backendId: "" }] }); setReview(false); }}>Add model / deployment</button>}
      <details className="section"><summary>Versioned rate card — token categories, effective intervals and sources</summary>
        <p className="section-note">Rates are USD per million tokens, not USD per CCU. Preserve historical entries; close an interval and append a new one. No automatic retail-to-token conversion.</p>
        {ratePreviewProblem ? <Notice danger>{ratePreviewProblem}</Notice> : <Table columns={[
          ["model", "Model"], ["input", "Input"], ["output", "Output"], ["cacheWrite5m", "Cache write 5m"],
          ["cacheWrite1h", "Cache write 1h"], ["cacheRead", "Cache read"], ["tier", "Prompt tokens"],
          ["geography", "Geo multipliers"], ["from", "Effective from"], ["to", "Effective to"], ["source", "Source"],
        ]} rows={rateRows}/>}
        <textarea className="input v2-json" aria-label="Versioned rate card JSON" value={rates} disabled={!editable} onChange={(e) => { setRates(e.target.value); setReview(false); }}/>
      </details>
      <div className="toolbar"><button className="btn" onClick={() => { try { download("rate-card.admin-v2.json", JSON.parse(rates)); } catch { setMessage("Fix the rate-card JSON before exporting."); } }}>Export rate card</button>
        {editable && <button className="btn" onClick={() => setReview(true)}>Review catalog</button>}
        {review && <button className="btn btn-primary" disabled={busy} onClick={save}>{busy ? "Saving…" : "Save reviewed catalog"}</button>}
      </div>{review && <pre>{JSON.stringify(catalog.models, null, 2)}</pre>}</>}
      {message && <Notice>{message}</Notice>}
    </DataState>
    <section className="section"><h2>Published live retail meters</h2>
      <p className="section-note">These are discovery results, not guaranteed Claude token rates or customer contract prices. An empty result is not a free model. New releases require explicit catalog mapping.</p>
      <DataState value={retail}><Table columns={[["product", "Product"], ["sku", "SKU"], ["meter", "Meter"], ["region", "Region"], ["unit", "Unit"], ["retailPrice", "Retail rate"], ["currency", "Currency"]]} rows={retail.data?.data?.prices}/></DataState>
    </section>
    <section className="section"><h2>Azure billed resource cost</h2>
      <p className="section-note">Month-to-date ActualCost, with Azure ingestion delay. A shared Foundry bill is not automatically a group's bill; do not add this to the calculated usage figures.</p>
      <DataState value={billed}><Table columns={[["ResourceId", "Resource"], ["PreTaxCost", "ActualCost before tax"], ["Currency", "Billing currency"]]} rows={billed.data?.data?.costs}/></DataState>
    </section>
  </>;
}
function Operations({ version }) {
  const health = useData("/v2/health", version);
  const runs = useData("/v2/runs", version);
  const inventory = useData("/v2/inventory", version);
  return <><h1>Health & operations</h1><p className="section-note">Unknown is not healthy. Control-plane state, live endpoint reachability and reconciler freshness are separate signals. No paid model requests are made.</p>
    <section className="section"><h2>Resource observations</h2><DataState value={inventory}><Table columns={[["name", "Resource"], ["type", "Type"], ["provisioningState", "Provisioning"], ["runtimeState", "Reported runtime"], ["lifecycle", "Visibility"]]} rows={inventory.data?.data?.resources}/></DataState></section>
    <section className="section"><h2>Live endpoint probes</h2><DataState value={health}><Table columns={[["name", "Endpoint"], ["state", "Observation"], ["httpStatus", "HTTP"], ["reason", "Concern"], ["observedAt", "Observed at"]]} rows={health.data?.data}/></DataState></section>
    <section className="section"><h2>Recent reconciler runs</h2><DataState value={runs}><Table columns={[["runId", "Run"], ["outcome", "Outcome"], ["reason", "Reason"], ["observedAt", "Observed at"]]} rows={runs.data?.data}/></DataState></section>
  </>;
}
function Audit({ version }) {
  const value = useData("/v2/audit", version);
  const [filter, setFilter] = useState("");
  return <><h1>Audit activity</h1><p className="section-note">Latest 200 admin events within 31 days from configured telemetry resources. Telemetry is not an immutable audit store; retention is configured in Azure.</p>
    <Field label="Filter returned events" value={filter} onChange={setFilter}/>
    <DataState value={value}><Table columns={[["at", "Time"], ["actorOid", "Actor Object ID"], ["operation", "Action"], ["projectId", "Project"], ["outcome", "Outcome"], ["requestId", "Correlation"], ["changes", "Changes"]]}
      rows={(value.data?.data ?? []).filter((r) => JSON.stringify(r).toLowerCase().includes(filter.toLowerCase()))}/></DataState>
  </>;
}
export function mountV2({ call, state, saved }) {
  api = call;
  function Shell() {
    const [route, setRoute] = useState(location.hash);
    const [project, setProject] = useState(null);
    const [version, setVersion] = useState(0);
    useEffect(() => {
      const onHash = () => { setRoute(location.hash); setProject(null); };
      const onProject = (e) => { setProject(e.detail); };
      window.addEventListener("hashchange", onHash);
      document.addEventListener("ccof:project", onProject);
      return () => { window.removeEventListener("hashchange", onHash); document.removeEventListener("ccof:project", onProject); };
    }, []);
    const active = route.replace("#/", "") in SECTIONS ? route.replace("#/", "") : "projects";
    const content = document.getElementById("v2-content");
    const extras = document.getElementById("project-extras");
    return <><nav className="v2-nav" aria-label="Console sections">{Object.entries(SECTIONS).map(([key, label]) =>
      <a key={key} className="btn btn-quiet" aria-current={active === key ? "page" : undefined} href={key === "projects" ? "#/" : `#/${key}`}>{label}</a>)}
      <span className="muted">v2.0.1</span></nav>
      {active !== "projects" && createPortal(<div className="detail-inner"><button className="btn btn-small v2-refresh" onClick={() => setVersion(version + 1)}>Refresh observations</button>
        {active === "budgets" && <Budgets version={version}/>}
        {active === "inventory" && <Inventory projects={state.projects} version={version}/>}
        {active === "pricing" && <Pricing canWrite={state.canWrite} version={version}/>}
        {active === "operations" && <Operations version={version}/>}
        {active === "audit" && <Audit version={version}/>}
      </div>, content)}
      {project && extras && active === "projects" && createPortal(<ProjectTools key={`${project.doc.projectId}/${project.etag}`} project={project} canWrite={state.canWrite} saved={saved}/>, extras)}
    </>;
  }
  createRoot(document.getElementById("console-navigation")).render(<Shell/>);
}
