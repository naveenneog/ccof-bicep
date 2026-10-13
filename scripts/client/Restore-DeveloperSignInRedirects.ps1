#Requires -Version 7.0
[CmdletBinding()]
param([string]$ConfigPath, [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$BackupPath, [switch]$Confirmed)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeveloperSignInRedirects.ps1')
if (-not $ConfigPath) { $ConfigPath = Get-ClientDefaultConfigPath }
Restore-CcofDeveloperRedirects -ConfigPath $ConfigPath -SubscriptionId $SubscriptionId `
    -BackupPath $BackupPath -Confirmed:$Confirmed
