// Microsoft Graph group membership (src/sync/graph.ts). A failed read is never
// an empty group: every failure returns a reason code the planner uses to leave
// that project unchanged.

import { test } from "node:test";
import assert from "node:assert/strict";
import { parseRetryAfter, readGroupMembers } from "../src/sync/graph.ts";
import type { GraphReaderOptions } from "../src/sync/graph.ts";
import { FakeGraph, GROUP_STD, NESTED_GROUP, PERSON_A, PERSON_B, PERSON_C, SP_TEST, member, membersUrl, page } from "./helpers/sync-fakes.ts";

function options(graph: FakeGraph, overrides: Partial<GraphReaderOptions> = {}) {
  const sleeps: number[] = [];
  const opts: GraphReaderOptions = {
    fetch: graph.fetch,
    getToken: async () => "token-value",
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    maxRetries: 3,
    maxRetryAfterSeconds: 30,
    timeoutSeconds: 10,
    readServicePrincipals: false,
    now: () => Date.parse("2026-10-11T12:00:00Z"),
    ...overrides,
  };
  return { opts, sleeps };
}

const NEXT = `https://graph.microsoft.com/v1.0/groups/${GROUP_STD}/members?$select=id&$top=999&$skiptoken=abc`;

test("reads one page with $select=id and the bearer token, and types each member", async () => {
  const graph = new FakeGraph().on(
    membersUrl(GROUP_STD),
    page([member(PERSON_A), member(SP_TEST, "#microsoft.graph.servicePrincipal"), member(NESTED_GROUP, "#microsoft.graph.group"), member(PERSON_B, "#microsoft.graph.device")]),
  );
  const result = await readGroupMembers(GROUP_STD, options(graph).opts);
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.members, [
      { id: PERSON_A, kind: "user" },
      { id: SP_TEST, kind: "servicePrincipal" },
      { id: NESTED_GROUP, kind: "group" },
      { id: PERSON_B, kind: "unknown" },
    ]);
  }
  assert.equal(graph.calls[0].authorization, "Bearer token-value");
});

test("follows @odata.nextLink until the last page", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([member(PERSON_A)], NEXT)).on(NEXT, page([member(PERSON_B)]));
  const result = await readGroupMembers(GROUP_STD, options(graph).opts);
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.members.map((m) => m.id), [PERSON_A, PERSON_B]);
    assert.equal(result.pages, 2);
  }
});

test("a nextLink to another host is refused: the token is never sent outside Microsoft Graph", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([member(PERSON_A)], "https://evil.example/v1.0/next"));
  const result = await readGroupMembers(GROUP_STD, options(graph).opts);
  assert.deepEqual(result.ok ? "ok" : result.reason, "graph_response_invalid");
  assert.equal(graph.calls.length, 1);
});

test("a nextLink that repeats is refused instead of looping", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([member(PERSON_A)], NEXT)).on(NEXT, page([member(PERSON_B)], NEXT));
  const result = await readGroupMembers(GROUP_STD, options(graph).opts);
  assert.deepEqual(result.ok ? "ok" : result.reason, "graph_response_invalid");
});

test("429 with Retry-After waits that many seconds, then continues", async () => {
  const graph = new FakeGraph().on(
    membersUrl(GROUP_STD),
    { status: 429, headers: { "Retry-After": "7" } },
    page([member(PERSON_A)]),
  );
  const { opts, sleeps } = options(graph);
  const result = await readGroupMembers(GROUP_STD, opts);
  assert.equal(result.ok, true);
  assert.deepEqual(sleeps, [7000]);
  if (result.ok) assert.equal(result.retries, 1);
});

test("503 with Retry-After is retried the same way, and a page after the first is retried too", async () => {
  const graph = new FakeGraph()
    .on(membersUrl(GROUP_STD), page([member(PERSON_A)], NEXT))
    .on(NEXT, { status: 503, headers: { "Retry-After": "2" } }, page([member(PERSON_C)]));
  const { opts, sleeps } = options(graph);
  const result = await readGroupMembers(GROUP_STD, opts);
  assert.equal(result.ok, true);
  assert.deepEqual(sleeps, [2000]);
});

test("retries are bounded: after maxRetries the read fails as throttled, never as an empty group", async () => {
  const throttled = { status: 429, headers: { "Retry-After": "1" } };
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), throttled, throttled, throttled, throttled);
  const { opts, sleeps } = options(graph, { maxRetries: 3 });
  const result = await readGroupMembers(GROUP_STD, opts);
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.equal(result.reason, "graph_throttled");
    assert.equal(result.httpStatus, 429);
  }
  assert.equal(graph.calls.length, 4);
  assert.equal(sleeps.length, 3);
});

test("a Retry-After longer than the configured bound fails at once instead of waiting", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), { status: 429, headers: { "Retry-After": "31" } });
  const { opts, sleeps } = options(graph, { maxRetryAfterSeconds: 30 });
  const result = await readGroupMembers(GROUP_STD, opts);
  assert.deepEqual(result.ok ? "ok" : result.reason, "graph_throttled");
  assert.deepEqual(sleeps, []);
});

