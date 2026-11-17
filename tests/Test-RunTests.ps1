#Requires -Version 7.0
# Offline checks for scripts/run-tests.ps1 (the `npm test` runner) with fixture suites: failure and exit-code
# semantics, fail-closed empty or missing suites and Bicep, output order, per-suite TEMP and logged-out Azure CLI
# profile isolation (Node included), parallel and sequential throttles, and short per-suite TEMP directories owned by
# the run, so suites work from a long Windows workspace (Git for Windows fails on paths over 260 characters).
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$runner = Join-Path $repo 'scripts/run-tests.ps1'
$pwshExe = (Get-Process -Id $PID).Path
$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++; Write-Host "ok   $Name" } else { $script:fail++; Write-Host "FAIL $Name" } }

$fixtureRoot = if ($env:CCOF_TEST_ROOT_TEMP) { $env:CCOF_TEST_ROOT_TEMP } else { [IO.Path]::GetTempPath() }
$base = Join-Path $fixtureRoot ('rt-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
$out = Join-Path $base 'out'
# The runner's own TEMP: the run creates its per-suite TEMP directories under it. The decoy must survive every run.
$sysTemp = Join-Path $base 's'
$decoy = Join-Path $sysTemp 'ccof-t-decoy'
New-Item -ItemType Directory -Path $out, $decoy | Out-Null
Set-Content -LiteralPath (Join-Path $decoy 'keep.txt') -Value 'not created by the runner'
function Get-RunTemps { @(Get-ChildItem -LiteralPath $sysTemp -Directory -Force | Where-Object FullName -ne $decoy) }

# Each fixture suite records its environment, writes a fixed-name file in TEMP, waits, and fails if another
# suite overwrote that file (shared TEMP).
$probe = @'
$name = Split-Path $PSCommandPath -LeafBase
$start = [DateTime]::UtcNow.Ticks
$file = Join-Path $env:TEMP 'same-name.txt'
Set-Content -LiteralPath $file -Value $name
Start-Sleep -Seconds 3
$seen = (Get-Content -LiteralPath $file -Raw).Trim()
[ordered]@{ name = $name; temp = $env:TEMP; rootTemp = $env:CCOF_TEST_ROOT_TEMP; cli = $env:AZURE_CONFIG_DIR; start = $start; end = [DateTime]::UtcNow.Ticks; seen = $seen;
    files = @(if ($env:AZURE_CONFIG_DIR -and (Test-Path $env:AZURE_CONFIG_DIR)) { Get-ChildItem -LiteralPath $env:AZURE_CONFIG_DIR -Recurse -File -Name }) } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:CCOF_RT_OUT "$name.json")
Write-Host "probe output from $name"
if ($seen -ne $name) { Write-Host "TEMP shared: $name saw $seen"; exit 1 }
'@

