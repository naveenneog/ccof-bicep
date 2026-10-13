// A request-side estimate of prompt-cache usage (ADR-0022 option D, O10). Offline prototype: no
// gateway, ledger or deployed app uses it. It answers one question for the owner: how close can the
// gateway get to a streamed call's cache counts from the request alone?
//
// The model follows Anthropic "Prompt caching" (retrieved 2026-10-12):
// - Prefixes run tools, system, messages in that order, up to and including a block with
//   cache_control; a top-level cache_control applies to the last eligible block (automatic caching).
// - At most 4 breakpoints; a 1-hour entry must come before any 5-minute entry.
// - A write happens only at a breakpoint and stores one entry for the prefix ending there. A read
//   looks back at most 20 block positions from each breakpoint for an entry an earlier request wrote.
// - A use refreshes the entry; the lifetime counts from the start of the request.
// - Billing with mixed TTLs: A = tokens at the highest hit, B = at the highest 1-hour breakpoint after
//   A, C = at the last breakpoint; read A, 1-hour write B - A, 5-minute write C - B.
// - Prefixes shorter than the model's minimum are not cached.
// - Changing tool_choice, thinking or effort invalidates the messages part (here: they seed the keys
//   of message blocks only; the model seeds every key).
// Tokens are estimated from characters with a caller-supplied ratio; Claude's tokenizer is not public.

import { createHash } from "node:crypto";

export type CacheTtl = "5m" | "1h";
export type PromptSection = "tools" | "system" | "messages";

export interface PromptBlock {
  section: PromptSection;
  chars: number;
  cumulativeChars: number;
  // Hash of the whole prefix ending at this block, without any cache_control.
  key: string;
  ttl: CacheTtl | null;
  eligible: boolean;
  // False for images, documents and other blocks whose size in tokens no character count gives.
  measured: boolean;
}

export interface PromptShape {
  blocks: PromptBlock[];
  breakpoints: number[];
  totalChars: number;
  // Images, documents and other blocks whose size in tokens no character count can give.
  unmeasuredBlocks: number;
}

export interface CacheEstimate {
  read: number;
  write5m: number;
  write1h: number;
  hitBlock: number | null;
  // False when a block up to the last breakpoint could not be measured: the counts are then a lower
  // bound, and a breakpoint may have been ignored as too short.
  measured: boolean;
}

export interface PrefixMemoryOptions {
  charsPerToken: number;
  minCacheableTokens: number;
  lookback?: number;
}

export type PromptShapeErrorCode =
  | "invalid_body"
  | "invalid_value"
  | "invalid_cache_control"
  | "too_many_breakpoints"
  | "ttl_order"
  | "conflicting_ttl";

export class PromptShapeError extends Error {
  readonly code: PromptShapeErrorCode;
  readonly field: string;
  constructor(code: PromptShapeErrorCode, field: string, message: string) {
    super(`${field}: ${message}`);
    this.name = "PromptShapeError";
    this.code = code;
    this.field = field;
  }
}

const MAX_BREAKPOINTS = 4;
const TTL_MS: Record<CacheTtl, number> = { "5m": 300_000, "1h": 3_600_000 };
const NOT_ELIGIBLE = new Set(["thinking", "redacted_thinking"]);

interface RawBlock {
  section: PromptSection;
  field: string;
  value: Record<string, unknown>;
  role: string | null;
}

export function readPromptShape(body: unknown): PromptShape {
  if (!isObject(body)) throw new PromptShapeError("invalid_body", "(body)", "must be a JSON object");
  const raw = collectBlocks(body);
  const model = typeof body.model === "string" ? body.model : "";
  const messageSeed = JSON.stringify([body.tool_choice ?? null, body.thinking ?? null, body.output_config ?? null, body.speed ?? null]);
  const blocks: PromptBlock[] = [];
  const breakpoints: number[] = [];
  let previousKey = "";
  let cumulativeChars = 0;
  let unmeasuredBlocks = 0;
  for (const [index, block] of raw.entries()) {
    const ttl = readCacheControl(block.value.cache_control, `${block.field}.cache_control`);
    if (ttl !== null) breakpoints.push(index);
    const { cache_control: _ignored, ...content } = block.value;
    const size = measure(block.section, content);
    if (size === null) unmeasuredBlocks++;
    cumulativeChars += size ?? 0;
    const seed = block.section === "messages" ? `${model}\u0000${messageSeed}` : model;
    const key = sha256(`${previousKey}\u0000${seed}\u0000${block.role ?? ""}\u0000${JSON.stringify(content)}`);
    previousKey = key;
    blocks.push({ section: block.section, chars: size ?? 0, cumulativeChars, key, ttl, eligible: isEligible(block.section, content), measured: size !== null });
  }
  if (breakpoints.length > MAX_BREAKPOINTS) {
    throw new PromptShapeError("too_many_breakpoints", `${raw[breakpoints[MAX_BREAKPOINTS]].field}.cache_control`, `at most ${MAX_BREAKPOINTS} cache breakpoints`);
  }
  applyAutomatic(body, raw, blocks, breakpoints);
  checkTtlOrder(raw, blocks, breakpoints);
  return { blocks, breakpoints, totalChars: cumulativeChars, unmeasuredBlocks };
}

