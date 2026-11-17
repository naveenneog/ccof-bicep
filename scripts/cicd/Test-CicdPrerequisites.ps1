#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only prerequisite checks for one CCOF environment folder (deploy/<env>/). Writes prereqs.json and
    prereqs.md (a checklist) and exits 1 when any check fails. Nothing in Azure or Entra is changed.

.DESCRIPTION
    Each check reports pass, fail or manual ("verify manually": the identity cannot read it, or no API
    exposes it), one evidence line and a source reference. See docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md.
      -Mode preview   checks the signed-in identity can read the scopes (ccof-preview runner)
      -Mode apply     checks the deployment actions at each scope (ccof-apply runner)
    -Scope limits the checks to the parts the run will deploy (primary, frontdoor, standby, health).
    Microsoft Graph is only read (GET); a denied read becomes "manual".

.EXAMPLE
    pwsh scripts/cicd/Test-CicdPrerequisites.ps1 -DeployDirectory deploy/prod -OutputDirectory evidence/prod -Mode apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DeployDirectory,
    [string]$OutputDirectory,
    [ValidateSet('preview', 'apply')][string]$Mode = 'preview',
    [ValidateSet('primary', 'frontdoor', 'standby', 'health')][string[]]$Scope = @('primary', 'frontdoor', 'standby', 'health'),
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CicdChecks.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CicdNetworkChecks.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CicdPrereqs.psm1') -Force

$dir = (Resolve-Path -LiteralPath $DeployDirectory).Path
$checks = @(Invoke-CicdPrerequisites $dir $Mode $Scope -Offline:$Offline)
$summary = Get-CicdSummary $checks
$envName = Split-Path $dir -Leaf
$report = [ordered]@{ environment = $envName; mode = $Mode; scope = $Scope; offline = [bool]$Offline; generatedAt = [DateTime]::UtcNow.ToString('o'); summary = $summary; checks = $checks }
$md = ConvertTo-CicdMarkdown $checks "Prerequisites: $envName ($Mode$(if ($Offline) { ', offline' }))"
if ($OutputDirectory) {
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'prereqs.json') -Encoding utf8NoBOM
    $md | Set-Content -LiteralPath (Join-Path $OutputDirectory 'prereqs.md') -Encoding utf8NoBOM
}
if ($env:GITHUB_STEP_SUMMARY) { $md | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM }
Write-Host $md
Write-Host "prerequisites: pass $($summary.pass), fail $($summary.fail), manual $($summary.manual)"
if ($summary.fail -gt 0) { exit 1 }
exit 0
