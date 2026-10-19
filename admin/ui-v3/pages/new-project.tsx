import { useState } from "react";
import { api, errorMessage, useQuery } from "../lib/api.ts";
import { int, usd } from "../lib/format.ts";
import { href, navigate } from "../lib/router.ts";
import { Button, Empty, ErrorNote, Field, PageHeader, Section, Segmented, useToast } from "../components/ui.tsx";
import { BudgetAssistant } from "../components/budget-assistant.tsx";
import { FAMILY_ORDER, LimitsEditor, emptyLimit, useCatalogModels } from "../components/limits.tsx";
import type { FamilyPolicy } from "../components/limits.tsx";
import { useSession } from "../components/shell.tsx";
import { applyPatch } from "./project-detail.tsx";

const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STEPS = ["Basics", "Access groups", "Models & budget", "Review"];

interface Group { code: string; groupId: string; groupName: string; onboardingMode: "block" | "warn"; aggregateMode: "strict" | "notify";
  personBudget: { amount: number; currency: "USD" | "CCU"; period: "monthly" }; aggregateBudget: { amount: number; currency: "USD" | "CCU"; period: "monthly" } | null; policy: FamilyPolicy }

const newPolicy = (catalog: Record<string, string[]>): FamilyPolicy => ({
  aggregateLimits: { person: emptyLimit(), group: emptyLimit() },
  families: catalog.sonnet?.length ? { sonnet: { models: [catalog.sonnet[0]], person: emptyLimit(), group: emptyLimit() } } : {},
});

