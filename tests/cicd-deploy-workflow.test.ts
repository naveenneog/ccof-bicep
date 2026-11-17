import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

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
  assert.ok(s.includes(`if: ${SAVE_IF}\n`), "Save condition");
  // Untrusted inputs reach scripts only through environment variables.
  for (const run of s.split(/\n\s+run: /).slice(1)) {
    const block = run.split(/\n\s+- /)[0];
    assert.doesNotMatch(block, /\$\{\{\s*inputs\./, `inline input in run block: ${block.slice(0, 80)}`);
  }
});

test("deploy-environment: pull requests run offline on GitHub-hosted runners only", () => {
  const text = deploy();
  assert.match(text, /concurrency:\n\s+group: ccof-env-\$\{\{ github\.event_name == 'pull_request' && format\('pr-\{0\}', github\.event\.pull_request\.number\) \|\| inputs\.environment \}\}\n\s+cancel-in-progress: false\n\s+queue: max\n/);
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
  // An owner-set repository variable proves nothing about the plan; it must not reach the check.
  assert.doesNotMatch(text, /CCOF_GITHUB_PLAN/);
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

// Splits a job body into steps keyed by name (or id).
function steps(text: string): { name: string; body: string }[] {
  return text.split(/\n\s+- (?=name:|uses:|id:)/).slice(1).map((b) => ({ name: /^name: ([^\n]*)/.exec(b)?.[1] ?? b.slice(0, 40), body: b }));
}

const DRIVER_RAN = "(steps.driver.outcome == 'success' || steps.driver.outcome == 'failure' || steps.driver.outcome == 'cancelled')";
const SAVE_IF = `always() && steps.trusted.outcome == 'success' && steps.restore.outcome == 'success' && ${DRIVER_RAN} && inputs.save_state && inputs.step != ''`;
// Evaluates a step "if:" made only of always(), steps.<id>.outcome, inputs.save_state/step, ==, !=, &&, ||, () and
// quoted strings, for given step outcomes (GitHub sets 'skipped' for a step that did not start). Anything else throws.
function evalIf(expr: string, outcomes: Record<string, string>): boolean {
  const js = expr
    .replace(/always\(\)/g, "true")
    .replace(/steps\.([a-z]+)\.outcome/g, (_, id: string) => JSON.stringify(outcomes[id] ?? ""))
    .replace(/inputs\.save_state/g, "true").replace(/inputs\.step/g, "'driver-step'")
    .replace(/!=/g, "!==").replace(/([^!=])==(?!=)/g, "$1===");
  if (!/^(?:\s|true|"[a-z]*"|'[a-z-]*'|===|!==|&&|\|\||\(|\))*$/.test(js)) throw new Error(`unsupported if: ${expr}`);
  return Boolean(new Function(`return (${js});`)());
}
const saveIf = (text: string) => { const s = steps(text); return /\n\s+if: ([^\n]*)/.exec(s.find((x) => /^Save driver state/.test(x.name))?.body ?? "")?.[1] ?? ""; };
// Step outcomes of one job: [scenario, outcomes, must save]. 'skipped' = never started.
const OK = { trusted: "success", restore: "success" };
const SAVE_CASES: [string, Record<string, string>, boolean][] = [
  ["prerequisite checks fail before the driver", { ...OK, driver: "skipped" }, false],
  ["build (npm ci/tsc) fails before the driver", { ...OK, driver: "skipped" }, false],
  ["job cancelled before the driver started", { ...OK, driver: "skipped" }, false],
  ["restore failed", { trusted: "success", restore: "failure", driver: "skipped" }, false],
  ["untrusted call", { trusted: "skipped", restore: "skipped", driver: "skipped" }, false],
  ["driver id missing (outcome unknown)", { ...OK }, false],
  ["driver failed after a successful restore (partial state)", { ...OK, driver: "failure" }, true],
  ["driver cancelled while running (partial state)", { ...OK, driver: "cancelled" }, true],
  ["driver succeeded", { ...OK, driver: "success" }, true],
];
// Returns the reasons a ccof-step text could save state after a failed restore (or skip saving after a failed driver).
function saveProblems(text: string): string[] {
  const s = steps(text);
  const idx = (re: RegExp) => s.findIndex((x) => re.test(x.name));
  const out: string[] = [];
  const r = idx(/^Restore driver state/), sv = idx(/^Save driver state/), d = idx(/^Driver /);
  if (r < 0 || sv < 0 || d < 0) return ["restore, driver or save step missing"];
  if (!/\n\s+id: restore\n/.test(s[r].body)) out.push("Restore has no id restore");
  if ((text.match(/\n\s+id: restore\n/g)?.length ?? 0) !== 1) out.push("id restore not unique");
  if ((/\n\s+if: ([^\n]*)/.exec(s[sv].body)?.[1] ?? "") !== SAVE_IF) out.push("Save condition differs");
  for (const re of [/^Trusted call/, /^Runner host preflight/, /^Guard inputs/, /^Azure sign-in/]) if (!(idx(re) >= 0 && idx(re) < r)) out.push(`${re} not before Restore`);
  const co = s.findIndex((x) => /uses: actions\/checkout@v4/.test(x.body));
  if (!(co >= 0 && co < r)) out.push("checkout not before Restore");
  if (!(r < d && d < sv)) out.push("order must be Restore < Driver < Save");
  if (!/\n\s+id: driver\n/.test(s[d].body) || (text.match(/\n\s+id: driver\n/g)?.length ?? 0) !== 1) out.push("Driver has no unique id driver");
  const pb = s.findIndex((x) => /^(Prerequisite checks|Build )/.test(x.name));
  if (s.filter((x) => /^(Prerequisite checks|Build )/.test(x.name)).some((x) => s.indexOf(x) > d)) out.push("prerequisite/build after Driver");
  if (pb < 0) out.push("prerequisite/build steps missing");
  try { for (const [name, o, want] of SAVE_CASES) if (evalIf(saveIf(text), o) !== want) out.push(`save ${want ? "skipped" : "runs"}: ${name}`); }
  catch (e) { out.push(String(e)); }
  return out;
}

test("ccof-step: driver state is saved only after a successful restore, and still after a failed driver", () => {
  assert.deepEqual(saveProblems(step()), []);
});

test("ccof-step save check: negative controls (each unsafe mutation is detected)", () => {
  const s = step();
  const mut: [string, string][] = [
    ["drop restore outcome", s.replace(" && steps.restore.outcome == 'success'", "")],
    ["drop always()", s.replace("if: always() && steps.trusted.outcome == 'success' && steps.restore", "if: steps.trusted.outcome == 'success' && steps.restore")],
    ["!= failure", s.replace("steps.restore.outcome == 'success'", "steps.restore.outcome != 'failure'")],
    ["drop id", s.replace(/\n\s+id: restore\n/, "\n")],
    ["duplicate id", s.replace(/(\n\s+)id: trusted\n/, "$1id: restore\n")],
    ["drop driver started (old 4cc7d75 condition)", s.replace(` && ${DRIVER_RAN}`, "")],
    ["driver != skipped (empty outcome passes)", s.replace(DRIVER_RAN, "steps.driver.outcome != 'skipped'")],
    ["driver success only (no partial save)", s.replace(DRIVER_RAN, "steps.driver.outcome == 'success'")],
    ["drop driver id", s.replace(/\n\s+id: driver\n/, "\n")],
    ["save before driver", s.replace(/(\n\s+- name: Driver [\s\S]*?)(\n\s+- name: Save driver state[\s\S]*?)(\n\s+- name: Upload evidence)/, "$2$1$3")],
  ];
  for (const [name, text] of mut) {
    assert.notEqual(text, s, `${name}: mutation applied`);
    assert.ok(saveProblems(text).length > 0, `${name}: detected`);
  }
});
const APPROVAL_IF = "inputs.gh_environment != '' && inputs.gh_environment != format('{0}-preview', inputs.environment)";
// Returns the reasons a ccof-step text could write (or sign in to Azure) in a reviewed environment without proving
// this job's own approval first (Assert-CicdJobApproval.ps1 + ledger artifact).
function approvalProblems(text: string): string[] {
  const s = steps(text);
  const idx = (re: RegExp) => s.findIndex((x) => re.test(x.name));
  const out: string[] = [];
  const a = idx(/^Approval of this job$/), l = idx(/^Record the approval as used/), login = idx(/^Azure sign-in/), r = idx(/^Restore driver state/), d = idx(/^Driver /);
  const co = s.findIndex((x) => /uses: actions\/checkout@v4/.test(x.body));
  if (a < 0 || l < 0 || login < 0 || d < 0 || r < 0) return ["approval, ledger, sign-in, restore or driver step missing"];
  const A = s[a].body, L = s[l].body;
  if (!/\n\s+id: approval\n/.test(A) || (text.match(/\n\s+id: approval\n/g)?.length ?? 0) !== 1) out.push("approval step id");
  if ((/\n\s+if: ([^\n]*)/.exec(A)?.[1] ?? "") !== APPROVAL_IF) out.push("approval condition differs");
  if (!/\n\s+run: pwsh scripts\/cicd\/Assert-CicdJobApproval\.ps1 -Environment \$env:CCOF_ENV -GitHubEnvironment \$env:CCOF_GH_ENV -JobKey \$env:CCOF_JOB_KEY(\n|$)/.test(A)) out.push("approval command");
  if (!/\n\s+GH_TOKEN: \$\{\{ github\.token \}\}\n/.test(A)) out.push("approval token");
  if ((/\n\s+if: ([^\n]*)/.exec(L)?.[1] ?? "") !== "steps.approval.outcome == 'success'") out.push("ledger condition differs");
  if (!/uses: actions\/upload-artifact@v4\n/.test(L) || !/name: '\$\{\{ steps\.approval\.outputs\.ledger \}\}'/.test(L) || !/if-no-files-found: error/.test(L)) out.push("ledger upload");
  if (!(co >= 0 && co < a && a < l && l < login && login < r && r < d)) out.push("order must be checkout < approval < ledger < sign-in < restore < driver");
  for (const x of s.slice(a, d + 1)) {
    if (/continue-on-error/.test(x.body)) out.push(`${x.name}: continue-on-error`);
    if (/\n\s+if: [^\n]*(always\(\)|failure\(\)|cancelled\(\))/.test(x.body)) out.push(`${x.name}: runs after a failed approval`);
  }
  const D = s[d].body;
  if (!/CCOF_APPROVAL_LEDGER: \$\{\{ steps\.approval\.outputs\.ledger \}\}/.test(D)) out.push("driver lacks the ledger");
  if (!D.includes("if (($env:CCOF_APPLY -eq 'true' -or $env:CCOF_TEST_NOTIFICATION -eq 'true') -and -not $env:CCOF_APPROVAL_LEDGER) { throw")) out.push("driver write guard");
  if (/actions\/runs\/[^\n]*approvals/.test(uncomment(text))) out.push("run-level approvals read outside the assertion script");
  return out;
}

test("ccof-step: every reviewed job proves its own approval before Azure sign-in and any write", () => {
  assert.deepEqual(approvalProblems(step()), []);
});

test("ccof-step approval check: negative controls (each unsafe mutation is detected)", () => {
  const s = step();
  const mut: [string, string][] = [
    ["approval only for apply", s.replace(`if: ${APPROVAL_IF}`, "if: inputs.apply")],
    ["continue-on-error", s.replace(/(\n(\s+)id: approval\n)/, "$1$2continue-on-error: true\n")],
    ["ledger always", s.replace("if: steps.approval.outcome == 'success'", "if: always()")],
    ["drop ledger upload", s.replace(/\n\s+- name: Record the approval as used[\s\S]*?(?=\n\s+- name: Azure sign-in)/, "")],
    ["sign-in before approval", s.replace(/(\n\s+- name: Approval of this job[\s\S]*?)(\n\s+- name: Azure sign-in[\s\S]*?)(\n\s+- name: Restore driver state)/, "$2$1$3")],
    ["drop driver guard", s.replace("if (($env:CCOF_APPLY -eq 'true' -or $env:CCOF_TEST_NOTIFICATION -eq 'true') -and -not $env:CCOF_APPROVAL_LEDGER) { throw", "if ($false) { throw")],
    ["log-only approvals back", s.replace("- name: Azure sign-in", "- name: Log\n        run: Invoke-RestMethod \"$env:GITHUB_API_URL/repos/x/actions/runs/1/approvals\"\n\n      - name: Azure sign-in")],
    ["wrong token", s.replace(/(id: approval\n[\s\S]*?)GH_TOKEN: \$\{\{ github\.token \}\}/, "$1GH_TOKEN: ${{ vars.X }}")],
  ];
  for (const [name, text] of mut) {
    assert.notEqual(text, s, `${name}: mutation applied`);
    assert.ok(approvalProblems(text).length > 0, `${name}: detected`);
  }
});

// Jobs of deploy-environment.yml that can run at the same time as another job of the same reviewed environment.
// One review approves every job waiting on that environment, so such jobs would share one approval (the ledger
// count would then refuse one of them, or both would pass on a single review).
function concurrentReviewed(text: string): string[] {
  const j = jobs(text);
  const needs = new Map<string, string[]>();
  for (const [id, b] of j) {
    const m = /\n {4}needs: (\[[^\]]*\]|[a-z0-9-]+)\n/.exec(`\n${b}`);
    needs.set(id, m ? m[1].replace(/[[\]]/g, "").split(",").map((x) => x.trim()).filter(Boolean) : []);
  }
  const anc = (id: string, seen = new Set<string>()): Set<string> => {
    for (const n of needs.get(id) ?? []) if (!seen.has(n)) { seen.add(n); anc(n, seen); }
    return seen;
  };
  const env = (b: string) => /gh_environment: '\$\{\{ inputs\.environment \}\}-((?:apply|gate-[a-z]+))'/.exec(b)?.[1];
  const reviewed = [...j].filter(([, b]) => env(b));
  const out: string[] = [];
  for (const [id, b] of reviewed) if (/\n\s+matrix:/.test(b) && !/\n\s+max-parallel: 1\n/.test(b)) out.push(`${id}: matrix without max-parallel: 1`);
  for (let x = 0; x < reviewed.length; x++) for (let y = x + 1; y < reviewed.length; y++) {
    const [a, ab] = reviewed[x], [b, bb] = reviewed[y];
    if (env(ab) === env(bb) && !anc(a).has(b) && !anc(b).has(a)) out.push(`${a} and ${b} (${env(ab)})`);
  }
  return out;
}

test("deploy-environment: no two jobs of one reviewed environment can wait for review together", () => {
  assert.deepEqual(concurrentReviewed(deploy()), []);
  const d = deploy();
  const mut: [string, string][] = [
    ["matrix in parallel", d.replace(/\n\s+max-parallel: 1\n/, "\n")],
    ["health-b apply not after health-a apply", d.replace("needs: [resolve, health-a-apply]", "needs: [resolve, fd-full-verify]")],
  ];
  for (const [name, text] of mut) {
    assert.notEqual(text, d, `${name}: mutation applied`);
    assert.ok(concurrentReviewed(text).length > 0, `${name}: detected`);
  }
});

test("drift-check: each matrix environment holds the shared ccof-env-<env> group; no self-deadlock, no cancellation", () => {
  const text = drift();
  const top = /^concurrency:\n\s+group: ([^\n]+)\n\s+cancel-in-progress: ([^\n]+)/m.exec(text);
  assert.ok(top, "workflow-level concurrency");
  assert.doesNotMatch(top[1], /ccof-env/i, "the workflow-level group must not be a ccof-env group (the drift job would wait on its own run)");
  assert.equal(top[2], "false");
  const j = jobs(text).get("drift") ?? "";
  assert.match(j, /\n {4}concurrency:\n {6}group: ccof-env-\$\{\{ matrix\.environment \}\}\n {6}cancel-in-progress: false\n {6}queue: max\n/, "drift job joins ccof-env-<env>");
  assert.ok(j.indexOf("concurrency:") < j.indexOf("steps:"), "job-level, not a step");
  for (const t of [text, deploy(), step()]) assert.doesNotMatch(uncomment(t), /cancel-in-progress: true/);
  // The deployment holds ccof-env-<env> at workflow level; a job-level ccof-env group in ccof-step (called by it) would deadlock.
  assert.doesNotMatch(uncomment(step()), /concurrency:/, "ccof-step sets no concurrency (inherits the caller's run lock)");
  // Same group string shape as deploy-environment (group names are case-insensitive; prefix must match exactly).
  // Every ccof-env-<env> holder (deploy, drift job; onboard-foundry on A-t1's branch) uses queue: max, so a pending
  // deployment is not replaced by a later pending run or drift job (GitHub default "single"). Never with cancel-in-progress true.
  assert.match(text, /\n {4}concurrency:\n {6}group: ccof-env-\$\{\{ matrix\.environment \}\}\n {6}cancel-in-progress: false\n {6}queue: max\n/, "drift job queues");
  assert.match(deploy(), /^concurrency:\n {2}group: ccof-env-[^\n]+\n {2}cancel-in-progress: false\n {2}queue: max\n/m, "deploy run queues");
  for (const t of [text, deploy(), step()]) for (const m of uncomment(t).matchAll(/\n\s*queue: ([^\n]*)/g)) assert.equal(m[1], "max", "only queue: max");
  assert.match(deploy(), /group: ccof-env-\$\{\{ github\.event_name == 'pull_request' && format\('pr-\{0\}', github\.event\.pull_request\.number\) \|\| inputs\.environment \}\}/);
});

// Paths owned by A-runner (feat/cicd-runner-oidc); this branch depends on that branch merging first.
const RUNNER_OWNED = new Set(["scripts/cicd/Test-RunnerHost.sh", "scripts/cicd/Test-RunnerHost.ps1", ".github/actions/azure-login-mi"]);

test("every script and local action referenced by the CICD workflows exists (A-runner paths allowlisted)", () => {
  const refs = new Set<string>();
  for (const text of [deploy(), step(), drift()]) {
    for (const line of text.split("\n")) {
      if (/^\s*(#|paths:)/.test(line)) continue;
      for (const m of line.matchAll(/(?:\.\/)?((?:scripts|infra)\/[A-Za-z0-9_./-]+\.(?:ps1|sh|psm1))/g)) refs.add(m[1]);
      const u = /uses:\s*\.\/([A-Za-z0-9_./-]+)/.exec(line);
      if (u) refs.add(u[1]);
    }
  }
  assert.ok(refs.size >= 8, `found ${refs.size} references`);
  const missing = [...refs].filter((r) => !RUNNER_OWNED.has(r) && !existsSync(new URL(`../${r}`, import.meta.url)));
  assert.deepEqual(missing, [], `missing workflow references: ${missing.join(", ")}`);
  for (const r of RUNNER_OWNED) assert.ok(refs.has(r), `allowlisted ${r} is still referenced`);
});