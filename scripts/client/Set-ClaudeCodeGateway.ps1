#Requires -Version 7.0
[CmdletBinding()]
param([string]$ConfigPath, [string]$BackupRoot, [switch]$Confirmed)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeCodeGateway.ps1')
. (Join-Path $PSScriptRoot 'ClientInventory.ps1')
Assert-ClientConfirmation -Confirmed:$Confirmed
if (-not $ConfigPath) { $ConfigPath = Get-ClientDefaultConfigPath }
if (-not $BackupRoot) { $BackupRoot = Join-Path (Split-Path $ConfigPath -Parent) 'backups' }
$inventory = Get-CcofClientInventory
Set-CcofClaudeCode -ConfigPath $ConfigPath -BackupRoot $BackupRoot -Inventory $inventory `
    -ClaudeHome (Join-Path $HOME '.claude') -VSCodeSettingsPath (Join-Path $env:APPDATA 'Code\User\settings.json') `
    -NodePath (Get-Command node -ErrorAction Stop).Source `
    -TokenEntryPath (Join-Path $script:ClientRepoRoot 'client\bin\ccof-token.mjs') -Confirmed
