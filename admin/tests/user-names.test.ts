import { test } from "node:test";
import assert from "node:assert/strict";
import { UserNames } from "../ui-v3/lib/user-names.ts";
import { createUserDirectory } from "../src/user-directory.ts";

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

test("visible user lookups are batched, deduplicated, memory cached and expired", async () => {
  const calls: string[][] = [];
  let now = 0;
  const names = new UserNames(async (ids) => {
    calls.push(ids);
    return { state: "available", observedAt: new Date(now).toISOString(), data: { users: ids.map((objectId) => ({
      objectId, state: "resolved", displayName: "Example User", userPrincipalName: "example@example.invalid", expiresAt: now + 300000,
    })) } };
  }, () => now);
  const users = await Promise.all([names.get(id(1)), names.get(id(1)), names.get(id(2))]);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0], [id(1), id(2)]);
  assert.equal(users[0].displayName, "Example User");
  await names.get(id(1));
  assert.equal(calls.length, 1);
  now = 300001;
  await names.get(id(1));
  assert.equal(calls.length, 2);
});

test("browser never extends an almost-expired server-cached name and rechecks a renamed user", async () => {
  let now = 0, name = "Before", reads = 0;
  const directory = createUserDirectory({ ADMIN_USER_NAMES_ENABLED: "true" },
    { getToken: async () => ({ token: "fixture", expiresOnTimestamp: 9999999 }) }, async () => {
      reads++;
      return new Response(JSON.stringify({ responses: [{ id: id(1), status: 200, body: { id: id(1), displayName: name } }] }));
    }, () => now);
  await directory.lookup([id(1)], () => {});
  now = 299000; name = "After";
  const names = new UserNames((ids) => directory.lookup(ids, () => {}), () => now);
  assert.equal((await names.get(id(1))).displayName, "Before");
  now = 300001;
  assert.equal((await names.get(id(1))).displayName, "After", "the browser must not reset the server's five-minute TTL");
  assert.equal(reads, 2);
});

test("a stalled lookup expires, settles its IDs and lets the next queued batch run", async () => {
  let attempts = 0;
  const names = new UserNames(async () => {
    if (++attempts === 1) return new Promise(() => {});
    return { state: "disabled", observedAt: "" };
  }, Date.now, 10);
  const first = names.get(id(1));
  await new Promise((resolve) => setTimeout(resolve, 0));
  const next = names.get(id(2));
  assert.equal((await first).state, "unavailable");
  assert.equal((await next).state, "disabled");
  assert.equal((await names.get(id(1))).state, "disabled", "timed-out ID can be retried");
});

test("server freshness is translated to browser time without extending TTL or causing clock-skew polling", async () => {
  let serverNow = 0, clientNow = 60000, lookups = 0, name = "Before";
  const directory = createUserDirectory({ ADMIN_USER_NAMES_ENABLED: "true" },
    { getToken: async () => ({ token: "fixture", expiresOnTimestamp: 9999999 }) }, async () =>
      new Response(JSON.stringify({ responses: [{ id: id(1), status: 200, body: { id: id(1), displayName: name } }] })), () => serverNow);
  await directory.lookup([id(1)], () => {});
  serverNow = 299000; clientNow = 359000; name = "After";
  const names = new UserNames(async (ids) => { lookups++; return directory.lookup(ids, () => {}); }, () => clientNow);
  const before = await names.get(id(1));
  assert.equal(before.displayName, "Before");
  assert.equal(before.expiresAt, 360000, "remaining server freshness is one second on the browser clock");
  clientNow = 359500; serverNow = 299500;
  await names.get(id(1));
  assert.equal(lookups, 1, "clock skew must not cause another lookup before the local deadline");
  clientNow = 360001; serverNow = 300001;
  assert.equal((await names.get(id(1))).displayName, "After");
});

test("browser requests stay bounded and denied, disabled, missing and transient results retain identity", async () => {
  const sizes: number[] = [];
  const names = new UserNames(async (ids) => {
    sizes.push(ids.length);
    return { state: "permission_required", observedAt: "", permission: "User.Read.All" };
  });
  const rows = await Promise.all(Array.from({ length: 101 }, (_, n) => names.get(id(n))));
  assert.deepEqual(sizes, [100, 1]);
  assert.equal(rows[0].objectId, id(0));
  assert.equal(rows[0].state, "permission_required");
  assert.equal(rows[0].displayName, null);
  const disabled = new UserNames(async () => ({ state: "disabled", observedAt: "" }));
  assert.equal((await disabled.get(id(0))).state, "disabled");
  let attempt = 0;
  const transient = new UserNames(async () => {
    if (++attempt === 1) throw new Error("network offline");
    return { state: "partial", observedAt: "", data: { users: [{
      objectId: id(0), displayName: null, userPrincipalName: null, state: "not_found",
    }] } };
  });
  assert.equal((await transient.get(id(0))).state, "unavailable");
  assert.equal((await transient.get(id(0))).state, "not_found", "a failed lookup must be retried, not cached as a user");
});
