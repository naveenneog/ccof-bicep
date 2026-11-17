import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (name: string) => readFileSync(new URL(`../.github/workflows/${name}`, import.meta.url), "utf8").replace(/\r\n/g, "\n");
const deploy = () => read("deploy-environment.yml");
const step = () => read("ccof-step.yml");
const drift = () => read("drift-check.yml");

// Splits the top-level jobs: map into job id -> job text (two-space indented keys under "jobs:").
function jobs(text: string): Map<string, string> {
  const body = text.slice(text.indexOf("\njobs:\n") + 7);
  const out = new Map<string, string>();
  let id = "";
  for (const line of body.split("\n")) {
    const m = /^ {2}([a-z0-9-]+):\s*$/.exec(line);
    if (m) { id = m[1]; out.set(id, ""); continue; }
    if (id) out.set(id, `${out.get(id)}${line}\n`);
  }
  return out;
}

test("CICD workflows sign in with the runner managed identity only", () => {
  for (const text of [deploy(), step(), drift()].map((t) => t.replace(/^\s*#.*$/gm, ""))) {
    assert.doesNotMatch(text, /azure\/login|id-token|secrets\.|client-secret|AZURE_CLIENT_SECRET|pull_request_target|federated/i);
  }
  const s = step();
  const login = s.indexOf("uses: ./.github/actions/azure-login-mi");
  assert.ok(login > 0, "ccof-step signs in through azure-login-mi");
  assert.ok(login < s.indexOf("Sync-CicdState.ps1 -Action Restore"), "sign-in before state restore");
  assert.ok(login < s.indexOf("run: ./scripts/cicd/Test-CicdPrerequisites.ps1"), "sign-in before the prerequisite checks");
  assert.ok(login < s.indexOf("& ./scripts/cicd/Invoke-CicdDriver.ps1"), "sign-in before the driver");
  assert.ok(s.indexOf("run: ./scripts/cicd/Test-CicdPrerequisites.ps1") > 0 && s.indexOf("& ./scripts/cicd/Invoke-CicdDriver.ps1") > 0);
  // A child "pwsh file.ps1" receives an array as separate positional strings; -Scope must bind in-process.
  assert.doesNotMatch(s, /run: pwsh [^\n]*-split/);
  assert.match(s, /expected-role: \$\{\{ env\.CCOF_EXPECTED_ROLE \}\}/);
  assert.match(s, /if: always\(\)[^\n]*\n\s+uses: \.\/\.github\/actions\/azure-login-mi\n\s+with:\n\s+mode: logout/);
  assert.match(drift(), /if: always\(\)\n\s+uses: \.\/\.github\/actions\/azure-login-mi\n\s+with:\n\s+mode: logout/);
});

test("ccof-step lands on the apply runner only outside pull requests and inside a GitHub environment", () => {
  const s = step();
  const runsOn = /runs-on: (.+)\n/.exec(s)?.[1] ?? "";
  assert.match(runsOn, /^\$\{\{ \(inputs\.runner == 'apply' && github\.event_name != 'pull_request' && inputs\.gh_environment != ''\) && fromJSON\('\["self-hosted","ccof-vnet","ccof-apply"\]'\) \|\| fromJSON\('\["self-hosted","ccof-vnet","ccof-preview"\]'\) \}\}$/);
  assert.match(s, /CCOF_EXPECTED_ROLE: \$\{\{ \(inputs\.runner == 'apply' && github\.event_name != 'pull_request' && inputs\.gh_environment != ''\) && 'apply' \|\| 'preview' \}\}/);
  assert.match(s, /environment: \$\{\{ inputs\.gh_environment \}\}/);
  assert.match(s, /if \(\$writes -and \$env:GITHUB_EVENT_NAME -eq 'pull_request'\) \{ throw/);
  assert.match(s, /if \(\$writes -and \$g -cnotmatch "\^\$e-\(apply\|gate-\[a-z\]\+\)\$"\) \{ throw/);
  assert.doesNotMatch(s, /^permissions:/m, "called workflow inherits (never raises) the caller token");
  assert.match(s, /persist-credentials: \$\{\{ github\.event_name != 'pull_request' \}\}/);
  assert.match(s, /if: always\(\) && inputs\.save_state && github\.event_name != 'pull_request'/);
  // Untrusted inputs reach scripts only through environment variables.
  for (const run of s.split(/\n\s+run: /).slice(1)) {
    const block = run.split(/\n\s+- /)[0];
    assert.doesNotMatch(block, /\$\{\{\s*inputs\./, `inline input in run block: ${block.slice(0, 80)}`);
  }
});

test("deploy-environment: pull requests are read-only on the preview runner", () => {
  const text = deploy();
  assert.match(text, /concurrency:\n\s+group: ccof-env-\$\{\{ github\.event_name == 'pull_request' && format\('pr-\{0\}', github\.event\.pull_request\.number\) \|\| inputs\.environment \}\}\n\s+cancel-in-progress: false/);
  assert.match(text, /^permissions:\n\s+contents: read/m);
  const j = jobs(text);
  assert.match(j.get("pr-environments") ?? "", /github\.event\.pull_request\.head\.repo\.full_name == github\.repository/);
  const pr = j.get("pr-checks") ?? "";
  assert.match(pr, /runner: preview/);
  assert.doesNotMatch(pr, /runner: apply|apply: true|save_state|gh_environment|contents: write/);
  for (const [id, body] of j) {
    if (id.startsWith("pr-")) continue;
    assert.match(body, /if: .*(github\.event_name == 'workflow_dispatch'|inputs\.scope|inputs\.apply)/, `${id} is dispatch-only`);
  }
});

test("deploy-environment: every write runs on the apply runner in <env>-apply or a named gate", () => {
  const j = jobs(deploy());
  const writers = [...j].filter(([, b]) => /apply: true/.test(b));
  assert.ok(writers.length >= 20, `found ${writers.length} apply jobs`);
  for (const [id, body] of writers) {
    assert.match(body, /runner: apply/, `${id} runner`);
    assert.match(body, /gh_environment: '\$\{\{ inputs\.environment \}\}-(apply|gate-(entra|network|privatelink|security|frontdoor))'/, `${id} environment`);
    assert.match(body, /if: \$\{\{ !cancelled\(\) && !failure\(\) && inputs\.apply/, `${id} needs apply input and no failed ancestor`);
    assert.match(body, /save_state: true|test_notification: true/, `${id} saves state`);
  }
  for (const [id, body] of j) {
    if (/runner: apply/.test(body)) assert.match(body, /gh_environment: '\$\{\{ inputs\.environment \}\}-/, `${id} on the apply runner without environment`);
  }
  const gates: Record<string, string> = {
    "gate-network": "gate-network", "gate-entra": "gate-entra", "fd-primary-approve-apply": "gate-privatelink",
    "standby-shells-apply": "gate-security", "standby-network-apply": "gate-network", "gate-standby-handoff": "gate-privatelink",
    "fd-full-deploy-apply": "gate-frontdoor", "fd-full-approve-apply": "gate-privatelink", "dr-bootstrap-apply": "gate-network",
  };
  for (const [id, gate] of Object.entries(gates)) assert.match(j.get(id) ?? "", new RegExp(`-${gate}'`), `${id} uses ${gate}`);
});

test("deploy-environment: run order, stage 4 manual, no manual-only operation", () => {
  const text = deploy();
  const order = ["resolve", "prereqs", "gate-network", "stage0", "stage1-apply", "stage3-apply", "stage4-preview", "gate-entra", "stage5-apply", "stage7-apply",
    "fd-primary-deploy-apply", "fd-primary-verify", "dr-discover", "dr-bootstrap-apply", "standby-data-apply", "standby-shells-apply", "standby-grants-apply",
    "standby-config-apply", "standby-network-apply", "gate-standby-handoff", "standby-code-apply", "standby-verify", "fd-full-verify", "health-a-apply", "health-b-apply", "health-test", "final"];
  const at = order.map((id) => text.indexOf(`\n  ${id}:\n`));
  at.forEach((p, i) => assert.ok(p > 0, `${order[i]} exists`));
  for (let i = 1; i < at.length; i++) assert.ok(at[i] > at[i - 1], `${order[i]} after ${order[i - 1]}`);
  const j = jobs(text);
  for (const [id, body] of j) {
    if (id === "resolve" || id.startsWith("pr-")) continue;
    assert.match(body, /needs: ([a-z0-9-]+|\[resolve, [a-z0-9-]+\])\n/, `${id} has one predecessor`);
  }
  assert.match(j.get("gate-entra") ?? "", /step: staged-4, apply: true/);
  for (const [, body] of j) assert.doesNotMatch(body, /step: (staged-8|frontdoor-(Lockdown|DrainPrimary|RestorePrimary)|failover-(Promote|Fence|Failback))/);
  assert.match(j.get("fd-primary-approve-apply") ?? "", /inputs\.fd_reviewed_ids != ''/);
  assert.match(j.get("fd-full-deploy-apply") ?? "", /approve: StandbyReady/);
  assert.match(j.get("standby-network-apply") ?? "", /approve: PrivateNetworkChanges/);
  assert.match(j.get("resolve") ?? "", /required_reviewers/);
  assert.match(j.get("resolve") ?? "", /deployment_branch_policy/);
  // A full (two-region) Front Door makes the driver refuse -PrimaryOnly; reruns skip the primary-only jobs.
  assert.match(j.get("resolve") ?? "", /fd_mode: \$\{\{ steps\.fdmode\.outputs\.mode \}\}/);
  for (const [id, body] of j) {
    if (id.startsWith("fd-primary-")) assert.match(body, /needs: \[resolve, [^\n]*\n\s+if: [^\n]*needs\.resolve\.outputs\.fd_mode != 'full'/, `${id} skipped after a full Front Door`);
  for (const id of ["health-b-preview", "health-b-apply"]) assert.match(j.get(id) ?? "", /needs: \[resolve, [^\n]*\n\s+if: [^\n]*needs\.resolve\.outputs\.health_b == 'true'/, `${id} runs only when health-b.json exists`);
  assert.match(j.get("health-test") ?? "", /fromJSON\(needs\.resolve\.outputs\.health_b == 'true'/, "health-test matrix follows health-b.json");
  }
  // failover-Status needs the standby state; only scopes that build or keep the standby run it.
  const fin = j.get("final") ?? "";
  assert.match(fin, /\(inputs\.scope == 'all' \|\| inputs\.scope == 'standby' \|\| inputs\.scope == 'frontdoor-full'\) && 'failover-Status'/);
  assert.match(fin, /inputs\.scope == 'frontdoor-primary' && 'primary,frontdoor'/);
});

test("drift-check is read-only: previews only, no save, issue on drift", () => {
  const text = drift();
  assert.match(text, /schedule:/);
  assert.match(text, /environment: \$\{\{ matrix\.environment \}\}-preview/);
  assert.match(text, /expected-role: apply/);
  assert.match(text, /Get-CicdDrift\.ps1/);
  assert.match(text, /issues: write/);
  assert.doesNotMatch(text, /-Apply|Action Save|apply: true|-TestNotification/);
  assert.match(text, /persist-credentials: false/);
  assert.match(text, /CCOF_STATE_TOKEN: \$\{\{ github\.token \}\}\n\s+run: pwsh scripts\/cicd\/Sync-CicdState\.ps1 -Action Restore/);
  // The report and issue steps have no always(); the preview loop must not end with a driver exit code.
  assert.match(text, /PREVIEW_FAILED=[^\n]*\n(\s*#[^\n]*\n)?\s+exit 0\n/);
  assert.match(step(), /CCOF_STATE_TOKEN: \$\{\{ github\.event_name == 'pull_request' && github\.token \|\| '' \}\}/);
});
