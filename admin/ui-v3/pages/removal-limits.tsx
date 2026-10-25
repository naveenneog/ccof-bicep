import { useEffect, useMemo, useState } from "react";
import { api, useQuery } from "../lib/api.ts";
import { when } from "../lib/format.ts";
import { href } from "../lib/router.ts";
import { Button, CapabilityNotice, ErrorNote, Field, Loading, PageHeader, Review, Section, StatePill, diff, useToast } from "../components/ui.tsx";
import { useSession } from "../components/shell.tsx";
import { UserIdentity } from "../components/user-identity.tsx";

const FRACTION = /^(0(\.\d{1,6})?|1(\.0{1,6})?)$/;
const STATE_TEXT: Record<string, string> = {
  none: "No override saved. The sync uses its app settings.",
  disabled: "Override saved but switched off. The sync uses its app settings.",
  expired: "Override expired. The sync uses its app settings.",
  in_effect: "Override in effect. The sync uses these limits at its next run.",
  invalid: "The saved document is invalid, so the sync ignores it and uses its app settings. Save a corrected version.",
};
const EXPIRY = [
  { value: "keep", label: "Keep current expiry" }, { value: "1", label: "1 day" }, { value: "7", label: "7 days" },
  { value: "30", label: "30 days" }, { value: "90", label: "90 days (maximum)" }, { value: "never", label: "No expiry" },
];

// "Keep current expiry" only while the saved expiry is still in the future; the server refuses a past one.
const keepable = (saved: any) => Boolean(saved?.expiresAt) && Date.parse(saved.expiresAt) > Date.now();

interface Draft { enabled: boolean; maxRemovalsPerRun: string; maxRemovalFraction: string; expiry: string; reason: string }

