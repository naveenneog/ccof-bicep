// Tests for the stream usage reader (ADR-0022, O10). The reader is an offline prototype: nothing in
// the gateway, the ledger or any deployed app uses it. Fixtures: tests/fixtures/usage/sse-streams.json
// (synthetic text, counts recorded live for U-C and U-D). Anthropic "Streaming messages" and "Prompt
// caching", retrieved 2026-10-12: message_start carries the usage with the cache counts and the TTL
// split; message_delta's usage is cumulative; ping, error and unknown events can occur.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { createStreamUsageReader, readStreamUsage } from "../src/usage/sse-usage.ts";
import type { StreamUsage, StreamUsageOptions } from "../src/usage/sse-usage.ts";
import { TOKEN_CATEGORIES } from "../src/cost/token-categories.ts";
import type { TokenCategory } from "../src/cost/token-categories.ts";

const FIXTURE_DIR = new URL("./fixtures/usage/", import.meta.url);
const FIXTURE_FILE = "sse-streams.json";

interface Expected {
  outcome: StreamUsage["outcome"];
  final: boolean;
  ttlSplitMismatch: boolean;
  tokens: Record<TokenCategory, number | null>;
}
interface Fixture {
  name: string;
  source: string;
  events: [string, unknown][];
  expected: Expected;
}

const fixtures: Fixture[] = JSON.parse(readFileSync(new URL(FIXTURE_FILE, FIXTURE_DIR), "utf8")).streams;

function fixture(name: string): Fixture {
  const found = fixtures.find((f) => f.name === name);
  assert.ok(found, `fixture ${name} exists`);
  return found;
}

function toSse(events: [string, unknown][], eol = "\n"): string {
  return events.map(([name, data]) => `event: ${name}${eol}data: ${JSON.stringify(data)}${eol}${eol}`).join("");
}

function readInChunks(text: string, chunkSize: number, options?: StreamUsageOptions): StreamUsage {
  const bytes = new TextEncoder().encode(text);
  const reader = createStreamUsageReader(options);
  for (let i = 0; i < bytes.length; i += chunkSize) reader.push(bytes.subarray(i, i + chunkSize));
  return reader.end();
}

function counts(result: StreamUsage): Expected {
  return { outcome: result.outcome, final: result.final, ttlSplitMismatch: result.ttlSplitMismatch, tokens: result.tokens };
}

test("every stream in the fixture file yields its expected outcome and counts", async (t) => {
  assert.ok(fixtures.length >= 13, "the fixture file holds the documented and recorded streams");
  for (const f of fixtures) {
    await t.test(f.name, () => {
      assert.deepEqual(counts(readStreamUsage(toSse(f.events))), f.expected, f.source);
    });
  }
});

test("U-C and U-D give exactly the usage WP-GW recorded for them on 2026-10-12", () => {
  const uc = readStreamUsage(toSse(fixture("u-c-recorded").events));
  assert.deepEqual(uc.tokens, { input: 13, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 5890, output: 4 });
  const ud = readStreamUsage(toSse(fixture("u-d-recorded").events));
  assert.deepEqual(ud.tokens, { input: 13, cacheWrite5m: 6650, cacheWrite1h: 0, cacheRead: 0, output: 4 });
  assert.equal(ud.outcome, "complete");
});

test("the result names exactly the rate card's five token categories", () => {
  const result = readStreamUsage(toSse(fixture("mixed-ttl").events));
  assert.deepEqual(Object.keys(result.tokens).sort(), [...TOKEN_CATEGORIES].sort());
});

test("LF, CRLF and CR line ends give the same result (the SSE format allows all three)", () => {
  for (const f of fixtures) {
    const lf = counts(readStreamUsage(toSse(f.events, "\n")));
    assert.deepEqual(counts(readStreamUsage(toSse(f.events, "\r\n"))), lf, `${f.name} with CRLF`);
    assert.deepEqual(counts(readStreamUsage(toSse(f.events, "\r"))), lf, `${f.name} with CR`);
  }
});

test("chunk boundaries do not change the result, including splits inside CRLF and multi-byte characters", () => {
  for (const f of fixtures) {
    for (const eol of ["\n", "\r\n"]) {
      const text = toSse(f.events, eol);
      const whole = counts(readStreamUsage(text));
      for (const size of [1, 2, 3, 5, 7, 64]) {
        assert.deepEqual(counts(readInChunks(text, size)), whole, `${f.name}, ${JSON.stringify(eol)}, ${size}-byte chunks`);
      }
    }
  }
});

