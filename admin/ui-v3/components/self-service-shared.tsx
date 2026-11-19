import { ApiFailure } from "../lib/api.ts";
import { CapabilityNotice, Field } from "./ui.tsx";
import type { Change } from "./ui.tsx";

export type OperationKind = "publish-routing" | "apply";
export interface Requirement { action: string; scope: string }
export interface Capability {
  state: "available" | "disabled" | "permission_required" | "unavailable";
  reason?: string;
  requirements?: Requirement[];
}
export type Capabilities = Partial<Record<OperationKind | "history", Capability>>;
export interface Job {
  id: string;
  kind: OperationKind;
  projectId: string;
  state: "queued" | "running" | "succeeded" | "blocked" | "failed";
  phase: string;
  createdAt: string;
  updatedAt: string;
  reasonCode?: string;
  requirements?: Requirement[];
  result?: unknown;
}
export interface HistoryVersion { versionId: string; createdAt: string; sourceEtag: string }
export interface HistoryPreview { versionId: string; etag: string; changes: Change[] }
export interface SelfServiceProps { projectId: string; etag: string | null; readOnly: boolean; onChanged: () => void }
export const LABELS: Record<OperationKind, string> = { "publish-routing": "Publish routing", apply: "Apply now" };
export const available = (cap?: Capability) => cap?.state === "available";
export const pending = (job: Pick<Job, "state"> | null) => job?.state === "queued" || job?.state === "running";
export const jobIdValid = (id: unknown): id is string => typeof id === "string" && /^[a-f0-9]{64}$/i.test(id);
export const projectPath = (id: string) => `/api/v3/projects/${encodeURIComponent(id)}`;

export function Requirements({ requirements }: { requirements?: Requirement[] }) {
  return requirements?.length ? <ul className="plain-list">{requirements.map((r, i) =>
    <li key={`${r.action}:${r.scope}:${i}`} className="wrap">Action: <code>{r.action}</code> · Scope: <code>{r.scope}</code></li>)}</ul> : null;
}

export function FeatureNotice({ cap, what }: { cap?: Capability; what: string }) {
  if (available(cap)) return null;
  return <><CapabilityNotice what={what} cap={cap ?? { state: "unavailable", reason: "capability_not_reported" }} />
    <Requirements requirements={cap?.requirements} /></>;
}

export function FailureRequirements({ error }: { error: unknown }) {
  return <Requirements requirements={failureRequirements(error)} />;
}

export function failureRequirements(error: unknown): Requirement[] {
  const body = error instanceof ApiFailure ? error.body : null;
  const capability = body?.capability;
  const requirements = capability && typeof capability === "object" && "requirements" in capability
    ? capability.requirements : body?.requirements;
  return Array.isArray(requirements) ? requirements.filter((r): r is Requirement =>
    r !== null && typeof r === "object" && typeof r.action === "string" && typeof r.scope === "string") : [];
}

export function validReason(reason: string) {
  return reason.trim().length >= 5 && reason.trim().length <= 500 && !/[\u0000-\u001f\u007f-\u009f]/.test(reason);
}

export function ReasonField({ reason, setReason, disabled }: { reason: string; setReason: (value: string) => void; disabled?: boolean }) {
  return <Field label="Reason for this operation" hint="5–500 characters, without control characters. Recorded with the operation."
    error={reason && !validReason(reason) ? "Enter a reason of 5–500 characters, without control characters." : null}>
    {(id, hint) => <input id={id} className="input" value={reason} maxLength={500} disabled={disabled}
      aria-describedby={hint} aria-invalid={Boolean(reason && !validReason(reason)) || undefined}
      onChange={(e) => setReason(e.target.value)} />}</Field>;
}

export function needsNewReview(error: unknown) {
  return error instanceof ApiFailure && (error.status === 409 || error.status === 412 || error.status === 428);
}

export interface OperationRequest {
  readonly path: string;
  readonly ifMatch: string;
  readonly idempotencyKey: string;
  readonly body: Readonly<{ kind: OperationKind; reason: string }>;
}

export function operationRequest(projectId: string, etag: string, kind: OperationKind, reason: string): OperationRequest {
  if (!etag || !validReason(reason)) throw new Error("A current project version and a valid reason are required.");
  return Object.freeze({ path: `${projectPath(projectId)}/operations`, ifMatch: etag,
    idempotencyKey: crypto.randomUUID(), body: Object.freeze({ kind, reason: reason.trim() }) });
}

export function rememberJob(projectId: string, id?: string): string | null {
  try {
    const key = `ccof:self-service:last-job:${projectId}`;
    if (id !== undefined && jobIdValid(id)) window.localStorage.setItem(key, id);
    const stored = window.localStorage.getItem(key);
    return jobIdValid(stored) ? stored : null;
  } catch { return null; }
}

export function forgetJob(projectId: string) {
  try { window.localStorage.removeItem(`ccof:self-service:last-job:${projectId}`); } catch { /* Storage can be disabled. */ }
}
