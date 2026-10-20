import { useEffect, useMemo, useRef, useState } from "react";
import { qs, useQuery } from "../lib/api.ts";
import { int, usd } from "../lib/format.ts";
import { href } from "../lib/router.ts";
import { Button, CapabilityNotice, ChoiceInput, ErrorNote, Field, Loading } from "./ui.tsx";
import { Donut, HBars, topWithOther } from "./charts.tsx";
import type { DonutItem } from "./charts.tsx";

// Month-to-date cost breakdown for the Overview: all projects → one project's classifications
// (STD, PRM, CYB, ...) → one classification, with the users and models split for the current level
// beside the main donut. Tags resolve to projects on the server. Unknown cost is never drawn as zero.

const ok = (cap: any) => cap && (cap.state === "available" || cap.state === "partial");
const money = (n: number | null) => usd(n);
const short = (id: string) => /^[0-9a-f-]{36}$/i.test(id) ? `${id.slice(0, 8)}…` : id;

function items(rows: any[], key: (r: any) => string, label: (r: any) => string = key): { items: DonutItem[]; unknown: number } {
  const all = rows.map((r) => ({ key: key(r), label: label(r), value: r.knownListUsd === null || r.knownListUsd === undefined ? null : Number(r.knownListUsd) }));
  return { items: all, unknown: all.filter((i) => i.value === null).length };
}

