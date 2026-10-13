// The gateway's D3 assignment data: docs/DEPLOYMENT-STAGES.md (wp/core), "D3 assignment data".
// Role assignments are data that D3 applies; resource-creation Bicep and the deploy script hold none.

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, test } from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const file = path.join(repoRoot, "infra", "gateway", "assignments.json");

describe("gateway D3 assignment data", () => {
  // Read inside each test: an error while describing would report zero tests and still exit 0.
  const load = () => {
    const text = readFileSync(file, "utf8");
    return { text, doc: JSON.parse(text) };
  };

  test("is a ccof.assignments document of WP-GW with no Cosmos roles", () => {
    const { doc } = load();
    assert.equal(doc.schemaVersion, 1);
    assert.equal(doc.kind, "ccof.assignments");
    assert.equal(doc.package, "WP-GW");
    assert.deepEqual(doc.cosmosRoleDefinitions, []);
  });

  test("grants APIM's identity Cognitive Services User on each managed-identity backend's Foundry account, and nothing else", () => {
    const { doc } = load();
    assert.equal(doc.assignments.length, 1);
    const [grant] = doc.assignments;
    assert.equal(grant.id, "gw-apim-foundry-user");
    assert.equal(grant.plane, "azure-rbac");
    assert.equal(grant.principal, "${d1.apim.principalId}");
    assert.equal(grant.principalType, "ServicePrincipal");
    assert.equal(grant.role, "Cognitive Services User");
    assert.equal(grant.roleDefinitionId, "a97b65f3-24c7-4388-baec-2e87135dc908");
    // D3 expands it per managed-identity backend (WP-CORE 5e27bb1); shape B has none, so it makes none.
    assert.equal(grant.forEach, "answers.backends");
    assert.equal(grant.where, "backendMode == managed-identity");
    assert.equal(grant.scope, "${item.foundryAccountResourceId}");
    assert.equal(grant.scopes, undefined);
    assert.equal(grant.runtime, undefined, "no D2 step waits for it: the policy deploys and its smoke test runs without Foundry");
    assert.ok(typeof grant.why === "string" && grant.why.length > 0);
  });

  test("carries no secret, subscription, tenant or other environment literal", () => {
    const { text } = load();
    const guids = text.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi) ?? [];
    assert.deepEqual(guids, ["a97b65f3-24c7-4388-baec-2e87135dc908"], "the only GUID is the built-in role definition");
    assert.doesNotMatch(text, /\/subscriptions\//);
    assert.doesNotMatch(text, /secret/i);
  });
});
