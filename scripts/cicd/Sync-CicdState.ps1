#Requires -Version 7.0
<#
.SYNOPSIS
    Restores or saves the driver state of one environment (deploy/<env>/) from or to the orphan branch
    cicd-state/<env> of this repository. Used by .github/workflows/deploy-environment.yml.

.DESCRIPTION
    Restore  fetches cicd-state/<env> and writes its files into deploy/<env>/ (first run: nothing to restore).
    Save     commits the state folders (.staged-state, .dr-state, .dr-evidence, .health-alerts-a,
             .health-alerts-b; JSON/text only, at most 5 MB a file) as a snapshot whose parent is the commit
             restored in this job, after a secret scan, and pushes it fast-forward only. A concurrent save
             makes the push fail; nothing is overwritten.
    The state branch holds environment identifiers: keep the deployment repository private.

.EXAMPLE
    pwsh scripts/cicd/Sync-CicdState.ps1 -Action Restore -Environment prod
    pwsh scripts/cicd/Sync-CicdState.ps1 -Action Save -Environment prod -Message "stage 3 apply (run 42)"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Restore', 'Save')][string]$Action,
    [Parameter(Mandatory)][string]$Environment,
    [string]$Message = 'ccof cicd state',
    [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$Remote = 'origin'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CicdState.psm1') -Force
$result = if ($Action -eq 'Restore') { Restore-CicdState $RepositoryRoot $Environment $Remote } else { Save-CicdState $RepositoryRoot $Environment $Message $Remote }
Write-Host "Sync-CicdState $Action $Environment : $($result.Message)"
if ($env:GITHUB_STEP_SUMMARY) { "- state $Action ``$Environment``: $($result.Message)" | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }
