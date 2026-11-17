#Requires -Version 7.0
<#
.SYNOPSIS
    Runs one driver step of .github/workflows/deploy-environment.yml for deploy/<env>/ and records the log.

.DESCRIPTION
    Builds the command with CicdDriver.psm1 (guards: Stage 4 only in Entra manual mode, no Stage 8, no
    Lockdown/Drain/Restore/Fence/Promote/Failback, approvals only on their own step and only with -Apply),
    prints it, runs it from the repository root, writes the output to evidence/<env>/<step>-<mode>.log and
    a job summary, and exits with the driver's exit code. Next to the log it writes <step>-<mode>.result.json
    (exit code, times) and, through CCOF_WHATIF_RESULTS, <step>-<mode>.whatif.jsonl: one structured record per
    what-if the driver ran. Get-CicdDrift.ps1 reads both and fails closed without them.
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
$stem = $log -replace '\.log$', ''
$resultPath = "$stem.result.json"; $whatIfPath = "$stem.whatif.jsonl"
# A result or what-if file from an earlier run must never stand in for this one.
Remove-Item -LiteralPath $resultPath, $whatIfPath -ErrorAction SilentlyContinue
$started = Get-Date
$savedWhatIf = $env:CCOF_WHATIF_RESULTS
$env:CCOF_WHATIF_RESULTS = $whatIfPath
Push-Location $repo
try {
    & pwsh -NoProfile -File $cmd.Script @($cmd.Arguments) 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
} finally { Pop-Location; $env:CCOF_WHATIF_RESULTS = $savedWhatIf }
$secs = [int]((Get-Date) - $started).TotalSeconds
[ordered]@{ schema = 'ccof.driver-result.v1'; environment = $Environment; step = $Step; mode = $cmd.Mode; exitCode = $code; startedAt = $started.ToUniversalTime().ToString('o'); seconds = $secs; command = $line } |
    ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
Write-Host "== exit $code after $secs s; log $($cmd.Log)"
if ($env:GITHUB_STEP_SUMMARY) {
    $tail = @(Get-Content -LiteralPath $log -Tail 25) -join "`n"
    @("### $Step ($($cmd.Mode)): exit $code, $secs s", '', '```text', $line, '', $tail, '```', '') | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM
}
exit $code
