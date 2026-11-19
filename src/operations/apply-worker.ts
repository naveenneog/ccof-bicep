import { randomUUID } from "node:crypto";
import { activeHeartbeatPair, configurationId, readWorkerPairs, samePair, validRequest } from "./apply-contracts.ts";
import type { ApplyHeartbeat, ApplyPhase, ApplyReceipt, ApplyRequest, ApplyStore, WorkerPair } from "./apply-contracts.ts";
import type { GraphPermissionProof } from "./apply-graph.ts";

export interface ApplyWorkerDependencies {
  env: Readonly<Record<string, string | undefined>>;
  store: ApplyStore;
  projects: { read(projectId: string): Promise<{ etag: string; status: string } | null> };
  run(request: ApplyRequest, ensureCurrent: () => Promise<void>): Promise<unknown>;
  graphPermission?(): Promise<GraphPermissionProof>;
  now?: () => Date;
}
const object = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null;
const fenceName = (phase: ApplyPhase) => phase === "sync" ? "AzureWebJobs.syncEntitlement.Disabled" : "AzureWebJobs.reconcileBudgets.Disabled";

function localConfiguration(env: ApplyWorkerDependencies["env"]) {
  if (env.CCOF_APPLY_WORKER_ENABLED !== "true") return null;
  const phase: ApplyPhase | null = env.CCOF_APP_ROLE === "sync" ? "sync" : env.CCOF_APP_ROLE === "reconciler" ? "reconcile" : null;
  const pairs = readWorkerPairs(env.CCOF_APPLY_WORKER_PAIRS);
  if (!phase || !pairs || pairs.length < 2) return null;
  const resourceId = env.CCOF_APPLY_WORKER_RESOURCE_ID;
  const pair = pairs.find((p) => resourceId === (phase === "sync" ? p.syncResourceId : p.reconcilerResourceId));
  if (!pair || !resourceId) return null;
  const fence = env[fenceName(phase)];
  const heartbeat: ApplyHeartbeat = {
    resourceId, phase, region: pair.region, configurationId: configurationId(pairs), observedAt: "",
    disabled: fence === "true" || fence === "false" ? fence : "unknown",
    writeMode: phase === "sync" ? env.SYNC_WRITE_MODE ?? "" : "",
  };
  return { pairs, pair, phase, heartbeat };
}

function summarize(request: ApplyRequest, result: unknown, startedAt: string, finishedAt: string, identityResourceId?: string): ApplyReceipt {
  const base: ApplyReceipt = { ...request, state: "failed", startedAt, finishedAt, guarded: true, reason: "runtime_result_invalid" };
  if (!object(result)) return base;
  if (request.phase === "sync") {
    const reasons = Array.isArray(result.reasons) ? result.reasons : [];
    const refusals = Array.isArray(result.refusals) ? result.refusals : [];
    if ([...reasons, ...refusals].includes("graph_permission_missing")) return {
      ...base, state: "blocked", reason: "sync_graph_application_permission_required",
      requirements: [{ action: "Microsoft Graph application GroupMember.Read.All", scope: identityResourceId ?? request.resourceId }],
    };
    if (result.outcome === "succeeded" && result.source === "graph" && result.writeMode === "apply" &&
      Array.isArray(result.reasons) && reasons.length === 0 && Array.isArray(result.refusals) && refusals.length === 0)
      return { ...base, state: "succeeded", guarded: false, outcome: "succeeded", source: "graph", writeMode: "apply", reason: undefined };
    return { ...base, state: "blocked", reason: "graph_sync_guarded_or_failed" };
  }
  const computed = typeof result.computedAt === "string" ? Date.parse(result.computedAt) : NaN;
  const validUntil = typeof result.validUntil === "string" ? Date.parse(result.validUntil) : NaN;
  if (result.outcome === "written" && result.reason === null && result.completeness === "complete" &&
    (!Array.isArray(result.problems) || result.problems.length === 0) &&
    Number.isFinite(computed) && computed >= Date.parse(startedAt) && computed <= Date.parse(finishedAt) && validUntil > Date.parse(finishedAt))
    return { ...base, state: "succeeded", guarded: false, outcome: "written", validUntil: new Date(validUntil).toISOString(), reason: undefined };
  return { ...base, state: "blocked", reason: "reconciler_guarded_or_failed" };
}

