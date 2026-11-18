// ADR 0040: the admin console onboards a Foundry backend that already exists, with its private endpoint
// approved and Cognitive Services User granted to each APIM identity. Preflight reads Azure and reports
// one check per prerequisite; onboarding reruns it, then writes, in order: the APIM backend entity in
// every gateway, the backend descriptor (Cosmos `backends`), and the registry entry. Every write is
// skipped when the same value already exists, so a failed run is finished by running it again.
// Nothing here grants a role, approves an endpoint or changes Entra.

import { ApiError } from "./auth.ts";
import type { ApiRequest, ApiResponse } from "./api.ts";
import { beginChange } from "./change-log.ts";
import type { ChangeLog } from "./change-log.ts";
import type { RegistryStore } from "./backend-routing.ts";
import { isObject } from "./validation.ts";
import type { Doc } from "./validation.ts";
import { registeredBackendProblems } from "../../src/contracts/project-routing.ts";
import type { RegisteredBackend } from "../../src/contracts/project-routing.ts";
import { checkBackendRecord } from "../../src/resolver/backend.ts";

export interface FoundryAccount {
  id: string;
  customSubDomainName: string | null;
  publicNetworkAccess: string | null;
  // The status of each private endpoint connection: Approved, Pending, Rejected, Disconnected.
  privateEndpointStatuses: string[];
}
export interface RoleAssignment { roleDefinitionId: string; scope: string }
export interface OnboardingProvider {
  account(accountId: string): Promise<FoundryAccount | null>;
  deployments(accountId: string): Promise<{ name: string; provisioningState: string }[]>;
  apimPrincipal(apimId: string): Promise<string | null>;
  // Assignments for the principal that apply at, above or below the account.
  roleAssignments(accountId: string, principalId: string): Promise<RoleAssignment[]>;
  apimBackendUrl(apimId: string, backendId: string): Promise<string | null>;
  putApimBackend(apimId: string, backendId: string, url: string): Promise<void>;
}
export interface DescriptorStore {
  read(backendId: string): Promise<Doc | null>;
  create(doc: Doc): Promise<"created" | "conflict">;
}
export interface OnboardingDependencies {
  provider: OnboardingProvider;
  descriptors: DescriptorStore;
  // The APIM services that must carry the backend entity (region A and, under DR, region B).
  targets: string[];
  // ADMIN_RESOURCE_IDS and ADMIN_DISCOVERY_SCOPES: the console may onboard only accounts inside them.
  resourceIds: string[];
  discoveryScopes: string[];
}
export interface OnboardingContext {
  onboarding?: OnboardingDependencies | null;
  registry?: RegistryStore | null;
  changeLog?: ChangeLog | null;
  now(): Date;
  log(line: string): void;
}

export const ONBOARDING_ROUTE = /^backend-onboarding(\/preflight)?$/;
const MAX_BODY_BYTES = 16 * 1024;
const BODY_KEYS = ["backendId", "foundryResourceId", "deployments", "displayName", "inferenceGeo", "circuitBreaker"];
const ACCOUNT_ID = /^\/subscriptions\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/resourceGroups\/[^/]+\/providers\/Microsoft\.CognitiveServices\/accounts\/[A-Za-z0-9-]{2,64}$/i;
// Cognitive Services User and Azure AI User (Foundry): either lets APIM's identity call the Anthropic endpoint.
const INFERENCE_ROLES = ["a97b65f3-24c7-4388-baec-2e87135dc908", "53ca6127-db72-4b80-b1b0-d745d6d5456d"];
const PLACEHOLDER_URL = "https://placeholder.services.ai.azure.com/anthropic";

export class OnboardingInvalid extends ApiError {
  readonly problems: string[];
  constructor(problems: string[]) { super(422, "invalid_onboarding_request"); this.problems = problems; }
}

type Status = "pass" | "warn" | "fail";
interface Check { id: string; status: Status; detail: string }
interface Request {
  backendId: string; foundryResourceId: string; deployments: string[] | null; displayName: string | null;
  inferenceGeo: RegisteredBackend["inferenceGeo"]; circuitBreaker: RegisteredBackend["circuitBreaker"];
}
interface Preflight { ok: boolean; conflict: boolean; checks: Check[]; endpoint: string | null; plan: RegisteredBackend | null }

const response = (status: number, data: unknown): ApiResponse =>
  ({ status, jsonBody: data, headers: { "cache-control": "no-store", "content-type": "application/json" } });
const lower = (s: string) => s.toLowerCase();
const sameUrl = (a: string, b: string) => lower(a).replace(/\/+$/, "") === lower(b).replace(/\/+$/, "");
const nameOf = (resourceId: string) => resourceId.split("/").pop() ?? resourceId;
const reason = (err: unknown) => {
  const e = err as { status?: number; code?: string; message?: string };
  return e?.status ? `${e.status} ${e.code ?? ""}`.trim() : e?.message ?? "error";
};

