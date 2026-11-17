# Proves (or reports that it cannot prove) the GitHub-side protections deploy-environment.yml relies on
# (docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md, "Trust boundaries"):
#  - required reviewers are enforceable: public repository, or a private/internal repository of an organization
#    on GitHub Enterprise. GitHub Free, Pro and Team do not enforce required reviewers on private repositories
#    (https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#required-reviewers).
#  - each environment admits only the protected default branch: a custom deployment branch policy that names
#    exactly the default branch (https://docs.github.com/en/rest/deployments/branch-policies). "Protected branches
#    only" is refused: it admits every branch when no rule exists and any branch a pattern rule covers later.
# Every API error or unreadable fact is "cannot prove" and fails. Read-only (GET only).
Set-StrictMode -Version Latest

function New-CicdGhFinding { param([string]$Subject, [ValidateSet('pass', 'fail', 'attested')][string]$Status, [string]$Evidence)
    [pscustomobject]@{ Subject = $Subject; Status = $Status; Evidence = $Evidence } }

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
    param([scriptblock]$Get, [string]$Repository, [string]$AttestedPlan = '')
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
    if ($AttestedPlan -ceq 'enterprise') {
        return New-CicdGhFinding 'reviewer plan' attested "NOT PROVED: the job token cannot read the plan of $owner (owner-only field); repository variable CCOF_GITHUB_PLAN=enterprise attests GitHub Enterprise. An organization owner must confirm it (runbook, Trust boundaries)."
    }
    return New-CicdGhFinding 'reviewer plan' fail "cannot prove: the job token cannot read the plan of organization $owner; an organization owner confirms GitHub Enterprise and sets repository variable CCOF_GITHUB_PLAN=enterprise (recorded as attested, not proved)"
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
            $bypass = if ($e.Body.PSObject.Properties['can_admins_bypass'] -and $e.Body.can_admins_bypass -eq $true) { '; administrators can bypass (turn off "Allow administrators to bypass")' } else { '' }
            $out.Add((New-CicdGhFinding "$Name reviewers" pass "configured: $who$bypass"))
        }
    }
    return $out.ToArray()
}

# All findings for <stem>-preview (branch policy) and each gate (branch policy + reviewers + enforceable plan).
function Test-CicdGhProtections {
    param([Parameter(Mandatory)][scriptblock]$Get, [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Environment,
        [string[]]$ReviewedGate = @(), [string]$AttestedPlan = '')
    $repo = Invoke-CicdGhGet $Get "/repos/$Repository"
    if (-not $repo.Ok -or -not [string]$repo.Body.default_branch) { return @(New-CicdGhFinding 'repository' fail "cannot prove: GET /repos/$Repository failed ($($repo.Error))") }
    $default = [string]$repo.Body.default_branch
    $findings = @(Test-CicdGhEnvironment $Get $Repository "$Environment-preview" $default $false)
    if ($ReviewedGate.Count) {
        $findings += Test-CicdGhReviewerPlan $Get $Repository $AttestedPlan
        foreach ($g in $ReviewedGate) { $findings += Test-CicdGhEnvironment $Get $Repository "$Environment-$g" $default $true }
    }
    return $findings
}

Export-ModuleMember -Function Test-CicdGhProtections, Test-CicdGhEnvironment, Test-CicdGhReviewerPlan
