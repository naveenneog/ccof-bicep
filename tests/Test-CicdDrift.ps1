#Requires -Version 7.0
# Offline tests for the drift check (scripts/cicd/CicdDrift.psm1, Get-CicdDrift.ps1). Fixtures in
# tests/fixtures/cicd-drift/infsim-hf are the files Invoke-CicdDriver.ps1 wrote for real lab previews
# (subscription ID and local paths replaced): staged-1 after completion (deployment record match), staged-3
# (NoChange and Ignore only), staged-6 (Modify) and health-b (Create, alerts not deployed yet).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts\cicd\CicdDrift.psm1') -Force
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$fixtures = Join-Path $PSScriptRoot 'fixtures\cicd-drift\infsim-hf'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ccof-drift-' + [guid]::NewGuid().ToString('N'))
$cli = Join-Path $root 'scripts\cicd\Get-CicdDrift.ps1'
function New-Case([string]$Name, [string[]]$Steps) {
    $d = Join-Path $scratch $Name; New-Item -ItemType Directory -Force $d | Out-Null
    foreach ($s in $Steps) { Copy-Item (Join-Path $fixtures "$s-preview.*") $d }
    return $d
}
function Status($r, [string]$Step) { ($r.Steps | Where-Object Step -eq $Step).Status }
function Invoke-Cli([string]$Dir, [string[]]$Steps) { $o = & pwsh -NoProfile -File $cli -LogDirectory $Dir -ExpectedStep ($Steps -join ',') 2>&1; return @{ Code = $LASTEXITCODE; Out = (@($o) -join "`n"); Md = $(if (Test-Path (Join-Path $Dir 'drift.md')) { Get-Content (Join-Path $Dir 'drift.md') -Raw }) } }

