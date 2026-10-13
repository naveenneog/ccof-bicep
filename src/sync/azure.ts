// The real Azure dependencies of a run: Cosmos containers through
// @azure/cosmos and Microsoft Graph through fetch, both with one Entra
// credential. Kept apart from the framework-free modules so the unit tests
// never load an Azure SDK (tests/helpers/live-azure.ts enforces this).

import { CosmosClient } from "@azure/cosmos";
import type { Container, Database } from "@azure/cosmos";
import type { TokenCredential } from "@azure/identity";
import type { SyncConfig } from "./config.ts";
import { GRAPH_SCOPE, readGroupMembers, readerSettings } from "./graph.ts";
import type { FetchLike } from "./graph.ts";
import type { LeaseDocument, LeaseStore, LeaseWrite } from "./lease.ts";
import type { EntitlementWriter, ExistingEntitlement } from "./plan-types.ts";
import { BACKENDS_CONTAINER } from "./registry-seed.ts";
import type { SeedContainer, SeedStore } from "./registry-seed.ts";
import type { RunDependencies } from "./run.ts";
import type { EntitlementRecord } from "./types.ts";

function statusOf(err: unknown): number | undefined {
  if (typeof err !== "object" || err === null) return undefined;
  const e = err as { code?: unknown; statusCode?: unknown };
  const value = typeof e.code === "number" ? e.code : e.statusCode;
  return typeof value === "number" ? value : undefined;
}

function etagOf(response: { etag?: string; resource?: { _etag?: string } }): string {
  return response.etag ?? response.resource?._etag ?? "";
}

export function createEntitlementWriter(container: Container): EntitlementWriter {
  return {
    async create(doc: EntitlementRecord) {
      try {
        await container.items.create(doc);
        return "created";
      } catch (err) {
        if (statusOf(err) === 409) return "conflict";
        throw err;
      }
    },
    async replace(doc: EntitlementRecord, etag: string) {
      try {
        await container.item(doc.id, doc.personId).replace(doc, { accessCondition: { type: "IfMatch", condition: etag } });
        return "replaced";
      } catch (err) {
        const status = statusOf(err);
        if (status === 412 || status === 404) return "conflict";
        throw err;
      }
    },
  };
}

// The lease container is partitioned on /id.
export function createLeaseStore(container: Container): LeaseStore {
  const write = async (work: () => Promise<{ etag?: string; resource?: { _etag?: string } }>, conflictStatuses: number[]): Promise<LeaseWrite> => {
    try {
      return { etag: etagOf(await work()) };
    } catch (err) {
      const status = statusOf(err);
      if (status !== undefined && conflictStatuses.includes(status)) return { conflict: true };
      throw err;
    }
  };
  return {
    async read(id: string) {
      try {
        const response = await container.item(id, id).read<Record<string, unknown>>();
        if (!response.resource) return null;
        return { doc: response.resource, etag: etagOf(response as { etag?: string; resource?: { _etag?: string } }) };
      } catch (err) {
        if (statusOf(err) === 404) return null;
        throw err;
      }
    },
    create: (doc: LeaseDocument) => write(() => container.items.create(doc), [409]),
    replace: (doc: LeaseDocument, etag: string) =>
      write(() => container.item(doc.id, doc.id).replace(doc, { accessCondition: { type: "IfMatch", condition: etag } }), [404, 412]),
  };
}

const fetchAdapter: FetchLike = (url, init) => fetch(url, init);

// One client setup for a sync run and for the registry seed: the account endpoint and database of
// the sync's settings, with the sync's Entra credential.
function openDatabase(config: SyncConfig, credential: TokenCredential): Database {
  return new CosmosClient({ endpoint: config.cosmosEndpoint, aadCredentials: credential }).database(config.cosmosDatabase);
}

// The registry seed's create-only writes (registry-seed.ts): items.create, never upsert or replace,
// which the sync identity's onbProjectWriter role would refuse anyway; a 409 is the caller's to read.
export function createSeedStore(config: SyncConfig, credential: TokenCredential): SeedStore {
  const database = openDatabase(config, credential);
  const containers: Record<SeedContainer, Container> = {
    projects: database.container(config.projectsContainer),
    backends: database.container(BACKENDS_CONTAINER),
  };
  return {
    async create(name, doc) {
      try {
        await containers[name].items.create(doc);
        return "created";
      } catch (err) {
        if (statusOf(err) === 409) return "conflict";
        throw err;
      }
    },
    async read(name, id, partitionKey) {
      try {
        const response = await containers[name].item(id, partitionKey).read<Record<string, unknown>>();
        return response.resource ?? null;
      } catch (err) {
        if (statusOf(err) === 404) return null;
        throw err;
      }
    },
  };
}

export function createAzureDependencies(config: SyncConfig, credential: TokenCredential): RunDependencies {
  const database = openDatabase(config, credential);
  const projects = database.container(config.projectsContainer);
  const entitlement = database.container(config.entitlementContainer);
  const getToken = async () => {
    const token = await credential.getToken(GRAPH_SCOPE);
    if (!token) throw new Error("no Graph token");
    return token.token;
  };
  return {
    async readProjects() {
      // Every document, active or not: a non-active one freezes its project
      // (reported as such) instead of looking like a missing document.
      const query = "SELECT * FROM c";
      const { resources } = await projects.items.query<Record<string, unknown>>(query).fetchAll();
      return resources;
    },
    async readEntitlements(): Promise<ExistingEntitlement[]> {
      const { resources } = await entitlement.items.query<Record<string, unknown>>("SELECT * FROM c").fetchAll();
      return resources.map((doc) => ({ doc, etag: typeof doc._etag === "string" ? doc._etag : "" }));
    },
    entitlements: createEntitlementWriter(entitlement),
    leases: createLeaseStore(database.container(config.leaseContainer)),
    readGroup: (groupId, beforeRequest) =>
      readGroupMembers(groupId, {
        fetch: fetchAdapter,
        getToken,
        sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
        ...readerSettings(config),
        beforeRequest,
      }),
  };
}
