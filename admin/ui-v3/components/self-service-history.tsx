import { useEffect, useRef, useState } from "react";
import { ApiFailure, api, useQuery } from "../lib/api.ts";
import { when } from "../lib/format.ts";
import { Button, DataTable, ErrorNote, Loading, Review, Section } from "./ui.tsx";
import { available, FailureRequirements, FeatureNotice, needsNewReview, projectPath, ReasonField, validReason } from "./self-service-shared.tsx";
import type { Capability, HistoryPreview, HistoryVersion, SelfServiceProps } from "./self-service-shared.tsx";

interface RestoreRequest { preview: HistoryPreview; body: Readonly<{ reason: string }> }

export function HistoryVersions({ versions, readOnly, busy, onPreview }: {
  versions: HistoryVersion[]; readOnly: boolean; busy: boolean; onPreview: (versionId: string) => void;
}) {
  return <DataTable caption="Immutable configuration versions" rows={versions} rowKey={(r) => r.versionId}
    empty={<p className="empty-inline">No configuration versions have been captured yet. Existing project editing keeps working.</p>}
    columns={[
      { key: "createdAt", label: "Captured", render: (r) => when(r.createdAt) },
      { key: "versionId", label: "Version", render: (r) => <code className="wrap">{r.versionId}</code> },
      { key: "sourceEtag", label: "Source version", render: (r) => <code className="wrap">{r.sourceEtag}</code> },
      { key: "preview", label: "Restore", render: (r) => <Button size="small" disabled={readOnly || busy} onClick={() => onPreview(r.versionId)}>Preview changes</Button> },
    ]} />;
}

