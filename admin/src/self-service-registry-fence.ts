import { randomUUID } from "node:crypto";
import { ApiError } from "./auth.ts";
import type { JobStore } from "./self-service-jobs.ts";

export interface RegistryVersion { backendId: string; etag: string }
type Verification<T> = { state: "busy" | "changed" } | { state: "verified"; value: T };
export interface RegistryFence {
  write<T>(backendId: string, run: () => Promise<T>): Promise<T>;
  verify<T>(versions: RegistryVersion[], run: () => Promise<T>): Promise<Verification<T>>;
}

export function createRegistryFence(deps: {
  leases: Pick<JobStore, "lock" | "unlock">;
  readEtag(backendId: string): Promise<string | null>;
  now(): Date;
  log?(line: string): void;
}): RegistryFence {
  const key = (backendId: string) => `registry:${backendId}`;
  const acquire = (backendId: string, owner: string) => {
    const now = deps.now();
    return deps.leases.lock(key(backendId), owner, now.toISOString(), new Date(+now + 5 * 60_000).toISOString());
  };
  const release = async (backendId: string, owner: string) => {
    try { await deps.leases.unlock(key(backendId), owner); }
    catch {
      (deps.log ?? console.warn)(JSON.stringify({ code: "registry_lease_release_failed", backendId }));
    }
  };
  return {
    async write(backendId, run) {
      const owner = randomUUID();
      if (!await acquire(backendId, owner)) throw new ApiError(409, "registry_publication_in_progress");
      try { return await run(); } finally { await release(backendId, owner); }
    },
    async verify(versions, run) {
      const owner = randomUUID();
      const acquired: string[] = [];
      const ordered = [...versions].sort((a, b) => a.backendId.localeCompare(b.backendId));
      if (new Set(ordered.map((entry) => entry.backendId)).size !== ordered.length || ordered.some((entry) => !entry.etag)) return { state: "changed" };
      try {
        for (const entry of ordered) {
          if (!await acquire(entry.backendId, owner)) return { state: "busy" };
          acquired.push(entry.backendId);
        }
        for (const entry of ordered) {
          if (await deps.readEtag(entry.backendId) !== entry.etag) return { state: "changed" };
        }
        return { state: "verified", value: await run() };
      } finally {
        await Promise.all(acquired.map((backendId) => release(backendId, owner)));
      }
    },
  };
}
