#Requires -Version 7.0
<#
.SYNOPSIS
    Runs one step of .github/workflows/onboard-foundry.yml for deploy/<env>/ and records the log.

.DESCRIPTION
    Builds the command with Get-CicdOnboardingCommand (CicdOnboarding.psm1), prints it, runs it in a child
    pwsh from the repository root, writes the output to evidence/<env>/onboard-<step>-<mode>.log and exits
    with the child's exit code. In GitHub Actions an -Apply step refuses to run unless the runner role
    (CCOF_RUNNER_ROLE, set on the runner host by infra/cicd) is "apply". The same command runs by hand
    from a runner shell (docs/runbooks/CICD-FOUNDRY-ONBOARDING.md).

.EXAMPLE
    pwsh scripts/cicd/Invoke-CicdOnboardingStep.ps1 -Environment stg -Step validate -BaseConfigPath base.json
    pwsh scripts/cicd/Invoke-CicdOnboardingStep.ps1 -Environment stg -Step standby-backends -BackendIds newbe -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Environment,
    [Parameter(Mandatory)] [string]$Step,
    [switch]$Apply,
    [string[]]$BackendIds = @(),
    [string]$BaseConfigPath,
    [switch]$RequirePrivateLink,
    [string]$ApplyPrincipalId,
    [switch]$Offline,
    [switch]$PrintOnly
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'CicdOnboarding.psm1') -Force
try {
    $cmd = Get-CicdOnboardingCommand -Step $Step -Environment $Environment -RepoRoot $repo -Apply:$Apply -BackendIds $BackendIds `
        -BaseConfigPath $BaseConfigPath -RequirePrivateLink:$RequirePrivateLink -ApplyPrincipalId $ApplyPrincipalId -Offline:$Offline
} catch { [Console]::Error.WriteLine("refused: $($_.Exception.Message)"); exit 2 }
if ($env:GITHUB_ACTIONS -eq 'true' -and $cmd.Mode -ne 'preview' -and $env:CCOF_RUNNER_ROLE -ne 'apply') {
    [Console]::Error.WriteLine("refused: runner_role_mismatch: $Step apply needs the ccof-apply runner (CCOF_RUNNER_ROLE=apply), found '$($env:CCOF_RUNNER_ROLE)'")
    exit 2
}
$quoted = @($cmd.Arguments | ForEach-Object { if ("$_" -match '\s') { "'$_'" } else { "$_" } })
Write-Host "== $Environment $Step ($($cmd.Mode))"
Write-Host "pwsh -NoProfile -File $($cmd.File) $($quoted -join ' ')"
if ($PrintOnly) { exit 0 }
$null = New-Item -ItemType Directory -Force -Path (Split-Path $cmd.Log -Parent)
Push-Location $repo
try {
    & pwsh -NoProfile -File $cmd.File @($cmd.Arguments) 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $cmd.Log
    $code = $LASTEXITCODE
} finally { Pop-Location }
if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value @("### $Environment $Step ($($cmd.Mode)): exit $code", '', "Log: ``$([IO.Path]::GetRelativePath($repo, $cmd.Log))``", '')
}
exit $code
