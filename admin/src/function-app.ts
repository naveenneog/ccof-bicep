// Azure Functions v4 registration of the project admin API. Thin by design: the logic is api.ts.
// This package is deployed only to the admin Function App; the resolver, sync and reconciler packages
// are built from the repository root and never include it.

import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { app } from "@azure/functions";
import type { HttpRequest, HttpResponseInit, InvocationContext } from "@azure/functions";
import { ManagedIdentityCredential } from "@azure/identity";
import { handleAdminRequest } from "./api.ts";
import type { ApiDependencies } from "./api.ts";
import { ApiError, createAuthenticator, readAuthConfig } from "./auth.ts";
import type { Authenticator } from "./auth.ts";
import { createCatalogStore, createCosmosProjectStore, openContainer, probeCosmos, readCosmosSettings } from "./cosmos-store.ts";
import { serveUi, serveUiV3, uiConfigurationResponse, v3Enabled } from "./ui.ts";
import { createOperations } from "./operations.ts";
import { handleV2Request } from "./v2.ts";
import { handleV3Request } from "./v3.ts";
import { createCosmosChangeLog } from "./change-log.ts";
import { createLimitsStore } from "./sync-limits.ts";
import { createRegistryStore } from "./backend-routing.ts";
import { QueryCache } from "./chargeback.ts";
import type { QuerySources } from "./chargeback.ts";
import { ADMIN_VERSION } from "./version.ts";
import { isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";
import { createUserDirectory } from "./user-directory.ts";

let authenticate: Authenticator | null = null;
let authProblem = "";
try {
  authenticate = createAuthenticator(readAuthConfig(process.env));
} catch (err) {
  authProblem = err instanceof ApiError ? err.code : "admin_auth_configuration_invalid";
}

const cosmos = readCosmosSettings(process.env);
const credential = new ManagedIdentityCredential(process.env.ADMIN_MANAGED_IDENTITY_CLIENT_ID ? { clientId: process.env.ADMIN_MANAGED_IDENTITY_CLIENT_ID } : {});
const directory = createUserDirectory(process.env, credential);
const container = cosmos ? openContainer(cosmos, credential) : null;
const store = container ? createCosmosProjectStore(container) : null;
const catalogContainer = cosmos && process.env.ADMIN_CONFIG_CONTAINER
  ? openContainer({ ...cosmos, container: process.env.ADMIN_CONFIG_CONTAINER }, credential) : null;
const catalogStore = catalogContainer ? createCatalogStore(catalogContainer) : null;
// The permanent change record and the sync removal limits share the adminConfig container.
const changeLog = catalogContainer ? createCosmosChangeLog(catalogContainer) : null;
const limitsStore = catalogContainer ? createLimitsStore(catalogContainer) : null;
const registry = catalogContainer ? createRegistryStore(catalogContainer) : null;
let defaultCatalogPromise: Promise<Doc | null> | null = null;
// A missing or invalid packaged rate card degrades only the cost-definitions view, and is retried
// on the next request rather than cached as a permanent failure.
function defaultCatalog(log: (line: string) => void): Promise<Doc | null> {
  defaultCatalogPromise ??= readFile(new URL("../../../ui-dist/rate-card.json", import.meta.url), "utf8").then((raw) => {
    const rateCard: unknown = JSON.parse(raw);
    if (!isObject(rateCard) || !Array.isArray(rateCard.entries)) throw new Error("packaged_rate_card_invalid");
    return { schemaVersion: 1, rateCard, models: [...new Map(rateCard.entries.filter(isObject).map((entry) => [entry.model, {
      family: String(entry.model).split("-")[1], model: entry.model, deployment: entry.model, backendId: "",
    }])).values()] } as Doc;
  }).catch(() => {
    log(JSON.stringify({ schema: "ccof.admin.integration.v2", capability: "packaged_rate_card", outcome: "unavailable" }));
    defaultCatalogPromise = null;
    return null;
  });
  return defaultCatalogPromise;
}

async function projectsHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const body = ["POST", "PUT", "PATCH"].includes(request.method.toUpperCase()) ? await request.text() : null;
  const deps: ApiDependencies = { authenticate, store, changeLog, log: (line) => context.log(line), now: () => new Date(), newId: () => randomUUID() };
  const response = await handleAdminRequest(
    { method: request.method, path: new URL(request.url).pathname, headers: (name) => request.headers.get(name), body },
    deps,
  );
  return { status: response.status, headers: response.headers, jsonBody: response.jsonBody };
}

// Function-key protected. Reports configuration and Cosmos reachability as codes only.
async function healthHandler(_request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const cosmosState = container ? await probeCosmos(container, (line) => context.log(line)) : "not_configured";
  const ready = authenticate !== null && cosmosState === "ok";
  return {
    status: ready ? 200 : 503,
    headers: { "cache-control": "no-store" },
    jsonBody: { version: ADMIN_VERSION, status: ready ? "ready" : "not_ready", checks: { auth: authenticate ? "configured" : authProblem, cosmos: cosmosState } },
  };
}