export function createMemoryDescriptorStore(): DescriptorStore & { docs: Map<string, Doc> } {
  const docs = new Map<string, Doc>();
  return {
    docs,
    async read(backendId) { const d = docs.get(backendId); return d ? structuredClone(d) : null; },
    async create(doc) {
      if (docs.has(String(doc.backendId))) return "conflict";
      docs.set(String(doc.backendId), structuredClone(doc));
      return "created";
    },
  };
}

export function descriptorFor(backendId: string): Doc {
  return { id: backendId, backendId, status: "active", apiFormat: "anthropic-messages", auth: { mode: "managed-identity", resource: "https://cognitiveservices.azure.com" } };
}

function readRequest(raw: string | null): Request {
  if (!raw) throw new ApiError(400, "body_required");
  if (Buffer.byteLength(raw) > MAX_BODY_BYTES) throw new ApiError(413, "body_too_large");
  let body: unknown;
  try { body = JSON.parse(raw); } catch { throw new ApiError(400, "body_not_json"); }
  if (!isObject(body)) throw new OnboardingInvalid(["body:not_an_object"]);
  const problems: string[] = [];
  if (Object.keys(body).some((k) => !BODY_KEYS.includes(k))) problems.push("body:unexpected_key");
  if (typeof body.foundryResourceId !== "string" || !ACCOUNT_ID.test(body.foundryResourceId)) problems.push("foundryResourceId:invalid");
  const request: Request = {
    backendId: body.backendId as string,
    foundryResourceId: body.foundryResourceId as string,
    deployments: body.deployments === undefined ? null : body.deployments as string[],
    displayName: typeof body.displayName === "string" ? body.displayName.trim() : body.displayName === undefined ? null : body.displayName as string,
    inferenceGeo: (body.inferenceGeo ?? "global") as Request["inferenceGeo"],
    circuitBreaker: (body.circuitBreaker ?? null) as Request["circuitBreaker"],
  };
  // The endpoint and default deployments come from Azure; placeholders let the shared contract check the rest now.
  problems.push(...registeredBackendProblems(entryFor(request, PLACEHOLDER_URL, request.deployments ?? ["placeholder"], request.displayName ?? "placeholder")));
  if (problems.length) throw new OnboardingInvalid([...new Set(problems)]);
  return request;
}

function entryFor(r: Request, url: string, deployments: string[], displayName: string): RegisteredBackend {
  return { backendId: r.backendId, displayName, url, deployments, inferenceGeo: r.inferenceGeo, status: "active", circuitBreaker: r.circuitBreaker };
}

function assertInScope(accountId: string, deps: OnboardingDependencies) {
  const id = lower(accountId);
  const allowed = deps.resourceIds.some((r) => lower(r) === id)
    || deps.discoveryScopes.some((s) => id.startsWith(`${lower(s).replace(/\/+$/, "")}/`));
  if (!allowed) throw new ApiError(403, "resource_out_of_scope");
}

async function attempt<T>(id: string, checks: Check[], read: () => Promise<T>): Promise<T | undefined> {
  try { return await read(); } catch (err) {
    checks.push({ id, status: "fail", detail: `The console could not read Azure (${reason(err)}). Check the console identity's read roles.` });
    return undefined;
  }
}

