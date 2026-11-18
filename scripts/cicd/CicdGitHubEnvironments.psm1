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
    $Token = $env:GH_TOKEN
    $api = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }
    $headers = @{ Authorization = ('Bearer', $Token -join ' '); Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
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
    if ($plan -cin 'free', 'team', 'pro') { return New-CicdGhFinding 'reviewer plan' fail "$vis repository, organization $owner on plan '$plan': required reviewers are not enforced on private repositories below GitHub Enterprise" }
    # plan.name is a free string in the API schema (no enum): anything but exact 'enterprise' cannot prove enforcement.
    if ($plan) { return New-CicdGhFinding 'reviewer plan' fail "cannot prove: organization $owner reports unknown plan '$plan'; only 'enterprise' (GET /orgs/$owner plan.name) is accepted" }
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
            $bad = @($rules | Where-Object { [string]$_.name -cne $DefaultBranch -or -not $_.PSObject.Properties['type'] -or [string]$_.type -cne 'branch' })
            if ($total -ne 1 -or $rules.Count -ne 1 -or $bad.Count) {
                $list = ($rules | ForEach-Object { "$($_.PSObject.Properties['type']?.Value):$($_.name)" }) -join ', '
                $out.Add((New-CicdGhFinding "$Name branches" fail "selected branches must be exactly '$DefaultBranch' (type branch); found $total rule(s): $list"))
            } else {
                $b = Invoke-CicdGhGet $Get "/repos/$Repository/branches/$([uri]::EscapeDataString($DefaultBranch))"
                if (-not $b.Ok) { $out.Add((New-CicdGhFinding "$Name branches" fail "cannot prove: GET branches/$DefaultBranch failed ($($b.Error))")) }
                elseif ($b.Body.protected -ne $true) { $out.Add((New-CicdGhFinding "$Name branches" fail "only '$DefaultBranch' may deploy, but '$DefaultBranch' has no branch protection (anyone with write access can push to it)")) }
                else { $out.Add((New-CicdGhFinding "$Name branches" pass "only '$DefaultBranch' (selected branch policy; '$DefaultBranch' reports protected:true, which alone only blocks force-push and deletion; see '$DefaultBranch review protection')")) }
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

# Proves that every change to <Branch> is a pull request approved by someone other than the pusher, with no bypass.
# protected:true alone only blocks force-push and deletion for non-admins. Three requirements must each be proved:
#  - review: a required, reviewed pull request (>= 1 approval, stale approvals dismissed or last push approved);
#  - force-push block: a force push can point the branch at commits no pull request approved, and GitHub models
#    "Block force pushes" as a separate ruleset rule (non_fast_forward), so a pull_request rule alone is not enough;
#  - deletion block: deleting the branch and pushing it again would recreate it from unreviewed commits.
# Each requirement may come from classic protection or any active ruleset (they aggregate; the most restrictive wins):
#  - classic protection (GET .../branches/{b}/protection, repository Administration: read; GITHUB_TOKEN cannot read
#    it): review = required reviews as above, administrators included, explicit empty bypass allowances; force-push
#    block = allow_force_pushes.enabled false; deletion block = allow_deletions.enabled false;
#  - a ruleset rule from GET .../rules/branches/{b} (pull_request with the review settings, non_fast_forward, deletion)
#    whose ruleset (GET .../rulesets/{id}) is active and returns an empty bypass_actors list. GitHub returns
#    bypass_actors only to callers with write access to the ruleset; when it is absent, "no bypass" cannot be proved.
#    Each ruleset is checked on its own, so a force-push rule in another ruleset needs its own proof.
# Anything unreadable or unknown fails. This is a detector run by a workflow on main, not an independent boundary: a
# push to an unreviewed main could change the workflow itself, so the protection must be enforced before runners connect.
function Test-CicdGhBranchReview {
    param([scriptblock]$Get, [string]$Repository, [string]$Branch)
    $subject = "$Branch review protection"
    $why = [Collections.Generic.List[string]]::new(); $b = [uri]::EscapeDataString($Branch)
    $need = [ordered]@{ pull_request = $null; non_fast_forward = $null; deletion = $null }
    $c = Invoke-CicdGhGet $Get "/repos/$Repository/branches/$b/protection"
    if ($c.Ok) {
        $g = Get-CicdGhClassicGaps $c.Body
        foreach ($k in @($need.Keys)) {
            if (-not $g[$k].Count) { $need[$k] = 'classic protection' } else { $why.Add("classic: $($g[$k] -join '; ')") }
        }
    } elseif ($c.Status -eq 404) { $why.Add('classic: none (HTTP 404)') }
    else { $why.Add("classic: cannot read ($($c.Error); needs repository Administration: read)") }

    if (@($need.Values | Where-Object { -not $_ }).Count) {
        $rules = [Collections.Generic.List[object]]::new(); $readable = $true
        for ($page = 1; $page -le 10; $page++) {
            $r = Invoke-CicdGhGet $Get "/repos/$Repository/rules/branches/$b`?per_page=100&page=$page"
            if (-not $r.Ok -or $r.Body -isnot [array]) { $readable = $false; $why.Add("rulesets: cannot read rules for $Branch ($($r.Error))"); break }
            foreach ($x in $r.Body) { $rules.Add($x) }
            if ($r.Body.Count -lt 100) { break }
            if ($page -eq 10) { $readable = $false; $why.Add('rulesets: more than 1000 rules, not all read') }
        }
        if (-not $readable) { return New-CicdGhFinding $subject fail (Get-CicdGhReviewFailText $Branch $why) }
        $proved = @{}
        foreach ($k in @($need.Keys | Where-Object { -not $need[$_] })) {
            $cand = @($rules | Where-Object { [string]$_.type -ceq $k })
            if ($k -eq 'pull_request') {
                $all = $cand.Count
                $cand = @($cand | Where-Object {
                        $q = $_.PSObject.Properties['parameters']?.Value
                        if (-not $q) { return $false }
                        $n = $q.PSObject.Properties['required_approving_review_count']?.Value
                        ($n -is [int] -or $n -is [long]) -and $n -ge 1 -and ($q.PSObject.Properties['dismiss_stale_reviews_on_push']?.Value -eq $true -or $q.PSObject.Properties['require_last_push_approval']?.Value -eq $true)
                    })
                if (-not $cand.Count) { $why.Add("rulesets: no active pull_request rule with >= 1 approval and stale dismissal or last-push approval ($all pull_request rule(s))"); continue }
            } elseif (-not $cand.Count) { $why.Add("rulesets: no active $k rule"); continue }
            foreach ($id in @($cand | ForEach-Object { $_.PSObject.Properties['ruleset_id']?.Value } | Sort-Object -Unique)) {
                if (-not $proved.ContainsKey("$id")) { $proved["$id"] = Test-CicdGhRulesetNoBypass $Get $Repository $id }
                $v = $proved["$id"]
                if ($v.Ok) { $need[$k] = $v.Name; break }
                if (-not $why.Contains($v.Why)) { $why.Add($v.Why) }
            }
            if (-not $need[$k]) { $why.Add("rulesets: no $k rule in an active ruleset proved to have no bypass actors") }
        }
    }
    if (@($need.Values | Where-Object { -not $_ }).Count) { return New-CicdGhFinding $subject fail (Get-CicdGhReviewFailText $Branch $why) }
    $src = ($need.Keys | ForEach-Object { "$_ from $($need[$_])" }) -join '; '
    $n = if ($need.pull_request -eq 'classic protection') { "$($c.Body.required_pull_request_reviews.required_approving_review_count) approving review(s), administrators included, no bypass allowances" } else { 'active pull_request rule, no bypass actors' }
    return New-CicdGhFinding $subject pass "reviewed pull request ($n), force pushes blocked, deletion blocked: $src"
}

function Test-CicdGhRulesetNoBypass {
    param([scriptblock]$Get, [string]$Repository, $Id)
    if ("$Id" -notmatch '^\d+$') { return @{ Ok = $false; Why = "rulesets: invalid ruleset_id '$Id'" } }
    $s = Invoke-CicdGhGet $Get "/repos/$Repository/rulesets/$Id`?includes_parents=true"
    if (-not $s.Ok) { return @{ Ok = $false; Why = "ruleset ${Id}: cannot read ($($s.Error))" } }
    $n = [string]$s.Body.name
    if ([string]$s.Body.enforcement -cne 'active') { return @{ Ok = $false; Why = "ruleset $n (${Id}): enforcement '$($s.Body.enforcement)'" } }
    $bp = $s.Body.PSObject.Properties['bypass_actors']
    if (-not $bp -or $null -eq $bp.Value -or $bp.Value -isnot [array]) { return @{ Ok = $false; Why = "ruleset $n (${Id}): bypass_actors not readable (returned only with write access to the ruleset); no bypass cannot be proved" } }
    if ($bp.Value.Count) { return @{ Ok = $false; Why = "ruleset $n (${Id}): bypass actors $(($bp.Value | ForEach-Object { "$($_.actor_type):$($_.actor_id)/$($_.bypass_mode)" }) -join ', ')" } }
    return @{ Ok = $true; Name = "ruleset $n ($Id, $($s.Body.source_type))" }
}

function Get-CicdGhReviewFailText([string]$Branch, $Why) {
    "cannot prove that every change to '$Branch' is a reviewed pull request without bypass (protected:true alone only blocks force-push and deletion): $($Why -join ' | ')"
}

function Get-CicdGhClassicGaps {
    param($P)
    $gaps = [Collections.Generic.List[string]]::new(); $fpg = [Collections.Generic.List[string]]::new(); $dg = [Collections.Generic.List[string]]::new()
    $rv = $P.PSObject.Properties['required_pull_request_reviews']?.Value
    if (-not $rv) { $gaps.Add('no required pull request reviews') }
    else {
        $n = $rv.PSObject.Properties['required_approving_review_count']?.Value
        if (-not ($n -is [int] -or $n -is [long]) -or $n -lt 1) { $gaps.Add("required approving reviews '$n' (need >= 1)") }
        if (-not ($rv.PSObject.Properties['dismiss_stale_reviews']?.Value -eq $true -or $rv.PSObject.Properties['require_last_push_approval']?.Value -eq $true)) {
            $gaps.Add('an approval survives a later push (enable dismiss stale approvals or require approval of the most recent push)')
        }
        # The schema marks bypass_pull_request_allowances and its lists optional; absence is not documented as
        # "none", so only explicit lists are evidence.
        $al = $rv.PSObject.Properties['bypass_pull_request_allowances']?.Value
        if ($null -eq $al) { $gaps.Add('bypass allowances not returned (absence does not prove there are none)') }
        else {
            foreach ($k in 'users', 'teams', 'apps') {
                $v = $al.PSObject.Properties[$k]?.Value
                if ($null -eq $v) { $gaps.Add("bypass allowances '$k' not returned (absence does not prove there are none)") }
                elseif ($v -isnot [array]) { $gaps.Add("bypass allowances '$k' unreadable") }
                elseif (@($v | Where-Object { $_ }).Count) {
                    $who = (@($v) | ForEach-Object { if ($_.PSObject.Properties['login']) { $_.login } elseif ($_.PSObject.Properties['slug']) { $_.slug } else { $_.id } }) -join ', '
                    $gaps.Add("pull request bypass allowance for ${k}: $who")
                }
            }
        }
    }
    $ea = $P.PSObject.Properties['enforce_admins']?.Value
    if (-not $ea -or $ea.enabled -isnot [bool]) { $gaps.Add('cannot read enforce_admins') }
    elseif (-not $ea.enabled) { $gaps.Add('administrators are not included (they can push without review)') }
    $fp = $P.PSObject.Properties['allow_force_pushes']?.Value
    if (-not $fp -or $fp.enabled -isnot [bool] -or $fp.enabled) { $fpg.Add('force pushes allowed or unreadable') }
    $dl = $P.PSObject.Properties['allow_deletions']?.Value
    if (-not $dl -or $dl.enabled -isnot [bool] -or $dl.enabled) { $dg.Add('branch deletion allowed or unreadable') }
    return @{ pull_request = $gaps.ToArray(); non_fast_forward = $fpg.ToArray(); deletion = $dg.ToArray() }
}

# All findings for <stem>-preview (branch policy) and each gate (branch policy + reviewers + enforceable plan).
function Test-CicdGhProtections {
    param([Parameter(Mandatory)][scriptblock]$Get, [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Environment,
        [string[]]$ReviewedGate = @())
    $repo = Invoke-CicdGhGet $Get "/repos/$Repository"
    if (-not $repo.Ok -or -not [string]$repo.Body.default_branch) { return @(New-CicdGhFinding 'repository' fail "cannot prove: GET /repos/$Repository failed ($($repo.Error))") }
    $default = [string]$repo.Body.default_branch
    $findings = @(Test-CicdGhBranchReview $Get $Repository $default)
    $findings += Test-CicdGhEnvironment $Get $Repository "$Environment-preview" $default $false

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

Export-ModuleMember -Function Test-CicdGhBranchReview, Test-CicdGhProtections, Test-CicdGhEnvironment, Test-CicdGhReviewerPlan, Test-CicdGhJobApproval, Get-CicdGhExitCode, New-CicdGhRestGet
