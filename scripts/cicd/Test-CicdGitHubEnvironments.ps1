#Requires -Version 7.0
<#
.SYNOPSIS
    Checks the GitHub environments of one CCOF environment before a deploy run (read-only GET calls).

.DESCRIPTION
    <Environment>-preview must admit only the protected default branch. With -ReviewedGate (apply runs) each
    <Environment>-<gate> must also have required reviewers that administrators cannot bypass, and the repository
    plan must enforce them (public repository, or an organization on GitHub Enterprise). Anything the token cannot
    read is "cannot prove" and fails. One exception: the plan of a private organization is owner-only; it is
    reported 'deferred' (NOT PROVED here) and every reviewed job proves enforcement before its writes
    (Assert-CicdJobApproval.ps1). Exit 0 = every finding passes or the plan is deferred, 1 = anything else.
    The default branch must accept only reviewed pull requests without bypass ('<branch> review protection'):
    protected:true alone is not enough. Branch protection and ruleset bypass lists are not readable with GITHUB_TOKEN
    (repository Administration: read, or write access to the ruleset); unreadable fails. CCOF_PROTECTION_READ_TOKEN,
    when set, is used only for those protection reads (read-only token; GET only).
    Token: GH_TOKEN. API: GITHUB_API_URL (default https://api.github.com). Module: CicdGitHubEnvironments.psm1.

.EXAMPLE
    pwsh scripts/cicd/Test-CicdGitHubEnvironments.ps1 -Repository o/r -Environment prod -ReviewedGate 'apply,gate-network'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Environment,
    [string[]]$ReviewedGate = @()
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CicdGitHubEnvironments.psm1') -Force
$ReviewedGate = @($ReviewedGate | ForEach-Object { $_ -split ',' } | ForEach-Object Trim | Where-Object { $_ })
$get = New-CicdGhRestGet
$pget = if ($env:CCOF_PROTECTION_READ_TOKEN) { New-CicdGhRestGet -Token $env:CCOF_PROTECTION_READ_TOKEN } else { $get }
$findings = @(Test-CicdGhProtections -Get $get -ProtectionGet $pget -Repository $Repository -Environment $Environment -ReviewedGate $ReviewedGate)
$code = Get-CicdGhExitCode $findings
$deferred = @($findings | Where-Object Status -eq 'deferred')
$md = @("### GitHub environment protections: $Environment", '', '| Subject | Result | Evidence |', '|---|---|---|')
$md += $findings | ForEach-Object { "| $($_.Subject) | $($_.Status) | $($_.Evidence -replace '\|', '/') |" }
if ($ReviewedGate.Count) {
    $md += '', $(if ($code) { '**Approvals are NOT enforced or cannot be proved: the run stops.**' } elseif ($deferred.Count) { '**Plan enforcement NOT PROVED yet: each reviewed job must prove its own approval before any write (Assert-CicdJobApproval.ps1).**' } else { 'Approvals: required reviewers configured, no administrator bypass, enforced by the repository plan. Each reviewed job still proves its own approval.' })
}
if ($env:GITHUB_STEP_SUMMARY) { $md + '' | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM }
$md | Write-Host
foreach ($f in @($findings | Where-Object { $_.Status -ne 'pass' -and $_.Status -ne 'deferred' })) { Write-Host "::error::$($f.Subject): $($f.Evidence)" }
foreach ($f in $deferred) { Write-Host "::warning::$($f.Subject): $($f.Evidence)" }
exit $code