// docs/ARCHITECTURE.md §3: the resolver's point reads run concurrently, in two
// waves - subscriptionIndex with entitlement, then everything keyed by the
// verified membership: the backend registry (C-8) and, in budget-state mode,
// budgetState with aggregateBudgetState (both aggregate modes since C-7).
// Proved with reads that stay pending until the test releases them: a
// sequential resolver issues the second read of a wave only after the first
// resolves, so it fails these tests.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveRequest } from "../src/resolver/decide.ts";
import type { ResolveDependencies } from "../src/resolver/decide.ts";
import {
  activeBudgetState,
  activeSubscriptionIndex,
  aggregateRecord,
  context,
  entitlementWithMembership,
  strictEntitlement,
  tokenLimitsOnlyContext,
} from "./helpers/resolver-fixtures.ts";

interface Deferred {
  promise: Promise<unknown>;
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
}

function deferred(): Deferred {
  let resolve!: (value: unknown) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<unknown>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

type ReadName = keyof ResolveDependencies;

// Every read records its call and returns a promise the test settles.
function controllableReads() {
  const pending = new Map<ReadName, Deferred>();
  const calls: ReadName[] = [];
  const read = (name: ReadName) => async () => {
    calls.push(name);
    const gate = deferred();
    pending.set(name, gate);
    return gate.promise;
  };
  const deps = {
    readSubscriptionIndex: read("readSubscriptionIndex"),
    readEntitlement: read("readEntitlement"),
    readBudgetState: read("readBudgetState"),
    readAggregateBudgetState: read("readAggregateBudgetState"),
    readBackend: read("readBackend"),
  } as ResolveDependencies;
  return { deps, calls, pending };
}

// Lets every already-queued microtask and timer run, so all reads that the
// resolver can start without waiting have started.
const settle = () => new Promise((resolve) => setImmediate(resolve));

test("subscriptionIndex and entitlement are both in flight before either returns", async () => {
  const { deps, calls, pending } = controllableReads();
  const result = resolveRequest({ personId: "person-1", subscriptionId: "sub-abc" }, deps, context());
  await settle();

  assert.deepEqual([...calls].sort(), ["readEntitlement", "readSubscriptionIndex"]);

  pending.get("readSubscriptionIndex")!.resolve(activeSubscriptionIndex);
  pending.get("readEntitlement")!.resolve(entitlementWithMembership);
  await settle();
  pending.get("readBudgetState")!.resolve(activeBudgetState);
  pending.get("readAggregateBudgetState")!.resolve(aggregateRecord);
  pending.get("readBackend")!.resolve(null);
  assert.equal((await result).refused, false);
});

test("budgetState and aggregateBudgetState are both in flight before either returns (strict scope)", async () => {
  const { deps, calls, pending } = controllableReads();
  const result = resolveRequest({ personId: "person-1", subscriptionId: "sub-abc" }, deps, context());
  await settle();
  pending.get("readSubscriptionIndex")!.resolve(activeSubscriptionIndex);
  pending.get("readEntitlement")!.resolve(strictEntitlement);
  await settle();

  assert.deepEqual(calls.slice(2).sort(), ["readAggregateBudgetState", "readBackend", "readBudgetState"]);

  pending.get("readBudgetState")!.resolve(activeBudgetState);
  pending.get("readAggregateBudgetState")!.resolve(aggregateRecord);
  pending.get("readBackend")!.resolve(null);
  const resolved = await result;
  assert.equal(resolved.refused, false);
  assert.equal(resolved.aggregateStrict, true);
});

test("the second wave waits for the first: budgetState is not read before the key is checked", async () => {
  // budgetState's id needs the projectId that subscriptionIndex returns and
  // entitlement confirms; reading it earlier would read an unverified key.
  const { deps, calls, pending } = controllableReads();
  const result = resolveRequest({ personId: "person-1", subscriptionId: "sub-abc" }, deps, context());
  await settle();
  pending.get("readSubscriptionIndex")!.resolve(null);
  pending.get("readEntitlement")!.resolve(entitlementWithMembership);

  const refused = await result;
  assert.equal(refused.refused, true);
  assert.equal(refused.reason, "unknown_subscription");
  assert.deepEqual([...calls].sort(), ["readEntitlement", "readSubscriptionIndex"]);
});

test("a refusal from subscriptionIndex stands even if the concurrent entitlement read fails", async () => {
  const { deps, pending } = controllableReads();
  const result = resolveRequest({ personId: "person-1", subscriptionId: "sub-abc" }, deps, context());
  await settle();
  pending.get("readSubscriptionIndex")!.resolve(null);
  pending.get("readEntitlement")!.reject(new Error("cosmos unavailable"));

  const refused = await result;
  assert.equal(refused.refused, true);
  assert.equal(refused.reason, "unknown_subscription");
});

test("a failed read the decision depends on is raised, not swallowed", async () => {
  const { deps, pending } = controllableReads();
  const result = resolveRequest({ personId: "person-1", subscriptionId: "sub-abc" }, deps, context());
  await settle();
  pending.get("readSubscriptionIndex")!.resolve(activeSubscriptionIndex);
  pending.get("readEntitlement")!.reject(new Error("cosmos unavailable"));

  await assert.rejects(result, /cosmos unavailable/);
});

test("token-limits-only: the backend registry read is the whole second wave, after the membership is verified", async () => {
  const { deps, calls, pending } = controllableReads();
  const result = resolveRequest({ personId: "person-1", subscriptionId: "sub-abc" }, deps, tokenLimitsOnlyContext());
  await settle();
  assert.deepEqual([...calls].sort(), ["readEntitlement", "readSubscriptionIndex"]);
  pending.get("readSubscriptionIndex")!.resolve(activeSubscriptionIndex);
  pending.get("readEntitlement")!.resolve(entitlementWithMembership);
  await settle();
  assert.deepEqual(calls.slice(2), ["readBackend"]);
  pending.get("readBackend")!.resolve(null);
  assert.equal((await result).refused, false);
});
