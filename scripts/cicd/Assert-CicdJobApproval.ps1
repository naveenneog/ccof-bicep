#Requires -Version 7.0
<#
.SYNOPSIS
    Fails closed unless this job, in a reviewed GitHub environment, has a reviewer approval of its own.

.DESCRIPTION
    Runs in ccof-step.yml before Azure sign-in in every job of <Environment>-apply or <Environment>-gate-<name>.
    GET /actions/runs/{id}/approvals is run-level (no job id), so Test-CicdGhJobApproval (CicdGitHubEnvironments.psm1)
    counts the approvals of the environment in this run against the ledger artifacts earlier jobs uploaded, and
    re-reads reviewers, administrator bypass, branch policy and plan now. On success it writes
    evidence/<Environment>/approval-<GitHubEnvironment>-<id>.json and the step outputs 'ledger' (artifact name to
    upload before any write) and 'path'. Exit 0 verified, 4 not verified, 2 usage or API error.
    Token: GH_TOKEN (job token, actions: read). Needs GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT.

.EXAMPLE
    pwsh scripts/cicd/Assert-CicdJobApproval.ps1 -Environment prod -GitHubEnvironment prod-apply -JobKey staged-1-apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$GitHubEnvironment,
    [Parameter(Mandatory)][string]$JobKey
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'CicdGitHubEnvironments.psm1') -Force
if ($Environment -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$' -or $GitHubEnvironment -cnotmatch '^[a-z0-9][a-z0-9-]{0,60}$' -or $JobKey -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,80}$') {
    [Console]::Error.WriteLine('refused: invalid environment or job key'); exit 2
}
$repo = "$env:GITHUB_REPOSITORY"; $runId = "$env:GITHUB_RUN_ID"; $attempt = "$env:GITHUB_RUN_ATTEMPT"
if (-not $repo -or $runId -notmatch '^[0-9]+$' -or $attempt -notmatch '^[1-9][0-9]*$' -or -not $env:GH_TOKEN) {
    [Console]::Error.WriteLine('refused: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT are required'); exit 2
}
try { $r = Test-CicdGhJobApproval -Get (New-CicdGhRestGet) -Repository $repo -Environment $Environment -GitHubEnvironment $GitHubEnvironment -RunId $runId -RunAttempt ([int]$attempt) }
catch { [Console]::Error.WriteLine("refused: $($_.Exception.Message)"); exit 2 }
$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
$ledger = "$($r.LedgerPrefix)$JobKey-$id"
$record = [ordered]@{
    environment = $GitHubEnvironment; job = $JobKey; ledger = $ledger; runId = $runId; runAttempt = $attempt; checkedAt = [DateTime]::UtcNow.ToString('o')
    verified = $r.Verified; approvedInRun = $r.Approved; usedByEarlierJobs = $r.Consumed; approvers = @($r.Approvers); problems = @($r.Problems); evidence = @($r.Evidence)
}
$path = Join-Path $repoRoot "evidence/$Environment/approval-$GitHubEnvironment-$JobKey-$id.json"
$null = New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent)
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
$md = @("### Approval of this job: $GitHubEnvironment", '') + @($r.Evidence | ForEach-Object { "- $_" }) + @($r.Problems | ForEach-Object { "- **NOT PROVED**: $_" }) +
    @('', $(if ($r.Verified) { "Verified: approved by $($r.Approvers -join ', ') (approval $($r.Consumed + 1) of $($r.Approved) in this run)." } else { '**No write runs: this job has no proved approval of its own.**' }), '')
if ($env:GITHUB_STEP_SUMMARY) { $md | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM }
$md | Write-Host
if (-not $r.Verified) { foreach ($p in $r.Problems) { Write-Host "::error::approval not proved: $p" }; exit 4 }
if ($env:GITHUB_OUTPUT) { "ledger=$ledger", "path=$path" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8NoBOM }
exit 0