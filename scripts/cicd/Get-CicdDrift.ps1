#Requires -Version 7.0
<#
.SYNOPSIS
    Reports drift from the structured preview results Invoke-CicdDriver.ps1 wrote for each expected step.

.DESCRIPTION
    Reads <step>-preview.result.json and <step>-preview.whatif.jsonl for every -ExpectedStep (CicdDrift.psm1).
    Writes drift.json and drift.md to -OutputDirectory and appends the Markdown to the job summary.
    Exit 0 only when every expected step is Clean (all NoChange/Ignore) or RecordMatch (Stage 1 parameters match
    its recorded deployment). Exit 1 on drift (Create/Delete/Modify), Unverifiable (Deploy/Unsupported),
    PreviewFailed, NoResult or Unmeasured (no recognised what-if result). Log text is not used.

.EXAMPLE
    pwsh scripts/cicd/Get-CicdDrift.ps1 -LogDirectory evidence/prod -ExpectedStep 'staged-1,staged-2,health-a'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LogDirectory,
    [string]$OutputDirectory = $LogDirectory,
    [string[]]$ExpectedStep = @()
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CicdDrift.psm1') -Force
# pwsh -File passes a list as one comma-separated string.
$ExpectedStep = @($ExpectedStep | ForEach-Object { $_ -split ',' } | ForEach-Object Trim | Where-Object { $_ })
try { $r = Get-CicdDrift -Directory $LogDirectory -ExpectedStep $ExpectedStep } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
$steps = @($r.Steps)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
[ordered]@{ checkedAt = (Get-Date).ToUniversalTime().ToString('o'); ok = $r.Ok; steps = @($steps | Select-Object Step, Status, Detail, Counts); drift = $r.Drift; review = $r.Review } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'drift.json') -Encoding utf8NoBOM
$good = @($steps | Where-Object Status -in 'Clean', 'RecordMatch').Count
$md = @(if ($r.Ok) { "## Drift check: No drift in $good of $($steps.Count) expected previews" } else { "## Drift check: $($r.Drift.Count) drift, $($r.Review.Count) unverifiable, $($steps.Count - $good) of $($steps.Count) expected previews not clean" }, '')
$md += '| Step | Status | Changes | Detail |', '|---|---|---|---|'
$md += $steps | ForEach-Object { "| $($_.Step) | $($_.Status) | $($_.Counts) | $($_.Detail) |" }
if ($r.Drift.Count -or $r.Review.Count) {
    $md += '', '| Step | Change | Resource |', '|---|---|---|'
    $md += @($r.Drift) + @($r.Review) | ForEach-Object { "| $($_.Step) | $($_.Change) | ``$($_.Id)`` |" }
}
$md | Set-Content -LiteralPath (Join-Path $OutputDirectory 'drift.md') -Encoding utf8NoBOM
if ($env:GITHUB_STEP_SUMMARY) { $md + '' | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM }
$md | Write-Host
exit ([int](-not $r.Ok))