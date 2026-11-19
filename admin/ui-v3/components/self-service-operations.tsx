import { useEffect, useRef, useState } from "react";
import { ApiFailure, api } from "../lib/api.ts";
import { human, when } from "../lib/format.ts";
import { Button, ErrorNote, Loading, Review, Section, StatePill } from "./ui.tsx";
import { available, failureRequirements, FailureRequirements, FeatureNotice, forgetJob, jobIdValid, LABELS, needsNewReview, operationRequest, pending, ReasonField, rememberJob, Requirements, validReason } from "./self-service-shared.tsx";
import type { Capabilities, Job, OperationKind, OperationRequest, SelfServiceProps } from "./self-service-shared.tsx";

export function OperationActions({ capabilities, readOnly, busy, onSelect }: {
  capabilities: Capabilities; readOnly: boolean; busy: boolean; onSelect: (kind: OperationKind) => void;
}) {
  return <div className="stack">{(["publish-routing", "apply"] as const).map((kind) =>
    <div key={kind}>
      <div className="form-actions"><Button disabled={readOnly || busy || !available(capabilities[kind])} onClick={() => onSelect(kind)}>{LABELS[kind]}</Button></div>
      <p className="hint">{kind === "publish-routing" ? "Verify routing in every configured gateway before activating it. The last verified route is kept if verification fails." :
        "Request entitlement sync and budget reconciliation on the active workers. Acceptance is not completion."}</p>
      <FeatureNotice cap={capabilities[kind]} what={LABELS[kind]} />
    </div>)}</div>;
}

export function OperationProgress({ job }: { job: Job }) {
  const running = pending(job);
  return <div role="status" aria-live="polite" className="stack">
    <p><strong>{job.kind ? LABELS[job.kind] : "Operation"}</strong> · <StatePill state={job.state === "succeeded" ? "available" : job.state} label={human(job.state)} /></p>
    <p>{running ? "Request accepted, not completed. Status is checked every 5 seconds." :
      job.state === "succeeded" ? "The operation completed successfully." : "The operation did not complete successfully. No side effect is retried automatically."}</p>
    <dl className="facts">
      {job.id && <div><dt>Job ID</dt><dd className="mono wrap">{job.id}</dd></div>}
      <div><dt>Phase</dt><dd>{human(job.phase)}</dd></div>
      {job.updatedAt && <div><dt>Last status update</dt><dd>{when(job.updatedAt)}</dd></div>}
      {job.reasonCode && <div><dt>Reason</dt><dd><code>{job.reasonCode}</code></dd></div>}
    </dl>
    <Requirements requirements={job.requirements} />
    {job.result != null && <details open={!running}><summary>Execution result and freshness</summary><pre className="json-preview">{JSON.stringify(job.result, null, 2)}</pre></details>}
  </div>;
}

function useOperationJob(projectId: string, onChanged: () => void) {
  const [id, setId] = useState<string | null>(() => rememberJob(projectId));
  const [job, setJob] = useState<Job | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [loading, setLoading] = useState(false);
  const [tick, setTick] = useState(0);
  const completed = useRef(new Set<string>());
  const changed = useRef(onChanged);
  changed.current = onChanged;
  useEffect(() => {
    if (!id) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      setLoading(true);
      try {
        const r = await api<Job>(`/api/v3/self-service/jobs/${encodeURIComponent(id)}`, { signal: controller.signal, refresh: true });
        if (controller.signal.aborted) return;
        if (r.data?.id !== id || r.data.projectId !== projectId || !["queued", "running", "succeeded", "blocked", "failed"].includes(r.data.state)) {
          throw new Error("The returned operation does not match this project or has an invalid status.");
        }
        setJob(r.data); setError(null);
        if (pending(r.data)) timer = setTimeout(poll, 5_000);
        else if (r.data.state === "succeeded" && !completed.current.has(id)) {
          completed.current.add(id); changed.current();
        }
      } catch (e) { if (!controller.signal.aborted) setError(e); }
      finally { if (!controller.signal.aborted) setLoading(false); }
    };
    void poll();
    return () => { controller.abort(); clearTimeout(timer); };
  }, [projectId, id, tick]);
  return { job, error, loading, id, reload: () => setTick((n) => n + 1),
    expired: error instanceof ApiFailure && (error.status === 404 || error.status === 410),
    dismiss: () => { forgetJob(projectId); setId(null); setJob(null); setError(null); },
    accept: (next: Job) => {
    rememberJob(projectId, next.id); setJob(next); setId(next.id); setError(null); setTick((n) => n + 1);
  } };
}