test("comments, a field without a space, multi-line data and unknown events are read as the SSE format defines", () => {
  const uc = fixture("u-c-recorded");
  const [startName, startData] = uc.events[0];
  const json = JSON.stringify(startData);
  const cut = json.indexOf(",\"usage\"");
  const text =
    ": keep-alive comment\n" +
    `event: ${startName}\ndata:${json.slice(0, cut)}\ndata: ${json.slice(cut)}\n\n` +
    "event: future_event\ndata: {\"type\":\"future_event\"}\n\n" +
    ": another comment\n" +
    toSse(uc.events.slice(1));
  const result = readStreamUsage(text);
  assert.deepEqual(counts(result), uc.expected);
  assert.equal(result.anomalies, 0);
  assert.ok(result.skippedEvents >= 5, `content, ping and unknown events skipped (${result.skippedEvents})`);
});

test("response text is never kept: memory stays bounded whatever the chunk size", () => {
  const uc = fixture("u-c-recorded");
  const big = { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "SENTINEL-TEXT " + "x".repeat(2_000_000) } };
  const events: [string, unknown][] = [uc.events[0], uc.events[1], ["content_block_delta", big], ...uc.events.slice(4)];
  const result = readInChunks(toSse(events, "\r\n"), 65_536);
  assert.deepEqual(result.tokens, uc.expected.tokens);
  assert.ok(result.maxRetainedChars < 2_000, `at most one usage event held at a time (${result.maxRetainedChars} chars)`);
  const smaller = { ...big, delta: { type: "text_delta", text: "y".repeat(20_000) } };
  const text = toSse([uc.events[0], uc.events[1], ["content_block_delta", smaller], ...uc.events.slice(4)]);
  for (const size of [1, 2, 3, 4, 7]) {
    const chunked = readInChunks(text, size);
    assert.deepEqual(chunked.tokens, uc.expected.tokens);
    assert.ok(chunked.maxRetainedChars < 2_000, `${size}-byte chunks: ${chunked.maxRetainedChars} chars held`);
  }
});

test("data sent before its event line is held only up to the size limit (Anthropic sends the event line first)", () => {
  const text = `data: {"type":"content_block_delta","text":"${"z".repeat(50_000)}"}\nevent: content_block_delta\n\n`;
  const result = readStreamUsage(text, { maxEventChars: 4_096 });
  assert.ok(result.maxRetainedChars <= 4_096, `${result.maxRetainedChars} chars held`);
  assert.equal(result.skippedEvents, 1);
});

test("a null count in message_delta means not reported: earlier counts stay (as Anthropic's SDK accumulates)", () => {
  const uc = fixture("u-c-recorded");
  const nulls = { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { input_tokens: null, cache_creation_input_tokens: null, cache_read_input_tokens: null, cache_creation: null, output_tokens: 4 } };
  const result = readStreamUsage(toSse([uc.events[0], ["message_delta", nulls], ["message_stop", { type: "message_stop" }]]));
  assert.deepEqual(result.tokens, uc.expected.tokens);
  assert.equal(result.final, true);
  const bad = { ...nulls, usage: { cache_creation: "not an object", output_tokens: 4 } };
  const unknownSplit = readStreamUsage(toSse([fixture("u-d-recorded").events[0], ["message_delta", bad], ["message_stop", { type: "message_stop" }]]));
  assert.deepEqual([unknownSplit.tokens.cacheWrite5m, unknownSplit.tokens.cacheWrite1h], [null, null], "a split that is not an object is unknown");
});

test("the TTL split is used only when cache_creation_input_tokens is a valid count equal to its sum", () => {
  for (const name of ["split-without-aggregate", "split-with-invalid-aggregate"]) {
    const result = readStreamUsage(toSse(fixture(name).events));
    assert.equal(result.cacheCreationTotal, null, `${name}: the aggregate is unknown`);
    assert.deepEqual([result.tokens.cacheWrite5m, result.tokens.cacheWrite1h], [null, null], `${name}: the split is not used`);
    assert.equal(result.ttlSplitMismatch, false, `${name}: no aggregate to disagree with`);
    assert.equal(result.final, true, `${name}: the stream itself completed`);
  }
  const [name, data] = fixture("split-with-invalid-aggregate").events[0] as [string, { message: { usage: Record<string, unknown> } }];
  const valid = { ...data, message: { ...data.message, usage: { ...data.message.usage, cache_creation_input_tokens: 100 } } };
  const control = readStreamUsage(toSse([[name, valid], ...fixture("split-with-invalid-aggregate").events.slice(1)]));
  assert.deepEqual([control.tokens.cacheWrite5m, control.tokens.cacheWrite1h, control.cacheCreationTotal], [100, 0, 100], "with a valid aggregate of 100 the split is used");
});

