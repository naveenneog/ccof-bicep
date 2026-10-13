// The Log Analytics query API client (docs/PILOT.md C-7): one POST per run
// with the managed identity's token. Every failure is a LedgerReadError with
// a code, never a body or a token, and never "no usage".

import { test } from "node:test";
import assert from "node:assert/strict";
import { LedgerReadError } from "../src/reconciler/ledger.ts";
import { createLedgerQuery, logAnalyticsScope } from "../src/reconciler/log-analytics.ts";
import type { FetchLike } from "../src/reconciler/log-analytics.ts";

const WORKSPACE = "00000000-0000-4000-8000-000001100000";
const TOKEN = "eyJ.fake.token";

interface Call {
  url: string;
  init: Parameters<FetchLike>[1];
}

function client(fetch: FetchLike, getToken: () => Promise<string> = async () => TOKEN) {
  return createLedgerQuery({ endpoint: "https://api.loganalytics.io", workspaceId: WORKSPACE, timeoutSeconds: 60, getToken, fetch });
}

const answer = (status: number, text: string): FetchLike => async () => ({ status, headers: new Headers(), text: async () => text });

async function reason(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    assert.ok(error instanceof LedgerReadError, String(error));
    assert.equal(String(error.message).includes(TOKEN), false, "the token never appears in an error");
    return `${error.reason}${error.code === undefined ? "" : `:${error.code}`}`;
  }
  return "no error";
}

test("the token scope is the endpoint's .default", () => {
  assert.equal(logAnalyticsScope("https://api.loganalytics.io"), "https://api.loganalytics.io/.default");
});

test("one POST to the workspace's query URL, with the bearer token, the server wait and the query and timespan", async () => {
  const calls: Call[] = [];
  const query = client(async (url, init) => {
    calls.push({ url, init });
    return { status: 200, headers: new Headers(), text: async () => '{"tables":[]}' };
  });
  assert.deepEqual(await query("Q", "2026-10-01T00:00:00.000Z/2026-11-01T00:00:00.000Z"), { body: { tables: [] }, responseAgeSeconds: null });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `https://api.loganalytics.io/v1/workspaces/${WORKSPACE}/query`);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers.authorization, `Bearer ${TOKEN}`);
  assert.equal(calls[0].init.headers.prefer, "wait=60");
  assert.deepEqual(JSON.parse(calls[0].init.body), { query: "Q", timespan: "2026-10-01T00:00:00.000Z/2026-11-01T00:00:00.000Z" });
  assert.ok(calls[0].init.signal instanceof AbortSignal);
});

// Every run sends the same query and timespan for a month. The API keeps an answer for 2 minutes unless the
// request says no-cache (Learn, "Caching"), so without it about 40% of the 2-minute runs read the previous
// run's answer (WP-E2E G6, docs/status/WP-REC.md "Ledger freshness").
test("every read bypasses the query API's response cache", async () => {
  const calls: Call[] = [];
  const query = client(async (url, init) => {
    calls.push({ url, init });
    return { status: 200, headers: new Headers(), text: async () => '{"tables":[]}' };
  });
  await query("Q", "T");
  await query("Q", "T");
  assert.deepEqual(calls.map((c) => c.init.headers["cache-control"]), ["no-cache", "no-cache"]);
});

test("an answer from the cache carries its Age in whole seconds; none, or a malformed one, is null", async () => {
  const withAge = (age: string | null): FetchLike => async () => ({
    status: 200,
    headers: new Headers(age === null ? {} : { age }),
    text: async () => '{"tables":[]}',
  });
  assert.equal((await client(withAge("75"))("Q", "T")).responseAgeSeconds, 75);
  assert.equal((await client(withAge("0"))("Q", "T")).responseAgeSeconds, 0);
  assert.equal((await client(withAge(null))("Q", "T")).responseAgeSeconds, null);
  for (const bad of ["", "-1", "1.5", "75s", "1e3", "99999999999"]) {
    assert.equal((await client(withAge(bad))("Q", "T")).responseAgeSeconds, null, `Age ${JSON.stringify(bad)}`);
  }
});

test("no token: the read fails before any request", async () => {
  let called = false;
  const query = client(async () => ((called = true), { status: 200, headers: new Headers(), text: async () => "{}" }), async () => {
    throw new Error("CredentialUnavailableError");
  });
  assert.equal(await reason(query("Q", "T")), "ledger_request_failed:token");
  assert.equal(called, false);
});

test("an HTTP error is a failed read with its status; 504 is the server's timeout", async () => {
  assert.equal(await reason(client(answer(403, "{}"))("Q", "T")), "ledger_http_error:403");
  assert.equal(await reason(client(answer(429, "{}"))("Q", "T")), "ledger_http_error:429");
  assert.equal(await reason(client(answer(504, "{}"))("Q", "T")), "ledger_timeout:504");
});

test("a client timeout and a network failure are failed reads", async () => {
  const timeout: FetchLike = async () => {
    throw new DOMException("The operation was aborted due to timeout", "TimeoutError");
  };
  assert.equal(await reason(client(timeout)("Q", "T")), "ledger_timeout");
  const network: FetchLike = async () => {
    throw new TypeError("fetch failed");
  };
  assert.equal(await reason(client(network)("Q", "T")), "ledger_request_failed:TypeError");
});

test("a body that fails to arrive or is not JSON is a failed read", async () => {
  const brokenBody: FetchLike = async () => ({
    status: 200,
    headers: new Headers(),
    text: async () => {
      throw new DOMException("aborted", "AbortError");
    },
  });
  assert.equal(await reason(client(brokenBody)("Q", "T")), "ledger_timeout");
  assert.equal(await reason(client(answer(200, "<html>"))("Q", "T")), "ledger_response_invalid:json");
});
