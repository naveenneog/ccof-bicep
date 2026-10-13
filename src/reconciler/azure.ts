// The real Azure dependencies of a reconciler run: the Cosmos containers
// through @azure/cosmos and the Log Analytics query API through fetch, both
// with the app's user-assigned managed identity. Kept apart from the
// framework-free modules so the unit tests never load an Azure SDK
// (tests/helpers/live-azure.ts enforces this).

import { CosmosClient } from "@azure/cosmos";
import type { Container } from "@azure/cosmos";
import type { TokenCredential } from "@azure/identity";
import type { LeaseDocument, LeaseStore, LeaseWrite } from "./lease.ts";
import { createLedgerQuery, logAnalyticsScope } from "./log-analytics.ts";
import type { FetchLike } from "./log-analytics.ts";
import type { RunDependencies } from "./run.ts";
import type { ReconcilerSettings } from "./settings.ts";

function statusOf(err: unknown): number | undefined {
  if (typeof err !== "object" || err === null) return undefined;
  const e = err as { code?: unknown; statusCode?: unknown };
  const value = typeof e.code === "number" ? e.code : e.statusCode;
  return typeof value === "number" ? value : undefined;
}

function etagOf(response: { etag?: string; resource?: { _etag?: string } }): string {
  return response.etag ?? response.resource?._etag ?? "";
}

// The lease container is partitioned on /id (the same adapter as the sync's).
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

async function readAll(container: Container): Promise<unknown[]> {
  const { resources } = await container.items.query<Record<string, unknown>>("SELECT * FROM c").fetchAll();
  return resources;
}

const fetchAdapter: FetchLike = (url, init) => fetch(url, init);

export function createReconcilerDependencies(settings: ReconcilerSettings, credential: TokenCredential): RunDependencies {
  const client = new CosmosClient({ endpoint: settings.cosmosEndpoint, aadCredentials: credential });
  const database = client.database(settings.cosmosDatabase);
  const { containers } = settings;
  const budgetState = database.container(containers.budgetState);
  const aggregateState = database.container(containers.aggregateState);
  const scope = logAnalyticsScope(settings.logAnalyticsEndpoint);
  return {
    leases: createLeaseStore(database.container(containers.lease)),
    readProjects: () => readAll(database.container(containers.projects)),
    readEntitlements: () => readAll(database.container(containers.entitlement)),
    queryLedger: createLedgerQuery({
      endpoint: settings.logAnalyticsEndpoint,
      workspaceId: settings.workspaceId,
      timeoutSeconds: settings.ledgerTimeoutSeconds,
      getToken: async () => {
        const token = await credential.getToken(scope);
        if (!token) throw new Error("no token");
        return token.token;
      },
      fetch: fetchAdapter,
    }),
    // Upsert: every run writes every state, renewing validUntil (ADR-0018).
    writeBudgetState: async (doc) => {
      await budgetState.items.upsert(doc);
    },
    writeAggregateState: async (doc) => {
      await aggregateState.items.upsert(doc);
    },
  };
}
