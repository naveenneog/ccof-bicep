// Immutable, configuration-only versions in adminConfig (/scopeId). No replace/upsert/delete API.
import { createHash } from "node:crypto";
import type { Container } from "@azure/cosmos";
import { ApiError } from "./auth.ts";
import { assertValidProject, canonical, isIdentifier, isObject, ValidationError } from "./validation.ts";
import type { Doc } from "./validation.ts";

export interface ConfigSnapshot {
  id: string;
  scopeId: string;
  kind: "projectConfigVersion";
  schema: 1;
  projectId: string;
  hash: string;
  capturedAt: string;
  config: Doc;
}
export interface ConfigHistoryStore {
  // Proves optional create/read/query on a non-version canary; never modifies a project.
  probe(): Promise<void>;
  create(snapshot: ConfigSnapshot): Promise<void>;
  read(projectId: string, version: string): Promise<ConfigSnapshot | null>;
  list(projectId: string, limit: number): Promise<ConfigSnapshot[]>;
}
export interface HistoryPermission { action: string; scope: string }
export class ConfigHistoryUnavailable extends ApiError {
  readonly required: HistoryPermission[];
  readonly requirements: HistoryPermission[];
  readonly permissionRequired: boolean;
  constructor(action: string, scope: string, code = "history_unavailable", permissionRequired = false) {
    super(503, code);
    this.required = [{ action, scope }];
    this.requirements = this.required;
    this.permissionRequired = permissionRequired;
  }
}
export const HISTORY_ACTIONS = {
  read: "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read",
  create: "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create",
  query: "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery",
  metadata: "Microsoft.DocumentDB/databaseAccounts/readMetadata",
} as const;
export function historyScope(projectId: string): string {
  if (!isIdentifier(projectId)) throw new ApiError(400, "invalid_project_id");
  return `history:${projectId}`;
}
export function assertVersionId(version: string): void {
  if (typeof version !== "string" || !/^config:[a-f0-9]{64}$/.test(version)) throw new ApiError(400, "invalid_history_version");
}

// Each level has an explicit allowlist; even an allowed scalar cannot smuggle an object.
function scalar(value: unknown): unknown {
  if (value === null || typeof value === "string" || typeof value === "boolean" ||
    typeof value === "number" && Number.isFinite(value)) return value;
  throw new ValidationError(["history.config:invalid_scalar"]);
}
function fields(value: unknown, keys: string[]): Doc {
  if (!isObject(value)) throw new ValidationError(["history.config:invalid_object"]);
  return Object.fromEntries(keys.filter((k) => Object.hasOwn(value, k)).map((k) => [k, scalar(value[k])]));
}
function strings(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new ValidationError(["history.config:invalid_array"]);
  return value.map(scalar);
}
function scopes(value: unknown): Doc {
  if (!isObject(value)) throw new ValidationError(["history.config:invalid_limits"]);
  return Object.fromEntries(["person", "group"].map((k) => [k, fields(value[k], ["tokensPerMinute", "tokenQuota", "tokenQuotaPeriod"])]));
}
function policy(value: unknown): Doc {
  if (!isObject(value) || !isObject(value.families)) throw new ValidationError(["history.config:invalid_policy"]);
  const families: Doc = {};
  for (const [family, entry] of Object.entries(value.families)) {
    if (!isObject(entry)) throw new ValidationError(["history.config:invalid_family"]);
    Object.defineProperty(families, family, { value: { ...scopes(entry), models: strings(entry.models) }, enumerable: true });
  }
  return { aggregateLimits: scopes(value.aggregateLimits), families };
}
export function projectConfig(doc: Doc): Doc {
  const config = fields(doc, ["id", "projectId", "displayName", "backendId", "designatedSubscriptionId"]);
  if (doc.adminTags !== undefined) config.adminTags = strings(doc.adminTags);
  if (!isObject(doc.classifications)) throw new ValidationError(["history.config:invalid_classifications"]);
  const classifications: Doc = {};
  for (const [code, c] of Object.entries(doc.classifications)) {
    if (!isObject(c)) throw new ValidationError(["history.config:invalid_classification"]);
    Object.defineProperty(classifications, code, { enumerable: true, value: {
      ...fields(c, ["groupId", "classificationGroupDisplayName", "aggregateMode", "onboardingMode"]),
      familyPolicy: policy(c.familyPolicy),
      personBudget: fields(c.personBudget, ["amount", "currency", "period"]),
      aggregateBudget: c.aggregateBudget === null ? null : fields(c.aggregateBudget, ["amount", "currency", "period"]),
    } });
  }
  config.classifications = classifications;
  if (doc.failover !== undefined) {
    if (!isObject(doc.failover)) throw new ValidationError(["history.config:invalid_failover"]);
    config.failover = { enabled: scalar(doc.failover.enabled), fallbackBackendIds: strings(doc.failover.fallbackBackendIds) };
  }
  const checked: Doc = { ...config, status: "active", supersedes: null, retiredAt: null };
  if (isObject(config.failover)) checked.failover = { ...config.failover, revision: 1, active: null };
  assertValidProject(checked);
  return config;
}
const hashConfig = (config: Doc): string => createHash("sha256").update(canonical({ schema: 1, config })).digest("hex");
export function configSnapshot(doc: Doc, at: Date): ConfigSnapshot {
  const config = projectConfig(doc), projectId = String(config.projectId), hash = hashConfig(config);
  return { id: `config:${hash}`, scopeId: historyScope(projectId), kind: "projectConfigVersion", schema: 1,
    projectId, hash, capturedAt: at.toISOString(), config };
}
export function assertSnapshot(value: ConfigSnapshot, projectId: string, version = value.id): ConfigSnapshot {
  try {
    assertVersionId(version);
    if (!isObject(value) || value.schema !== 1 || value.kind !== "projectConfigVersion" ||
      value.projectId !== projectId || value.scopeId !== historyScope(projectId) || value.id !== version ||
      !isObject(value.config) || value.config.projectId !== projectId || value.config.id !== projectId ||
      !Number.isFinite(Date.parse(value.capturedAt)) || hashConfig(value.config) !== value.hash ||
      value.id !== `config:${value.hash}` || canonical(projectConfig(value.config)) !== canonical(value.config)) {
      throw new Error("invalid");
    }
    return structuredClone({ id: value.id, scopeId: value.scopeId, kind: value.kind, schema: value.schema,
      projectId: value.projectId, hash: value.hash, capturedAt: value.capturedAt, config: value.config });
  } catch { throw new ApiError(409, "history_snapshot_invalid"); }
}

