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

    # Property verdicts (infra/staged/Staged.WhatIf.ps1) on the real staged-6 Modify records.
    function Set-Verdicts([string]$Dir, [scriptblock]$For) {
        $j = Join-Path $Dir 'staged-6-preview.whatif.jsonl'; $rec = Get-Content $j -Raw | ConvertFrom-Json -Depth 20
        $i = 0; foreach ($c in @($rec.changes | Where-Object change -eq 'Modify')) { $c | Add-Member -NotePropertyName properties -NotePropertyValue @(& $For $i $c) -Force; $i++ }
        $rec | ConvertTo-Json -Depth 20 -Compress | Set-Content $j
    }
    $v = { param($verdict, $path = 'properties.isIPv6EnabledPrivateEndpoint') [pscustomobject]@{ path = $path; change = 'Delete'; verdict = $verdict; rule = 'r'; detail = '' } }
    $d = New-Case 'verdict-noise' @('staged-6'); Set-Verdicts $d { param($i) & $v 'noise'; & $v 'matched' 'properties' }
    $r = Get-CicdDrift -Directory $d -ExpectedStep 'staged-6'
    Check 'verdicts: every Modify noise or matched is clean and counted' ((Status $r 'staged-6') -eq 'Clean' -and $r.Ok -and ($r.Steps | Where-Object Step -eq 'staged-6').Detail -match 'property verdicts \(10\)')
    $x = Invoke-Cli $d @('staged-6')
    Check 'cli: explained Modify exit 0' ($x.Code -eq 0 -and $x.Md -match 'No drift in 1 of 1')
    $d = New-Case 'verdict-drift' @('staged-6'); Set-Verdicts $d { param($i) & $v 'noise'; if ($i -eq 3) { & $v 'drift' 'properties.customNetworkInterfaceName' } }
    $r = Get-CicdDrift -Directory $d -ExpectedStep 'staged-6'
    Check 'verdicts neg: one drift verdict makes exactly that Modify drift with its path' ((Status $r 'staged-6') -eq 'Drift' -and $r.Drift.Count -eq 1 -and $r.Drift[0].Detail -match 'customNetworkInterfaceName')
    $x = Invoke-Cli $d @('staged-6')
    Check 'cli: drift verdict exit 1, path in markdown' ($x.Code -eq 1 -and $x.Md -match 'drift properties\.customNetworkInterfaceName')
    $d = New-Case 'verdict-open' @('staged-6'); Set-Verdicts $d { param($i) & $v 'matched'; if ($i -eq 0) { & $v 'unmeasured' 'properties.serializedData' } }
    $r = Get-CicdDrift -Directory $d -ExpectedStep 'staged-6'
    Check 'verdicts neg: unmeasured verdict is Unverifiable, not clean' ((Status $r 'staged-6') -eq 'Unverifiable' -and $r.Review.Count -eq 1 -and -not $r.Ok)
    $d = New-Case 'verdict-both' @('staged-6'); Set-Verdicts $d { param($i) & $v 'unmeasured'; & $v 'drift' 'properties.x' }
    Check 'verdicts neg: drift wins over unmeasured' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'staged-6') 'staged-6') -eq 'Drift')
    $d = New-Case 'verdict-empty' @('staged-6'); Set-Verdicts $d { param($i) }
    $r = Get-CicdDrift -Directory $d -ExpectedStep 'staged-6'
    Check 'verdicts neg: empty properties is drift' ((Status $r 'staged-6') -eq 'Drift' -and $r.Drift.Count -eq 10)
    $d = New-Case 'verdict-unknown' @('staged-6'); Set-Verdicts $d { param($i) & $v 'ignored' }
    Check 'verdicts neg: unknown verdict is Unmeasured' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'staged-6') 'staged-6') -eq 'Unmeasured')
    $d = New-Case 'verdict-nopath' @('staged-6'); Set-Verdicts $d { param($i) [pscustomobject]@{ verdict = 'noise' } }
    Check 'verdicts neg: verdict without path is Unmeasured' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'staged-6') 'staged-6') -eq 'Unmeasured')
    $d = New-Case 'verdict-create' @('health-b')
    $j = Join-Path $d 'health-b-preview.whatif.jsonl'; $rec = Get-Content $j -Raw | ConvertFrom-Json -Depth 20
    foreach ($c in $rec.changes) { $c | Add-Member -NotePropertyName properties -NotePropertyValue @(& $v 'noise') -Force }
    $rec | ConvertTo-Json -Depth 20 -Compress | Set-Content $j
    Check 'verdicts neg: noise verdicts never clean a Create' ((Status (Get-CicdDrift -Directory $d -ExpectedStep 'health-b') 'health-b') -eq 'Drift')

    # End to end: Write-StgWhatIfResult with verdicts from the real classifier, read by Get-CicdDrift.
    . (Join-Path $root 'infra\staged\Staged.Common.ps1'); . (Join-Path $root 'infra\staged\Staged.WhatIf.ps1')
    # Hashtables, as Invoke-QsAz returns what-if output.
    $fxPath = Join-Path $PSScriptRoot 'fixtures\cicd-drift\whatif-delta\lab-modify.json'
    $rb = { param($k, $t) $fx = Get-Content $fxPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100; if (-not $fx.readBacks.Contains("$k|$t")) { throw "no read-back $k|$t" }; $fx.readBacks["$k|$t"] }
    $d = Join-Path $scratch 'e2e'; New-Item -ItemType Directory -Force $d | Out-Null
    $saved = $env:CCOF_WHATIF_RESULTS
    try {
        foreach ($case in @(@{ Name = 'clean'; Mutate = $false }, @{ Name = 'mutated'; Mutate = $true })) {
            $changes = @((Get-Content $fxPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100).changes)
            if ($case.Mutate) { @($changes | Where-Object { $_.resourceId -match '/privateEndpoints/[^/]+$' })[0].delta[0].before = $true }
            $env:CCOF_WHATIF_RESULTS = Join-Path $d "$($case.Name).jsonl"
            $verdicts = @{}; foreach ($c in $changes) { $verdicts[[string]$c.resourceId] = @(Get-StgModifyVerdicts $c $rb) }
            Write-StgWhatIfResult 'lab-modify' $changes -Verdicts $verdicts
            Copy-Item $env:CCOF_WHATIF_RESULTS (Join-Path $d 'staged-5-preview.whatif.jsonl') -Force
            $o = Get-Content (Join-Path $fixtures 'staged-3-preview.result.json') -Raw | ConvertFrom-Json; $o.step = 'staged-5'; $o | ConvertTo-Json | Set-Content (Join-Path $d 'staged-5-preview.result.json')
            $r = Get-CicdDrift -Directory $d -ExpectedStep 'staged-5'
            # Unchanged lab: the admin app's empty live settings cannot be proved from what-if (unmeasured).
            $want = if ($case.Mutate) { 'Drift' } else { 'Unverifiable' }
            Check "e2e $($case.Name): real lab Modify deltas through the writer give $want" ((Status $r 'staged-5') -eq $want)
            if (-not $case.Mutate) { Check 'e2e unchanged: 10 Modify explained, only admin app settings reviewed, no drift' (($r.Steps | Where-Object Step -eq 'staged-5').Detail -match '1 Deploy, Unsupported or unmeasured Modify' -and $r.Review.Count -eq 1 -and $r.Review[0].Id -match '-admin/config/appsettings$' -and -not $r.Drift.Count) }
            else { Check 'e2e mutated: only the PE is drift' ($r.Drift.Count -eq 1 -and $r.Drift[0].Id -match '/privateEndpoints/') }
        }
    } finally { $env:CCOF_WHATIF_RESULTS = $saved }
} finally {
    Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
}
Write-Host "Test-CicdDrift: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0 -or $script:pass -lt 41) { exit 1 }
