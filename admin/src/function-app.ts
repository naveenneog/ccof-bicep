// Azure Functions v4 registration of the project admin API. Thin by design: the logic is api.ts.
// This package is deployed only to the admin Function App; the resolver, sync and reconciler packages
// are built from the repository root and never include it.

import { randomUUID } from "node:crypto";
import { app } from "@azure/functions";
import type { HttpRequest, HttpResponseInit, InvocationContext } from "@azure/functions";
import { ManagedIdentityCredential } from "@azure/identity";
import { handleAdminRequest } from "./api.ts";
import type { ApiDependencies } from "./api.ts";
import { ApiError, createAuthenticator, readAuthConfig } from "./auth.ts";
import type { Authenticator } from "./auth.ts";
import { createCosmosProjectStore, openContainer, probeCosmos, readCosmosSettings } from "./cosmos-store.ts";

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
async function healthHandler(): Promise<HttpResponseInit> {
  const cosmosState = container ? await probeCosmos(container) : "not_configured";
  const ready = authenticate !== null && cosmosState === "ok";
  return {
    status: ready ? 200 : 503,
    headers: { "cache-control": "no-store" },
    jsonBody: { status: ready ? "ready" : "not_ready", checks: { auth: authenticate ? "configured" : authProblem, cosmos: cosmosState } },
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
app.http("adminHealth", { methods: ["GET"], authLevel: "function", route: "admin-health", handler: healthHandler });
