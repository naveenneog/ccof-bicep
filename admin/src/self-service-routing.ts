import { createHash } from "node:crypto";
import type { ProjectStore } from "./api.ts";
import type { RegistryStore } from "./backend-routing.ts";
import { routingPlan } from "./backend-routing.ts";
import { failoverProblems, registeredBackendProblems } from "../../src/contracts/project-routing.ts";
import { canonical, isObject, stripSystem } from "./validation.ts";
import type { Doc } from "./validation.ts";
import type { FeatureCapability, OperationJob, OperationStep, PermissionRequirement } from "./self-service-contracts.ts";
import { readRoutingTargets, ROUTING_BACKEND_ACTIONS, RoutingProviderError } from "./self-service-routing-arm.ts";
import type { RoutingProvider } from "./self-service-routing-arm.ts";
import { routingMemberBody, routingPoolBody, routingResourceMatches } from "./self-service-routing-resources.ts";

export interface RoutingRegistryVersion { backendId: string; etag: string }
export interface RoutingPublisherDependencies {
  env: Readonly<Record<string, string | undefined>>;
  projects: Pick<ProjectStore, "read" | "replace">;
  registry: Pick<RegistryStore, "list">;
  provider: RoutingProvider;
  // Must durably append idempotent intent (job ID + phase + target + planHash) and reject on failure.
  // Called before ARM changes and promotion; retries may repeat an already acknowledged intent.
  audit(job: OperationJob, record: Doc): Promise<void>;
  // Mandatory distributed/transactional boundary, honored by EVERY registry mutation in both
  // regions. Compare these versions, hold the fence through run(), return null on contention.
  // A local mutex, independent lease, or reread-before-CAS is NOT a valid implementation.
  withRegistryFence?: (versions: RoutingRegistryVersion[], run: () => Promise<OperationStep>) => Promise<OperationStep | null>;
  now?: () => Date;
}

class RoutingBlocked extends Error {}
const hash = (value: unknown) => createHash("sha256").update(canonical(value)).digest("hex");
const denied = (error: RoutingProviderError): PermissionRequirement[] => [{ action: error.action, scope: error.scope }];

async function bounded<T, R>(items: T[], concurrency: number, run: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = [];
  let next = 0, failed = false;
  let error: unknown;
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (!failed && next < items.length) {
      const index = next++;
      try { results[index] = await run(items[index]); }
      catch (caught) { failed = true; error = caught; }
    }
  }));
  // Drain in-flight writes before releasing the distributed fence or returning to the job engine.
  if (failed) throw error;
  return results;
}

