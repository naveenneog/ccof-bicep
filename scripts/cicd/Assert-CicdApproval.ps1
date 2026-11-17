#Requires -Version 7.0
<#
.SYNOPSIS
    Fails closed unless a reviewer approval was enforced for this workflow run in a GitHub environment.

.DESCRIPTION
    Reads the environment (required reviewers, deployment branches main only) and the run's review history from
    the GitHub REST API with the job token (permission actions: read) and checks them with
    Get-CicdApprovalProblems (CicdOnboarding.psm1). Writes evidence/<env>/approval-<github environment>.json;
    Invoke-CicdOnboardingStep.ps1 refuses -Apply in GitHub Actions without a verified record for this run
    attempt. Exit 0 verified, 4 not enforced, 2 usage or API error.

    Required reviewers on a private repository need GitHub Enterprise; on Free, Pro and Team plans they exist
    for public repositories only (https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#required-reviewers).
    Without them this script fails, so the apply never runs unreviewed. The job token cannot read an
    organization's plan: the one approval of this environment observed in this run is the proof that GitHub
    enforced the review. can_admins_bypass must be readable and false.

.EXAMPLE
    pwsh scripts/cicd/Assert-CicdApproval.ps1 -Environment stg -GitHubEnvironment stg-apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Environment,
    [Parameter(Mandatory)] [string]$GitHubEnvironment,
    # Tests: JSON with environment, branchPolicies and approvals instead of the API.
    [string]$FixturePath
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'CicdOnboarding.psm1') -Force
if ($Environment -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$' -or $GitHubEnvironment -cnotmatch '^[a-z0-9][a-z0-9-]{0,60}$') {
    [Console]::Error.WriteLine('refused: invalid environment name'); exit 2
}
$repo = "$env:GITHUB_REPOSITORY"; $runId = "$env:GITHUB_RUN_ID"; $attempt = "$env:GITHUB_RUN_ATTEMPT"
if (-not $repo -or -not $runId -or $attempt -notmatch '^[1-9][0-9]*$') { [Console]::Error.WriteLine('refused: GITHUB_REPOSITORY, GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT are required'); exit 2 }

try {
    if ($FixturePath) {
        $f = Get-Content -Raw -LiteralPath $FixturePath | ConvertFrom-Json
        $envObj = $f.environment; $policies = @($f.branchPolicies); $approvals = @($f.approvals)
    } else {
        if (-not $env:CCOF_APPROVAL_TOKEN) { throw 'CCOF_APPROVAL_TOKEN (the job token) is required' }
        $api = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }
        $h = @{ Authorization = "Bearer $env:CCOF_APPROVAL_TOKEN"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
        $get = { param($path) Invoke-RestMethod -Uri "$api/repos/$repo/$path" -Headers $h -Method Get }
        $envName = [Uri]::EscapeDataString($GitHubEnvironment)
        $envObj = try { & $get "environments/$envName" } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { $null } else { throw }
        }
        $policies = @()
        if ($envObj -and $envObj.deployment_branch_policy -and $envObj.deployment_branch_policy.custom_branch_policies) {
            $policies = @((& $get "environments/$envName/deployment-branch-policies?per_page=100").branch_policies)
        }
        $approvals = @(& $get "actions/runs/$runId/approvals")
    }
} catch { [Console]::Error.WriteLine("refused: GitHub API: $($_.Exception.Message)"); exit 2 }

$r = Get-CicdApprovalProblems -Name $GitHubEnvironment -Environment $envObj -BranchPolicies $policies -Approvals $approvals -Actor "$env:GITHUB_ACTOR" -RunAttempt ([int]$attempt)
$record = [ordered]@{
    environment = $GitHubEnvironment; runId = $runId; runAttempt = $attempt; checkedAt = [DateTime]::UtcNow.ToString('o')
    verified = (@($r.problems).Count -eq 0); approvers = @($r.approvers); problems = @($r.problems); warnings = @($r.warnings)
}
$path = Join-Path $repoRoot "evidence/$Environment/approval-$GitHubEnvironment.json"
$null = New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent)
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
foreach ($w in $r.warnings) { Write-Host "warning: $w" }
if (-not $record.verified) {
    foreach ($p in $r.problems) { [Console]::Error.WriteLine("approval not enforced: $p") }
    exit 4
}
Write-Host "approval enforced for $GitHubEnvironment in run $runId/$attempt by $($r.approvers -join ', ')"
exit 0
