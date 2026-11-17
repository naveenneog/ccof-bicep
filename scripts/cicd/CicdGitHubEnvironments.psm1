# Proves (or reports that it cannot prove) the GitHub-side protections deploy-environment.yml relies on
# (docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md, "Trust boundaries"):
#  - required reviewers are enforceable: public repository, or a private/internal repository of an organization
#    on GitHub Enterprise. GitHub Free, Pro and Team do not enforce required reviewers on private repositories
#    (https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#required-reviewers).
#  - each environment admits only the protected default branch: a custom deployment branch policy that names
#    exactly the default branch (https://docs.github.com/en/rest/deployments/branch-policies). "Protected branches
#    only" is refused: it admits every branch when no rule exists and any branch a pattern rule covers later.
#  - administrators cannot bypass the reviewers of a reviewed environment (can_admins_bypass false): a bypassed
#    job runs without any approval.
# Every API error or unreadable fact is "cannot prove" and fails. One exception, before any write: the plan of a
# private organization is owner-only, so Test-CicdGhProtections reports it 'deferred' and every reviewed job proves
# it later by observing an enforced approval (Test-CicdGhJobApproval). Nothing is ever attested. Read-only (GET only).
Set-StrictMode -Version Latest

function New-CicdGhFinding { param([string]$Subject, [ValidateSet('pass', 'fail', 'deferred')][string]$Status, [string]$Evidence)
    [pscustomobject]@{ Subject = $Subject; Status = $Status; Evidence = $Evidence } }

# GET against the GitHub REST API with GH_TOKEN. JSON arrays stay arrays (-NoEnumerate): an empty or one-item list
# is not mistaken for "no body" or an object.
function New-CicdGhRestGet {
    $api = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }
    $headers = @{ Authorization = ('Bearer', $env:GH_TOKEN -join ' '); Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    {
        param($Path)
        $r = Invoke-WebRequest -Method Get -Headers $headers -Uri "$api$Path" -SkipHttpErrorCheck
        $body = if ($r.Content) { [string]$r.Content | ConvertFrom-Json -NoEnumerate } else { $null }
        @{ Status = [int]$r.StatusCode; Body = $body }
    }.GetNewClosure()
}

function Invoke-CicdGhGet {
    # Returns @{ Ok; Status; Body }. $Get is injectable for tests: param($Path) -> same shape.
    param([scriptblock]$Get, [string]$Path)
    try { $r = & $Get $Path } catch { return @{ Ok = $false; Status = 0; Body = $null; Error = $_.Exception.Message } }
    if ($r -isnot [hashtable] -or -not $r.ContainsKey('Status')) { return @{ Ok = $false; Status = 0; Body = $null; Error = 'no response' } }
    $r.Ok = ($r.Status -ge 200 -and $r.Status -lt 300); if (-not $r.ContainsKey('Error')) { $r.Error = "HTTP $($r.Status)" }
    return $r
}

# Required reviewers enforceable on this repository's plan.
function Test-CicdGhReviewerPlan {
    param([scriptblock]$Get, [string]$Repository)
    $repo = Invoke-CicdGhGet $Get "/repos/$Repository"
    if (-not $repo.Ok) { return New-CicdGhFinding 'reviewer plan' fail "cannot prove: GET /repos/$Repository failed ($($repo.Error))" }
    $vis = [string]$repo.Body.visibility; $ownerType = [string]$repo.Body.owner.type; $owner = [string]$repo.Body.owner.login
    if ($vis -ceq 'public') { return New-CicdGhFinding 'reviewer plan' pass 'public repository: required reviewers are enforced on every plan' }
    if ($vis -notin 'private', 'internal') { return New-CicdGhFinding 'reviewer plan' fail "cannot prove: repository visibility '$vis' unknown" }
    if ($ownerType -cne 'Organization') {
        return New-CicdGhFinding 'reviewer plan' fail "$vis repository owned by user account '$owner': GitHub Free/Pro do not enforce required reviewers on private repositories; move it to an organization on GitHub Enterprise"
    }
    $org = Invoke-CicdGhGet $Get "/orgs/$owner"
    $plan = if ($org.Ok -and $org.Body.PSObject.Properties['plan'] -and $org.Body.plan) { [string]$org.Body.plan.name } else { '' }
    if ($plan -ceq 'enterprise') { return New-CicdGhFinding 'reviewer plan' pass "$vis repository, organization $owner on plan 'enterprise' (read from GET /orgs/$owner)" }
    if ($plan) { return New-CicdGhFinding 'reviewer plan' fail "$vis repository, organization $owner on plan '$plan': required reviewers are not enforced on private repositories below GitHub Enterprise" }
    return New-CicdGhFinding 'reviewer plan' deferred "NOT PROVED here: the job token cannot read the plan of organization $owner ($($org.Error); owner-only field). No write runs on this: each reviewed job proves enforcement before its writes by observing a reviewer approval of its own environment in this run (Test-CicdGhJobApproval), and fails otherwise."
}

