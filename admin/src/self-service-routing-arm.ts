import type { TokenCredential } from "@azure/identity";
import type { Doc } from "./validation.ts";

const ARM = "https://management.azure.com";
const APIM_API = "2024-05-01";
const AUTH_API = "2022-04-01";
const GUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const APIM = new RegExp(`^/subscriptions/${GUID}/resourceGroups/[A-Za-z0-9._-]{1,90}/providers/Microsoft\\.ApiManagement/service/[A-Za-z0-9-]{1,50}$`, "i");
const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
const READ = "Microsoft.ApiManagement/service/backends/read";
const WRITE = "Microsoft.ApiManagement/service/backends/write";
export const ROUTING_PERMISSIONS_READ = "Microsoft.Authorization/permissions/read";
export const ROUTING_BACKEND_ACTIONS = [READ, WRITE] as const;
const object = (v: unknown): v is Doc => typeof v === "object" && v !== null && !Array.isArray(v);

export class RoutingProviderError extends Error {
  readonly status: number;
  readonly action: string;
  readonly scope: string;
  constructor(status: number, action: string, scope: string) {
    super(`routing_provider_${status}`);
    this.status = status;
    this.action = action;
    this.scope = scope;
  }
}

export interface RoutingProvider {
  permitted(scope: string, action: string): Promise<boolean>;
  backend(scope: string, backendId: string): Promise<Doc | null>;
  putBackend(scope: string, backendId: string, body: Doc): Promise<void>;
}

export function readRoutingTargets(env: Readonly<Record<string, string | undefined>>): string[] {
  const raw = env.ADMIN_GATEWAY_RESOURCE_IDS !== undefined ? env.ADMIN_GATEWAY_RESOURCE_IDS : env.ADMIN_GATEWAY_RESOURCE_ID;
  const ids = (raw ?? "").split(",").map((id) => id.trim());
  if (env.ADMIN_GATEWAY_RESOURCE_IDS === undefined && ids.length !== 1) throw new Error("admin_gateway_resource_ids_invalid");
  if (!ids.length || ids.length > 10 || ids.some((id) => !APIM.test(id) || id.split("/").some((part) => part === "." || part === "..")) ||
    new Set(ids.map((id) => id.toLowerCase())).size !== ids.length) throw new Error("admin_gateway_resource_ids_invalid");
  if (env.ADMIN_GATEWAY_RESOURCE_IDS !== undefined && env.ADMIN_GATEWAY_RESOURCE_ID?.trim() &&
    !ids.some((id) => id.toLowerCase() === env.ADMIN_GATEWAY_RESOURCE_ID!.trim().toLowerCase())) {
    throw new Error("admin_gateway_resource_ids_inconsistent");
  }
  return ids;
}

const wildcard = (pattern: string, action: string) => {
  const escaped = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  return new RegExp(`^${escaped}$`, "i").test(action);
};

// Unlike onboarding's narrow provider, publication needs full resources, effective permissions,
// and conditional isolation of approved targets; the shared onboarding transport is not exported.
export function createRoutingArmProvider(credential: Pick<TokenCredential, "getToken">, targets: readonly string[],
  transport: typeof fetch = fetch): RoutingProvider {
  const allowed = new Set(readRoutingTargets({ ADMIN_GATEWAY_RESOURCE_IDS: targets.join(",") }).map((s) => s.toLowerCase()));
  const target = (scope: string) => {
    if (!APIM.test(scope) || !allowed.has(scope.toLowerCase())) throw new Error("routing_target_not_approved");
  };
  async function request(url: string, scope: string, action: string, init: RequestInit = {}): Promise<Doc | null> {
    const parsed = new URL(url);
    if (parsed.origin !== ARM || parsed.username || parsed.password || parsed.hash) throw new Error("routing_arm_url_invalid");
    const signal = AbortSignal.timeout(15000);
    const token = await credential.getToken(`${ARM}/.default`, { abortSignal: signal });
    if (!token) throw new RoutingProviderError(401, action, scope);
    const response = await transport(url, { ...init, redirect: "error", signal,
      headers: { authorization: `Bearer ${token.token}`, "content-type": "application/json" } });
    if (response.status === 404 && (init.method ?? "GET") === "GET" && action === READ) return null;
    if (!response.ok) throw new RoutingProviderError(response.status, action, scope);
    const text = await response.text();
    if (!text) return {};
    const body: unknown = JSON.parse(text);
    if (!object(body)) throw new Error("routing_arm_response_invalid");
    return body;
  }
  const path = (scope: string, id: string) => {
    target(scope);
    if (!ID.test(id)) throw new Error("routing_backend_id_invalid");
    return `${ARM}${scope}/backends/${id}?api-version=${APIM_API}`;
  };
  return {
    async permitted(scope, action) {
      target(scope);
      if (!ROUTING_BACKEND_ACTIONS.includes(action as typeof READ | typeof WRITE)) throw new Error("routing_action_invalid");
      const pathname = `${scope}/providers/Microsoft.Authorization/permissions`;
      let url = `${ARM}${pathname}?api-version=${AUTH_API}`;
      let granted = false;
      for (let page = 0; page < 50; page++) {
        const doc = await request(url, scope, ROUTING_PERMISSIONS_READ);
        if (!Array.isArray(doc?.value)) throw new Error("routing_permissions_invalid");
        for (const value of doc.value) {
          if (!object(value) || !Array.isArray(value.actions) || !Array.isArray(value.notActions) ||
            [...value.actions, ...value.notActions].some((a) => typeof a !== "string")) throw new Error("routing_permissions_invalid");
          if (value.actions.some((a) => wildcard(a, action)) && !value.notActions.some((a) => wildcard(a, action))) granted = true;
        }
        if (!doc.nextLink) return granted;
        if (typeof doc.nextLink !== "string") throw new Error("routing_permissions_next_link_invalid");
        const next = new URL(doc.nextLink);
        if (next.origin !== ARM || next.pathname.toLowerCase() !== pathname.toLowerCase() ||
          next.username || next.password || next.hash) throw new Error("routing_permissions_next_link_invalid");
        url = next.href;
      }
      throw new Error("routing_permissions_page_limit");
    },
    async backend(scope, id) {
      const doc = await request(path(scope, id), scope, READ);
      if (doc && ((doc.id !== undefined && (typeof doc.id !== "string" || doc.id.toLowerCase() !== `${scope}/backends/${id}`.toLowerCase())) ||
        (doc.name !== undefined && (typeof doc.name !== "string" || doc.name.toLowerCase() !== id.toLowerCase())) ||
        (doc.type !== undefined && (typeof doc.type !== "string" || doc.type.toLowerCase() !== "microsoft.apimanagement/service/backends")))) {
        throw new Error("routing_backend_identity_mismatch");
      }
      return doc;
    },
    async putBackend(scope, id, body) {
      if (!/^ccof-(m|pool)-/.test(id)) throw new Error("routing_backend_not_revision_scoped");
      await request(path(scope, id), scope, WRITE, { method: "PUT", body: JSON.stringify(body) });
    },
  };
}
