// Reads the token usage of an Anthropic Messages stream as it passes, and keeps nothing else
// (ADR-0022, O10). Offline prototype: no gateway, ledger or deployed app uses it.
//
// Sources (retrieved 2026-10-12):
// - WHATWG HTML, "Server-sent events", event stream interpretation: lines end in CRLF, LF or CR; a
//   line starting with ":" is a comment; "field: value" drops one leading space; data lines join
//   with "\n"; a blank line dispatches the event; an event without data is not dispatched.
// - Anthropic "Streaming messages": message_start holds a Message with empty content and its
//   usage; one or more message_delta events follow, whose usage counts are cumulative; then
//   message_stop. ping and error events occur, and unknown event types must be tolerated. Each
//   event's data carries the matching "type".
// - Anthropic "Prompt caching": usage has input_tokens (after the last breakpoint),
//   cache_creation_input_tokens, cache_read_input_tokens and output_tokens, and cache_creation
//   with ephemeral_5m_input_tokens and ephemeral_1h_input_tokens, whose sum equals
//   cache_creation_input_tokens.
//
// Rules, as in analytics/ledger.kql: a count is a non-negative whole number or unknown (null),
// never coerced and never inferred as zero. The reader's own rule for the TTL split: it is used only
// when both of its fields and cache_creation_input_tokens are valid counts and the split adds up to
// that aggregate; otherwise both cache-write counts are unknown. Response text is never kept: data of
// content, ping and unknown events is dropped as it arrives, and a usage-bearing event larger than
// maxEventChars is dropped.
// Anthropic sends each event line before its data; data that arrives before its event line is held
// only up to maxEventChars.

import type { TokenCategory } from "../cost/token-categories.ts";

export type StreamOutcome = "complete" | "error" | "incomplete";

export interface StreamUsageOptions {
  // Largest usage-bearing event kept, in characters (default 65,536).
  maxEventChars?: number;
}

export interface StreamUsage {
  // complete: message_stop seen; error: an error event; incomplete: the stream ended earlier.
  outcome: StreamOutcome;
  // complete, and no anomaly and no dropped usage event. Other counts are lower bounds at best.
  final: boolean;
  // The five categories as the stream last reported them; null when not reported or invalid.
  tokens: Record<TokenCategory, number | null>;
  cacheCreationTotal: number | null;
  // The TTL split and cache_creation_input_tokens are both valid counts and do not add up. False
  // when either is unknown: there is nothing to compare, and the cache-write counts are unknown.
  ttlSplitMismatch: boolean;
  events: number;
  skippedEvents: number;
  oversizedEvents: number;
  anomalies: number;
  maxRetainedChars: number;
}

export interface StreamUsageReader {
  push(chunk: Uint8Array | string): void;
  end(): StreamUsage;
}

const USAGE_EVENTS = new Set(["message_start", "message_delta", "message_stop", "error"]);
const DEFAULT_MAX_EVENT_CHARS = 65_536;
const LF = 10;
const CR = 13;

type Count = number | null;
interface Reported {
  input?: Count;
  output?: Count;
  cacheRead?: Count;
  cacheCreation?: Count;
  ttl5m?: Count;
  ttl1h?: Count;
}

