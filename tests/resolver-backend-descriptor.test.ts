// C-8 (docs/PILOT.md): backends by data. The resolver reads the backend
// registry document for the selected membership's backendId and returns a
// descriptor without secrets. With no registry document, the response carries
// no descriptor and the gateway uses its own configuration for that backendId
// (the legacy path, which tonight's shape-B backend still uses).

import { test } from "node:test";
import assert from "node:assert/strict";
import { checkBackendRecord } from "../src/resolver/backend.ts";
import { resolveRequest } from "../src/resolver/decide.ts";
import { handleResolveRequest } from "../src/resolver/http-handler.ts";
import type { ResolverRuntime } from "../src/resolver/http-handler.ts";
import type { ResolveDependencies } from "../src/resolver/decide.ts";
import { context, fakeReads, RESOLVE_NOW, tokenLimitsOnlyContext } from "./helpers/resolver-fixtures.ts";

const input = { personId: "person-1", subscriptionId: "sub-abc" };

const managedIdentityBackend = {
  id: "foundry-sample-hub",
  backendId: "foundry-sample-hub",
  status: "active",
  apiFormat: "anthropic-messages",
  auth: { mode: "managed-identity", resource: "https://cognitiveservices.azure.com" },
};

function withBackend(record: unknown) {
  const keys: string[] = [];
  const deps = fakeReads({
    readBackend: async (backendId: string) => {
      keys.push(backendId);
      return record;
    },
  });
  return { deps, keys };
}

// ---- through resolveRequest ----

