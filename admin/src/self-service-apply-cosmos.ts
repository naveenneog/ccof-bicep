import type { Container } from "@azure/cosmos";
import { activeHeartbeatPair, readWorkerPairs } from "../../src/operations/apply-contracts.ts";
import { createCosmosApplyStore } from "../../src/operations/apply-store.ts";
import type { ApplyDependencies, ApplyProvider } from "./self-service-apply.ts";
import { ApplyPermissionError, createApplyExecutor, isTransientApplyDependencyError } from "./self-service-apply.ts";
import type { FeatureCapability } from "./self-service-contracts.ts";

export interface CosmosApplyDependencies extends Pick<ApplyDependencies, "env" | "projects" | "now" | "prerequisites"> {
  container: Container;
}

export function createCosmosApplyExecutor(dependencies: CosmosApplyDependencies) {
  const { env, container } = dependencies, now = dependencies.now ?? (() => new Date());
  const store = createCosmosApplyStore(container), pairs = readWorkerPairs(env.ADMIN_WORKER_RESOURCE_IDS);
  const scope = `${env.COSMOS_ENDPOINT ?? "Cosmos"}/dbs/${env.COSMOS_DATABASE ?? ""}/colls/${env.ADMIN_CONFIG_CONTAINER ?? "adminConfig"}`;
  const requirement = (action: string) => ({ action: `Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/${action}`, scope });
  const denied = (error: unknown) => [401, 403].includes(Number((error as { code?: unknown; statusCode?: unknown })?.code ?? (error as { statusCode?: unknown })?.statusCode));
  async function access<T>(action: string, work: () => Promise<T>): Promise<T> {
    try { return await work(); } catch (error) {
      if (denied(error)) throw new ApplyPermissionError([requirement(action)]);
      throw error;
    }
  }
  let settings = new Map<string, Record<string, string>>();
  const provider: ApplyProvider = {
    async capability(): Promise<FeatureCapability> {
      if (!pairs) return { state: "unavailable", reason: "worker_targets_invalid", requirements: [] };
      try {
        const beats = await store.heartbeats(pairs);
        const active = activeHeartbeatPair(pairs, beats, now());
        if (!active) return { state: "unavailable", reason: "worker_fence_unverified", requirements: [] };
        const sync = beats.find((beat) => beat?.resourceId === active.syncResourceId)!;
        if (sync.graphPermission === "permission_required" && sync.identityResourceId) return {
          state: "permission_required", reason: "sync_graph_application_permission_required",
          requirements: [{ action: "Microsoft Graph application GroupMember.Read.All", scope: sync.identityResourceId }],
        };
        if (sync.graphPermission !== "granted" || !sync.identityResourceId)
          return { state: "unavailable", reason: "sync_graph_prerequisite_unverified", requirements: [] };
        settings = new Map(beats.map((beat) => [beat!.resourceId, {
          CCOF_APP_ROLE: beat!.phase === "sync" ? "sync" : "reconciler",
          [beat!.phase === "sync" ? "AzureWebJobs.syncEntitlement.Disabled" : "AzureWebJobs.reconcileBudgets.Disabled"]: beat!.disabled,
          SYNC_WRITE_MODE: beat!.writeMode,
        }]));
        return { state: "available", requirements: [] };
      } catch (error) {
        if (isTransientApplyDependencyError(error)) throw error;
        return {
          state: denied(error) ? "permission_required" : "unavailable",
          reason: denied(error) ? "apply_cosmos_permission_required" : "apply_cosmos_unavailable",
          requirements: denied(error) ? [requirement("read")] : [],
        };
      }
    },
    async settings(resourceId) { return settings.get(resourceId) ?? {}; },
  };
  return createApplyExecutor({
    ...dependencies, provider,
    receipts: {
      reserve: (request) => access("create", () => store.enqueue(request)),
      read: (request) => access("read", () => store.readReceipt(request)),
    },
  });
}
