// The registry reads (src/resolver/registry-reads.ts) without a live account.
// The client options come from the settings (ADR-0014 decision 6), and every
// read names its container, id and partition key, maps "not found" to null,
// and stops at the read deadline. A fake database stands in for the SDK, so no
// Azure call is made; cosmos-reads.ts only wires the real client to these.

import { test } from "node:test";
import assert from "node:assert/strict";
import { cosmosClientOptions, createRegistryReads } from "../src/resolver/registry-reads.ts";
import type { CosmosDatabaseLike } from "../src/resolver/registry-reads.ts";

const settings = {
  endpoint: "https://sample-pilot-cosmos.documents.azure.com:443/",
  databaseName: "ccof",
  requestTimeoutMs: 1500,
  retryAttempts: 1,
  retryMaxWaitSeconds: 1,
};

const credential = { getToken: async () => null };

interface ReadCall {
  container: string;
  id: string;
  partitionKey: string;
  signal: AbortSignal;
}

function fakeDatabase(respond: (call: ReadCall) => Promise<{ resource?: unknown }>) {
  const calls: ReadCall[] = [];
  const database: CosmosDatabaseLike = {
    container: (container) => ({
      item: (id, partitionKey) => ({
        read: (options) => {
          const call = { container, id, partitionKey, signal: options.abortSignal };
          calls.push(call);
          return respond(call);
        },
      }),
    }),
  };
  return { database, calls };
}

test("the Cosmos client options are the configured limits, never the SDK defaults", () => {
  assert.deepEqual(cosmosClientOptions(settings, credential), {
    endpoint: settings.endpoint,
    aadCredentials: credential,
    connectionPolicy: { requestTimeout: 1500, retryOptions: { maxRetryAttemptCount: 1, maxWaitTimeInSeconds: 1 } },
  });
});

test("each read names its container, id and partition key, and returns the document", async () => {
  const { database, calls } = fakeDatabase(async (call) => ({ resource: { id: call.id } }));
  const reads = createRegistryReads(database, 1000);
  assert.deepEqual(await reads.readSubscriptionIndex("sub-abc"), { id: "sub-abc" });
  assert.deepEqual(await reads.readEntitlement("person-1"), { id: "person-1" });
  assert.deepEqual(await reads.readBudgetState("person-1", "SAMPLEORGAIAZ103"), { id: "person-1:SAMPLEORGAIAZ103" });
  assert.deepEqual(await reads.readAggregateBudgetState("SAMPLEORGAIAZ103:STD"), { id: "SAMPLEORGAIAZ103:STD" });
  assert.deepEqual(await reads.readBackend("foundry-sample-hub"), { id: "foundry-sample-hub" });
  assert.deepEqual(
    calls.map(({ container, id, partitionKey }) => ({ container, id, partitionKey })),
    [
      { container: "subscriptionIndex", id: "sub-abc", partitionKey: "sub-abc" },
      { container: "entitlement", id: "person-1", partitionKey: "person-1" },
      { container: "budgetState", id: "person-1:SAMPLEORGAIAZ103", partitionKey: "person-1" },
      { container: "aggregateBudgetState", id: "SAMPLEORGAIAZ103:STD", partitionKey: "SAMPLEORGAIAZ103:STD" },
      { container: "backends", id: "foundry-sample-hub", partitionKey: "foundry-sample-hub" },
    ],
  );
});

test("a missing document is null; any other failure is thrown unchanged", async () => {
  const notFound = fakeDatabase(async () => {
    throw Object.assign(new Error("not found"), { code: 404 });
  });
  assert.equal(await createRegistryReads(notFound.database, 1000).readEntitlement("p"), null);

  const empty = fakeDatabase(async () => ({}));
  assert.equal(await createRegistryReads(empty.database, 1000).readEntitlement("p"), null);

  const throttled = Object.assign(new Error("throttled"), { code: 429 });
  const failing = fakeDatabase(async () => {
    throw throttled;
  });
  await assert.rejects(createRegistryReads(failing.database, 1000).readEntitlement("p"), (err) => err === throttled);
});

test("every read hands the SDK an abort signal that fires at the read deadline", { timeout: 5000 }, async () => {
  // Like the SDK (RequestHandler.js): a hung request ends only when the
  // caller's signal aborts.
  const { database, calls } = fakeDatabase(
    (call) =>
      new Promise((_, reject) => {
        call.signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })));
      }),
  );
  const reads = createRegistryReads(database, 40);
  // AbortSignal.timeout's timer does not hold the event loop open, and nothing
  // else here does (Node 22 then cancels the test); in the Functions host the
  // loop stays open, so the test holds it open itself, for a bounded time: a
  // read that never stops then fails the test instead of hanging the run.
  const keepAlive = setTimeout(() => {}, 2000);
  try {
    const started = performance.now();
    await assert.rejects(reads.readEntitlement("person-1"), { name: "AbortError" });
    const elapsedMs = performance.now() - started;
    assert.ok(elapsedMs >= 35 && elapsedMs < 1000, `stopped after ${elapsedMs} ms`);
    assert.equal(calls[0].signal.aborted, true);
  } finally {
    clearTimeout(keepAlive);
  }
});

test("each read gets its own signal, so one read's deadline does not cut a later read short", async () => {
  const { database, calls } = fakeDatabase(async (call) => ({ resource: { id: call.id } }));
  const reads = createRegistryReads(database, 1000);
  await reads.readEntitlement("person-1");
  await reads.readEntitlement("person-2");
  assert.notEqual(calls[0].signal, calls[1].signal);
});

test("a read given the request's signal hands exactly that signal to the SDK", async () => {
  const { database, calls } = fakeDatabase(async (call) => ({ resource: { id: call.id } }));
  const reads = createRegistryReads(database, 1000);
  const request = new AbortController();
  await reads.readEntitlement("person-1", request.signal);
  await reads.readBackend("foundry-sample-hub", request.signal);
  assert.equal(calls[0].signal, request.signal);
  assert.equal(calls[1].signal, request.signal);
});