export function ConfigurationHistory({ projectId, etag, readOnly, onChanged, capability }: SelfServiceProps & { capability?: Capability }) {
  const base = `${projectPath(projectId)}/history`;
  const history = useQuery<{ versions: HistoryVersion[] }>(available(capability) ? base : null);
  const [preview, setPreview] = useState<HistoryPreview | null>(null);
  const [reason, setReason] = useState("");
  const [review, setReview] = useState<RestoreRequest | null>(null);
  const [busy, setBusy] = useState(false);
  const sending = useRef(false);
  const [error, setError] = useState<unknown>(null);
  const [failedVersion, setFailedVersion] = useState<string | null>(null);
  const [previewDenied, setPreviewDenied] = useState<unknown>(null);
  const [restoreDenied, setRestoreDenied] = useState<unknown>(null);
  const [saved, setSaved] = useState(false);
  useEffect(() => { setPreviewDenied(null); setRestoreDenied(null); }, [capability]);
  const writable = !readOnly && available(capability) && Boolean(etag);
  const versionChanged = Boolean(preview && preview.etag !== etag);
  const stale = needsNewReview(error) || versionChanged;
  const reset = () => { setPreview(null); setReview(null); setReason(""); setError(null); setFailedVersion(null); };
  const loadPreview = async (versionId: string) => {
    if (!writable || sending.current || previewDenied) return;
    sending.current = true; setBusy(true); setError(null); setSaved(false); setFailedVersion(versionId);
    try {
      const r = await api<HistoryPreview>(`${base}/${encodeURIComponent(versionId)}/preview`, { method: "POST" });
      if (r.data?.versionId !== versionId || typeof r.data.etag !== "string" || !r.data.etag || !Array.isArray(r.data.changes)) {
        throw new Error("The server did not return a valid current-version preview. Preview again before restoring.");
      }
      setPreview(r.data); setReview(null); setReason(""); setFailedVersion(null);
      if (r.data.etag !== etag) onChanged();
    } catch (e) { setError(e); if (e instanceof ApiFailure && e.status === 403) setPreviewDenied(e); }
    finally { sending.current = false; setBusy(false); }
  };
  const restore = async () => {
    if (!review || !writable || stale || restoreDenied || sending.current) return;
    sending.current = true; setBusy(true); setError(null);
    try {
      const r = await api(`${base}/${encodeURIComponent(review.preview.versionId)}/restore`, {
        method: "POST", ifMatch: review.preview.etag, body: review.body,
      });
      if (!r.data?.project || !r.etag) throw new Error("The restore response is incomplete. Reload the project before reviewing another restore.");
      reset(); setSaved(true); history.reload(); onChanged();
    } catch (e) {
      setError(e);
      if (e instanceof ApiFailure && e.status === 403) setRestoreDenied(e);
      if (needsNewReview(e)) onChanged();
    } finally { sending.current = false; setBusy(false); }
  };
  return <Section title="Configuration history" description="Immutable configuration versions only. Restore creates a new change; it never rewinds spend, usage, audit history or retirement. Routing must be published and verified again.">
    {!available(capability) ? <FeatureNotice cap={capability} what="Configuration history" /> : <div className="stack">
      {saved && <p className="notice" role="status">Configuration restored as a new change. Historical routing verification was not restored. Publish routing again where needed, then use Apply now or wait for the next scheduled run.</p>}
      {history.loading && !history.data ? <Loading label="Loading configuration versions" rows={3} /> : history.error ?
        <><ErrorNote error={history.error} retry={history.reload} /><FailureRequirements error={history.error} /></> :
        <HistoryVersions versions={history.data?.versions ?? []} readOnly={!writable || Boolean(previewDenied)} busy={busy} onPreview={loadPreview} />}
      <div className="form-actions"><Button size="small" variant="quiet" busy={history.loading} onClick={history.reload}>Refresh configuration history</Button></div>
      {Boolean(previewDenied) && <><p className="hint">Preview is disabled until permissions are rechecked. History viewing and other operations remain available.</p><FailureRequirements error={previewDenied} /></>}
      {Boolean(restoreDenied) && <><p className="hint">Restore is disabled until permissions are rechecked. History viewing and preview remain available.</p><FailureRequirements error={restoreDenied} /></>}
      {preview && writable && !stale && !restoreDenied ? review ? <>
        <Review title="Review configuration restore" changes={review.preview.changes} busy={busy} error={error}
          confirmLabel={error ? "Retry reviewed restore" : "Restore configuration"} onConfirm={restore} onCancel={() => { setReview(null); setError(null); }}
          note={`Version ${review.preview.versionId}. Reason: ${review.body.reason}. Checked against the current project version; concurrent changes refuse the restore.`} />
        <FailureRequirements error={error} />
      </> : <div className="stack">
        <h3>Preview configuration restore</h3>
        <DataTable caption="Configuration restore differences" rows={preview.changes} rowKey={(r) => r.path}
          empty={<p className="empty-inline">This version has no restorable configuration differences.</p>} columns={[
            { key: "path", label: "Field", render: (r) => <code>{r.path}</code> },
            { key: "before", label: "Current", render: (r) => <code className="wrap">{JSON.stringify(r.before) ?? "(none)"}</code> },
            { key: "after", label: "Restored", render: (r) => <code className="wrap">{JSON.stringify(r.after) ?? "(none)"}</code> },
          ]} />
        <ReasonField reason={reason} setReason={setReason} disabled={busy} />
        <div className="form-actions"><Button variant="primary" disabled={busy || !validReason(reason) || !preview.changes.length}
          onClick={() => setReview({ preview, body: Object.freeze({ reason: reason.trim() }) })}>Review restore</Button><Button variant="quiet" disabled={busy} onClick={reset}>Cancel</Button></div>
      </div> : null}
      {preview && stale && <div className="notice notice-warn" role="status"><p>The current project version changed. Preview this configuration again before restoring it.</p>
        <Button size="small" disabled={!writable || busy || Boolean(previewDenied)} onClick={() => loadPreview(preview.versionId)}>Preview current changes</Button></div>}
      {Boolean(error) && (!review || stale || restoreDenied || !writable) && <>
        <ErrorNote error={error} retry={failedVersion && !previewDenied ? () => loadPreview(failedVersion) : undefined} /><FailureRequirements error={error} />
      </>}
    </div>}
  </Section>;
}
