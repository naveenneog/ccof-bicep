import { strict as assert } from "node:assert";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";

const file = new URL("../infra/workbook/assignments.json", import.meta.url);
// Built-in role ids (az role definition list --name, 2026-10-11). Read-only roles only.
const builtIn: Record<string, string> = {
  "Workbook Reader": "b279062a-9be3-42a0-92ae-8b3cf002ec4d",
  "Log Analytics Reader": "73c42c96-874c-492b-b04d-ab87d138a893",
};

test("D3 data grants workbook readers read-only access to the workbook and its workspace, nothing else", () => {
  assert.ok(existsSync(file), "infra/workbook/assignments.json");
  const data = JSON.parse(readFileSync(file, "utf8"));
  assert.deepEqual(Object.keys(data).sort(), ["assignments", "cosmosRoleDefinitions", "kind", "package", "schemaVersion"]);
  assert.equal(data.schemaVersion, 1);
  assert.equal(data.kind, "ccof.assignments");
  assert.equal(data.package, "WP-WB");
  assert.deepEqual(data.cosmosRoleDefinitions, []);
  const scopes = Object.fromEntries(data.assignments.map((a: { role: string; scope: string }) => [a.role, a.scope]));
  assert.deepEqual(scopes, { "Workbook Reader": "${d1.workbook.id}", "Log Analytics Reader": "${d1.workspace.id}" });
  const ids = data.assignments.map((a: { id: string }) => a.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const a of data.assignments) {
    assert.deepEqual(Object.keys(a).sort(), ["id", "plane", "principals", "role", "roleDefinitionId", "scope", "why"]);
    assert.match(a.id, /^workbook-[a-z-]+$/);
    assert.equal(a.plane, "azure-rbac");
    assert.equal(a.principals, "${answers.permissions.workbookReaderPrincipalIds}");
    assert.equal(a.roleDefinitionId, builtIn[a.role], a.role);
    assert.ok(typeof a.why === "string" && a.why.length > 20);
  }
});
