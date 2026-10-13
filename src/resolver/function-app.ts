// Thin Azure Functions v4 registration - the only part of the resolver that
// needs the real Functions host to exercise, deliberately kept minimal.
// All testable logic lives in http-handler.ts, decide.ts, freshness.ts and
// config.ts (framework-free); this file wires them to app.http, the app
// settings and a real Cosmos client.
//
// Both functions are anonymous at the Functions level: App Service
// Authentication, configured on the Function App, admits only APIM's managed
// identity (ADR-0009). There is no function key.

import { app } from "@azure/functions";
import type { HttpRequest, HttpResponseInit, InvocationContext } from "@azure/functions";
import { readResolverConfig } from "./config.ts";
import { createCosmosReads } from "./cosmos-reads.ts";
import {
  handleHealthRequest,
  handleResolveRequest,
  hasPlatformPrincipal,
  isPlatformAuthEnabled,
} from "./http-handler.ts";
import type { ResolverReadiness, ResolverRequestContext, ResolverRuntime } from "./http-handler.ts";

// Read once per host instance; an app-settings change restarts the host.
// Invalid settings leave the resolver unready, and it refuses every request.
const config = readResolverConfig(process.env);

// Built once per host instance (standard Azure Functions pattern - expensive
// clients like CosmosClient should outlive a single invocation).
const readiness: ResolverReadiness = config.ok
  ? {
      ready: true,
      budgetEnforcement: config.config.budgetEnforcement,
      requestDeadlineMs: config.config.requestDeadlineMs,
      reads: createCosmosReads({ ...config.config.cosmos, readDeadlineMs: config.config.requestDeadlineMs }),
    }
  : { ready: false, problems: config.problems };

function runtimeFor(context: InvocationContext): ResolverRuntime {
  return { readiness, now: () => new Date(), log: (line) => context.log(line) };
}

function requestContext(request: HttpRequest, body?: unknown): ResolverRequestContext {
  return {
    platformAuthEnabled: isPlatformAuthEnabled(process.env.WEBSITE_AUTH_ENABLED),
    authenticatedPrincipal: hasPlatformPrincipal((name) => request.headers.get(name)),
    body,
  };
}

async function resolveHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    body = undefined; // answered 400 after the authentication guards
  }
  return handleResolveRequest(requestContext(request, body), runtimeFor(context));
}

async function healthHandler(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  return handleHealthRequest(requestContext(request), runtimeFor(context));
}

app.http("resolve", {
  methods: ["POST"],
  authLevel: "anonymous",
  handler: resolveHandler,
});

app.http("health", {
  methods: ["GET"],
  authLevel: "anonymous",
  handler: healthHandler,
});
