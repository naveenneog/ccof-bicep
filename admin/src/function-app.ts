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
import { serveUi, uiConfigurationResponse } from "./ui.ts";
import { createOperations } from "./operations.ts";
import { handleV2Request } from "./v2.ts";
import { isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";

let authenticate: Authenticator | null = null;
let authProblem = "";
try {
  authenticate = createAuthenticator(readAuthConfig(process.env));
} catch (err) {
  authProblem = err instanceof ApiError ? err.code : "admin_auth_configuration_invalid";
}

const cosmos = readCosmosSettings(process.env);
const credential = new ManagedIdentityCredential(process.env.ADMIN_MANAGED_IDENTITY_CLIENT_ID ? { clientId: process.env.ADMIN_MANAGED_IDENTITY_CLIENT_ID } : {});
const container = cosmos ? openContainer(cosmos, credential) : null;
const store = container ? createCosmosProjectStore(container) : null;
const catalogContainer = cosmos && process.env.ADMIN_CONFIG_CONTAINER
  ? openContainer({ ...cosmos, container: process.env.ADMIN_CONFIG_CONTAINER }, credential) : null;
const catalogStore = catalogContainer ? createCatalogStore(catalogContainer) : null;
let defaultCatalogPromise: Promise<Doc> | null = null;
function defaultCatalog(): Promise<Doc> {
  defaultCatalogPromise ??= readFile(new URL("../../../ui-dist/rate-card.json", import.meta.url), "utf8").then((raw) => {
    const rateCard: unknown = JSON.parse(raw);
    if (!isObject(rateCard) || !Array.isArray(rateCard.entries)) throw new Error("packaged_rate_card_invalid");
    return { schemaVersion: 1, rateCard, models: [...new Map(rateCard.entries.filter(isObject).map((entry) => [entry.model, {
      family: String(entry.model).split("-")[1], model: entry.model, deployment: entry.model, backendId: "",
    }])).values()] };
  });
  return defaultCatalogPromise;
}

async function projectsHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  const body = ["POST", "PUT", "PATCH"].includes(request.method.toUpperCase()) ? await request.text() : null;
  const deps: ApiDependencies = { authenticate, store, log: (line) => context.log(line), now: () => new Date(), newId: () => randomUUID() };
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
    jsonBody: { version: "2.0.0", status: ready ? "ready" : "not_ready", checks: { auth: authenticate ? "configured" : authProblem, cosmos: cosmosState } },
  };
}

app.http("projects", { methods: ["GET", "POST"], authLevel: "anonymous", route: "projects", handler: projectsHandler });
app.http("project", { methods: ["GET"], authLevel: "anonymous", route: "projects/{projectId}", handler: projectsHandler });
app.http("classificationPolicy", {
  methods: ["PUT", "PATCH"],
  authLevel: "anonymous",
  route: "projects/{projectId}/classifications/{code}/{part}",
  handler: projectsHandler,
});
app.http("projectSettings", { methods: ["PUT"], authLevel: "anonymous", route: "projects/{projectId}/settings", handler: projectsHandler });
app.http("adminV2", {
  methods: ["GET", "PUT"], authLevel: "anonymous", route: "v2/{feature}",
  handler: async (request, context) => {
    const response = await handleV2Request({
      method: request.method, path: new URL(request.url).pathname + new URL(request.url).search,
      headers: (name) => request.headers.get(name), body: request.method === "PUT" ? await request.text() : null,
    }, {
      authenticate, projects: store, catalogStore, defaultCatalog: await defaultCatalog(),
      operations: createOperations(process.env, credential, (line) => context.log(line)),
      now: () => new Date(), newId: randomUUID, log: (line) => context.log(line),
    });
    return { status: response.status, headers: response.headers, jsonBody: response.jsonBody };
  },
});
app.http("adminHealth", { methods: ["GET"], authLevel: "function", route: "health", handler: healthHandler });

app.http("adminUi", {
  methods: ["GET"], authLevel: "anonymous", route: "console/{asset?}",
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
