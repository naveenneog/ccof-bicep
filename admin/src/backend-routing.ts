// Backend registry and per-project failover (ADR 0034, docs/design/DR-IMPLEMENTATION.md).
//
// Registry entries live in the adminConfig container (partition `backend-registry`). An entry names one
// approved Foundry Anthropic endpoint, the deployments it serves, its inference geography and an optional
// circuit breaker. Registration authorizes nothing: a project uses a registered backend only after an
// editor selects it as a fallback for that project, and only after the routing publisher has created
// and verified the project's own APIM pool (POST routing/{projectId}/publication).

import type { Container } from "@azure/cosmos";
import {
  admittedModelsOf, failoverCompatibilityProblems, failoverProblems, MAX_FALLBACKS, memberBackendIdFor, poolBackendIdFor,
  REGISTRY_KEYS, registeredBackendProblems,
} from "../../src/contracts/project-routing.ts";
import type { RegisteredBackend } from "../../src/contracts/project-routing.ts";
import { ValidationError, isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";

export const REGISTRY_PARTITION = "backend-registry";

export interface RegistryStore {
  list(): Promise<{ doc: RegisteredBackend; etag: string }[]>;
  read(backendId: string): Promise<{ doc: RegisteredBackend; etag: string } | null>;
  // The new ETag, or null when the stored ETag differs (or the entry appeared meanwhile).
  save(doc: RegisteredBackend, etag: string | null): Promise<string | null>;
}

const strip = (d: Doc): RegisteredBackend => Object.fromEntries(REGISTRY_KEYS.map((k) => [k, d[k] ?? null])) as unknown as RegisteredBackend;

export function registryEntryFromBody(backendId: string, body: unknown): RegisteredBackend {
  if (!isObject(body)) throw new ValidationError(["backend:not_an_object"]);
  if (Object.keys(body).some((k) => !REGISTRY_KEYS.includes(k) || k === "backendId")) throw new ValidationError(["backend:unexpected_key"]);
  const doc = { backendId, ...body, displayName: typeof body.displayName === "string" ? body.displayName.trim() : body.displayName };
  const problems = registeredBackendProblems(doc);
  if (problems.length) throw new ValidationError(problems);
  return doc as RegisteredBackend;
}

export function createRegistryStore(container: Container): RegistryStore {
  const id = (backendId: string) => `backend:${backendId}`;
  return {
    async list() {
      const { resources } = await container.items.query<Doc & { _etag?: string }>({
        query: "SELECT * FROM c WHERE c.scopeId = @p AND c.kind = 'backendRegistration'", parameters: [{ name: "@p", value: REGISTRY_PARTITION }],
      }, { partitionKey: REGISTRY_PARTITION }).fetchAll();
      return resources.map((r) => ({ doc: strip(r), etag: r._etag ?? "" })).sort((a, b) => a.doc.backendId.localeCompare(b.doc.backendId));
    },
    async read(backendId) {
      try {
        const response = await container.item(id(backendId), REGISTRY_PARTITION).read<Doc>();
        return response.resource ? { doc: strip(response.resource), etag: response.etag ?? "" } : null;
      } catch (err) { if ((err as { code?: number })?.code === 404) return null; throw err; }
    },
    async save(doc, etag) {
      const value = { ...doc, id: id(doc.backendId), scopeId: REGISTRY_PARTITION, kind: "backendRegistration" };
      try {
        const response = etag
          ? await container.item(value.id, REGISTRY_PARTITION).replace(value, { accessCondition: { type: "IfMatch", condition: etag } })
          : await container.items.create(value);
        return response.etag ?? null;
      } catch (err) { if ([409, 412, 404].includes((err as { code?: number })?.code ?? 0)) return null; throw err; }
    },
  };
}

export function createMemoryRegistryStore(): RegistryStore & { entries: Map<string, { doc: RegisteredBackend; etag: string }> } {
  let n = 0;
  const entries = new Map<string, { doc: RegisteredBackend; etag: string }>();
  return {
    entries,
    async list() { return [...entries.values()].map((e) => structuredClone(e)).sort((a, b) => a.doc.backendId.localeCompare(b.doc.backendId)); },
    async read(backendId) { const e = entries.get(backendId); return e ? structuredClone(e) : null; },
    async save(doc, etag) {
      if ((entries.get(doc.backendId)?.etag ?? null) !== etag) return null;
      const next = { doc: structuredClone(doc), etag: `"backend-${++n}"` };
      entries.set(doc.backendId, next);
      return next.etag;
    },
  };
}

export async function registryMap(store: RegistryStore): Promise<Map<string, RegisteredBackend>> {
  return new Map((await store.list()).map((e) => [e.doc.backendId, e.doc]));
}

// The project document after an editor's failover request. The revision moves only when the pool's
// composition changes (first configuration or a different ordered fallback list); switching failover
// on or off keeps the revision, so a verified pool is reused. `active` is never set here.
export function failoverAfterEdit(project: Doc, body: unknown, registry: Map<string, RegisteredBackend>): Doc {
  if (!isObject(body) || Object.keys(body).some((k) => k !== "enabled" && k !== "fallbackBackendIds")) throw new ValidationError(["failover:unexpected_key"]);
  if (typeof body.enabled !== "boolean") throw new ValidationError(["failover.enabled:invalid"]);
  const list = body.fallbackBackendIds;
  if (!Array.isArray(list) || list.length > MAX_FALLBACKS) throw new ValidationError(["failover.fallbackBackendIds:invalid"]);
  const prior = isObject(project.failover) ? project.failover : null;
  const sameList = prior !== null && JSON.stringify(prior.fallbackBackendIds) === JSON.stringify(list);
  const revision = prior === null ? 1 : sameList ? Number(prior.revision) : Number(prior.revision) + 1;
  const failover = { enabled: body.enabled, fallbackBackendIds: [...list], revision, active: prior?.active ?? null };
  const problems = failoverProblems(failover, project.backendId);
  if (body.enabled) problems.push(...failoverCompatibilityProblems(String(project.backendId), list as string[], admittedModelsOf(project), registry));
  if (problems.length) throw new ValidationError(problems);
  return failover;
}

export type RoutingState = "off" | "pending_publication" | "verified" | "disabled_with_pool";

export function routingState(failover: unknown): RoutingState {
  if (!isObject(failover)) return "off";
  const active = isObject(failover.active) ? failover.active : null;
  if (!failover.enabled) return active ? "disabled_with_pool" : "off";
  return active && active.revision === failover.revision ? "verified" : "pending_publication";
}

export interface RoutingMember {
  backendId: string;
  memberBackendId: string;
  url: string;
  priority: number;
  weight: number;
  circuitBreaker: RegisteredBackend["circuitBreaker"];
}

// What the routing publisher must create for one project revision. The primary is priority 1, each
// fallback the next priority in the editor's order; problems block publication of that project.
export function routingPlan(project: Doc, registry: Map<string, RegisteredBackend>) {
  const failover = project.failover as Doc;
  const projectId = String(project.projectId);
  const revision = Number(failover.revision);
  const ids = [String(project.backendId), ...(failover.fallbackBackendIds as string[])];
  const problems = failoverCompatibilityProblems(ids[0], ids.slice(1), admittedModelsOf(project), registry);
  const members: RoutingMember[] = ids.flatMap((id, i) => {
    const b = registry.get(id);
    return b ? [{ backendId: id, memberBackendId: memberBackendIdFor(projectId, revision, i), url: b.url, priority: i + 1, weight: 1, circuitBreaker: b.circuitBreaker }] : [];
  });
  return { projectId, revision, poolBackendId: poolBackendIdFor(projectId, revision), primaryBackendId: ids[0], members, problems };
}

export const publicEntry = (e: { doc: RegisteredBackend; etag: string }) => ({ ...e.doc, etag: e.etag });

// UNKNOWNS DR-13: the publisher copies a registry breaker onto member entities only when it creates a
// revision's pool, so a breaker edit moves the revision of each verified project whose pool includes
// the backend. A pending revision already publishes the current registry; a project with failover off
// keeps its direct route and is not touched. Null means unaffected.
export function failoverAfterBreakerChange(project: Doc, backendId: string): Doc | null {
  if (project.status !== "active" || routingState(project.failover) !== "verified") return null;
  const failover = project.failover as Doc;
  if (![String(project.backendId), ...(failover.fallbackBackendIds as string[])].includes(backendId)) return null;
  return { ...failover, revision: Number(failover.revision) + 1 };
}