function New-Fixture([string]$Name, [hashtable]$Suites, [switch]$Bicep) {
    $dir = Join-Path $base $Name
    $tests = Join-Path $dir 'tests'; $cli = Join-Path $dir 'azure'
    New-Item -ItemType Directory -Path $tests, (Join-Path $cli 'bin') -Force | Out-Null
    foreach ($k in $Suites.Keys) { Set-Content -LiteralPath (Join-Path $tests "$k.ps1") -Value $Suites[$k] }
    Set-Content -LiteralPath (Join-Path $cli 'config') -Value "[core]`ncollect_telemetry = no"
    Set-Content -LiteralPath (Join-Path $cli 'msal_token_cache.json') -Value '{"fake":"not a token"}'
    Set-Content -LiteralPath (Join-Path $cli 'azureProfile.json') -Value '{"subscriptions":[]}'
    if ($Bicep) { Set-Content -LiteralPath (Join-Path $cli 'bin/bicep.exe') -Value 'fake'; Set-Content -LiteralPath (Join-Path $cli 'bin/bicep') -Value 'fake' }
    @{ tests = $tests; cli = $cli; scratch = (Join-Path $dir 'scratch') }
}
function Invoke-Runner($Fx, [string]$Throttle, [switch]$WithNode, [string]$Path = $env:PATH, [string]$TestsDir = $Fx.tests, [string]$Temp = $sysTemp) {
    Get-ChildItem -LiteralPath $out -File | Remove-Item -Force
    $saved = @{ t = $env:CCOF_TEST_THROTTLE; c = $env:AZURE_CONFIG_DIR; o = $env:CCOF_RT_OUT; p = $env:PATH; tmp = $env:TMP; temp = $env:TEMP }
    $env:CCOF_TEST_THROTTLE = $Throttle; $env:AZURE_CONFIG_DIR = $Fx.cli; $env:CCOF_RT_OUT = $out
    $extra = @(if (-not $WithNode) { '-NoNodeSuites' })
    try { $env:PATH = $Path; $env:TMP = $Temp; $env:TEMP = $Temp; $text = (& $pwshExe -NoProfile -File $runner -TestsDir $TestsDir -ScratchDir $Fx.scratch @extra *>&1 | Out-String); $code = $LASTEXITCODE }
    finally { $env:CCOF_TEST_THROTTLE = $saved.t; $env:AZURE_CONFIG_DIR = $saved.c; $env:CCOF_RT_OUT = $saved.o; $env:PATH = $saved.p; $env:TMP = $saved.tmp; $env:TEMP = $saved.temp }
    $rec = @{}; Get-ChildItem -LiteralPath $out -Filter '*.json' | ForEach-Object { $j = Get-Content -Raw $_.FullName | ConvertFrom-Json; $rec[$j.name] = $j }
    @{ code = $code; text = $text; rec = $rec }
}
function Test-Overlap($Rec, [string[]]$Names) {
    $r = @($Names | ForEach-Object { $Rec[$_] })
    for ($i = 0; $i -lt $r.Count; $i++) { for ($j = $i + 1; $j -lt $r.Count; $j++) { if ($r[$i].start -lt $r[$j].end -and $r[$j].start -lt $r[$i].end) { return $true } } }
    $false
}

