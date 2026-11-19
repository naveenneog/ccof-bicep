export interface GraphPermissionProof {
  state: "granted" | "permission_required" | "unknown";
  identityResourceId?: string;
}
const IDENTITY = /^\/subscriptions\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/resourceGroups\/[A-Za-z0-9_.()-]{1,90}\/providers\/Microsoft\.ManagedIdentity\/userAssignedIdentities\/[A-Za-z0-9_-]{1,128}$/i;

// Only pass a token obtained directly from the configured ManagedIdentityCredential for Graph.
// This is claim inspection of that trusted credential result, not a JWT authentication endpoint.
export function graphPermissionFromManagedIdentityToken(
  token: { token: string; expiresOnTimestamp: number } | null,
  identityResourceId: string | undefined,
  now: Date,
): GraphPermissionProof {
  const identity = identityResourceId && IDENTITY.test(identityResourceId) ? identityResourceId : undefined;
  const unknown: GraphPermissionProof = { state: "unknown", ...(identity ? { identityResourceId: identity } : {}) };
  if (!identity || !token || !Number.isFinite(token.expiresOnTimestamp) || token.expiresOnTimestamp <= now.getTime() ||
    typeof token.token !== "string" || token.token.length > 32_768) return unknown;
  try {
    const parts = token.token.split(".");
    if (parts.length !== 3) return unknown;
    const claims = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")) as Record<string, unknown>;
    if (!["https://graph.microsoft.com", "https://graph.microsoft.com/", "00000003-0000-0000-c000-000000000000"].includes(String(claims.aud)) ||
      typeof claims.exp !== "number" || claims.exp * 1000 <= now.getTime() ||
      (claims.roles !== undefined && (!Array.isArray(claims.roles) || claims.roles.some((role) => typeof role !== "string")))) return unknown;
    return {
      state: Array.isArray(claims.roles) && claims.roles.includes("GroupMember.Read.All") ? "granted" : "permission_required",
      identityResourceId: identity,
    };
  } catch { return unknown; }
}
