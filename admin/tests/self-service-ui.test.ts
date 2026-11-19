import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { join } from "node:path";
import { build } from "esbuild";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

test("operation controls disable only the denied feature and explain its exact grant", async () => {
  const directory = await mkdtemp(fileURLToPath(new URL("./.self-service-ui-", import.meta.url)));
  try {
    const output = join(directory, "view.mjs");
    await build({
      entryPoints: [fileURLToPath(new URL("../ui-v3/components/self-service.tsx", import.meta.url))],
      outfile: output, bundle: true, packages: "external", platform: "node", format: "esm", jsx: "automatic", logLevel: "silent",
    });
    const { OperationActions, OperationProgress } = await import(pathToFileURL(output).href);
    const capabilities = {
      "publish-routing": { state: "permission_required", reason: "missing_action", requirements: [{ action: "Microsoft.ApiManagement/service/backends/write", scope: "/approved/apim-A" }] },
      apply: { state: "available", requirements: [] },
    };
    const html = renderToStaticMarkup(React.createElement(OperationActions, { capabilities, readOnly: false, busy: false, onSelect: () => {} }));
    assert.match(html, /disabled=""[^>]*>Publish routing|disabled=""[^>]*>.*?Publish routing/s);
    assert.match(html, /backends\/write/);
    assert.match(html, /\/approved\/apim-A/);
    assert.match(html, /<button(?![^>]*disabled)[^>]*>Apply now<\/button>/);
    const reader = renderToStaticMarkup(React.createElement(OperationActions, { capabilities, readOnly: true, busy: false, onSelect: () => {} }));
    assert.doesNotMatch(reader, /<button(?![^>]*disabled)[^>]*>Apply now<\/button>/);
    const progress = renderToStaticMarkup(React.createElement(OperationProgress, { job: { state: "running", phase: "sync_requested" } }));
    assert.match(progress, /not completed/i);
    assert.doesNotMatch(progress, /Configuration is applied/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