test("without Retry-After the wait backs off exponentially within the bound", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), { status: 503 }, { status: 503 }, { status: 503 }, page([]));
  const { opts, sleeps } = options(graph, { maxRetries: 3, maxRetryAfterSeconds: 3 });
  const result = await readGroupMembers(GROUP_STD, opts);
  assert.equal(result.ok, true);
  assert.deepEqual(sleeps, [1000, 2000, 3000]);
});

test("403 Authorization_RequestDenied is graph_permission_missing and is not retried", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), {
    status: 403,
    body: { error: { code: "Authorization_RequestDenied", message: "Insufficient privileges to complete the operation." } },
  });
  const { opts, sleeps } = options(graph);
  const result = await readGroupMembers(GROUP_STD, opts);
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.equal(result.reason, "graph_permission_missing");
    assert.equal(result.graphErrorCode, "Authorization_RequestDenied");
    assert.equal(result.httpStatus, 403);
  }
  assert.equal(graph.calls.length, 1);
  assert.deepEqual(sleeps, []);
});

test("other statuses map to their own reason codes, with no retry", async () => {
  const cases: [number, string][] = [
    [401, "graph_unauthorized"],
    [404, "graph_group_not_found"],
    [400, "graph_request_failed"],
    [500, "graph_unavailable"],
    [502, "graph_unavailable"],
  ];
  for (const [status, reason] of cases) {
    const graph = new FakeGraph().on(membersUrl(GROUP_STD), { status, body: { error: { code: "X", message: "m" } } });
    const result = await readGroupMembers(GROUP_STD, options(graph).opts);
    assert.deepEqual(result.ok ? "ok" : result.reason, reason, String(status));
    assert.equal(graph.calls.length, 1, String(status));
  }
});

test("a network error is retried with backoff, then reported as graph_unavailable", async () => {
  const boom = new TypeError("fetch failed");
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), boom, boom);
  const { opts } = options(graph, { maxRetries: 1 });
  const result = await readGroupMembers(GROUP_STD, opts);
  assert.deepEqual(result.ok ? "ok" : result.reason, "graph_unavailable");
  assert.equal(graph.calls.length, 2);
});

test("a token that cannot be obtained fails the read with graph_token_failed and makes no call", async () => {
  const graph = new FakeGraph();
  const { opts } = options(graph, {
    getToken: async () => {
      throw new Error("no identity");
    },
  });
  const result = await readGroupMembers(GROUP_STD, opts);
  assert.deepEqual(result.ok ? "ok" : result.reason, "graph_token_failed");
  assert.equal(graph.calls.length, 0);
});

test("a malformed page is graph_response_invalid", async () => {
  for (const body of ["not json", { value: "x" }, { value: [{ id: "not-a-guid" }] }, { value: [{}] }]) {
    const graph = new FakeGraph().on(membersUrl(GROUP_STD), { status: 200, body });
    const result = await readGroupMembers(GROUP_STD, options(graph).opts);
    assert.deepEqual(result.ok ? "ok" : result.reason, "graph_response_invalid", JSON.stringify(body));
  }
});

test("a member without @odata.type fails the read (U-new-SYNC-1): a shape Graph does not document is never read as a group of nobody", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), page([member(PERSON_B), { id: PERSON_A }]));
  const result = await readGroupMembers(GROUP_STD, options(graph).opts);
  assert.deepEqual(result.ok ? result.members : result.reason, "graph_response_invalid");
});

test("the beforeRequest hook runs before every request, including retries, and its failure stops the read", async () => {
  const graph = new FakeGraph().on(membersUrl(GROUP_STD), { status: 429, headers: { "Retry-After": "1" } }, page([member(PERSON_A)]));
  let hooks = 0;
  const { opts } = options(graph, {
    beforeRequest: async () => {
      hooks += 1;
    },
  });
  await readGroupMembers(GROUP_STD, opts);
  assert.equal(hooks, 2);

  const lost = new Error("lease lost");
  const graph2 = new FakeGraph();
  const { opts: opts2 } = options(graph2, {
    beforeRequest: async () => {
      throw lost;
    },
  });
  await assert.rejects(readGroupMembers(GROUP_STD, opts2), lost);
  assert.equal(graph2.calls.length, 0);
});

test("parseRetryAfter reads delta-seconds and HTTP dates, and rejects anything else", () => {
  const now = Date.parse("2026-10-11T12:00:00Z");
  assert.equal(parseRetryAfter("10", now), 10);
  assert.equal(parseRetryAfter("0", now), 0);
  assert.equal(parseRetryAfter("Sun, 11 Oct 2026 12:00:05 GMT", now), 5);
  assert.equal(parseRetryAfter("Sun, 11 Oct 2026 11:59:00 GMT", now), 0);
  assert.equal(parseRetryAfter(null, now), null);
  assert.equal(parseRetryAfter("soon", now), null);
  assert.equal(parseRetryAfter("-3", now), null);
});
