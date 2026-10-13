#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$BackupPath, [switch]$Confirmed, [switch]$AllowChangedFiles)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClientGateway.Common.ps1')
Restore-ClientSnapshot -BackupPath $BackupPath -Kind 'claude-code' `
    -Confirmed:$Confirmed -AllowChangedFiles:$AllowChangedFiles
