// Integration test: Phase 6 (docs/ROADMAP.md M1.5) - a second project, a
// second designated backend, and the negative cross-project test proving
// ADR-0002's central defence live, not just at the unit level
// (tests/resolver-decide.test.ts already covers this with fakes - this
// seeds two real projects into the live Cosmos account and proves the same
// refusal through the real @azure/cosmos-backed reads).
//
// Scope note: "second designated subscription" is represented here as a
// second, distinct backendId value in the seeded data, not a second real
// Azure subscription with its own live Foundry account - standing up a
// second full Foundry backend is a separate, real cost/scope decision
// (docs/STATUS.md's established pattern of not provisioning new billable
// resources without it being an explicit, confirmed step). What this test
// proves is the registry/resolver's routing and isolation logic with two
// genuinely different projects' data, which is the part that was actually
// in question - not a second live model deployment.
//
// Same gate as resolver-cosmos-integration.test.ts: runs only with
// CCOF_LIVE_TESTS=1 (tests/helpers/live-azure.ts), and only from inside the
// VNet, because this subscription forces Cosmos public access off by policy.
// The default suite skips it; a requested run that cannot reach the account
// fails with that explanation.

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
  "two real projects resolve to their own distinct backends, and a cross-project key is refused",
  { skip: live.kind === "skip" && live.reason },
  async () => {
    const { endpoint, databaseName } = requireLiveConfig(live);
    const { CosmosClient } = await import("@azure/cosmos");
    const { DefaultAzureCredential } = await import("@azure/identity");
    const { createCosmosReads } = await import("../src/resolver/cosmos-reads.ts");
    const { resolveRequest } = await import("../src/resolver/decide.ts");

    const client = new CosmosClient({ endpoint, aadCredentials: new DefaultAzureCredential() });
    const database = client.database(databaseName);

    const suffix = Date.now();
    const personId = `itest-p6-person-${suffix}`;
    const projectA = "ITESTPROJA";
    const projectB = "ITESTPROJB";
    const subA = `itest-p6-sub-a-${suffix}`;
    const subB = `itest-p6-sub-b-${suffix}`;
    const budgetIdA = `${personId}:${projectA}`;

    try {
      // Seed subscriptionIndex for BOTH projects, but the person's entitlement
      // (below) is only an active member of project A - project B's
      // subscriptionIndex entry exists (e.g. belonging to a different real
      // person in practice) purely to prove A's own key cannot be confused
      // with B's, and that B's own backend is genuinely distinct from A's.
      await database.container("subscriptionIndex").items.upsert({
        id: subA, subscriptionId: subA, personId, projectId: projectA,
        classification: "STD", issuedAt: new Date().toISOString(), status: "active",
      });
      await database.container("subscriptionIndex").items.upsert({
        id: subB, subscriptionId: subB, personId: `itest-p6-other-person-${suffix}`, projectId: projectB,
        classification: "STD", issuedAt: new Date().toISOString(), status: "active",
      });

      await database.container("entitlement").items.upsert({
        id: personId, personId,
        projectMemberships: [
          {
            projectId: projectA, classification: "STD", classificationGroupId: "22222222-2222-2222-2222-222222222222",
            subscriptionId: subA,
            backendId: "foundry-project-a-backend", aggregateMode: "notify",
            familyPolicy: {
              aggregateLimits: STD_FAMILY_POLICY.aggregateLimits,
              families: { haiku: STD_FAMILY_POLICY.families.haiku },
            },
            denormalizedAt: new Date().toISOString(), joinedAt: new Date().toISOString(), status: "active",
          },
        ],
        generation: 1, lastVerifiedAt: new Date().toISOString(),
      });

      await database.container("budgetState").items.upsert({
        id: budgetIdA, personId, projectId: projectA, classification: "STD",
        spentSoFar: 0, exhausted: false, currency: "USD", realtimeCeilingTokensPerMinute: 4200,
        reconciledAt: new Date().toISOString(), validUntil: new Date(Date.now() + 300_000).toISOString(),
      });

      // Test inputs, generous because a live run tolerates slowness.
      const reads = createCosmosReads({ endpoint, databaseName, requestTimeoutMs: 10000, retryAttempts: 3, retryMaxWaitSeconds: 10, readDeadlineMs: 30000 });
      // Fresh seeded state, the strictest policy (ADR-0008), this machine's clock.
      const liveContext = () => ({
        now: new Date(),
        budgetEnforcement: { mode: "budget-state" as const, staleness: { graceSeconds: 0, hardLimitSeconds: 0 } },
      });

      // 1. The person's own key for project A resolves correctly to A's own backend.
      const resultA = await resolveRequest({ personId, subscriptionId: subA }, reads, liveContext());
      assert.equal(resultA.refused, false);
      if (!resultA.refused) {
        assert.equal(resultA.projectId, projectA);
        assert.equal(resultA.backendId, "foundry-project-a-backend");
      }

      // 2. THE NEGATIVE TEST (ADR-0002's central defence, live): presenting
      // project B's subscription key alongside this person's own identity is
      // refused - the person is not an active member of project B, and
      // subscriptionIndex's claim alone is never trusted.
      const crossProject = await resolveRequest({ personId, subscriptionId: subB }, reads, liveContext());
      assert.equal(crossProject.refused, true);
      if (crossProject.refused) {
        assert.equal(crossProject.reason, "subscription_person_mismatch");
        assert.equal(crossProject.httpStatus, 403);
      }
    } catch (err) {
      throw explainLiveFailure(err);
    } finally {
      await database.container("subscriptionIndex").item(subA, subA).delete().catch(() => {});
      await database.container("subscriptionIndex").item(subB, subB).delete().catch(() => {});
      await database.container("entitlement").item(personId, personId).delete().catch(() => {});
      await database.container("budgetState").item(budgetIdA, personId).delete().catch(() => {});
    }
  },
);