// Only the admin host has an empty prefix so the site root can redirect. A route template cannot start
// with "/"; an optional zero-length parameter matches only the root path. All existing public API URLs
// keep their explicit /api prefix; resolver/sync/reconciler host files are not changed.
app.http("adminHome", { methods: ["GET"], authLevel: "anonymous", route: "{root:maxlength(0)?}", handler: () => ({
  status: 302, headers: { location: v3Enabled(process.env) ? "/api/console-v3#/overview" : "/api/console", "cache-control": "no-store" },
}) });
app.http("projects", { methods: ["GET", "POST"], authLevel: "anonymous", route: "api/projects", handler: projectsHandler });
app.http("project", { methods: ["GET"], authLevel: "anonymous", route: "api/projects/{projectId}", handler: projectsHandler });
app.http("classificationPolicy", {
  methods: ["PUT", "PATCH"],
  authLevel: "anonymous",
  route: "api/projects/{projectId}/classifications/{code}/{part}",
  handler: projectsHandler,
});
app.http("projectSettings", { methods: ["PUT"], authLevel: "anonymous", route: "api/projects/{projectId}/settings", handler: projectsHandler });
app.http("projectRetire", { methods: ["POST"], authLevel: "anonymous", route: "api/projects/{projectId}/retire", handler: projectsHandler });
app.http("adminV2", {
  methods: ["GET", "PUT"], authLevel: "anonymous", route: "api/v2/{feature}",
  handler: async (request, context) => {
    const response = await handleV2Request({
      method: request.method, path: new URL(request.url).pathname + new URL(request.url).search,
      headers: (name) => request.headers.get(name), body: request.method === "PUT" ? await request.text() : null,
    }, {
      authenticate, projects: store, catalogStore, changeLog, defaultCatalog: await defaultCatalog((line) => context.log(line)),
      operations: createOperations(process.env, credential, (line) => context.log(line)),
      now: () => new Date(), newId: randomUUID, log: (line) => context.log(line),
    });
    return { status: response.status, headers: response.headers, jsonBody: response.jsonBody };
  },
});
app.http("adminHealth", { methods: ["GET"], authLevel: "function", route: "api/health", handler: healthHandler });

app.http("adminUi", {
  methods: ["GET"], authLevel: "anonymous", route: "api/console/{asset?}",
  handler: async (request, context) => {
    const asset = request.params.asset ?? "";
    if (asset === "config") return uiConfigurationResponse(process.env);
    if (asset === "me") {
      try {
        if (!authenticate) throw new ApiError(503, "admin_auth_not_configured");
        const actor = await authenticate(request.headers.get("authorization"));
        return { status: 200, headers: { "cache-control": "no-store" }, jsonBody: { canWrite: actor.canWrite } };
      } catch (err) {
        const status = err instanceof ApiError ? err.status : 500;
        const error = err instanceof ApiError ? err.code : "internal_error";
        context.log(JSON.stringify({ schema: "ccof.admin.ui.v1", outcome: "refused", status, error }));
        return { status, headers: { "cache-control": "no-store" }, jsonBody: { error } };
      }
    }
    try {
      return await serveUi(asset);
    } catch {
      context.error("ccof.admin.ui.v1: packaged UI assets unavailable");
      return { status: 503, body: "Admin console assets are unavailable. Check the package deployment." };
    }
  },
});

// ---- V3 console and API (docs/ADMIN-V3.md). Served only with ADMIN_V3_ENABLED=true; V2 is untouched. ----
const v3Cache = new QueryCache();
let sourcesPromise: Promise<QuerySources | null> | null = null;
// The packaged KQL (ledger, pricing, budgets) shared with the workbook; a missing file disables only
// the log-backed V3 views and is retried on the next request.
function querySources(log: (line: string) => void): Promise<QuerySources | null> {
  const read = (name: string) => readFile(new URL(`../../../kql/${name}`, import.meta.url), "utf8");
  sourcesPromise ??= Promise.all([read("ledger.kql"), read("pricing.kql"), read("budgets.kql")])
    .then(([ledger, pricing, budgets]) => ({ ledger, pricing, budgets }))
    .catch(() => {
      log(JSON.stringify({ schema: "ccof.admin.integration.v2", capability: "packaged_queries", outcome: "unavailable" }));
      sourcesPromise = null;
      return null;
    });
  return sourcesPromise;
}

app.http("adminV3", {
  methods: ["GET", "POST", "PUT"], authLevel: "anonymous", route: "api/v3/{*rest}",
  handler: async (request, context) => {
    if (!v3Enabled(process.env)) return { status: 404, headers: { "cache-control": "no-store" }, jsonBody: { error: "route_not_found" } };
    const log = (line: string) => context.log(line);
    const response = await handleV3Request({
      method: request.method, path: new URL(request.url).pathname + new URL(request.url).search,
      headers: (name) => request.headers.get(name), body: ["POST", "PUT"].includes(request.method.toUpperCase()) ? await request.text() : null,
    }, {
      authenticate, projects: store, catalogStore, changeLog, limitsStore, registry, defaultCatalog: await defaultCatalog(log),
      operations: createOperations(process.env, credential, log), env: process.env,
      sources: await querySources(log), cache: v3Cache, directory, now: () => new Date(), newId: randomUUID, log,
    });
    return { status: response.status, headers: response.headers, jsonBody: response.jsonBody };
  },
});

app.http("adminUiV3", {
  methods: ["GET"], authLevel: "anonymous", route: "api/console-v3/{asset?}",
  handler: async (request, context) => {
    const enabled = v3Enabled(process.env);
    if (!enabled) return { status: 404, headers: { "cache-control": "no-store" }, body: "Not found" };
    const asset = request.params.asset ?? "";
    // Same public sign-in configuration as V2; the browser registers /api/console-v3 as its redirect URI.
    if (asset === "config") return uiConfigurationResponse(process.env);
    try {
      return await serveUiV3(asset, enabled);
    } catch {
      context.error("ccof.admin.ui.v3: packaged UI assets unavailable");
      return { status: 503, body: "Admin console V3 assets are unavailable. Check the package deployment." };
    }
  },
});