export function createStreamUsageReader(options: StreamUsageOptions = {}): StreamUsageReader {
  const cap = options.maxEventChars ?? DEFAULT_MAX_EVENT_CHARS;
  if (!Number.isSafeInteger(cap) || cap < 1) throw new RangeError("maxEventChars must be a whole number of at least 1");

  const decoder = new TextDecoder("utf-8");
  let ended = false;
  let afterCR = false;
  // The current line: kept only until it is known to be a data line of a skipped event.
  let line = "";
  let lineDropped = false;
  let lineTooLong = false;
  // The current event.
  let eventType = "";
  let data = "";
  let hasData = false;
  let eventTooLong = false;

  const reported: Reported = {};
  let starts = 0;
  let stopped = false;
  let errored = false;
  let poisoned = false;
  const stats = { events: 0, skippedEvents: 0, oversizedEvents: 0, anomalies: 0, maxRetainedChars: 0 };

  const skipping = () => eventType !== "" && !USAGE_EVENTS.has(eventType);
  const retain = () => {
    stats.maxRetainedChars = Math.max(stats.maxRetainedChars, line.length + data.length);
  };

  function appendToLine(text: string, from: number, to: number): void {
    if (lineDropped || from >= to) return;
    // A data line of a content, ping or unknown event is dropped once its field name is read.
    if (skipping() && line.length < 5) {
      const take = Math.min(5 - line.length, to - from);
      line += text.slice(from, from + take);
      from += take;
      if (line === "data:") {
        line = "";
        lineDropped = true;
        hasData = true;
        return;
      }
    }
    const room = cap - line.length;
    if (to - from > room) {
      line += text.slice(from, from + room);
      lineTooLong = true;
      lineDropped = true;
    } else {
      line += text.slice(from, to);
    }
    retain();
  }

  function endLine(): void {
    const text = line;
    const dropped = lineDropped;
    const tooLong = lineTooLong;
    line = "";
    lineDropped = false;
    lineTooLong = false;
    if (dropped && !tooLong) return; // a skipped event's data line
    if (text === "" && !dropped) return dispatch();
    // A comment (":...") has an empty field name and, like any other unknown field, is ignored.
    const colon = text.indexOf(":");
    const field = colon < 0 ? text : text.slice(0, colon);
    let value = colon < 0 ? "" : text.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") {
      eventType = tooLong ? "\u0000oversized" : value;
    } else if (field === "data") {
      hasData = true;
      if (tooLong || eventTooLong || data.length + value.length + 1 > cap) {
        eventTooLong = true;
        data = "";
      } else {
        data += value + "\n";
      }
    }
    retain();
  }

  function dispatch(): void {
    const type = eventType === "" ? "message" : eventType;
    const body = data.endsWith("\n") ? data.slice(0, -1) : data;
    const tooLong = eventTooLong;
    const had = hasData;
    eventType = "";
    data = "";
    hasData = false;
    eventTooLong = false;
    if (!had) return;
    stats.events++;
    if (!USAGE_EVENTS.has(type)) {
      stats.skippedEvents++;
      return;
    }
    if (tooLong) {
      stats.oversizedEvents++;
      return;
    }
    if (stopped) {
      stats.anomalies++;
      return;
    }
    let payload: unknown;
    try {
      payload = JSON.parse(body);
    } catch {
      stats.anomalies++;
      return;
    }
    if (!isObject(payload) || payload.type !== type) {
      stats.anomalies++;
      return;
    }
    if (type === "message_start") {
      starts++;
      if (starts > 1) poisoned = true;
      const message = payload.message;
      if (isObject(message) && "usage" in message) applyUsage(message.usage);
    } else if (type === "message_delta") {
      if ("usage" in payload) applyUsage(payload.usage);
    } else if (type === "message_stop") {
      stopped = true;
    } else {
      errored = true;
    }
  }

  function applyUsage(usage: unknown): void {
    if (!isObject(usage)) {
      stats.anomalies++;
      return;
    }
    // A field that is absent or null is not reported: the earlier value stays, as Anthropic's SDK
    // accumulates a stream. Any other invalid value makes the count unknown.
    const update = (value: unknown, previous: Count | undefined): Count | undefined =>
      value === undefined || value === null ? previous : readCount(value);
    reported.input = update(usage.input_tokens, reported.input);
    reported.output = update(usage.output_tokens, reported.output);
    reported.cacheRead = update(usage.cache_read_input_tokens, reported.cacheRead);
    reported.cacheCreation = update(usage.cache_creation_input_tokens, reported.cacheCreation);
    const split = usage.cache_creation;
    if (isObject(split)) {
      reported.ttl5m = update(split.ephemeral_5m_input_tokens, reported.ttl5m);
      reported.ttl1h = update(split.ephemeral_1h_input_tokens, reported.ttl1h);
    } else if (split !== undefined && split !== null) {
      reported.ttl5m = null;
      reported.ttl1h = null;
    }
  }

  function feed(text: string): void {
    let i = 0;
    if (afterCR && text.length > 0) {
      afterCR = false;
      if (text.charCodeAt(0) === LF) i = 1;
    }
    while (i < text.length) {
      let j = i;
      while (j < text.length) {
        const c = text.charCodeAt(j);
        if (c === LF || c === CR) break;
        j++;
      }
      appendToLine(text, i, j);
      if (j >= text.length) return;
      endLine();
      if (text.charCodeAt(j) === CR) {
        if (j + 1 < text.length) {
          if (text.charCodeAt(j + 1) === LF) j++;
        } else {
          afterCR = true;
        }
      }
      i = j + 1;
    }
  }

  return {
    push(chunk) {
      if (ended) throw new Error("the reader has ended");
      feed(typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true }));
    },
    end() {
      if (ended) throw new Error("the reader has ended");
      ended = true;
      feed(decoder.decode());
      return summarise(reported, { stopped, errored, poisoned }, stats);
    },
  };
}

export function readStreamUsage(text: string | Uint8Array, options?: StreamUsageOptions): StreamUsage {
  const reader = createStreamUsageReader(options);
  reader.push(text);
  return reader.end();
}

function summarise(
  r: Reported,
  state: { stopped: boolean; errored: boolean; poisoned: boolean },
  stats: Omit<StreamUsage, "outcome" | "final" | "tokens" | "cacheCreationTotal" | "ttlSplitMismatch">,
): StreamUsage {
  const known = (value: Count | undefined): Count => (state.poisoned || value === undefined ? null : value);
  const total = known(r.cacheCreation);
  const ttl5m = known(r.ttl5m);
  const ttl1h = known(r.ttl1h);
  const splitKnown = ttl5m !== null && ttl1h !== null && total !== null;
  const mismatch = splitKnown && ttl5m + ttl1h !== total;
  const splitUsed = splitKnown && !mismatch;
  const outcome: StreamOutcome = state.errored ? "error" : state.stopped ? "complete" : "incomplete";
  return {
    outcome,
    final: outcome === "complete" && !state.poisoned && stats.anomalies === 0 && stats.oversizedEvents === 0,
    tokens: {
      input: known(r.input),
      cacheWrite5m: splitUsed ? ttl5m : null,
      cacheWrite1h: splitUsed ? ttl1h : null,
      cacheRead: known(r.cacheRead),
      output: known(r.output),
    },
    cacheCreationTotal: total,
    ttlSplitMismatch: mismatch,
    ...stats,
  };
}

function readCount(value: unknown): Count {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