export function CostBreakdown({ refresh = 0 }: { refresh?: number }) {
  const [tags, setTags] = useState<string[]>([]);
  const [project, setProject] = useState("");
  const [classification, setClassification] = useState("");
  const tagParam = tags.join(",");
  const scope = { period: "month", tags: tagParam, project, classification };

  const registry = useQuery("/api/v2/projects?limit=100");
  const projects = useQuery(`/api/v3/chargeback/projects${qs({ period: "month", tags: tagParam, limit: 200 })}`);
  const classes = useQuery(project ? `/api/v3/chargeback/classifications${qs({ period: "month", project, limit: 50 })}` : null);
  const totals = useQuery(`/api/v3/chargeback/totals${qs(scope)}`);
  const users = useQuery(`/api/v3/chargeback/developers${qs({ ...scope, limit: 100 })}`);
  const models = useQuery(`/api/v3/chargeback/models${qs({ ...scope, limit: 50 })}`);

  const first = useRef(true);
  useEffect(() => {
    if (first.current) { first.current = false; return; }
    [registry, projects, classes, totals, users, models].forEach((q) => q.reload());
  }, [refresh]);

  const knownTags = useMemo(() => [...new Set<string>((registry.data?.projects ?? []).flatMap((p: any) => p.adminTags ?? []))].sort(), [registry.data]);
  const projectRows: any[] = ok(projects.data) ? projects.data.data.rows : [];
  const projectOptions = projectRows.map((r) => String(r.projectLabel));
  const total = ok(totals.data) ? totals.data.data.rows[0] : null;

  const main = project
    ? items(ok(classes.data) ? classes.data.data.rows : [], (r) => String(r.classification || "unassigned"))
    : items(projectRows, (r) => String(r.projectLabel));
  const userSplit = items(ok(users.data) ? users.data.data.rows : [], (r) => String(r.person), (r) => short(String(r.person)));
  const modelSplit = items(ok(models.data) ? models.data.data.rows : [], (r) => String(r.model));
  const mainQ = project ? classes : projects;

  const toggleTag = (t: string) => { setTags((cur) => cur.includes(t) ? cur.filter((x) => x !== t) : [...cur, t].sort()); setProject(""); setClassification(""); };
  const reset = () => { setTags([]); setProject(""); setClassification(""); };
  const drill = (key: string) => {
    if (!project) { setProject(key); setClassification(""); }
    else setClassification(classification === key ? "" : key);
  };
  const scopeText = classification ? `${project} · ${classification}` : project || (tags.length ? `projects tagged ${tags.join(" + ")}` : "all projects");
  const chargebackLink = `/chargeback${qs({ project, tags: tagParam })}`;

  return (
    <section className="panel breakdown" data-help="project-costs" aria-labelledby="breakdown-title">
      <div className="panel-head">
        <div><h2 id="breakdown-title">Month-to-date cost breakdown</h2>
          <p className="section-desc">Select a slice to drill from projects into classifications (STD, PRM, CYB). The users and models split follows the selection.</p></div>
        <a className="btn btn-quiet btn-small" href={href(chargebackLink)}>Open in chargeback</a>
      </div>

      <div className="breakdown-filters" role="group" aria-label="Breakdown filters">
        <div className="field">
          <span className="field-label" id="bd-tags">Tags</span>
          {knownTags.length ? <div className="tag-toggles" role="group" aria-labelledby="bd-tags">
            {knownTags.map((t) => <button key={t} type="button" className="tag-toggle" aria-pressed={tags.includes(t)} onClick={() => toggleTag(t)}>{t}</button>)}
          </div> : <span className="hint">{registry.loading ? "Loading tags…" : "No tagged projects"}</span>}
        </div>
        <Field label="Project">{(id) => <ChoiceInput id={id} value={project} options={projectOptions} emptyLabel="All projects"
          onChange={(v) => { setProject(v); setClassification(""); }} manualLabel="Enter a project ID…" />}</Field>
        {project && <Field label="Classification">{(id) => (
          <select id={id} className="input" value={classification} onChange={(e) => setClassification(e.target.value)}>
            <option value="">All classifications</option>
            {main.items.map((i) => <option key={i.key} value={i.key}>{i.key}</option>)}
          </select>
        )}</Field>}
        {(tags.length > 0 || project) && <Button variant="quiet" size="small" onClick={reset}>Clear</Button>}
      </div>

      <div className="breakdown-summary">
        <span className="breakdown-total" aria-live="polite">{total ? usd(total.knownListUsd) : totals.loading ? "…" : "—"}</span>
        <span className="hint">known list cost for {scopeText}{total?.listUsd === null && total?.knownListUsd !== null ? " · lower bound, some usage is unpriced" : ""}{total ? ` · ${int(total.requests)} requests` : ""}</span>
        {project && <ol className="crumbs" aria-label="Drill-down">
          <li>{project ? <button type="button" onClick={() => { setProject(""); setClassification(""); }}>All projects</button> : <span aria-current="location">All projects</span>}</li>
          {project && <li>{classification ? <button type="button" onClick={() => setClassification("")}>{project}</button> : <span aria-current="location">{project}</span>}</li>}
          {classification && <li><span aria-current="location">{classification}</span></li>}
        </ol>}
      </div>

      <div className="breakdown-grid">
        <div className="breakdown-main">
          <h3>{project ? `${project} by classification` : "By project"}</h3>
          {!mainQ.data && !mainQ.error ? <Loading chart /> : mainQ.error ? <ErrorNote error={mainQ.error} retry={mainQ.reload} />
            : !ok(mainQ.data) ? <CapabilityNotice cap={mainQ.data} what="Cost breakdown" />
              : main.items.length === 0 ? <p className="empty-inline">No usage observed for {scopeText} this month. That is no data, not zero cost.</p>
                : <Donut items={topWithOther(main.items)} format={money} label={project ? `${project} cost by classification` : "Cost by project"}
                  centerValue={usd(main.items.reduce((s, i) => s + (i.value ?? 0), 0), 0)} centerLabel={project ? "project" : "all projects"}
                  onSelect={drill} selected={project ? classification : undefined} unknownCount={main.unknown} />}
          {!project && main.items.length > 8 && <p className="hint">The top 7 projects are drawn; the rest are combined. Pick one from Project to drill in.</p>}
          {project && <p className="hint"><a href={href(`/projects/${encodeURIComponent(project)}`)}>Open {project}</a> for budgets, limits and onboarding files.</p>}
        </div>
        <div>
          <h3>Users</h3>
          {!users.data && !users.error ? <Loading rows={5} /> : users.error ? <ErrorNote error={users.error} retry={users.reload} />
            : !ok(users.data) ? <CapabilityNotice cap={users.data} what="Users split" />
              : userSplit.items.length === 0 ? <p className="empty-inline">No user activity for {scopeText}.</p>
                : <>
                  <HBars label={`Cost by user for ${scopeText}`} format={money}
                    items={userSplit.items.slice(0, 8).map((i) => ({ key: i.key, value: i.value,
                      label: <a href={href(`/chargeback${qs({ developer: i.key, project })}`)} title={i.key}>{i.label}</a> }))} />
                  <p className="hint">{int(userSplit.items.length)} user{userSplit.items.length === 1 ? "" : "s"}{userSplit.items.length > 8 ? ", top 8 shown" : ""}. IDs are Entra object IDs; no names are stored.</p>
                </>}
        </div>
        <div>
          <h3>Models</h3>
          {!models.data && !models.error ? <Loading chart /> : models.error ? <ErrorNote error={models.error} retry={models.reload} />
            : !ok(models.data) ? <CapabilityNotice cap={models.data} what="Models split" />
              : modelSplit.items.length === 0 ? <p className="empty-inline">No model usage for {scopeText}.</p>
                : <Donut items={topWithOther(modelSplit.items, 5)} format={money} label={`Cost by model for ${scopeText}`} size={150}
                  centerValue={String(modelSplit.items.length)} centerLabel={modelSplit.items.length === 1 ? "model" : "models"} unknownCount={modelSplit.unknown} />}
        </div>
      </div>
      <p className="hint">Current month in UTC at list price, not an invoice. Projects with no telemetry are not shown; <a href={href("/projects")}>the registry lists every project</a>.</p>
    </section>
  );
}
