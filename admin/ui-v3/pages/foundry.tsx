import { useState } from "react";
import { qs, useQuery } from "../lib/api.ts";
import { human } from "../lib/format.ts";
import { href } from "../lib/router.ts";
import { Button, CapabilityNotice, DataTable, ErrorNote, Loading, PageHeader, Section, StatePill } from "../components/ui.tsx";

const ok = (cap: any) => cap && (cap.state === "available" || cap.state === "partial");

function Deployments({ resourceId }: { resourceId: string }) {
  const q = useQuery(`/api/v2/deployments${qs({ resourceId })}`);
  if (q.loading && !q.data) return <Loading rows={2} />;
  if (q.error) return <ErrorNote error={q.error} />;
  if (!ok(q.data)) return <CapabilityNotice cap={q.data} what="Deployments" />;
  return <DataTable caption="Deployments" dense rows={q.data.data.deployments} empty={<p className="empty-inline">No model deployments.</p>} columns={[
    { key: "name", label: "Deployment", render: (d: any) => <code>{d.name}</code> }, { key: "model", label: "Model", render: (d: any) => <code>{d.model}</code> },
    { key: "state", label: "State", render: (d: any) => <StatePill state={d.state} /> },
  ]} />;
}

function LinkedProjects({ backendId }: { backendId: string }) {
  const q = useQuery(`/api/v2/projects${qs({ backendId, limit: 100 })}`);
  if (q.loading && !q.data) return <span className="muted">…</span>;
  const list: any[] = q.data?.projects ?? [];
  if (!list.length) return <span className="muted">none</span>;
  return <span className="tag-list">{list.slice(0, 8).map((p) => <a key={p.projectId} className="tag tag-link" href={href(`/projects/${encodeURIComponent(p.projectId)}`)}>{p.projectId}</a>)}{list.length > 8 && <span className="muted">+{list.length - 8}{q.data?.cursor ? "+" : ""}</span>}</span>;
}

export function Foundry() {
  const inv = useQuery("/api/v2/inventory");
  const [open, setOpen] = useState<string | null>(null);
  if (inv.loading && !inv.data) return <div className="page"><PageHeader title="Foundry" /><Loading rows={8} /></div>;
  const data = ok(inv.data) ? inv.data.data : null;
  const accounts = data ? data.resources.filter((r: any) => r.type === "Microsoft.CognitiveServices/accounts") : [];
  const apim = data ? data.resources.filter((r: any) => r.type === "Microsoft.ApiManagement/service") : [];
  const missing = accounts.filter((a: any) => a.lifecycle === "not_found");
  return (
    <div className="page">
      <PageHeader title="Foundry" subtitle="Accounts, gateway backends and model deployments, with the projects that route to each backend." observedAt={inv.observedAt} onRefresh={inv.reload} busy={inv.loading} />
      {inv.error ? <ErrorNote error={inv.error} retry={inv.reload} /> : !data ? <CapabilityNotice cap={inv.data} what="Resource inventory" /> : (
        <>
          {missing.length > 0 && (
            <div className="notice notice-danger" role="alert">
              <div><p><strong>{missing.length} configured Foundry account{missing.length === 1 ? " was" : "s were"} not found.</strong> Projects routed to {missing.length === 1 ? "its" : "their"} backends will fail.</p>
                {missing.map((m: any) => <p key={m.id}><code>{m.name}</code>: affected projects {m.backendIds.length ? m.backendIds.map((b: string) => <LinkedProjects key={b} backendId={b} />) : <LinkedProjects backendId={m.name} />}</p>)}</div>
            </div>
          )}
          {data.truncated && <p className="notice notice-warn">The inventory is partial: some resources could not be read. {data.warnings.join(" ")}</p>}
          <Section title="Foundry accounts" description="Select an account to list its model deployments.">
            <DataTable caption="Foundry accounts" rows={accounts} rowKey={(r) => r.id} columns={[
              { key: "name", label: "Account", render: (r: any) => <><strong>{r.name}</strong><span className="block muted mono small">{r.id.split("/resourceGroups/")[1]?.split("/")[0]}</span></> },
              { key: "region", label: "Region" },
              { key: "lifecycle", label: "Lifecycle", render: (r: any) => <StatePill state={r.lifecycle} /> },
              { key: "provisioningState", label: "Provisioning", render: (r: any) => <StatePill state={r.provisioningState} /> },
              { key: "publicNetworkAccess", label: "Public access", render: (r: any) => human(r.publicNetworkAccess) },
              { key: "backendIds", label: "Backends", render: (r: any) => r.backendIds.length ? r.backendIds.map((b: string) => <code key={b} className="block">{b}</code>) : <span className="muted">none matched</span> },
              { key: "deployments", label: "Deployments", render: (r: any) => r.lifecycle === "observed" ? <Button size="small" aria-expanded={open === r.id} onClick={() => setOpen(open === r.id ? null : r.id)}>{open === r.id ? "Hide" : "Show"}</Button> : <span className="muted">—</span> },
            ]} />
            {open && <div className="subpanel"><h3>Deployments in {open.split("/").at(-1)}</h3><Deployments resourceId={open} /></div>}
          </Section>
          <Section title="Gateway backends" description="APIM backends and the projects routed to each. A project's backend is set in its settings.">
            <DataTable caption="Gateway backends" rows={data.backends} rowKey={(r) => r.backendId} columns={[
              { key: "backendId", label: "Backend ID", render: (r: any) => <code>{r.backendId}</code> },
              { key: "host", label: "Host", render: (r: any) => r.host ? <code className="wrap">{r.host}</code> : <span className="muted">invalid URL</span> },
              { key: "account", label: "Account", render: (r: any) => { const a = accounts.find((x: any) => x.backendIds.includes(r.backendId)); return a ? <span>{a.name} <StatePill state={a.lifecycle} /></span> : <span className="muted">not matched</span>; } },
              { key: "projects", label: "Projects", render: (r: any) => <LinkedProjects backendId={r.backendId} /> },
            ]} />
          </Section>
          <Section title="API Management">
            <DataTable caption="API Management" rows={apim} rowKey={(r) => r.id} dense columns={[
              { key: "name", label: "Instance", render: (r: any) => <strong>{r.name}</strong> }, { key: "region", label: "Region" },
              { key: "provisioningState", label: "Provisioning", render: (r: any) => <StatePill state={r.provisioningState} /> },
              { key: "publicNetworkAccess", label: "Public access", render: (r: any) => human(r.publicNetworkAccess) },
            ]} />
          </Section>
        </>
      )}
    </div>
  );
}
