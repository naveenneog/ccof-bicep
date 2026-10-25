import { useEffect, useMemo, useState } from "react";
import { api, errorMessage, useQuery } from "../lib/api.ts";
import { int, usd } from "../lib/format.ts";
import { Button, DataTable, ErrorNote, Field, Loading, Segmented } from "./ui.tsx";
import { limitsFromPlan } from "../lib/planner.ts";
import type { LimitsPatch } from "../lib/planner.ts";
import type { Plan } from "../../src/token-planner.ts";
import type { PlanModel } from "../../src/rate-cards.ts";
export type { Limit, LimitsPatch } from "../lib/planner.ts";
export interface PlannerBudget { amount: number; currency: "USD" | "CCU"; period: "monthly" }
interface PlanResponse { plan: Plan; budgetUsd: string; groupBudgetUsd: string | null; rateCardVersion: string; geoMultiplier: string }

function Slider({ label, value, onChange, min = 0, max = 100, step = 1, suffix = "%", hint }: { label: string; value: number; onChange: (v: number) => void; min?: number; max?: number; step?: number; suffix?: string; hint?: string }) {
  return (
    <Field label={<span className="slider-label"><span>{label}</span><output>{value}{suffix}</output></span>} hint={hint}>
      {(id, d) => <input id={id} aria-describedby={d} type="range" className="range" min={min} max={max} step={step} value={value}
        aria-valuetext={`${value}${suffix}`} onChange={(e) => onChange(Number(e.target.value))} />}
    </Field>
  );
}

// Rebalance a family split so it always totals 100: the changed family keeps its value; the rest share the remainder.
function rebalance(split: Record<string, number>, changed: string, value: number): Record<string, number> {
  const others = Object.keys(split).filter((k) => k !== changed);
  if (!others.length) return { [changed]: 100 };
  const rest = 100 - value;
  const prior = others.reduce((s, k) => s + split[k], 0);
  const next: Record<string, number> = { [changed]: value };
  let assigned = 0;
  others.forEach((k, i) => {
    const v = i === others.length - 1 ? rest - assigned : Math.round(prior > 0 ? (split[k] / prior) * rest : rest / others.length);
    next[k] = Math.max(0, v); assigned += next[k];
  });
  return next;
}

