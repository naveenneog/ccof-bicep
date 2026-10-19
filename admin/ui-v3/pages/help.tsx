import { HELP } from "../help.ts";
import { href } from "../lib/router.ts";
import { DataTable, PageHeader, Section } from "../components/ui.tsx";

const PERMISSIONS = [
  { feature: "Projects, limits, budgets", needs: "Cosmos DB data role on the projects container (COSMOS_ENDPOINT, COSMOS_DATABASE)", without: "Console unavailable" },
  { feature: "Chargeback, Overview cost", needs: "Log Analytics Reader on the gateway telemetry workspace; ADMIN_GATEWAY_RESOURCE_ID", without: "Chargeback shows its capability state" },
  { feature: "Budgets, reconciler", needs: "Log Analytics Reader on ADMIN_WORKSPACE_ID; ADMIN_LOG_RESOURCE_IDS or ADMIN_RECONCILER_RESOURCE_ID", without: "Budget and reconciler panels disabled" },
  { feature: "Audit, activity", needs: "Log Analytics Reader on the admin app's workspace (ADMIN_AUDIT_WORKSPACE_ID)", without: "Audit disabled" },
  { feature: "Foundry inventory", needs: "Reader on APIM and Foundry accounts (ADMIN_RESOURCE_IDS or ADMIN_DISCOVERY_SCOPES)", without: "Inventory disabled; type backend IDs by hand" },
  { feature: "Group search", needs: "Microsoft Graph GroupMember.Read.All with tenant-admin consent (ADMIN_GRAPH_ENABLED)", without: "Paste Object IDs" },
  { feature: "Billed cost", needs: "Cost Management Reader on ADMIN_COST_SCOPE", without: "Billed cost disabled" },
  { feature: "Saving cost definitions", needs: "ADMIN_CONFIG_CONTAINER and a scoped Cosmos data role; CCOF.Projects.Write", without: "Rate card read-only (packaged)" },
  { feature: "Budget assistant", needs: "None", without: "Always available" },
];

export function HelpPage() {
  return (
    <div className="page">
      <PageHeader title="Help" subtitle="Every page has the same help in the Help drawer (top bar). Here it is all in one place." />
      <nav className="help-index" aria-label="Help topics">
        <ul>{Object.entries(HELP).filter(([k]) => k !== "help").map(([k, t]) => <li key={k}><a href={`#/help`} onClick={(e) => { e.preventDefault(); document.getElementById(`help-${k}`)?.scrollIntoView({ behavior: "smooth" }); }}>{t.title}</a></li>)}</ul>
      </nav>
      <Section title="Permissions" description="All optional except the registry. Each missing one disables only its own feature." id="perm">
        <DataTable caption="Permissions matrix" rows={PERMISSIONS} rowKey={(r) => r.feature} columns={[
          { key: "feature", label: "Feature", render: (r) => <strong>{r.feature}</strong> }, { key: "needs", label: "Admin app identity needs" }, { key: "without", label: "Without it" },
        ]} />
        <p className="hint">People: reading needs the CCOF.Projects.Read app role (or ADMIN_READER_IDS); changes need CCOF.Projects.Write (or ADMIN_EDITOR_IDS).</p>
      </Section>
      {Object.entries(HELP).filter(([k]) => k !== "help").map(([k, t]) => (
        <section key={k} id={`help-${k}`} className="section help-topic" aria-labelledby={`help-${k}-t`}>
          <h2 id={`help-${k}-t`}>{t.title}</h2>
          <p className="prose">{t.summary}</p>
          {t.figures && <dl className="help-dl">{t.figures.map(([a, b]) => <div key={a}><dt>{a}</dt><dd>{b}</dd></div>)}</dl>}
          {t.troubleshooting && <dl className="help-dl">{t.troubleshooting.map(([a, b]) => <div key={a}><dt>{a}</dt><dd>{b}</dd></div>)}</dl>}
        </section>
      ))}
      <Section title="Runbooks" description="In the repository's docs folder.">
        <ul className="prose-list">
          <li><code>docs/ADMIN-V3.md</code>: settings, permissions, deploying and upgrading from the VDI, redirect URI, the V3 flag and rollback to V2.</li>
          <li><code>docs/ADMIN-V2.md</code>: the V2 console, still available at <a href="/api/console">/api/console</a>.</li>
          <li><code>docs/CHARGEBACK.md</code>: how chargeback is calculated; the workbook and this console share one query builder.</li>
          <li><a href={href("/cost-definitions")}>Cost definitions</a>: the rate card in USD and CCU.</li>
        </ul>
      </Section>
    </div>
  );
}
