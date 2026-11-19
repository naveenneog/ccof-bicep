import { createHash } from "node:crypto";
import type { Container } from "@azure/cosmos";
import type { TokenCredential } from "@azure/identity";
import { ApiError } from "./auth.ts";
import type { Authenticator } from "./auth.ts";
import type { ProjectStore } from "./api.ts";
import type { RegistryStore } from "./backend-routing.ts";
import { beginChange } from "./change-log.ts";
import type { ChangeLog } from "./change-log.ts";
import { createConfigHistory, withConfigHistory } from "./config-history.ts";
import type { ConfigHistoryService } from "./config-history.ts";
import { createCosmosConfigHistoryStore } from "./config-history-store.ts";
import { createRoutingPublisher } from "./self-service-routing.ts";
import { createRoutingArmProvider, readRoutingTargets } from "./self-service-routing-arm.ts";
import { createCosmosJobStore } from "./self-service-job-store.ts";
import { processOperations } from "./self-service-jobs.ts";
import { createApplyRuntime } from "./self-service-apply-runtime.ts";
import type { HistoryAccess, SelfServiceDependencies } from "./self-service-api.ts";
import type { FeatureCapability, OperationJob, OperationStep } from "./self-service-contracts.ts";

interface RuntimeFeature {
  capability(): Promise<FeatureCapability>;
  advance(job: OperationJob): Promise<OperationStep>;
}
const disabled: FeatureCapability = { state: "disabled", reason: "feature_not_enabled", requirements: [] };
const unavailable = (reason: string): RuntimeFeature => ({
  capability: async () => ({ state: "unavailable", reason, requirements: [] }),
  advance: async () => ({ state: "blocked", phase: "unavailable", reason }),
});

export function createHistoryAccess(
  history: Pick<ConfigHistoryService, "capability" | "list" | "preview" | "restore">,
  projects: Pick<ProjectStore, "read">,
): HistoryAccess {
  return {
    capability: () => history.capability(),
    async list(projectId) {
      return { versions: (await history.list(projectId)).map((version) => ({
        versionId: version.id, createdAt: version.capturedAt, sourceEtag: null,
      })) };
    },
    async preview(projectId, versionId, actorOid) {
      const current = await projects.read(projectId);
      if (!current) throw new ApiError(404, "project_not_found");
      const preview = await history.preview({
        projectId, version: versionId, ifMatch: current.etag, reason: "Preview configuration restore",
        actor: { oid: actorOid, canWrite: true },
      });
      return { versionId: preview.version, etag: preview.ifMatch, changes: preview.changes, requiresPublication: preview.requiresPublication };
    },
    async restore(input) {
      return history.restore({
        projectId: input.projectId, version: input.versionId, ifMatch: input.etag,
        actor: { oid: input.actorOid, canWrite: true }, reason: input.reason, requestId: input.requestId,
      });
    },
  };
}

