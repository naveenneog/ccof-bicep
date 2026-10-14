#Requires -Version 7.0
<#
.SYNOPSIS
Builds one Function App ZIP locally. Does not deploy code or create Azure resources.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('resolver', 'sync', 'reconciler')] [string]$App,
    [string]$OutputDirectory = '.env.portal-artifacts',
    [string]$RateCardPath = 'config/rate-card.json',
    [string]$ContractSchedulePath = 'config/contract-schedule.json'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'scripts/Core.D2Code.psm1') -DisableNameChecking
$out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$rateCard = (Resolve-Path -LiteralPath $RateCardPath).Path
$contracts = (Resolve-Path -LiteralPath $ContractSchedulePath).Path
Push-Location $root
try {
    npm run build
    if ($LASTEXITCODE -ne 0) { throw 'portal_build_failed: restore dependencies with npm ci, then correct the build error.' }
} finally { Pop-Location }
$answers = @{ rateCard = @{ path = $rateCard; contractSchedulePath = $contracts } }
$package = New-CoreAppPackage -RepositoryRoot $root -App $App -Answers $answers -AnswersDirectory $root -StageRoot (Join-Path $out 'packages')
if ($package.Missing.Count) { throw "portal_package_files_missing: $($package.Missing -join ', ')" }
Push-Location $package.Directory
try {
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "portal_production_dependencies_failed: $App" }
} finally { Pop-Location }
$zip = Join-Path $out "$App.zip"
New-CoreZip -Directory $package.Directory -ZipPath $zip
Get-FileHash -LiteralPath $zip -Algorithm SHA256 | Format-Table -AutoSize
Write-Host "Local ZIP: $zip. Review it, then run the separate az config-zip command. No Azure call was made."
