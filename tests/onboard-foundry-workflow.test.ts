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

// The steps of one job, split at "      - " (six spaces).
function steps(body: string): string[] {
  return body.split(/\n(?= {6}- )/).filter((s) => s.startsWith("      - "));
}

// A self-hosted job runs the Linux preflight (.sh, bash) only on Linux, the Windows preflight (.ps1, pwsh,
// no Bash) only on Windows, fails on any other OS, all before its first Azure sign-in; Bash appears nowhere else.
function preflightProblems(body: string): string[] {
  const problems: string[] = [];
  const all = steps(body);
  const signIn = all.findIndex((s) => s.includes("azure-login-mi"));
  const linux = all.findIndex((s) => /\n {8}if: runner\.os == 'Linux'\n {8}shell: bash\n {8}run: bash scripts\/cicd\/Test-RunnerHost\.sh\n?$/.test(s));
  const windows = all.findIndex((s) => /\n {8}if: runner\.os == 'Windows'\n {8}shell: pwsh\n {8}run: pwsh -NoProfile -File scripts\/cicd\/Test-RunnerHost\.ps1\n?$/.test(s));
  const other = all.findIndex((s) => /\n {8}if: runner\.os != 'Linux' && runner\.os != 'Windows'\n {8}shell: pwsh\n(?:.*\n)*? {10}exit 1/.test(s));
  if (linux < 0) problems.push("no Linux-only bash preflight");
  if (windows < 0) problems.push("no Windows-only pwsh preflight");
  if (other < 0) problems.push("no failing step for other OSes");
  if (signIn < 0 || [linux, windows, other].some((i) => i < 0 || i > signIn)) problems.push("preflight not before sign-in");
  all.forEach((s, i) => { if (i !== linux && /bash|\.sh\b/.test(s)) problems.push(`bash outside the Linux preflight: ${s.split("\n")[0]}`); });
  return problems;
}

test("onboard-foundry signs in with the runner managed identity only", () => {
  const text = workflow();
  assert.doesNotMatch(text, /azure\/login|secrets\.|id-token|pull_request_target|client-secret|AZURE_CLIENT_ID/);
  assert.match(text, /^permissions:\n {2}contents: read$/m);
  for (const name of ["validate", "preview", "gate-privatelink", "apply"]) {
    const body = job(text, name);
    assert.deepEqual(preflightProblems(body), [], `${name} runs the host preflight for its OS`);
    assert.match(body, /uses: \.\/\.github\/actions\/azure-login-mi\n {8}with:\n {10}expected-role: (preview|apply)/, `${name} signs in`);
    assert.match(body, /if: always\(\)\n {8}uses: \.\/\.github\/actions\/azure-login-mi\n {8}with:\n {10}mode: logout/, `${name} signs out`);
  }
});

test("pull request code never runs on a self-hosted runner or gets a managed identity", () => {
  const text = workflow();
  const pr = job(text, "pr-check");
  assert.match(pr, /if: github\.event_name == 'pull_request'\n {4}runs-on: ubuntu-latest\n/);
  assert.match(pr, /persist-credentials: false/);
  assert.match(pr, /-Step validate -BaseConfigPath \$base -Offline/);
  assert.doesNotMatch(pr, /self-hosted|azure-login-mi|Sync-CicdState|environment:|-Apply|az /);
  const jobs = [...text.slice(text.indexOf("\njobs:\n")).matchAll(/\n {2}([a-z][a-z-]*):\n/g)].map((m) => m[1]);
  assert.deepEqual(jobs, ["pr-check", "validate", "preview", "gate-privatelink", "apply"]);
  for (const name of jobs.filter((n) => n !== "pr-check")) {
    const body = job(text, name);
    assert.match(body, /runs-on: \[self-hosted, ccof-vnet, ccof-(preview|apply)\]/, `${name} is self-hosted`);
    assert.match(body, /\n {4}if: (?:>-\n {6})?.*github\.ref == 'refs\/heads\/main'/, `${name} runs only from main`);
    assert.match(body, /\n {4}environment: \$\{\{ [a-z.-]+ \}\}-(preview|gate-privatelink|apply)\n/, `${name} runs in a main-only GitHub environment`);
    assert.doesNotMatch(body, /pull_request'(?! \|\|)/, `${name} is not a pull request job`);
  }
  assert.match(job(text, "validate"), /if: github\.event_name == 'workflow_dispatch' && github\.ref == 'refs\/heads\/main'\n {4}runs-on: \[self-hosted, ccof-vnet, ccof-preview\]/);
  assert.match(job(text, "preview"), /if: github\.event_name == 'workflow_dispatch' && github\.ref == 'refs\/heads\/main'\n {4}runs-on: \[self-hosted, ccof-vnet, ccof-apply\]/);
  assert.match(job(text, "gate-privatelink"), /runs-on: \[self-hosted, ccof-vnet, ccof-preview\]/);
  assert.equal(text.match(/ccof-apply\]/g)?.length, 2, "only preview and apply use the apply runner");
});
// Job-level `if`, folded (>-) blocks joined; "" when the job has none.
function jobIf(body: string): string {
  const m = body.match(/\n {4}if: (>-\n((?: {6}.*\n)+)|.*\n)/);
  if (!m) return "";
  return (m[2] ?? m[1]).split("\n").map((l) => l.trim()).filter(Boolean).join(" ");
}