export function createCosmosConfigHistoryStore(container: Container, scope: string): ConfigHistoryStore {
  const guard = async <T>(action: string, work: () => Promise<T>): Promise<T> => {
    try { return await work(); } catch (e) {
      if (e instanceof ApiError) throw e;
      const error = e as { code?: number; statusCode?: number };
      throw new ConfigHistoryUnavailable(action, scope, "history_unavailable", (error?.statusCode ?? error?.code) === 403);
    }
  };
  const read = async (projectId: string, version: string): Promise<ConfigSnapshot | null> => {
    const partition = historyScope(projectId); assertVersionId(version);
    return guard(HISTORY_ACTIONS.read, async () => {
      try {
        const { resource } = await container.item(version, partition).read<ConfigSnapshot>();
        return resource ? assertSnapshot(resource, projectId, version) : null;
      } catch (e) { if ((e as { code?: number }).code === 404) return null; throw e; }
    });
  };
  return {
    async probe() {
      const canary = { id: "history-probe-v1", scopeId: "history-probe", kind: "projectConfigHistoryProbe", schema: 1 };
      await guard(HISTORY_ACTIONS.create, async () => {
        try { await container.items.create(canary); }
        catch (e) { if ((e as { code?: number }).code !== 409) throw e; }
      });
      await guard(HISTORY_ACTIONS.read, async () => {
        const { resource } = await container.item(canary.id, canary.scopeId).read<Doc>();
        if (!resource || Object.keys(canary).some((k) => resource[k] !== canary[k as keyof typeof canary])) {
          throw new ApiError(503, "history_probe_invalid");
        }
      });
      await guard(HISTORY_ACTIONS.query, async () => {
        const { resources } = await container.items.query<{ id: string }>({
          query: "SELECT TOP 1 c.id FROM c WHERE c.scopeId = @scope AND c.kind = @kind AND c.id = @id",
          parameters: [{ name: "@scope", value: canary.scopeId }, { name: "@kind", value: canary.kind }, { name: "@id", value: canary.id }],
        }, { partitionKey: canary.scopeId }).fetchAll();
        if (resources.length !== 1 || resources[0].id !== canary.id) throw new ApiError(503, "history_probe_invalid");
      });
    },
    read,
    async create(snapshot) {
      const value = assertSnapshot(snapshot, snapshot.projectId);
      await guard(HISTORY_ACTIONS.create, async () => {
        try { await container.items.create(value); } catch (e) {
          if ((e as { code?: number }).code !== 409) throw e;
          const existing = await read(value.projectId, value.id);
          if (!existing || canonical(existing.config) !== canonical(value.config)) throw new ApiError(409, "history_snapshot_invalid");
        }
      });
    },
    async list(projectId, limit) {
      const partition = historyScope(projectId);
      if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new ApiError(400, "invalid_history_limit");
      return guard(HISTORY_ACTIONS.query, async () => {
        const { resources } = await container.items.query<ConfigSnapshot>({
          query: "SELECT TOP @limit * FROM c WHERE c.scopeId = @scope AND c.kind = @kind AND c.projectId = @project ORDER BY c.capturedAt DESC",
          parameters: [{ name: "@limit", value: limit }, { name: "@scope", value: partition },
            { name: "@kind", value: "projectConfigVersion" }, { name: "@project", value: projectId }],
        }, { partitionKey: partition }).fetchAll();
        return resources.map((r) => assertSnapshot(r, projectId));
      });
    },
  };
}
export function createMemoryConfigHistoryStore(): ConfigHistoryStore {
  const entries = new Map<string, ConfigSnapshot>();
  const key = (p: string, id: string) => `${historyScope(p)}/${id}`;
  return {
    async probe() {},
    async create(value) {
      const v = assertSnapshot(value, value.projectId), k = key(v.projectId, v.id), prior = entries.get(k);
      if (prior) assertSnapshot(prior, v.projectId, v.id);
      else entries.set(k, structuredClone(v));
    },
    async read(projectId, version) { const v = entries.get(key(projectId, version)); return v ? structuredClone(v) : null; },
    async list(projectId, limit) {
      historyScope(projectId);
      return [...entries.values()].filter((v) => v.projectId === projectId)
        .sort((a, b) => b.capturedAt.localeCompare(a.capturedAt) || a.id.localeCompare(b.id)).slice(0, limit).map((v) => structuredClone(v));
    },
  };
}