export class PrefixMemory {
  private readonly charsPerToken: number;
  private readonly minCacheableTokens: number;
  private readonly lookback: number;
  private readonly entries = new Map<string, { ttl: CacheTtl; expiresAt: number }>();

  constructor(options: PrefixMemoryOptions) {
    if (!(Number.isFinite(options.charsPerToken) && options.charsPerToken > 0)) throw new RangeError("charsPerToken must be a positive number");
    if (!(Number.isSafeInteger(options.minCacheableTokens) && options.minCacheableTokens >= 0)) {
      throw new RangeError("minCacheableTokens must be a whole number of at least 0");
    }
    const lookback = options.lookback ?? 20;
    if (!(Number.isSafeInteger(lookback) && lookback >= 1)) throw new RangeError("lookback must be a whole number of at least 1");
    this.charsPerToken = options.charsPerToken;
    this.minCacheableTokens = options.minCacheableTokens;
    this.lookback = lookback;
  }

  get size(): number {
    return this.entries.size;
  }

  // Estimates one request that starts at startMs, then records what it read and wrote.
  estimate(shape: PromptShape, startMs: number): CacheEstimate {
    if (!Number.isFinite(startMs)) throw new RangeError("startMs must be a finite number of milliseconds");
    for (const [key, entry] of this.entries) if (entry.expiresAt <= startMs) this.entries.delete(key);
    const tokensAt = (position: number) => Math.round(shape.blocks[position].cumulativeChars / this.charsPerToken);
    const breakpoints = shape.breakpoints.filter((position) => tokensAt(position) >= this.minCacheableTokens);
    let hit: number | null = null;
    for (const breakpoint of breakpoints) {
      for (let position = breakpoint; position >= 0 && position > breakpoint - this.lookback; position--) {
        if (this.entries.has(shape.blocks[position].key)) {
          if (hit === null || position > hit) hit = position;
          break;
        }
      }
    }
    const a = hit === null ? 0 : tokensAt(hit);
    const after = breakpoints.filter((position) => hit === null || position > hit);
    const oneHour = after.filter((position) => shape.blocks[position].ttl === "1h");
    const b = oneHour.length > 0 ? tokensAt(oneHour[oneHour.length - 1]) : a;
    const c = after.length > 0 ? tokensAt(after[after.length - 1]) : a;
    if (hit !== null) this.keep(shape.blocks[hit].key, this.entries.get(shape.blocks[hit].key)!.ttl, startMs);
    for (const position of breakpoints) this.keep(shape.blocks[position].key, shape.blocks[position].ttl!, startMs);
    const last = shape.breakpoints.length > 0 ? shape.breakpoints[shape.breakpoints.length - 1] : -1;
    const measured = shape.blocks.slice(0, last + 1).every((block) => block.measured);
    return { read: a, write1h: Math.max(0, b - a), write5m: Math.max(0, c - Math.max(a, b)), hitBlock: hit, measured };
  }

  private keep(key: string, ttl: CacheTtl, startMs: number): void {
    const expiresAt = startMs + TTL_MS[ttl];
    const existing = this.entries.get(key);
    if (existing === undefined || existing.expiresAt < expiresAt) this.entries.set(key, { ttl, expiresAt });
  }
}