test("no registry document: no descriptor, and backendId as before (the gateway's own configuration applies)", async () => {
  const result = await resolveRequest(input, fakeReads(), tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
  assert.equal(result.backendId, "foundry-sample-hub");
  assert.equal("backend" in result, false);
});

test("an active registry document is returned as the descriptor, read by the membership's backendId", async () => {
  const { deps, keys } = withBackend(managedIdentityBackend);
  const result = await resolveRequest(input, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, false);
  assert.deepEqual(result.backend, {
    id: "foundry-sample-hub",
    apiFormat: "anthropic-messages",
    auth: { mode: "managed-identity", resource: "https://cognitiveservices.azure.com" },
  });
  assert.deepEqual(keys, ["foundry-sample-hub"]);
});

test("budget-state mode returns the descriptor too", async () => {
  const { deps } = withBackend(managedIdentityBackend);
  const result = await resolveRequest(input, deps, context());
  assert.equal(result.refused, false);
  assert.equal(result.backend?.auth.mode, "managed-identity");
});

test("a disabled backend is 403 backend_not_active: the gateway routes only to what the resolver returns", async () => {
  const { deps } = withBackend({ ...managedIdentityBackend, status: "disabled" });
  const result = await resolveRequest(input, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, true);
  assert.equal(result.reason, "backend_not_active");
  assert.equal(result.httpStatus, 403);
  assert.equal(result.projectId, "SAMPLEORGAIAZ103");
});

test("a malformed registry document is 503 backend_record_invalid with a detail code", async () => {
  const { deps } = withBackend({ ...managedIdentityBackend, apiFormat: "openai-chat" });
  const result = await resolveRequest(input, deps, tokenLimitsOnlyContext());
  assert.equal(result.refused, true);
  assert.equal(result.reason, "backend_record_invalid");
  assert.equal(result.httpStatus, 503);
  assert.equal(result.detail, "invalid_api_format");
});

test("a failed registry read is raised, as any other read the decision depends on", async () => {
  const deps = fakeReads({
    readBackend: async () => {
      throw new Error("cosmos unavailable");
    },
  });
  await assert.rejects(resolveRequest(input, deps, tokenLimitsOnlyContext()), /cosmos unavailable/);
});

test("a budget refusal stands even if the concurrent registry read fails", async () => {
  const deps = fakeReads({
    readBudgetState: async () => null,
    readBackend: async () => {
      throw new Error("cosmos unavailable");
    },
  });
  const result = await resolveRequest(input, deps, context());
  assert.equal(result.refused, true);
  assert.equal(result.reason, "budget_state_missing");
});

// ---- checkBackendRecord ----

test("each authentication mode is rebuilt with exactly its own fields, so nothing else reaches the gateway", () => {
  const cases: Array<[unknown, unknown]> = [
    [
      { mode: "managed-identity", resource: "api://00000000-0000-4000-8000-000001101100", clientSecret: "not-returned" },
      { mode: "managed-identity", resource: "api://00000000-0000-4000-8000-000001101100" },
    ],
    [
      { mode: "credential-manager", providerId: "Validation-entra", connectionId: "foundry-sample-hub", extra: 1 },
      { mode: "credential-manager", providerId: "Validation-entra", connectionId: "foundry-sample-hub" },
    ],
    [{ mode: "backend-entity", headers: { "api-key": "not-returned" } }, { mode: "backend-entity" }],
  ];
  for (const [auth, expected] of cases) {
    const verdict = checkBackendRecord({ ...managedIdentityBackend, auth, notes: "x" }, "foundry-sample-hub");
    assert.deepEqual(verdict, {
      kind: "active",
      descriptor: { id: "foundry-sample-hub", apiFormat: "anthropic-messages", auth: expected },
    });
  }
});

test("a managed-identity resource is an https URL, an api:// URI or a GUID", () => {
  for (const resource of [
    "https://cognitiveservices.azure.com",
    "https://cognitiveservices.azure.com/",
    "api://00000000-0000-4000-8000-000001101100",
    "api://ccof-resolver-api",
    "00000000-0000-4000-8000-000001101100",
  ]) {
    const verdict = checkBackendRecord({ ...managedIdentityBackend, auth: { mode: "managed-identity", resource } }, "foundry-sample-hub");
    assert.equal(verdict.kind, "active", resource);
  }
  for (const resource of [
    "http://cognitiveservices.azure.com",
    "cognitiveservices.azure.com",
    "https://",
    "https://cognitiveservices.azure.com\"><x/>",
    "api://",
    "api://a b",
    "c5880110-bdd4-41d3-805a-6ba1b68ff2a",
    "",
    42,
    undefined,
  ]) {
    const verdict = checkBackendRecord({ ...managedIdentityBackend, auth: { mode: "managed-identity", resource } }, "foundry-sample-hub");
    assert.deepEqual(verdict, { kind: "invalid", detail: "invalid_auth" }, String(resource));
  }
});

test("credential-manager names follow the identifier pattern", () => {
  for (const [providerId, connectionId] of [
    ["Validation entra", "c1"],
    ["-Validation", "c1"],
    ["Validation", ""],
    ["Validation", "x".repeat(81)],
    ["Validation", undefined],
  ]) {
    const verdict = checkBackendRecord(
      { ...managedIdentityBackend, auth: { mode: "credential-manager", providerId, connectionId } },
      "foundry-sample-hub",
    );
    assert.deepEqual(verdict, { kind: "invalid", detail: "invalid_auth" }, `${providerId}/${connectionId}`);
  }
});

test("every malformed registry document names its problem", () => {
  const cases: Array<[Record<string, unknown>, string]> = [
    [{ ...managedIdentityBackend, backendId: "foundry-other" }, "backend_id_mismatch"],
    [{ ...managedIdentityBackend, id: "foundry-other" }, "backend_id_mismatch"],
    [{ ...managedIdentityBackend, status: "Active" }, "invalid_status"],
    [{ ...managedIdentityBackend, status: undefined }, "invalid_status"],
    [{ ...managedIdentityBackend, apiFormat: undefined }, "invalid_api_format"],
    [{ ...managedIdentityBackend, auth: undefined }, "invalid_auth_mode"],
    [{ ...managedIdentityBackend, auth: "managed-identity" }, "invalid_auth_mode"],
    [{ ...managedIdentityBackend, auth: { mode: "client-secret", secret: "x" } }, "invalid_auth_mode"],
    [{ ...managedIdentityBackend, auth: { mode: "Managed-Identity", resource: "https://cognitiveservices.azure.com" } }, "invalid_auth_mode"],
  ];
  for (const [record, detail] of cases) {
    assert.deepEqual(checkBackendRecord(record, "foundry-sample-hub"), { kind: "invalid", detail }, detail);
  }
  assert.deepEqual(checkBackendRecord("not an object", "foundry-sample-hub"), { kind: "invalid", detail: "not_an_object" });
});

test("a disabled document is reported as not active, whatever its other fields", () => {
  assert.deepEqual(checkBackendRecord({ ...managedIdentityBackend, status: "disabled", auth: null }, "foundry-sample-hub"), {
    kind: "not_active",
  });
});

test("no document is the legacy path", () => {
  assert.deepEqual(checkBackendRecord(null, "foundry-sample-hub"), { kind: "legacy" });
});

// ---- the HTTP layer ----

function runtime(reads: ResolveDependencies, logs: string[]): ResolverRuntime {
  return {
    readiness: { ready: true, budgetEnforcement: { mode: "token-limits-only" }, requestDeadlineMs: 5000, reads },
    now: () => RESOLVE_NOW,
    log: (line) => logs.push(line),
  };
}

const authenticated = { platformAuthEnabled: true, authenticatedPrincipal: true };

test("the 200 body carries the descriptor when the registry has one, and none on the legacy path", async () => {
  const withDescriptor = await handleResolveRequest(
    { ...authenticated, body: input },
    runtime(withBackend(managedIdentityBackend).deps, []),
  );
  assert.equal(withDescriptor.status, 200);
  assert.deepEqual(withDescriptor.jsonBody.backend, {
    id: "foundry-sample-hub",
    apiFormat: "anthropic-messages",
    auth: { mode: "managed-identity", resource: "https://cognitiveservices.azure.com" },
  });
  assert.equal(withDescriptor.jsonBody.backendId, "foundry-sample-hub");

  const legacy = await handleResolveRequest({ ...authenticated, body: input }, runtime(fakeReads(), []));
  assert.equal(legacy.status, 200);
  assert.equal("backend" in legacy.jsonBody, false);
});

test("a disabled backend is a collapsed 403 not_authorized; the log names backend_not_active", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: input },
    runtime(withBackend({ ...managedIdentityBackend, status: "disabled" }).deps, logs),
  );
  assert.equal(response.status, 403);
  assert.deepEqual(response.jsonBody, { error: "not_authorized", resolverOutcome: "refused" });
  assert.equal(JSON.parse(logs[0]).reason, "backend_not_active");
});

test("a malformed registry document is 503 temporarily_unavailable; the log names the problem", async () => {
  const logs: string[] = [];
  const response = await handleResolveRequest(
    { ...authenticated, body: input },
    runtime(withBackend({ ...managedIdentityBackend, auth: { mode: "client-secret" } }).deps, logs),
  );
  assert.equal(response.status, 503);
  assert.deepEqual(response.jsonBody, { error: "temporarily_unavailable", resolverOutcome: "unavailable" });
  const event = JSON.parse(logs[0]);
  assert.equal(event.reason, "backend_record_invalid");
  assert.equal(event.detail, "invalid_auth_mode");
});
