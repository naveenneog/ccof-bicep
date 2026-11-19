import assert from "node:assert/strict";
import test from "node:test";
import { createRegistryFence } from "../src/self-service-registry-fence.ts";
import { createMemoryJobStore } from "../src/self-service-jobs.ts";

function fixture() {
  const leases = createMemoryJobStore();
  const versions = new Map([["primary", '"one"'], ["fallback", '"two"']]);
  return {
    versions,
    fence: createRegistryFence({
      leases, readEtag: async (id) => versions.get(id) ?? null,
      now: () => new Date("2026-11-20T12:00:00Z"),
    }),
  };
}
const expected = [{ backendId: "primary", etag: '"one"' }, { backendId: "fallback", etag: '"two"' }];

test("registry writes and publication share the same leases across hosts", async () => {
  const { fence } = fixture();
  let release!: () => void;
  let entered!: () => void;
  const wait = new Promise<void>((done) => { release = done; });
  const ready = new Promise<void>((done) => { entered = done; });
  const publishing = fence.verify(expected, async () => {
    entered();
    await wait;
    return "activated";
  });
  await ready;
  let writes = 0;
  await assert.rejects(fence.write("primary", async () => { writes++; }), /registry_publication_in_progress/);
  assert.equal(writes, 0);
  release();
  assert.deepEqual(await publishing, { state: "verified", value: "activated" });
  await fence.write("primary", async () => { writes++; });
  assert.equal(writes, 1);
});

test("changed or missing registry ETags cannot activate and every acquired lease is released", async () => {
  const { fence, versions } = fixture();
  let calls = 0;
  versions.set("fallback", '"changed"');
  assert.deepEqual(await fence.verify(expected, async () => { calls++; }), { state: "changed" });
  versions.set("fallback", "");
  assert.deepEqual(await fence.verify([{ backendId: "fallback", etag: "" }], async () => { calls++; }), { state: "changed" });
  assert.equal(calls, 0);
  await fence.write("primary", async () => {});
  await assert.rejects(fence.write("primary", async () => { throw new Error("storage_failed"); }), /storage_failed/);
  await fence.write("primary", async () => {});
});

test("a concurrent writer makes verification retryable rather than invoking promotion", async () => {
  const { fence } = fixture();
  let release!: () => void;
  let entered!: () => void;
  const wait = new Promise<void>((done) => { release = done; });
  const ready = new Promise<void>((done) => { entered = done; });
  const writing = fence.write("primary", async () => { entered(); await wait; });
  await ready;
  let promoted = false;
  assert.deepEqual(await fence.verify(expected, async () => { promoted = true; }), { state: "busy" });
  assert.equal(promoted, false);
  release();
  await writing;
});

test("registry cleanup outages preserve a persisted write or its original failure", async () => {
  const warnings: string[] = [];
  const fence = createRegistryFence({
    leases: { lock: async () => true, unlock: async () => { throw new Error("storage_cleanup_unavailable"); } },
    readEtag: async () => '"one"', now: () => new Date("2026-11-20T12:00:00Z"),
    log: (line) => warnings.push(line),
  });
  assert.equal(await fence.write("primary", async () => "saved"), "saved");
  await assert.rejects(fence.write("primary", async () => { throw new Error("original_write_failed"); }), /original_write_failed/);
  assert.equal(warnings.length, 2);
  assert.ok(warnings.every((line) => JSON.parse(line).code === "registry_lease_release_failed"));
});

test("publication cleanup attempts every lease without masking verified activation", async () => {
  const releases: string[] = [];
  const fence = createRegistryFence({
    leases: { lock: async () => true, unlock: async (id) => { releases.push(id); throw new Error("cleanup_unavailable"); } },
    readEtag: async (id) => expected.find((entry) => entry.backendId === id)?.etag ?? null,
    now: () => new Date("2026-11-20T12:00:00Z"), log: () => {},
  });
  assert.deepEqual(await fence.verify(expected, async () => "activated"), { state: "verified", value: "activated" });
  assert.deepEqual(releases.sort(), ["registry:fallback", "registry:primary"]);
});
