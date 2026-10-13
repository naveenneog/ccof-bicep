// Integration test: seeds real documents into the live serverless Cosmos
// account (sample-pilot-cosmos, docs/STATUS.md Phase 3) and drives
// resolveRequest through the real @azure/cosmos-backed reads
// (src/resolver/cosmos-reads.ts), not the fakes tests/resolver-decide.test.ts
// uses. Proves the schema (docs/LLD.md §1) and the decision logic actually
// round-trip through a real account, not just through in-memory fixtures.
//
// Runs only when CCOF_LIVE_TESTS=1 is set, with a git-ignored .env holding
// COSMOS_ENDPOINT and COSMOS_DATABASE (see tests/helpers/live-azure.ts and
// infra/poc/create-cosmos-containers.ps1). The default suite skips it and
// makes no Azure call.
//
// This account's public network access is enforced Disabled by this
// subscription's own Azure Policy (`CosmosDB_PublicNetwork_Modify`, effect
// "modify" - confirmed live 2026-10-09, `az policy state list`), so the only
// way to reach it is from inside its VNet through the private endpoint
// (infra/poc/jumpbox-full-test.sh). A requested run from anywhere else fails
// with that explanation rather than skipping, so a green live run means the
// test actually reached the account.

import { test } from "node:test";
import assert from "node:assert/strict";
import { STD_FAMILY_POLICY } from "./helpers/resolver-fixtures.ts";
import {
  REPO_DOTENV_PATH,
  decideLiveRun,
  explainLiveFailure,
  loadDotEnv,
  requireLiveConfig,
} from "./helpers/live-azure.ts";

const live = decideLiveRun(process.env, loadDotEnv(REPO_DOTENV_PATH));

test(
  "resolveRequest round-trips through a real Cosmos account (seeded data)",
  { skip: live.kind === "skip" && live.reason },
  async () => {
    const { endpoint, databaseName } = requireLiveConfig(live);
    const { CosmosClient } = await import("@azure/cosmos");
    const { DefaultAzureCredential } = await import("@azure/identity");
    const { createCosmosReads } = await import("../src/resolver/cosmos-reads.ts");
    const { resolveRequest } = await import("../src/resolver/decide.ts");

    // Local (key-based) auth is disabled on this account (docs/STATUS.md
    // Phase 3) - this test authenticates the same way createCosmosReads does,
    // via DefaultAzureCredential (the developer's own `az login` session
    // locally; a real deployment uses the Function App's managed identity).
    const client = new CosmosClient({ endpoint, aadCredentials: new DefaultAzureCredential() });
    const database = client.database(databaseName);

    const personId = `itest-person-${Date.now()}`;
    const projectId = "ITESTPROJ01";
    const subscriptionId = `itest-sub-${Date.now()}`;

    try {
      // Seed exactly the shapes docs/LLD.md §1 defines.
      await database.container("subscriptionIndex").items.upsert({
        id: subscriptionId,
        subscriptionId,
        personId,
        projectId,
        classification: "STD",
        issuedAt: new Date().toISOString(),
        status: "active",
      });
    } catch (err) {
      throw explainLiveFailure(err);
    }

    await database.container("entitlement").items.upsert({
      id: personId,
      personId,
      projectMemberships: [
        {
          projectId,
          classification: "STD",
          classificationGroupId: "22222222-2222-2222-2222-222222222222",
          subscriptionId,
          backendId: "foundry-sample-hub",
          aggregateMode: "notify",
          familyPolicy: {
            aggregateLimits: STD_FAMILY_POLICY.aggregateLimits,
            families: { haiku: STD_FAMILY_POLICY.families.haiku },
          },
          denormalizedAt: new Date().toISOString(),
          joinedAt: new Date().toISOString(),
          status: "active",
        },
      ],
      generation: 1,
      lastVerifiedAt: new Date().toISOString(),
    });

    const budgetId = `${personId}:${projectId}`;
    await database.container("budgetState").items.upsert({
      id: budgetId,
      personId,
      projectId,
      classification: "STD",
      spentSoFar: 0,
      exhausted: false,
      currency: "USD",
      realtimeCeilingTokensPerMinute: 4200,
      reconciledAt: new Date().toISOString(),
      validUntil: new Date(Date.now() + 300_000).toISOString(),
    });

    try {
      // Test inputs, generous because a live run tolerates slowness.
      const reads = createCosmosReads({ endpoint, databaseName, requestTimeoutMs: 10000, retryAttempts: 3, retryMaxWaitSeconds: 10, readDeadlineMs: 30000 });
      // The seeded state is fresh, so the strictest policy (no grace, no hard
      // limit; ADR-0008) must still serve it. The clock is this machine's.
      const liveContext = () => ({
        now: new Date(),
        budgetEnforcement: { mode: "budget-state" as const, staleness: { graceSeconds: 0, hardLimitSeconds: 0 } },
      });
      const result = await resolveRequest({ personId, subscriptionId }, reads, liveContext());

      assert.equal(result.refused, false);
      if (!result.refused) {
        assert.equal(result.projectId, projectId);
        assert.equal(result.classification, "STD");
        assert.equal(result.backendId, "foundry-sample-hub");
        assert.equal(result.personCeilingTokensPerMinute, 4200);
      }

      // Negative case against the same real account: an unseeded subscription id.
      const missing = await resolveRequest(
        { personId, subscriptionId: "itest-sub-does-not-exist" },
        reads,
        liveContext(),
      );
      assert.equal(missing.refused, true);
      assert.equal(missing.reason, "unknown_subscription");
      assert.equal(missing.httpStatus, 403);
    } finally {
      // Clean up - this is a live, billed (serverless, pay-per-request)
      // account; do not leave test documents behind on every run.
      await database.container("subscriptionIndex").item(subscriptionId, subscriptionId).delete();
      await database.container("entitlement").item(personId, personId).delete();
      await database.container("budgetState").item(budgetId, personId).delete();
    }
  },
);
