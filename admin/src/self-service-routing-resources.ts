import type { RoutingMember } from "./backend-routing.ts";
import { canonical, isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";

const RESOURCE = /^(https:\/\/management\.azure\.com)?\/subscriptions\/[0-9a-f-]{36}\/resourceGroups\/[A-Za-z0-9._-]{1,90}\/providers\/Microsoft\.CognitiveServices\/accounts\/[A-Za-z0-9._-]{1,64}$/i;
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KEYS = ["description", "title", "url", "protocol", "type", "resourceId", "credentials", "tls", "circuitBreaker", "pool"];

export function routingMemberBody(member: RoutingMember, projectId: string, source: Doc | null): Doc {
  const p = source?.properties;
  if (!isObject(p) || p.url !== member.url || p.protocol !== "http" ||
    (p.type !== undefined && p.type !== "Single") || Object.keys(p).some((k) => !KEYS.includes(k)) || p.pool) {
    throw new Error("routing_source_backend_mismatch");
  }
  const properties: Doc = {
    description: `CCOF ${projectId} pool member ${member.priority}: ${member.backendId} (ADR 0034)`,
    url: member.url, protocol: "http", tls: { validateCertificateChain: true, validateCertificateName: true },
  };
  if (p.resourceId !== undefined && p.resourceId !== "") {
    if (typeof p.resourceId !== "string" || !RESOURCE.test(p.resourceId) || p.resourceId.split("/").some((part) => part === "." || part === "..")) {
      throw new Error("routing_source_resource_invalid");
    }
    // APIM's native Foundry resourceId may include the ARM origin; never strip/rewrite it.
    properties.resourceId = p.resourceId;
  }
  if (p.credentials !== undefined && p.credentials !== null) {
    if (!isObject(p.credentials) || Object.keys(p.credentials).some((k) => k !== "managedIdentity")) throw new Error("routing_source_auth_invalid");
    const identity = p.credentials.managedIdentity;
    if (identity !== undefined) {
      if (!isObject(identity) || Object.keys(identity).some((k) => !["resource", "clientId"].includes(k)) ||
        identity.resource !== "https://cognitiveservices.azure.com" ||
        (identity.clientId != null && (typeof identity.clientId !== "string" || !GUID.test(identity.clientId)))) throw new Error("routing_source_auth_invalid");
      properties.credentials = structuredClone(p.credentials);
    }
  }
  if (p.tls !== undefined && (!isObject(p.tls) || Object.keys(p.tls).some((k) => !["validateCertificateChain", "validateCertificateName"].includes(k)) ||
    p.tls.validateCertificateChain !== true || p.tls.validateCertificateName !== true)) throw new Error("routing_source_tls_invalid");
  const b = member.circuitBreaker;
  if (b?.enabled) properties.circuitBreaker = { rules: [{
    name: "ccof-breaker",
    failureCondition: { count: b.failureCount, interval: `PT${b.failureIntervalSeconds}S`,
      statusCodeRanges: structuredClone(b.statusCodeRanges), errorReasons: ["BackendConnectionFailure", "Timeout"] },
    tripDuration: `PT${b.tripDurationSeconds}S`, acceptRetryAfter: b.acceptRetryAfter,
  }] };
  return { properties };
}

export function routingPoolBody(plan: { projectId: string; revision: number; members: RoutingMember[] }, apim: string): Doc {
  return { properties: {
    description: `CCOF ${plan.projectId} failover pool, revision ${plan.revision} (ADR 0034)`, type: "Pool",
    pool: { services: plan.members.map((m) => ({ id: `${apim}/backends/${m.memberBackendId}`, priority: m.priority, weight: m.weight })) },
  } };
}

const duration = (v: unknown) => {
  if (typeof v !== "string") return v;
  const m = /^P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/.exec(v);
  return m ? Number(m[1] ?? 0) * 86400 + Number(m[2] ?? 0) * 3600 + Number(m[3] ?? 0) * 60 + Number(m[4] ?? 0) : v;
};

// Keep every meaningful field, rejecting unknown overrides rather than checking only the URL.
// Normalize only ARM's harmless ordering, duration and absent-vs-empty serialization differences.
function comparable(body: Doc): unknown {
  if (!isObject(body.properties)) return body;
  const p = structuredClone(body.properties);
  // ARM GET serializes unset properties as null (title on every backend; protocol/url on pools).
  for (const key of Object.keys(p)) if (p[key] === null) delete p[key];
  if (p.type === "Single") delete p.type;
  for (const key of ["credentials", "resourceId", "circuitBreaker"]) {
    if (p[key] === "" || (isObject(p[key]) && !Object.keys(p[key]).length)) delete p[key];
  }
  if (isObject(p.circuitBreaker) && Array.isArray(p.circuitBreaker.rules)) {
    for (const rule of p.circuitBreaker.rules) if (isObject(rule)) {
      rule.tripDuration = duration(rule.tripDuration);
      if (isObject(rule.failureCondition)) {
        const c = rule.failureCondition;
        c.interval = duration(c.interval);
        if (Array.isArray(c.errorReasons)) c.errorReasons.sort();
        if (Array.isArray(c.statusCodeRanges)) c.statusCodeRanges.sort((a, b) => canonical(a).localeCompare(canonical(b)));
      }
    }
  }
  if (isObject(p.pool) && Array.isArray(p.pool.services)) {
    for (const service of p.pool.services) if (isObject(service) && typeof service.id === "string") service.id = service.id.toLowerCase();
    p.pool.services.sort((a, b) => canonical(a).localeCompare(canonical(b)));
  }
  return p;
}

export function routingResourceMatches(expected: Doc, actual: Doc | null): boolean {
  return actual !== null && canonical(comparable(expected)) === canonical(comparable(actual));
}