# Exit code of Test-CicdGitHubEnvironments.ps1: 0 only when every finding passes, except a deferred reviewer plan.
function Get-CicdGhExitCode {
    param([object[]]$Findings = @())
    $f = @($Findings | Where-Object { $_ })
    if (-not $f.Count) { return 1 }
    $bad = @($f | Where-Object { -not ($_.Status -ceq 'pass' -or ($_.Status -ceq 'deferred' -and $_.Subject -ceq 'reviewer plan')) })
    return [int]($bad.Count -gt 0)
}

# One environment: exists, custom branch policy = exactly the protected default branch, reviewers when required.
function Test-CicdGhEnvironment {
    param([scriptblock]$Get, [string]$Repository, [string]$Name, [string]$DefaultBranch, [bool]$RequireReviewers)
    $out = [Collections.Generic.List[object]]::new()
    $e = Invoke-CicdGhGet $Get "/repos/$Repository/environments/$Name"
    if (-not $e.Ok) {
        $why = if ($e.Status -eq 404) { 'missing (create it before the run; a job would create an unknown name without protection)' } else { "cannot prove: $($e.Error)" }
        $out.Add((New-CicdGhFinding $Name fail $why)); return $out.ToArray()
    }
    $policy = $e.Body.PSObject.Properties['deployment_branch_policy']?.Value
    if (-not $policy) { $out.Add((New-CicdGhFinding "$Name branches" fail 'no deployment branch policy: every branch can deploy')) }
    elseif ($policy.protected_branches -eq $true) {
        $out.Add((New-CicdGhFinding "$Name branches" fail "cannot prove: 'Protected branches only' admits every branch when no protection rule exists, and any branch a pattern rule covers later; use 'Selected branches' with exactly '$DefaultBranch'"))
    } elseif ($policy.custom_branch_policies -ne $true) { $out.Add((New-CicdGhFinding "$Name branches" fail 'cannot prove: deployment branch policy is neither protected nor custom')) }
    else {
        $p = Invoke-CicdGhGet $Get "/repos/$Repository/environments/$Name/deployment-branch-policies?per_page=100"
        if (-not $p.Ok) { $out.Add((New-CicdGhFinding "$Name branches" fail "cannot prove: GET deployment-branch-policies failed ($($p.Error))")) }
        else {
            $rules = @($p.Body.branch_policies)
            $total = [int]$p.Body.total_count
            $bad = @($rules | Where-Object { [string]$_.name -cne $DefaultBranch -or ($_.PSObject.Properties['type'] -and [string]$_.type -cne 'branch') })
            if ($total -ne 1 -or $rules.Count -ne 1 -or $bad.Count) {
                $list = ($rules | ForEach-Object { "$($_.PSObject.Properties['type']?.Value):$($_.name)" }) -join ', '
                $out.Add((New-CicdGhFinding "$Name branches" fail "selected branches must be exactly '$DefaultBranch' (type branch); found $total rule(s): $list"))
            } else {
                $b = Invoke-CicdGhGet $Get "/repos/$Repository/branches/$([uri]::EscapeDataString($DefaultBranch))"
                if (-not $b.Ok) { $out.Add((New-CicdGhFinding "$Name branches" fail "cannot prove: GET branches/$DefaultBranch failed ($($b.Error))")) }
                elseif ($b.Body.protected -ne $true) { $out.Add((New-CicdGhFinding "$Name branches" fail "only '$DefaultBranch' may deploy, but '$DefaultBranch' has no branch protection (anyone with write access can push to it)")) }
                else { $out.Add((New-CicdGhFinding "$Name branches" pass "only '$DefaultBranch' (selected branch policy, branch protected)")) }
            }
        }
    }
    $reviewers = @(@($e.Body.PSObject.Properties['protection_rules']?.Value) | Where-Object { $_ -and [string]$_.type -ceq 'required_reviewers' } | ForEach-Object { @($_.reviewers) } | Where-Object { $_ })
    if ($RequireReviewers) {
        if (-not $reviewers.Count) { $out.Add((New-CicdGhFinding "$Name reviewers" fail 'no required reviewer')) }
        else {
            $who = ($reviewers | ForEach-Object { "$($_.type):$(if ($_.reviewer.PSObject.Properties['login']) { $_.reviewer.login } else { $_.reviewer.slug })" }) -join ', '
            $bypassProp = $e.Body.PSObject.Properties['can_admins_bypass']
            if (-not $bypassProp -or $bypassProp.Value -isnot [bool]) {
                $out.Add((New-CicdGhFinding "$Name reviewers" fail "cannot prove: can_admins_bypass is not readable as true/false; administrators may be able to bypass the reviewers ($who)"))
            } elseif ($bypassProp.Value) {
                $out.Add((New-CicdGhFinding "$Name reviewers" fail "administrators can bypass the reviewers ($who); a bypassed job runs without approval. Turn off 'Allow administrators to bypass configured protection rules' on $Name"))
            } else { $out.Add((New-CicdGhFinding "$Name reviewers" pass "configured: $who; administrators cannot bypass")) }
        }
    }
    return $out.ToArray()
}

