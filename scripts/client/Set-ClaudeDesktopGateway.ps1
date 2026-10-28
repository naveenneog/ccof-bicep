#Requires -Version 7.0
[CmdletBinding()]
param([string]$ConfigPath, [string]$BackupRoot, [ValidateSet('Helper', 'AzureCli')][string]$TokenSource = 'Helper', [switch]$Confirmed)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeDesktopGateway.ps1')
. (Join-Path $PSScriptRoot 'ClientInventory.ps1')
Assert-ClientConfirmation -Confirmed:$Confirmed
if (-not $ConfigPath) { $ConfigPath = Get-ClientDefaultConfigPath }
if (-not $BackupRoot) { $BackupRoot = Join-Path (Split-Path $ConfigPath -Parent) 'backups' }
$inventory = Get-CcofClientInventory
if (-not $inventory.DesktopVersion) {
    @{ event = 'not_installed'; component = 'claude-desktop' } | ConvertTo-Json -Compress
    exit 0
}
Assert-NoCcofManagedDesktopPolicy
$node = Get-Command node -ErrorAction SilentlyContinue
if ($TokenSource -eq 'Helper' -and -not $node) { throw 'Node.js is missing. Ask the coordinator before installing it, or use -TokenSource AzureCli.' }
$schema = if ($node) { Get-CcofInstalledDesktopSchema $inventory } else {
    Write-Warning 'Node.js is not installed, so the Desktop bundle schema was not inspected; the documented helper-script keys are used. Check the profile in Desktop after setup.'
    Get-CcofKnownDesktopHelperSchema
}
Set-CcofClaudeDesktop -ConfigPath $ConfigPath -BackupRoot $BackupRoot -Inventory $inventory -Schema $schema -TokenSource $TokenSource `
    -LibraryPath (Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary') `
    -NodePath $(if ($node) { $node.Source } else { '' }) `
    -TokenEntryPath (Join-Path $script:ClientRepoRoot 'client\bin\ccof-token.mjs') -Confirmed