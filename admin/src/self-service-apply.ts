import type { FeatureCapability, OperationJob, OperationStep, PermissionRequirement } from "./self-service-contracts.ts";
import { sameRequest, readWorkerPairs } from "../../src/operations/apply-contracts.ts";
import type { ApplyPhase, ApplyRequest, ApplyReceipt, WorkerPair } from "../../src/operations/apply-contracts.ts";
export type { ApplyPhase, ApplyRequest, ApplyReceipt, WorkerPair } from "../../src/operations/apply-contracts.ts";
export class ApplyPermissionError extends Error {
  readonly requirements: PermissionRequirement[];
  constructor(requirements: PermissionRequirement[]) { super("apply_cosmos_permission_required"); this.requirements = requirements; }
}

export function isTransientApplyDependencyError(error: unknown, depth = 0): boolean {
  if (!error || typeof error !== "object" || depth > 2 || error instanceof ApplyPermissionError) return false;
  const value = error as { code?: unknown; statusCode?: unknown; status?: unknown; name?: unknown; cause?: unknown };
  const status = Number(value.statusCode ?? value.status ?? value.code);
  if (status === 401 || status === 403) return false;
  return status === 408 || status === 429 || status >= 500 && status <= 599 ||
    ["ETIMEDOUT", "ESOCKETTIMEDOUT", "ECONNRESET", "REQUEST_TIMEOUT"].includes(String(value.code)) ||
    ["TimeoutError", "RequestTimeoutError"].includes(String(value.name)) ||
    isTransientApplyDependencyError(value.cause, depth + 1);
}

export interface ApplyReceiptStore {
  // Durable create-only job+phase reservation. "existing" must never authorize a redispatch,
  // including when the original caller crashed before recording HTTP acceptance.
  reserve(request: ApplyRequest): Promise<"created" | "existing" | "busy">;
  // Only runtime-produced records, never an ARM acknowledgement or a telemetry snapshot.
  read(request: ApplyRequest): Promise<ApplyReceipt | null>;
}
export interface ApplyProvider {
  capability(pairs: WorkerPair[]): Promise<FeatureCapability>;
  settings(resourceId: string): Promise<Record<string, string | undefined>>;
  // Queued transports dispatch through the durable reservation itself.
  invoke?(resourceId: string, functionName: "syncEntitlement" | "reconcileBudgets"): Promise<"accepted">;
}
export interface ApplyDependencies {
  env: Readonly<Record<string, string | undefined>>;
  prerequisites?: (pairs: WorkerPair[]) => Promise<FeatureCapability>;
  provider?: ApplyProvider;
  receipts?: ApplyReceiptStore;
  projects: { read(projectId: string): Promise<{ etag: string } | null> };
  now?: () => Date;
}

const MAX_WAIT_MS = 20 * 60_000;
const object = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const deadline = (job: OperationJob) => "expiresAt" in job && typeof job.expiresAt === "string"
  ? Date.parse(job.expiresAt) : Date.parse(job.createdAt) + 30 * 60_000;

export const readApplyWorkerPairs = readWorkerPairs;

interface Checkpoint {
  phase: ApplyPhase;
  pair: WorkerPair;
  request: ApplyRequest;
  waiting: boolean;
  syncFinishedAt?: string;
}

function requestFor(job: OperationJob, phase: ApplyPhase, pair: WorkerPair, now: Date, syncFinishedAt?: string): ApplyRequest {
  return {
    projectId: job.projectId, expectedEtag: job.expectedEtag, pair: { ...pair },
    jobId: job.id, phase, resourceId: phase === "sync" ? pair.syncResourceId : pair.reconcilerResourceId,
    requestedAt: now.toISOString(), expiresAt: new Date(Math.min(now.getTime() + MAX_WAIT_MS, deadline(job))).toISOString(),
    ...(syncFinishedAt ? { syncFinishedAt } : {}),
  };
}

