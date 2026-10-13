// The backend registry (docs/PILOT.md C-8): one document per APIM backend
// entity, written by onboarding Stage 2 or edited in the portal, in the Cosmos
// container `backends` (partition key /backendId, id = backendId). The
// resolver turns it into a descriptor without secrets; the gateway applies the
// authentication mode from the descriptor, so adding a backend of a known mode
// changes no policy.

import { isIdentifier } from "./freshness.ts";

export type BackendAuth =
  | { mode: "managed-identity"; resource: string }
  | { mode: "credential-manager"; providerId: string; connectionId: string }
  | { mode: "backend-entity" };

export interface BackendDescriptor {
  id: string;
  apiFormat: "anthropic-messages";
  auth: BackendAuth;
}

export interface BackendRecord {
  id: string;
  backendId: string;
  status: "active" | "disabled";
  apiFormat: string;
  auth: unknown;
}

export type BackendProblem =
  | "not_an_object"
  | "backend_id_mismatch"
  | "invalid_status"
  | "invalid_api_format"
  | "invalid_auth_mode"
  | "invalid_auth";

// legacy: no registry document, so the gateway's own configuration for the
// backendId applies (the path tonight's shape-B backend uses).
export type BackendVerdict =
  | { kind: "legacy" }
  | { kind: "active"; descriptor: BackendDescriptor }
  | { kind: "not_active" }
  | { kind: "invalid"; detail: BackendProblem };

// The forms an Entra resource takes. Narrow on purpose: the gateway places the
// value in a policy, so only characters a resource identifier needs pass.
const HOST = /[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*/.source;
const HTTPS_RESOURCE = new RegExp(`^https://${HOST}(?::\\d{1,5})?(?:/[A-Za-z0-9._~/-]*)?$`);
const API_URI = /^api:\/\/[A-Za-z0-9][A-Za-z0-9._~/-]{0,199}$/;
const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

const isResource = (value: unknown): value is string =>
  typeof value === "string" && (HTTPS_RESOURCE.test(value) || API_URI.test(value) || GUID.test(value));

// Rebuilt field by field, so only the mode's own fields reach the gateway,
// even if the document holds more.
function parseAuth(value: unknown): BackendAuth | BackendProblem {
  if (typeof value !== "object" || value === null) return "invalid_auth_mode";
  const auth = value as Record<string, unknown>;
  switch (auth.mode) {
    case "managed-identity":
      return isResource(auth.resource) ? { mode: "managed-identity", resource: auth.resource } : "invalid_auth";
    case "credential-manager":
      return isIdentifier(auth.providerId) && isIdentifier(auth.connectionId)
        ? { mode: "credential-manager", providerId: auth.providerId, connectionId: auth.connectionId }
        : "invalid_auth";
    case "backend-entity":
      return { mode: "backend-entity" };
    default:
      return "invalid_auth_mode";
  }
}

export function checkBackendRecord(record: unknown, backendId: string): BackendVerdict {
  if (record === null || record === undefined) return { kind: "legacy" };
  if (typeof record !== "object") return { kind: "invalid", detail: "not_an_object" };
  const { id, backendId: recordBackendId, status, apiFormat, auth } = record as Record<string, unknown>;
  if (id !== backendId || recordBackendId !== backendId) return { kind: "invalid", detail: "backend_id_mismatch" };
  if (status === "disabled") return { kind: "not_active" };
  if (status !== "active") return { kind: "invalid", detail: "invalid_status" };
  if (apiFormat !== "anthropic-messages") return { kind: "invalid", detail: "invalid_api_format" };
  const parsed = parseAuth(auth);
  if (typeof parsed === "string") return { kind: "invalid", detail: parsed };
  return { kind: "active", descriptor: { id: backendId, apiFormat, auth: parsed } };
}
