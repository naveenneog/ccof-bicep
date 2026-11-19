import { test } from "node:test";
import assert from "node:assert/strict";
import { createRoutingPublisher } from "../src/self-service-routing.ts";
import { RoutingProviderError } from "../src/self-service-routing-arm.ts";
import type { OperationJob, OperationStep } from "../src/self-service-contracts.ts";
import type { RegisteredBackend } from "../../src/contracts/project-routing.ts";

const A = "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-a";
const B = `${A}-b`;
const breaker = { enabled: true, failureCount: 3, failureIntervalSeconds: 60, tripDurationSeconds: 90,
  statusCodeRanges: [{ min: 429, max: 429 }, { min: 500, max: 599 }], acceptRetryAfter: true };
const oldRoute = { revision: 1, poolBackendId: "ccof-pool-old-r1", verifiedAt: "2026-11-18T00:00:00Z" };
const job = (): OperationJob => ({ id: "job-1", kind: "publish-routing", projectId: "PROJECT02",
  expectedEtag: '"e1"', actorOid: "actor", createdAt: "2026-11-19T00:00:00Z", reason: "Publish approved failover", checkpoint: {} });

function setup() {
  let project: Record<string, unknown> = { projectId: "PROJECT02", status: "active", backendId: "foundry-a",
    classifications: {}, failover: { enabled: true, fallbackBackendIds: ["foundry-b"], revision: 2, active: oldRoute } };
  let etag = '"e1"';
  const entries = ["a", "b"].map((n) => ({
    doc: { backendId: `foundry-${n}`, displayName: n, url: `https://acct-${n}.services.ai.azure.com/anthropic`,
      deployments: ["claude-haiku-4-5"], inferenceGeo: "global", status: "active", circuitBreaker: n === "a" ? breaker : null } as RegisteredBackend,
    etag: `"registry-${n}"`,
  }));
  const resources = new Map<string, Record<string, unknown>>();
  for (const target of [A, B]) for (const e of entries) resources.set(`${target}/backends/${e.doc.backendId}`, {
    properties: { url: e.doc.url, protocol: "http",
      resourceId: `https://management.azure.com/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/acct-${e.doc.displayName}`,
      credentials: { managedIdentity: { resource: "https://cognitiveservices.azure.com" } },
      tls: { validateCertificateChain: true, validateCertificateName: true } },
  });
  let permissions = async (_scope: string, _action: string) => true;
  let onGet = (_scope: string, _id: string, value: Record<string, unknown> | null) => value;
  let onPut = async (_scope: string, _id: string) => {};
  let onAudit = async () => {};
  let onFence = async () => true;
  const writes: string[] = [];
  const audit: string[] = [];
  const replacements: string[] = [];
  let fenced = false;
  const deps = {
    env: { ADMIN_ROUTING_PUBLISH_ENABLED: "true", ADMIN_GATEWAY_RESOURCE_IDS: `${A},${B}` } as Record<string, string>,
    projects: {
      async read(_id: string) { return { doc: structuredClone(project), etag }; },
      async replace(doc: Record<string, unknown>, expected: string) {
        assert.ok(fenced, "promotion must be inside the registry fence");
        replacements.push(expected);
        if (expected !== etag) return "precondition_failed";
        project = structuredClone(doc); etag = '"e2"'; return etag;
      },
    },
    registry: { async list() { return structuredClone(entries); } },
    provider: {
      async permitted(scope: string, action: string) { return permissions(scope, action); },
      async backend(scope: string, id: string) {
        return onGet(scope, id, structuredClone(resources.get(`${scope}/backends/${id}`) ?? null));
      },
      async putBackend(scope: string, id: string, body: Record<string, unknown>) {
        assert.ok(fenced, "ARM writes must be inside the registry fence");
        assert.ok(audit.length, "durable audit intent must precede writes");
        await onPut(scope, id);
        writes.push(`${scope}/backends/${id}`); resources.set(`${scope}/backends/${id}`, structuredClone(body));
      },
    },
    async audit(_job: OperationJob, record: Record<string, unknown>) { await onAudit(); audit.push(String(record.phase)); },
    // The production adapter must serialize ALL registry writers, across both admin regions.
    async withRegistryFence(_versions: { backendId: string; etag: string }[], run: () => Promise<OperationStep>) {
      if (!await onFence()) return null;
      fenced = true;
      try { return await run(); } finally { fenced = false; }
    },
    now: () => new Date("2026-11-19T00:00:00Z"),
  };
  const publisher = () => createRoutingPublisher(deps);
  async function planned() {
    const j = job();
    const step = await publisher().advance(j);
    assert.equal(step.state, "running");
    j.checkpoint = step.checkpoint!;
    return j;
  }
  async function finish(j: OperationJob) {
    for (let i = 0; i < 20; i++) {
      const step = await publisher().advance(j);
      if (step.state !== "running") return step;
      j.checkpoint = step.checkpoint!;
    }
    assert.fail("publication did not finish in its bounded number of steps");
  }
  return { deps, publisher, planned, finish, writes, audit, replacements, entries, resources, get project() { return project; },
    setPermissions(fn: typeof permissions) { permissions = fn; }, setGet(fn: typeof onGet) { onGet = fn; },
    setPut(fn: typeof onPut) { onPut = fn; }, setAudit(fn: typeof onAudit) { onAudit = fn; },
    setFence(fn: typeof onFence) { onFence = fn; }, raceProject() { etag = '"concurrent"'; } };
}