function checkpointOf(job: OperationJob, pairs: WorkerPair[]): Checkpoint | null {
  const c = job.checkpoint.apply;
  if (!object(c) || !["sync", "reconcile"].includes(String(c.phase)) || !object(c.pair) || !object(c.request) || typeof c.waiting !== "boolean") return null;
  const savedPair = c.pair;
  const pair = pairs.find((p) => p.region === savedPair.region && p.syncResourceId === savedPair.syncResourceId && p.reconcilerResourceId === savedPair.reconcilerResourceId);
  if (!pair) return null;
  const phase = c.phase as ApplyPhase;
  const request = c.request as unknown as ApplyRequest;
  if (request.jobId !== job.id || request.projectId !== job.projectId || request.expectedEtag !== job.expectedEtag ||
    !request.pair || !sameRequest(request, { ...request, pair }) || request.phase !== phase ||
    request.resourceId !== (phase === "sync" ? pair.syncResourceId : pair.reconcilerResourceId) ||
    typeof request.requestedAt !== "string" || typeof request.expiresAt !== "string" ||
    !Number.isFinite(Date.parse(request.requestedAt)) || !Number.isFinite(Date.parse(request.expiresAt)) ||
    Date.parse(request.expiresAt) <= Date.parse(request.requestedAt) ||
    Date.parse(request.expiresAt) - Date.parse(request.requestedAt) > MAX_WAIT_MS || Date.parse(request.expiresAt) > deadline(job) ||
    (phase === "sync" && request.syncFinishedAt !== undefined) ||
    (phase === "reconcile" && (typeof c.syncFinishedAt !== "string" || request.syncFinishedAt !== c.syncFinishedAt || !Number.isFinite(Date.parse(c.syncFinishedAt))))) return null;
  return { phase, pair, request, waiting: c.waiting, ...(typeof c.syncFinishedAt === "string" ? { syncFinishedAt: c.syncFinishedAt } : {}) };
}

async function activePair(provider: ApplyProvider, pairs: WorkerPair[]): Promise<WorkerPair | null> {
  const all = await Promise.all(pairs.map(async (pair) => ({
    pair, sync: await provider.settings(pair.syncResourceId), rec: await provider.settings(pair.reconcilerResourceId),
  })));
  const enabled: WorkerPair[] = [];
  for (const { pair, sync, rec } of all) {
    if (sync.CCOF_APP_ROLE !== "sync" || rec.CCOF_APP_ROLE !== "reconciler") return null;
    const sd = sync["AzureWebJobs.syncEntitlement.Disabled"], rd = rec["AzureWebJobs.reconcileBudgets.Disabled"];
    if (!["true", "false"].includes(sd ?? "") || !["true", "false"].includes(rd ?? "") || sd !== rd) return null;
    if (sd === "false") {
      if (sync.SYNC_WRITE_MODE !== "apply") return null;
      enabled.push(pair);
    }
  }
  return enabled.length === 1 ? enabled[0] : null;
}

function validReceipt(receipt: ApplyReceipt, c: Checkpoint, now: Date): boolean {
  if (!sameRequest(receipt, c.request) || typeof receipt.startedAt !== "string") return false;
  const started = Date.parse(receipt.startedAt), finished = Date.parse(receipt.finishedAt ?? "");
  const lower = Math.max(Date.parse(c.request.requestedAt), Date.parse(c.syncFinishedAt ?? c.request.requestedAt));
  return Number.isFinite(started) && started >= lower && started <= now.getTime() &&
    (receipt.state === "running" || (Number.isFinite(finished) && finished >= started && finished <= now.getTime() && finished <= Date.parse(c.request.expiresAt)));
}

