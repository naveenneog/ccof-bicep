import type { Container } from "@azure/cosmos";
import { createCosmosApplyExecutor } from "./self-service-apply-cosmos.ts";
import type { ApplyDependencies } from "./self-service-apply.ts";
import type { FeatureCapability, OperationJob, OperationStep } from "./self-service-contracts.ts";

export interface ApplyRuntimeDependencies extends Pick<ApplyDependencies, "env" | "projects" | "now"> {
  container: Container | null;
  log?: (line: string) => void;
}

export interface ApplyRuntime {
  capability(): Promise<FeatureCapability>;
  advance(job: OperationJob): Promise<OperationStep>;
}
export function createApplyRuntime(dependencies: ApplyRuntimeDependencies): ApplyRuntime {
  if (dependencies.container) return createCosmosApplyExecutor({ ...dependencies, container: dependencies.container });
  const capability = async (): Promise<FeatureCapability> => dependencies.env.ADMIN_APPLY_ENABLED === "true"
    ? { state: "unavailable", reason: "apply_cosmos_unconfigured", requirements: [] }
    : { state: "disabled", reason: "apply_disabled", requirements: [] };
  return {
    capability,
    async advance(_job: OperationJob): Promise<OperationStep> {
      const cap = await capability();
      return { state: "blocked", phase: "preflight", reason: cap.reason, requirements: cap.requirements };
    },
  };
}
