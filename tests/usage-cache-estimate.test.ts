// Tests for the request-side cache estimate (ADR-0022 option D, O10). Offline prototype: nothing in
// the gateway or the ledger uses it. It models Anthropic "Prompt caching" (retrieved 2026-10-12):
// prefixes in tools, system, messages order; a write only at a breakpoint; reads found by a lookback
// of 20 blocks; at most 4 breakpoints; a 1-hour entry before any 5-minute one; billing positions A, B
// and C for mixed TTLs; a per-model minimum cacheable length. The recorded-call tests measure it
// against WP-GW's U-34 run (tests/fixtures/usage/u34-recorded-calls.json).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { PrefixMemory, PromptShapeError, readPromptShape } from "../src/usage/cache-estimate.ts";
import type { CacheEstimate } from "../src/usage/cache-estimate.ts";

const FIXTURE_DIR = new URL("./fixtures/usage/", import.meta.url);
const RECORDED_FILE = "u34-recorded-calls.json";
const MIN = 60_000;

type Body = Record<string, unknown>;
const text = (t: string, ttl?: "5m" | "1h") => ({ type: "text", text: t, ...(ttl ? { cache_control: ttl === "5m" ? { type: "ephemeral" } : { type: "ephemeral", ttl } } : {}) });
const turn = (i: number) => ({ role: i % 2 === 0 ? "user" : "assistant", content: [text(`turn ${i} `.padEnd(100, "x"))] });
// A conversation of `blocks` content blocks (100 characters each) whose last block is the breakpoint.
function conversation(blocks: number, extraBreakpointAt?: number): Body {
  const messages = Array.from({ length: blocks }, (_, i) => turn(i)) as { content: Record<string, unknown>[] }[];
  messages[blocks - 1].content[0].cache_control = { type: "ephemeral" };
  if (extraBreakpointAt !== undefined) messages[extraBreakpointAt - 1].content[0].cache_control = { type: "ephemeral" };
  return { model: "m", messages };
}
const memory = (min = 0) => new PrefixMemory({ charsPerToken: 1, minCacheableTokens: min });
const shape = (body: Body) => readPromptShape(body);

function refuses(body: unknown, code: string, field: string): void {
  assert.throws(() => readPromptShape(body), (error: unknown) => {
    assert.ok(error instanceof PromptShapeError, String(error));
    assert.equal(error.code, code, error.message);
    assert.equal(error.field, field, error.message);
    return true;
  });
}

test("breakpoints are found in tools, system and messages order, each with its TTL", () => {
  const s = shape({
    model: "m",
    tools: [{ name: "t1", input_schema: {}, cache_control: { type: "ephemeral", ttl: "1h" } }],
    system: [text("system prompt", "5m")],
    messages: [{ role: "user", content: "question" }],
  });
  assert.deepEqual(s.blocks.map((b) => [b.section, b.ttl]), [["tools", "1h"], ["system", "5m"], ["messages", null]]);
  assert.deepEqual(s.breakpoints, [0, 1]);
  assert.equal(s.blocks[0].chars, JSON.stringify({ name: "t1", input_schema: {} }).length, "a tool is measured as its JSON definition");
  assert.equal(s.totalChars, s.blocks[0].chars + "system prompt".length + "question".length);
  assert.equal(s.blocks[1].cumulativeChars, s.blocks[0].chars + "system prompt".length);
});

test("a top-level cache_control marks the last eligible block (automatic caching)", () => {
  const s = shape({
    model: "m",
    cache_control: { type: "ephemeral", ttl: "1h" },
    messages: [
      { role: "user", content: [text("ask")] },
      { role: "assistant", content: [text("answer"), { type: "thinking", thinking: "t", signature: "s" }, text("")] },
    ],
  });
  assert.deepEqual(s.breakpoints, [1], "the thinking block and the empty text block are not eligible");
  assert.equal(s.blocks[1].ttl, "1h");
});

