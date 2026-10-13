// One run at a time (src/sync/lease.ts): a lease document with an expiry,
// taken and renewed with etags, so two hosts (the timer app and a manual CLI
// run) never write at once, and a lease left by a stopped run expires.

import { test } from "node:test";
import assert from "node:assert/strict";
import { LEASE_ID, LeaseLostError, acquireLease } from "../src/sync/lease.ts";
import { ManualClock, MemoryLeases } from "./helpers/sync-fakes.ts";

const START = "2026-10-11T12:00:00.000Z";

test("the first run takes the lease, and a second run is refused while it is held", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  const first = await acquireLease(store, { holder: "run-1", leaseSeconds: 300, now: clock.now });
  assert.equal(first.acquired, true);
  const doc = store.docs.get(LEASE_ID)?.doc;
  assert.deepEqual(doc, {
    id: LEASE_ID,
    holder: "run-1",
    acquiredAt: START,
    renewedAt: START,
    leaseExpiresAt: "2026-10-11T12:05:00.000Z",
    released: false,
    evidenceAt: null,
  });

  clock.advance(299);
  const second = await acquireLease(store, { holder: "run-2", leaseSeconds: 300, now: clock.now });
  assert.deepEqual(second, { acquired: false, heldBy: "run-1", leaseExpiresAt: "2026-10-11T12:05:00.000Z" });
});

test("a lease left by a stopped run expires and is taken over", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  await acquireLease(store, { holder: "run-1", leaseSeconds: 300, now: clock.now });
  clock.advance(300);
  const takeover = await acquireLease(store, { holder: "run-2", leaseSeconds: 300, now: clock.now });
  assert.equal(takeover.acquired, true);
  assert.equal(store.docs.get(LEASE_ID)?.doc.holder, "run-2");
});

test("a malformed lease document counts as expired, so it cannot block every run", async () => {
  const store = new MemoryLeases();
  store.docs.set(LEASE_ID, { doc: { id: LEASE_ID, holder: "x", acquiredAt: "", renewedAt: "", leaseExpiresAt: "tomorrow", released: false, evidenceAt: null }, etag: '"m"' });
  const result = await acquireLease(store, { holder: "run-2", leaseSeconds: 300, now: new ManualClock(START).now });
  assert.equal(result.acquired, true);
});

test("a released lease is free at once", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  const first = await acquireLease(store, { holder: "run-1", leaseSeconds: 300, now: clock.now });
  if (!first.acquired) assert.fail("expected the lease");
  assert.equal(await first.lease.release(), true);
  assert.equal(store.docs.get(LEASE_ID)?.doc.released, true);
  const second = await acquireLease(store, { holder: "run-2", leaseSeconds: 300, now: clock.now });
  assert.equal(second.acquired, true);
});

test("two runs racing for an expired lease: only one wins (etag)", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  await acquireLease(store, { holder: "run-0", leaseSeconds: 60, now: clock.now });
  clock.advance(61);
  const [a, b] = await Promise.all([
    acquireLease(store, { holder: "run-a", leaseSeconds: 60, now: clock.now }),
    acquireLease(store, { holder: "run-b", leaseSeconds: 60, now: clock.now }),
  ]);
  assert.equal([a.acquired, b.acquired].filter(Boolean).length, 1);
});

test("ensure renews once a third of the lease has passed, and not before", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  const result = await acquireLease(store, { holder: "run-1", leaseSeconds: 300, now: clock.now });
  if (!result.acquired) assert.fail("expected the lease");
  clock.advance(99);
  await result.lease.ensure();
  assert.equal(store.docs.get(LEASE_ID)?.doc.leaseExpiresAt, "2026-10-11T12:05:00.000Z");
  clock.advance(1);
  await result.lease.ensure();
  assert.equal(store.docs.get(LEASE_ID)?.doc.leaseExpiresAt, "2026-10-11T12:06:40.000Z");
});

test("ensure throws LeaseLostError when another run took the lease, so no further write happens", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  const result = await acquireLease(store, { holder: "run-1", leaseSeconds: 60, now: clock.now });
  if (!result.acquired) assert.fail("expected the lease");
  clock.advance(61);
  const other = await acquireLease(store, { holder: "run-2", leaseSeconds: 60, now: clock.now });
  assert.equal(other.acquired, true);
  await assert.rejects(result.lease.ensure(), LeaseLostError);
  assert.equal(await result.lease.release(), false, "releasing a lost lease does not touch the new holder's lease");
  assert.equal(store.docs.get(LEASE_ID)?.doc.holder, "run-2");
});

test("the lease carries the newest evidence time across takeovers, and release can advance it", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  const first = await acquireLease(store, { holder: "run-1", leaseSeconds: 60, now: clock.now });
  if (!first.acquired) assert.fail("expected the lease");
  assert.equal(first.previousEvidenceAt, null);
  await first.lease.release("2026-10-11T11:59:00.000Z");
  const second = await acquireLease(store, { holder: "run-2", leaseSeconds: 60, now: clock.now });
  if (!second.acquired) assert.fail("expected the lease");
  assert.equal(second.previousEvidenceAt, "2026-10-11T11:59:00.000Z");
  await second.lease.release(null);
  assert.equal(store.docs.get(LEASE_ID)?.doc.evidenceAt, "2026-10-11T11:59:00.000Z", "a run that applied nothing keeps the old evidence time");
  clock.advance(120);
  const third = await acquireLease(store, { holder: "run-3", leaseSeconds: 60, now: clock.now });
  if (!third.acquired) assert.fail("expected the lease");
  await third.lease.ensure();
  assert.equal(third.previousEvidenceAt, "2026-10-11T11:59:00.000Z");
});
