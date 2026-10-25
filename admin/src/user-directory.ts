import type { TokenCredential } from "@azure/identity";
import { ApiError, isGuid } from "./auth.ts";
import { isObject } from "./validation.ts";
import { ProviderError } from "./operations.ts";

export interface DirectoryUser {
  objectId: string;
  displayName: string | null;
  userPrincipalName: string | null;
  state: "resolved" | "not_found" | "permission_required" | "unavailable";
  expiresAt?: number;
}
export interface DirectoryResult {
  state: "available" | "partial" | "disabled" | "permission_required" | "unavailable";
  observedAt: string;
  reason?: string;
  permission?: string;
  data?: { users: DirectoryUser[] };
}
export interface UserDirectory {
  lookup(ids: string[], log: (line: string) => void, refresh?: boolean): Promise<DirectoryResult>;
}
export const USER_LOOKUP_MAX = 100;
const PERMISSION = "Microsoft Graph User.Read.All application permission on the admin Function App managed identity, with tenant admin consent.";

export function readUserIds(body: unknown): string[] {
  if (!isObject(body) || Object.keys(body).length !== 1 || !Array.isArray(body.objectIds) ||
      body.objectIds.length < 1 || body.objectIds.length > USER_LOOKUP_MAX || body.objectIds.some((id) => !isGuid(id))) {
    throw new ApiError(400, "invalid_user_ids");
  }
  return [...new Set((body.objectIds as string[]).map((id) => id.toLowerCase()))];
}

const unresolved = (objectId: string, state: DirectoryUser["state"]): DirectoryUser =>
  ({ objectId, state, displayName: null, userPrincipalName: null });
const label = (value: unknown, max: number) => typeof value === "string" && value.trim() && value.length <= max ? value.trim() : null;

// Memory only: directory labels are never added to the registry, ledger, logs or HTTP caches.
export function createUserDirectory(
  env: Readonly<Record<string, string | undefined>>, credential: TokenCredential,
  transport: typeof fetch = fetch, now: () => number = Date.now, timeoutMs = 15000,
): UserDirectory {
  const cache = new Map<string, { user: DirectoryUser; expires: number }>();
  return {
    async lookup(rawIds, log, refresh = false) {
      const ids = readUserIds({ objectIds: rawIds });
      const observedAt = new Date(now()).toISOString();
      if (env.ADMIN_USER_NAMES_ENABLED !== "true") return {
        state: "disabled", observedAt, reason: "ADMIN_USER_NAMES_ENABLED_not_set", permission: PERMISSION,
      };
      const users = new Map<string, DirectoryUser>();
      const missing = ids.filter((id) => {
        const entry = cache.get(id);
        if (!refresh && entry && entry.expires > now()) { users.set(id, entry.user); return false; }
        cache.delete(id);
        return true;
      });
      if (missing.length) {
        const controller = new AbortController();
        let timer: ReturnType<typeof setTimeout> | undefined;
        try {
          const deadline = new Promise<never>((_resolve, reject) => {
            timer = setTimeout(() => {
              controller.abort();
              reject(new ProviderError(504, "directory_request_timeout"));
            }, timeoutMs);
          });
          const token = await Promise.race([credential.getToken("https://graph.microsoft.com/.default", { abortSignal: controller.signal }), deadline]);
          if (!token) throw new ProviderError(401, "directory_token_unavailable");
          const chunks: string[][] = [];
          for (let i = 0; i < missing.length; i += 20) chunks.push(missing.slice(i, i + 20));
          const batches = await Promise.race([Promise.all(chunks.map(async (chunk) => {
            const res = await transport("https://graph.microsoft.com/v1.0/$batch", {
              method: "POST", redirect: "error", signal: controller.signal,
              headers: { authorization: `Bearer ${token.token}`, "content-type": "application/json" },
              body: JSON.stringify({ requests: chunk.map((id) => ({
                id, method: "GET", url: `/users/${id}?$select=id,displayName,userPrincipalName`,
              })) }),
            });
            if (!res.ok) throw new ProviderError(res.status, `directory_http_${res.status}`);
            const body: unknown = await res.json();
            if (!isObject(body) || !Array.isArray(body.responses) || body.responses.length !== chunk.length) {
              throw new ProviderError(502, "invalid_directory_batch");
            }
            const seen = new Set<string>();
            return body.responses.map((r: unknown): DirectoryUser => {
              if (!isObject(r) || typeof r.id !== "string" || !chunk.includes(r.id) || seen.has(r.id)) {
                throw new ProviderError(502, "invalid_directory_batch");
              }
              seen.add(r.id);
              if (r.status === 404) return unresolved(r.id, "not_found");
              if (r.status === 401 || r.status === 403) return unresolved(r.id, "permission_required");
              if (r.status !== 200) return unresolved(r.id, "unavailable");
              if (!isObject(r.body) || typeof r.body.id !== "string" || r.body.id.toLowerCase() !== r.id) {
                throw new ProviderError(502, "invalid_directory_user");
              }
              const displayName = label(r.body.displayName, 256), userPrincipalName = label(r.body.userPrincipalName, 320);
              if (!displayName && !userPrincipalName) return unresolved(r.id, "unavailable");
              return { objectId: r.id, state: "resolved", displayName, userPrincipalName };
            });
          })), deadline]);
          for (const user of batches.flat()) {
            users.set(user.objectId, user);
            if (user.state === "resolved" || user.state === "not_found") {
              user.expiresAt = now() + (user.state === "resolved" ? 300000 : 60000);
              cache.set(user.objectId, { user, expires: user.expiresAt });
              while (cache.size > 1000) cache.delete(cache.keys().next().value!);
            }
          }
          if (batches.flat().some((u) => u.state === "permission_required" || u.state === "unavailable")) {
            log(JSON.stringify({ schema: "ccof.admin.directory.v1", code: "directory_partial_failure", count: missing.length }));
          }
        } catch (err) {
          const status = err instanceof ProviderError ? err.status : null;
          const state = status === 401 || status === 403 ? "permission_required" : "unavailable";
          log(JSON.stringify({ schema: "ccof.admin.directory.v1", status, code: err instanceof ProviderError ? err.code : "directory_request_failed" }));
          for (const id of missing) users.set(id, unresolved(id, state));
        } finally {
          controller.abort();
          clearTimeout(timer);
        }
      }
      const rows = ids.map((id) => users.get(id)!);
      const state = rows.every((u) => u.state === "resolved") ? "available"
        : rows.every((u) => u.state === "permission_required") ? "permission_required"
          : rows.every((u) => u.state === "unavailable") ? "unavailable" : "partial";
      return { state, observedAt, permission: PERMISSION, data: { users: rows } };
    },
  };
}
