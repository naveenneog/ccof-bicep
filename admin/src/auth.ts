// Caller authentication for the project admin API. The app validates the Entra access token itself,
// so it does not depend on a change to the deployed APIM instance or to an existing app registration.
// Access is the intersection of: the configured tenant, audience and delegated scope; an allowed OAuth
// client; and an administrator listed by object id or holding the configured app role.

import { createRemoteJWKSet, jwtVerify } from "jose";
import type { JWTPayload, JWTVerifyGetKey } from "jose";

const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isGuid = (value: unknown): value is string => typeof value === "string" && GUID.test(value);

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

export type Permission = "read" | "write";

export interface AuthConfig {
  tenantId: string;
  audience: string;
  scope: string;
  allowedClients: Set<string>;
  readerIds: Set<string>;
  editorIds: Set<string>;
  readerRole: string;
  editorRole: string;
}

export interface Actor {
  oid: string;
  canWrite: boolean;
}

function roleList(payload: JWTPayload): string[] {
  return Array.isArray(payload.roles) ? payload.roles.filter((r): r is string => typeof r === "string") : [];
}

export function authorizeClaims(payload: JWTPayload, config: AuthConfig): Actor {
  if (typeof payload.tid !== "string" || payload.tid.toLowerCase() !== config.tenantId || !isGuid(payload.oid)) {
    throw new ApiError(403, "tenant_or_user_denied");
  }
  const client = payload.azp ?? payload.appid;
  if (typeof client !== "string" || !config.allowedClients.has(client.toLowerCase())) throw new ApiError(403, "oauth_client_denied");
  if (typeof payload.scp !== "string" || !payload.scp.split(" ").includes(config.scope)) throw new ApiError(403, "delegated_scope_required");
  const oid = payload.oid.toLowerCase();
  const roles = roleList(payload);
  const canWrite = config.editorIds.has(oid) || roles.includes(config.editorRole);
  const canRead = canWrite || config.readerIds.has(oid) || roles.includes(config.readerRole);
  if (!canRead) throw new ApiError(403, "administrator_not_allowed");
  return { oid, canWrite };
}

export type Authenticator = (authorization: string | null) => Promise<Actor>;

export function createAuthenticator(config: AuthConfig, keys?: JWTVerifyGetKey): Authenticator {
  const keySet = keys ?? createRemoteJWKSet(new URL(`https://login.microsoftonline.com/${config.tenantId}/discovery/v2.0/keys`));
  return async (authorization) => {
    const match = /^Bearer ([A-Za-z0-9._~+/=-]+)$/.exec(authorization ?? "");
    if (!match) throw new ApiError(401, "bearer_token_required");
    let payload: JWTPayload;
    try {
      ({ payload } = await jwtVerify(match[1], keySet, {
        audience: config.audience,
        issuer: [`https://login.microsoftonline.com/${config.tenantId}/v2.0`, `https://sts.windows.net/${config.tenantId}/`],
        algorithms: ["RS256"],
        requiredClaims: ["exp", "iat", "oid", "tid"],
        clockTolerance: 30,
      }));
    } catch {
      throw new ApiError(401, "invalid_access_token");
    }
    return authorizeClaims(payload, config);
  };
}

// Missing or invalid settings refuse every request (fail closed); they never fall back to open access.
export function readAuthConfig(env: Readonly<Record<string, string | undefined>>): AuthConfig {
  const ids = (key: string): Set<string> => {
    const values = (env[key] ?? "").split(",").map((v) => v.trim().toLowerCase()).filter(Boolean);
    if (values.some((v) => !isGuid(v))) throw new ApiError(503, "admin_auth_configuration_invalid");
    return new Set(values);
  };
  const tenantId = env.ADMIN_TENANT_ID;
  const audience = env.ADMIN_AUDIENCE?.trim();
  const scope = env.ADMIN_SCOPE?.trim();
  if (!isGuid(tenantId) || !audience || !scope) throw new ApiError(503, "admin_auth_not_configured");
  const allowedClients = ids("ADMIN_ALLOWED_CLIENT_IDS");
  const readerIds = ids("ADMIN_READER_IDS");
  const editorIds = ids("ADMIN_EDITOR_IDS");
  const readerRole = env.ADMIN_READER_ROLE?.trim() || "CCOF.Projects.Read";
  const editorRole = env.ADMIN_EDITOR_ROLE?.trim() || "CCOF.Projects.Write";
  if (allowedClients.size === 0) throw new ApiError(503, "admin_auth_not_configured");
  return { tenantId: tenantId.toLowerCase(), audience, scope, allowedClients, readerIds, editorIds, readerRole, editorRole };
}