try {
    # 1. Passing, failing, throwing and silently-crashing suites run together.
    $fx = New-Fixture 'mixed' @{
        'Test-A' = $probe; 'Test-B' = $probe; 'Test-C' = $probe
        'Test-Fail' = "Write-Host 'fail suite output'; exit 3"
        'Test-Throw' = "`$ErrorActionPreference = 'Stop'; throw 'fixture throw'"
    } -Bicep
    $r = Invoke-Runner $fx '4'
    Check 'a failing suite makes the run exit 1' ($r.code -eq 1)
    Check 'the exit-3 and throwing suites are both reported as failed' ($r.text -match 'SUITE FAILED: Test-Fail\.ps1 \(exit code 3\)' -and $r.text -match 'SUITE FAILED: Test-Throw\.ps1 \(exit code 1\)')
    Check 'the summary lists exactly the failed suites' ($r.text -match 'failed: Test-Fail\.ps1, Test-Throw\.ps1')
    $order = @([regex]::Matches($r.text, '=== (Test-\w+\.ps1) ===') | ForEach-Object { $_.Groups[1].Value })
    Check 'each suite is printed once, in name order' (($order -join ',') -ceq 'Test-A.ps1,Test-B.ps1,Test-C.ps1,Test-Fail.ps1,Test-Throw.ps1')
    Check 'suite output appears under its own header' ($r.text -match '(?s)=== Test-Fail\.ps1 ===\s+fail suite output' -and $r.text -match '(?s)=== Test-B\.ps1 ===\s+probe output from Test-B')
    Check 'all three probe suites ran and passed' ($r.rec.Count -eq 3 -and $r.text -notmatch 'SUITE FAILED: Test-[ABC]\.ps1')
    $temps = @($r.rec.Values | ForEach-Object temp | Sort-Object -Unique)
    Check 'each suite has its own TEMP' ($temps.Count -eq 3 -and -not ($r.rec.Values | Where-Object { $_.seen -ne $_.name }))
    Check 'nested runner fixtures receive the original TEMP root, not a per-suite TEMP' (@($r.rec.Values | Where-Object { -not $_.rootTemp -or $_.rootTemp.TrimEnd('\', '/') -ne $sysTemp.TrimEnd('\', '/') }).Count -eq 0)
    $clis = @($r.rec.Values | ForEach-Object cli | Sort-Object -Unique)
    Check 'each suite has its own Azure CLI profile, not the operator profile' ($clis.Count -eq 3 -and $clis -notcontains $fx.cli)
    $files = @($r.rec['Test-A'].files)
    Check 'the suite profile has the config and the Bicep binary' ($files -contains 'config' -and ($files -contains 'bin\bicep.exe' -or $files -contains 'bin/bicep.exe'))
    Check 'the suite profile has no token cache or account list' ($files -notcontains 'msal_token_cache.json' -and $files -notcontains 'azureProfile.json')
    Check 'suites ran in parallel with throttle 4' (Test-Overlap $r.rec 'Test-A', 'Test-B', 'Test-C')
    Check 'passing suites leave no scratch; the failed suites keep theirs' (-not (Get-ChildItem -LiteralPath $fx.scratch -Recurse -Directory -Filter 'Test-A') -and (Get-ChildItem -LiteralPath $fx.scratch -Recurse -Directory -Filter 'Test-Fail'))
    Check 'the operator profile is unchanged' (@(Get-ChildItem -LiteralPath $fx.cli -Recurse -File).Count -eq 5)
    $kept = [regex]::Match($r.text, 'SUITE FAILED: Test-Fail\.ps1 [^\r\n]*TEMP kept in (\S+)').Groups[1].Value
    Check 'a failed suite keeps its TEMP and reports where; a passing suite''s TEMP is removed' ($kept -and (Test-Path -LiteralPath $kept) -and
        $kept.StartsWith($sysTemp, [StringComparison]::OrdinalIgnoreCase) -and $r.rec['Test-A'].temp -and -not (Test-Path -LiteralPath $r.rec['Test-A'].temp))
    Get-RunTemps | Remove-Item -Recurse -Force

    # 2. All passing; throttle 1 runs one suite at a time.
    $fx = New-Fixture 'sequential' @{ 'Test-A' = $probe; 'Test-B' = $probe } -Bicep
    $r = Invoke-Runner $fx '1'
    Check 'all suites passing exits 0' ($r.code -eq 0 -and $r.text -match 'failed: none')
    Check 'throttle 1 runs the suites one at a time' ($r.rec.Count -eq 2 -and -not (Test-Overlap $r.rec 'Test-A', 'Test-B'))
    Check 'a clean run removes its scratch' (-not (Get-ChildItem -LiteralPath $fx.scratch -Directory -Filter 'run-*'))
    Check 'a clean run removes its own TEMP directory and nothing else there' ((Get-RunTemps).Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $decoy 'keep.txt')))

    # 3. No Bicep binary in the operator profile or on PATH: stop before any suite, never fall back to that profile.
    $fx = New-Fixture 'nobicep' @{ 'Test-A' = $probe; 'Test-B' = $probe }
    $r = Invoke-Runner $fx '4' -Path (Split-Path $pwshExe)
    Check 'without a Bicep binary the run exits 1 with the reason' ($r.code -eq 1 -and $r.text -match 'no Bicep binary')
    Check 'without a Bicep binary no suite runs against the operator profile' ($r.rec.Count -eq 0)

    # 4. Nothing to run is a failure, not a green run.
    $fx = New-Fixture 'empty' @{}
    $r = Invoke-Runner $fx '4' -WithNode
    Check 'an empty tests directory exits 1' ($r.code -eq 1 -and $r.text -match 'no Node suites')
    $r = Invoke-Runner $fx '4'
    Check 'zero PowerShell suites exits 1 even without Node suites' ($r.code -eq 1 -and $r.text -match 'no PowerShell suites')
    $r = Invoke-Runner $fx '4' -WithNode -TestsDir (Join-Path $base 'missing-dir')
    Check 'a missing tests directory exits 1' ($r.code -eq 1 -and $r.text -match 'tests directory not found')
    $fx = New-Fixture 'psonly' @{ 'Test-A' = $probe } -Bicep
    $r = Invoke-Runner $fx '4' -WithNode
    Check 'by default, missing Node suites fail the run' ($r.code -eq 1 -and $r.text -match 'no Node suites')

    # 5. Node suites run, their failure counts, and they also get an isolated profile.
    $nodeProbe = "import { test } from 'node:test'; import { writeFileSync } from 'node:fs'; import { join } from 'node:path';`ntest('probe', () => { writeFileSync(join(process.env.CCOF_RT_OUT!, 'node.json'), JSON.stringify({ name: 'node', cli: process.env.AZURE_CONFIG_DIR, temp: process.env.TEMP })); });`n"
    $fx = New-Fixture 'node' @{ 'Test-A' = $probe } -Bicep
    Set-Content -LiteralPath (Join-Path $fx.tests 'probe.test.ts') -Value $nodeProbe
    $r = Invoke-Runner $fx '4' -WithNode
    Check 'Node and PowerShell suites pass together' ($r.code -eq 0 -and $r.rec.ContainsKey('node') -and $r.rec.ContainsKey('Test-A'))
    Check 'the Node suites use an isolated profile, not the operator profile' ($r.rec['node'].cli -and $r.rec['node'].cli -ne $fx.cli -and $r.rec['node'].cli -ne $r.rec['Test-A'].cli)
    Set-Content -LiteralPath (Join-Path $fx.tests 'fail.test.ts') -Value "import { test } from 'node:test'; test('fails', () => { throw new Error('fixture'); });"
    $r = Invoke-Runner $fx '4' -WithNode
    Check 'a failing Node suite makes the run exit 1' ($r.code -eq 1 -and $r.text -match 'NODE SUITES FAILED')
    $nkept = [regex]::Match($r.text, 'NODE SUITES FAILED [^\r\n]*TEMP kept in (\S+)').Groups[1].Value
    Check 'a failed Node run keeps its TEMP under the runner TEMP and reports where' ($nkept -and (Test-Path -LiteralPath $nkept) -and $nkept.StartsWith((Join-Path $sysTemp 'ccof-t-'), [StringComparison]::OrdinalIgnoreCase))
    Get-RunTemps | Remove-Item -Recurse -Force

    # 6. A long workspace, like the deep Git worktree of the packet gate: each suite's TEMP is a short directory owned
    # by the run, under the runner's TEMP and outside the scratch directory, so a suite that builds nested Git
    # repositories in TEMP (like Test-CicdState) stays under the 260-character Windows path limit.
    $gitProbe = @(
        '$name = Split-Path $PSCommandPath -LeafBase'
        '$repo = Join-Path (Join-Path $env:TEMP (''ccof-cicd-state-'' + [guid]::NewGuid().ToString(''n''))) ''a'''
        '$rel = ''deploy/prod/.dr-state/frontdoor-state.json'''
        'New-Item -ItemType Directory -Path (Split-Path (Join-Path $repo $rel)) -Force | Out-Null'
        'Set-Content -LiteralPath (Join-Path $repo $rel) -Value ''{}'''
        'git -c init.defaultBranch=main init -q $repo 2>&1 | Write-Host; $init = $LASTEXITCODE'
        'git -C $repo add -- $rel 2>&1 | Write-Host; $add = $LASTEXITCODE'
        '[ordered]@{ name = $name; temp = $env:TEMP; init = $init; add = $add } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:CCOF_RT_OUT "$name.json")'
        'if ($init -or $add) { exit 1 }'
    ) -join "`n"
    $fx = New-Fixture ('long-' + ('w' * [Math]::Max(1, 116 - $base.Length))) @{ 'Test-CicdStateLike' = $gitProbe } -Bicep
    # The Node suites share one TEMP: the same kind of nested repository from os.tmpdir(), with a work-tree path that
    # passes 260 characters from the scratch directory but not from a short TEMP.
    $nodeGit = @'
import { test } from 'node:test'; import { writeFileSync, mkdtempSync, mkdirSync } from 'node:fs'; import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os'; import { spawnSync } from 'node:child_process';
test('git repository in tmpdir', () => {
  const t = tmpdir(); const repo = join(mkdtempSync(join(t, 'ccof-cicd-state-0123456789abcdef0123456789abcdef-')), 'a');
  const rel = 'deploy/prod/.dr-state/' + 'r'.repeat(40) + '/' + 's'.repeat(40) + '/frontdoor-state.json';
  mkdirSync(dirname(join(repo, rel)), { recursive: true }); writeFileSync(join(repo, rel), '{}');
  const init = spawnSync('git', ['-c', 'init.defaultBranch=main', 'init', '-q', repo]).status;
  const add = spawnSync('git', ['-C', repo, 'add', '--', rel]).status;
  writeFileSync(join(process.env.CCOF_RT_OUT!, 'nodegit.json'), JSON.stringify({ name: 'nodegit', temp: t, init, add, path: join(repo, rel).length }));
  if (init !== 0 || add !== 0) throw new Error('git failed in tmpdir');
});
'@
    Set-Content -LiteralPath (Join-Path $fx.tests 'nodegit.test.ts') -Value $nodeGit
    $r = Invoke-Runner $fx '2' -WithNode
    $g = $r.rec['Test-CicdStateLike']; $ng = $r.rec['nodegit']
    Check "the long-workspace fixture is as deep as the gate worktree (scratch: $($fx.scratch.Length) characters)" ($fx.scratch.Length -ge 124)
    Check 'a suite that creates nested Git repositories in TEMP passes from a long workspace' ($r.code -eq 0 -and $g -and $g.init -eq 0 -and $g.add -eq 0)
    Check "the suite TEMP is short ($($g.temp.Length) characters), under the runner's TEMP, outside the scratch directory" ($g -and $g.temp.Length -le 120 -and
        $g.temp.StartsWith((Join-Path $sysTemp 'ccof-t-'), [StringComparison]::OrdinalIgnoreCase) -and -not $g.temp.StartsWith($fx.scratch, [StringComparison]::OrdinalIgnoreCase))
    Check "the Node suites also get a short TEMP of their own ($($ng.temp.Length) characters), outside the scratch directory" ($ng -and $ng.temp.Length -le 120 -and $ng.temp -ne $g.temp -and
        $ng.temp.StartsWith((Join-Path $sysTemp 'ccof-t-'), [StringComparison]::OrdinalIgnoreCase) -and -not $ng.temp.StartsWith($fx.scratch, [StringComparison]::OrdinalIgnoreCase))
    Check "a Node suite that creates a nested Git repository in os.tmpdir() passes from a long workspace (scratch + work tree would be $($fx.scratch.Length + $ng.path - $ng.temp.Length) characters)" (
        $ng -and $ng.init -eq 0 -and $ng.add -eq 0 -and ($fx.scratch.Length + $ng.path - $ng.temp.Length) -gt 260)
    Check 'the Node TEMP of a passing run is removed' ($ng -and -not (Test-Path -LiteralPath $ng.temp))
    Check 'the decoy directory next to the run TEMP is untouched' ((Test-Path -LiteralPath (Join-Path $decoy 'keep.txt')) -and (Get-RunTemps).Count -eq 0)

    # 7. A runner TEMP so long that a suite TEMP would exceed the budget: on Windows, stop before any suite and create
    # nothing there.
    $deep = Join-Path $base ('d' * 120)
    New-Item -ItemType Directory -Path $deep | Out-Null
    $fx = New-Fixture 'deeptemp' @{ 'Test-A' = $probe } -Bicep
    $r = Invoke-Runner $fx '2' -Temp $deep
    if ($IsWindows) {
        Check 'on Windows, an overlong TEMP exits 1 with the reason before any suite' ($r.code -eq 1 -and $r.text -match 'RUN FAILED: .*TEMP.*260' -and $r.rec.Count -eq 0)
        Check 'on Windows, nothing is created in the overlong TEMP' (@(Get-ChildItem -LiteralPath $deep -Force).Count -eq 0)
    } else {
        Check 'outside Windows, a long TEMP is accepted' ($r.code -eq 0 -and $r.rec.Count -eq 1)
    }
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Run-tests runner: $pass checks passed, $fail failed."
if ($fail) { exit 1 }
