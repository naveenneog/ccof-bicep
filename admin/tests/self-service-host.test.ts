import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { app } from "@azure/functions";

test("the Functions host mounts self-service before legacy asset loading and leaves default-off timers absent", async () => {
  const routes = new Map<string, any>();
  const timers: string[] = [];
  const http = app.http;
  const timer = app.timer;
  const readFile = fs.readFile;
  let reads = 0;
  app.http = ((name: string, registration: unknown) => { routes.set(name, registration); }) as typeof app.http;
  app.timer = ((name: string) => { timers.push(name); }) as typeof app.timer;
  process.env.ADMIN_V3_ENABLED = "true";
  process.env.ADMIN_ROUTING_PUBLISH_ENABLED = "false";
  process.env.ADMIN_APPLY_ENABLED = "false";
  process.env.ADMIN_HISTORY_ENABLED = "false";
  delete process.env.COSMOS_ENDPOINT;
  try {
    await import("../src/function-app.ts");
    fs.readFile = (async () => { reads++; throw new Error("packaged_assets_unavailable"); }) as typeof fs.readFile;
    syncBuiltinESMExports();
    const request = (path: string) => ({
      method: "GET", url: `https://admin.test${path}`, headers: new Headers(), params: {},
    });
    const context = { log() {}, error() {} };
    const handler = routes.get("adminV3").handler;
    const response = await handler(request("/api/v3/self-service/capabilities"), context);
    assert.equal(response.status, 503);
    assert.equal(reads, 0, "self-service authentication must not depend on unrelated packaged assets");
    assert.deepEqual(timers, []);
    await handler(request("/api/v3/projects"), context);
    assert.ok(reads > 0, "unrelated routes must retain the existing dispatcher");
  } finally {
    app.http = http;
    app.timer = timer;
    fs.readFile = readFile;
    syncBuiltinESMExports();
  }
});
