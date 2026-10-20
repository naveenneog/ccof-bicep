import { useState } from "react";
import { qs, useQuery } from "../lib/api.ts";
import { download, when } from "../lib/format.ts";
import { Button, ErrorNote, Field, Loading, Section, Segmented, StatePill } from "./ui.tsx";

// Project → client onboarding files. The server builds both files from the registry and the admin
// app's client settings; nothing here is secret. config.json is what the developer's CCOF helper
// reads; onboarding.json is the hand-out for whoever onboards the team.

const json = (v: unknown) => `${JSON.stringify(v, null, 2)}\n`;

export function OnboardingTab({ project, codes }: { project: any; codes: string[] }) {
  const [code, setCode] = useState(codes[0] ?? "");
  const [show, setShow] = useState<"config" | "onboarding">("config");
  const q = useQuery(code ? `/api/v3/projects/${encodeURIComponent(project.projectId)}/client-config${qs({ classification: code })}` : null);
  const d = q.data;
  const base = `${project.projectId}-${code}`.toLowerCase();

  if (!codes.length) return <Section title="Client onboarding"><p className="empty-inline">Add a classification first; the files are generated per classification.</p></Section>;
  return (
    <Section title="Client onboarding"
      description="Download the files a developer needs to connect Claude Code or Claude Desktop to this project through the gateway. They contain no tokens, keys or user lists.">
      <div className="breakdown-filters">
        <Field label="Classification" hint="Each classification has its own Entra group and models.">{(id, hint) => (
          <select id={id} aria-describedby={hint} className="input" value={code} onChange={(e) => setCode(e.target.value)}>
            {codes.map((c) => <option key={c} value={c}>{c}{project.classifications?.[c]?.classificationGroupDisplayName ? ` · ${project.classifications[c].classificationGroupDisplayName}` : ""}</option>)}
          </select>
        )}</Field>
      </div>
      {!d && !q.error ? <Loading rows={6} /> : q.error ? <ErrorNote error={q.error} retry={q.reload} /> : d && <>
        {d.complete
          ? <div className="notice notice-info" role="status"><StatePill state="complete" label="ready" /><div><p>Both files are complete for <strong>{project.projectId} · {code}</strong>.</p></div></div>
          : <div className="notice notice-warn" role="status"><div>
            <p><strong>Not ready to hand out.</strong> The admin app is missing {d.missing.length === 1 ? "a setting" : "settings"}: {d.missing.map((m: string) => <code key={m}>{m}</code>).reduce((a: any, b: any) => [a, ", ", b])}.</p>
            <p className="hint">The files use <code>REPLACE-…</code> placeholders there, and the client refuses them until they are replaced. Set the app settings (see Help) to generate complete files.</p>
          </div></div>}
        <div className="download-row">
          <Button variant="primary" icon="download" onClick={() => download(`config.json`, json(d.config), "application/json")}>Download config.json</Button>
          <Button icon="download" onClick={() => download(`${base}-onboarding.json`, json(d.onboarding), "application/json")}>Download onboarding.json</Button>
        </div>
        <div className="onboarding-grid">
          <div>
            <h3 className="subhead">Where config.json goes</h3>
            <dl className="facts">
              <div><dt>Windows</dt><dd><code>{d.onboarding.clientConfig.installPath.windows}</code></dd></div>
              <div><dt>macOS</dt><dd><code>{d.onboarding.clientConfig.installPath.macos}</code></dd></div>
              <div><dt>Linux</dt><dd><code>{d.onboarding.clientConfig.installPath.linux}</code></dd></div>
              <div><dt>Override</dt><dd>Set <code>CCOF_CONFIG_FILE</code> to an absolute path</dd></div>
            </dl>
            <h3 className="subhead">Steps</h3>
            <ol className="steps-list">{d.onboarding.steps.map((s: string) => <li key={s}>{s}</li>)}</ol>
            <p className="hint">Entra group: {d.onboarding.entraGroup.displayName ?? "—"} <code>{d.onboarding.entraGroup.objectId ?? "no group"}</code>. Generated {when(d.observedAt)}.</p>
          </div>
          <div>
            <div className="panel-head">
              <h3 className="subhead">Preview</h3>
              <Segmented label="Preview file" value={show} onChange={setShow}
                options={[{ value: "config", label: "config.json" }, { value: "onboarding", label: "onboarding.json" }]} />
            </div>
            <pre className="json-preview" tabIndex={0} aria-label={`${show}.json preview`}>{json(show === "config" ? d.config : d.onboarding)}</pre>
          </div>
        </div>
      </>}
    </Section>
  );
}
