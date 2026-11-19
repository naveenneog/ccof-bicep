import { CosmosClient } from "@azure/cosmos";
import type { Database } from "@azure/cosmos";
import { ManagedIdentityCredential } from "@azure/identity";
import type { InvocationContext } from "@azure/functions";
import { createCosmosApplyStore } from "./apply-store.ts";
import { createApplyWorker } from "./apply-worker.ts";
import type { ApplyPhase, ApplyRequest } from "./apply-contracts.ts";
import { graphPermissionFromManagedIdentityToken } from "./apply-graph.ts";
import { createApplyControlHandler as createControlHandler } from "./apply-control.ts";
import type { Environment } from "./apply-control.ts";

export { applyControlEnabled } from "./apply-control.ts";

export const APPLY_CONTROL_FUNCTION_NAME = "applyControl";
export const APPLY_CONTROL_SCHEDULE = "*/10 * * * * *";

export function createApplyControlHandler(options: {
  env: Environment;
  phase: ApplyPhase;
  run(request: ApplyRequest, context: InvocationContext, ensureCurrent: () => Promise<void>): Promise<unknown>;
}) {
  let database: Database | undefined;
  let credential: ManagedIdentityCredential | undefined;
  return createControlHandler({
    env: options.env, phase: options.phase,
    async tick({ endpoint, database: name, adminContainer, projectsContainer, clientId }, context) {
      const { env } = options;
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
    },
  });
}