export function createApplyExecutor(dependencies: ApplyDependencies) {
  const { env, provider, receipts, projects } = dependencies;
  const now = dependencies.now ?? (() => new Date());
  const pairs = readApplyWorkerPairs(env.ADMIN_WORKER_RESOURCE_IDS);
  async function checkCapability(retryTransient: boolean): Promise<FeatureCapability> {
    if (env.ADMIN_APPLY_ENABLED !== "true") return { state: "disabled", reason: "apply_disabled", requirements: [] };
    if (!pairs) return { state: "unavailable", reason: "worker_targets_invalid", requirements: [] };
    try {
      const prerequisite = await dependencies.prerequisites?.(structuredClone(pairs));
      if (prerequisite && prerequisite.state !== "available") return prerequisite;
      // The documented manual-run transport requires a master key. The candidate ARM proxy's
      // URL/API contract is unverified; never substitute keys, timer writes or a snapshot run.
      if (!provider) return { state: "unavailable", reason: "apply_transport_unverified", requirements: [] };
      if (!receipts) return { state: "unavailable", reason: "apply_receipts_unavailable", requirements: [] };
      return await provider.capability(pairs);
    }
    catch (error) {
      if (retryTransient && isTransientApplyDependencyError(error)) throw new Error("apply_dependency_unavailable");
      return { state: "unavailable", reason: "apply_preflight_unavailable", requirements: [] };
    }
  }
  async function advance(job: OperationJob): Promise<OperationStep> {
    const cap = await checkCapability(true);
    if (cap.state !== "available") return { state: "blocked", phase: "preflight", reason: cap.reason ?? cap.state, requirements: cap.requirements };
    if (job.kind !== "apply" || !/^[A-Za-z0-9_-]{1,128}$/.test(job.id) || !Number.isFinite(deadline(job)))
      return { state: "blocked", phase: "preflight", reason: "apply_job_invalid" };
    if (now().getTime() >= deadline(job)) return { state: "failed", phase: "preflight", reason: "apply_job_expired" };
    try {
      const current = await projects.read(job.projectId);
      if (!current || current.etag !== job.expectedEtag) return { state: "blocked", phase: "preflight", reason: "project_changed" };
      const active = await activePair(provider!, pairs!);
      if (!active) return { state: "blocked", phase: "preflight", reason: "writer_fence_unverified" };
      const stored = checkpointOf(job, pairs!);
      if (job.checkpoint.apply !== undefined && !stored) return { state: "blocked", phase: "preflight", reason: "apply_checkpoint_invalid" };
      const c: Checkpoint = stored ?? { phase: "sync", pair: active, request: requestFor(job, "sync", active, now()), waiting: false };
      if (c.pair.region !== active.region) return { state: "blocked", phase: "preflight", reason: "writer_changed" };
      const save = (phase: string): OperationStep => ({ state: "running", phase, checkpoint: { ...job.checkpoint, apply: { ...c } } });
      if (!stored) return save("sync-ready");
      if (now().getTime() >= Date.parse(c.request.expiresAt)) return { state: "failed", phase: `${c.phase}-waiting`, reason: "runtime_completion_unknown" };
      if (!c.waiting) {
        let reservation: "created" | "existing" | "busy";
        try { reservation = await receipts!.reserve(c.request); } catch (error) {
          if (error instanceof ApplyPermissionError || isTransientApplyDependencyError(error)) throw error;
          // A lost enqueue acknowledgement can safely retry the same create-only ID. Workers'
          // processing claims, not transport acknowledgements, authorize at-most-once execution.
          return save(`${c.phase}-queueing`);
        }
        if (reservation === "busy") return { state: "blocked", phase: `${c.phase}-ready`, reason: "worker_operation_busy" };
        // Reservation is durable before dispatch. An ambiguous timeout never re-dispatches: it
        // waits for a correlated receipt and reports unknown completion if none becomes visible.
        if (reservation === "created" && provider!.invoke) {
          try { await provider!.invoke(c.request.resourceId, c.phase === "sync" ? "syncEntitlement" : "reconcileBudgets"); }
          catch { /* Acceptance is unknown; only a runtime receipt can establish completion. */ }
        }
        c.waiting = true;
        return save(`${c.phase}-waiting`);
      }
      const receipt = await receipts!.read(c.request);
      if (!receipt) return save(`${c.phase}-waiting`);
      if (!validReceipt(receipt, c, now())) return { state: "blocked", phase: `${c.phase}-waiting`, reason: "runtime_receipt_invalid" };
      if (receipt.state === "running") return save(`${c.phase}-waiting`);
      if (receipt.state !== "succeeded" || receipt.guarded !== false) return {
        state: "blocked", phase: `${c.phase}-waiting`, reason: receipt.reason ?? "runtime_guarded_or_failed", requirements: receipt.requirements,
      };
      if (c.phase === "sync") {
        if (receipt.source !== "graph" || receipt.writeMode !== "apply" || receipt.outcome !== "succeeded")
          return { state: "blocked", phase: "sync-waiting", reason: "graph_sync_not_completed" };
        c.syncFinishedAt = receipt.finishedAt;
        c.phase = "reconcile";
        c.waiting = false;
        c.request = requestFor(job, "reconcile", active, now(), c.syncFinishedAt);
        return save("reconcile-ready");
      }
      if (receipt.outcome !== "written" || !Number.isFinite(Date.parse(receipt.validUntil ?? "")) || Date.parse(receipt.validUntil!) <= now().getTime())
        return { state: "blocked", phase: "reconcile-waiting", reason: "budget_state_not_fresh" };
      return {
        state: "succeeded", phase: "completed",
        result: { syncFinishedAt: c.syncFinishedAt, reconciledAt: receipt.finishedAt, budgetValidUntil: receipt.validUntil, region: active.region },
      };
    } catch (error) {
      if (error instanceof ApplyPermissionError) return { state: "blocked", phase: "preflight", reason: "apply_cosmos_permission_required", requirements: error.requirements };
      if (isTransientApplyDependencyError(error)) throw new Error("apply_dependency_unavailable");
      return { state: "blocked", phase: "preflight", reason: "apply_dependency_unavailable" };
    }
  }
  return { capability: () => checkCapability(false), advance };
}