# All findings for <stem>-preview (branch policy) and each gate (branch policy + reviewers + enforceable plan).
function Test-CicdGhProtections {
    param([Parameter(Mandatory)][scriptblock]$Get, [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Environment,
        [string[]]$ReviewedGate = @())
    $repo = Invoke-CicdGhGet $Get "/repos/$Repository"
    if (-not $repo.Ok -or -not [string]$repo.Body.default_branch) { return @(New-CicdGhFinding 'repository' fail "cannot prove: GET /repos/$Repository failed ($($repo.Error))") }
    $default = [string]$repo.Body.default_branch
    $findings = @(Test-CicdGhEnvironment $Get $Repository "$Environment-preview" $default $false)
    if ($ReviewedGate.Count) {
        $findings += Test-CicdGhReviewerPlan $Get $Repository
        foreach ($g in $ReviewedGate) { $findings += Test-CicdGhEnvironment $Get $Repository "$Environment-$g" $default $true }
    }
    return $findings
}

# Before any write, a job in reviewed environment <Environment>-(apply|gate-<name>) proves its own approval.
# GET /actions/runs/{id}/approvals is run-level (one record per review, no job id) and one review approves every job
# waiting on that environment at that moment, so a review seen there may belong to an earlier job. Each job that
# passes uploads a ledger artifact named <LedgerPrefix><job> (ccof-step.yml) before it signs in to Azure; a job is
# approved only when the approvals of its environment in this run outnumber the ledger entries of earlier jobs.
# deploy-environment.yml never runs two jobs of one reviewed environment at the same time (tests), so each waits
# for its own review. Also required now, at job time: reviewers in force, bypass off, main-only branch policy, an
# enforcing plan (readable, or proved by the observed approval), first run attempt (reviews are per run).
function Test-CicdGhJobApproval {
    param([Parameter(Mandatory)][scriptblock]$Get, [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$GitHubEnvironment, [Parameter(Mandatory)][string]$RunId, [int]$RunAttempt = 1)
    $problems = [Collections.Generic.List[string]]::new(); $evidence = [Collections.Generic.List[string]]::new()
    $prefix = "ccof-approval_$($GitHubEnvironment)_"
    $result = { [pscustomobject]@{ Verified = ($problems.Count -eq 0); Environment = $GitHubEnvironment; Approved = $approved; Consumed = $consumed
            Approvers = @($approvers); LedgerPrefix = $prefix; Problems = @($problems); Evidence = @($evidence) } }
    $approved = 0; $consumed = 0; $approvers = @()
    if ($GitHubEnvironment -cnotmatch "^$([regex]::Escape($Environment))-(apply|gate-[a-z]+)$") {
        $problems.Add("not_reviewed_environment: '$GitHubEnvironment' is not $Environment-apply or $Environment-gate-<name>"); return & $result
    }
    if ($RunAttempt -ne 1) { $problems.Add("rerun_attempt: attempt $RunAttempt cannot be bound to its own approval (reviews are recorded per run); dispatch a new run") }
    $repo = Invoke-CicdGhGet $Get "/repos/$Repository"
    if (-not $repo.Ok -or -not [string]$repo.Body.default_branch) { $problems.Add("cannot prove: GET /repos/$Repository failed ($($repo.Error))"); return & $result }
    foreach ($f in @(Test-CicdGhEnvironment $Get $Repository $GitHubEnvironment ([string]$repo.Body.default_branch) $true)) {
        if ($f.Status -ceq 'pass') { $evidence.Add("$($f.Subject): $($f.Evidence)") } else { $problems.Add("$($f.Subject): $($f.Evidence)") }
    }
    $a = Invoke-CicdGhGet $Get "/repos/$Repository/actions/runs/$RunId/approvals"
    $list = $null; if ($a.Ok -and $a.Body -is [array]) { $list = [object[]]$a.Body }
    if ($null -eq $list) { $problems.Add("cannot prove: GET actions/runs/$RunId/approvals failed or is not a list ($($a.Error))") }
    else {
        $mine = @($list | Where-Object { $_ -and @($_.environments | Where-Object { $_ -and [string]$_.name -ceq $GitHubEnvironment }).Count })
        $ok = @($mine | Where-Object { [string]$_.state -ceq 'approved' }); $approved = $ok.Count
        $approvers = @($ok | ForEach-Object { [string]$_.user.login } | Sort-Object -Unique)
        if (@($mine | Where-Object { [string]$_.state -cne 'approved' }).Count) { $problems.Add("rejected: a review of '$GitHubEnvironment' in this run is not 'approved'") }
        if (-not $approved) { $problems.Add("not_approved: no reviewer approved '$GitHubEnvironment' in this run (no reviewers enforced, or the job was bypassed)") }
    }
    $names = [Collections.Generic.List[string]]::new(); $total = -1; $page = 1; $ledgerOk = $true
    while ($ledgerOk) {
        $r = Invoke-CicdGhGet $Get "/repos/$Repository/actions/runs/$RunId/artifacts?per_page=100&page=$page"
        if (-not $r.Ok -or -not $r.Body -or -not $r.Body.PSObject.Properties['total_count']) { $ledgerOk = $false; $problems.Add("cannot prove: GET actions/runs/$RunId/artifacts page $page failed ($($r.Error))"); break }
        $total = [int]$r.Body.total_count; $batch = @($r.Body.artifacts | Where-Object { $_ })
        foreach ($x in $batch) { $names.Add([string]$x.name) }
        if ($names.Count -ge $total) { break }
        if (-not $batch.Count -or $page -ge 20) { $ledgerOk = $false; $problems.Add("cannot prove: the run lists $total artifact(s) but $($names.Count) were returned"); break }
        $page++
    }
    $consumed = @($names | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) }).Count
    if ($ledgerOk -and $null -ne $list -and $approved -and $approved -le $consumed) {
        $problems.Add("approval_already_consumed: $approved approval(s) of '$GitHubEnvironment' in this run and $consumed already used by earlier jobs; this job has no approval of its own (bypassed?)")
    }
    $plan = Test-CicdGhReviewerPlan $Get $Repository
    if ($plan.Status -ceq 'pass') { $evidence.Add("reviewer plan: $($plan.Evidence)") }
    elseif ($plan.Status -ceq 'deferred' -and $approved) { $evidence.Add("reviewer plan: enforcement observed: GitHub held '$GitHubEnvironment' for review in this run ($approved approval(s)); the plan itself is not readable") }
    else { $problems.Add("reviewer plan: $($plan.Evidence)") }
    if ($approved) { $evidence.Add("approvals of '$GitHubEnvironment' in this run: $approved by $($approvers -join ', '); used by earlier jobs: $consumed") }
    return & $result
}

Export-ModuleMember -Function Test-CicdGhProtections, Test-CicdGhEnvironment, Test-CicdGhReviewerPlan, Test-CicdGhJobApproval, Get-CicdGhExitCode, New-CicdGhRestGet
