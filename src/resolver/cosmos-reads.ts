// Real @azure/cosmos implementations of the four reads src/resolver/decide.ts
// injects. Kept separate from decide.ts deliberately (ADR-0003): the decision
// logic stays framework-free and unit-testable without a live account; this
// module is what function-app.ts wires in for a real deployment, and what the
// live integration tests exercise against the real serverless Cosmos account.

import { CosmosClient } from "@azure/cosmos";
import { DefaultAzureCredential } from "@azure/identity";
import type { CosmosClientSettings } from "./config.ts";
import type { ResolveDependencies } from "./decide.ts";
import { cosmosClientOptions, createRegistryReads } from "./registry-reads.ts";

// The resolver's request deadline bounds each read too (http-handler.ts).
export type CosmosRegistryConfig = CosmosClientSettings & { readDeadlineMs: number };

// Entra RBAC only - this tenant disables Cosmos DB local (key-based) auth by
// default (`disableLocalAuth: true`, confirmed live on sample-pilot-cosmos,
// docs/STATUS.md Phase 3), consistent with the Foundry account's own
// `disableLocalAuth: true` found in Phase 1/2. DefaultAzureCredential picks
// up the Function App's managed identity in a real deployment, or the
// developer's own `az login` session locally (as this integration test
// uses) - either way needs the Cosmos DB Built-in Data Reader/Contributor
// **data-plane** role assigned via `az cosmosdb sql role assignment create`,
// which is separate from, and not implied by, any Azure control-plane RBAC
// role on the account.
export function createCosmosReads(config: CosmosRegistryConfig): ResolveDependencies {
  const client = new CosmosClient(cosmosClientOptions(config, new DefaultAzureCredential()));
  return createRegistryReads(client.database(config.databaseName), config.readDeadlineMs);
}
