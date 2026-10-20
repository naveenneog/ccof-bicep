// Project-specific client onboarding files for V3: config.json for the CCOF token helper
// (client/src/config.mjs validates it) and onboarding.json for the administrator who hands it out.
// Read-only and secret-free: tenant, public client ID, scope, gateway URL, project selector and the
// classification's allowed deployments. No user lists, tokens or keys. Missing admin-app settings
// are reported, and the affected field carries an explicit REPLACE- placeholder instead of a guess.

import { createHash } from "node:crypto";
import { ApiError, isGuid } from "./auth.ts";
import { isIdentifier, isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";

export const CLIENT_FAMILIES = ["sonnet", "haiku", "opus"] as const;
const FAMILY_ORDER = ["sonnet", "haiku", "opus", "fable", "mythos"];
const DEPLOYMENT = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/;
const HEADER = /^[A-Za-z][A-Za-z0-9-]{0,63}$/;

export interface ClientSettings { tenantId: string | null; clientId: string | null; scope: string | null; gatewayUrl: string | null; selectorHeader: string; missing: string[] }

function validGatewayUrl(value: string | undefined): string | null {
  if (!value) return null;
  try {
    const u = new URL(value);
    if (u.protocol !== "https:" || u.username || u.password || u.search || u.hash || /\/v1(?:\/messages)?\/?$/.test(u.pathname) || /\s/.test(value)) return null;
    return u.toString().replace(/\/+$/, "");
  } catch { return null; }
}

export function readClientSettings(env: Readonly<Record<string, string | undefined>>): ClientSettings {
  const missing: string[] = [];
  const tenant = env.ADMIN_CLIENT_TENANT_ID || env.ADMIN_TENANT_ID;
  const tenantId = isGuid(tenant) ? tenant!.toLowerCase() : null;
  if (!tenantId) missing.push("ADMIN_CLIENT_TENANT_ID");
  const clientId = isGuid(env.ADMIN_CLIENT_ID) ? env.ADMIN_CLIENT_ID!.toLowerCase() : null;
  if (!clientId) missing.push("ADMIN_CLIENT_ID");
  let scope: string | null = env.ADMIN_CLIENT_SCOPE || (clientId ? `api://${clientId}/access_as_user` : null);
  if (scope && (/\s/.test(scope) || !/^(api|https):\/\/[^/\s]+\/\S+$/.test(scope))) scope = null;
  if (!scope) missing.push("ADMIN_CLIENT_SCOPE");
  const gatewayUrl = validGatewayUrl(env.ADMIN_GATEWAY_URL);
  if (!gatewayUrl) missing.push("ADMIN_GATEWAY_URL");
  const header = env.ADMIN_PROJECT_HEADER || "x-ccof-project";
  const selectorHeader = HEADER.test(header) ? header : "x-ccof-project";
  return { tenantId, clientId, scope, gatewayUrl, selectorHeader, missing };
}

// A stable Desktop profile GUID per tenant, project and classification, so re-downloading the file
// updates the same Claude Desktop profile rather than adding another.
export function stableProfileId(parts: string[]): string {
  const h = createHash("sha256").update(parts.join("\n"), "utf8").digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${["8", "9", "a", "b"][parseInt(h[16], 16) % 4]}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

export function buildClientFiles(project: Doc, classification: string, settings: ClientSettings, now: Date) {
  if (!isIdentifier(classification)) throw new ApiError(400, "invalid_classification");
  const classes = isObject(project.classifications) ? project.classifications : {};
  const c = classes[classification];
  if (!isObject(c)) throw new ApiError(404, "classification_not_found");
  const projectId = String(project.projectId);
  const families = isObject(c.familyPolicy) && isObject(c.familyPolicy.families) ? c.familyPolicy.families as Record<string, Doc> : {};
  const byFamily: Record<string, string[]> = {};
  for (const f of FAMILY_ORDER) {
    const models = Array.isArray(families[f]?.models) ? (families[f].models as unknown[]).filter((m): m is string => typeof m === "string" && DEPLOYMENT.test(m)) : [];
    if (models.length) byFamily[f] = models;
  }
  const available = [...new Set(Object.values(byFamily).flat())];
  if (!available.length) throw new ApiError(409, "classification_has_no_models");
  const first = (f: string) => byFamily[f]?.[0];
  const fallback = first("sonnet") ?? first("haiku") ?? first("opus") ?? available[0];
  const models: Doc = { default: fallback, opus: first("opus") ?? fallback, sonnet: first("sonnet") ?? fallback, haiku: first("haiku") ?? fallback, available };
  const placeholder = (name: string) => `REPLACE-${name}`;
  const tenantId = settings.tenantId ?? placeholder("TENANT-ID");
  const clientId = settings.clientId ?? placeholder("CLIENT-ID");
  const config = {
    schemaVersion: 1,
    tenantId,
    clientId,
    scope: settings.scope ?? `api://${placeholder("CLIENT-ID")}/access_as_user`,
    gatewayUrl: settings.gatewayUrl ?? `https://${placeholder("GATEWAY-HOST")}.azure-api.net/anthropic`,
    helperTtlSeconds: 300,
    minimumTokenLifetimeSeconds: 360,
    loginTimeoutSeconds: 120,
    tokenTimeoutSeconds: 30,
    disableNonessentialTraffic: true,
    models,
    desktop: { profileId: stableProfileId([tenantId, projectId, classification]), profileName: `${projectId} ${classification}`.slice(0, 120) },
    project: { id: projectId, selectorHeader: settings.selectorHeader },
  };
  const group = { objectId: isGuid(c.groupId) ? String(c.groupId) : null,
    displayName: typeof c.classificationGroupDisplayName === "string" ? c.classificationGroupDisplayName : null };
  const onboarding = {
    schemaVersion: 1,
    kind: "ccof.project-onboarding",
    generatedAt: now.toISOString(),
    complete: settings.missing.length === 0,
    missingAdminSettings: settings.missing,
    project: { id: projectId, displayName: typeof project.displayName === "string" ? project.displayName : projectId, status: project.status ?? null, backendId: project.backendId ?? null },
    classification,
    entraGroup: group,
    access: "Membership of this Entra group grants access after the next entitlement sync. This file grants nothing by itself.",
    models: byFamily,
    gateway: { url: config.gatewayUrl, projectHeader: settings.selectorHeader, projectId },
    clientConfig: {
      fileName: "config.json",
      installPath: {
        windows: "%LOCALAPPDATA%\\ClaudeGateway\\config.json",
        macos: "~/Library/Application Support/ClaudeGateway/config.json",
        linux: "$XDG_CONFIG_HOME/claude-gateway/config.json (or ~/.config/claude-gateway/config.json)",
      },
      overrideEnvironmentVariable: "CCOF_CONFIG_FILE",
    },
    steps: [
      `Ask the platform team to add the developer to the Entra group ${group.displayName ?? group.objectId ?? classification}; access starts after the next entitlement sync.`,
      "Install the CCOF client helper on the developer's machine (client/ in the repository; npm ci --prefix ./client).",
      "Save config.json to the install path for the platform, or set CCOF_CONFIG_FILE to its absolute path.",
      "Run ccof-token login, then the Claude Code or Claude Desktop setup script; they read this project's selector header.",
      `Send a test prompt. A 403 means the developer is not yet in the group or the sync has not run; a 401 means sign-in needs repeating.`,
    ],
    note: "No tokens, keys or user lists are included. Values are copied from the admin app settings and the project registry.",
  };
  return { config, onboarding, missing: settings.missing, complete: settings.missing.length === 0 };
}
