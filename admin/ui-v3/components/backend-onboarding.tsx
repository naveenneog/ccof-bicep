import { useState } from "react";
import { ApiFailure, api } from "../lib/api.ts";
import { onboardingBody, onboardingProblems, suggestBackendId } from "../lib/onboarding.ts";
import type { OnboardingDraft, OnboardingScope } from "../lib/onboarding.ts";
import { Button, DataTable, ErrorNote, Field, Section, StatePill } from "./ui.tsx";

// ADR 0040. Onboard a Foundry account that already exists, with its private endpoint and APIM roles in
// place: Check runs the read-only preflight, Onboard writes the APIM backend (every region), the
// gateway descriptor and the registry entry. Rerunning with the same values finishes a partial run.

interface Check { id: string; status: "pass" | "warn" | "fail"; detail: string }
interface Preflight { ok: boolean; checks: Check[]; endpoint: string | null }
interface Step { step: string; result: "created" | "exists" }

const EMPTY: OnboardingDraft = { foundryResourceId: "", backendId: "", displayName: "", deployments: "", inferenceGeo: "global" };
const CHECK_LABEL: Record<string, string> = { account_found: "Foundry account", deployments: "Deployments", network: "Private network", id_free: "Backend ID", plan: "Registry entry" };
const checkName = (id: string) => id.startsWith("roles:") ? `Gateway role (${id.split("/").pop()})` : CHECK_LABEL[id] ?? id;
const stepName = (s: string) => s.startsWith("apim:") ? `APIM backend in ${s.split("/").pop()}` : s === "descriptor" ? "Gateway descriptor" : "Registry entry";
const PILL = { pass: "available", warn: "warning", fail: "failed" } as const;

export function BackendOnboarding({ scope, onDone, onCancel }: { scope: OnboardingScope & { targets: string[] }; onDone: () => void; onCancel: () => void }) {
  const [d, setD] = useState<OnboardingDraft>(EMPTY);
  const [idTouched, setIdTouched] = useState(false);
  const [checked, setChecked] = useState<Preflight | null>(null);
  const [steps, setSteps] = useState<{ steps: Step[]; changed: boolean } | null>(null);
  const [busy, setBusy] = useState<"check" | "onboard" | null>(null);
  const [error, setError] = useState<unknown>(null);

  const problems = onboardingProblems(d, scope);
  const valid = !Object.keys(problems).length;
  const set = (patch: Partial<OnboardingDraft>) => { setD({ ...d, ...patch }); setChecked(null); setSteps(null); setError(null); };
  const setAccount = (v: string) => set({ foundryResourceId: v.trim(), ...(idTouched ? {} : { backendId: suggestBackendId(v) }) });

  const run = async (kind: "check" | "onboard") => {
    setBusy(kind); setError(null);
    try {
      const r = await api(kind === "check" ? "/api/v3/backend-onboarding/preflight" : "/api/v3/backend-onboarding", { method: "POST", body: onboardingBody(d) });
      if (kind === "check") setChecked(r.data);
      else { setSteps({ steps: r.data.steps, changed: r.data.changed }); onDone(); }
    } catch (e) {
      const body = e instanceof ApiFailure ? e.body : null;
      if (body?.preflight) setChecked(body.preflight as Preflight);
      if (Array.isArray(body?.steps)) setSteps({ steps: body.steps as Step[], changed: true });
      setError(e);
    } finally { setBusy(null); }
  };

  const regions = scope.targets.map((t) => t.split("/").pop()).join(" and ");
  return (
    <Section title="Onboard a Foundry account" description={<>For an account that already has its model deployments, an approved private endpoint and Cognitive Services User for the gateway identities. The console adds the backend to {regions || "the gateway"}, the gateway descriptor and the backend registry. No project uses it until an editor selects it.</>}>
      <fieldset className="form-grid" disabled={busy !== null}>
        <Field label="Foundry account resource ID" error={d.foundryResourceId ? problems.foundryResourceId : null}
          hint={<>Azure portal: the account's Overview → JSON View → Resource ID. Allowed: {[...scope.resourceIds, ...scope.discoveryScopes].join(", ") || "none configured"}.</>}>
          {(id, h) => <input id={id} aria-describedby={h} className="input mono" value={d.foundryResourceId} placeholder="/subscriptions/…/providers/Microsoft.CognitiveServices/accounts/…" onChange={(e) => setAccount(e.target.value)} />}</Field>
        <Field label="Backend ID" error={d.backendId ? problems.backendId : null} hint="Filled from the account name. Projects and APIM refer to the backend by this ID; it can't be changed later.">
          {(id, h) => <input id={id} aria-describedby={h} className="input mono" value={d.backendId} onChange={(e) => { setIdTouched(true); set({ backendId: e.target.value.trim() }); }} />}</Field>
        <Field label="Display name" hint="Optional; defaults to the account name." error={problems.displayName ?? null}>
          {(id, h) => <input id={id} aria-describedby={h} className="input" maxLength={120} value={d.displayName} onChange={(e) => set({ displayName: e.target.value })} />}</Field>
        <Field label="Deployments" hint="Optional, comma-separated; blank means every succeeded deployment on the account.">
          {(id, h) => <input id={id} aria-describedby={h} className="input mono" value={d.deployments} onChange={(e) => set({ deployments: e.target.value })} />}</Field>
        <Field label="Inference geography" hint="Fallbacks must match their primary.">{(id) => <select id={id} className="input" value={d.inferenceGeo} onChange={(e) => set({ inferenceGeo: e.target.value })}>
          {["global", "us", "eu"].map((g) => <option key={g} value={g}>{g}</option>)}</select>}</Field>
      </fieldset>
      {checked && <DataTable caption="Preflight checks" rows={checked.checks} rowKey={(r) => r.id} dense
        columns={[
          { key: "id", label: "Check", render: (r: Check) => checkName(r.id) },
          { key: "status", label: "Result", render: (r: Check) => <StatePill state={PILL[r.status]} label={r.status} /> },
          { key: "detail", label: "Detail" },
        ]} />}
      {steps && <DataTable caption={steps.changed ? "Onboarding steps" : "Already onboarded: nothing changed"} rows={steps.steps} rowKey={(r) => r.step} dense
        columns={[
          { key: "step", label: "Step", render: (r: Step) => stepName(r.step) },
          { key: "result", label: "Result", render: (r: Step) => <StatePill state={r.result === "created" ? "created" : "current"} label={r.result} /> },
        ]} />}
      {Boolean(error) && <ErrorNote error={error} />}
      <div className="form-actions">
        <Button variant={checked?.ok ? "default" : "primary"} disabled={!valid || busy !== null} busy={busy === "check"} onClick={() => run("check")}>Check</Button>
        <Button variant="primary" disabled={!valid || !checked?.ok || busy !== null} busy={busy === "onboard"} onClick={() => run("onboard")}>Onboard</Button>
        <Button variant="quiet" disabled={busy !== null} onClick={onCancel}>{steps && !error ? "Close" : "Cancel"}</Button>
      </div>
    </Section>
  );
}
