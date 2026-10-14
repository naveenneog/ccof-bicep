import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const workflow = () => readFileSync(new URL("../.github/workflows/public-ci.yml", import.meta.url), "utf8");

test("public CI tests branch and PR merge candidates without live Azure credentials", () => {
  const text = workflow();
  assert.match(text, /pull_request:/);
  assert.match(text, /push:/);
  assert.match(text, /permissions:\s*\n\s+contents: read/);
  assert.match(text, /persist-credentials: false/);
  assert.match(text, /CCOF_LIVE_TESTS: ['"]0['"]/);
  assert.doesNotMatch(text, /azure\/login|secrets\.|id-token:\s*write|pull_request_target/);
});

test("public CI runs the exact complete test command plus builds and all tracked Bicep", () => {
  const text = workflow();
  assert.match(text, /npm ci --ignore-scripts --no-audit --no-fund/);
  assert.match(text, /run: npm test/);
  assert.match(text, /tsconfig\.typecheck\.json/);
  assert.match(text, /tsconfig\.json/);
  assert.match(text, /git ls-files '\*\.bicep'/);
  assert.match(text, /az bicep build --file/);
  assert.match(text, /dotnet-version: ['"]10\.0\.x['"]/);
  assert.match(text, /node: \[['"]22['"], ['"]26['"]\]/);
  assert.doesNotMatch(text, /continue-on-error|npm test.*\|\||az bicep build.*\|\|/);
});
