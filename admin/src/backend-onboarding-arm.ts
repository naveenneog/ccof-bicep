// ADR 0040: the Azure side of backend onboarding. ARM reads of the Foundry account and APIM, the
// one APIM write (the backend entity), and the Cosmos `backends` descriptor store. Uses the admin
// app's managed identity only; the least-privilege roles are listed in docs/runbooks/ADMIN-OPERATIONS.md.

import type { Container } from "@azure/cosmos";
import type { TokenCredential } from "@azure/identity";
import type { DescriptorStore, OnboardingProvider } from "./backend-onboarding.ts";
import { ProviderError } from "./operations.ts";
import { isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";

const ARM = "https://management.azure.com";
const ARM_SCOPE = `${ARM}/.default`;
const COGNITIVE_API = "2025-06-01";
const APIM_API = "2024-05-01";
const AUTHZ_API = "2022-04-01";
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const APIM_ID = /^\/subscriptions\/[0-9a-f-]{36}\/resourceGroups\/[^/]+\/providers\/Microsoft\.ApiManagement\/service\/[A-Za-z0-9-]{1,50}$/i;
const object = (v: unknown): Doc => isObject(v) ? v : {};
const text = (v: unknown) => typeof v === "string" ? v : null;

export function readOnboardingTargets(env: Readonly<Record<string, string | undefined>>): string[] {
  const raw = env.ADMIN_GATEWAY_RESOURCE_IDS?.trim() ? env.ADMIN_GATEWAY_RESOURCE_IDS : env.ADMIN_GATEWAY_RESOURCE_ID ?? "";
  const ids = raw.split(",").map((s) => s.trim()).filter(Boolean);
  if (!ids.every((id) => APIM_ID.test(id))) throw new Error("admin_gateway_resource_ids_invalid");
  return ids;
}

export function createArmOnboardingProvider(credential: TokenCredential, transport: typeof fetch = fetch): OnboardingProvider {
  // Returns null on 404 so "not there yet" is distinguishable from "cannot read".
  async function call(path: string, query: string, init: RequestInit = {}): Promise<Doc | null> {
    const token = await credential.getToken(ARM_SCOPE);
    if (!token) throw new ProviderError(401, "managed_identity_token_unavailable");
    const response = await transport(`${ARM}${path}?${query}`, {
      ...init, redirect: "error", signal: AbortSignal.timeout(15000),
      headers: { "content-type": "application/json", authorization: `Bearer ${token.token}` },
    });
    if (response.status === 404 && (init.method ?? "GET") === "GET") return null;
    if (!response.ok) throw new ProviderError(response.status, `upstream_${response.status}`);
    const body = await response.text();
    return body ? object(JSON.parse(body)) : {};
  }
  const values = (doc: Doc | null) => Array.isArray(doc?.value) ? doc.value.map(object) : [];

  return {
    async account(accountId) {
      const doc = await call(accountId, `api-version=${COGNITIVE_API}`);
      if (!doc) return null;
      const p = object(doc.properties);
      const connections = Array.isArray(p.privateEndpointConnections) ? p.privateEndpointConnections.map(object) : [];
      return {
        id: text(doc.id) ?? accountId,
        customSubDomainName: text(p.customSubDomainName),
        publicNetworkAccess: text(p.publicNetworkAccess),
        privateEndpointStatuses: connections.map((c) => text(object(object(c.properties).privateLinkServiceConnectionState).status) ?? "Unknown"),
      };
    },
    async deployments(accountId) {
      return values(await call(`${accountId}/deployments`, `api-version=${COGNITIVE_API}`))
        .map((d) => ({ name: text(d.name) ?? "", provisioningState: text(object(d.properties).provisioningState) ?? "Unknown" }))
        .filter((d) => d.name);
    },
    async apimPrincipal(apimId) {
      const doc = await call(apimId, `api-version=${APIM_API}`);
      return text(object(doc?.identity).principalId);
    },
    async roleAssignments(accountId, principalId) {
      if (!GUID.test(principalId)) throw new ProviderError(400, "invalid_principal");
      const filter = encodeURIComponent(`principalId eq '${principalId}'`);
      return values(await call(`${accountId}/providers/Microsoft.Authorization/roleAssignments`, `api-version=${AUTHZ_API}&$filter=${filter}`))
        .map((a) => object(a.properties))
        .map((p) => ({ roleDefinitionId: text(p.roleDefinitionId) ?? "", scope: text(p.scope) ?? "" }));
    },
    async apimBackendUrl(apimId, backendId) {
      const doc = await call(`${apimId}/backends/${encodeURIComponent(backendId)}`, `api-version=${APIM_API}`);
      return doc ? text(object(doc.properties).url) : null;
    },
    async putApimBackend(apimId, backendId, url) {
      await call(`${apimId}/backends/${encodeURIComponent(backendId)}`, `api-version=${APIM_API}`, {
        method: "PUT",
        body: JSON.stringify({ properties: { url, protocol: "http", tls: { validateCertificateChain: true, validateCertificateName: true } } }),
      });
    },
  };
}

function statusOf(err: unknown): number | undefined {
  const e = err as { code?: unknown; statusCode?: unknown } | null;
  const value = typeof e?.code === "number" ? e.code : e?.statusCode;
  return typeof value === "number" ? value : undefined;
}

// The `backends` container (partition key /backendId) the resolver reads; create never upserts.
export function createCosmosDescriptorStore(container: Container): DescriptorStore {
  return {
    async read(backendId) {
      try {
        const { resource, statusCode } = await container.item(backendId, backendId).read<Doc>();
        return statusCode === 404 || !resource ? null : resource;
      } catch (err) {
        if (statusOf(err) === 404) return null;
        throw err;
      }
    },
    async create(doc) {
      try {
        await container.items.create(doc);
        return "created";
      } catch (err) {
        if (statusOf(err) === 409) return "conflict";
        throw err;
      }
    },
  };
}