export function Operations({ projectId, etag, readOnly, onChanged, capabilities }: SelfServiceProps & { capabilities: Capabilities }) {
  const status = useOperationJob(projectId, onChanged);
  const [selected, setSelected] = useState<OperationKind | null>(null);
  const [reason, setReason] = useState("");
  const [review, setReview] = useState<OperationRequest | null>(null);
  const [busy, setBusy] = useState(false);
  const sending = useRef(false);
  const [error, setError] = useState<unknown>(null);
  const [denied, setDenied] = useState<Capabilities>({});
  useEffect(() => setDenied({}), [capabilities]);
  const effective = { ...capabilities, ...denied };
  const jobUnresolved = Boolean(status.id && (!status.job || pending(status.job)));
  const allowed = selected !== null && available(effective[selected]) && !readOnly && Boolean(etag);
  const stale = needsNewReview(error);
  const cancel = () => { setSelected(null); setReview(null); setReason(""); setError(null); };
  const confirm = async () => {
    if (!review || !allowed || stale || sending.current) return;
    sending.current = true; setBusy(true); setError(null);
    try {
      const r = await api<Job>(review.path, { method: "POST", body: review.body, ifMatch: review.ifMatch, idempotencyKey: review.idempotencyKey });
      if (r.status !== 202 || !jobIdValid(r.data?.id) || r.data.projectId !== projectId || r.data.kind !== review.body.kind) {
        throw new Error("The server did not return an accepted operation. Retry this same request to recover its status.");
      }
      status.accept(r.data); cancel();
    } catch (e) {
      setError(e);
      if (e instanceof ApiFailure && e.status === 403) setDenied((d) => ({ ...d,
        [review.body.kind]: { state: "permission_required", reason: e.code, requirements: failureRequirements(e) },
      }));
      if (needsNewReview(e)) onChanged();
    }
    finally { sending.current = false; setBusy(false); }
  };
  const prepare = () => {
    if (!selected || !etag || !allowed || !validReason(reason)) return;
    try { setReview(operationRequest(projectId, etag, selected, reason)); setError(null); }
    catch (e) { setError(e); }
  };
  return <Section title="Routing and Apply now" description="Review each operation before sending it. A queued or running job is not proof that the configuration is in effect.">
    {status.id && <div className="stack">
      {status.job ? <OperationProgress job={status.job} /> : status.loading ? <Loading label="Loading last operation" rows={2} /> : null}
      {Boolean(status.error) && <><ErrorNote error={status.error} retry={status.reload} /><FailureRequirements error={status.error} /></>}
      {status.expired && <><p className="hint">This job no longer has a retained status. Check current project state before reviewing a new operation. Dismissing does not repeat the operation.</p>
        <div className="form-actions"><Button size="small" onClick={status.dismiss}>Dismiss expired job</Button></div></>}
      <div className="form-actions"><Button size="small" variant="quiet" busy={status.loading} onClick={status.reload}>Refresh operation status</Button></div>
    </div>}
    {selected && allowed ? review && !stale ? <>
      <Review title={`Review ${LABELS[selected].toLowerCase()}`} changes={[
        { path: "operation", before: null, after: LABELS[selected] }, { path: "project", before: null, after: projectId },
        { path: "reason", before: null, after: review.body.reason },
      ]} busy={busy} error={error} confirmLabel={error ? "Retry same request" : `Confirm ${LABELS[selected].toLowerCase()}`} onConfirm={confirm} onCancel={cancel}
        note="Uses the reviewed project version. A retry sends the identical request and idempotency key; it does not start a second job. If the connection fails, retry here to recover the outcome." />
      <FailureRequirements error={error} />
    </> : <div className="stack">
      <h3>{LABELS[selected]}</h3>
      {stale && <><ErrorNote error={error} /><p className="hint">The project or operation state changed. Reload the project and review a new request.</p><Button onClick={cancel}>Close review</Button></>}
      {!stale && <><ReasonField reason={reason} setReason={setReason} />
        {Boolean(error) && <ErrorNote error={error} retry={prepare} />}
        <div className="form-actions"><Button variant="primary" disabled={!validReason(reason)} onClick={prepare}>Review operation</Button><Button variant="quiet" onClick={cancel}>Cancel</Button></div></>}
    </div> : <>
      {selected && <p className="notice notice-warn" role="status">This operation can no longer be submitted with the current permissions or project version.</p>}
      {Boolean(error) && <><ErrorNote error={error} /><FailureRequirements error={error} /></>}
      {!etag && !readOnly && <p className="hint">Reload the project to obtain its current version before running an operation.</p>}
      {jobUnresolved && <p className="hint">Resolve the last operation's status before starting another operation for this project.</p>}
      <OperationActions capabilities={effective} readOnly={readOnly} busy={busy || jobUnresolved || !etag} onSelect={(kind) => { cancel(); setSelected(kind); }} />
    </>}
  </Section>;
}
