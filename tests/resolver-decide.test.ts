// RED-first unit tests for the resolver's core decision logic (ADR-0003).
// These exercise `resolveRequest` directly, with fake Cosmos reads injected -
// no Functions host, no network, no real Cosmos account needed for this layer.
// Fixtures mirror docs/LLD.md §1's schemas (tests/helpers/resolver-fixtures.ts);
// the clock and the staleness policy are injected (ADR-0008).

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveRequest } from "../src/resolver/decide.ts";
import {
  activeBudgetState,
  activeMembership,
  activeSubscriptionIndex,
  aggregateRecord,
  context,
  entitlementWithMembership,
  fakeReads,
  strictEntitlement,
} from "./helpers/resolver-fixtures.ts";

test("resolves a valid person+subscription to routing and budget info", async () => {
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads(),
    context(),
  );

  assert.equal(result.refused, false);
  assert.equal(result.projectId, "SAMPLEORGAIAZ103");
  assert.equal(result.classification, "STD");
  assert.equal(result.backendId, "foundry-sample-hub");
  assert.deepEqual(result.familyPolicy, activeMembership.familyPolicy);
  assert.equal(result.aggregateStrict, false);
  assert.equal(result.aggregateState, null);
  assert.equal(result.personBudgetScope, "person-1:SAMPLEORGAIAZ103");
  assert.equal(result.personCeilingTokensPerMinute, 4200);
});

test("refuses with 403 unknown_subscription when the subscriptionIndex key does not exist", async () => {
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-does-not-exist" },
    fakeReads({ readSubscriptionIndex: async () => null }),
    context(),
  );

  assert.equal(result.refused, true);
  assert.equal(result.reason, "unknown_subscription");
  assert.equal(result.httpStatus, 403);
});

test("refuses with 403 unknown_subscription when the subscriptionIndex key is not active", async () => {
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads({
      readSubscriptionIndex: async () => ({ ...activeSubscriptionIndex, status: "revoked" }),
    }),
    context(),
  );

  assert.equal(result.refused, true);
  assert.equal(result.reason, "unknown_subscription");
  assert.equal(result.httpStatus, 403);
});

test("refuses with 403 subscription_person_mismatch when the key was issued to someone else", async () => {
  // Defends against a stolen/reused APIM subscription key presented alongside
  // a different person's own valid bearer token (docs/ARCHITECTURE.md §2).
  const result = await resolveRequest(
    { personId: "person-2", subscriptionId: "sub-abc" },
    fakeReads(),
    context(),
  );

  assert.equal(result.refused, true);
  assert.equal(result.reason, "subscription_person_mismatch");
  assert.equal(result.httpStatus, 403);
});

test("resolves correctly for a person in >1 project when the key claims the second membership", async () => {
  // ADR-0002's headline feature: cross-project membership. A single-membership
  // fixture would never catch a resolver that only ever checked
  // projectMemberships[0] instead of actually finding the matching one.
  const secondMembership = {
    projectId: "SAMPLEORGAIAZ210",
    classification: "PRM",
    classificationGroupId: "44444444-4444-4444-4444-444444444444",
    subscriptionId: "sub-xyz",
    familyPolicy: activeMembership.familyPolicy,
    backendId: "foundry-other-subscription",
    aggregateMode: "notify",
    denormalizedAt: "2026-10-09T04:00:00Z",
    joinedAt: "2026-10-09T00:00:00Z",
    status: "active",
  };
  const multiProjectEntitlement = {
    ...entitlementWithMembership,
    projectMemberships: [entitlementWithMembership.projectMemberships[0], secondMembership],
  };
  const secondBudgetState = { ...activeBudgetState, projectId: "SAMPLEORGAIAZ210", realtimeCeilingTokensPerMinute: 9000 };

  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-xyz" },
    fakeReads({
      readSubscriptionIndex: async () => ({
        ...activeSubscriptionIndex,
        subscriptionId: "sub-xyz",
        projectId: "SAMPLEORGAIAZ210",
        classification: "PRM",
      }),
      readEntitlement: async () => multiProjectEntitlement,
      readBudgetState: async () => secondBudgetState,
    }),
    context(),
  );

  assert.equal(result.refused, false);
  assert.equal(result.projectId, "SAMPLEORGAIAZ210");
  assert.equal(result.classification, "PRM");
  assert.equal(result.backendId, "foundry-other-subscription");
  assert.equal(result.personCeilingTokensPerMinute, 9000);
});

