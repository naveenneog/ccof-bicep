#Requires -Version 7.0
[CmdletBinding()]
param([string]$ConfigPath, [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$BackupRoot, [switch]$IncludeDesktopBrokerRedirect, [switch]$IncludeDesktopBrowserRedirect,
    [switch]$Confirmed)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeveloperSignInRedirects.ps1')
if (-not $ConfigPath) { $ConfigPath = Get-ClientDefaultConfigPath }
if (-not $BackupRoot) { $BackupRoot = Join-Path (Split-Path $ConfigPath -Parent) 'backups' }
Set-CcofDeveloperRedirects -ConfigPath $ConfigPath -SubscriptionId $SubscriptionId -BackupRoot $BackupRoot `
    -IncludeDesktopBrokerRedirect:$IncludeDesktopBrokerRedirect `
    -IncludeDesktopBrowserRedirect:$IncludeDesktopBrowserRedirect -Confirmed:$Confirmed
