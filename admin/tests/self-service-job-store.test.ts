import assert from "node:assert/strict";
import test from "node:test";
import { createCosmosJobStore } from "../src/self-service-job-store.ts";
import { enqueueOperation } from "../src/self-service-jobs.ts";

const now = new Date("2026-11-20T12:00:00Z");
function cosmos() {
  const docs = new Map<string, Record<string, any>>();
  let version = 0;
  let deny = "";
  const fail = (operation: string) => { if (deny === operation) throw Object.assign(new Error("provider-secret"), { code: 403 }); };
  const container: any = {
    item(id: string, partition: string) {
      assert.equal(partition, "admin-operations");
      return {
        async read() {
          fail("read");
          if (!docs.has(id)) throw { code: 404 };
          return { resource: structuredClone(docs.get(id)), etag: docs.get(id)!._etag };
        },
        async replace(doc: any, options: any) {
          fail("replace");
          if (docs.get(id)?._etag !== options.accessCondition.condition) throw { code: 412 };
          const etag = `"${++version}"`;
          docs.set(id, { ...structuredClone(doc), _etag: etag });
          return { etag };
        },
      };
    },
    items: {
      async create(doc: any) {
        fail("create");
        if (docs.has(doc.id)) throw { code: 409 };
        assert.equal(doc.scopeId, "admin-operations");
        const etag = `"${++version}"`;
        docs.set(doc.id, { ...structuredClone(doc), _etag: etag });
        return { etag };
      },
      query(_query: any, options: any) {
        assert.equal(options.partitionKey, "admin-operations");
        return { async fetchAll() { fail("query"); return { resources: [] }; } };
      },
    },
  };
  return { store: createCosmosJobStore(container), docs, deny: (operation: string) => { deny = operation; } };
}

test("Cosmos storage probe proves create, conditional replace and query, not just reads", async () => {
  const fixture = cosmos();
  for (const action of ["read", "create", "replace", "query"]) {
    fixture.deny(action);
    await assert.rejects(fixture.store.probe!(), (error: any) => error.code === 403);
  }
  fixture.deny("");
  await fixture.store.probe!();
  assert.ok([...fixture.docs.values()].every((doc) => doc.recordKind !== "adminOperation"), "probe cannot enqueue real work");
});

test("Cosmos job writes use ETags and leases cannot be stolen or released by another owner", async () => {
  const { store } = cosmos();
  const job = await enqueueOperation(store, {
    key: "request-key", kind: "apply", projectId: "PROJECT", expectedEtag: '"one"', actorOid: "actor", reason: "Apply reviewed config",
  }, now);
  const stored = await store.read(job.id);
  assert.ok(stored);
  assert.equal((stored.job as any).scopeId, undefined);
  assert.equal(await store.replace({ ...job, phase: "wrong-version" }, '"stale"'), null);
  assert.equal((await store.read(job.id))?.job.phase, "queued");
  assert.equal(await store.lock("PROJECT", "A", now.toISOString(), new Date(+now + 60_000).toISOString()), true);
  assert.equal(await store.lock("PROJECT", "B", now.toISOString(), new Date(+now + 60_000).toISOString()), false);
  await store.unlock("PROJECT", "B");
  assert.equal(await store.lock("PROJECT", "B", now.toISOString(), new Date(+now + 60_000).toISOString()), false);
  await store.unlock("PROJECT", "A");
  assert.equal(await store.lock("PROJECT", "B", now.toISOString(), new Date(+now + 60_000).toISOString()), true);
});
