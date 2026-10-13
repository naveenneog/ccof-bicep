#Requires -Version 7.0
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClientInventory.ps1')
$inventory = Get-CcofClientInventory
$result = @{ cliVersion = $inventory.CliVersion; vscodeExtensionVersion = $inventory.VSCodeVersion
    desktopVersion = $inventory.DesktopVersion; softwareInstalled = $false }
if ($inventory.DesktopVersion) {
    $schema = Get-CcofInstalledDesktopSchema $inventory
    $result.desktopKeyCount = $schema.keys.Count
    $result.desktopCredentialKinds = $schema.credentialKinds
}
$result | ConvertTo-Json -Compress
