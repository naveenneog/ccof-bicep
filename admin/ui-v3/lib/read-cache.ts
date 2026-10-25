// Per-page, bounded memory only. Never persistent, never stores tokens, failures or write results.
export class ReadCache<T> {
  private entries = new Map<string, { expires: number; value: T }>();
  generation = 0;
  private maxEntries: number;
  constructor(maxEntries = 100) { this.maxEntries = maxEntries; }
  get(key: string, now = Date.now()): T | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (entry.expires <= now) { this.entries.delete(key); return undefined; }
    return entry.value;
  }
  put(key: string, value: T, ttl: number, generation: number, now = Date.now()) {
    if (generation !== this.generation || ttl <= 0) return;
    this.entries.delete(key);
    while (this.entries.size >= this.maxEntries) this.entries.delete(this.entries.keys().next().value!);
    this.entries.set(key, { value, expires: now + ttl });
  }
  clear() { this.entries.clear(); this.generation++; }
}

export function readTtl(path: string): number {
  if (/^\/api\/v2\/health(?:\?|$)/.test(path)) return 10_000;
  if (/^\/api\/projects\//.test(path)) return 15_000;
  if (/^\/api\/v[23]\//.test(path)) return /\/(?:inventory|chargeback|reconciler|plan)(?:[/?]|$)/.test(path) ? 60_000 : 30_000;
  return 0;
}
