// One version for the admin package, both consoles and every version endpoint.
export const ADMIN_VERSION = "3.3.0";

export interface ServedBy { app: string | null; region: string | null }

// Deployments set ADMIN_SERVED_REGION/ADMIN_SERVED_APP from the site itself; App Service's read-only
// REGION_NAME and WEBSITE_SITE_NAME are the fallback. In a two-region deployment this shows which
// admin app answered the request through Front Door.
export function readServedBy(env: Record<string, string | undefined>): ServedBy {
  const value = (...names: string[]) => names.map((name) => env[name]?.trim()).find(Boolean) || null;
  return { app: value("ADMIN_SERVED_APP", "WEBSITE_SITE_NAME"), region: value("ADMIN_SERVED_REGION", "REGION_NAME") };
}
