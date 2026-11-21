import { createHash } from "node:crypto";

export type ApplyPhase = "sync" | "reconcile";
export interface WorkerPair { region: string; syncResourceId: string; reconcilerResourceId: string }
export interface ApplyRequest {
  jobId: string;
  projectId: string;
  expectedEtag: string;
  pair: WorkerPair;
  phase: ApplyPhase;
  resourceId: string;
  requestedAt: string;
  expiresAt: string;
  syncFinishedAt?: string;
}
export interface ApplyReceipt extends ApplyRequest {
  state: "running" | "succeeded" | "failed" | "blocked";
  startedAt: string;
  finishedAt?: string;
  outcome?: string;
  source?: string;
  writeMode?: string;
  guarded?: boolean;
  validUntil?: string;
  reason?: string;
  requirements?: Array<{ action: string; scope: string }>;
}
export interface ApplyHeartbeat {
  resourceId: string;
  phase: ApplyPhase;
  region: string;
  configurationId: string;
  observedAt: string;
  disabled: "true" | "false" | "unknown";
  writeMode: string;
  graphPermission?: "granted" | "permission_required" | "unknown";
  identityResourceId?: string;
}
export interface ProcessingLease { id: string; etag: string; owner: string; until: string }
export interface ApplyStore {
  heartbeat(value: ApplyHeartbeat): Promise<void>;
  heartbeats(pairs: WorkerPair[]): Promise<Array<ApplyHeartbeat | null>>;
  enqueue(request: ApplyRequest): Promise<"created" | "existing">;
  readRequest(jobId: string, phase: ApplyPhase): Promise<ApplyRequest | null>;
  readReceipt(request: ApplyRequest): Promise<ApplyReceipt | null>;
  pending(target: string, now: Date): Promise<ApplyRequest[]>;
  claim(request: ApplyRequest, owner: string, now: Date): Promise<ProcessingLease | "busy" | "finished">;
  renew(request: ApplyRequest, lease: ProcessingLease, now: Date): Promise<boolean>;
  complete(request: ApplyRequest, lease: ProcessingLease, receipt: ApplyReceipt, now: Date): Promise<void>;
}

const digest = (value: string) => createHash("sha256").update(value).digest("hex");
export const requestId = (request: Pick<ApplyRequest, "jobId" | "phase">) => `apply-request-${digest(request.jobId)}-${request.phase}`;
export const heartbeatId = (resourceId: string) => `apply-worker-${digest(resourceId.toLowerCase())}`;
export const configurationId = (pairs: WorkerPair[]) => digest(JSON.stringify(pairs.map((p) =>
  [p.region, p.syncResourceId.toLowerCase(), p.reconcilerResourceId.toLowerCase()]).sort((a, b) => a[0].localeCompare(b[0]))));
export const samePair = (a: WorkerPair, b: WorkerPair) => a.region === b.region &&
  a.syncResourceId === b.syncResourceId && a.reconcilerResourceId === b.reconcilerResourceId;
export function sameRequest(a: ApplyRequest, b: ApplyRequest): boolean {
  return ["jobId", "projectId", "expectedEtag", "phase", "resourceId", "requestedAt", "expiresAt", "syncFinishedAt"].every(
    (key) => a[key as keyof ApplyRequest] === b[key as keyof ApplyRequest]) && !!a.pair && !!b.pair && samePair(a.pair, b.pair);
}
export function readWorkerPairs(value: string | undefined): WorkerPair[] | null {
  const site = /^\/subscriptions\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/resourceGroups\/[A-Za-z0-9_.()-]{1,90}\/providers\/Microsoft\.Web\/sites\/[A-Za-z0-9-]{2,60}$/i;
  try {
    const raw: unknown = JSON.parse(value ?? "");
    if (!Array.isArray(raw) || !raw.length || raw.length > 10) return null;
    const regions = new Set<string>(), ids = new Set<string>();
    for (const pair of raw) {
      if (!pair || typeof pair !== "object" || Object.keys(pair).some((key) => !["region", "syncResourceId", "reconcilerResourceId"].includes(key)) ||
        typeof pair.region !== "string" || !/^[A-Za-z0-9-]{1,30}$/.test(pair.region) || regions.has(pair.region.toLowerCase())) return null;
      regions.add(pair.region.toLowerCase());
      for (const key of ["syncResourceId", "reconcilerResourceId"]) {
        const id = pair[key];
        if (typeof id !== "string" || !site.test(id) || ids.has(id.toLowerCase())) return null;
        ids.add(id.toLowerCase());
      }
    }
    return raw as WorkerPair[];
  } catch { return null; }
}
export function activeHeartbeatPair(pairs: WorkerPair[], beats: Array<ApplyHeartbeat | null>, now: Date): WorkerPair | null {
  if (!pairs.length || beats.length !== pairs.length * 2) return null;
  const active: WorkerPair[] = [], fingerprint = configurationId(pairs);
  for (let index = 0; index < pairs.length; index++) {
    const pair = pairs[index], sync = beats[index * 2], rec = beats[index * 2 + 1];
    if (!sync || !rec) return null;
    for (const [beat, phase, resourceId] of [[sync, "sync", pair.syncResourceId], [rec, "reconcile", pair.reconcilerResourceId]] as const) {
      const age = now.getTime() - Date.parse(beat.observedAt);
      if (beat.configurationId !== fingerprint || beat.phase !== phase || beat.region !== pair.region || beat.resourceId !== resourceId ||
        !Number.isFinite(age) || age < -5_000 || age > 45_000 || !["true", "false"].includes(beat.disabled)) return null;
    }
    if (sync.disabled !== rec.disabled) return null;
    if (sync.disabled === "false") {
      if (sync.writeMode !== "apply") return null;
      active.push(pair);
    }
  }
  return active.length === 1 ? active[0] : null;
}
export function validRequest(request: ApplyRequest, pairs: WorkerPair[], now: Date): boolean {
  if (!request || !/^[A-Za-z0-9_-]{1,128}$/.test(request.jobId) || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/.test(request.projectId) ||
    typeof request.expectedEtag !== "string" || !request.expectedEtag || request.expectedEtag.length > 256 || !request.pair ||
    !pairs.some((p) => samePair(p, request.pair)) || !["sync", "reconcile"].includes(request.phase)) return false;
  const start = Date.parse(request.requestedAt), end = Date.parse(request.expiresAt);
  return Number.isFinite(start) && Number.isFinite(end) && start <= now.getTime() && end > now.getTime() &&
    end - start > 0 && end - start <= 20 * 60_000 && request.resourceId === (request.phase === "sync" ? request.pair.syncResourceId : request.pair.reconcilerResourceId) &&
    (request.phase === "sync" ? request.syncFinishedAt === undefined : Number.isFinite(Date.parse(request.syncFinishedAt ?? "")) && Date.parse(request.syncFinishedAt!) <= start);
}
