import type { RunDependencies as SyncDependencies } from "../sync/run.ts";
import type { RunDependencies as ReconcilerDependencies } from "../reconciler/run.ts";
import type { ApplyRequest } from "./apply-contracts.ts";

async function projects(
  read: () => Promise<unknown[]>, guard: () => Promise<void>, request?: ApplyRequest,
) {
  await guard();
  const documents = await read();
  if (request) {
    const project = documents.find((doc): doc is Record<string, unknown> => typeof doc === "object" && doc !== null &&
      (doc as Record<string, unknown>).projectId === request.projectId);
    if (!project || project._etag !== request.expectedEtag || project.status !== "active") throw new Error("configuration_drift");
  }
  return documents;
}

export function guardSyncDependencies(deps: SyncDependencies, guard: () => Promise<void>, request?: ApplyRequest): SyncDependencies {
  return {
    ...deps,
    readProjects: () => projects(() => deps.readProjects(), guard, request),
    readGroup: (groupId, beforeRequest) => deps.readGroup(groupId, async () => { await guard(); await beforeRequest(); }),
    entitlements: {
      async create(doc) { await guard(); return deps.entitlements.create(doc); },
      async replace(doc, etag) { await guard(); return deps.entitlements.replace(doc, etag); },
    },
  };
}
export function guardReconcilerDependencies(deps: ReconcilerDependencies, guard: () => Promise<void>, request?: ApplyRequest): ReconcilerDependencies {
  return {
    ...deps,
    readProjects: () => projects(() => deps.readProjects(), guard, request),
    async readEntitlements() { await guard(); return deps.readEntitlements(); },
    async writeBudgetState(doc) { await guard(); return deps.writeBudgetState(doc); },
    async writeAggregateState(doc) { await guard(); return deps.writeAggregateState(doc); },
  };
}
