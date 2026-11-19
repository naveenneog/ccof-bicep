import { CosmosClient } from "@azure/cosmos";
import type { Database } from "@azure/cosmos";
import { ManagedIdentityCredential } from "@azure/identity";
import type { InvocationContext, Timer } from "@azure/functions";
import { createCosmosApplyStore } from "./apply-store.ts";
import { createApplyWorker } from "./apply-worker.ts";
import type { ApplyPhase, ApplyRequest } from "./apply-contracts.ts";
import { graphPermissionFromManagedIdentityToken } from "./apply-graph.ts";

export const APPLY_CONTROL_FUNCTION_NAME = "applyControl";
export const APPLY_CONTROL_SCHEDULE = "*/10 * * * * *";
type Environment = Readonly<Record<string, string | undefined>>;
export function applyControlEnabled(env: Environment, phase: ApplyPhase): boolean {
  return env.CCOF_APPLY_WORKER_ENABLED === "true" && env.CCOF_APP_ROLE === (phase === "sync" ? "sync" : "reconciler");
}

export function createApplyControlHandler(options: {
  env: Environment;
  phase: ApplyPhase;
  run(request: ApplyRequest, context: InvocationContext, ensureCurrent: () => Promise<void>): Promise<unknown>;
}) {
  let database: Database | undefined;
  let credential: ManagedIdentityCredential | undefined;
  return async (_timer: Timer, context: InvocationContext): Promise<void> => {
    const { env, phase } = options;
    if (!applyControlEnabled(env, phase)) return;
    try {
      const endpoint = env.COSMOS_ENDPOINT, name = env.COSMOS_DATABASE, adminContainer = env.ADMIN_CONFIG_CONTAINER;
      const projectsContainer = env[phase === "sync" ? "SYNC_PROJECTS_CONTAINER" : "RECONCILER_PROJECTS_CONTAINER"];
      const clientId = env[phase === "sync" ? "SYNC_MANAGED_IDENTITY_CLIENT_ID" : "RECONCILER_MANAGED_IDENTITY_CLIENT_ID"];
      const cosmosName = /^[A-Za-z0-9_-]{1,255}$/;
      if (!endpoint || !/^https:\/\/[a-z0-9-]+\.documents\.azure\.com(:443)?\/?$/.test(endpoint) || !name || !cosmosName.test(name) ||
        !adminContainer || !cosmosName.test(adminContainer) || !projectsContainer || !cosmosName.test(projectsContainer) ||
        !clientId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(clientId)) throw new Error("apply_worker_configuration_invalid");
      credential ??= new ManagedIdentityCredential({ clientId });
      database ??= new CosmosClient({ endpoint, aadCredentials: credential }).database(name);
      const projects = database.container(projectsContainer);
      await createApplyWorker({
        env, store: createCosmosApplyStore(database.container(adminContainer)),
        projects: {
          async read(projectId) {
            try {
              const response = await projects.item(projectId, projectId).read<Record<string, unknown>>();
              return response.resource ? { etag: response.etag ?? String(response.resource._etag ?? ""), status: String(response.resource.status ?? "") } : null;
            } catch (error) {
              if (Number((error as { code?: unknown })?.code) === 404) return null;
              throw error;
            }
          },
        },
        run: (request, ensureCurrent) => options.run(request, context, ensureCurrent),
        graphPermission: async () => graphPermissionFromManagedIdentityToken(
          await credential!.getToken("https://graph.microsoft.com/.default"),
          env.CCOF_APPLY_WORKER_IDENTITY_RESOURCE_ID,
          new Date(),
        ),
      }).tick();
    } catch {
      // This optional control plane must neither fail host startup nor contaminate the existing business timers.
      context.log(JSON.stringify({ schema: "ccof.apply.worker.v1", phase, state: "unavailable", reason: "apply_worker_unavailable" }));
    }
  };
}
