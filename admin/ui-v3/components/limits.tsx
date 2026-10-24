import { useMemo } from "react";
import { useQuery } from "../lib/api.ts";
import { Button, Icon } from "./ui.tsx";
import type { Limit } from "./budget-assistant.tsx";

export interface FamilyPolicy { aggregateLimits: { person: Limit; group: Limit }; families: Record<string, { models: string[]; person: Limit; group: Limit }> }
const PERIODS = ["Hourly", "Daily", "Weekly", "Monthly", "Yearly"];
export const FAMILY_ORDER = ["sonnet", "haiku", "opus", "fable", "mythos"];
export const emptyLimit = (): Limit => ({ tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null });

// Catalog models by family, for adding models to a family; falls back to the packaged rate card.
export function useCatalogModels(): Record<string, string[]> {
  const catalog = useQuery("/api/v2/catalog");
  return useMemo(() => {
    const out: Record<string, string[]> = {};
    const models = catalog.data?.catalog?.models ?? [];
    for (const m of models) (out[m.family] ??= []).includes(m.model) || out[m.family].push(m.model);
    return out;
  }, [catalog.data]);
}

function LimitInputs({ value, onChange, label, readOnly }: { value: Limit; onChange: (l: Limit) => void; label: string; readOnly?: boolean }) {
  const num = (v: string) => v.trim() === "" ? null : Math.max(0, Math.floor(Number(v)));
  return (
    <>
      <td>
        <input className="input input-num input-compact" inputMode="numeric" aria-label={`${label} tokens per minute`} readOnly={readOnly}
          value={value.tokensPerMinute ?? ""} placeholder="No limit" onChange={(e) => onChange({ ...value, tokensPerMinute: num(e.target.value) })} />
      </td>
      <td>
        <input className="input input-num input-compact" inputMode="numeric" aria-label={`${label} token quota`} readOnly={readOnly}
          value={value.tokenQuota ?? ""} placeholder="No quota"
          onChange={(e) => { const q = num(e.target.value); onChange({ ...value, tokenQuota: q, tokenQuotaPeriod: q === null ? null : value.tokenQuotaPeriod ?? "Monthly" }); }} />
      </td>
      <td>
        <select className="input input-compact" aria-label={`${label} quota period`} disabled={readOnly || value.tokenQuota === null}
          value={value.tokenQuotaPeriod ?? ""} onChange={(e) => onChange({ ...value, tokenQuotaPeriod: e.target.value || null })}>
          <option value="">—</option>{PERIODS.map((p) => <option key={p}>{p}</option>)}
        </select>
      </td>
    </>
  );
}

export function LimitsEditor({ policy, onChange, classification, readOnly }: { policy: FamilyPolicy; onChange: (p: FamilyPolicy) => void; classification: string; readOnly?: boolean }) {
  const catalog = useCatalogModels();
  const families = FAMILY_ORDER.filter((f) => policy.families[f]);
  const addable = FAMILY_ORDER.filter((f) => !policy.families[f] && (classification === "CYB" || !["fable", "mythos"].includes(f)));
  const set = (fn: (p: FamilyPolicy) => void) => { const next = structuredClone(policy); fn(next); onChange(next); };
  const rows: { key: string; label: string; scope: "person" | "group"; family?: string }[] = [
    { key: "agg-person", label: "All families · person", scope: "person" }, { key: "agg-group", label: "All families · group", scope: "group" },
    ...families.flatMap((f) => [{ key: `${f}-person`, label: `${f} · person`, scope: "person" as const, family: f }, { key: `${f}-group`, label: `${f} · group`, scope: "group" as const, family: f }]),
  ];
  return (
    <div className="limits-editor">
      <div className="table-wrap" tabIndex={0} role="region" aria-label="Token limits">
        <table className="table table-dense">
          <caption className="visually-hidden">Token limits for {classification}</caption>
          <thead><tr><th scope="col">Scope</th><th scope="col">TPM</th><th scope="col">Quota</th><th scope="col">Period</th></tr></thead>
          <tbody>
            {rows.map((r) => {
              const value = r.family ? policy.families[r.family][r.scope] : policy.aggregateLimits[r.scope];
              return (
                <tr key={r.key} className={r.family ? undefined : "row-aggregate"}>
                  <th scope="row" className="cap">{r.label}</th>
                  <LimitInputs label={r.label} value={value} readOnly={readOnly}
                    onChange={(l) => set((p) => { if (r.family) p.families[r.family][r.scope] = l; else p.aggregateLimits[r.scope] = l; })} />
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <h3 className="subhead">Admitted models</h3>
      <ul className="family-models">
        {families.map((f) => (
          <li key={f}>
            <span className="family-name">{f}</span>
            <span className="tag-list">
              {policy.families[f].models.map((m) => (
                <span key={m} className="tag tag-removable">{m}
                  {!readOnly && <button type="button" aria-label={`Remove ${m}`} disabled={policy.families[f].models.length === 1 && families.length === 1}
                    onClick={() => set((p) => { p.families[f].models = p.families[f].models.filter((x) => x !== m); if (!p.families[f].models.length) delete p.families[f]; })}><Icon name="close" size={12} /></button>}
                </span>
              ))}
            </span>
            {!readOnly && (catalog[f] ?? []).some((m) => !policy.families[f].models.includes(m)) && (
              <select className="input input-compact" aria-label={`Add a ${f} model`} value="" onChange={(e) => { const m = e.target.value; if (m) set((p) => { p.families[f].models.push(m); }); }}>
                <option value="">Add model…</option>
                {(catalog[f] ?? []).filter((m) => !policy.families[f].models.includes(m)).map((m) => <option key={m}>{m}</option>)}
              </select>
            )}
          </li>
        ))}
      </ul>
      {!readOnly && addable.length > 0 && (
        <div className="add-family">
          {addable.filter((f) => (catalog[f] ?? []).length).map((f) => (
            <Button key={f} size="small" icon="plus" onClick={() => set((p) => { p.families[f] = { models: [catalog[f][0]], person: emptyLimit(), group: emptyLimit() }; })}>Admit {f}</Button>
          ))}
        </div>
      )}
      <p className="hint">Empty TPM or quota means no limit at that scope. Fable and Mythos can be admitted only for the CYB classification.</p>
    </div>
  );
}