async function preflight(r: Request, deps: OnboardingDependencies, registry: RegistryStore): Promise<Preflight> {
  const { provider } = deps;
  const checks: Check[] = [];
  const failed = (): Preflight => ({ ok: false, conflict: false, checks, endpoint: null, plan: null });
  const account = await attempt("account_found", checks, () => provider.account(r.foundryResourceId));
  if (account === undefined) return failed();
  if (!account || !account.customSubDomainName) {
    checks.push({ id: "account_found", status: "fail", detail: account ? "The account has no custom subdomain, so it has no Foundry endpoint." : "No Foundry account with this resource ID." });
    return failed();
  }
  const endpoint = `https://${lower(account.customSubDomainName)}.services.ai.azure.com/anthropic`;
  checks.push({ id: "account_found", status: "pass", detail: endpoint });

  const listed = await attempt("deployments", checks, () => provider.deployments(r.foundryResourceId));
  const ready = (listed ?? []).filter((d) => d.provisioningState === "Succeeded").map((d) => d.name);
  const deployments = r.deployments ?? ready;
  if (listed) {
    const missing = deployments.filter((d) => !ready.includes(d));
    checks.push(missing.length || !deployments.length
      ? { id: "deployments", status: "fail", detail: deployments.length ? `Not deployed or not succeeded: ${missing.join(", ")}.` : "The account has no succeeded deployment." }
      : { id: "deployments", status: "pass", detail: deployments.join(", ") });
  }

  const statuses = account.privateEndpointStatuses;
  if (statuses.includes("Approved")) checks.push({ id: "network", status: "pass", detail: "A private endpoint connection is approved." });
  else if (lower(account.publicNetworkAccess ?? "enabled") === "enabled") {
    checks.push({ id: "network", status: "warn", detail: "No approved private endpoint; the gateway reaches the account over public network access." });
  } else {
    checks.push({ id: "network", status: "fail", detail: statuses.length
      ? `Public access is disabled and no private endpoint connection is approved (${statuses.join(", ")}). Approve it on the account's Networking page.`
      : "Public access is disabled and the account has no private endpoint connection." });
  }

  const accountId = lower(r.foundryResourceId);
  for (const apimId of deps.targets) {
    const id = `roles:${apimId}`;
    const principal = await attempt(id, checks, () => provider.apimPrincipal(apimId));
    if (principal === undefined) continue;
    if (!principal) { checks.push({ id, status: "fail", detail: `${nameOf(apimId)} has no system-assigned managed identity.` }); continue; }
    const assignments = await attempt(id, checks, () => provider.roleAssignments(r.foundryResourceId, principal));
    if (assignments === undefined) continue;
    const granted = assignments.some((a) => INFERENCE_ROLES.some((role) => lower(a.roleDefinitionId).endsWith(`/${role}`))
      && !lower(a.scope).startsWith(`${accountId}/`));
    checks.push(granted
      ? { id, status: "pass", detail: `${nameOf(apimId)} (${principal}) may call the account.` }
      : { id, status: "fail", detail: `Grant Cognitive Services User on the account to ${nameOf(apimId)}'s identity ${principal}.` });
  }

  const conflicts: string[] = [];
  const free = await attempt("id_free", checks, async () => {
    const entry = await registry.read(r.backendId);
    if (entry && !sameUrl(entry.doc.url, endpoint)) conflicts.push(`registry (${entry.doc.url})`);
    const descriptor = await deps.descriptors.read(r.backendId);
    if (descriptor && !sameDescriptor(descriptor, r.backendId)) conflicts.push("backend descriptor");
    for (const apimId of deps.targets) {
      const url = await provider.apimBackendUrl(apimId, r.backendId);
      if (url && !sameUrl(url, endpoint)) conflicts.push(`${nameOf(apimId)} (${url})`);
    }
    return true;
  });
  if (free) {
    checks.push(conflicts.length
      ? { id: "id_free", status: "fail", detail: `Backend ID ${r.backendId} is already used for another endpoint in: ${conflicts.join("; ")}.` }
      : { id: "id_free", status: "pass", detail: `Backend ID ${r.backendId} is free or already points at this endpoint.` });
  }
  const plan = entryFor(r, endpoint, deployments, r.displayName ?? nameOf(r.foundryResourceId));
  const planProblems = registeredBackendProblems(plan);
  if (planProblems.length) checks.push({ id: "plan", status: "fail", detail: `The registry entry is invalid: ${planProblems.join(", ")}.` });
  return { ok: checks.every((c) => c.status !== "fail"), conflict: conflicts.length > 0, checks, endpoint, plan };
}

// Same as the descriptor onboarding writes, including the token audience the gateway requests.
function sameDescriptor(doc: Doc, backendId: string): boolean {
  const verdict = checkBackendRecord(doc, backendId);
  const auth = verdict.kind === "active" ? verdict.descriptor.auth : null;
  return auth?.mode === "managed-identity" && auth.resource === (descriptorFor(backendId).auth as Doc).resource;
}

export async function onboardingRequest(path: string, method: string, url: URL, request: ApiRequest, actor: { oid: string; canWrite: boolean },
  requestId: string, ctx: OnboardingContext): Promise<ApiResponse | null> {
  if (!ONBOARDING_ROUTE.test(path)) return null;
  const deps = ctx.onboarding;
  if (!deps) throw new ApiError(404, "route_not_found");
  if ([...url.searchParams].length) throw new ApiError(400, "unknown_parameter");
  if (path === "backend-onboarding" && method === "GET") {
    return response(200, { enabled: true, targets: deps.targets, resourceIds: deps.resourceIds, discoveryScopes: deps.discoveryScopes,
      editable: actor.canWrite && Boolean(ctx.registry), observedAt: ctx.now().toISOString() });
  }
  if (method !== "POST") throw new ApiError(405, "method_not_allowed");
  if (!actor.canWrite) throw new ApiError(403, "write_permission_required");
  if (!ctx.registry) throw new ApiError(503, "backend_registry_not_configured");
  const r = readRequest(request.body);
  assertInScope(r.foundryResourceId, deps);
  const checked = await preflight(r, deps, ctx.registry);
  const result = { ok: checked.ok, checks: checked.checks, endpoint: checked.endpoint, plan: checked.plan };
  if (path === "backend-onboarding/preflight") return response(200, { ...result, observedAt: ctx.now().toISOString() });

  const operation = "v3/backend-onboarding";
  const audit = (fields: Doc) => ctx.log(JSON.stringify({ schema: "ccof.admin.audit.v1", at: ctx.now().toISOString(), requestId, actorOid: actor.oid,
    operation, backendId: r.backendId, foundryResourceId: r.foundryResourceId, ...fields }));
  if (!checked.ok || !checked.plan || !checked.endpoint) {
    const status = checked.conflict ? 409 : 422;
    const error = checked.conflict ? "backend_id_conflict" : "preflight_failed";
    audit({ outcome: "refused", status, code: error });
    return response(status, { error, requestId, preflight: result });
  }
  return write(r, checked.plan, deps, ctx.registry, ctx, requestId, actor.oid, audit);
}