// Top-level && conjuncts of a GitHub expression (parenthesised groups stay whole).
function conjuncts(expr: string): string[] {
  const parts: string[] = [];
  let depth = 0, start = 0;
  for (let i = 0; i < expr.length; i++) {
    if (expr[i] === "(") depth++;
    else if (expr[i] === ")") depth--;
    else if (depth === 0 && expr.startsWith(" && ", i)) { parts.push(expr.slice(start, i).trim()); start = i + 4; }
  }
  parts.push(expr.slice(start).trim());
  return parts.filter(Boolean);
}

const DISPATCH = "github.event_name == 'workflow_dispatch'";
const MAIN = "github.ref == 'refs/heads/main'";

test("only pull_request and workflow_dispatch start it; nothing routes to another workflow", () => {
  const text = workflow();
  const on = text.slice(text.indexOf("\non:\n") + 5, text.indexOf("\npermissions:\n"));
  const triggers = [...on.matchAll(/^ {2}([a-z_]+):/gm)].map((m) => m[1]);
  assert.deepEqual(triggers, ["pull_request", "workflow_dispatch"]);
  assert.doesNotMatch(text, /\.github\/workflows\/[^\s]*\.ya?ml|workflow_call|workflow_run|repository_dispatch|pull_request_target/,
    "no reusable workflow or chained trigger can carry branch code to the private runners");
  for (const m of text.matchAll(/^\s+runs-on: (.*)$/gm)) assert.doesNotMatch(m[1], /\$\{\{/, "runs-on is static");
});

test("a job reachable from a pull request is GitHub-hosted; self-hosted jobs require dispatch on main", () => {
  const text = workflow();
  const names = [...text.slice(text.indexOf("\njobs:\n")).matchAll(/\n {2}([a-z][a-z-]*):\n/g)].map((m) => m[1]);
  let hosted = 0;
  for (const name of names) {
    const body = job(text, name);
    const runsOn = body.match(/\n {4}runs-on: (.*)\n/)?.[1] ?? "";
    const c = conjuncts(jobIf(body));
    const dispatchOnly = c.includes(DISPATCH) && c.includes(MAIN);
    if (/self-hosted/.test(runsOn)) {
      assert.ok(dispatchOnly, `${name}: self-hosted job needs top-level '${DISPATCH} && ${MAIN}' (got '${jobIf(body)}')`);
      assert.match(body, /\n {4}environment: /, `${name}: self-hosted job runs in a GitHub environment`);
    } else {
      assert.equal(runsOn, "ubuntu-latest", `${name}: a job not limited to dispatch on main is GitHub-hosted`);
      assert.doesNotMatch(body, /azure-login-mi|Sync-CicdState|Test-RunnerHost|\n {4}environment:/, `${name}: no identity, state or environment`);
      hosted++;
    }
  }
  assert.equal(hosted, 1, "only pr-check is GitHub-hosted");
});

test("the condition checks reject reachable self-hosted jobs (negative controls)", () => {
  assert.deepEqual(conjuncts(`always() && ${DISPATCH} && ${MAIN} && (a || b)`), ["always()", DISPATCH, MAIN, "(a || b)"]);
  for (const bad of [`${MAIN}`, `${DISPATCH} || ${MAIN}`, `(${DISPATCH} || x) && ${MAIN}`, `inputs.apply && ${MAIN}`, ""]) {
    const c = conjuncts(bad);
    assert.ok(!(c.includes(DISPATCH) && c.includes(MAIN)), `'${bad}' must not count as dispatch-only`);
  }
  assert.equal(jobIf("\n    if: >-\n      always() && a\n      && b\n    runs-on: x\n"), "always() && a && b");
});

test("approval is verified with the job token before any Azure sign-in, in gate and apply", () => {
  const text = workflow();
  const before = (body: string, a: string, b: string) => {
    const i = body.indexOf(a), j = body.indexOf(b);
    assert.ok(i >= 0 && j >= 0 && i < j, `'${a}' precedes '${b}'`);
  };
  const gate = job(text, "gate-privatelink");
  assert.match(gate, /\n {4}permissions:\n {6}contents: read\n {6}actions: read\n/);
  assert.match(gate, /CCOF_APPROVAL_TOKEN: \$\{\{ github\.token \}\}\n {8}run: pwsh scripts\/cicd\/Assert-CicdApproval\.ps1 -Environment \$env:CCOF_ENV -GitHubEnvironment "\$env:CCOF_ENV-gate-privatelink"/);
  before(gate, "Assert-CicdApproval.ps1", "azure-login-mi");
  const apply = job(text, "apply");
  assert.match(apply, /\n {4}permissions:\n {6}contents: write\n {6}actions: read\n/);
  assert.match(apply, /Assert-CicdApproval\.ps1 -Environment \$env:CCOF_ENV -GitHubEnvironment "\$env:CCOF_ENV-apply"\n {10}if \(\$LASTEXITCODE\) \{ exit \$LASTEXITCODE \}/);
  assert.match(apply, /if \(\$env:CCOF_GATE_NEEDED -eq 'true'\) \{\n {12}pwsh scripts\/cicd\/Assert-CicdApproval\.ps1 -Environment \$env:CCOF_ENV -GitHubEnvironment "\$env:CCOF_ENV-gate-privatelink"\n {12}exit \$LASTEXITCODE/);
  assert.match(apply, /CCOF_GATE_NEEDED: \$\{\{ needs\.validate\.outputs\.needs-privatelink-gate \}\}/);
  before(apply, "Assert-CicdApproval.ps1", "azure-login-mi");
  before(apply, "azure-login-mi", "Apply = $true");
  for (const name of ["pr-check", "validate", "preview"]) {
    assert.doesNotMatch(job(text, name), /actions: read|Assert-CicdApproval|CCOF_APPROVAL_TOKEN/, `${name} needs no approval API access`);
  }
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
  // Jobs without stored checkout credentials pass the job token; the apply job (which pushes state) must not
  // add it on top of the stored credentials: two Authorization headers are rejected.
  for (const name of ["validate", "preview", "gate-privatelink", "apply"]) {
    const body = job(text, name);
    const restore = body.match(/\n( {6}- name: Restore driver state[^\n]*\n(?: {8}[^\n]*\n)+)/)?.[1] ?? "";
    assert.match(restore, /Sync-CicdState\.ps1 -Action Restore/, `${name} restores state`);
    const stored = !/persist-credentials: false/.test(body);
    assert.equal(/CCOF_STATE_TOKEN: \$\{\{ github\.token \}\}/.test(restore), !stored, `${name}: token only without stored credentials`);
    assert.equal(stored, name === "apply", `${name}: only apply keeps checkout credentials`);
  }
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

test("the host preflight follows runner.os (negative controls)", () => {
  const text = workflow();
  assert.match(text, /^defaults:\n {2}run:\n {4}shell: pwsh$/m, "other steps use pwsh on Linux and Windows");
  const body = job(text, "apply");
  assert.deepEqual(preflightProblems(body), []);
  const mutants: Array<[string, string, RegExp]> = [
    ["unconditional bash", "        if: runner.os == 'Linux'\n        shell: bash", /no Linux-only bash preflight/],
    ["Windows step runs bash", "        shell: pwsh\n        run: pwsh -NoProfile -File scripts/cicd/Test-RunnerHost.ps1", /no Windows-only pwsh preflight/],
    ["Windows step on Linux", "        if: runner.os == 'Windows'", /no Windows-only pwsh preflight/],
    ["unsupported OS passes", "          exit 1", /no failing step for other OSes/],
  ];
  const replacement: Record<string, string> = {
    "unconditional bash": "        shell: bash",
    "Windows step runs bash": "        shell: bash\n        run: bash scripts/cicd/Test-RunnerHost.sh",
    "Windows step on Linux": "        if: runner.os == 'Linux'",
    "unsupported OS passes": "          exit 0",
  };
  for (const [name, find, expected] of mutants) {
    assert.ok(body.includes(find), `${name}: anchor present`);
    assert.match(preflightProblems(body.replace(find, replacement[name])).join(";"), expected, name);
  }
  const late = body.replace(/( {6}# The preflight matching the host OS[^\n]*\n(?: {6}- name: Runner host preflight[^\n]*\n(?: {8}[^\n]*\n| {10}[^\n]*\n)*)+)/, "");
  assert.notEqual(late, body, "preflight block found");
  assert.match(preflightProblems(late).join(";"), /no Linux-only/, "a job without preflight fails");
});