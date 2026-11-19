import { test } from "node:test";
import assert from "node:assert/strict";
import { createRoutingArmProvider, readRoutingTargets, RoutingProviderError } from "../src/self-service-routing-arm.ts";

const A = "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-a";
const token = { async getToken(scope: string) { assert.equal(scope, "https://management.azure.com/.default"); return { token: "offline", expiresOnTimestamp: 9999999999999 }; } };

test("strict approved APIM targets cannot turn into URLs, path traversal, query strings or partial fallback", () => {
  assert.deepEqual(readRoutingTargets({ ADMIN_GATEWAY_RESOURCE_ID: A }), [A]);
  assert.throws(() => readRoutingTargets({ ADMIN_GATEWAY_RESOURCE_ID: `${A},${A}-b` }));
  assert.deepEqual(readRoutingTargets({ ADMIN_GATEWAY_RESOURCE_IDS: `${A},${A}-b`, ADMIN_GATEWAY_RESOURCE_ID: A }), [A, `${A}-b`]);
  for (const bad of [`https://evil.example${A}`, `${A}?x=y`, `${A}/../other`, `${A},`, `${A},${A}`, A.replace("/rg/", "/../"), A.replace("/rg/", "/./")]) {
    assert.throws(() => readRoutingTargets({ ADMIN_GATEWAY_RESOURCE_IDS: bad }));
    assert.throws(() => readRoutingTargets({ ADMIN_GATEWAY_RESOURCE_IDS: bad, ADMIN_GATEWAY_RESOURCE_ID: A }));
  }
});

test("ARM permission evaluation respects notActions; GET-only grants do not prove write", async () => {
  const provider = createRoutingArmProvider(token, [A], async (url, init) => {
    assert.equal(new URL(String(url)).host, "management.azure.com");
    assert.equal(init?.redirect, "error");
    assert.ok(init?.signal);
    assert.match(String(url), /providers\/Microsoft.Authorization\/permissions/);
    return Response.json({ value: [{ actions: ["Microsoft.ApiManagement/*"], notActions: ["*/write"] }] });
  });
  assert.equal(await provider.permitted(A, "Microsoft.ApiManagement/service/backends/read"), true);
  assert.equal(await provider.permitted(A, "Microsoft.ApiManagement/service/backends/write"), false);
});

test("ARM sends only approved backend IDs to fixed host, never follows redirects, and reports exact denied scope", async () => {
  const calls: string[] = [];
  const provider = createRoutingArmProvider(token, [A], async (url, init) => {
    calls.push(String(url));
    assert.equal(init?.redirect, "error"); assert.ok(init?.signal);
    return new Response("", { status: init?.method === "PUT" ? 403 : 404 });
  });
  assert.equal(await provider.backend(A, "foundry-a"), null);
  await assert.rejects(() => provider.putBackend(A, "ccof-pool-project-r2", { properties: { type: "Pool" } }),
    (e: unknown) => e instanceof RoutingProviderError && e.status === 403 && e.scope === A && e.action.endsWith("/write"));
  for (const [scope, id] of [[`${A}-other`, "foundry-a"], [A, "../evil"], [A, "x?api-version=bad"]]) {
    await assert.rejects(() => provider.backend(scope, id));
  }
  assert.equal(calls.length, 2);
});

test("ARM does not accept a mismatched resource identity even when the response URL/configuration looks correct", async () => {
  const provider = createRoutingArmProvider(token, [A], async () => Response.json({
    id: `${A}-other/backends/foundry-a`, name: "foundry-a", properties: { protocol: "http" },
  }));
  await assert.rejects(() => provider.backend(A, "foundry-a"));
});

test("ARM permission 401/403 names the permission-read action and scope; redirects fail closed", async () => {
  for (const status of [401, 403, 302]) {
    let calls = 0;
    const provider = createRoutingArmProvider(token, [A], async (_url, init) => {
      calls++;
      assert.equal(init?.redirect, "error");
      return new Response("", { status, headers: { location: "https://evil.example/steal" } });
    });
    await assert.rejects(() => provider.permitted(A, "Microsoft.ApiManagement/service/backends/write"),
      (e: unknown) => e instanceof RoutingProviderError && e.status === status &&
        e.action === "Microsoft.Authorization/permissions/read" && e.scope === A);
    assert.equal(calls, 1);
  }
});