async function write(r: Request, plan: RegisteredBackend, deps: OnboardingDependencies, registry: RegistryStore, ctx: OnboardingContext,
  requestId: string, actorOid: string, audit: (fields: Doc) => void): Promise<ApiResponse> {
  const { provider } = deps;
  const descriptor = descriptorFor(r.backendId);
  // Reread just before writing: another request may have claimed the ID since preflight.
  const conflict = () => {
    audit({ outcome: "refused", status: 409, code: "backend_id_conflict" });
    return response(409, { error: "backend_id_conflict", requestId, hint: "The backend ID was claimed for another endpoint during onboarding. Run Check again." });
  };
  const existingDescriptor = await deps.descriptors.read(r.backendId);
  const existingEntry = await registry.read(r.backendId);
  if ((existingDescriptor && !sameDescriptor(existingDescriptor, r.backendId)) || (existingEntry && !sameUrl(existingEntry.doc.url, plan.url))) return conflict();
  const todo = { apim: [] as string[], descriptor: !existingDescriptor, registry: !existingEntry };
  for (const apimId of deps.targets) {
    const url = await provider.apimBackendUrl(apimId, r.backendId);
    if (url && !sameUrl(url, plan.url)) return conflict();
    if (!url) todo.apim.push(apimId);
  }
  const changes = [
    ...todo.apim.map((id) => ({ path: `apim:${id}`, before: null, after: plan.url })),
    ...(todo.descriptor ? [{ path: "descriptor", before: null, after: descriptor }] : []),
    ...(todo.registry ? [{ path: "registry", before: null, after: plan }] : []),
  ];
  const steps: { step: string; result: "created" | "exists" }[] = [];
  if (!changes.length) {
    steps.push(...deps.targets.map((id) => ({ step: `apim:${id}`, result: "exists" as const })),
      { step: "descriptor", result: "exists" }, { step: "registry", result: "exists" });
    audit({ outcome: "unchanged", steps });
    return response(200, { backend: plan, steps, changed: false, requestId });
  }
  const pending = await beginChange(ctx.changeLog, { requestId, at: ctx.now().toISOString(), actorOid, operation: "v3/backend-onboarding",
    projectId: null, changes, details: { backendId: r.backendId, foundryResourceId: r.foundryResourceId } }, ctx.now, ctx.log);
  try {
    for (const apimId of deps.targets) {
      if (todo.apim.includes(apimId)) {
        await provider.putApimBackend(apimId, r.backendId, plan.url);
        const readBack = await provider.apimBackendUrl(apimId, r.backendId);
        if (!readBack || !sameUrl(readBack, plan.url)) throw new Error(`apim_readback_mismatch:${nameOf(apimId)}`);
      }
      steps.push({ step: `apim:${apimId}`, result: todo.apim.includes(apimId) ? "created" : "exists" });
    }
    if (todo.descriptor && await deps.descriptors.create(descriptor) === "conflict") throw new ApiError(409, "backend_id_conflict");
    steps.push({ step: "descriptor", result: todo.descriptor ? "created" : "exists" });
    if (todo.registry && !(await registry.save(plan, null))) throw new ApiError(409, "backend_id_conflict");
    steps.push({ step: "registry", result: todo.registry ? "created" : "exists" });
  } catch (err) {
    const code = err instanceof ApiError ? err.code : "onboarding_incomplete";
    await pending.finish("unconfirmed", { code, steps });
    audit({ outcome: "unconfirmed", code, steps, cause: reason(err) });
    return response(err instanceof ApiError ? err.status : 502, { error: code, requestId, steps,
      hint: "Steps already done are kept. Run onboarding again with the same values to finish the rest." });
  }
  await pending.finish("created", { steps });
  audit({ outcome: "created", steps, url: plan.url });
  return response(201, { backend: plan, steps, changed: true, requestId });
}
