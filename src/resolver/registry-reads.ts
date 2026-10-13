// The four registry reads src/resolver/decide.ts injects, over any database
// shaped like the Cosmos SDK's, plus the client options built from the
// settings. Only type imports from the SDK: the unit tests run this module
// against a fake database without reaching Azure (tests/live-azure-gate.test.ts);
// cosmos-reads.ts builds the real client around it.

import type { CosmosClientOptions } from "@azure/cosmos";
import type { BackendRecord } from "./backend.ts";
import type { TokenCredential } from "@azure/identity";
import type { CosmosClientSettings } from "./config.ts";
import type {
  AggregateBudgetStateRecord,
  BudgetStateRecord,
  EntitlementRecord,
  ResolveDependencies,
  SubscriptionIndexRecord,
} from "./decide.ts";

// The part of the SDK's Database the reads use.
export interface CosmosDatabaseLike {
  container(name: string): {
    item(id: string, partitionKey: string): {
      read(options: { abortSignal: AbortSignal }): Promise<{ resource?: unknown }>;
    };
  };
}

// The request timeout and the throttling retry budget come from app settings
// (ADR-0014 decision 6) instead of the SDK's defaults (60 s per attempt; 9
// throttling retries within 30 s). requestTimeout limits one attempt only.
export function cosmosClientOptions(settings: CosmosClientSettings, credential: TokenCredential): CosmosClientOptions {
  return {
    endpoint: settings.endpoint,
    aadCredentials: credential,
    connectionPolicy: {
      requestTimeout: settings.requestTimeoutMs,
      retryOptions: {
        maxRetryAttemptCount: settings.retryAttempts,
        maxWaitTimeInSeconds: settings.retryMaxWaitSeconds,
      },
    },
  };
}

// Each read takes the request's signal (http-handler.ts), and the SDK stops
// retrying when it fires (@azure/cosmos 4.10.1 RequestHandler.js passes it to
// every attempt). A caller without one (the live tests) gets readDeadlineMs.
export function createRegistryReads(database: CosmosDatabaseLike, readDeadlineMs: number): ResolveDependencies {
  async function read<T>(container: string, id: string, partitionKey: string, signal?: AbortSignal): Promise<T | null> {
    try {
      const { resource } = await database
        .container(container)
        .item(id, partitionKey)
        .read({ abortSignal: signal ?? AbortSignal.timeout(readDeadlineMs) });
      return (resource as T) ?? null;
    } catch (err: unknown) {
      if (isNotFound(err)) return null;
      throw err;
    }
  }

  return {
    readSubscriptionIndex: (subscriptionId, signal) =>
      read<SubscriptionIndexRecord>("subscriptionIndex", subscriptionId, subscriptionId, signal),
    readEntitlement: (personId, signal) => read<EntitlementRecord>("entitlement", personId, personId, signal),
    readBudgetState: (personId, projectId, signal) =>
      read<BudgetStateRecord>("budgetState", `${personId}:${projectId}`, personId, signal),
    readAggregateBudgetState: (scopeId, signal) => read<AggregateBudgetStateRecord>("aggregateBudgetState", scopeId, scopeId, signal),
    // C-8; partition key /backendId, id = backendId.
    readBackend: (backendId, signal) => read<BackendRecord>("backends", backendId, backendId, signal),
  };
}

function isNotFound(err: unknown): boolean {
  return typeof err === "object" && err !== null && "code" in err && (err as { code: unknown }).code === 404;
}
