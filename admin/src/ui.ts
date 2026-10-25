import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isGuid } from "./auth.ts";
import type { ApiResponse } from "./api.ts";

const files: Record<string, { file: string; type: string }> = {
  "": { file: "index.html", type: "text/html; charset=utf-8" },
  "app.css": { file: "app.css", type: "text/css; charset=utf-8" },
  "app.js": { file: "app.js", type: "text/javascript; charset=utf-8" },
  "icon.svg": { file: "icon.svg", type: "image/svg+xml" },
};

export const UI_HEADERS = {
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
  "content-security-policy": [
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self'",
    "connect-src 'self' https://login.microsoftonline.com",
    "frame-src https://login.microsoftonline.com",
    "frame-ancestors 'none'",
    "base-uri 'none'",
    "form-action 'self'",
    "object-src 'none'",
  ].join("; "),
  "cross-origin-opener-policy": "same-origin-allow-popups",
};

export interface UiConfig {
  configured: boolean;
  tenantId?: string;
  clientId?: string;
  scope?: string;
}

// This endpoint exposes only public SPA configuration, never API keys, object-id allowlists or tokens.
export function publicUiConfig(env: Readonly<Record<string, string | undefined>>): UiConfig {
  const tenantId = env.ADMIN_TENANT_ID;
  const clientId = env.ADMIN_UI_CLIENT_ID;
  const scope = env.ADMIN_UI_SCOPE;
  if (!isGuid(tenantId) || !isGuid(clientId) || !scope ||
      !/^api:\/\/[A-Za-z0-9._/-]+$/.test(scope)) return { configured: false };
  return { configured: true, tenantId, clientId, scope };
}

// Compiled to dist/admin/src/ui.js; the package root holds ui-dist/ (Build-AdminPackage.ps1).
const PACKAGED_UI = fileURLToPath(new URL("../../../ui-dist/", import.meta.url));

export async function serveUi(asset: string, base = PACKAGED_UI): Promise<{
  status: number;
  headers: Record<string, string>;
  body: string;
}> {
  const entry = Object.hasOwn(files, asset) ? files[asset] : undefined;
  if (!entry) return { status: 404, headers: UI_HEADERS, body: "Not found" };
  return { status: 200, headers: { ...UI_HEADERS, "content-type": entry.type }, body: await readFile(resolve(base, entry.file), "utf8") };
}

export function uiConfigurationResponse(env: Readonly<Record<string, string | undefined>>): ApiResponse {
  return { status: 200, headers: { ...UI_HEADERS, "content-type": "application/json" }, jsonBody: publicUiConfig(env) };
}

// V3 console (docs/ADMIN-V3.md): the same headers and strict CSP, its own explicit allow-list and
// build output, and served only when ADMIN_V3_ENABLED=true so V2 stays the default.
const v3Files: Record<string, { file: string; type: string }> = {
  "": { file: "index.html", type: "text/html; charset=utf-8" },
  "app.css": { file: "app.css", type: "text/css; charset=utf-8" },
  "app.js": { file: "app.js", type: "text/javascript; charset=utf-8" },
  "icon.svg": { file: "icon.svg", type: "image/svg+xml" },
};
const PACKAGED_UI_V3 = fileURLToPath(new URL("../../../ui-dist-v3/", import.meta.url));
export const v3Enabled = (env: Readonly<Record<string, string | undefined>>): boolean => env.ADMIN_V3_ENABLED === "true";

export async function serveUiV3(asset: string, enabled: boolean, base = PACKAGED_UI_V3): Promise<{
  status: number;
  headers: Record<string, string>;
  body: string;
}> {
  const entry = enabled ? v3Files[asset] : undefined;
  if (!entry || !Object.hasOwn(v3Files, asset)) return { status: 404, headers: UI_HEADERS, body: "Not found" };
  return { status: 200, headers: { ...UI_HEADERS, "content-type": entry.type }, body: await readFile(resolve(base, entry.file), "utf8") };
}