try {
    # Real formats.
    $d = New-Case 'clean' @('staged-1', 'staged-3')
    $r = Get-CicdDrift -Directory $d -ExpectedStep 'staged-1', 'staged-3'
    Check 'real staged-3 what-if (NoChange, Ignore) is clean' ((Status $r 'staged-3') -eq 'Clean' -and $r.Ok)
    Check 'real staged-1 deployment record match is clean and labelled' ((Status $r 'staged-1') -eq 'RecordMatch' -and ($r.Steps | Where-Object Step -eq 'staged-1').Detail -match 'resource what-if not run')
    $x = Invoke-Cli $d @('staged-1', 'staged-3')
    Check 'cli: clean exit 0 with measured coverage line' ($x.Code -eq 0 -and $x.Md -match 'No drift in 2 of 2 expected previews' -and $x.Md -notmatch 'Every preview')
    $r = Get-CicdDrift -Directory (New-Case 'modify' @('staged-6')) -ExpectedStep 'staged-6'
    Check 'real staged-6 Modify is drift' ((Status $r 'staged-6') -eq 'Drift' -and $r.Drift.Count -eq 10 -and -not $r.Ok -and @($r.Drift | Where-Object { $_.Change -ne 'Modify' }).Count -eq 0)
    $r = Get-CicdDrift -Directory (New-Case 'health' @('health-b')) -ExpectedStep 'health-b'
    Check 'real health-b what-if (alerts not deployed) is drift with Create' ((Status $r 'health-b') -eq 'Drift' -and @($r.Drift | Where-Object Change -eq 'Create').Count -eq 16)

    # Mutation of a real NoChange into Modify is detected.
    $d = New-Case 'mutate' @('staged-3')
    $j = Join-Path $d 'staged-3-preview.whatif.jsonl'
    $rec = Get-Content $j -Raw | ConvertFrom-Json -Depth 20
    $target = @($rec.changes | Where-Object change -eq 'NoChange')[0]; $target.change = 'Modify'
    $rec | ConvertTo-Json -Depth 20 -Compress | Set-Content $j
    $r = Get-CicdDrift -Directory $d -ExpectedStep 'staged-3'
    Check 'mutation: one real NoChange made Modify is drift with its ID' ((Status $r 'staged-3') -eq 'Drift' -and $r.Drift.Count -eq 1 -and $r.Drift[0].Id -eq $target.id)
    Check 'cli: drift exit 1 and row in markdown' (((Invoke-Cli $d @('staged-3')).Code -eq 1) -and (Get-Content (Join-Path $d 'drift.md') -Raw) -match '\| staged-3 \| Modify \|')

    # Fail closed: nothing measured is never clean.
    $d = New-Case 'vacuous' @()
    'No what-if output was produced.' | Set-Content (Join-Path $d 'staged-2-preview.log')
    $x = Invoke-Cli $d @('staged-2')
    Check 'neg: log with "No what-if output was produced." only fails (no result)' ($x.Code -eq 1 -and $x.Md -notmatch 'No drift' -and $x.Md -match 'staged-2 \| NoResult')
    $o = Get-Content (Join-Path $fixtures 'staged-3-preview.result.json') -Raw | ConvertFrom-Json; $o.step = 'staged-2'; $o | ConvertTo-Json | Set-Content (Join-Path $d 'staged-2-preview.result.json')
    Check 'neg: successful result without a what-if record is Unmeasured' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'staged-2') 'staged-2') -eq 'Unmeasured')
    '' | Set-Content (Join-Path $d 'staged-2-preview.whatif.jsonl')
    Check 'neg: empty what-if record file is Unmeasured' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'staged-2') 'staged-2') -eq 'Unmeasured')
    'what-if stage2-schema : NoChange=3' | Set-Content (Join-Path $d 'staged-2-preview.whatif.jsonl')
    Check 'neg: unparseable record is Unmeasured' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'staged-2') 'staged-2') -eq 'Unmeasured')
    $x = Invoke-Cli $d @('staged-2')
    Check 'cli: Unmeasured exit 1, no clean claim' ($x.Code -eq 1 -and $x.Md -match 'staged-2 \| Unmeasured' -and $x.Md -notmatch 'No drift in')
    '{"schema":"ccof.whatif.v1","source":"stage2-schema","kind":"whatIf","changes":[]}' | Set-Content (Join-Path $d 'staged-2-preview.whatif.jsonl')
    Check 'neg: what-if with no resources is Unmeasured' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'staged-2') 'staged-2') -eq 'Unmeasured')
    '{"schema":"ccof.whatif.v1","source":"x","kind":"whatIf","changes":[{"change":"Mystery","id":"/a/b"}]}' | Set-Content (Join-Path $d 'staged-2-preview.whatif.jsonl')
    Check 'neg: unknown change type is Unmeasured' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'staged-2') 'staged-2') -eq 'Unmeasured')
    '{"schema":"ccof.other","source":"x","kind":"whatIf","changes":[{"change":"NoChange","id":"/a/b"}]}' | Set-Content (Join-Path $d 'staged-2-preview.whatif.jsonl')
    Check 'neg: wrong schema is Unmeasured' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'staged-2') 'staged-2') -eq 'Unmeasured')
    '{"schema":"ccof.whatif.v1","source":"x","kind":"guess","changes":[]}' | Set-Content (Join-Path $d 'staged-2-preview.whatif.jsonl')
    Check 'neg: unknown record kind is Unmeasured' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'staged-2') 'staged-2') -eq 'Unmeasured')

    # Fail closed: failed, missing, mismatched previews.
    $d = New-Case 'failed' @('health-b')
    $p = Join-Path $d 'health-b-preview.result.json'; $o = Get-Content $p -Raw | ConvertFrom-Json; $o.exitCode = 3; $o | ConvertTo-Json | Set-Content $p
    $r = Get-CicdDrift -Directory $d -ExpectedStep 'health-b'
    Check 'neg: failed preview (exit 3, e.g. whatif_refused) fails even with a record' ((Status $r 'health-b') -eq 'PreviewFailed' -and -not $r.Ok)
    $o.exitCode = 0; $o.step = 'health-a'; $o | ConvertTo-Json | Set-Content $p
    Check 'neg: result for another step is NoResult' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'health-b') 'health-b') -eq 'NoResult')
    $o.step = 'health-b'; $o.mode = 'apply'; $o | ConvertTo-Json | Set-Content $p
    Check 'neg: apply result is not a preview' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'health-b') 'health-b') -eq 'NoResult')
    'not json' | Set-Content $p
    Check 'neg: unparseable result is NoResult' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'health-b') 'health-b') -eq 'NoResult')
    $d = New-Case 'missing' @('staged-3')
    $r = Get-CicdDrift -Directory $d -ExpectedStep 'staged-3', 'staged-5'
    Check 'neg: missing expected step fails while the other is clean' ((Status $r 'staged-3') -eq 'Clean' -and (Status $r 'staged-5') -eq 'NoResult' -and -not $r.Ok)
    $x = Invoke-Cli $d @('staged-3', 'staged-5')
    Check 'cli: missing step exit 1, no clean claim' ($x.Code -eq 1 -and $x.Md -notmatch 'No drift in')
    Check 'neg: no expected step refused' ((Invoke-Cli $d @()).Code -ne 0)

    # Deploy and Unsupported cannot be verified: never clean.
    foreach ($kind in 'Unsupported', 'Deploy') {
        $d = New-Case "unv-$kind" @('staged-3')
        $j = Join-Path $d 'staged-3-preview.whatif.jsonl'; $rec = Get-Content $j -Raw | ConvertFrom-Json -Depth 20
        @($rec.changes | Where-Object change -eq 'NoChange')[0].change = $kind
        $rec | ConvertTo-Json -Depth 20 -Compress | Set-Content $j
        $r = Get-CicdDrift -Directory $d -ExpectedStep 'staged-3'
        Check "neg: $kind is Unverifiable, not clean" ((Status $r 'staged-3') -eq 'Unverifiable' -and $r.Review.Count -eq 1 -and -not $r.Ok)
        Check "cli: $kind exit 1" ((Invoke-Cli $d @('staged-3')).Code -eq 1)
    }
} finally {
    Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
}
Write-Host "Test-CicdDrift: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0 -or $script:pass -lt 27) { exit 1 }
