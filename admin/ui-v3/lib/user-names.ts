import type { DirectoryResult, DirectoryUser } from "../../src/user-directory.ts";
import { ReadCache } from "./read-cache.ts";

export type UserLabel = Omit<DirectoryUser, "state"> & {
  state: DirectoryUser["state"] | "disabled";
  reason?: string;
};
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const fallback = (objectId: string, state: UserLabel["state"], reason?: string): UserLabel =>
  ({ objectId, state, displayName: null, userPrincipalName: null, reason });

// CSV export: keeps the object ID column and adds the current directory labels after it.
// nameLookup records why a name is empty (disabled, permission_required, not_found, unavailable).
export async function withUserNames(columns: string[], rows: Record<string, unknown>[], idColumn: string,
  get: (id: string) => Promise<UserLabel>): Promise<{ columns: string[]; rows: Record<string, unknown>[] }> {
  const at = columns.indexOf(idColumn);
  if (at < 0) return { columns, rows };
  const ids = [...new Set(rows.map((r) => r[idColumn]).filter((v): v is string => typeof v === "string" && v.length > 0))];
  const labels = new Map(await Promise.all(ids.map(async (id) => [id, await get(id)] as const)));
  const next = [...columns.slice(0, at + 1), "displayName", "userPrincipalName", "nameLookup", ...columns.slice(at + 1)];
  return { columns: next, rows: rows.map((r) => {
    const label = typeof r[idColumn] === "string" ? labels.get(r[idColumn] as string) : undefined;
    return { ...r, displayName: label?.displayName ?? null, userPrincipalName: label?.userPrincipalName ?? null, nameLookup: label?.state ?? "no_id" };
  }) };
}

// One instance per signed-in console. Only visible IDs are requested; no directory enumeration.
export class UserNames {
  private cache = new ReadCache<UserLabel>(1000);
  private pending = new Map<string, { promise: Promise<UserLabel>; resolve: (user: UserLabel) => void }>();
  private queue: string[] = [];
  private running = false;
  private lookup: (ids: string[], signal: AbortSignal) => Promise<DirectoryResult>;
  private now: () => number;
  private timeoutMs: number;
  constructor(lookup: (ids: string[], signal: AbortSignal) => Promise<DirectoryResult>, now = Date.now, timeoutMs = 20000) {
    this.lookup = lookup; this.now = now; this.timeoutMs = timeoutMs;
  }

  get(rawId: string): Promise<UserLabel> {
    const id = rawId.toLowerCase();
    if (!GUID.test(id)) return Promise.resolve(fallback(rawId, "not_found", "Not a user object ID"));
    const cached = this.cache.get(id, this.now());
    if (cached) return Promise.resolve(cached);
    const pending = this.pending.get(id);
    if (pending) return pending.promise;
    if (this.pending.size >= 1000) return Promise.resolve(fallback(id, "unavailable", "Too many pending user lookups"));
    let resolve!: (user: UserLabel) => void;
    const promise = new Promise<UserLabel>((done) => { resolve = done; });
    this.pending.set(id, { promise, resolve });
    this.queue.push(id);
    if (!this.running) { this.running = true; queueMicrotask(() => void this.flush()); }
    return promise;
  }

  private async flush() {
    while (this.queue.length) {
      const ids = this.queue.splice(0, 100);
      let results: UserLabel[];
      const controller = new AbortController();
      const started = this.now();
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        const deadline = new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => { controller.abort(); reject(new Error("User lookup timed out")); }, this.timeoutMs);
        });
        const cap = await Promise.race([this.lookup(ids, controller.signal), deadline]);
        const users = new Map((cap.data?.users ?? []).map((u) => [u.objectId.toLowerCase(), u]));
        const state = cap.state === "disabled" || cap.state === "permission_required" ? cap.state : "unavailable";
        const serverTime = Date.parse(cap.observedAt), received = this.now();
        results = ids.map((id) => {
          const user = users.get(id);
          if (!user) return fallback(id, state, cap.permission ?? cap.reason);
          // Translate server freshness, not server wall-clock timestamps, into the browser clock.
          // Deduct the entire round-trip duration so time in transit never extends freshness.
          const ttl = user.expiresAt !== undefined && Number.isFinite(serverTime)
            ? Math.max(0, Math.min(300000, user.expiresAt - serverTime) - Math.max(0, received - started)) : null;
          return { ...user, expiresAt: ttl === null ? undefined : received + ttl };
        });
      } catch (err) {
        results = ids.map((id) => fallback(id, "unavailable", err instanceof Error ? err.message : "User lookup failed"));
      } finally {
        clearTimeout(timer);
      }
      for (const user of results) {
        if (user.state === "resolved" || user.state === "not_found") {
          // A response may already be server-cached. Its original expiry must cross the browser
          // cache unchanged, rather than starting a second five-minute freshness window.
          const ttl = Math.max(0, Math.min(300000, (user.expiresAt ?? this.now()) - this.now()));
          this.cache.put(user.objectId, user, ttl, this.cache.generation, this.now());
        }
        this.pending.get(user.objectId)?.resolve(user);
        this.pending.delete(user.objectId);
      }
    }
    this.running = false;
  }
}