export function RemovalLimits() {
  const session = useSession();
  const toast = useToast();
  const q = useQuery("/api/v3/sync/removal-limits");
  const saved = q.data?.limits ?? null;
  const initial = useMemo<Draft>(() => ({
    enabled: saved?.enabled ?? true, maxRemovalsPerRun: String(saved?.maxRemovalsPerRun ?? 5), maxRemovalFraction: saved?.maxRemovalFraction ?? "0.1",
    expiry: keepable(saved) ? "keep" : saved && !saved.expiresAt ? "never" : "7", reason: "",
  }), [saved]);
  const [draft, setDraft] = useState<Draft>(initial);
  const [review, setReview] = useState<{ body: any; before: any } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  useEffect(() => setDraft(initial), [initial]);

  if (q.loading && !q.data) return <div className="page"><PageHeader title="Removal limits" /><Loading rows={6} /></div>;
  if (q.error) return <div className="page"><PageHeader title="Removal limits" /><ErrorNote error={q.error} retry={q.reload} /></div>;
  const data = q.data;
  const editable = Boolean(data?.editable && session.canWrite);
  const count = Number(draft.maxRemovalsPerRun);
  const problems = {
    count: !/^\d+$/.test(draft.maxRemovalsPerRun) || count > 10_000_000 ? "A whole number from 0 to 10,000,000." : null,
    fraction: FRACTION.test(draft.maxRemovalFraction) ? null : "A decimal from 0 to 1, at most six decimal places (0.1 = 10%).",
    reason: draft.reason.trim() && draft.reason.trim().length <= 200 ? null : "Required, up to 200 characters. It is stored with the change.",
    expiry: draft.expiry === "keep" && !keepable(saved) ? "Choose an expiry." : null,
  };
  const valid = !Object.values(problems).some(Boolean);
  const expiresAt = draft.expiry === "keep" ? saved?.expiresAt ?? null : draft.expiry === "never" ? null
    : new Date(Date.now() + Number(draft.expiry) * 86_400_000).toISOString();
  const body = { enabled: draft.enabled, maxRemovalsPerRun: count, maxRemovalFraction: draft.maxRemovalFraction, expiresAt, reason: draft.reason.trim() };
  const before = saved ? { enabled: saved.enabled, maxRemovalsPerRun: saved.maxRemovalsPerRun, maxRemovalFraction: saved.maxRemovalFraction, expiresAt: saved.expiresAt, reason: saved.reason } : {};

  const confirm = async () => {
    if (!review) return;
    setBusy(true); setError(null);
    try {
      await api("/api/v3/sync/removal-limits", { method: "PUT", body: review.body, ...(data.etag ? { ifMatch: data.etag } : { ifNoneMatch: "*" }) });
      setReview(null);
      toast("Saved. The sync applies it at its next run.");
      q.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  return (
    <div className="page">
      <PageHeader title="Removal limits" subtitle="How many access removals one entitlement sync run may apply before it holds them back for review."
        observedAt={q.observedAt} onRefresh={q.reload} busy={q.loading} />
      {review ? (
        <Review title="Review removal limits" changes={diff(review.before, review.body)} busy={busy} error={error} onConfirm={confirm} onCancel={() => setReview(null)}
          note="Sent with the version you loaded. The change is written to the permanent change record before it is saved." />
      ) : (<>
        <Section title="Current state" description={data?.appliesWhen}>
          <p><StatePill state={data?.state === "in_effect" ? "available" : data?.state === "invalid" ? "unavailable" : "disabled"} label={String(data?.state ?? "none").replace("_", " ")} /> {STATE_TEXT[data?.state] ?? ""}</p>
          {saved && <dl className="facts">
            <div><dt>Max removals per run</dt><dd>{saved.maxRemovalsPerRun}</dd></div>
            <div><dt>Max removal fraction</dt><dd>{saved.maxRemovalFraction} ({(Number(saved.maxRemovalFraction) * 100).toFixed(4).replace(/\.?0+$/, "")}% of current memberships)</dd></div>
            <div><dt>Expires</dt><dd>{saved.expiresAt ? when(saved.expiresAt) : "No expiry"}</dd></div>
            <div><dt>Reason</dt><dd>{saved.reason}</dd></div>
            <div><dt>Last changed</dt><dd>{saved.updatedAt ? when(saved.updatedAt) : "—"}</dd></div>
            <div><dt>Changed by</dt><dd><UserIdentity objectId={saved.updatedBy} /></dd></div>
          </dl>}
          <p className="muted">{data?.fallback} Removals are held back only when a run exceeds both limits. Retiring a project is not counted against them.
            {" "}<a href={href("/audit?operation=v3/sync/removal-limits")}>Change history</a></p>
        </Section>
        {!data?.editable && data?.reason ? <CapabilityNotice cap={{ state: "disabled", permission: data.reason }} what="Saving removal limits" /> : editable && (
          <Section title="Change limits" description="Raise them for a planned bulk change (for example a reorganisation), then let the override expire.">
            <div className="form-grid">
              <Field label="Override enabled">{(id) => <label className="check-inline"><input id={id} type="checkbox" checked={draft.enabled} onChange={(e) => setDraft({ ...draft, enabled: e.target.checked })} /> Use these limits instead of the app settings</label>}</Field>
              <Field label="Max removals per run" error={problems.count}>{(id, d) => <input id={id} aria-describedby={d} className="input" inputMode="numeric" value={draft.maxRemovalsPerRun} onChange={(e) => setDraft({ ...draft, maxRemovalsPerRun: e.target.value.trim() })} />}</Field>
              <Field label="Max removal fraction" hint="0.1 = 10% of current memberships." error={problems.fraction}>{(id, d) => <input id={id} aria-describedby={d} className="input" value={draft.maxRemovalFraction} onChange={(e) => setDraft({ ...draft, maxRemovalFraction: e.target.value.trim() })} />}</Field>
              <Field label="Expires" error={problems.expiry}>{(id, d) => <select id={id} aria-describedby={d} className="input" value={draft.expiry} onChange={(e) => setDraft({ ...draft, expiry: e.target.value })}>
                {EXPIRY.filter((o) => o.value !== "keep" || keepable(saved)).map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</select>}</Field>
              <Field label="Reason" error={draft.reason ? problems.reason : null} hint="Stored with the change, for example the change ticket.">{(id, d) => <input id={id} aria-describedby={d} className="input" maxLength={200} value={draft.reason} onChange={(e) => setDraft({ ...draft, reason: e.target.value })} />}</Field>
            </div>
            <div className="form-actions"><Button variant="primary" disabled={!valid} onClick={() => { setError(null); setReview({ body, before }); }}>Review change</Button></div>
          </Section>
        )}
      </>)}
    </div>
  );
}
