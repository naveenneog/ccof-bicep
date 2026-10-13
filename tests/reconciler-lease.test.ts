// One reconciler run at a time (src/reconciler/lease.ts): the protocol and the
// tests of src/sync/lease.ts on wp/sync (ADR-0016), with the reconciler's
// own lease id, so the sync's lease and the reconciler's never collide.

import { test } from "node:test";
import assert from "node:assert/strict";
import { LeaseLostError, RECONCILER_LEASE_ID, acquireLease } from "../src/reconciler/lease.ts";
import { ManualClock, MemoryLeases } from "./helpers/reconciler-fakes.ts";

const START = "2026-10-11T12:00:00.000Z";

test("the reconciler's lease id is its own, not the sync's", () => {
  assert.equal(RECONCILER_LEASE_ID, "ccof-budget-reconciler");
});

test("the first run takes the lease, and a second run is refused while it is held", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  const first = await acquireLease(store, { holder: "run-1", leaseSeconds: 300, now: clock.now });
  assert.equal(first.acquired, true);
  assert.deepEqual(store.docs.get(RECONCILER_LEASE_ID)?.doc, {
    id: RECONCILER_LEASE_ID,
    holder: "run-1",
    acquiredAt: START,
    renewedAt: START,
    leaseExpiresAt: "2026-10-11T12:05:00.000Z",
    released: false,
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
  assert.equal(store.docs.get(RECONCILER_LEASE_ID)?.doc.holder, "run-2");
});

test("a malformed lease document counts as expired, so it cannot block every run", async () => {
  const store = new MemoryLeases();
  store.docs.set(RECONCILER_LEASE_ID, {
    doc: { id: RECONCILER_LEASE_ID, holder: "x", acquiredAt: "", renewedAt: "", leaseExpiresAt: "tomorrow", released: false },
    etag: '"m"',
  });
  const result = await acquireLease(store, { holder: "run-2", leaseSeconds: 300, now: new ManualClock(START).now });
  assert.equal(result.acquired, true);
});

test("a released lease is free at once", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  const first = await acquireLease(store, { holder: "run-1", leaseSeconds: 300, now: clock.now });
  if (!first.acquired) assert.fail("expected the lease");
  assert.equal(await first.lease.release(), true);
  assert.equal(store.docs.get(RECONCILER_LEASE_ID)?.doc.released, true);
  assert.equal((await acquireLease(store, { holder: "run-2", leaseSeconds: 300, now: clock.now })).acquired, true);
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
  assert.equal(store.docs.get(RECONCILER_LEASE_ID)?.doc.leaseExpiresAt, "2026-10-11T12:05:00.000Z");
  clock.advance(1);
  await result.lease.ensure();
  assert.equal(store.docs.get(RECONCILER_LEASE_ID)?.doc.leaseExpiresAt, "2026-10-11T12:06:40.000Z");
});

test("ensure throws LeaseLostError when another run took the lease, and release leaves the new holder alone", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  const result = await acquireLease(store, { holder: "run-1", leaseSeconds: 60, now: clock.now });
  if (!result.acquired) assert.fail("expected the lease");
  clock.advance(61);
  assert.equal((await acquireLease(store, { holder: "run-2", leaseSeconds: 60, now: clock.now })).acquired, true);
  await assert.rejects(result.lease.ensure(), LeaseLostError);
  assert.equal(await result.lease.release(), false);
  assert.equal(store.docs.get(RECONCILER_LEASE_ID)?.doc.holder, "run-2");
});

test("concurrent ensure calls share one renewal: the holder never loses its own lease (council finding)", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  const result = await acquireLease(store, { holder: "run-1", leaseSeconds: 300, now: clock.now });
  if (!result.acquired) assert.fail("expected the lease");
  clock.advance(101);
  const outcomes = await Promise.allSettled(Array.from({ length: 8 }, () => result.lease.ensure()));
  assert.deepEqual(outcomes.map((o) => o.status), Array(8).fill("fulfilled"));
  assert.equal(store.ops.filter((op) => op.startsWith("replace")).length, 1, "one renewal for all callers");
  assert.equal(store.docs.get(RECONCILER_LEASE_ID)?.doc.holder, "run-1");
});

test("a renewal that finds the lease taken fails every waiting caller", async () => {
  const store = new MemoryLeases();
  const clock = new ManualClock(START);
  const result = await acquireLease(store, { holder: "run-1", leaseSeconds: 300, now: clock.now });
  if (!result.acquired) assert.fail("expected the lease");
  clock.advance(101);
  store.failNextReplace = true;
  const outcomes = await Promise.allSettled(Array.from({ length: 3 }, () => result.lease.ensure()));
  assert.ok(outcomes.every((o) => o.status === "rejected" && o.reason instanceof LeaseLostError));
});