test("bodies the API would refuse are refused here, naming the field", () => {
  refuses(null, "invalid_body", "(body)");
  refuses({ model: "m" }, "invalid_value", "messages");
  refuses({ model: "m", messages: [{ role: "user", content: [{ text: "no type" }] }] }, "invalid_value", "messages[0].content[0].type");
  refuses({ model: "m", messages: [{ role: "user", content: [text("a"), { ...text("b"), cache_control: { type: "ephemeral", ttl: "2h" } }] }] }, "invalid_cache_control", "messages[0].content[1].cache_control");
  const five = [text("1", "5m"), text("2", "5m"), text("3", "5m"), text("4", "5m"), text("5", "5m")];
  refuses({ model: "m", messages: [{ role: "user", content: five }] }, "too_many_breakpoints", "messages[0].content[4].cache_control");
  refuses({ model: "m", cache_control: { type: "ephemeral" }, messages: [{ role: "user", content: five.slice(0, 4).concat([text("x")]) }] }, "too_many_breakpoints", "cache_control");
  refuses({ model: "m", messages: [{ role: "user", content: [text("a", "5m"), text("b", "1h")] }] }, "ttl_order", "messages[0].content[1].cache_control");
  refuses({ model: "m", cache_control: { type: "ephemeral", ttl: "1h" }, messages: [{ role: "user", content: [text("a", "5m")] }] }, "conflicting_ttl", "cache_control");
});

test("a repeated prefix within its TTL is read; a new or expired one is written", () => {
  const m = memory();
  const body = conversation(3);
  const tokens = shape(body).blocks[2].cumulativeChars;
  assert.deepEqual(m.estimate(shape(body), 0), { read: 0, write5m: tokens, write1h: 0, hitBlock: null, measured: true });
  assert.deepEqual(m.estimate(shape(body), 299_000), { read: tokens, write5m: 0, write1h: 0, hitBlock: 2, measured: true });
  assert.deepEqual(m.estimate(shape(body), 299_000 + 300_001), { read: 0, write5m: tokens, write1h: 0, hitBlock: null, measured: true }, "expired five minutes after the last use");
});

test("a read refreshes the entry, and a one-hour entry outlives five minutes", () => {
  const m = memory();
  const body = conversation(2);
  m.estimate(shape(body), 0);
  assert.equal(m.estimate(shape(body), 240_000).hitBlock, 1);
  assert.equal(m.estimate(shape(body), 480_000).hitBlock, 1, "refreshed at 240 s, so still fresh at 480 s");
  const viaLookback = memory();
  viaLookback.estimate(shape(conversation(10)), 0);
  assert.equal(viaLookback.estimate(shape(conversation(15)), 200_000).hitBlock, 9, "read through the lookback");
  assert.equal(viaLookback.estimate(shape(conversation(10)), 450_000).hitBlock, 9, "that read refreshed block 10's entry");
  const hour = { model: "m", messages: [{ role: "user", content: [text("long-lived", "1h")] }] };
  const h = memory();
  h.estimate(shape(hour), 0);
  assert.equal(h.estimate(shape(hour), 3_599_000).hitBlock, 0);
  assert.equal(h.estimate(shape(hour), 3_599_000 + 3_600_001).hitBlock, null);
});

test("the lookback finds an earlier write only within 20 blocks (Anthropic's growing-conversation example)", () => {
  const m = memory();
  m.estimate(shape(conversation(10)), 0);
  const turn2 = m.estimate(shape(conversation(15)), 10_000);
  assert.equal(turn2.hitBlock, 9, "turn 2 reads the prefix turn 1 wrote at block 10");
  assert.equal(turn2.read, shape(conversation(15)).blocks[9].cumulativeChars);
  assert.equal(m.estimate(shape(conversation(35)), 20_000).hitBlock, null, "turn 3: block 15 is outside blocks 35 to 16");
  const n = memory();
  n.estimate(shape(conversation(10)), 0);
  n.estimate(shape(conversation(15)), 10_000);
  assert.equal(n.estimate(shape(conversation(35, 15)), 20_000).hitBlock, 14, "a second breakpoint at block 15 finds it");
});