function collectBlocks(body: Record<string, unknown>): RawBlock[] {
  const blocks: RawBlock[] = [];
  if (body.tools !== undefined) {
    if (!Array.isArray(body.tools)) throw new PromptShapeError("invalid_value", "tools", "must be an array");
    body.tools.forEach((tool, i) => blocks.push({ section: "tools", field: `tools[${i}]`, value: object(tool, `tools[${i}]`), role: null }));
  }
  if (typeof body.system === "string") {
    blocks.push({ section: "system", field: "system", value: { type: "text", text: body.system }, role: null });
  } else if (body.system !== undefined) {
    if (!Array.isArray(body.system)) throw new PromptShapeError("invalid_value", "system", "must be a string or an array of blocks");
    body.system.forEach((block, i) => blocks.push({ section: "system", field: `system[${i}]`, value: typed(block, `system[${i}]`), role: null }));
  }
  if (!Array.isArray(body.messages)) throw new PromptShapeError("invalid_value", "messages", "must be an array");
  body.messages.forEach((message, m) => {
    const value = object(message, `messages[${m}]`);
    if (typeof value.role !== "string") throw new PromptShapeError("invalid_value", `messages[${m}].role`, "must be a string");
    const role = value.role;
    if (typeof value.content === "string") {
      blocks.push({ section: "messages", field: `messages[${m}].content`, value: { type: "text", text: value.content }, role });
    } else if (Array.isArray(value.content)) {
      value.content.forEach((block, i) => blocks.push({ section: "messages", field: `messages[${m}].content[${i}]`, value: typed(block, `messages[${m}].content[${i}]`), role }));
    } else {
      throw new PromptShapeError("invalid_value", `messages[${m}].content`, "must be a string or an array of blocks");
    }
  });
  return blocks;
}

function applyAutomatic(body: Record<string, unknown>, raw: RawBlock[], blocks: PromptBlock[], breakpoints: number[]): void {
  const ttl = readCacheControl(body.cache_control, "cache_control");
  if (ttl === null) return;
  let target = blocks.length - 1;
  while (target >= 0 && !blocks[target].eligible) target--;
  if (target < 0) return;
  if (blocks[target].ttl !== null) {
    if (blocks[target].ttl !== ttl) throw new PromptShapeError("conflicting_ttl", "cache_control", `differs from the TTL on ${raw[target].field}`);
    return;
  }
  if (breakpoints.length >= MAX_BREAKPOINTS) throw new PromptShapeError("too_many_breakpoints", "cache_control", `no breakpoint slot left for automatic caching`);
  blocks[target].ttl = ttl;
  breakpoints.push(target);
  breakpoints.sort((x, y) => x - y);
}

function checkTtlOrder(raw: RawBlock[], blocks: PromptBlock[], breakpoints: number[]): void {
  let seenFiveMinutes = false;
  for (const position of breakpoints) {
    if (blocks[position].ttl === "5m") seenFiveMinutes = true;
    else if (seenFiveMinutes) throw new PromptShapeError("ttl_order", `${raw[position].field}.cache_control`, "a 1-hour breakpoint must come before any 5-minute one");
  }
}

function readCacheControl(value: unknown, field: string): CacheTtl | null {
  if (value === undefined || value === null) return null;
  if (!isObject(value) || value.type !== "ephemeral") throw new PromptShapeError("invalid_cache_control", field, 'must be {"type": "ephemeral"}');
  if (value.ttl === undefined) return "5m";
  if (value.ttl === "5m" || value.ttl === "1h") return value.ttl;
  throw new PromptShapeError("invalid_cache_control", field, 'ttl must be "5m" or "1h"');
}

// Characters that carry text into the prompt; null for blocks no character count measures.
function measure(section: PromptSection, block: Record<string, unknown>): number | null {
  if (section === "tools") return JSON.stringify(block).length;
  switch (block.type) {
    case "text":
      return typeof block.text === "string" ? block.text.length : null;
    case "thinking":
      return typeof block.thinking === "string" ? block.thinking.length : null;
    case "tool_use":
      return (typeof block.name === "string" ? block.name.length : 0) + JSON.stringify(block.input ?? {}).length;
    case "tool_result":
      return measureToolResult(block.content);
    default:
      return null;
  }
}

function measureToolResult(content: unknown): number | null {
  if (typeof content === "string") return content.length;
  if (!Array.isArray(content)) return content === undefined ? 0 : null;
  let total = 0;
  for (const item of content) {
    if (!isObject(item) || item.type !== "text" || typeof item.text !== "string") return null;
    total += item.text.length;
  }
  return total;
}

function isEligible(section: PromptSection, block: Record<string, unknown>): boolean {
  if (section === "tools") return true;
  if (typeof block.type === "string" && NOT_ELIGIBLE.has(block.type)) return false;
  return !(block.type === "text" && block.text === "");
}

function object(value: unknown, field: string): Record<string, unknown> {
  if (!isObject(value)) throw new PromptShapeError("invalid_value", field, "must be an object");
  return value;
}

function typed(value: unknown, field: string): Record<string, unknown> {
  const block = object(value, field);
  if (typeof block.type !== "string") throw new PromptShapeError("invalid_value", `${field}.type`, "must be a string");
  return block;
}

function sha256(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
