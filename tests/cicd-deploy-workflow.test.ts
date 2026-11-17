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

const TRUSTED = "(github.event_name == 'workflow_dispatch' || github.event_name == 'schedule') && inputs.gh_environment != ''";
const uncomment = (t: string) => t.replace(/^\s*#.*$/gm, "");

test("ccof-step: self-hosted only for dispatch or schedule inside an environment; any other call is GitHub-hosted and refused", () => {
  const s = step();
  const runsOn = /runs-on: (.+)\n/.exec(s)?.[1] ?? "";
  assert.equal(runsOn, `\${{ (${TRUSTED}) && (inputs.runner == 'apply' && fromJSON('["self-hosted","ccof-vnet","ccof-apply"]') || fromJSON('["self-hosted","ccof-vnet","ccof-preview"]')) || 'ubuntu-latest' }}`);
  assert.doesNotMatch(uncomment(s).replace(runsOn, ""), /"self-hosted"|\[self-hosted|runs-on:[^\n]*self-hosted/, "self-hosted labels only in the trusted branch of runs-on");
  const refuse = s.indexOf("- name: Refuse an untrusted call");
  assert.ok(refuse > 0 && refuse < s.indexOf("- uses: actions/checkout@v4"), "refusal runs before any repository code");
  assert.match(s.slice(refuse), new RegExp(`^- name: Refuse an untrusted call[^\\n]*\\n\\s+if: \\$\\{\\{ !\\(${TRUSTED.replace(/[()|.$]/g, "\\$&")}\\) \\}\\}\\n\\s+run: \\|\\n[^\\n]*\\n\\s+exit 1\\n`));
  assert.match(s, /CCOF_EXPECTED_ROLE: \$\{\{ inputs\.runner == 'apply' && 'apply' \|\| 'preview' \}\}/);
  assert.match(s, /environment: \$\{\{ inputs\.gh_environment \}\}/);
  assert.match(s, /if \(\$env:GITHUB_EVENT_NAME -notin 'workflow_dispatch', 'schedule'\) \{ throw/);
  assert.match(s, /if \(\$writes -and \$g -cnotmatch "\^\$e-\(apply\|gate-\[a-z\]\+\)\$"\) \{ throw/);
  assert.doesNotMatch(uncomment(s), /pull_request/, "no pull-request path in ccof-step");
  assert.doesNotMatch(s, /^permissions:/m, "called workflow inherits (never raises) the caller token");
  assert.match(s, /if: always\(\) && steps\.trusted\.outcome == 'success' && inputs\.save_state/);
  // Untrusted inputs reach scripts only through environment variables.
  for (const run of s.split(/\n\s+run: /).slice(1)) {
    const block = run.split(/\n\s+- /)[0];
    assert.doesNotMatch(block, /\$\{\{\s*inputs\./, `inline input in run block: ${block.slice(0, 80)}`);
  }
});

test("deploy-environment: pull requests run offline on GitHub-hosted runners only", () => {
  const text = deploy();
  assert.match(text, /concurrency:\n\s+group: ccof-env-\$\{\{ github\.event_name == 'pull_request' && format\('pr-\{0\}', github\.event\.pull_request\.number\) \|\| inputs\.environment \}\}\n\s+cancel-in-progress: false/);
  assert.match(text, /^permissions:\n\s+contents: read/m);
  assert.doesNotMatch(uncomment(text), /self-hosted|ccof-preview\]|ccof-apply\]/, "no job of deploy-environment names a self-hosted runner itself");
  const j = jobs(text);
  const pr = [...j].filter(([, b]) => /github\.event_name == 'pull_request'/.test(b));
  assert.deepEqual(pr.map(([id]) => id), ["pr-offline"]);
  const body = j.get("pr-offline") ?? "";
  assert.match(body, /runs-on: ubuntu-latest\n/);
  assert.match(body, /permissions: \{ contents: read \}/);
  assert.match(body, /persist-credentials: false/);
  assert.match(body, /Test-CicdPrerequisites\.ps1 [^\n]*-Offline -Mode preview/);
  assert.doesNotMatch(body, /azure-login-mi|Sync-CicdState|CCOF_STATE_TOKEN|ccof-step|uses: \.\/|GH_TOKEN|github\.token|secrets\./);
  for (const [id, b] of j) {
    assert.match(b, /runs-on: ubuntu-latest\n|uses: \.\/\.github\/workflows\/ccof-step\.yml\n/, `${id} is GitHub-hosted or goes through ccof-step`);
    if (id === "pr-offline") continue;
    assert.match(b, /if: .*(github\.event_name == 'workflow_dispatch'|inputs\.scope|inputs\.apply)/, `${id} is dispatch-only`);
    if (/uses: \.\/\.github\/workflows\/ccof-step\.yml/.test(b)) assert.match(b, /gh_environment: '\$\{\{ inputs\.environment \}\}-(preview|apply|gate-[a-z]+)'/, `${id} runs inside a GitHub environment`);
  }
  assert.doesNotMatch(text, /^\s+pull_request_target:|^\s+push:/m);
  const resolve = j.get("resolve") ?? "";
  assert.match(resolve, /runs-on: ubuntu-latest\n/, "the dispatch ref is checked before any self-hosted job");
  assert.doesNotMatch(resolve, /azure-login-mi/);
  assert.match(resolve, /& \.\/scripts\/cicd\/Test-CicdGitHubEnvironments\.ps1 -Repository \$env:GITHUB_REPOSITORY -Environment \$env:CCOF_ENV -ReviewedGate \$gates\n\s+exit \$LASTEXITCODE/);
  assert.match(resolve, /CCOF_GITHUB_PLAN: \$\{\{ vars\.CCOF_GITHUB_PLAN \}\}/);
});

test("runner host preflight matches the runner OS (bash on Linux, PowerShell on Windows)", () => {
  for (const [name, text] of [["ccof-step", step()], ["drift-check", drift()]]) {
    assert.match(text, /- name: Runner host preflight \(Linux\)\n\s+if: runner\.os != 'Windows'\n\s+shell: bash\n\s+run: bash scripts\/cicd\/Test-RunnerHost\.sh\n/, `${name} Linux`);
    assert.match(text, /- name: Runner host preflight \(Windows\)\n\s+if: runner\.os == 'Windows'\n\s+shell: pwsh\n\s+run: pwsh -NoProfile -File scripts\/cicd\/Test-RunnerHost\.ps1\n/, `${name} Windows`);
    for (const blk of text.split(/\n\s+- (?=name:|uses:)/)) if (/\n\s+shell: bash\n/.test(blk)) assert.match(blk, /\n\s+if: runner\.os != 'Windows'\n/, `${name}: bash step without an OS condition: ${blk.slice(0, 60)}`);
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

  // A full (two-region) Front Door makes the driver refuse -PrimaryOnly; reruns skip the primary-only jobs.
  assert.match(j.get("resolve") ?? "", /fd_mode: \$\{\{ steps\.fdmode\.outputs\.mode \}\}/);
  for (const [id, body] of j) {
    if (id.startsWith("fd-primary-")) assert.match(body, /needs: \[resolve, [^\n]*\n\s+if: [^\n]*needs\.resolve\.outputs\.fd_mode != 'full'/, `${id} skipped after a full Front Door`);
  for (const id of ["health-b-preview", "health-b-apply"]) assert.match(j.get(id) ?? "", /needs: \[resolve, [^\n]*\n\s+if: [^\n]*needs\.resolve\.outputs\.health_b == 'true'/, `${id} runs only when health-b.json exists`);
  assert.match(j.get("health-test") ?? "", /fromJSON\(needs\.resolve\.outputs\.health_b == 'true'/, "health-test matrix follows health-b.json");
  const resolve = j.get("resolve") ?? "";
  assert.match(resolve, /if \(\$hb -eq \$optOut\) \{ throw [^\n]*exactly one of health-b\.json[^\n]*health-b\.optout\.json/, "a DR environment needs health-b.json or an explicit opt-out");
  assert.match(resolve, /-in 'all', 'health' -and \(Test-Path "deploy\/\$e\/dr-standby\.config\.json"\)/, "region B requirement applies to DR environments in health scopes");
  assert.match(resolve, /::warning::NO REGION B HEALTH MONITORING[\s\S]*\*\*NO REGION B HEALTH MONITORING\*\*[^\n]*GITHUB_STEP_SUMMARY/, "the opt-out is a visible warning and summary line");
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
  assert.match(text, /Get-CicdDrift\.ps1 -LogDirectory "evidence\/\$env:CCOF_ENV" -ExpectedStep \$env:CCOF_EXPECTED_STEPS\n/);
  assert.match(text, /"CCOF_EXPECTED_STEPS=\$\(\$steps -join ','\)"/);
  assert.doesNotMatch(text, /-ExpectedLog/);
  assert.doesNotMatch(uncomment(text), /pull_request|push:/, "drift-check has no pull-request trigger");
  const j = jobs(text);
  assert.match(j.get("targets") ?? "", /runs-on: ubuntu-latest\n[\s\S]*Test-CicdGitHubEnvironments\.ps1 -Repository \$env:GITHUB_REPOSITORY -Environment \$e\n/, "environment names and branch policies proved on a GitHub-hosted runner");
  assert.match(j.get("drift") ?? "", /needs: targets\n[\s\S]*environment: \$\{\{ fromJSON\(needs\.targets\.outputs\.environments\) \}\}\n\s+runs-on: \[self-hosted, ccof-vnet, ccof-apply\]/);
  assert.match(text, /issues: write/);
  assert.doesNotMatch(text, /-Apply|Action Save|apply: true|-TestNotification/);
  assert.match(text, /persist-credentials: false/);
  assert.match(text, /CCOF_STATE_TOKEN: \$\{\{ github\.token \}\}\n\s+run: pwsh scripts\/cicd\/Sync-CicdState\.ps1 -Action Restore/);
  // The report and issue steps have no always(); the preview loop must not end with a driver exit code.
  assert.match(text, /PREVIEW_FAILED=[^\n]*\n(\s*#[^\n]*\n)?\s+exit 0\n/);
  assert.doesNotMatch(step(), /CCOF_STATE_TOKEN/);
});