test("mixed TTLs are billed at Anthropic's positions A, B and C", () => {
  const body = { model: "m", messages: [{ role: "user", content: [text("a".repeat(100), "1h"), text("b".repeat(50)), text("c".repeat(30), "5m")] }] };
  const m = memory();
  assert.deepEqual(m.estimate(shape(body), 0), { read: 0, write1h: 100, write5m: 80, hitBlock: null, measured: true });
  assert.deepEqual(m.estimate(shape(body), 1_000), { read: 180, write1h: 0, write5m: 0, hitBlock: 2, measured: true });
  const later = memory();
  later.estimate(shape(body), 0);
  assert.deepEqual(later.estimate(shape(body), 301_000), { read: 100, write1h: 0, write5m: 80, hitBlock: 0, measured: true }, "the 5-minute entry expired, the 1-hour one did not");
});

test("a prefix below the model's minimum is neither written nor read", () => {
  const m = memory(MIN);
  const body = conversation(3);
  assert.deepEqual(m.estimate(shape(body), 0), { read: 0, write5m: 0, write1h: 0, hitBlock: null, measured: true });
  assert.deepEqual(m.estimate(shape(body), 1_000), { read: 0, write5m: 0, write1h: 0, hitBlock: null, measured: true });
  assert.equal(m.size, 0);
});

test("changing tool_choice invalidates the messages part only", () => {
  const base = { model: "m", system: [text("s".repeat(200), "5m")], messages: [{ role: "user", content: [text("u".repeat(50), "5m")] }] };
  const m = memory();
  m.estimate(shape(base), 0);
  const changed = m.estimate(shape({ ...base, tool_choice: { type: "any" } }), 1_000);
  assert.deepEqual(changed, { read: 200, write5m: 50, write1h: 0, hitBlock: 0, measured: true });
});

test("the same text under another role or another model is another prefix", () => {
  const body = (role: string, model = "m") => ({ model, messages: [{ role, content: [text("same text", "5m")] }] });
  const m = memory();
  m.estimate(shape(body("user")), 0);
  assert.equal(m.estimate(shape(body("assistant")), 1_000).hitBlock, null);
  assert.equal(m.estimate(shape(body("user", "other")), 2_000).hitBlock, null);
  assert.equal(m.estimate(shape(body("user")), 3_000).hitBlock, 0);
});

test("estimates use the given characters per token, and options are checked", () => {
  const m = new PrefixMemory({ charsPerToken: 4, minCacheableTokens: 0 });
  const body = { model: "m", messages: [{ role: "user", content: [text("x".repeat(1_000), "5m")] }] };
  assert.equal(m.estimate(shape(body), 0).write5m, 250);
  assert.throws(() => new PrefixMemory({ charsPerToken: 0, minCacheableTokens: 0 }), /charsPerToken/);
  assert.throws(() => new PrefixMemory({ charsPerToken: 4, minCacheableTokens: -1 }), /minCacheableTokens/);
  assert.throws(() => new PrefixMemory({ charsPerToken: 4, minCacheableTokens: 0, lookback: 0 }), /lookback/);
  assert.throws(() => m.estimate(shape(body), Number.NaN), /startMs/);
});

// WP-GW's recorded calls (2026-10-12): synthetic prompts, recorded counts.
interface RecordedCall {
  label: string;
  atUtc: string;
  system: "cached" | "plain";
  prefix: string;
  usage: { input: number; cacheWrite5m: number; cacheWrite1h: number; cacheRead: number; output: number };
}
const recorded = JSON.parse(readFileSync(new URL(RECORDED_FILE, FIXTURE_DIR), "utf8")) as {
  model: string;
  minCacheableTokens: number;
  prefix: { lines: number; template: string; saltLength: number };
  userMessage: string;
  calls: RecordedCall[];
};

function rebuild(call: RecordedCall): Body {
  const salt = call.prefix.repeat(recorded.prefix.saltLength).slice(0, recorded.prefix.saltLength);
  const lines = Array.from({ length: recorded.prefix.lines }, (_, i) => recorded.prefix.template.replace("{n}", String(i + 1)).replace("{salt}", salt));
  const system = call.system === "cached" ? [{ type: "text", text: lines.join("\n"), cache_control: { type: "ephemeral" } }] : lines.join("\n");
  return { model: recorded.model, max_tokens: 16, system, messages: [{ role: "user", content: recorded.userMessage }] };
}
const totalInput = (c: RecordedCall) => c.usage.input + c.usage.cacheWrite5m + c.usage.cacheWrite1h + c.usage.cacheRead;
const category = (e: CacheEstimate) => (e.write5m + e.write1h > 0 ? "write" : e.read > 0 ? "read" : "none");
const recordedCategory = (c: RecordedCall) => (c.usage.cacheWrite5m + c.usage.cacheWrite1h > 0 ? "write" : c.usage.cacheRead > 0 ? "read" : "none");