export function BudgetAssistant({ families, initialBudget, initialGroupBudget, onApply, applyLabel = "Apply to limits" }: {
  families: { family: string; models: string[] }[]; initialBudget?: PlannerBudget; initialGroupBudget?: PlannerBudget | null;
  onApply?: (patch: LimitsPatch, summary: string, budgets: { personBudget: PlannerBudget; groupBudget: PlannerBudget | null }) => void; applyLabel?: string;
}) {
  const options = useQuery<{ models: PlanModel[] }>("/api/v3/plan");
  const plannable = useMemo(() => families.filter((f) => ["haiku", "sonnet", "opus", "fable", "mythos"].includes(f.family)), [families]);
  const [amount, setAmount] = useState(String(initialBudget?.amount ?? 100));
  const [currency, setCurrency] = useState<"USD" | "CCU">(initialBudget?.currency ?? "USD");
  const [withGroup, setWithGroup] = useState(Boolean(initialGroupBudget));
  const [groupAmount, setGroupAmount] = useState(String(initialGroupBudget?.amount ?? 500));
  const [groupCurrency, setGroupCurrency] = useState<"USD" | "CCU">(initialGroupBudget?.currency ?? "USD");
  const [geography, setGeography] = useState("global");
  const [sizing, setSizing] = useState<"expected" | "guaranteed">("guaranteed");
  const [mix, setMix] = useState({ outputPercentOfTokens: 20, cacheReadPercentOfInput: 50, cacheWrite5mPercentOfInput: 10, cacheWrite1hPercentOfInput: 0 });
  const [split, setSplit] = useState<Record<string, number>>({});
  const [models, setModels] = useState<Record<string, string>>({});
  const [days, setDays] = useState(22);
  const [hours, setHours] = useState(8);
  const [burst, setBurst] = useState(3);
  const [response, setResponse] = useState<{ key: string; data: PlanResponse } | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { setAmount(String(initialBudget?.amount ?? 100)); setCurrency(initialBudget?.currency ?? "USD"); }, [initialBudget?.amount, initialBudget?.currency]);
  useEffect(() => {
    setWithGroup(Boolean(initialGroupBudget)); setGroupAmount(String(initialGroupBudget?.amount ?? 500));
    setGroupCurrency(initialGroupBudget?.currency ?? "USD");
  }, [initialGroupBudget?.amount, initialGroupBudget?.currency]);

  const familyKey = plannable.map((f) => f.family).join(",");
  useEffect(() => {
    const n = plannable.length;
    if (!n) return;
    const even = Math.floor(100 / n);
    setSplit(Object.fromEntries(plannable.map((f, i) => [f.family, i === 0 ? 100 - even * (n - 1) : even])));
  }, [familyKey]);
  useEffect(() => {
    const list = options.data?.models ?? [];
    if (!list.length) return;
    setModels((cur) => Object.fromEntries(plannable.map((f) => {
      const priced = list.filter((m) => m.family === f.family);
      const admitted = priced.find((m) => f.models.includes(m.model));
      return [f.family, cur[f.family] && priced.some((m) => m.model === cur[f.family]) ? cur[f.family] : (admitted ?? priced[0])?.model ?? ""];
    })));
  }, [options.data, familyKey]);

  const cacheTotal = mix.cacheReadPercentOfInput + mix.cacheWrite5mPercentOfInput + mix.cacheWrite1hPercentOfInput;
  const body = useMemo(() => ({
    budgetBasis: "person", monthlyBudget: { amount: amount.trim(), currency },
    groupMonthlyBudget: withGroup ? { amount: groupAmount.trim(), currency: groupCurrency } : null, geography, sizing, mix,
    families: plannable.map((f) => ({ family: f.family, model: models[f.family], budgetPercent: split[f.family] ?? 0 })),
    workingDaysPerMonth: days, workingHoursPerDay: hours, burstFactor: burst,
  }), [amount, currency, withGroup, groupAmount, groupCurrency, geography, sizing, mix, plannable, models, split, days, hours, burst]);
  const requestKey = JSON.stringify(body);
  const result = response?.key === requestKey ? response.data : null;

  useEffect(() => {
    setResponse(null); setError(null); setBusy(false);
    if (!body.families.length || body.families.some((f) => !f.model)) { setError(new Error("Every admitted family needs an in-force model price before limits can be applied.")); return; }
    if (!/^\d{1,9}(\.\d{1,6})?$/.test(body.monthlyBudget.amount) || Number(body.monthlyBudget.amount) <= 0 ||
      withGroup && (!/^\d{1,9}(\.\d{1,6})?$/.test(groupAmount.trim()) || Number(groupAmount) <= 0)) {
      setError(new Error("Enter a budget greater than zero for each enabled scope.")); return;
    }
    if (cacheTotal > 100) { setError(new Error("Cache shares add up to more than 100 % of input.")); return; }
    const controller = new AbortController();
    setBusy(true);
    const t = setTimeout(() => {
      api<PlanResponse>("/api/v3/plan", { method: "POST", body, signal: controller.signal }).then(
        (r) => { if (!controller.signal.aborted) { setResponse({ key: requestKey, data: r.data }); setError(null); setBusy(false); } },
        (e) => { if (!controller.signal.aborted) { setError(e); setBusy(false); } });
    }, 200);
    return () => { clearTimeout(t); controller.abort(); };
  }, [JSON.stringify(body), cacheTotal]);

  if (!plannable.length) return <p className="muted">Admit at least one model family first; the assistant sizes limits per family.</p>;
  if (options.loading && !options.data) return <Loading rows={5} />;
  if (options.error) return <ErrorNote error={options.error} retry={options.reload} />;
  const priced = options.data?.models ?? [];
  const geos = [...new Set(priced.flatMap((m) => Object.keys(m.geos)))].sort();

  const apply = () => {
    if (!result || !onApply || !result.plan.applicable) return;
    onApply(limitsFromPlan(result.plan),
      `${usd(result.budgetUsd)} per user per month, ${sizing === "guaranteed" ? "conservative" : "expected"} sizing; ${withGroup ? `${usd(result.groupBudgetUsd)} independent group budget` : "existing group limits unchanged"}; rate card ${result.rateCardVersion}`,
      { personBudget: { amount: Number(amount), currency, period: "monthly" },
        groupBudget: withGroup ? { amount: Number(groupAmount), currency: groupCurrency, period: "monthly" } : null });
  };

  return (
    <div className="assistant">
      <div className="assistant-inputs">
        <fieldset className="fieldset">
          <legend>Per-user budget</legend>
          <div className="row-fields">
            <Field label="Monthly budget per user" hint="Each user gets this allowance. Group size is not needed.">{(id) => (
              <div className="input-group">
                <input id={id} className="input input-num" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
                <select className="input" aria-label="Budget unit" value={currency} onChange={(e) => setCurrency(e.target.value as "USD" | "CCU")}><option>USD</option><option>CCU</option></select>
              </div>
            )}</Field>
            <Field label="Geography">{(id) => <select id={id} className="input" value={geography} onChange={(e) => setGeography(e.target.value)}>{geos.map((g) => <option key={g} value={g}>{g === "global" ? "Global" : g === "us" ? "US data zone" : g}</option>)}</select>}</Field>
          </div>
          <div className="field">
            <span className="label" id="sizing-label">Sizing</span>
            <Segmented label="Sizing" value={sizing} onChange={setSizing} options={[{ value: "expected", label: "Expected mix" }, { value: "guaranteed", label: "Conservative" }]} />
            <p className="hint">{sizing === "guaranteed" ? "Sizes quotas at the highest token price across the selected model's prompt tiers. This is a sizing estimate, not a guarantee of invoice or dollar-budget enforcement." : "More tokens at the assumed mix and base tier; output-heavy use or higher tiers can exceed the budget."}</p>
          </div>
        </fieldset>
        <fieldset className="fieldset">
          <legend>Optional whole-group budget</legend>
          <label className="check"><input type="checkbox" checked={withGroup} onChange={(e) => setWithGroup(e.target.checked)} /> Also size whole-group limits</label>
          <p className="hint">Independent cap shared by the group, never divided among users. When off, applying preserves existing group token limits.</p>
          {withGroup && <Field label="Whole-group monthly budget">{(id) => <div className="input-group">
            <input id={id} className="input input-num" inputMode="decimal" value={groupAmount} onChange={(e) => setGroupAmount(e.target.value)} />
            <select className="input" aria-label="Whole-group budget unit" value={groupCurrency} onChange={(e) => setGroupCurrency(e.target.value as "USD" | "CCU")}><option>USD</option><option>CCU</option></select>
          </div>}</Field>}
        </fieldset>
        <fieldset className="fieldset">
          <legend>Traffic mix</legend>
          <Slider label="Output share of tokens" value={mix.outputPercentOfTokens} onChange={(v) => setMix({ ...mix, outputPercentOfTokens: v })} />
          <Slider label="Cache reads (of input)" value={mix.cacheReadPercentOfInput} onChange={(v) => setMix({ ...mix, cacheReadPercentOfInput: v })} />
          <Slider label="Cache writes 5 m (of input)" value={mix.cacheWrite5mPercentOfInput} onChange={(v) => setMix({ ...mix, cacheWrite5mPercentOfInput: v })} />
          <Slider label="Cache writes 1 h (of input)" value={mix.cacheWrite1hPercentOfInput} onChange={(v) => setMix({ ...mix, cacheWrite1hPercentOfInput: v })} />
          {cacheTotal > 100 && <p className="field-error">Cache shares total {cacheTotal} % of input; lower one of them.</p>}
        </fieldset>
        <fieldset className="fieldset">
          <legend>Budget split by family</legend>
          {plannable.map((f) => (
            <div key={f.family} className="family-split">
              <Slider label={f.family[0].toUpperCase() + f.family.slice(1)} value={split[f.family] ?? 0} onChange={(v) => setSplit(rebalance(split, f.family, v))} />
              <Field label={<span className="visually-hidden">{f.family} model priced</span>}>{(id) => (
                <select id={id} className="input input-compact" value={models[f.family] ?? ""} onChange={(e) => setModels({ ...models, [f.family]: e.target.value })}>
                  {priced.filter((m) => m.family === f.family).map((m) => <option key={m.model} value={m.model}>{m.model}{m.tiered ? " (base tier)" : ""}</option>)}
                </select>
              )}</Field>
            </div>
          ))}
        </fieldset>
        <fieldset className="fieldset">
          <legend>Rate limits</legend>
          <div className="row-fields">
            <Field label="Working days">{(id) => <input id={id} className="input input-num" type="number" min={1} max={31} value={days} onChange={(e) => setDays(Math.min(31, Math.max(1, Number(e.target.value) || 1)))} />}</Field>
            <Field label="Hours a day">{(id) => <input id={id} className="input input-num" type="number" min={1} max={24} value={hours} onChange={(e) => setHours(Math.min(24, Math.max(1, Number(e.target.value) || 1)))} />}</Field>
          </div>
          <Slider label="Burst factor" value={burst} min={1} max={10} step={0.5} suffix="×" onChange={setBurst} hint="TPM = monthly quota ÷ working minutes × burst." />
        </fieldset>
      </div>
      <div className="assistant-result" aria-live="polite" aria-busy={busy}>
        {error ? <p className="field-error" role="alert">{errorMessage(error)}</p> : null}
        {result ? (
          <>
            <DataTable caption="Suggested limits by family" dense rows={result.plan.families} rowKey={(r) => r.family} columns={[
              { key: "family", label: "Family", render: (r) => <><strong>{r.family}</strong><span className="mono muted block">{r.model}</span></> },
              { key: "blendedUsdPerMTok", label: "$/MTok (blend)", align: "end", render: (r) => Number(r.blendedUsdPerMTok).toFixed(2) },
              { key: "personMonthlyTokens", label: "Person / month", align: "end", render: (r) => int(r.personMonthlyTokens) },
              { key: "personTokensPerMinute", label: "Person TPM", align: "end", render: (r) => int(r.personTokensPerMinute) },
              { key: "groupMonthlyTokens", label: "Group / month", align: "end", render: (r) => r.groupMonthlyTokens === null ? "Unchanged" : int(r.groupMonthlyTokens) },
              { key: "groupTokensPerMinute", label: "Group TPM", align: "end", render: (r) => int(r.groupTokensPerMinute) },
            ]} />
            <p className="assistant-summary">
              <span>{sizing === "guaranteed" ? "Conservative" : "Expected"} per-user sizing:</span>
              <span>expected <strong data-testid="plan-expected">{usd(result.plan.expectedSpendUsd)}</strong></span>
              <span>worst case <strong data-testid="plan-worst">{usd(result.plan.worstCaseSpendUsd)}</strong></span>
              <span className="muted">of {usd(result.budgetUsd)} · rate card {result.rateCardVersion}{result.geoMultiplier !== "1" ? ` · geo ×${result.geoMultiplier}` : ""}</span>
            </p>
            {result.plan.warnings.map((w: string) => <p key={w} className="notice notice-warn">{w}</p>)}
            {onApply && <Button variant="primary" onClick={apply} disabled={busy || !result.plan.applicable}>{applyLabel}</Button>}
            <p className="hint">Suggested token limits only. Monetary budgets are not saved by Apply; review both budget settings and limits before saving.</p>
          </>
        ) : !error && <Loading rows={3} label="Calculating" />}
      </div>
    </div>
  );
}