export function createApplyWorker(dependencies: ApplyWorkerDependencies) {
  const { env, store, projects } = dependencies;
  const now = dependencies.now ?? (() => new Date());
  async function projectMatches(request: ApplyRequest) {
    const project = await projects.read(request.projectId);
    return project?.etag === request.expectedEtag && project.status === "active";
  }
  async function currentPair(pairs: WorkerPair[]) {
    return activeHeartbeatPair(pairs, await store.heartbeats(pairs), now());
  }
  async function publish(local: NonNullable<ReturnType<typeof localConfiguration>>) {
    let graph: GraphPermissionProof | undefined;
    if (local.phase === "sync") {
      try { graph = await dependencies.graphPermission?.(); } catch { /* No token/provider details enter heartbeat records. */ }
    }
    const heartbeat: ApplyHeartbeat = {
      ...local.heartbeat, observedAt: now().toISOString(),
      ...(local.phase === "sync" ? { graphPermission: graph?.state ?? "unknown", identityResourceId: graph?.identityResourceId } : {}),
    };
    await store.heartbeat(heartbeat);
  }
  async function syncSucceeded(request: ApplyRequest) {
    if (request.phase === "sync") return true;
    // Locate the immutable preceding request, never a generic "last sync" timestamp.
    const sync = await store.readRequest(request.jobId, "sync");
    if (!sync || sync.projectId !== request.projectId || sync.expectedEtag !== request.expectedEtag || !samePair(sync.pair, request.pair) ||
      !validRequest(sync, [request.pair], new Date(sync.requestedAt))) return false;
    const receipt = await store.readReceipt(sync);
    return receipt?.state === "succeeded" && receipt.guarded === false && receipt.source === "graph" && receipt.writeMode === "apply" &&
      receipt.outcome === "succeeded" && receipt.finishedAt === request.syncFinishedAt &&
      Date.parse(receipt.finishedAt!) >= Date.parse(sync.requestedAt) && Date.parse(receipt.finishedAt!) <= Date.parse(sync.expiresAt) &&
      Date.parse(receipt.finishedAt!) <= Date.parse(request.requestedAt);
  }
  async function tick(): Promise<void> {
    const local = localConfiguration(env);
    if (!local) return;
    await publish(local);
    const active = await currentPair(local.pairs);
    if (!active || !samePair(active, local.pair) || local.heartbeat.disabled !== "false") return;
    for (const request of await store.pending(local.heartbeat.resourceId, now())) {
      if (!validRequest(request, local.pairs, now()) || request.phase !== local.phase || !samePair(request.pair, active)) continue;
      const lease = await store.claim(request, randomUUID(), now());
      if (typeof lease !== "object") continue;
      const startedAt = now().toISOString();
      const blocked = (reason: string): ApplyReceipt => ({
        ...request, state: "blocked", guarded: true, reason, startedAt, finishedAt: now().toISOString(),
      });
      const activeSync = (await store.heartbeats(local.pairs)).find((beat) => beat?.resourceId === request.pair.syncResourceId);
      let receipt: ApplyReceipt;
      if (activeSync?.graphPermission !== "granted") receipt = {
        ...blocked(activeSync?.graphPermission === "permission_required" ? "sync_graph_application_permission_required" : "sync_graph_prerequisite_unverified"),
        ...(activeSync?.graphPermission === "permission_required" && activeSync.identityResourceId ? {
          requirements: [{ action: "Microsoft Graph application GroupMember.Read.All", scope: activeSync.identityResourceId }],
        } : {}),
      };
      else if (!await projectMatches(request)) receipt = blocked("configuration_drift");
      else if (!await syncSucceeded(request)) receipt = blocked("correlated_sync_required");
      else {
        let lost = false, drifted = false, renewing: Promise<void> | undefined, checking: Promise<void> | undefined;
        const ensureCurrent = (): Promise<void> => {
          if (!checking) checking = (async () => {
            const current = localConfiguration(env), pair = await currentPair(local.pairs);
            if (!current || current.heartbeat.disabled !== "false" || !pair || !samePair(pair, request.pair) || !await projectMatches(request)) {
              drifted = true; throw new Error("configuration_drift");
            }
            if (lost || now().getTime() >= Date.parse(request.expiresAt) || !await store.renew(request, lease, now())) {
              lost = true; throw new Error("apply_claim_lost");
            }
          })().finally(() => { checking = undefined; });
          return checking;
        };
        const timer = setInterval(() => {
          if (!renewing) renewing = (async () => {
            const current = localConfiguration(env);
            if (!current || current.heartbeat.disabled !== "false") { drifted = true; return; }
            await publish(current);
            await ensureCurrent();
          })().catch(() => { lost = true; }).finally(() => { renewing = undefined; });
        }, 10_000);
        timer.unref();
        try {
          const before = localConfiguration(env), pairBefore = await currentPair(local.pairs);
          if (!before || before.heartbeat.disabled !== "false" || !pairBefore || !samePair(pairBefore, request.pair) || !await projectMatches(request))
            receipt = blocked("configuration_drift");
          else {
            await ensureCurrent();
            const result = await dependencies.run(request, ensureCurrent);
            receipt = summarize(request, result, startedAt, now().toISOString(), activeSync?.identityResourceId);
            const after = localConfiguration(env), pairAfter = await currentPair(local.pairs);
            if (!after || after.heartbeat.disabled !== "false" || !pairAfter || !samePair(pairAfter, request.pair) || !await projectMatches(request))
              receipt = blocked("configuration_drift");
            if (lost || now().getTime() >= Date.parse(request.expiresAt)) receipt = blocked("runtime_completion_unknown");
          }
        } catch { receipt = { ...blocked("runtime_failed"), state: "failed" }; }
        finally { clearInterval(timer); await renewing; }
        if (lost) receipt = blocked("runtime_completion_unknown");
        if (drifted) receipt = blocked("configuration_drift");
      }
      await store.complete(request, lease, receipt, now());
      return; // One phase per tick; business runners retain their own independent global leases.
    }
  }
  return { tick };
}
