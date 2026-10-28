#Requires -Version 7.0
[CmdletBinding()]
param([string]$ConfigPath, [string]$BackupRoot, [ValidateSet('Helper', 'AzureCli')][string]$TokenSource = 'Helper', [switch]$Confirmed)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeCodeGateway.ps1')
. (Join-Path $PSScriptRoot 'ClientInventory.ps1')
Assert-ClientConfirmation -Confirmed:$Confirmed
if (-not $ConfigPath) { $ConfigPath = Get-ClientDefaultConfigPath }
if (-not $BackupRoot) { $BackupRoot = Join-Path (Split-Path $ConfigPath -Parent) 'backups' }
$inventory = Get-CcofClientInventory
# -TokenSource AzureCli: the helper calls the Azure CLI (az.cmd on PATH); Node.js and ccof-token are not used.
$nodePath = if ($TokenSource -eq 'Helper') { (Get-Command node -ErrorAction Stop).Source } else { '' }
Set-CcofClaudeCode -ConfigPath $ConfigPath -BackupRoot $BackupRoot -Inventory $inventory -TokenSource $TokenSource `
    -ClaudeHome (Join-Path $HOME '.claude') -VSCodeSettingsPath (Join-Path $env:APPDATA 'Code\User\settings.json') `
    -NodePath $nodePath -TokenEntryPath (Join-Path $script:ClientRepoRoot 'client\bin\ccof-token.mjs') -Confirmed