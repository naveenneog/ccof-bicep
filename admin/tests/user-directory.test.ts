import { test } from "node:test";
import assert from "node:assert/strict";
import { createUserDirectory, readUserIds } from "../src/user-directory.ts";

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const enabled = { ADMIN_USER_NAMES_ENABLED: "true" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

test("lookup validates and normalizes bounded GUID input before contacting Graph", () => {
  assert.deepEqual(readUserIds({ objectIds: [id(1).toUpperCase(), id(1)] }), [id(1)]);
  for (const body of [null, {}, { objectIds: [] }, { objectIds: ["x?api-version=bad"] },
    { objectIds: Array.from({ length: 101 }, (_, i) => id(i)) }, { objectIds: [id(1)], other: 1 }]) {
    assert.throws(() => readUserIds(body), /invalid_user_ids/);
  }
});

test("Graph batch lookup requests only identity labels, joins out-of-order responses by ID, and expires cache", async () => {
  let now = 0;
  const requests: { ids: string[]; urls: string[] }[] = [];
  const logs: string[] = [];
  const directory = createUserDirectory(enabled, { getToken: async () => ({ token: "fixture", expiresOnTimestamp: 9999999 }) },
    async (url, init) => {
      assert.equal(url, "https://graph.microsoft.com/v1.0/$batch");
      assert.equal(init?.redirect, "error");
      assert.equal(init?.method, "POST");
      const batch = JSON.parse(String(init?.body)).requests;
      requests.push({ ids: batch.map((r: { id: string }) => r.id), urls: batch.map((r: { url: string }) => r.url) });
      assert.ok(batch.length <= 20);
      return json({ responses: batch.toReversed().map((r: { id: string; url: string }) => ({
        id: r.id, status: 200, body: { id: r.id, displayName: `Person ${r.id}`, userPrincipalName: "person@example.invalid", extra: "not returned" },
      })) });
    }, () => now);
  const ids = Array.from({ length: 21 }, (_, i) => id(i));
  const cap = await directory.lookup(ids, (l) => logs.push(l));
  assert.equal(cap.state, "available");
  assert.equal(requests.length, 2);
  assert.ok(requests.every((r) => r.urls.every((u) => u.endsWith("?$select=id,displayName,userPrincipalName"))));
  assert.deepEqual(cap.data?.users.map((u) => u.objectId), ids);
  assert.equal(cap.data?.users[0].displayName, `Person ${id(0)}`);
  assert.ok(cap.data?.users.every((u) => !Object.hasOwn(u, "extra")));
  await directory.lookup(ids, () => {});
  assert.equal(requests.length, 2);
  now = 300001;
  await directory.lookup([id(0)], () => {});
  assert.equal(requests.length, 3);
  assert.deepEqual(logs, []);
});

test("missing users and per-request throttling stay distinct; failures are not cached or logged with names/IDs", async () => {
  let attempts = 0;
  const logs: string[] = [];
  const directory = createUserDirectory(enabled, { getToken: async () => ({ token: "fixture", expiresOnTimestamp: 9999999 }) }, async () => {
    attempts++;
    return json({ responses: [
      { id: id(1), status: 404 },
      { id: id(2), status: attempts === 1 ? 429 : 200, body: { id: id(2), displayName: "Example User", userPrincipalName: "u@example.invalid" } },
    ].filter((r) => attempts === 1 || r.id === id(2)) });
  });
  const first = await directory.lookup([id(1), id(2)], (l) => logs.push(l));
  assert.equal(first.state, "partial");
  assert.deepEqual(first.data?.users.map((u) => u.state), ["not_found", "unavailable"]);
  const second = await directory.lookup([id(1), id(2)], () => {});
  assert.equal(attempts, 2);
  assert.equal(second.data?.users[1].displayName, "Example User");
  assert.ok(logs.length > 0);
  assert.ok(logs.every((l) => !l.includes(id(1)) && !l.includes(id(2)) && !l.includes("@") && !l.includes("Example")));
});

test("disabled, permission denied, malformed and redirected/provider failures never become resolved users", async () => {
  let calls = 0;
  const credential = { getToken: async () => { calls++; return { token: "fixture", expiresOnTimestamp: 9999999 }; } };
  const off = createUserDirectory({}, credential, async () => { throw new Error("must not call"); });
  assert.equal((await off.lookup([id(1)], () => {})).state, "disabled");
  assert.equal(calls, 0);
  for (const [status, body, expected] of [
    [403, {}, "permission_required"], [200, { responses: [] }, "unavailable"],
    [200, { responses: [{ id: id(1), status: 200, body: { id: id(2), displayName: "Wrong person" } }] }, "unavailable"],
  ] as const) {
    const directory = createUserDirectory(enabled, credential, async () => json(body, status));
    const result = await directory.lookup([id(1)], () => {});
    assert.equal(result.state, expected);
    assert.equal(result.data?.users[0].displayName, null);
  }
});

test("server cache is bounded, refresh bypasses it, and a per-user permission denial stays explicit", async () => {
  let calls = 0, denied = false;
  const directory = createUserDirectory(enabled, { getToken: async () => ({ token: "fixture", expiresOnTimestamp: 9999999 }) }, async (_url, init) => {
    calls++;
    const requests = JSON.parse(String(init?.body)).requests;
    return json({ responses: requests.map((r: { id: string }) => ({
      id: r.id, status: denied ? 403 : 200, body: { id: r.id, displayName: "Example" },
    })) });
  });

  for (let batch = 0; batch < 11; batch++) {
    await directory.lookup(Array.from({ length: 100 }, (_, i) => id(batch * 100 + i)), () => {});
  }
  const cachedCalls = calls;
  await directory.lookup([id(1099)], () => {});
  assert.equal(calls, cachedCalls);
  await directory.lookup([id(0)], () => {});
  assert.equal(calls, cachedCalls + 1, "oldest identity was evicted");
  denied = true;
  const refresh = await directory.lookup([id(1099)], () => {}, true);
  assert.equal(refresh.state, "permission_required");
  assert.equal(refresh.data?.users[0].displayName, null, "refresh must not serve a previously cached name after denial");
});

test("server deadline includes managed-identity token acquisition", async () => {
  const logs: string[] = [];
  const directory = createUserDirectory(enabled, { getToken: () => new Promise(() => {}) },
    async () => { throw new Error("must not reach transport"); }, Date.now, 10);
  const cap = await directory.lookup([id(1)], (l) => logs.push(l));
  assert.equal(cap.state, "unavailable");
  assert.match(logs[0], /directory_request_timeout/);
});

test("an early batch failure aborts sibling transports as the lookup ends", async () => {
  const signals: AbortSignal[] = [];
  const directory = createUserDirectory(enabled, { getToken: async () => ({ token: "fixture", expiresOnTimestamp: 9999999 }) },
    async (_url, init) => {
      signals.push(init!.signal!);
      if (signals.length === 1) return json({}, 503);
      return new Promise(() => {});
    });
  assert.equal((await directory.lookup(Array.from({ length: 21 }, (_, i) => id(i)), () => {})).state, "unavailable");
  assert.equal(signals.length, 2);
  assert.ok(signals.every((s) => s.aborted), "no sibling request should remain unbounded after returning");
});