test("refuses with 403 no_entitlement when the person has no entitlement record at all", async () => {
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads({ readEntitlement: async () => null }),
    context(),
  );

  assert.equal(result.refused, true);
  assert.equal(result.reason, "no_entitlement");
  assert.equal(result.httpStatus, 403);
});

test("refuses with 403 project_mismatch when the claimed project is not an active membership", async () => {
  // The central cross-project-membership defence (docs/adr/0002, ADR's central decision):
  // a subscription key claiming project X is worthless unless entitlement itself
  // independently confirms this person is an active member of project X.
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads({
      readSubscriptionIndex: async () => ({ ...activeSubscriptionIndex, projectId: "SAMPLEORGAIAZ210" }),
    }),
    context(),
  );

  assert.equal(result.refused, true);
  assert.equal(result.reason, "project_mismatch");
  assert.equal(result.httpStatus, 403);
});

test("refuses with 403 project_mismatch when the matching membership is not active", async () => {
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads({
      readEntitlement: async () => ({
        ...entitlementWithMembership,
        projectMemberships: [{ ...entitlementWithMembership.projectMemberships[0], status: "removed" }],
      }),
    }),
    context(),
  );

  assert.equal(result.refused, true);
  assert.equal(result.reason, "project_mismatch");
  assert.equal(result.httpStatus, 403);
});

test("refuses with 403 classification_mismatch when the key's classification no longer matches entitlement", async () => {
  // Catches a key issued under one classification surviving a later reclassification
  // (e.g. STD -> PRM) before the next sync denormalizes it away.
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads({
      readSubscriptionIndex: async () => ({ ...activeSubscriptionIndex, classification: "PRM" }),
    }),
    context(),
  );

  assert.equal(result.refused, true);
  assert.equal(result.reason, "classification_mismatch");
  assert.equal(result.httpStatus, 403);
});

test("fails closed with 503 budget_state_missing rather than granting unmetered access", async () => {
  // Mirrors the reference repository's fail-closed convention cited in docs/LLD.md
  // ("never stale authorization") - a missing budget record is a reconciler gap,
  // not evidence the person has no budget.
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads({ readBudgetState: async () => null }),
    context(),
  );

  assert.equal(result.refused, true);
  assert.equal(result.reason, "budget_state_missing");
  assert.equal(result.httpStatus, 503);
});

test("strict aggregateMode reads aggregateBudgetState and returns it alongside the resolution", async () => {
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads({
      readEntitlement: async () => strictEntitlement,
      readAggregateBudgetState: async () => aggregateRecord,
    }),
    context(),
  );

  assert.equal(result.refused, false);
  assert.equal(result.aggregateStrict, true);
  // No ceiling formula exists yet (docs/UNKNOWNS.md U-11) - the raw record is
  // passed through rather than a number invented with no basis.
  assert.deepEqual(result.aggregateState, aggregateRecord);
});

test("fails closed with 503 aggregate_budget_state_missing when strict mode has no aggregate record", async () => {
  const result = await resolveRequest(
    { personId: "person-1", subscriptionId: "sub-abc" },
    fakeReads({
      readEntitlement: async () => strictEntitlement,
      readAggregateBudgetState: async () => null,
    }),
    context(),
  );

  assert.equal(result.refused, true);
  assert.equal(result.reason, "aggregate_budget_state_missing");
  assert.equal(result.httpStatus, 503);
});
