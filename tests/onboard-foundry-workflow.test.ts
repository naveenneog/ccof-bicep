import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const workflow = () => readFileSync(new URL("../.github/workflows/onboard-foundry.yml", import.meta.url), "utf8").replace(/\r\n/g, "\n");

// The text of one job: from "  <name>:" to the next two-space job key.
function job(text: string, name: string): string {
  const jobs = text.slice(text.indexOf("\njobs:\n"));
  const start = jobs.indexOf(`\n  ${name}:\n`);
  assert.ok(start >= 0, `job ${name} exists`);
  const rest = jobs.slice(start + 1);
  const next = rest.slice(1).search(/\n {2}[a-z][a-z-]*:\n/);
  return next < 0 ? rest : rest.slice(0, next + 1);
}

test("onboard-foundry signs in with the runner managed identity only", () => {
  const text = workflow();
  assert.doesNotMatch(text, /azure\/login|secrets\.|id-token|pull_request_target|client-secret|AZURE_CLIENT_ID/);
  assert.match(text, /^permissions:\n {2}contents: read$/m);
  for (const name of ["validate", "preview", "gate-privatelink", "apply"]) {
    const body = job(text, name);
    assert.match(body, /uses: actions\/checkout@v4\n(?:.*\n)*? {6}- name: Runner host preflight\n {8}shell: bash\n {8}run: bash scripts\/cicd\/Test-RunnerHost\.sh/, `${name} runs the host preflight`);
    assert.match(body, /uses: \.\/\.github\/actions\/azure-login-mi\n {8}with:\n {10}expected-role: (preview|apply)/, `${name} signs in`);
    assert.match(body, /if: always\(\)\n {8}uses: \.\/\.github\/actions\/azure-login-mi\n {8}with:\n {10}mode: logout/, `${name} signs out`);
  }
});

test("pull requests stay on the read-only preview runner and never write", () => {
  const text = workflow();
  const validate = job(text, "validate");
  assert.match(validate, /runs-on: \[self-hosted, ccof-vnet, ccof-preview\]/);
  assert.match(validate, /expected-role: preview/);
  assert.match(validate, /persist-credentials: false/);
  assert.doesNotMatch(validate, /-Apply|Action Save|\n {4}environment:/);
  for (const name of ["preview", "apply"]) {
    const body = job(text, name);
    assert.match(body, /runs-on: \[self-hosted, ccof-vnet, ccof-apply\]/);
    assert.match(body, /github\.ref == 'refs\/heads\/main'/, `${name} runs only from main`);
  }
  assert.match(job(text, "preview"), /if: github\.event_name == 'workflow_dispatch'/);
  assert.match(job(text, "gate-privatelink"), /runs-on: \[self-hosted, ccof-vnet, ccof-preview\]/);
  assert.equal(text.match(/ccof-apply\]/g)?.length, 2, "only preview and apply use the apply runner");
});

test("every apply-runner job runs inside its GitHub environment and only apply saves state", () => {
  const text = workflow();
  assert.match(job(text, "preview"), /environment: \$\{\{ needs\.validate\.outputs\.environment \}\}-preview/);
  assert.match(job(text, "gate-privatelink"), /environment: \$\{\{ needs\.validate\.outputs\.environment \}\}-gate-privatelink/);
  const apply = job(text, "apply");
  assert.match(apply, /environment: \$\{\{ needs\.validate\.outputs\.environment \}\}-apply/);
  assert.match(apply, /permissions:\n {6}contents: write/);
  assert.match(apply, /if: always\(\)\n {8}run: pwsh scripts\/cicd\/Sync-CicdState\.ps1 -Action Save/);
  assert.match(apply, /needs\.gate-privatelink\.result == 'success' \|\| needs\.gate-privatelink\.result == 'skipped'/);
  assert.match(apply, /if: failure\(\)\n {8}run: \|\n {10}Import-Module \.\/scripts\/cicd\/CicdOnboarding\.psm1/);
  assert.equal(text.match(/-Action Save/g)?.length, 1, "previews and the gate never save state");
  assert.match(text, /group: .*format\('ccof-env-\{0\}', inputs\.environment\)/);
  assert.match(text, /cancel-in-progress: false/);
});

test("apply runs region A, then region B, then the descriptor and the smoke test", () => {
  const apply = job(workflow(), "apply");
  const order = ["'validate'; RequirePrivateLink = \\$true", "'stage3'", "'stage5'", "'stage6'", "'standby-backends'", "'standby-verify'", "'frontdoor-verify'", "'descriptor'", "'smoke'"];
  let at = -1;
  for (const step of order) {
    const found = apply.search(new RegExp(`Step = ${step}`));
    assert.ok(found > at, `${step} follows the previous step`);
    at = found;
  }
  assert.doesNotMatch(workflow(), /-Stage 7|stage7|-Stage 8|stage8|Invoke-StagedDeployment/);
  assert.match(apply, /throw "\$\(\$p\.Step\) failed/);
});
