#Requires -Version 7.0
<#
.SYNOPSIS
    Reads preview logs written by Invoke-CicdDriver.ps1 and reports drift (what-if Create, Delete or Modify).

.DESCRIPTION
    Writes drift.json and drift.md to -OutputDirectory and appends the Markdown to the job summary.
    Exit 0 = no drift, 1 = drift or a missing log. Deploy/Unsupported lines are listed for review only.

.EXAMPLE
    pwsh scripts/cicd/Get-CicdDrift.ps1 -LogDirectory evidence/prod -OutputDirectory evidence/prod
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LogDirectory,
    [string]$OutputDirectory = $LogDirectory,
    [string[]]$ExpectedLog = @()
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CicdDriver.psm1') -Force
$logs = @(Get-ChildItem -LiteralPath $LogDirectory -Filter '*-preview.log' -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
$logs += @($ExpectedLog | Where-Object { $_ } | ForEach-Object { Join-Path $LogDirectory $_ } | Where-Object { $logs -notcontains $_ })
if (-not $logs.Count) { [Console]::Error.WriteLine("no preview log in $LogDirectory"); exit 1 }
$r = Get-CicdDrift -LogPath $logs
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
[ordered]@{ checkedAt = (Get-Date).ToUniversalTime().ToString('o'); logs = @($logs | ForEach-Object { Split-Path $_ -Leaf }); drift = $r.Drift; review = $r.Review } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'drift.json') -Encoding utf8NoBOM
$md = @("## Drift check: $($r.Drift.Count) drift, $($r.Review.Count) to review, $($logs.Count) preview logs", '')
if ($r.Drift.Count -or $r.Review.Count) {
    $md += '| Log | Change | Resource |', '|---|---|---|'
    $md += @($r.Drift) + @($r.Review) | ForEach-Object { "| $($_.Log) | $($_.Change) | ``$($_.Id)`` |" }
} else { $md += 'Every preview reports no Create, Delete or Modify.' }
$md | Set-Content -LiteralPath (Join-Path $OutputDirectory 'drift.md') -Encoding utf8NoBOM
if ($env:GITHUB_STEP_SUMMARY) { $md + '' | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM }
$md | Write-Host
exit ([int]($r.Drift.Count -gt 0))
