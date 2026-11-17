#Requires -Version 7.0
<#
.SYNOPSIS
    Runs one driver step of .github/workflows/deploy-environment.yml for deploy/<env>/ and records the log.

.DESCRIPTION
    Builds the command with CicdDriver.psm1 (guards: Stage 4 only in Entra manual mode, no Stage 8, no
    Lockdown/Drain/Restore/Fence/Promote/Failback, approvals only on their own step and only with -Apply),
    prints it, runs it from the repository root, writes the output to evidence/<env>/<step>-<mode>.log and
    a job summary, and exits with the driver's exit code.
    In GitHub Actions an -Apply step refuses to run unless the runner role (CCOF_RUNNER_ROLE, set on the
    runner host by infra/cicd) is "apply".

.EXAMPLE
    pwsh scripts/cicd/Invoke-CicdDriver.ps1 -Environment prod -Step staged-1
    pwsh scripts/cicd/Invoke-CicdDriver.ps1 -Environment prod -Step standby-Network -Apply -Approve PrivateNetworkChanges
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$Step,
    [switch]$Apply,
    [string[]]$Approve = @(),
    [switch]$PrimaryOnly,
    [string]$ReviewedConnectionIds = '',
    [switch]$TestNotification,
    [ValidateSet('A', 'B')][string]$Region = 'A',
    [switch]$PrintOnly
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'CicdDriver.psm1') -Force
$approvals = @($Approve | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
try {
    $cmd = Get-CicdDriverCommand -Step $Step -Environment $Environment -RepoRoot $repo -Apply:$Apply -Approve $approvals -PrimaryOnly:$PrimaryOnly `
        -ReviewedConnectionIds $ReviewedConnectionIds -TestNotification:$TestNotification -Region $Region
} catch { [Console]::Error.WriteLine("refused: $($_.Exception.Message)"); exit 2 }
if ($env:GITHUB_ACTIONS -eq 'true' -and $cmd.Mode -ne 'preview' -and $env:CCOF_RUNNER_ROLE -ne 'apply') {
    [Console]::Error.WriteLine("refused: runner_role_mismatch: $Step $($cmd.Mode) needs the ccof-apply runner (CCOF_RUNNER_ROLE=apply), found '$($env:CCOF_RUNNER_ROLE)'")
    exit 2
}
$line = Format-CicdCommand $cmd
Write-Host "== $Environment $Step ($($cmd.Mode))"
Write-Host $line
if ($PrintOnly) { exit 0 }

$log = Join-Path $repo $cmd.Log
New-Item -ItemType Directory -Force -Path (Split-Path $log -Parent) | Out-Null
$started = Get-Date
Push-Location $repo
try {
    & pwsh -NoProfile -File $cmd.Script @($cmd.Arguments) 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
} finally { Pop-Location }
$secs = [int]((Get-Date) - $started).TotalSeconds
Write-Host "== exit $code after $secs s; log $($cmd.Log)"
if ($env:GITHUB_STEP_SUMMARY) {
    $tail = @(Get-Content -LiteralPath $log -Tail 25) -join "`n"
    @("### $Step ($($cmd.Mode)): exit $code, $secs s", '', '```text', $line, '', $tail, '```', '') | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM
}
exit $code