test("a usage event over the size limit is dropped, and its counts are unknown, never zero", () => {
  const ud = fixture("u-d-recorded");
  const [name, data] = ud.events[0] as [string, { message: Record<string, unknown> }];
  const padded = { ...data, message: { ...data.message, id: "msg_" + "p".repeat(5_000) } };
  const result = readStreamUsage(toSse([[name, padded], ...ud.events.slice(1)]), { maxEventChars: 2_000 });
  assert.equal(result.oversizedEvents, 1);
  assert.ok(result.maxRetainedChars <= 2_000, `no more than the limit is held (${result.maxRetainedChars})`);
  assert.equal(result.final, false, "a dropped usage event makes the stream not final");
  assert.equal(result.tokens.cacheWrite5m, null, "the TTL split came only with the dropped event");
  assert.equal(result.tokens.cacheWrite1h, null);
  assert.equal(result.ttlSplitMismatch, false, "no split was read, so none can disagree");
  assert.equal(result.tokens.cacheRead, 0, "message_delta repeats the cache totals, so they are still known");
  assert.equal(result.tokens.output, 4, "message_delta's cumulative output is still read");
  assert.equal(result.tokens.input, 13, "message_delta repeats input, so it is still known");
});

test("data lines that together exceed the size limit drop the event, as one long line does", () => {
  const json = JSON.stringify(fixture("u-c-recorded").events[0][1]);
  const lines = json.split(",").map((part, i, all) => (i < all.length - 1 ? `${part},` : part));
  assert.ok(lines.length > 10 && lines.every((l) => l.length < 150));
  const text = `event: message_start\n${lines.map((l) => `data: ${l}`).join("\n")}\n\n` + toSse([["message_stop", { type: "message_stop" }]]);
  assert.equal(readStreamUsage(text).tokens.cacheRead, 5890, "within the default limit the split event is read");
  const limited = readStreamUsage(text, { maxEventChars: 200 });
  assert.equal(limited.oversizedEvents, 1);
  assert.equal(limited.tokens.cacheRead, null);
});

test("an event without a data line is not dispatched, as the SSE format defines", () => {
  const result = readStreamUsage("event: message_stop\n\nevent: ping\n\n");
  assert.equal(result.outcome, "incomplete");
  assert.equal(result.events, 0);
  assert.equal(result.anomalies, 0);
});

test("malformed JSON in a usage event is an anomaly and leaves its counts unknown", () => {
  const text = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":13\n\n" + toSse([["message_stop", { type: "message_stop" }]]);
  const result = readStreamUsage(text);
  assert.equal(result.anomalies, 1);
  assert.equal(result.final, false);
  assert.equal(result.tokens.input, null);
});

test("an event after message_stop is an anomaly and does not change the counts", () => {
  const uc = fixture("u-c-recorded");
  const late: [string, unknown] = ["message_delta", { type: "message_delta", delta: {}, usage: { output_tokens: 999 } }];
  const result = readStreamUsage(toSse([...uc.events, late]));
  assert.equal(result.outcome, "complete");
  assert.equal(result.final, false);
  assert.equal(result.tokens.output, 4);
});

test("random bytes never make the reader throw, and give no counts", () => {
  let seed = 7;
  const next = () => (seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648);
  for (let round = 0; round < 20; round++) {
    const bytes = new Uint8Array(4_096).map(() => next() % 256);
    const reader = createStreamUsageReader();
    reader.push(bytes);
    const result = reader.end();
    assert.equal(result.outcome, "incomplete");
    assert.deepEqual(Object.values(result.tokens), [null, null, null, null, null]);
  }
});

test("the reader refuses input after end(), and options outside their range", () => {
  const reader = createStreamUsageReader();
  reader.push("event: ping\ndata: {\"type\":\"ping\"}\n\n");
  reader.end();
  assert.throws(() => reader.push("x"), /ended/);
  assert.throws(() => reader.end(), /ended/);
  assert.throws(() => createStreamUsageReader({ maxEventChars: 0 }), /maxEventChars/);
  assert.throws(() => createStreamUsageReader({ maxEventChars: 1.5 }), /maxEventChars/);
});

test("the fixture file is referenced with its exact case (Linux file names are case-sensitive)", () => {
  const names = readdirSync(FIXTURE_DIR);
  assert.ok(names.includes(FIXTURE_FILE), `${FIXTURE_FILE} among ${names.join(", ")}`);
});
