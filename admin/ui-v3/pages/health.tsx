import { useQuery } from "../lib/api.ts";
import { ago, human, int, when } from "../lib/format.ts";
import { CapabilityNotice, DataTable, ErrorNote, Loading, PageHeader, Section, StatePill } from "../components/ui.tsx";
import { useSession } from "../components/shell.tsx";

const ok = (cap: any) => cap && (cap.state === "available" || cap.state === "partial");
const FEATURE_LABEL: Record<string, string> = {
  projects: "Project registry (Cosmos DB)", chargeback: "Chargeback (gateway telemetry)", reconciler: "Reconciler logs", audit: "Audit logs",
  queries: "Packaged KQL", catalogStore: "Cost definitions store",
};

export function Health() {
  const session = useSession();
  const probes = useQuery("/api/v2/health");
  const runs = useQuery("/api/v3/reconciler/runs");
  const coverage = useQuery("/api/v3/chargeback/coverage?period=month");
  const version = useQuery("/api/v3/version");
  const reload = () => [probes, runs, coverage].forEach((q) => q.reload());
  const written = ok(runs.data) ? runs.data.data.rows.find((r: any) => r.outcome === "written") : null;
  const cov = ok(coverage.data) ? coverage.data.data.rows[0] : null;
  return (
    <div className="page">
      <PageHeader title="Health" subtitle="Separate signals, each with its own observation time. One healthy signal doesn't imply the others." observedAt={probes.observedAt} onRefresh={reload} busy={probes.loading} />
      <div className="signal-grid">
        <section className="panel signal">
          <h2>Reconciler freshness</h2>
          {runs.loading && !runs.data ? <Loading rows={2} /> : !ok(runs.data) ? <p className="muted">{human(runs.data?.state ?? "unavailable")}: {runs.data?.reason}</p> : written
            ? <><p className="signal-value"><StatePill state={written.freshness} /> last wrote {ago(written.latestRunAt)}</p><p className="hint">Timer every {runs.data.data.intervalMinutes} min · {int(written.statesWritten)} states · read {when(runs.data.data.observedAt)}</p></>
            : <p className="signal-value"><StatePill state="stale" label="no written run" /></p>}
        </section>
        <section className="panel signal">
          <h2>Telemetry freshness</h2>
          {coverage.loading && !coverage.data ? <Loading rows={2} /> : !ok(coverage.data) ? <p className="muted">{human(coverage.data?.state ?? "unavailable")}: {coverage.data?.reason}</p> : cov
            ? <><p className="signal-value"><StatePill state={cov.reportState} /> latest request {ago(cov.latestRequest)}</p><p className="hint">Request to ingestion up to {cov.requestToIngestSeconds ?? "—"} s · {int(cov.noUsageRequests)} requests without usage · read {when(coverage.data.data.observedAt)}</p></>
            : <p className="muted">No data.</p>}
        </section>
        <section className="panel signal">
          <h2>Admin app</h2>
          <p className="signal-value">Version <strong>{version.data?.version ?? "—"}</strong></p>
          <p className="hint">Consoles: {(version.data?.consoles ?? []).join(" and ")} · you are {session.canWrite ? "an editor" : "a reader"}</p>
        </section>
      </div>
      <Section title="Endpoint probes" description="An HTTP response from each configured endpoint. It doesn't prove model inference, billing or timer freshness.">
        {probes.loading && !probes.data ? <Loading rows={3} /> : probes.error ? <ErrorNote error={probes.error} retry={probes.reload} /> : !ok(probes.data) ? <CapabilityNotice cap={probes.data} what="Endpoint probes" />
          : <DataTable caption="Endpoint probes" rows={probes.data.data} rowKey={(r) => r.name} columns={[
            { key: "name", label: "Endpoint", render: (r: any) => <strong>{r.name}</strong> },
            { key: "state", label: "State", render: (r: any) => <StatePill state={r.state} /> },
            { key: "httpStatus", label: "HTTP", align: "end", render: (r: any) => r.httpStatus ?? "—" },
            { key: "reason", label: "Detail", render: (r: any) => r.reason ? <code>{r.reason}</code> : <span className="muted">{r.evidence ?? "—"}</span> },
            { key: "observedAt", label: "Observed", render: (r: any) => ago(r.observedAt) },
          ]} />}
      </Section>
      <Section title="Integrations" description="Which optional features this admin app is configured for. Each one missing disables only its own feature.">
        <DataTable caption="Integrations" rows={Object.entries(session.features).map(([k, v]) => ({ k, v }))} rowKey={(r) => r.k} columns={[
          { key: "k", label: "Feature", render: (r: any) => FEATURE_LABEL[r.k] ?? r.k },
          { key: "v", label: "State", render: (r: any) => <StatePill state={r.v === "configured" || r.v === "packaged" ? "configured" : "disabled"} label={human(r.v)} /> },
        ]} />
      </Section>
    </div>
  );
}
