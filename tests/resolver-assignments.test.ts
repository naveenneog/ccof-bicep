// The resolver's role and data-plane assignments as data (docs/PILOT.md C-9,
// stage D3), in WP-CORE's ccof.assignments format (docs/DEPLOYMENT-STAGES.md
// on wp/core): D3 resolves the placeholders and applies them; no
// resource-creation template embeds them. The file names principals and
// scopes only through D1 checkpoint keys and answers, and grants the least
// each identity needs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

interface Assignment {
  id: string;
  plane: "azure-rbac" | "cosmos-data" | "graph-app-role";
  principal: string;
  principalType?: string;
  role: string;
  roleDefinitionId: string;
  scope: string;
  runtime?: boolean;
  why: string;
}

const file = JSON.parse(readFileSync(new URL("../infra/poc/resolver-auth.assignments.json", import.meta.url), "utf8")) as {
  schemaVersion: number;
  kind: string;
  package: string;
  cosmosRoleDefinitions: unknown[];
  assignments: Assignment[];
};

// Built-in role names and their ids, as D3 checks them.
const AZURE_ROLES: Record<string, string> = {
  "Storage Blob Data Owner": "b7e6dc6d-f1e8-4753-8033-0f276bb0955b",
  "Monitoring Metrics Publisher": "3913510d-42f4-4e42-8a64-420c390055eb",
};
const RESOLVER_PRINCIPAL = "${d1.apps.resolver.principalId}";

test("the file is a ccof.assignments file of WP-RES, version 1, with no custom Cosmos role", () => {
  assert.equal(file.schemaVersion, 1);
  assert.equal(file.kind, "ccof.assignments");
  assert.equal(file.package, "WP-RES");
  assert.deepEqual(file.cosmosRoleDefinitions, []);
});

test("every assignment is the resolver's own identity, with a unique id and a reason", () => {
  const ids = file.assignments.map((a) => a.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const a of file.assignments) {
    assert.equal(a.principal, RESOLVER_PRINCIPAL, a.id);
    assert.ok(a.why.length > 0, a.id);
  }
});

test("scopes come from D1 keys and answers, never from literal ids or names", () => {
  for (const a of file.assignments) {
    if (a.plane === "cosmos-data") assert.match(a.scope, /^\/dbs\/\$\{answers\.names\.cosmosDatabase\}$/, a.id);
    else assert.match(a.scope, /^\$\{d1\.apps\.resolver\.[A-Za-z]+\}$/, a.id);
    assert.doesNotMatch(JSON.stringify(a), /REPLACE-id|REPLACE-id|23b606df|sample-pilot/, a.id);
  }
});

test("the resolver reads Cosmos with the data-plane Reader role, never Contributor", () => {
  const cosmos = file.assignments.filter((a) => a.plane === "cosmos-data");
  assert.deepEqual(
    cosmos.map((a) => [a.role, a.roleDefinitionId]),
    [["Cosmos DB Built-in Data Reader", "00000000-0000-0000-0000-000000000001"]],
  );
  assert.ok(!JSON.stringify(file).includes("00000000-0000-0000-0000-000000000002"));
});

test("Azure roles are the documented built-in roles, named and identified consistently", () => {
  const rbac = file.assignments.filter((a) => a.plane === "azure-rbac");
  assert.deepEqual(rbac.map((a) => [a.role, a.scope]).sort(), [
    ["Monitoring Metrics Publisher", "${d1.apps.resolver.appInsightsId}"],
    ["Storage Blob Data Owner", "${d1.apps.resolver.storageAccountId}"],
  ]);
  for (const a of rbac) assert.equal(a.roleDefinitionId, AZURE_ROLES[a.role], a.id);
});

test("the grants the code needs to run are marked runtime, so D2's code step waits for them", () => {
  const runtime = file.assignments.filter((a) => a.runtime === true).map((a) => a.role).sort();
  assert.deepEqual(runtime, ["Cosmos DB Built-in Data Reader", "Storage Blob Data Owner"]);
});

test("APIM gets no Azure role on the resolver: its grant is the authentication allow-list (ADR-0009)", () => {
  assert.ok(!file.assignments.some((a) => /apim/i.test(a.principal)));
});
