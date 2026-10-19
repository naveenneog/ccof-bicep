import { Fragment, useEffect, useMemo, useRef, useState } from "react";
import { api, errorMessage, useQuery } from "../lib/api.ts";
import { day, download, human, int, when } from "../lib/format.ts";
import { Button, CapabilityNotice, DataTable, Empty, ErrorNote, Field, Loading, PageHeader, Review, Section, Segmented, StatePill, diff, useToast } from "../components/ui.tsx";
import { rateForDisplay, rateFromDisplay } from "../../src/units.ts";
import type { RateUnit } from "../../src/units.ts";
import { useSession } from "../components/shell.tsx";

const CATS = [
  { key: "input", label: "Input" }, { key: "output", label: "Output" }, { key: "cacheRead", label: "Cache read" },
  { key: "cacheWrite5m", label: "Cache write 5m" }, { key: "cacheWrite1h", label: "Cache write 1h" },
];
const familyOf = (m: string) => /^claude-(haiku|sonnet|opus|fable|mythos)(?:[-.]|$)/i.exec(m)?.[1]?.toLowerCase() ?? "unknown";
const tomorrow = () => { const d = new Date(); return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1)).toISOString().slice(0, 10); };
const status = (e: any, now = Date.now()) => Date.parse(e.effectiveFrom) > now ? "scheduled" : e.effectiveTo && Date.parse(e.effectiveTo) <= now ? "closed" : "in_force";
const DEC = /^\d{1,12}(\.\d{1,12})?$/;

function RepriceRow({ entry, perTokens, unit, onAdd, onCancel }: { entry: any; perTokens: number; unit: RateUnit; onAdd: (newEntry: any, from: string) => void; onCancel: () => void }) {
  const [from, setFrom] = useState(tomorrow());
  const [rates, setRates] = useState<Record<string, string>[]>(entry.promptTiers.map((t: any) => Object.fromEntries(CATS.map((c) => [c.key, rateForDisplay(t.rates[c.key], perTokens, unit)]))));
  const [err, setErr] = useState<string | null>(null);
  const ref = useRef<HTMLFieldSetElement>(null);
  useEffect(() => { ref.current?.querySelector("input")?.focus(); }, []);
  const add = () => {
    if (!/^\d{4}-\d\d-\d\d$/.test(from) || Date.parse(`${from}T00:00:00Z`) <= Date.now()) return setErr("Choose a future date: a new price can't reprice recorded usage.");
    if (rates.some((t) => CATS.some((c) => !DEC.test(t[c.key]) || Number(t[c.key]) <= 0))) return setErr("Every rate must be a positive decimal.");
    const at = `${from}T00:00:00Z`;
    onAdd({
      ...structuredClone(entry), effectiveFrom: at, effectiveTo: null,
      source: { ...entry.source, retrieved: new Date().toISOString().slice(0, 10) },
      promptTiers: entry.promptTiers.map((t: any, i: number) => ({ ...t, rates: Object.fromEntries(CATS.map((c) => [c.key, rateFromDisplay(rates[i][c.key], perTokens, unit)])) })),
    }, at);
  };
  return (
    <fieldset className="fieldset reprice" ref={ref}>
      <legend>New price for <code>{entry.model}</code>, in {unit} per million tokens</legend>
      <Field label="Effective from (UTC, 00:00)" hint={`Closes the current entry at the same instant.`}>{(id, d) => <input id={id} aria-describedby={d} type="date" className="input" min={tomorrow()} value={from} onChange={(e) => setFrom(e.target.value)} />}</Field>
      {rates.map((t, i) => (
        <div key={i} className="rate-inputs">
          {entry.promptTiers.length > 1 && <span className="muted">Tier {i + 1}</span>}
          {CATS.map((c) => (
            <Field key={c.key} label={c.label}>{(id) => <input id={id} className="input input-num input-compact" inputMode="decimal" value={t[c.key]}
              onChange={(e) => setRates(rates.map((r, j) => j === i ? { ...r, [c.key]: e.target.value.trim() } : r))} />}</Field>
          ))}
        </div>
      ))}
      {err && <p className="field-error" role="alert">{err}</p>}
      <div className="form-actions"><Button variant="primary" size="small" onClick={add}>Add price change</Button><Button variant="quiet" size="small" onClick={onCancel}>Cancel</Button></div>
    </fieldset>
  );
}