export function NewProject() {
  const session = useSession();
  const toast = useToast();
  const catalog = useCatalogModels();
  const inventory = useQuery("/api/v2/inventory");
  const [step, setStep] = useState(0);
  const [basics, setBasics] = useState({ projectId: "", displayName: "", backendId: "", designatedSubscriptionId: "", tags: "" });
  const [groups, setGroups] = useState<Group[]>([]);
  const [active, setActive] = useState(0);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [saveError, setSaveError] = useState<unknown>(null);
  const [note, setNote] = useState<string | null>(null);
  if (!session.canWrite) return <div className="page"><PageHeader title="New project" /><Empty title="Read-only access">Creating projects needs the CCOF.Projects.Write role.</Empty></div>;
  const backends: string[] = inventory.data?.data?.backends?.map((b: any) => b.backendId) ?? [];

  const addGroup = () => {
    const code = ["STD", "INT", "CYB", "EXT"].find((c) => !groups.some((g) => g.code === c)) ?? "";
    setGroups([...groups, { code, groupId: "", groupName: basics.projectId ? `${basics.projectId}-${code}` : "", onboardingMode: "block", aggregateMode: "strict",
      personBudget: { amount: 25, currency: "USD", period: "monthly" }, aggregateBudget: { amount: 500, currency: "USD", period: "monthly" }, policy: newPolicy(catalog) }]);
    setActive(groups.length);
  };
  const setGroup = (i: number, patch: Partial<Group>) => setGroups(groups.map((g, j) => j === i ? { ...g, ...patch } : g));

  const validate = (s: number): boolean => {
    const e: Record<string, string> = {};
    if (s === 0) {
      if (!ID.test(basics.projectId)) e.projectId = "Letters, digits, - and _ only; start with a letter or digit; up to 80.";
      if (!basics.displayName.trim()) e.displayName = "Give the project a name.";
      if (!ID.test(basics.backendId)) e.backendId = "Enter the APIM backend ID the project routes to.";
      if (!GUID.test(basics.designatedSubscriptionId)) e.designatedSubscriptionId = "A subscription ID (GUID).";
    }
    if (s === 1) {
      if (!groups.length) e.groups = "Add at least one access group.";
      const seen = new Set<string>();
      groups.forEach((g, i) => {
        if (!ID.test(g.code) || seen.has(g.code)) e[`code${i}`] = "A unique classification code, for example STD.";
        seen.add(g.code);
        if (!GUID.test(g.groupId)) e[`group${i}`] = "The Entra group's Object ID (GUID).";
        if (groups.some((o, j) => j !== i && o.groupId.toLowerCase() === g.groupId.toLowerCase() && g.groupId)) e[`group${i}`] = "Each classification needs its own group.";
      });
    }
    if (s === 2) groups.forEach((g, i) => { if (!Object.keys(g.policy.families).length) e[`fam${i}`] = "Admit at least one model family."; });
    setErrors(e);
    return Object.keys(e).length === 0;
  };
  const next = () => { if (validate(step)) setStep(step + 1); };
  const tags = basics.tags.split(",").map((t) => t.trim()).filter(Boolean);
  const doc = {
    id: basics.projectId, projectId: basics.projectId, displayName: basics.displayName.trim(), status: "active", backendId: basics.backendId,
    designatedSubscriptionId: basics.designatedSubscriptionId.toLowerCase(), supersedes: null, retiredAt: null, ...(tags.length ? { adminTags: tags } : {}),
    classifications: Object.fromEntries(groups.map((g) => [g.code, {
      groupId: g.groupId.toLowerCase(), ...(g.groupName.trim() ? { classificationGroupDisplayName: g.groupName.trim() } : {}),
      familyPolicy: g.policy, personBudget: g.personBudget, aggregateBudget: g.aggregateBudget, aggregateMode: g.aggregateMode, onboardingMode: g.onboardingMode,
    }])),
  };
  const create = async () => {
    setBusy(true); setSaveError(null);
    try {
      await api("/api/projects", { method: "POST", body: doc });
      toast(`Created ${basics.projectId}. Developers get access after the next entitlement sync.`);
      navigate(`/projects/${encodeURIComponent(basics.projectId)}`);
    } catch (e) { setSaveError(e); } finally { setBusy(false); }
  };
  const g = groups[active];

  return (
    <div className="page">
      <PageHeader title="New project" subtitle="Four steps. Nothing is saved until you create the project on the last step." />
      <ol className="stepper" aria-label="Steps">
        {STEPS.map((s, i) => (
          <li key={s} className={i === step ? "is-current" : i < step ? "is-done" : undefined} aria-current={i === step ? "step" : undefined}>
            <button type="button" disabled={i > step} onClick={() => setStep(i)}><span className="step-num" aria-hidden="true">{i + 1}</span>{s}</button>
          </li>
        ))}
      </ol>
      {step === 0 && (
        <Section title="Basics">
          <div className="form-grid">
            <Field label="Project ID" hint="Permanent. Used in limits, budgets and chargeback." error={errors.projectId}>{(id, d) => <input id={id} aria-describedby={d} aria-invalid={Boolean(errors.projectId)} className="input mono" value={basics.projectId} onChange={(e) => setBasics({ ...basics, projectId: e.target.value })} autoComplete="off" spellCheck={false} />}</Field>
            <Field label="Display name" error={errors.displayName}>{(id, d) => <input id={id} aria-describedby={d} aria-invalid={Boolean(errors.displayName)} className="input" value={basics.displayName} maxLength={200} onChange={(e) => setBasics({ ...basics, displayName: e.target.value })} />}</Field>
            <Field label="Foundry backend" hint={backends.length ? "From the APIM inventory." : "Type the APIM backend ID."} error={errors.backendId}>{(id, d) => (
              <><input id={id} aria-describedby={d} aria-invalid={Boolean(errors.backendId)} className="input mono" list={`${id}-l`} value={basics.backendId} onChange={(e) => setBasics({ ...basics, backendId: e.target.value })} autoComplete="off" spellCheck={false} />
                <datalist id={`${id}-l`}>{backends.map((b) => <option key={b} value={b} />)}</datalist></>
            )}</Field>
            <Field label="Designated subscription ID" error={errors.designatedSubscriptionId}>{(id, d) => <input id={id} aria-describedby={d} aria-invalid={Boolean(errors.designatedSubscriptionId)} className="input mono" value={basics.designatedSubscriptionId} onChange={(e) => setBasics({ ...basics, designatedSubscriptionId: e.target.value.trim() })} autoComplete="off" spellCheck={false} />}</Field>
            <Field label="Tags" hint="Optional, comma-separated.">{(id, d) => <input id={id} aria-describedby={d} className="input" value={basics.tags} onChange={(e) => setBasics({ ...basics, tags: e.target.value })} />}</Field>
          </div>
        </Section>
      )}
      {step === 1 && (
        <Section title="Access groups" description="One Entra security group per classification. Members get that classification's models, limits and budgets."
          actions={<Button icon="plus" onClick={addGroup}>Add access group</Button>}>
          {errors.groups && <p className="field-error" role="alert">{errors.groups}</p>}
          {!groups.length ? <Empty title="No access groups yet" action={<Button variant="primary" icon="plus" onClick={addGroup}>Add access group</Button>}>Most projects start with one standard group, STD.</Empty> : (
            <div className="group-rows">
              {groups.map((grp, i) => (
                <fieldset key={i} className="fieldset group-row">
                  <legend>Access group {i + 1}</legend>
                  <Field label="Classification" error={errors[`code${i}`]}>{(id, d) => <input id={id} aria-describedby={d} aria-invalid={Boolean(errors[`code${i}`])} className="input input-short mono" value={grp.code} onChange={(e) => setGroup(i, { code: e.target.value.toUpperCase() })} />}</Field>
                  <Field label="Entra group Object ID" error={errors[`group${i}`]}>{(id, d) => <input id={id} aria-describedby={d} aria-invalid={Boolean(errors[`group${i}`])} className="input mono" value={grp.groupId} placeholder="00000000-0000-0000-0000-000000000000" onChange={(e) => setGroup(i, { groupId: e.target.value.trim() })} />}</Field>
                  <Field label="Group name (snapshot)">{(id) => <input id={id} className="input" value={grp.groupName} onChange={(e) => setGroup(i, { groupName: e.target.value })} />}</Field>
                  <Field label="Onboarding">{(id) => <select id={id} className="input" value={grp.onboardingMode} onChange={(e) => setGroup(i, { onboardingMode: e.target.value as "block" | "warn" })}><option value="block">Block until synced</option><option value="warn">Warn only</option></select>}</Field>
                  <Button variant="quiet" size="small" onClick={() => { setGroups(groups.filter((_, j) => j !== i)); setActive(0); }}>Remove</Button>
                </fieldset>
              ))}
            </div>
          )}
        </Section>
      )}
      {step === 2 && g && (
        <div className="stack">
          {groups.length > 1 && <Segmented label="Access group" value={String(active)} onChange={(v) => setActive(Number(v))} options={groups.map((x, i) => ({ value: String(i), label: x.code }))} />}
          <Section title={`Budgets for ${g.code}`}>
            <div className="row-fields">
              <Field label="Person budget (monthly)" hint={g.personBudget.currency === "USD" ? `= ${int(g.personBudget.amount * 100)} CCU` : `= ${usd(g.personBudget.amount / 100)}`}>{(id, d) => (
                <div className="input-group"><input id={id} aria-describedby={d} className="input input-num" inputMode="decimal" value={g.personBudget.amount} onChange={(e) => setGroup(active, { personBudget: { ...g.personBudget, amount: Number(e.target.value) || 0 } })} />
                  <select className="input" aria-label="Person budget unit" value={g.personBudget.currency} onChange={(e) => setGroup(active, { personBudget: { ...g.personBudget, currency: e.target.value as "USD" | "CCU" } })}><option>USD</option><option>CCU</option></select></div>
              )}</Field>
              <Field label="Group budget (monthly)" hint={g.aggregateBudget === null ? "No cap" : undefined}>{(id, d) => (
                <div className="input-group"><input id={id} aria-describedby={d} className="input input-num" inputMode="decimal" disabled={g.aggregateBudget === null} value={g.aggregateBudget?.amount ?? ""} onChange={(e) => setGroup(active, { aggregateBudget: { ...(g.aggregateBudget ?? { currency: "USD", period: "monthly" }), amount: Number(e.target.value) || 0 } as Group["aggregateBudget"] })} />
                  <select className="input" aria-label="Group budget unit" value={g.aggregateBudget?.currency ?? "none"} onChange={(e) => setGroup(active, { aggregateBudget: e.target.value === "none" ? null : { amount: g.aggregateBudget?.amount ?? 500, currency: e.target.value as "USD" | "CCU", period: "monthly" } })}><option>USD</option><option>CCU</option><option value="none">No cap</option></select></div>
              )}</Field>
              <Field label="Group mode">{(id) => <select id={id} className="input" value={g.aggregateMode} onChange={(e) => setGroup(active, { aggregateMode: e.target.value as "strict" | "notify" })}><option value="strict">Strict</option><option value="notify">Notify only</option></select>}</Field>
            </div>
          </Section>
          <Section title={`Models and limits for ${g.code}`}>
            {errors[`fam${active}`] && <p className="field-error" role="alert">{errors[`fam${active}`]}</p>}
            {note && <p className="notice notice-info" role="status">{note}</p>}
            <LimitsEditor policy={g.policy} classification={g.code} onChange={(p) => setGroup(active, { policy: p })} />
          </Section>
          <Section title="Budget assistant" description="Suggests quotas and TPM from a monthly budget; Apply fills the limits above for review.">
            <BudgetAssistant key={`${active}-${Object.keys(g.policy.families).join()}`} families={FAMILY_ORDER.filter((f) => g.policy.families[f]).map((f) => ({ family: f, models: g.policy.families[f].models }))}
              defaultMembers={10} applyLabel={`Apply to ${g.code} limits`}
              onApply={(patch, summary) => { setGroup(active, { policy: applyPatch(g.policy, patch) }); setNote(`Limits filled from the budget assistant (${summary}). Check them before you continue.`); }} />
          </Section>
        </div>
      )}
      {step === 3 && (
        <Section title="Review" description="This is the document that will be saved to the registry.">
          <dl className="facts facts-wide">
            <div><dt>Project</dt><dd><strong>{doc.displayName}</strong> <span className="mono muted">{doc.projectId}</span></dd></div>
            <div><dt>Backend</dt><dd><code>{doc.backendId}</code></dd></div>
            <div><dt>Subscription</dt><dd className="mono wrap">{doc.designatedSubscriptionId}</dd></div>
            <div><dt>Tags</dt><dd>{tags.join(", ") || "—"}</dd></div>
            {groups.map((x) => (
              <div key={x.code}><dt>{x.code}</dt><dd>
                <code className="wrap">{x.groupId}</code> · {Object.keys(x.policy.families).join(", ")} · person {x.personBudget.amount} {x.personBudget.currency} · group {x.aggregateBudget ? `${x.aggregateBudget.amount} ${x.aggregateBudget.currency}` : "no cap"} ({x.aggregateMode})
              </dd></div>
            ))}
          </dl>
          <details className="data-table"><summary>Document (JSON)</summary><pre className="code-block">{JSON.stringify(doc, null, 2)}</pre></details>
          {saveError ? <ErrorNote error={saveError} /> : null}
        </Section>
      )}
      <div className="form-actions stepper-actions">
        {step > 0 && <Button onClick={() => setStep(step - 1)} disabled={busy}>Back</Button>}
        {step < 3 && <Button variant="primary" onClick={next} disabled={step === 2 && !groups.length}>Continue</Button>}
        {step === 3 && <Button variant="primary" onClick={create} busy={busy}>Create project</Button>}
        <a className="btn btn-quiet" href={href("/projects")}>Cancel</a>
        {Object.keys(errors).length > 0 && <span className="field-error" role="alert">{Object.keys(errors).length} field{Object.keys(errors).length === 1 ? " needs" : "s need"} attention</span>}
      </div>
      {saveError && (saveError as any).problems?.length ? <p className="hint">{errorMessage(saveError)}</p> : null}
    </div>
  );
}
