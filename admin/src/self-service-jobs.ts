import { createHash } from "node:crypto";
import type { OperationJob, OperationStep, PermissionRequirement } from "./self-service-contracts.ts";

export interface DurableJob extends OperationJob {
  state: "queued" | OperationStep["state"];
  phase: string;
  updatedAt: string;
  expiresAt: string;
  nextAt: string;
  leaseOwner: string | null;
  leaseUntil: string | null;
  failures: number;
  reasonCode?: string;
  result?: Record<string, unknown>;
  requirements?: PermissionRequirement[];
}
export interface StoredJob { job: DurableJob; etag: string }
export interface JobStore {
  probe?(): Promise<void>;
  read(id: string): Promise<StoredJob | null>;
  create(job: DurableJob): Promise<boolean>;
  replace(job: DurableJob, etag: string): Promise<string | null>;
  runnable(now: string, limit: number): Promise<StoredJob[]>;
  lock(projectId: string, owner: string, now: string, until: string): Promise<boolean>;
  unlock(projectId: string, owner: string): Promise<void>;
}
export interface EnqueueInput extends Omit<OperationJob, "id" | "createdAt" | "checkpoint"> { key: string }
export type OperationExecutors = Partial<Record<OperationJob["kind"], (job: OperationJob) => Promise<OperationStep>>>;
const active = (job: DurableJob) => job.state === "queued" || job.state === "running";
const hash = (value: string) => createHash("sha256").update(value).digest("hex");
const fingerprint = (input: Pick<OperationJob, "kind" | "projectId" | "expectedEtag" | "actorOid" | "reason">) =>
  JSON.stringify([input.kind, input.projectId, input.expectedEtag, input.actorOid, input.reason]);

export async function findOperation(store: JobStore, input: EnqueueInput): Promise<DurableJob | null> {
  const prior = await store.read(hash(`${input.actorOid}:${input.key}`));
  if (!prior) return null;
  if (fingerprint(prior.job) !== fingerprint(input)) throw new Error("idempotency_conflict");
  return prior.job;
}

export async function enqueueOperation(store: JobStore, input: EnqueueInput, now: Date): Promise<DurableJob> {
  const id = hash(`${input.actorOid}:${input.key}`);
  const at = now.toISOString();
  const { key: _key, ...fields } = input;
  const job: DurableJob = {
    ...fields, id, createdAt: at, updatedAt: at, expiresAt: new Date(+now + 30 * 60_000).toISOString(),
    nextAt: at, state: "queued", phase: "queued", checkpoint: {}, leaseOwner: null, leaseUntil: null, failures: 0,
  };
  if (await store.create(job)) return job;
  const prior = await store.read(id);
  if (!prior || fingerprint(prior.job) !== fingerprint(input)) throw new Error("idempotency_conflict");
  return prior.job;
}

// One bounded step per tick. Both regional admin hosts compete through the same ETag and project
// lease; abandoned leases expire, but a completed external side effect must still be retry-safe.
export async function processOperations(
  store: JobStore,
  executors: OperationExecutors,
  context: { now(): Date; owner: string; log(line: string): void },
): Promise<void> {
  const at = context.now().toISOString();
  const candidates = await store.runnable(at, 10);
  for (const candidate of candidates) {
    if (!active(candidate.job) || candidate.job.nextAt > at || candidate.job.leaseUntil && candidate.job.leaseUntil > at) continue;
    const until = new Date(+context.now() + 5 * 60_000).toISOString();
    const owner = `${context.owner}:${candidate.job.id}`;
    if (!await store.lock(candidate.job.projectId, owner, at, until)) continue;
    try {
      const current = await store.read(candidate.job.id);
      if (!current || !active(current.job) || current.job.nextAt > at || current.job.leaseUntil && current.job.leaseUntil > at) continue;
      const claimed: DurableJob = { ...current.job, state: "running", updatedAt: at, leaseOwner: owner, leaseUntil: until };
      const etag = await store.replace(claimed, current.etag);
      if (!etag) continue;
      let next: DurableJob;
      try {
        const executor = executors[claimed.kind];
        const step: OperationStep = claimed.expiresAt <= at
          ? { state: "failed", phase: "expired", reason: "operation_expired" }
          : executor ? await executor(structuredClone(claimed))
            : { state: "blocked", phase: "disabled", reason: "feature_disabled" };
        next = {
          ...claimed, state: step.state, phase: step.phase, checkpoint: step.checkpoint ?? claimed.checkpoint,
          result: step.result, reasonCode: step.reason, requirements: step.requirements,
          updatedAt: context.now().toISOString(), nextAt: new Date(+context.now() + 15_000).toISOString(),
          leaseOwner: null, leaseUntil: null,
        };
      } catch {
        const failures = claimed.failures + 1;
        next = {
          ...claimed, state: failures >= 3 ? "failed" : "running", failures, phase: "retry_pending",
          reasonCode: "operation_unavailable", updatedAt: context.now().toISOString(),
          nextAt: new Date(+context.now() + failures * 30_000).toISOString(), leaseOwner: null, leaseUntil: null,
        };
      }
      if (!await store.replace(next, etag)) {
        context.log(JSON.stringify({ schema: "ccof.admin.operation.v1", id: claimed.id, code: "job_checkpoint_conflict" }));
      } else {
        context.log(JSON.stringify({ schema: "ccof.admin.operation.v1", id: claimed.id, projectId: claimed.projectId, kind: claimed.kind, state: next.state, phase: next.phase }));
      }
      return;
    } finally {
      try { await store.unlock(candidate.job.projectId, owner); } catch {
        context.log(JSON.stringify({ schema: "ccof.admin.operation.v1", id: candidate.job.id, code: "job_lease_release_failed" }));
      }
    }
  }
}

export function createMemoryJobStore(): JobStore & { jobs: Map<string, StoredJob> } {
  let version = 0;
  const jobs = new Map<string, StoredJob>();
  const locks = new Map<string, { owner: string; until: string }>();
  return {
    jobs,
    async read(id) { return structuredClone(jobs.get(id) ?? null); },
    async create(job) {
      if (jobs.has(job.id)) return false;
      jobs.set(job.id, { job: structuredClone(job), etag: String(++version) });
      return true;
    },
    async replace(job, etag) {
      if (jobs.get(job.id)?.etag !== etag) return null;
      const next = String(++version);
      jobs.set(job.id, { job: structuredClone(job), etag: next });
      return next;
    },
    async runnable(now, limit) {
      return [...jobs.values()].filter(({ job }) => active(job) && job.nextAt <= now && (!job.leaseUntil || job.leaseUntil <= now))
        .sort((a, b) => a.job.createdAt.localeCompare(b.job.createdAt)).slice(0, limit).map((value) => structuredClone(value));
    },
    async lock(projectId, owner, now, until) {
      const prior = locks.get(projectId);
      if (prior && prior.until > now) return false;
      locks.set(projectId, { owner, until });
      return true;
    },
    async unlock(projectId, owner) { if (locks.get(projectId)?.owner === owner) locks.delete(projectId); },
  };
}