export function createRoutingPublisher(deps: RoutingPublisherDependencies): {
  capability(): Promise<FeatureCapability>;
  advance(job: OperationJob): Promise<OperationStep>;
} {
  const now = deps.now ?? (() => new Date());
  function configured(): string[] | FeatureCapability {
    if (deps.env.ADMIN_ROUTING_PUBLISH_ENABLED !== "true") return { state: "disabled", requirements: [] };
    if (!deps.withRegistryFence) return { state: "unavailable", reason: "routing_registry_fence_unavailable", requirements: [] };
    try { return readRoutingTargets(deps.env); } catch { return { state: "unavailable", reason: "admin_gateway_resource_ids_invalid", requirements: [] }; }
  }
  async function capability(): Promise<FeatureCapability> {
    const targets = configured();
    if (!Array.isArray(targets)) return targets;
    const missing: PermissionRequirement[] = [];
    try {
      await bounded(targets.flatMap((scope) => ROUTING_BACKEND_ACTIONS.map((action) => ({ scope, action }))), 4,
        async ({ scope, action }) => { if (!await deps.provider.permitted(scope, action)) missing.push({ action, scope }); });
      return missing.length ? { state: "permission_required", reason: "routing_permission_required", requirements: missing } :
        { state: "available", requirements: [] };
    } catch (error) {
      if (error instanceof RoutingProviderError && [401, 403].includes(error.status)) {
        return { state: "permission_required", reason: "routing_permission_required", requirements: denied(error) };
      }
      return { state: "unavailable", reason: "routing_permission_preflight_unavailable", requirements: [] };
    }
  }
  async function advance(job: OperationJob): Promise<OperationStep> {
    const targets = configured();
    if (!Array.isArray(targets)) return { state: "blocked", phase: "capability", reason: targets.reason ?? targets.state, requirements: targets.requirements };
    if (job.kind !== "publish-routing" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/.test(job.projectId) ||
      !job.expectedEtag || job.expectedEtag === "*" || !job.reason.trim() || !job.actorOid) {
      return { state: "blocked", phase: "validation", reason: "routing_job_invalid" };
    }
    try {
      const current = await deps.projects.read(job.projectId);
      if (!current) throw new RoutingBlocked("etag_mismatch");
      const recovering = current.etag !== job.expectedEtag &&
        hash(stripSystem(current.doc)) === job.checkpoint.routingPromotedHash;
      if (current.etag !== job.expectedEtag && !recovering) throw new RoutingBlocked("etag_mismatch");
      if (current.doc.projectId !== job.projectId || current.doc.status !== "active" || !isObject(current.doc.failover) ||
        current.doc.failover.enabled !== true || failoverProblems(current.doc.failover, current.doc.backendId).length ||
        Number(current.doc.failover.revision) > 999999999) throw new RoutingBlocked("routing_project_not_publishable");
      const entries = await deps.registry.list();
      const ids = [current.doc.backendId, ...(current.doc.failover.fallbackBackendIds as string[])];
      const selected = entries.filter((entry) => ids.includes(entry.doc.backendId)).sort((a, b) => a.doc.backendId.localeCompare(b.doc.backendId));
      if (selected.length !== ids.length || selected.some((e) => !e.etag || registeredBackendProblems(e.doc).length)) {
        throw new RoutingBlocked("routing_registry_invalid");
      }
      const plan = routingPlan(current.doc, new Map(selected.map((e) => [e.doc.backendId, e.doc])));
      if (plan.problems.length || plan.members.length < 2) throw new RoutingBlocked("routing_plan_incompatible");
      const versions = selected.map((e) => ({ backendId: e.doc.backendId, etag: e.etag }));
      const registryHash = hash(selected);
      const base = stripSystem(current.doc);
      const configuration = { ...base, failover: { ...current.doc.failover, active: null } };
      const planHash = hash({ job: { id: job.id, projectId: job.projectId, expectedEtag: job.expectedEtag,
        actorOid: job.actorOid, reason: job.reason }, project: configuration, registryHash, targets, plan });
      const verifiedAt = typeof job.checkpoint.routingVerifiedAt === "string" ? job.checkpoint.routingVerifiedAt : null;
      const active = { revision: plan.revision, poolBackendId: plan.poolBackendId, verifiedAt };
      const after = { ...base, failover: { ...current.doc.failover, active } };
      const promotedHash = hash(after);
      const checkpoint = { ...job.checkpoint, routingPlanHash: planHash };
      if (job.checkpoint.routingPlanHash === undefined) return { state: "running", phase: "planned", checkpoint };
      if (job.checkpoint.routingPlanHash !== planHash ||
        (job.checkpoint.routingPromotedHash !== undefined && job.checkpoint.routingPromotedHash !== promotedHash)) throw new RoutingBlocked("routing_plan_changed");
      const cursor = job.checkpoint.routingNextTarget ?? 0;
      if (typeof cursor !== "number" || !Number.isInteger(cursor) || cursor < 0 || cursor > targets.length ||
        (recovering && cursor !== targets.length)) throw new RoutingBlocked("routing_checkpoint_invalid");
      async function assertRegistry() {
        const fresh = (await deps.registry.list()).filter((e) => ids.includes(e.doc.backendId)).sort((a, b) => a.doc.backendId.localeCompare(b.doc.backendId));
        if (hash(fresh) !== registryHash) throw new RoutingBlocked("routing_registry_changed");
      }
      const result = await deps.withRegistryFence!(versions, async () => {
        await assertRegistry();
        const scopes = cursor < targets.length ? [targets[cursor]] : targets;
        if (cursor < targets.length) {
          const missing: PermissionRequirement[] = [];
          await bounded([...ROUTING_BACKEND_ACTIONS], 2, async (action) => {
            if (!await deps.provider.permitted(scopes[0], action)) missing.push({ action, scope: scopes[0] });
          });
          if (missing.length) return { state: "blocked", phase: "capability", reason: "routing_permission_required", requirements: missing, checkpoint };
        }
        const tasks = scopes.flatMap((scope) => [
          ...plan.members.map((member) => ({ scope, member, id: member.memberBackendId })),
          { scope, member: null, id: plan.poolBackendId },
        ]);
        // One gateway's writes per advance; final all-gateway verification has at most 60 entities.
        // Sixteen bounded readers × 15-second ARM deadlines leave storage/audit time in the lease.
        const resources = await bounded(tasks, cursor < targets.length ? 6 : 16, async ({ scope, member, id }) => {
          let body: Doc;
          if (member) {
            const source = await deps.provider.backend(scope, member.backendId);
            try { body = routingMemberBody(member, plan.projectId, source); }
            catch { throw new RoutingBlocked("routing_source_backend_mismatch"); }
          } else body = routingPoolBody(plan, scope);
          const actual = await deps.provider.backend(scope, id);
          if (cursor === targets.length && !actual) throw new RoutingBlocked("routing_readback_mismatch");
          if (actual && !routingResourceMatches(body, actual)) throw new RoutingBlocked("routing_resource_conflict");
          return { scope, id, body, missing: actual === null };
        });
        if (cursor < targets.length) {
          await deps.audit(job, { phase: "publish", revision: plan.revision, poolBackendId: plan.poolBackendId,
            target: scopes[0], backendIds: resources.map((r) => r.id), planHash });
          await assertRegistry();
          await bounded(resources.filter((r) => r.missing && r.id !== plan.poolBackendId), 3,
            async (r) => { await deps.provider.putBackend(r.scope, r.id, r.body); });
          const pool = resources.find((r) => r.id === plan.poolBackendId)!;
          if (pool.missing) await deps.provider.putBackend(pool.scope, pool.id, pool.body);
          const matches = await bounded(resources, 6,
            async (r) => routingResourceMatches(r.body, await deps.provider.backend(r.scope, r.id)));
          if (matches.some((match) => !match)) return { state: "failed", phase: "verification", reason: "routing_readback_mismatch", checkpoint };
          await assertRegistry();
          return { state: "running", phase: "gateway_verified", checkpoint: { ...checkpoint, routingNextTarget: cursor + 1 } };
        }
        await assertRegistry();
        if (verifiedAt === null) {
          const observedAt = now().toISOString();
          const promoted = { ...after, failover: { ...after.failover, active: { ...active, verifiedAt: observedAt } } };
          return { state: "running", phase: "verified", checkpoint: { ...checkpoint,
            routingVerifiedAt: observedAt, routingPromotedHash: hash(promoted) } };
        }
        await deps.audit(job, { phase: "activate", revision: plan.revision, poolBackendId: plan.poolBackendId,
          verifiedTargets: targets, planHash });
        await assertRegistry();
        const latest = await deps.projects.read(job.projectId);
        if (recovering) {
          if (!latest || hash(stripSystem(latest.doc)) !== promotedHash) throw new RoutingBlocked("etag_mismatch");
          return { state: "succeeded", phase: "published", checkpoint,
            result: { projectId: plan.projectId, revision: plan.revision, poolBackendId: plan.poolBackendId,
              verifiedTargets: targets, etag: latest.etag, recovered: true } };
        }
        if (!latest || latest.etag !== job.expectedEtag) throw new RoutingBlocked("etag_mismatch");
        const etag = await deps.projects.replace(after, job.expectedEtag);
        if (etag === "precondition_failed") throw new RoutingBlocked("etag_mismatch");
        return { state: "succeeded", phase: "published", checkpoint,
          result: { projectId: plan.projectId, revision: plan.revision, poolBackendId: plan.poolBackendId, verifiedTargets: targets, etag } };
      });
      return result ?? { state: "blocked", phase: "registry", reason: "routing_registry_fence_contended", checkpoint };
    } catch (error) {
      if (error instanceof RoutingBlocked) return { state: "blocked", phase: "publication", reason: error.message, checkpoint: job.checkpoint };
      if (error instanceof RoutingProviderError && [401, 403].includes(error.status)) {
        return { state: "blocked", phase: "publication", reason: "routing_permission_required", requirements: denied(error), checkpoint: job.checkpoint };
      }
      // Transport/throttling failures are deliberately thrown to the durable engine's bounded retry.
      if (error instanceof RoutingProviderError && [408, 429, 500, 502, 503, 504].includes(error.status)) throw error;
      if (error instanceof Error && ["TimeoutError", "AbortError", "TypeError"].includes(error.name)) throw error;
      return { state: "failed", phase: "publication", reason: "routing_publication_failed", checkpoint: job.checkpoint };
    }
  }
  return { capability, advance };
}