test("recorded U-A to U-D: the prefix memory puts each call in its recorded category, write or read", () => {
  const calls = recorded.calls.filter((c) => c.system === "cached");
  assert.deepEqual(calls.map((c) => c.label), ["U-A", "U-B", "U-C", "U-D"]);
  const prefixChars = readPromptShape(rebuild(calls[0])).blocks[0].cumulativeChars;
  const m = new PrefixMemory({ charsPerToken: prefixChars / calls[0].usage.cacheWrite5m, minCacheableTokens: recorded.minCacheableTokens });
  for (const call of calls) {
    assert.equal(category(m.estimate(readPromptShape(rebuild(call)), Date.parse(call.atUtc))), recordedCategory(call), call.label);
  }
});

test("recorded calls: prompts of equal length were 5,903 to 6,663 input tokens, so a size-based estimate errs by at least 6%", () => {
  const sizes = new Set(recorded.calls.map((c) => readPromptShape(rebuild(c)).totalChars));
  assert.equal(sizes.size, 1, "the run's nine prompts had the same length: every salt was 12 characters");
  const totals = recorded.calls.map(totalInput);
  const low = Math.min(...totals);
  const high = Math.max(...totals);
  assert.deepEqual([low, high], [5903, 6663]);
  // The single estimate with the smallest worst-case relative error is the harmonic mean of the extremes.
  const best = 2 / (1 / low + 1 / high);
  const worstError = (best - low) / low;
  assert.ok(worstError > 0.06 && worstError < 0.061, `best worst-case error ${(worstError * 100).toFixed(2)}%`);
});

test("recorded U-A and U-D: calibrated on U-A, the estimate gives U-D's write as 5,890 tokens; the response said 6,650", () => {
  const [ua, , , ud] = recorded.calls;
  const prefixChars = readPromptShape(rebuild(ua)).blocks[0].cumulativeChars;
  const m = new PrefixMemory({ charsPerToken: prefixChars / ua.usage.cacheWrite5m, minCacheableTokens: recorded.minCacheableTokens });
  assert.deepEqual(m.estimate(readPromptShape(rebuild(ua)), Date.parse(ua.atUtc)), { read: 0, write5m: 5890, write1h: 0, hitBlock: null, measured: true });
  const estimate = m.estimate(readPromptShape(rebuild(ud)), Date.parse(ud.atUtc));
  assert.deepEqual(estimate, { read: 0, write5m: 5890, write1h: 0, hitBlock: null, measured: true });
  const error = (estimate.write5m - ud.usage.cacheWrite5m) / ud.usage.cacheWrite5m;
  assert.ok(error < -0.114 && error > -0.115, `U-D under-estimated by ${(error * 100).toFixed(1)}%`);
});

test("a prefix with a block no character count can measure is flagged, not reported as no caching", () => {
  const pdf = { type: "document", source: { type: "base64", media_type: "application/pdf", data: "QUJD".repeat(100_000) } };
  const body = { model: "m", messages: [{ role: "user", content: [{ ...pdf, cache_control: { type: "ephemeral" } }, text("question")] }] };
  const s = shape(body);
  assert.equal(s.unmeasuredBlocks, 1);
  const estimate = memory(1_024).estimate(s, 0);
  assert.equal(estimate.measured, false, "the zeros are a lower bound, not a measurement");
  assert.equal(memory(0).estimate(shape(conversation(2)), 0).measured, true);
});

test("the recorded fixture is referenced with its exact case (Linux file names are case-sensitive)", () => {
  assert.ok(readdirSync(FIXTURE_DIR).includes(RECORDED_FILE));
});
