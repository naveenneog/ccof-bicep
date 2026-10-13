// Live test of the sync's Cosmos adapter (src/sync/azure.ts) against the real
// account: the lease store's create/409, etag replace/412 and read/404, and
// the entitlement writer's create/conflict and replace/conflict. It uses a
// lease id and a person id of its own and deletes them afterwards, so it never
// touches the real lease or a real person's document.
//
// Runs only with CCOF_LIVE_TESTS=1 and a .env holding COSMOS_ENDPOINT and
// COSMOS_DATABASE (tests/helpers/live-azure.ts), from inside the VNet, with a
// login that holds a Cosmos data-plane role allowing delete (for cleanup). The
// .env must also name both containers, SYNC_LIVE_LEASE_CONTAINER and
// SYNC_LIVE_ENTITLEMENT_CONTAINER; there is no default.

import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { REPO_DOTENV_PATH, decideLiveRun, explainLiveFailure, loadDotEnv, requireLiveConfig } from "./helpers/live-azure.ts";

const dotEnv = loadDotEnv(REPO_DOTENV_PATH);
const live = decideLiveRun(process.env, dotEnv);

test("the sync's Cosmos adapter keeps etag semantics on the real account", { skip: live.kind === "skip" && live.reason }, async () => {
  const { endpoint, databaseName } = requireLiveConfig(live);
  const leaseContainerName = dotEnv?.SYNC_LIVE_LEASE_CONTAINER?.trim();
  const entitlementContainerName = dotEnv?.SYNC_LIVE_ENTITLEMENT_CONTAINER?.trim();
  if (!leaseContainerName || !entitlementContainerName) {
    throw new Error("CCOF_LIVE_TESTS=1 needs SYNC_LIVE_LEASE_CONTAINER and SYNC_LIVE_ENTITLEMENT_CONTAINER in .env");
  }
  const { CosmosClient } = await import("@azure/cosmos");
  const { DefaultAzureCredential } = await import("@azure/identity");
  const { createEntitlementWriter, createLeaseStore } = await import("../src/sync/azure.ts");

  const database = new CosmosClient({ endpoint, aadCredentials: new DefaultAzureCredential() }).database(databaseName);
  const leaseContainer = database.container(leaseContainerName);
  const entitlementContainer = database.container(entitlementContainerName);
  const leases = createLeaseStore(leaseContainer);
  const writer = createEntitlementWriter(entitlementContainer);
  const leaseId = `itest-lease-${randomUUID()}`;
  const personId = `itest-sync-${randomUUID()}`;
  const now = new Date().toISOString();
  const lease = { id: leaseId, holder: "itest", acquiredAt: now, renewedAt: now, leaseExpiresAt: now, released: false, evidenceAt: null };

  try {
    let created;
    try {
      created = await leases.create(lease);
    } catch (err) {
      throw explainLiveFailure(err);
    }
    assert.ok("etag" in created && created.etag.length > 0, "create returns an etag");
    assert.deepEqual(await leases.create(lease), { conflict: true }, "a second create is a conflict (409)");
    const read = await leases.read(leaseId);
    assert.equal(read?.doc.holder, "itest");
    const replaced = await leases.replace({ ...lease, holder: "itest-2" }, read?.etag ?? "");
    assert.ok("etag" in replaced, "replace with the current etag succeeds");
    assert.deepEqual(await leases.replace({ ...lease, holder: "itest-3" }, read?.etag ?? ""), { conflict: true }, "a stale etag is a conflict (412)");
    assert.equal(await leases.read(`itest-absent-${randomUUID()}`), null, "a missing lease reads as null (404)");

    const doc = { id: personId, personId, projectMemberships: [], generation: 1, lastVerifiedAt: now };
    assert.equal(await writer.create(doc), "created");
    assert.equal(await writer.create(doc), "conflict");
    const { resource } = await entitlementContainer.item(personId, personId).read();
    const etag = (resource as { _etag: string })._etag;
    assert.equal(await writer.replace({ ...doc, generation: 2 }, etag), "replaced");
    assert.equal(await writer.replace({ ...doc, generation: 3 }, etag), "conflict", "a stale etag does not overwrite");
  } finally {
    await leaseContainer.item(leaseId, leaseId).delete().catch(() => undefined);
    await entitlementContainer.item(personId, personId).delete().catch(() => undefined);
  }
});