test("routing is independently default off; permission preflight never equates GET access with write", async () => {
  const s = setup();
  delete s.deps.env.ADMIN_ROUTING_PUBLISH_ENABLED;
  assert.equal((await s.publisher().capability()).state, "disabled");
  assert.equal((await s.publisher().advance(job())).state, "blocked");
  s.deps.env.ADMIN_ROUTING_PUBLISH_ENABLED = "true";
  s.setPermissions(async (scope, action) => !(scope === B && action.endsWith("/write")));
  const cap = await s.publisher().capability();
  assert.equal(cap.state, "permission_required");
  assert.deepEqual(cap.requirements, [{ action: "Microsoft.ApiManagement/service/backends/write", scope: B }]);
  assert.equal(s.writes.length, 0);
});

test("publishes immutable revision resources to every APIM, preserves native MI auth, then uses original If-Match", async () => {
  const s = setup();
  const j = await s.planned();
  assert.equal(s.writes.length, 0);
  const step = await s.finish(j);
  assert.equal(step.state, "succeeded", step.reason);
  assert.equal(s.writes.length, 6);
  assert.deepEqual(s.replacements, ['"e1"']);
  const pool = String(step.result!.poolBackendId);
  for (const apim of [A, B]) {
    const p = s.resources.get(`${apim}/backends/${pool}`)!.properties as Record<string, any>;
    const memberId = p.pool.services[0].id;
    const m = s.resources.get(memberId)!.properties as Record<string, any>;
    assert.match(m.resourceId, /^https:\/\/management.azure.com\/subscriptions\//);
    assert.deepEqual(m.credentials, { managedIdentity: { resource: "https://cognitiveservices.azure.com" } });
    assert.deepEqual(m.circuitBreaker.rules[0].failureCondition.errorReasons, ["BackendConnectionFailure", "Timeout"]);
    assert.ok(p.pool.services.every((v: { id: string }) => v.id.startsWith(`${apim}/backends/ccof-m-`)));
  }
  assert.equal((s.project.failover as Record<string, any>).active.revision, 2);
});

test("each write advance is bounded to one gateway and leaves the active route unchanged until all verification completes", async () => {
  const s = setup(); const j = await s.planned();
  const first = await s.publisher().advance(j);
  assert.equal(first.state, "running");
  assert.equal(first.phase, "gateway_verified");
  assert.equal(s.writes.length, 3);
  assert.ok(s.writes.every((id) => id.startsWith(`${A}/backends/`)));
  assert.deepEqual((s.project.failover as Record<string, unknown>).active, oldRoute);
  j.checkpoint = first.checkpoint!;
  assert.equal((await s.finish(j)).state, "succeeded");
});

test("one APIM denying PUT is feature-local and preserves the last verified route; retry reuses matching resources", async () => {
  const s = setup();
  const j = await s.planned();
  s.setPut(async (scope) => { if (scope === B) throw new RoutingProviderError(403, "Microsoft.ApiManagement/service/backends/write", B); });
  const denied = await s.finish(j);
  assert.equal(denied.state, "blocked");
  assert.deepEqual(denied.requirements, [{ action: "Microsoft.ApiManagement/service/backends/write", scope: B }]);
  assert.deepEqual((s.project.failover as Record<string, unknown>).active, oldRoute);
  assert.equal(s.writes.length, 3);
  s.setPut(async () => {});
  const done = await s.finish({ ...j, checkpoint: denied.checkpoint ?? j.checkpoint });
  assert.equal(done.state, "succeeded", done.reason);
  assert.equal(s.writes.length, 6, "retry must not overwrite previously created entities");
});

test("readback mismatch of auth, protocol, TLS, breaker or pool never promotes; unexpected owner is never overwritten", async () => {
  for (const field of ["credentials", "resourceId", "protocol", "tls", "circuitBreaker", "pool", "description"]) {
    const s = setup();
    const j = await s.planned();
    s.setGet((scope, id, value) => {
      if (scope === B && id.startsWith(field === "pool" ? "ccof-pool-" : "ccof-m-") && value) {
        const p = value.properties as Record<string, unknown>;
        if (field === "protocol") p.protocol = "soap";
        else if (field === "description") p.description = "someone else";
        else delete p[field];
      }
      return value;
    });
    const bad = await s.finish(j);
    assert.notEqual(bad.state, "succeeded", field);
    assert.equal(s.replacements.length, 0, field);
    assert.deepEqual((s.project.failover as Record<string, unknown>).active, oldRoute);
  }
  const s = setup(); const j = await s.planned();
  s.setGet((_scope, id, value) => id.startsWith("ccof-") ? { properties: { description: "foreign resource" } } : value);
  assert.equal((await s.finish(j)).state, "blocked");
  assert.equal(s.writes.length, 0);
});

test("ARM null serialization of unset fields (title; pool protocol/url) verifies; a null over an expected value does not", async () => {
  const s = setup(); const j = await s.planned();
  s.setGet((_scope, id, value) => {
    if (!value || !id.startsWith("ccof-")) return value;
    const p = value.properties as Record<string, unknown>;
    p.title = null;
    if (id.startsWith("ccof-pool-")) { p.protocol = null; p.url = null; }
    return value;
  });
  const done = await s.finish(j);
  assert.equal(done.state, "succeeded", done.reason);
  const t = setup(); const k = await t.planned();
  t.setGet((_scope, id, value) => {
    if (value && id.startsWith("ccof-m-")) (value.properties as Record<string, unknown>).protocol = null;
    return value;
  });
  assert.notEqual((await t.finish(k)).state, "succeeded");
  assert.equal(t.replacements.length, 0);
});

test("stale project/registry, final CAS race and denied registry fence cannot activate a stale plan", async () => {
  for (const race of ["project", "registry", "fence", "cas", "late-registry"]) {
    const s = setup(); const j = await s.planned();
    if (race === "project") s.raceProject();
    if (race === "registry") s.entries[0].etag = '"changed"';
    if (race === "fence") s.setFence(async () => false);
    if (race === "cas") {
      const replace = s.deps.projects.replace;
      s.deps.projects.replace = async (doc, expected) => { s.raceProject(); return replace(doc, expected); };
    }
    if (race === "late-registry") s.setGet((_scope, id, value) => {
      if (id.startsWith("ccof-pool-") && value) s.entries[0].etag = '"changed-under-broken-fence"';
      return value;
    });

    assert.equal((await s.finish(j)).state, "blocked", race);
    assert.deepEqual((s.project.failover as Record<string, unknown>).active, oldRoute, race);
  }
});

test("transient partial failure is retried only by the durable engine without replacing the old route or rewriting resources", async () => {
  const s = setup(); const j = await s.planned();
  s.setPut(async (scope) => { if (scope === B) throw new RoutingProviderError(503, "Microsoft.ApiManagement/service/backends/write", B); });
  await assert.rejects(() => s.finish(j), RoutingProviderError);
  assert.deepEqual((s.project.failover as Record<string, unknown>).active, oldRoute);
  assert.equal(s.writes.length, 3);
  s.setPut(async () => {});
  assert.equal((await s.finish(j)).state, "succeeded");
  assert.equal(s.writes.length, 6);
});

test("retry recovers an uncertain successful promotion by verifying the pinned result, without a second project mutation", async () => {
  const s = setup(); const j = await s.planned();
  const replace = s.deps.projects.replace;
  s.deps.projects.replace = async (doc, expected) => {
    await replace(doc, expected);
    throw new TypeError("response lost after successful CAS");
  };
  await assert.rejects(() => s.finish(j), TypeError);
  const recovered = await s.finish(j);
  assert.equal(recovered.state, "succeeded", recovered.reason);
  assert.deepEqual(s.replacements, ['"e1"']);
  assert.equal(s.writes.length, 6);
});

test("native system-assigned managed identity clientId null is preserved, rather than rewritten into a different auth form", async () => {
  const s = setup();
  for (const resource of s.resources.values()) {
    ((resource.properties as Record<string, any>).credentials.managedIdentity).clientId = null;
  }
  const j = await s.planned();
  const done = await s.finish(j);
  assert.equal(done.state, "succeeded", done.reason);
  for (const id of s.writes.filter((id) => id.includes("/ccof-m-"))) {
    assert.deepEqual((s.resources.get(id)!.properties as Record<string, any>).credentials,
      { managedIdentity: { resource: "https://cognitiveservices.azure.com", clientId: null } });
  }
});

test("the project and approved registry are the only source of plan IDs/URLs; forged job checkpoint fields are ignored", async () => {
  const s = setup(); const j = await s.planned();
  j.checkpoint.url = "https://evil.example";
  j.checkpoint.targets = ["https://evil.example"];
  j.checkpoint.poolBackendId = "someone-elses-backend";
  assert.equal((await s.finish(j)).state, "succeeded");
  assert.ok(s.writes.every((id) => id.startsWith(`${A}/backends/ccof-`) || id.startsWith(`${B}/backends/ccof-`)));
});

test("audit refusal and missing cross-region registry fence fail closed before any ARM writes", async () => {
  const s = setup(); const j = await s.planned();
  s.setAudit(async () => { throw new Error("audit unavailable"); });
  assert.equal((await s.publisher().advance(j)).state, "failed");
  assert.equal(s.writes.length, 0);
  const unsafe = { ...s.deps, withRegistryFence: undefined };
  assert.equal((await createRoutingPublisher(unsafe).capability()).state, "unavailable");
});
