#Requires -Version 7.0
<#
.SYNOPSIS
    Checks the GitHub environments of one CCOF environment before a deploy run (read-only GET calls).

.DESCRIPTION
    <Environment>-preview must admit only the protected default branch. With -ReviewedGate (apply runs) each
    <Environment>-<gate> must also have required reviewers, and the repository plan must enforce them
    (public repository, or an organization on GitHub Enterprise). Anything the token cannot read is
    "cannot prove" and fails. Exit 0 = all pass (an attested plan is reported as NOT PROVED), 1 = a failure.
    Token: GH_TOKEN. API: GITHUB_API_URL (default https://api.github.com). Module: CicdGitHubEnvironments.psm1.

.EXAMPLE
    pwsh scripts/cicd/Test-CicdGitHubEnvironments.ps1 -Repository o/r -Environment prod -ReviewedGate 'apply,gate-network'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Environment,
    [string[]]$ReviewedGate = @(),
    [string]$AttestedPlan = $env:CCOF_GITHUB_PLAN
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CicdGitHubEnvironments.psm1') -Force
$ReviewedGate = @($ReviewedGate | ForEach-Object { $_ -split ',' } | ForEach-Object Trim | Where-Object { $_ })
$api = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }
$headers = @{ Authorization = ('Bearer', $env:GH_TOKEN -join ' '); Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
$get = {
    param($Path)
    $code = 0
    $body = Invoke-RestMethod -Method Get -Headers $headers -Uri "$api$Path" -SkipHttpErrorCheck -StatusCodeVariable code
    @{ Status = [int]$code; Body = $body }
}.GetNewClosure()
$findings = @(Test-CicdGhProtections -Get $get -Repository $Repository -Environment $Environment -ReviewedGate $ReviewedGate -AttestedPlan $AttestedPlan)
$failed = @($findings | Where-Object Status -eq 'fail')
$attested = @($findings | Where-Object Status -eq 'attested')
$md = @("### GitHub environment protections: $Environment", '', '| Subject | Result | Evidence |', '|---|---|---|')
$md += $findings | ForEach-Object { "| $($_.Subject) | $($_.Status) | $($_.Evidence -replace '\|', '/') |" }
if ($ReviewedGate.Count) {
    $md += '', $(if ($failed.Count) { '**Approvals are NOT enforced or cannot be proved: the run stops.**' } elseif ($attested.Count) { '**Approvals: required reviewers configured; plan enforcement NOT PROVED (attested).**' } else { 'Approvals: required reviewers configured and enforced by the repository plan.' })
}
if ($env:GITHUB_STEP_SUMMARY) { $md + '' | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM }
$md | Write-Host
foreach ($f in $failed) { Write-Host "::error::$($f.Subject): $($f.Evidence)" }
foreach ($f in $attested) { Write-Host "::warning::$($f.Subject): $($f.Evidence)" }
exit ([int]($failed.Count -gt 0))
