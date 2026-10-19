import { useEffect, useMemo, useState } from "react";
import { qs, useQuery } from "../lib/api.ts";
import { pct } from "../lib/format.ts";
import { href, navigate } from "../lib/router.ts";
import { Button, DataTable, Empty, ErrorNote, Field, Loading, PageHeader, StatePill } from "../components/ui.tsx";
import { Meter } from "../components/charts.tsx";
import { useSession } from "../components/shell.tsx";

const PAGE = 25;
function useDebounced<T>(value: T, ms = 300): T {
  const [v, setV] = useState(value);
  useEffect(() => { const t = setTimeout(() => setV(value), ms); return () => clearTimeout(t); }, [value, ms]);
  return v;
}

export function Projects({ query }: { query: URLSearchParams }) {
  const session = useSession();
  const [search, setSearch] = useState(query.get("search") ?? "");
  const [tagText, setTagText] = useState(query.get("tags") ?? "");
  const [backend, setBackend] = useState(query.get("backend") ?? "");
  const [classification, setClassification] = useState(query.get("classification") ?? "");
  const [cursors, setCursors] = useState<(string | null)[]>([null]);
  const debounced = useDebounced({ search, tagText, backend, classification });
  const tags = debounced.tagText.split(",").map((t) => t.trim()).filter(Boolean);
  const filterKey = JSON.stringify(debounced);
  useEffect(() => { setCursors([null]); }, [filterKey]);
  const cursor = cursors.at(-1) ?? null;
  const list = useQuery(`/api/v2/projects${qs({ search: debounced.search, tags: tags.join(","), backendId: debounced.backend, classification: debounced.classification, limit: PAGE, cursor })}`);
  const budgets = useQuery("/api/v2/budgets?limit=500");
  const inventory = useQuery("/api/v2/inventory");
  const used = useMemo(() => {
    const map = new Map<string, { pct: number; exhausted: boolean }>();
    const groups = budgets.data?.data?.groups ?? [];
    for (const g of groups) {
      const p = g.usedPercent === null ? null : Number(g.usedPercent);
      const cur = map.get(g.projectId);
      if (p !== null && (!cur || p > cur.pct)) map.set(g.projectId, { pct: p, exhausted: g.exhausted || cur?.exhausted || false });
    }
    return map;
  }, [budgets.data]);
  const backendOptions: string[] = inventory.data?.data?.backends?.map((b: any) => b.backendId) ?? [];
  const active = [search, tagText, backend, classification].filter(Boolean).length;
  const rows = list.data?.projects ?? [];

  return (
    <div className="page">
      <PageHeader title="Projects" subtitle="Search and filter run on the server; 25 projects a page." observedAt={list.observedAt} onRefresh={list.reload} busy={list.loading}
        actions={session.canWrite && <a className="btn btn-primary" href={href("/projects/new")}>New project</a>} />
      <div className="filter-bar" role="search" aria-label="Filter projects">
        <Field label="Search">{(id) => <input id={id} className="input" type="search" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Name or project ID" autoComplete="off" spellCheck={false} />}</Field>
        <Field label="Tags" hint="Comma-separated; all must match">{(id, d) => <input id={id} aria-describedby={d} className="input" value={tagText} onChange={(e) => setTagText(e.target.value)} placeholder="finance, pilot" autoComplete="off" />}</Field>
        <Field label="Backend">{(id) => (
          <>
            <input id={id} className="input" list={`${id}-list`} value={backend} onChange={(e) => setBackend(e.target.value)} placeholder="Any backend" autoComplete="off" spellCheck={false} />
            <datalist id={`${id}-list`}>{backendOptions.map((b) => <option key={b} value={b} />)}</datalist>
          </>
        )}</Field>
        <Field label="Classification">{(id) => <input id={id} className="input input-short" value={classification} onChange={(e) => setClassification(e.target.value.toUpperCase())} placeholder="STD" autoComplete="off" spellCheck={false} />}</Field>
        {active > 0 && <Button variant="quiet" size="small" onClick={() => { setSearch(""); setTagText(""); setBackend(""); setClassification(""); }}>Clear filters</Button>}
      </div>
      {list.error ? <ErrorNote error={list.error} retry={list.reload} /> : list.loading && !list.data ? <Loading rows={8} /> : (
        <div className={list.loading ? "is-refreshing" : undefined} aria-busy={list.loading}>
          <DataTable caption="Projects" rows={rows} rowKey={(r) => r.projectId} onRowClick={(r) => navigate(`/projects/${encodeURIComponent(r.projectId)}`)}
            empty={active ? <Empty title="No projects match these filters" action={<Button size="small" onClick={() => { setSearch(""); setTagText(""); setBackend(""); setClassification(""); }}>Clear filters</Button>}>Tags and backend match exactly; search matches names and IDs.</Empty>
              : <Empty title="No projects yet" action={session.canWrite ? <a className="btn btn-primary" href={href("/projects/new")}>Create the first project</a> : undefined}>A project groups access groups, their models, limits and budgets.</Empty>}
            columns={[
              { key: "displayName", label: "Project", render: (r) => <a href={href(`/projects/${encodeURIComponent(r.projectId)}`)} onClick={(e) => e.stopPropagation()} className="cell-primary"><span>{r.displayName}</span><span className="mono muted">{r.projectId}</span></a> },
              { key: "adminTags", label: "Tags", render: (r) => (r.adminTags ?? []).length ? <span className="tag-list">{r.adminTags.map((t: string) => <span key={t} className="tag">{t}</span>)}</span> : <span className="muted">—</span> },
              { key: "backendId", label: "Backend", render: (r) => <code>{r.backendId}</code> },
              { key: "classifications", label: "Classifications", render: (r) => Object.keys(r.classifications ?? {}).sort().join(", ") },
              { key: "budget", label: "Budget used", render: (r) => {
                const u = used.get(r.projectId);
                return u ? <span className="budget-cell"><Meter value={u.pct} max={100} label={`${pct(u.pct)} of budget used`} /><span>{pct(u.pct)}</span></span> : <span className="muted" title="No reconciler snapshot for this project">—</span>;
              } },
              { key: "status", label: "Status", render: (r) => <StatePill state={r.status === "active" ? "available" : r.status} label={r.status} /> },
            ]} />
          <nav className="pager" aria-label="Project pages">
            <span className="muted">Page {cursors.length}{rows.length ? ` · ${rows.length} project${rows.length === 1 ? "" : "s"}` : ""}</span>
            <div className="pager-buttons">
              <Button size="small" disabled={cursors.length === 1} onClick={() => setCursors(cursors.slice(0, -1))}>Previous</Button>
              <Button size="small" disabled={!list.data?.cursor} onClick={() => setCursors([...cursors, list.data.cursor])}>Next</Button>
            </div>
          </nav>
        </div>
      )}
    </div>
  );
}