export function CostDefinitions() {
  const session = useSession();
  const toast = useToast();
  const q = useQuery("/api/v2/catalog");
  const prices = useQuery("/api/v2/prices");
  const billed = useQuery("/api/v2/billed-cost");
  const [unit, setUnit] = useState<RateUnit>("USD");
  const [draft, setDraft] = useState<any>(null);
  const [repricing, setRepricing] = useState<string | null>(null);
  const [review, setReview] = useState<any>(null);
  const [reviewError, setReviewError] = useState<unknown>(null);
  const [saveError, setSaveError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const [filter, setFilter] = useState("");
  const fileRef = useRef<HTMLInputElement>(null);
  const current = q.data?.catalog?.rateCard ?? null;
  useEffect(() => { setDraft(null); setReview(null); }, [q.data]);
  const card = draft ?? current;
  const perTokens = card?.rateUnit?.perTokens ?? 1_000_000;
  const editable = Boolean(q.data?.editable) && session.canWrite;
  const dirty = draft && JSON.stringify(draft) !== JSON.stringify(current);

  const rows = useMemo(() => !card ? [] : card.entries.flatMap((e: any) => e.promptTiers.map((t: any, i: number) => ({ e, t, i, key: `${e.model}@${e.effectiveFrom}#${i}` })))
    .filter((r: any) => !filter || r.e.model.includes(filter) || familyOf(r.e.model) === filter), [card, filter]);

  const startEdit = () => setDraft(structuredClone(current));
  const loadFile = async (file: File) => {
    setReviewError(null);
    try {
      if (file.size > 1024 * 1024) throw new Error("The file is larger than 1 MiB.");
      const parsed = JSON.parse(await file.text());
      const candidate = parsed?.rateCard && parsed?.schemaVersion === 1 && Array.isArray(parsed.models) ? parsed.rateCard : parsed;
      setDraft(candidate);
      await openReview(candidate);
      toast(`Loaded ${file.name}. Review the changes before saving.`);
    } catch (e) { setReviewError(e instanceof SyntaxError ? new Error("That file isn't valid JSON.") : e); }
  };
  const openReview = async (candidate = draft) => {
    setReviewError(null); setSaveError(null);
    try {
      const r = await api("/api/v3/rate-card/review", { method: "POST", body: candidate });
      setReview({ server: r.data.review, changes: diff(current, candidate) });
    } catch (e) { setReview(null); setReviewError(e); }
  };
  const save = async () => {
    setBusy(true); setSaveError(null);
    try {
      const models = [...q.data.catalog.models];
      for (const e of draft.entries) {
        const fam = familyOf(e.model);
        if (fam !== "unknown" && !models.some((m: any) => m.model === e.model)) models.push({ family: fam, model: e.model, deployment: e.model, backendId: "" });
      }
      const fromStore = q.data.source === "admin_catalog";
      await api("/api/v2/catalog", { method: "PUT", body: { schemaVersion: 1, models, rateCard: draft }, ifMatch: fromStore ? q.etag : null, ifNoneMatch: fromStore ? undefined : "*" });
      toast(`Saved rate card ${draft.version}. Chargeback and the budget assistant use it now; deploy it to the reconciler separately.`);
      q.reload();
    } catch (e) { setSaveError(e); } finally { setBusy(false); }
  };
  const exportCard = () => download(`rate-card-${card.version}.json`, JSON.stringify(card, null, 2) + "\n", "application/json");

  if (q.loading && !q.data) return <div className="page"><PageHeader title="Cost definitions" /><Loading rows={10} /></div>;
  if (q.error) return <div className="page"><PageHeader title="Cost definitions" /><ErrorNote error={q.error} retry={q.reload} /></div>;
  if (q.data?.state === "unavailable") return <div className="page"><PageHeader title="Cost definitions" /><CapabilityNotice cap={q.data} what="The rate card" /></div>;

  return (
    <div className="page">
      <PageHeader title="Cost definitions" subtitle="The versioned rate card that prices chargeback, budgets and the budget assistant." observedAt={q.observedAt} onRefresh={q.reload} busy={q.loading}
        actions={<Button icon="download" onClick={exportCard}>Export JSON</Button>} />
      <div className="toolbar">
        <dl className="inline-facts">
          <div><dt>Version</dt><dd><strong>{card.version}</strong>{dirty && <span className="pill pill-warn">edited</span>}</dd></div>
          <div><dt>Source</dt><dd>{human(q.data.source)}</dd></div>
          <div><dt>Unit</dt><dd>{card.rateUnit.currency} per {int(card.rateUnit.perTokens)} tokens</dd></div>
          <div><dt>Entries</dt><dd>{card.entries.length}</dd></div>
        </dl>
        <div className="toolbar-actions">
          <Segmented label="Show rates in" value={unit} onChange={setUnit} options={[{ value: "USD", label: "USD / MTok" }, { value: "CCU", label: "CCU / MTok" }]} />
          {editable && !draft && <Button onClick={startEdit}>Edit prices</Button>}
          {editable && <>
            <input ref={fileRef} type="file" accept="application/json,.json" className="visually-hidden" id="rate-card-file" tabIndex={-1}
              onChange={(e) => { const f = e.target.files?.[0]; if (f) loadFile(f); e.target.value = ""; }} />
            <Button icon="upload" onClick={() => fileRef.current?.click()}>Load from file</Button>
          </>}
        </div>
      </div>
      {!editable && <p className="hint">{session.canWrite ? q.data.reason ?? "Saving is not configured." : "Read only: editing needs CCOF.Projects.Write."}</p>}
      {reviewError ? <ErrorNote error={reviewError} /> : null}
      {review && draft ? (
        <div className="stack">
          <section className="panel">
            <div className="panel-head"><h2>Rate card review</h2></div>
            <dl className="facts">
              <div><dt>Version</dt><dd><code>{review.server.version.before ?? "(none)"}</code> → <code>{review.server.version.after}</code></dd></div>
              <div><dt>New entries</dt><dd>{review.server.added.length ? review.server.added.map((e: any) => <span key={`${e.model}${e.effectiveFrom}`} className="block"><code>{e.model}</code> from {day(e.effectiveFrom)}</span>) : "none"}</dd></div>
              <div><dt>Closed entries</dt><dd>{review.server.closed.length ? review.server.closed.map((e: any) => <span key={`${e.model}${e.effectiveFrom}`} className="block"><code>{e.model}</code> ends {when(e.effectiveTo)}</span>) : "none"}</dd></div>
              <div><dt>Unchanged</dt><dd>{review.server.unchanged} of {review.server.entries}</dd></div>
            </dl>
            <p className="hint">Validated on the server with the reconciler's parser and the history rules: recorded prices are never edited, the version changes, and new prices start in the future.</p>
          </section>
          <Review title="Field changes" changes={review.changes} busy={busy} error={saveError} onConfirm={save} onCancel={() => setReview(null)} confirmLabel="Save rate card"
            note="Saved with the catalog's version tag (If-Match). Export and deploy the approved card to update reconciler pricing." />
        </div>
      ) : (
        <>
          {draft && (
            <div className="edit-bar" role="region" aria-label="Edit rate card">
              <Field label="New version" hint="Required: a saved card's version must change.">{(id, d) => <input id={id} aria-describedby={d} className="input mono" value={draft.version} onChange={(e) => setDraft({ ...draft, version: e.target.value })} />}</Field>
              <div className="form-actions">
                <Button variant="primary" disabled={!dirty} onClick={() => openReview()}>Review changes</Button>
                <Button variant="quiet" onClick={() => { setDraft(null); setRepricing(null); }}>Discard</Button>
              </div>
            </div>
          )}
          <Section title="Rates" description={`Per million tokens, in ${unit}${unit === "CCU" ? " (100 CCU = USD 1, exact)" : ""}. Stored in USD as published.`}
            actions={<Field label={<span className="visually-hidden">Filter by model or family</span>}>{(id) => <input id={id} className="input input-compact" placeholder="Filter: model or family" value={filter} onChange={(e) => setFilter(e.target.value.trim().toLowerCase())} />}</Field>}>
            <div className="table-wrap" tabIndex={0} role="region" aria-label="Rate card entries">
              <table className="table table-dense rate-table">
                <caption className="visually-hidden">Rate card entries in {unit} per million tokens</caption>
                <thead><tr>
                  <th scope="col">Model</th><th scope="col">Family</th><th scope="col">Effective</th><th scope="col">Geo ×</th><th scope="col">Tier</th>
                  {CATS.map((c) => <th key={c.key} scope="col" className="num">{c.label}</th>)}<th scope="col"><span className="visually-hidden">Actions</span></th>
                </tr></thead>
                <tbody>
                  {rows.map(({ e, t, i, key }: any) => (
                    <Fragment key={key}>
                      <tr className={status(e) === "closed" ? "row-muted" : undefined}>
                        <td>{i === 0 ? <><code>{e.model}</code>{e.displayName && <span className="block muted small">{e.displayName}</span>}</> : null}</td>
                        <td className="cap">{i === 0 ? familyOf(e.model) : null}</td>
                        <td>{i === 0 ? <><span className="block">{day(e.effectiveFrom)} → {e.effectiveTo ? day(e.effectiveTo) : "open"}</span><StatePill state={status(e) === "in_force" ? "current" : status(e) === "closed" ? "historical" : "partial"} label={human(status(e))} /></> : null}</td>
                        <td>{i === 0 ? Object.entries(e.inferenceGeoMultipliers).map(([g, m]) => <span key={g} className="block nowrap">{g} ×{String(m)}</span>) : null}</td>
                        <td className="nowrap">{e.promptTiers.length === 1 ? "all" : t.promptTokensUpTo ? `≤ ${int(t.promptTokensUpTo)}` : `> ${int(t.promptTokensOver)}`}</td>
                        {CATS.map((c) => <td key={c.key} className="num mono" data-testid={i === 0 && c.key === "input" ? `rate-${e.model}` : undefined}>{rateForDisplay(t.rates[c.key], perTokens, unit)}</td>)}
                        <td>{i === 0 && draft && status(e) !== "closed" && !e.effectiveTo && repricing !== key && <Button size="small" onClick={() => setRepricing(key)}>Reprice</Button>}</td>
                      </tr>
                      {repricing === key && (
                        <tr className="row-edit"><td colSpan={6 + CATS.length}>
                          <RepriceRow entry={e} perTokens={perTokens} unit={unit} onCancel={() => setRepricing(null)} onAdd={(next, at) => {
                            setDraft({ ...draft, entries: [...draft.entries.map((x: any) => x === e ? { ...x, effectiveTo: at } : x), next] });
                            setRepricing(null);
                            toast(`Added a new ${e.model} price from ${day(at)}. Set a new version, then review.`);
                          }} />
                        </td></tr>
                      )}
                    </Fragment>
                  ))}
                </tbody>
              </table>
            </div>
            {!rows.length && <Empty title="No entries match the filter" />}
            <p className="hint">Cache categories: cache read, 5-minute and 1-hour cache writes are priced separately. A geography not listed for a model is reported unpriced.</p>
          </Section>
          <Section title="Model mappings" description="Catalog models drive the console's model lists. Deployment and backend mappings are optional.">
            <DataTable caption="Model mappings" dense rows={q.data.catalog.models} rowKey={(m: any) => `${m.backendId}/${m.deployment}`} columns={[
              { key: "family", label: "Family", render: (m: any) => <span className="cap">{m.family}</span> }, { key: "model", label: "Model", render: (m: any) => <code>{m.model}</code> },
              { key: "deployment", label: "Deployment", render: (m: any) => <code>{m.deployment}</code> }, { key: "backendId", label: "Backend", render: (m: any) => m.backendId ? <code>{m.backendId}</code> : <span className="muted">any</span> },
            ]} />
          </Section>
          <div className="split">
            <Section title="Retail meters" description="Published Azure retail meters, for comparison only; never used for pricing.">
              {prices.loading && !prices.data ? <Loading rows={3} /> : prices.data?.state === "available" ? <DataTable caption="Retail meters" dense maxHeight rows={prices.data.data.prices.slice(0, 50)} columns={[
                { key: "product", label: "Product" }, { key: "meter", label: "Meter" }, { key: "retailPrice", label: "Price", align: "end" }, { key: "unit", label: "Unit" },
              ]} /> : prices.data ? <CapabilityNotice cap={prices.data} what="Retail meters" /> : null}
            </Section>
            <Section title="Billed cost" description="Azure ActualCost month to date per Foundry account: delayed, and not allocated to projects.">
              {billed.loading && !billed.data ? <Loading rows={3} /> : billed.data?.state === "available" ? <DataTable caption="Billed cost" dense rows={billed.data.data.costs} columns={Object.keys(billed.data.data.costs[0] ?? {}).map((k) => ({ key: k, label: k }))} />
                : billed.data ? <CapabilityNotice cap={billed.data} what="Billed cost" /> : null}
            </Section>
          </div>
          {saveError ? <p className="field-error">{errorMessage(saveError)}</p> : null}
        </>
      )}
    </div>
  );
}