export function createSelfServiceRuntime(deps: {
  env: Readonly<Record<string, string | undefined>>;
  authenticate: Authenticator | null;
  projects: ProjectStore | null;
  container: Container | null;
  registry: RegistryStore | null;
  changeLog: ChangeLog | null;
  credential: Pick<TokenCredential, "getToken">;
  now(): Date;
  newId(): string;
  log(line: string): void;
}): { projects: ProjectStore | null; dependencies: SelfServiceDependencies; tick(): Promise<void> } {
  const { env } = deps;
  const storageScope = `/dbs/${env.COSMOS_DATABASE ?? ""}/colls/${env.ADMIN_CONFIG_CONTAINER ?? "adminConfig"}`;
  const projectScope = `/dbs/${env.COSMOS_DATABASE ?? ""}/colls/${env.ADMIN_PROJECTS_CONTAINER ?? "projects"}`;
  const jobs = deps.container ? createCosmosJobStore(deps.container) : null;
  const initialize = (flag: string, create: () => RuntimeFeature): RuntimeFeature => {
    if (env[flag] !== "true") return {
      capability: async () => structuredClone(disabled),
      advance: async () => ({ state: "blocked", phase: "disabled", reason: "feature_not_enabled" }),
    };
    try { return create(); } catch {
      deps.log(JSON.stringify({ schema: "ccof.admin.operation.v1", code: "feature_initialization_failed", feature: flag }));
      return unavailable("feature_configuration_invalid");
    }
  };
  let projects = deps.projects;
  let history: HistoryAccess | null = null;
  if (projects) {
    try {
      const enabled = env.ADMIN_HISTORY_ENABLED === "true";
      const versions = deps.container && enabled ? createCosmosConfigHistoryStore(deps.container, storageScope) : null;
      projects = enabled ? withConfigHistory(projects, {
        enabled, versions, scope: storageScope, projectScope, now: deps.now,
        onUnavailable: () => deps.log(JSON.stringify({ schema: "ccof.admin.history.v1", code: "optional_capture_unavailable" })),
      }) : projects;
      history = createHistoryAccess(createConfigHistory({
        enabled, versions, projects, registry: deps.registry, changeLog: deps.changeLog,
        scope: storageScope, projectScope, now: deps.now, newId: deps.newId, log: deps.log,
      }), projects);
    } catch {
      deps.log(JSON.stringify({ schema: "ccof.admin.history.v1", code: "history_initialization_failed" }));
      history = {
        capability: async () => ({ state: "unavailable", reason: "history_configuration_invalid", requirements: [] }),
        list: async () => { throw new ApiError(503, "history_configuration_invalid"); },
        preview: async () => { throw new ApiError(503, "history_configuration_invalid"); },
        restore: async () => { throw new ApiError(503, "history_configuration_invalid"); },
      };
    }
  }
  const routing = initialize("ADMIN_ROUTING_PUBLISH_ENABLED", () => {
    const registry = deps.registry;
    if (!projects || !registry?.withVersions) return unavailable("registry_coordination_not_configured");
    return createRoutingPublisher({
      env, projects, registry, provider: createRoutingArmProvider(deps.credential, readRoutingTargets(env)),
      audit: createRoutingAudit(deps),
      withRegistryFence: async (versions, run) => {
        const result = await registry.withVersions!(versions, run);
        return result.state === "verified" ? result.value : result.state === "busy"
          ? { state: "running", phase: "registry_wait" } : null;
      },
      now: deps.now,
    });
  });
  const apply = initialize("ADMIN_APPLY_ENABLED", () => projects && deps.container
    ? createApplyRuntime({ env, projects, container: deps.container, now: deps.now, log: deps.log })
    : unavailable("apply_store_not_configured"));
  const dependencies: SelfServiceDependencies = {
    authenticate: deps.authenticate, projects, jobs, changeLog: deps.changeLog, storageScope,
    features: { "publish-routing": routing, apply }, history,
    now: deps.now, newId: deps.newId, log: deps.log,
  };
  return {
    projects, dependencies,
    tick: async () => {
      if (!jobs || env.ADMIN_ROUTING_PUBLISH_ENABLED !== "true" && env.ADMIN_APPLY_ENABLED !== "true") return;
      await processOperations(jobs, { "publish-routing": routing.advance, apply: apply.advance }, {
        now: deps.now, owner: deps.newId(), log: deps.log,
      });
    },
  };
}

export function createRoutingAudit(deps: {
  changeLog: ChangeLog | null;
  now(): Date;
  newId(): string;
  log(line: string): void;
}) {
  return async (job: OperationJob, record: Record<string, unknown>): Promise<void> => {
    if (!deps.changeLog) throw new ApiError(503, "change_log_not_configured");
    const intentId = createHash("sha256").update(JSON.stringify([
      job.id, record.phase, record.target ?? null, record.planHash,
    ])).digest("hex");
    // Keep retries as separate audit attempts, linked by an immutable intent identity.
    const pending = await beginChange(deps.changeLog, {
      requestId: deps.newId(), at: deps.now().toISOString(), actorOid: job.actorOid,
      operation: "self_service_routing_intent", projectId: job.projectId, changes: [],
      details: { ...record, intentId, operationId: job.id, reason: job.reason, expectedEtag: job.expectedEtag },
    }, deps.now, deps.log);
    await pending.finish("intent_recorded");
  };
}
