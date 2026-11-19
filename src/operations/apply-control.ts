import type { InvocationContext, Timer } from "@azure/functions";
import type { ApplyPhase } from "./apply-contracts.ts";

export type Environment = Readonly<Record<string, string | undefined>>;
export interface ApplyControlConfiguration {
  endpoint: string;
  database: string;
  adminContainer: string;
  projectsContainer: string;
  clientId: string;
}

export function applyControlEnabled(env: Environment, phase: ApplyPhase): boolean {
  return env.CCOF_APPLY_WORKER_ENABLED === "true" && env.CCOF_APP_ROLE === (phase === "sync" ? "sync" : "reconciler");
}

export function createApplyControlHandler(options: {
  env: Environment;
  phase: ApplyPhase;
  tick(configuration: ApplyControlConfiguration, context: InvocationContext): Promise<void>;
}) {
  return async (_timer: Timer, context: InvocationContext): Promise<void> => {
    const { env, phase } = options;
    if (!applyControlEnabled(env, phase)) return;
    try {
      const endpoint = env.COSMOS_ENDPOINT, database = env.COSMOS_DATABASE, adminContainer = env.ADMIN_CONFIG_CONTAINER;
      const projectsContainer = env[phase === "sync" ? "SYNC_PROJECTS_CONTAINER" : "RECONCILER_PROJECTS_CONTAINER"];
      const clientId = env[phase === "sync" ? "SYNC_MANAGED_IDENTITY_CLIENT_ID" : "RECONCILER_MANAGED_IDENTITY_CLIENT_ID"];
      const cosmosName = /^[A-Za-z0-9_-]{1,255}$/;
      if (!endpoint || !/^https:\/\/[a-z0-9-]+\.documents\.azure\.com(:443)?\/?$/.test(endpoint) || !database || !cosmosName.test(database) ||
        !adminContainer || !cosmosName.test(adminContainer) || !projectsContainer || !cosmosName.test(projectsContainer) ||
        !clientId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(clientId)) throw new Error("apply_worker_configuration_invalid");
      await options.tick({ endpoint, database, adminContainer, projectsContainer, clientId }, context);
    } catch {
      // The optional control plane must not fail the existing business timers.
      context.log(JSON.stringify({ schema: "ccof.apply.worker.v1", phase, state: "unavailable", reason: "apply_worker_unavailable" }));
    }
  };
}
