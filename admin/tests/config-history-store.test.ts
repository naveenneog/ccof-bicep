import { test } from "node:test";
import assert from "node:assert/strict";
import type { Container } from "@azure/cosmos";
import { configSnapshot, createCosmosConfigHistoryStore, HISTORY_ACTIONS } from "../src/config-history-store.ts";

const scope = "/subscriptions/test/resourceGroups/test/providers/Microsoft.DocumentDB/databaseAccounts/test/sqlDatabases/ccof/containers/adminConfig";
const limit = { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null };
function snapshot() {
  return configSnapshot({ id: "P1", projectId: "P1", displayName: "Project", backendId: "foundry-a",
    designatedSubscriptionId: "00000000-0000-4000-8000-0000000000b1",
    classifications: { STD: { groupId: "00000000-0000-4000-8000-0000000000c1", classificationGroupDisplayName: "P1-STD",
      familyPolicy: { aggregateLimits: { person: limit, group: limit },
        families: { haiku: { models: ["claude-haiku-4-5"], person: limit, group: limit } } },
      personBudget: { amount: 10, currency: "USD", period: "monthly" },
      aggregateBudget: null, aggregateMode: "strict", onboardingMode: "block",
    } },
  }, new Date("2026-11-19T12:00:00Z"));
}
function fake() {
  const docs = new Map<string, unknown>(), calls: { op: string; args: unknown[] }[] = [];
  let denial = "";
  const denied = (op: string) => { if (denial === op) throw { code: 403, message: "provider secret" }; };
  const container = {
    item(id: string, partition: string) {
      return {
        async read() {
          calls.push({ op: "read", args: [id, partition] }); denied("read");
          return { resource: structuredClone(docs.get(`${partition}/${id}`)) };
        },
      };
    },
    items: {
      async create(value: any) {
        calls.push({ op: "create", args: [structuredClone(value)] }); denied("create");
        const key = `${value.scopeId}/${value.id}`;
        if (docs.has(key)) throw { code: 409 };
        docs.set(key, structuredClone(value)); return {};
      },
      query(query: any, options: any) {
        calls.push({ op: "query", args: [query, options] });
        return { async fetchAll() {
          denied("query");
          const canary = query.parameters.find((p: any) => p.name === "@kind")?.value === "projectConfigHistoryProbe";
          return { resources: canary ? [...docs.values()].filter((d: any) => d.kind === "projectConfigHistoryProbe").map((d: any) => ({ id: d.id })) :
            [...docs.values()].map((d) => structuredClone(d)) };
        } };
      },
    },
  };
  return { docs, calls, deny(op: string) { denial = op; }, store: createCosmosConfigHistoryStore(container as unknown as Container, scope) };
}

test("Cosmos snapshots create only, deduplicate conflict with verified read and never replace/upsert", async () => {
  const f = fake(), v = snapshot();
  await f.store.create(v); await f.store.create({ ...v, capturedAt: "2026-11-20T12:00:00Z" });
  assert.deepEqual(f.calls.map((c) => c.op), ["create", "create", "read"]);
  assert.deepEqual(f.calls.at(-1)?.args, [v.id, "history:P1"]);
  assert.equal((await f.store.read("P1", v.id))?.capturedAt, v.capturedAt);
  f.docs.set(`history:P1/${v.id}`, { ...v, config: { ...v.config, displayName: "corrupted" } });
  await assert.rejects(() => f.store.create(v), (e: any) => e.code === "history_snapshot_invalid");
});

test("Cosmos query is bounded, parameterized and partition scoped; foreign rows never escape", async () => {
  const f = fake(), v = snapshot();
  await f.store.create(v);
  assert.equal((await f.store.list("P1", 10)).length, 1);
  const [query, options] = f.calls.find((c) => c.op === "query")!.args as any[];
  assert.deepEqual(options, { partitionKey: "history:P1" });
  assert.ok(query.query.includes("TOP @limit"));
  assert.deepEqual(query.parameters.map((p: any) => p.value), [10, "history:P1", "projectConfigVersion", "P1"]);
  await assert.rejects(() => f.store.list("P1", 101), (e: any) => e.status === 400);
  await assert.rejects(() => f.store.list("P1' OR 1=1", 10), (e: any) => e.status === 400);
  await assert.rejects(() => f.store.list("OTHER", 10), (e: any) => e.code === "history_snapshot_invalid");
});

test("Cosmos adapter maps each denied read/create/query to exact required action and scope without provider text", async () => {
  for (const op of ["read", "create", "query"] as const) {
    const f = fake(), v = snapshot(); f.deny(op);
    await assert.rejects(() => op === "read" ? f.store.read("P1", v.id) : op === "create" ? f.store.create(v) : f.store.list("P1", 10),
      (e: any) => e.status === 503 && e.code === "history_unavailable" && !e.message.includes("secret") &&
        e.required[0].action === HISTORY_ACTIONS[op] && e.required[0].scope === scope);
  }
});

test("read strips Cosmos and unexpected envelope properties; invalid IDs do not reach provider", async () => {
  const f = fake(), v = snapshot();
  f.docs.set(`history:P1/${v.id}`, { ...v, _etag: "private", arbitrary: { secret: true } });
  assert.deepEqual(await f.store.read("P1", v.id), v);
  const before = f.calls.length;
  await assert.rejects(() => f.store.read("P1", "../OTHER"));
  assert.equal(f.calls.length, before);
});

test("probe proves create/read/query on one immutable non-version canary, never a project", async () => {
  const f = fake();
  await f.store.probe(); await f.store.probe();
  assert.equal(f.docs.size, 1);
  assert.deepEqual(f.calls.map((c) => c.op), ["create", "read", "query", "create", "read", "query"]);
  const canary = [...f.docs.values()][0] as any;
  assert.equal(canary.kind, "projectConfigHistoryProbe");
  assert.equal(Object.hasOwn(canary, "config"), false);
  assert.equal(Object.hasOwn(canary, "projectId"), false);
  assert.ok(f.calls.filter((c) => c.op === "read").every((c) => c.args[1] === "history-probe"));
});

test("probe never infers create permission from successful reads, including an existing canary", async () => {
  for (const op of ["read", "create", "query"] as const) {
    const f = fake(); await f.store.probe(); f.deny(op);
    await assert.rejects(() => f.store.probe(), (e: any) => e.permissionRequired === true &&
      e.requirements[0].action === HISTORY_ACTIONS[op] && e.requirements[0].scope === scope);
  }
});
