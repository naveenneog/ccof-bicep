#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ParametersPath,
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [string]$ApimCreateSettingsPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'infra\quickstart\Deploy-Quickstart.ps1') -ParametersPath $ParametersPath -DotSourceOnly
Import-Module (Join-Path $PSScriptRoot 'Inputs.psm1') -Force
$parameters = Read-QsParameters (Resolve-QsParametersPath $ParametersPath)
$inputArguments = @{ P = $parameters; RepositoryRoot = $root }
if ($ApimCreateSettingsPath) {
    $inputArguments.ApimCreateSettings = Get-Content -LiteralPath $ApimCreateSettingsPath -Raw | ConvertFrom-Json -AsHashtable
}
# Materialise and validate every input before writing any output.
$inputs = @(Get-ManualResourceInputs @inputArguments)
$out = Resolve-QsParametersPath $OutputDirectory
New-Item -ItemType Directory -Path $out -Force | Out-Null
$manifest = @()
foreach ($entry in $inputs) {
    $path = Join-Path $out "$($entry.Id).parameters.json"
    [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'; parameters = $entry.Parameters
    } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    $manifest += [ordered]@{
        id = $entry.Id; stage = $entry.Stage; template = $entry.Template; parametersFile = $path
        subscriptionId = $entry.SubscriptionId; resourceGroup = $entry.ResourceGroup
        deploymentName = "$($parameters.names.deploymentPrefix)-manual-$($entry.Id)"
        needs = $entry.Needs
    }
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $out 'manifest.json') -Encoding utf8NoBOM
Write-Host "Offline inputs exported to $out. Review manifest.json; deploy each module separately (docs/MANUAL-DEPLOYMENT.md)."
