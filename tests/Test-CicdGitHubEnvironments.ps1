#Requires -Version 7.0
# Offline tests for scripts/cicd/CicdGitHubEnvironments.psm1 (GitHub environment branch policy, required
# reviewers, plan). Responses are mocked with the field names of the GitHub REST API (repos, orgs,
# environments, deployment-branch-policies, branches).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts\cicd\CicdGitHubEnvironments.psm1') -Force
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
function J($o) { $o | ConvertTo-Json -Depth 10 | ConvertFrom-Json }
$R = 'org1/ccof'
function Env-Body([string]$Name, $Policy, [bool]$Reviewers) {
    $rules = @(); if ($Reviewers) { $rules += @{ type = 'required_reviewers'; reviewers = @(@{ type = 'Team'; reviewer = @{ slug = 'ccof-approvers' } }) } }
    J @{ name = $Name; deployment_branch_policy = $Policy; protection_rules = $rules; can_admins_bypass = $false }
}
$custom = @{ protected_branches = $false; custom_branch_policies = $true }
# Classic branch protection (GET /repos/{r}/branches/{b}/protection) that makes every change to main a reviewed PR.
function Classic([int]$Count = 1, [bool]$Admins = $true, [bool]$Stale = $true, [bool]$LastPush = $false, $Allow = @{ users = @(); teams = @(); apps = @() }, [bool]$Force = $false, [bool]$Reviews = $true) {
    $b = @{ enabled = $true; enforce_admins = @{ enabled = $Admins }; allow_force_pushes = @{ enabled = $Force }; allow_deletions = @{ enabled = $false } }
    if ($Reviews) {
        $b.required_pull_request_reviews = @{ required_approving_review_count = $Count; dismiss_stale_reviews = $Stale; require_last_push_approval = $LastPush; require_code_owner_reviews = $false }
        if ($Allow) { $b.required_pull_request_reviews.bypass_pull_request_allowances = $Allow }
    }
    J $b
}
# A ruleset pull_request rule as returned by GET /repos/{r}/rules/branches/{b}, and the ruleset itself.
function PrRule([int]$Id = 7, [int]$Count = 1, [bool]$Stale = $true, [bool]$LastPush = $false) { J @{ type = 'pull_request'; ruleset_id = $Id; ruleset_source_type = 'Repository'; ruleset_source = $R; parameters = @{ required_approving_review_count = $Count; dismiss_stale_reviews_on_push = $Stale; require_last_push_approval = $LastPush; require_code_owner_review = $false; required_review_thread_resolution = $false } } }
function Ruleset([int]$Id = 7, [string]$Enforcement = 'active', $Bypass = @(), [switch]$Hidden) { $h = @{ id = $Id; name = "rs$Id"; target = 'branch'; enforcement = $Enforcement; source_type = 'Repository'; source = $R }; if (-not $Hidden) { $h.bypass_actors = @($Bypass) }; J $h }function Base([string]$Visibility = 'private', [string]$OwnerType = 'Organization', $Plan = 'enterprise') {
    $m = @{}
    $m["/repos/$R"] = @{ Status = 200; Body = (J @{ visibility = $Visibility; default_branch = 'main'; owner = @{ login = 'org1'; type = $OwnerType } }) }
    $m['/orgs/org1'] = if ($Plan) { @{ Status = 200; Body = (J @{ login = 'org1'; plan = @{ name = $Plan } }) } } else { @{ Status = 200; Body = (J @{ login = 'org1' }) } }
    $m["/repos/$R/branches/main"] = @{ Status = 200; Body = (J @{ name = 'main'; protected = $true }) }
    $m["/repos/$R/branches/main/protection"] = @{ Status = 200; Body = (Classic) }
    $m["/repos/$R/rules/branches/main?per_page=100&page=1"] = @{ Status = 200; Body = @() }
    foreach ($e in 'prod-preview', 'prod-apply', 'prod-gate-network') {
        $m["/repos/$R/environments/$e"] = @{ Status = 200; Body = (Env-Body $e $custom ($e -ne 'prod-preview')) }
        $m["/repos/$R/environments/$e/deployment-branch-policies?per_page=100"] = @{ Status = 200; Body = (J @{ total_count = 1; branch_policies = @(@{ id = 1; name = 'main'; type = 'branch' }) }) }
    }
    return $m
}
function Run($m, [string[]]$Gates = @('apply', 'gate-network')) {
    $get = { param($p) if ($m.ContainsKey($p)) { $m[$p] } else { @{ Status = 404; Body = $null } } }.GetNewClosure()
    @(Test-CicdGhProtections -Get $get -Repository $R -Environment 'prod' -ReviewedGate $Gates)
}
function F($f, [string]$Subject) { $f | Where-Object Subject -eq $Subject }
function NoFail($f) { -not @($f | Where-Object Status -eq 'fail').Count }

# Positive: org on Enterprise, selected branch main, protected, reviewers.
$f = Run (Base)
Check 'enterprise org + selected main + protected + reviewers passes' ((NoFail $f) -and (F $f 'reviewer plan').Status -eq 'pass' -and (F $f 'prod-apply reviewers').Evidence -match 'Team:ccof-approvers')
Check 'preview has no reviewer requirement' (-not (F $f 'prod-preview reviewers'))
$f = Run (Base 'public' 'User' $null)
Check 'public repository: reviewers enforced on every plan' ((NoFail $f) -and (F $f 'reviewer plan').Evidence -match 'public')
$f = Run (Base) @()
Check 'preview-only run checks main review protection and the preview environment only (preview jobs also run on a private runner)' ((NoFail $f) -and -not (F $f 'reviewer plan') -and @($f).Count -eq 2 -and (F $f 'main review protection').Status -eq 'pass')

# Plans that cannot enforce required reviewers on private repositories.
foreach ($plan in 'free', 'team', 'pro') {
    $f = Run (Base 'private' 'Organization' $plan)
    Check "neg: private repo on org plan '$plan' fails" ((F $f 'reviewer plan').Status -eq 'fail' -and (F $f 'reviewer plan').Evidence -match "plan '$plan'")
}
$f = Run (Base 'private' 'User' $null)
Check 'neg: private user-owned repository fails (Free/Pro)' ((F $f 'reviewer plan').Status -eq 'fail' -and (F $f 'reviewer plan').Evidence -match 'user account')
$f = Run (Base 'internal' 'Organization' $null)
Check 'neg: unreadable org plan is deferred, never pass' ((F $f 'reviewer plan').Status -eq 'deferred' -and (F $f 'reviewer plan').Evidence -match 'NOT PROVED')
# An unreadable plan is never passed: it is deferred to each reviewed job, which must observe an enforced approval
# (Test-CicdGhJobApproval). A repository variable (former CCOF_GITHUB_PLAN attestation) proves nothing and is ignored.
$f = Run (Base 'private' 'Organization' $null)
Check 'neg: unreadable private org plan is deferred (not pass), evidence says not proved' ((F $f 'reviewer plan').Status -eq 'deferred' -and (F $f 'reviewer plan').Evidence -match 'NOT PROVED' -and (F $f 'reviewer plan').Evidence -match 'each reviewed job')
$m = Base 'private' 'Organization' $null; $m['/orgs/org1'] = @{ Status = 403; Body = $null }; $f = Run $m
Check 'neg: org GET 403 is deferred, never pass' ((F $f 'reviewer plan').Status -eq 'deferred')
Check 'neg: the protections module has no attestation input' (-not (Get-Command Test-CicdGhProtections).Parameters.ContainsKey('AttestedPlan') -and -not (Get-Command Test-CicdGhReviewerPlan).Parameters.ContainsKey('AttestedPlan'))
$f = Run (Base 'private' 'Organization' 'team')
Check 'neg: readable team plan still fails' ((F $f 'reviewer plan').Status -eq 'fail')
# Exit code of Test-CicdGitHubEnvironments.ps1: only pass, or a deferred plan, exit 0; every other status fails.
Check 'exit: all pass = 0' ((Get-CicdGhExitCode (Run (Base))) -eq 0)
Check 'exit: deferred plan = 0 (this job writes nothing; each reviewed job asserts before writes)' ((Get-CicdGhExitCode (Run (Base 'private' 'Organization' $null))) -eq 0)
Check 'neg exit: a failure = 1' ((Get-CicdGhExitCode (Run (Base 'private' 'Organization' 'team'))) -eq 1)
Check 'neg exit: unknown status (e.g. attested) = 1' ((Get-CicdGhExitCode @([pscustomobject]@{ Subject = 'reviewer plan'; Status = 'attested'; Evidence = 'x' })) -eq 1)
Check 'neg exit: deferred on a non-plan subject = 1' ((Get-CicdGhExitCode @([pscustomobject]@{ Subject = 'prod-apply reviewers'; Status = 'deferred'; Evidence = 'x' })) -eq 1)
Check 'neg exit: no findings = 1' ((Get-CicdGhExitCode @()) -eq 1)
$m = Base; $m.Remove("/repos/$R"); $f = Run $m
Check 'neg: unreadable repository fails' ((F $f 'repository').Status -eq 'fail')

# Branch policies.
$m = Base; $m["/repos/$R/environments/prod-apply"].Body.deployment_branch_policy = $null; $f = Run $m
Check 'neg: no branch policy fails' ((F $f 'prod-apply branches').Status -eq 'fail' -and (F $f 'prod-apply branches').Evidence -match 'every branch')
$m = Base; $m["/repos/$R/environments/prod-apply"].Body.deployment_branch_policy = (J @{ protected_branches = $true; custom_branch_policies = $false }); $f = Run $m
Check "neg: 'protected branches only' cannot be proved and fails" ((F $f 'prod-apply branches').Status -eq 'fail' -and (F $f 'prod-apply branches').Evidence -match 'admits every branch')
$m = Base; $m["/repos/$R/environments/prod-preview/deployment-branch-policies?per_page=100"].Body = (J @{ total_count = 1; branch_policies = @(@{ name = '*'; type = 'branch' }) }); $f = Run $m
Check 'neg: wildcard selected branch fails' ((F $f 'prod-preview branches').Status -eq 'fail')
$m = Base; $m["/repos/$R/environments/prod-apply/deployment-branch-policies?per_page=100"].Body = (J @{ total_count = 2; branch_policies = @(@{ name = 'main'; type = 'branch' }, @{ name = 'release/*'; type = 'branch' }) }); $f = Run $m
Check 'neg: an extra selected branch fails' ((F $f 'prod-apply branches').Status -eq 'fail' -and (F $f 'prod-apply branches').Evidence -match 'release')
$m = Base; $m["/repos/$R/environments/prod-apply/deployment-branch-policies?per_page=100"].Body = (J @{ total_count = 1; branch_policies = @(@{ name = 'main'; type = 'tag' }) }); $f = Run $m
Check 'neg: a tag rule named main fails' ((F $f 'prod-apply branches').Status -eq 'fail')
$m = Base; $m["/repos/$R/environments/prod-apply/deployment-branch-policies?per_page=100"].Body = (J @{ total_count = 0; branch_policies = @() }); $f = Run $m
Check 'neg: empty selected branch list fails' ((F $f 'prod-apply branches').Status -eq 'fail')
$m = Base; $m["/repos/$R/environments/prod-apply/deployment-branch-policies?per_page=100"] = @{ Status = 403; Body = $null }; $f = Run $m
Check 'neg: unreadable branch policies fail closed' ((F $f 'prod-apply branches').Status -eq 'fail' -and (F $f 'prod-apply branches').Evidence -match 'cannot prove.*403')
$m = Base; $m["/repos/$R/branches/main"].Body.protected = $false; $f = Run $m
Check 'neg: unprotected default branch fails' ((F $f 'prod-apply branches').Status -eq 'fail' -and (F $f 'prod-apply branches').Evidence -match 'no branch protection')
$m = Base; $m["/repos/$R/branches/main"] = @{ Status = 500; Body = $null }; $f = Run $m
Check 'neg: unreadable default branch fails closed' ((F $f 'prod-preview branches').Status -eq 'fail')

# Review protection of the default branch: protected:true alone only blocks force-push and deletion
# (https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
$RP = 'main review protection'
$f = Run (Base)
Check 'classic: required reviewed PR, stale dismissal, admins enforced, no allowances passes' ((F $f $RP).Status -eq 'pass' -and (F $f $RP).Evidence -match 'classic')
$m = Base; $m["/repos/$R/branches/main/protection"].Body = (Classic -Stale $false -LastPush $true); $f = Run $m
Check 'classic: last-push approval instead of stale dismissal passes' ((F $f $RP).Status -eq 'pass')
$m = Base; $m["/repos/$R/branches/main/protection"] = @{ Status = 404; Body = $null }; $f = Run $m
Check 'neg: protected:true with no readable review protection fails (parent repro)' ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match 'protected:true alone')
Check 'neg exit: protected:true only = 1' ((Get-CicdGhExitCode $f) -eq 1)
$m = Base; $m["/repos/$R/branches/main/protection"] = @{ Status = 403; Body = $null }; $f = Run $m
Check 'neg: classic protection unreadable (job token, 403) fails closed' ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match 'cannot read.*403')
$m = Base; $m["/repos/$R/branches/main/protection"].Body = (Classic -Reviews $false); $f = Run $m
Check 'neg: protected:true, classic protection without required reviews fails' ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match 'no required pull request reviews')
$m = Base; $m["/repos/$R/branches/main/protection"].Body = (Classic -Count 0); $f = Run $m
Check 'neg: required review count 0 fails' ((F $f $RP).Status -eq 'fail')
$m = Base; $m["/repos/$R/branches/main/protection"].Body = (Classic -Admins $false); $f = Run $m
Check 'neg: administrators not included (admin bypass) fails' ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match 'administrators')
foreach ($kind in 'users', 'teams', 'apps') {
    $allow = @{ users = @(); teams = @(); apps = @() }; $allow[$kind] = @(@{ login = 'x'; slug = 'x'; id = 1 })
    $m = Base; $m["/repos/$R/branches/main/protection"].Body = (Classic -Allow $allow); $f = Run $m
    Check "neg: pull request bypass allowance ($kind) fails" ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match "bypass allowance.*$kind")
}
$m = Base; $m["/repos/$R/branches/main/protection"].Body = (Classic -Allow (J @{ users = 'everyone' })); $f = Run $m
Check 'neg: malformed bypass allowances fail closed' ((F $f $RP).Status -eq 'fail')
$m = Base; $m["/repos/$R/branches/main/protection"].Body = (Classic -Force $true); $f = Run $m
Check 'neg: force pushes allowed fails' ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match 'force')
$m = Base; $m["/repos/$R/branches/main/protection"].Body = (Classic -Stale $false); $f = Run $m
Check 'neg: approval survives later pushes (no stale dismissal, no last-push approval) fails' ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match 'later push')
$m = Base; $m["/repos/$R/branches/main/protection"].Body.enforce_admins = $null; $f = Run $m
Check 'neg: enforce_admins unreadable fails closed' ((F $f $RP).Status -eq 'fail')
# Rulesets (only when the ruleset and its bypass list are readable).
function RsBase([object[]]$Rules, $Rs) { $m = Base; $m["/repos/$R/branches/main/protection"] = @{ Status = 404; Body = $null }; $m["/repos/$R/rules/branches/main?per_page=100&page=1"] = @{ Status = 200; Body = @($Rules) }; if ($Rs) { $m["/repos/$R/rulesets/7?includes_parents=true"] = @{ Status = 200; Body = $Rs } }; $m }
$f = Run (RsBase @((PrRule)) (Ruleset))
Check 'ruleset: active pull_request rule, readable empty bypass list passes' ((F $f $RP).Status -eq 'pass' -and (F $f $RP).Evidence -match 'ruleset rs7')
$f = Run (RsBase @((PrRule)) (Ruleset -Hidden))
Check 'neg: ruleset bypass list not returned (no write access) fails closed' ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match 'bypass_actors not readable')
$f = Run (RsBase @((PrRule)) (Ruleset -Bypass @(@{ actor_id = 1; actor_type = 'OrganizationAdmin'; bypass_mode = 'always' })))
Check 'neg: ruleset with an admin bypass actor fails' ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match 'OrganizationAdmin')
$f = Run (RsBase @((PrRule)) (Ruleset -Bypass @(@{ actor_id = 5; actor_type = 'RepositoryRole'; bypass_mode = 'pull_request' })))
Check 'neg: ruleset with a pull_request-mode bypass actor fails' ((F $f $RP).Status -eq 'fail')
$f = Run (RsBase @((PrRule)) (Ruleset -Enforcement 'evaluate'))
Check 'neg: ruleset not active fails' ((F $f $RP).Status -eq 'fail')
$f = Run (RsBase @((PrRule -Count 0)) (Ruleset))
Check 'neg: ruleset rule with 0 approvals fails' ((F $f $RP).Status -eq 'fail')
$f = Run (RsBase @((PrRule -Stale $false)) (Ruleset))
Check 'neg: ruleset approval survives later pushes fails' ((F $f $RP).Status -eq 'fail')
$f = Run (RsBase @((J @{ type = 'deletion'; ruleset_id = 7 }), (J @{ type = 'non_fast_forward'; ruleset_id = 7 })) (Ruleset))
Check 'neg: ruleset with only deletion/non-fast-forward rules fails' ((F $f $RP).Status -eq 'fail')
$f = Run (RsBase @((PrRule)) $null)
Check 'neg: ruleset unreadable (404) fails closed' ((F $f $RP).Status -eq 'fail')
$m = RsBase @() $null; $m["/repos/$R/rules/branches/main?per_page=100&page=1"] = @{ Status = 403; Body = $null }; $f = Run $m
Check 'neg: rules and classic protection both unreadable fail closed' ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match 'cannot read')
# A separate read-only getter (e.g. a token with repository Administration: read) is used only for protection reads.
# bypass_pull_request_allowances and its users/teams/apps are optional in GitHub's OpenAPI schema
# (protected-branch-pull-request-review): absence is not documented as "none", so it cannot prove "no bypass".
$m = Base; $m["/repos/$R/branches/main/protection"].Body = (Classic -Allow $null); $f = Run $m
Check 'neg: bypass allowances not returned fails closed (absence is not proof of none)' ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match 'bypass allowances not returned')
foreach ($kind in 'users', 'teams', 'apps') {
    $allow = @{ users = @(); teams = @(); apps = @() }; $allow.Remove($kind)
    $m = Base; $m["/repos/$R/branches/main/protection"].Body = (Classic -Allow $allow); $f = Run $m
    Check "neg: bypass allowances without '$kind' fail closed" ((F $f $RP).Status -eq 'fail' -and (F $f $RP).Evidence -match "'$kind' not returned")
}
$f = Run (Base)
Check 'neg: no environment claims protection from protected:true' (-not @($f | Where-Object { $_.Subject -like '*branches' -and $_.Evidence -match 'branch protected\)' }).Count)
# No GitHub secret: the protection reads use the job token only; no separate token input exists.
Check 'neg: no separate protection token (module parameter or CLI variable)' (-not (Get-Command Test-CicdGhProtections).Parameters.ContainsKey('ProtectionGet') -and -not (Select-String -Quiet -Pattern 'CCOF_PROTECTION_READ_TOKEN|ProtectionGet' -Path (Join-Path $root 'scripts\cicd\*.ps1'), (Join-Path $root 'scripts\cicd\*.psm1'), (Join-Path $root '.github\workflows\*.yml')))
# Deployment branch policy type must be present and 'branch'.
$m = Base; $m["/repos/$R/environments/prod-apply/deployment-branch-policies?per_page=100"].Body = (J @{ total_count = 1; branch_policies = @(@{ id = 1; name = 'main' }) }); $f = Run $m
Check 'neg: selected rule named main without a type fails (cannot prove type branch)' ((F $f 'prod-apply branches').Status -eq 'fail')
# Organization plan: GET /orgs/{org} documents plan.name as a free string (no enum); only exact 'enterprise' passes.
foreach ($plan in 'Enterprise', 'business', 'enterprise_plus', ' enterprise') {
    $f = Run (Base 'private' 'Organization' $plan)
    Check "neg: unknown org plan '$plan' fails closed" ((F $f 'reviewer plan').Status -eq 'fail' -and (F $f 'reviewer plan').Evidence -match 'unknown')
}

# Environments and reviewers.
$m = Base; $m.Remove("/repos/$R/environments/prod-gate-network"); $f = Run $m
Check 'neg: missing gate environment fails' ((F $f 'prod-gate-network').Status -eq 'fail' -and (F $f 'prod-gate-network').Evidence -match 'missing')
$m = Base; $m["/repos/$R/environments/prod-apply"].Body.protection_rules = @(); $f = Run $m
Check 'neg: apply without required reviewers fails' ((F $f 'prod-apply reviewers').Status -eq 'fail')
$m = Base; $m["/repos/$R/environments/prod-apply"].Body.protection_rules = @(J @{ type = 'wait_timer'; wait_timer = 5 }); $f = Run $m
Check 'neg: a wait timer is not a reviewer' ((F $f 'prod-apply reviewers').Status -eq 'fail')
$m = Base; $m["/repos/$R/environments/prod-apply"].Body.can_admins_bypass = $true; $f = Run $m
Check 'neg: admin bypass allowed fails (a bypassed job has no approval)' ((F $f 'prod-apply reviewers').Status -eq 'fail' -and (F $f 'prod-apply reviewers').Evidence -match 'bypass')
$m = Base; $m["/repos/$R/environments/prod-apply"].Body.PSObject.Properties.Remove('can_admins_bypass'); $f = Run $m
Check 'neg: unreadable can_admins_bypass fails closed' ((F $f 'prod-apply reviewers').Status -eq 'fail' -and (F $f 'prod-apply reviewers').Evidence -match 'cannot prove')
$m = Base; $m["/repos/$R/environments/prod-apply"].Body.can_admins_bypass = 'false'; $f = Run $m
Check 'neg: non-boolean can_admins_bypass fails closed' ((F $f 'prod-apply reviewers').Status -eq 'fail')
$m = Base; $m["/repos/$R/environments/prod-preview"].Body.can_admins_bypass = $true; $f = Run $m
Check 'preview (no reviewers required) is not judged on bypass' (NoFail $f)
$f = Run (Base) -Gates @('apply') ; $throwGet = { param($p) throw 'network down' }
$t = @(Test-CicdGhProtections -Get $throwGet -Repository $R -Environment 'prod' -ReviewedGate 'apply')
Check 'neg: transport error fails closed' ($t.Count -eq 1 -and $t[0].Status -eq 'fail')

# ---------------------------------------------------------------- per-job approval before writes (ccof-step.yml)
# GET /actions/runs/{id}/approvals is run-level: one record per review, no job id. A job proves its own approval
# only when approvals for its environment in this run outnumber the ledger artifacts (ccof-approval_<env>_<job>)
# that earlier jobs of the run uploaded after consuming one, with admin bypass off and reviewers in force.
$RunId = '777'
function Appr([string]$State = 'approved', [string]$EnvName = 'prod-apply', [string]$User = 'rev1') { J @{ state = $State; comment = 'ok'; user = @{ login = $User }; environments = @(@{ id = 1; name = $EnvName }) } }
function Ledger([string[]]$Names) { J @{ total_count = $Names.Count; artifacts = @($Names | ForEach-Object { @{ id = 1; name = $_; expired = $false } }) } }
function JobBase($Approvals = @((Appr)), [string[]]$LedgerNames = @(), $Plan = 'enterprise') {
    $m = Base 'private' 'Organization' $Plan
    $m["/repos/$R/actions/runs/$RunId/approvals"] = @{ Status = 200; Body = @($Approvals) }
    $m["/repos/$R/actions/runs/$RunId/artifacts?per_page=100&page=1"] = @{ Status = 200; Body = (Ledger $LedgerNames) }
    return $m
}
function RunJob($m, [string]$GhEnv = 'prod-apply', [int]$Attempt = 1) {
    $get = { param($p) if ($m.ContainsKey($p)) { $m[$p] } else { @{ Status = 404; Body = $null } } }.GetNewClosure()
    Test-CicdGhJobApproval -Get $get -Repository $R -Environment 'prod' -GitHubEnvironment $GhEnv -RunId $RunId -RunAttempt $Attempt
}
$j = RunJob (JobBase)
Check 'job: first reviewed job with its approval passes' ($j.Verified -and $j.Approved -eq 1 -and $j.Consumed -eq 0 -and $j.LedgerPrefix -ceq 'ccof-approval_prod-apply_' -and @($j.Approvers) -ceq 'rev1')
$j = RunJob (JobBase @((Appr), (Appr)) @('ccof-approval_prod-apply_staged-1-apply'))
Check 'job: second job with a second approval passes' ($j.Verified -and $j.Approved -eq 2 -and $j.Consumed -eq 1)
$j = RunJob (JobBase @((Appr)) @('ccof-approval_prod-apply_staged-1-apply'))
Check "neg job: an earlier job's review is not this job's approval (approved 1, consumed 1)" (-not $j.Verified -and ($j.Problems -join ';') -match 'approval_already_consumed')
$j = RunJob (JobBase @())
Check 'neg job: no review in this run (absent or bypassed) fails' (-not $j.Verified -and ($j.Problems -join ';') -match 'not_approved')
$j = RunJob (JobBase @((Appr 'approved' 'prod-gate-network')))
Check 'neg job: an approval of another environment does not count' (-not $j.Verified -and ($j.Problems -join ';') -match 'not_approved')
$j = RunJob (JobBase @((Appr), (Appr 'rejected')))
Check 'neg job: a rejection in this run fails' (-not $j.Verified -and ($j.Problems -join ';') -match 'rejected')
$j = RunJob (JobBase @((Appr 'approved' 'prod-apply-x')))
Check 'neg job: environment names are matched exactly' (-not $j.Verified)
$j = RunJob (JobBase @((Appr), (Appr)) @('ccof-approval_prod-apply-x_a', 'ccof-approval_prod-gate-network_b', 'evidence-prod-staged-1-apply-1'))
Check 'job: ledger of other environments and evidence artifacts is not counted' ($j.Verified -and $j.Consumed -eq 0)
$m = JobBase; $m["/repos/$R/environments/prod-apply"].Body.can_admins_bypass = $true; $j = RunJob $m
Check 'neg job: admin bypass allowed fails even with an approval' (-not $j.Verified -and ($j.Problems -join ';') -match 'bypass')
$m = JobBase; $m["/repos/$R/environments/prod-apply"].Body.protection_rules = @(); $j = RunJob $m
Check 'neg job: reviewers removed fails even with an approval' (-not $j.Verified -and ($j.Problems -join ';') -match 'reviewer')
$m = JobBase; $m["/repos/$R/branches/main"].Body.protected = $false; $j = RunJob $m
Check 'neg job: unprotected default branch fails' (-not $j.Verified)
$j = RunJob (JobBase -Plan $null)
Check 'job: unreadable plan is proved by the enforced approval observed in this run' ($j.Verified -and ($j.Evidence -join ';') -match 'observed')
$j = RunJob (JobBase @() -Plan $null)
Check 'neg job: unreadable plan and no approval fails' (-not $j.Verified -and ($j.Problems -join ';') -match 'plan')
$j = RunJob (JobBase -Plan 'team')
Check 'neg job: readable team plan fails even with an approval' (-not $j.Verified -and ($j.Problems -join ';') -match 'plan')
$j = RunJob (JobBase) -Attempt 2
Check 'neg job: a re-run attempt fails (reviews are per run)' (-not $j.Verified -and ($j.Problems -join ';') -match 'rerun_attempt')
$j = RunJob (JobBase) -GhEnv 'prod-preview'
Check 'neg job: preview environment is not a reviewed environment' (-not $j.Verified -and ($j.Problems -join ';') -match 'not_reviewed_environment')
$j = RunJob (JobBase) -GhEnv 'stg-apply'
Check 'neg job: environment of another CCOF environment refused' (-not $j.Verified)
$m = JobBase; $m["/repos/$R/actions/runs/$RunId/approvals"] = @{ Status = 403; Body = $null }; $j = RunJob $m
Check 'neg job: unreadable approvals fail closed' (-not $j.Verified -and ($j.Problems -join ';') -match 'cannot prove')
$m = JobBase; $m["/repos/$R/actions/runs/$RunId/artifacts?per_page=100&page=1"] = @{ Status = 500; Body = $null }; $j = RunJob $m
Check 'neg job: unreadable ledger fails closed' (-not $j.Verified -and ($j.Problems -join ';') -match 'cannot prove')
$m = JobBase; $m["/repos/$R/actions/runs/$RunId/artifacts?per_page=100&page=1"].Body = (J @{ total_count = 150; artifacts = @(1..100 | ForEach-Object { @{ name = "evidence-$_" } }) })
$m["/repos/$R/actions/runs/$RunId/artifacts?per_page=100&page=2"] = @{ Status = 200; Body = (J @{ total_count = 150; artifacts = @(1..50 | ForEach-Object { @{ name = $(if ($_ -eq 7) { 'ccof-approval_prod-apply_x' } else { "e2-$_" }) } }) }) }; $j = RunJob $m
Check 'neg job: the ledger is paged (a consumption on page 2 counts)' (-not $j.Verified -and $j.Consumed -eq 1)
$m = JobBase; $m["/repos/$R/actions/runs/$RunId/artifacts?per_page=100&page=1"].Body = (J @{ total_count = 150; artifacts = @(1..100 | ForEach-Object { @{ name = "evidence-$_" } }) }); $j = RunJob $m
Check 'neg job: a short ledger (fewer artifacts than total_count) fails closed' (-not $j.Verified -and ($j.Problems -join ';') -match 'cannot prove')
$m = JobBase; $m["/repos/$R/actions/runs/$RunId/approvals"].Body = (J @{ message = 'odd' }); $j = RunJob $m
Check 'neg job: approvals that are not a list fail closed' (-not $j.Verified)
$throwGet = { param($p) throw 'network down' }
$j = Test-CicdGhJobApproval -Get $throwGet -Repository $R -Environment 'prod' -GitHubEnvironment 'prod-apply' -RunId $RunId -RunAttempt 1
Check 'neg job: transport error fails closed' (-not $j.Verified)

# ---------------------------------------------------------------- the real scripts over HTTP (local listener)
# Real JSON text, so a one-item or empty array goes through ConvertFrom-Json exactly as in a job.
$routes = [Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
for ($try = 1; ; $try++) {
    $port = Get-Random -Minimum 20000 -Maximum 60000
    $listener = [Net.HttpListener]::new(); $listener.Prefixes.Add("http://localhost:$port/")
    try { $listener.Start(); break } catch { $listener.Close(); if ($try -ge 10) { throw } }
}
$server = Start-ThreadJob -ArgumentList $listener, $routes {
    param($l, $routes)
    while ($l.IsListening) {
        try { $c = $l.GetContext() } catch { break }
        $key = $c.Request.Url.PathAndQuery; $hit = $null
        $resp = if ($routes.TryGetValue($key, [ref]$hit)) { $hit } else { @(404, '{"message":"Not Found"}') }
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$resp[1]); $c.Response.StatusCode = [int]$resp[0]
        $c.Response.ContentType = 'application/json'; $c.Response.OutputStream.Write($bytes, 0, $bytes.Length); $c.Response.Close()
    }
}
function Serve($m) { $routes.Clear(); foreach ($k in $m.Keys) { $null = $routes.TryAdd($k, @($m[$k].Status, $(if ($null -eq $m[$k].Body) { '' } else { ConvertTo-Json -InputObject $m[$k].Body -Depth 10 -Compress }))) } }
$scratch = Join-Path ([IO.Path]::GetTempPath()) "ghe-$([guid]::NewGuid().ToString('N').Substring(0, 8))"; $null = New-Item -ItemType Directory $scratch
$cicd = Join-Path $root 'scripts\cicd'; $hadEvidence = Test-Path (Join-Path $root 'evidence')
function Child([string]$Script, [string[]]$ScriptArgs) {
    $env:GITHUB_API_URL = "http://localhost:$port"; $env:GH_TOKEN = 'test-token'; $env:GITHUB_REPOSITORY = $R; $env:GITHUB_RUN_ID = $RunId; $env:GITHUB_RUN_ATTEMPT = '1'
    $env:GITHUB_OUTPUT = Join-Path $scratch 'out.txt'; $env:GITHUB_STEP_SUMMARY = Join-Path $scratch 'summary.md'; Remove-Item $env:GITHUB_OUTPUT -ErrorAction Ignore
    $o = & pwsh -NoProfile -File (Join-Path $cicd $Script) @ScriptArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($n in 'GITHUB_API_URL', 'GH_TOKEN', 'GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY') { Remove-Item "env:$n" -ErrorAction Ignore }
    [pscustomobject]@{ Code = $code; Text = $o }
}
try {
    $assertArgs = @('-Environment', 'prod', '-GitHubEnvironment', 'prod-apply', '-JobKey', 'staged-1-apply')
    Serve (JobBase -Plan $null); $c = Child 'Assert-CicdJobApproval.ps1' $assertArgs
    $out = if (Test-Path (Join-Path $scratch 'out.txt')) { Get-Content -Raw (Join-Path $scratch 'out.txt') } else { '' }
    Check 'http: one approval (one-item JSON array), private org plan unreadable: verified, ledger output' ($c.Code -eq 0 -and (@($out -split '\r?\n') -cmatch '^ledger=ccof-approval_prod-apply_staged-1-apply-[0-9a-f]{8}$').Count -eq 1)
    if ($c.Code -ne 0) { Write-Host $c.Text }
    $rec = Get-ChildItem (Join-Path $root 'evidence\prod') -Filter 'approval-prod-apply-staged-1-apply-*.json' -ErrorAction Ignore | Sort-Object LastWriteTime | Select-Object -Last 1
    Check 'http: approval record written' ($rec -and (Get-Content -Raw $rec.FullName | ConvertFrom-Json).verified -eq $true)
    Serve (JobBase @()); $c = Child 'Assert-CicdJobApproval.ps1' $assertArgs
    Check 'neg http: empty approvals (JSON []) exit 4' ($c.Code -eq 4 -and $c.Text -match 'not_approved' -and -not (Test-Path (Join-Path $scratch 'out.txt')))
    Serve (JobBase @((Appr)) @('ccof-approval_prod-apply_staged-1-apply-0a1b2c3d')); $c = Child 'Assert-CicdJobApproval.ps1' @('-Environment', 'prod', '-GitHubEnvironment', 'prod-apply', '-JobKey', 'staged-2-apply')
    Check "neg http: second job on the first job's review exit 4" ($c.Code -eq 4 -and $c.Text -match 'approval_already_consumed')
    $m = JobBase; $m["/repos/$R/environments/prod-apply"].Body.can_admins_bypass = $true; Serve $m; $c = Child 'Assert-CicdJobApproval.ps1' $assertArgs
    Check 'neg http: admin bypass exit 4' ($c.Code -eq 4)
    $c = Child 'Assert-CicdJobApproval.ps1' @('-Environment', 'prod', '-GitHubEnvironment', 'prod-apply', '-JobKey', 'bad key')
    Check 'neg http: invalid job key exit 2' ($c.Code -eq 2)
    $cliArgs = @('-Repository', $R, '-Environment', 'prod', '-ReviewedGate', 'apply,gate-network')
    Serve (Base 'private' 'Organization' $null); $c = Child 'Test-CicdGitHubEnvironments.ps1' $cliArgs
    Check 'http cli: unreadable plan is deferred, exit 0, says NOT PROVED' ($c.Code -eq 0 -and $c.Text -match 'NOT PROVED')
    $m = Base 'private' 'Organization' $null; $m["/repos/$R/environments/prod-gate-network"].Body.can_admins_bypass = $true; Serve $m; $c = Child 'Test-CicdGitHubEnvironments.ps1' $cliArgs
    Check 'neg http cli: admin bypass exit 1' ($c.Code -eq 1 -and $c.Text -match 'bypass')
    $m = Base; $m["/repos/$R/branches/main/protection"] = @{ Status = 404; Body = $null }; Serve $m; $c = Child 'Test-CicdGitHubEnvironments.ps1' $cliArgs
    Check 'neg http cli: main protected:true without review protection exit 1' ($c.Code -eq 1 -and $c.Text -match 'main review protection' -and $c.Text -match 'protected:true alone')
    $m = Base; $m["/repos/$R/branches/main/protection"] = @{ Status = 403; Body = $null }; Serve $m; $c = Child 'Test-CicdGitHubEnvironments.ps1' $cliArgs
    Check 'neg http cli: protection unreadable with the job token exit 1 (no fallback)' ($c.Code -eq 1 -and $c.Text -match 'cannot read')
    $m = RsBase @((PrRule)) (Ruleset); Serve $m; $c = Child 'Test-CicdGitHubEnvironments.ps1' $cliArgs
    Check 'http cli: ruleset proof over real JSON (one-item rules array, empty bypass list) exit 0' ($c.Code -eq 0 -and $c.Text -match 'ruleset rs7')
    $env:CCOF_GITHUB_PLAN = 'enterprise'; Serve (Base 'private' 'Organization' $null); $c = Child 'Test-CicdGitHubEnvironments.ps1' $cliArgs; Remove-Item env:CCOF_GITHUB_PLAN
    Check 'neg http cli: CCOF_GITHUB_PLAN=enterprise is ignored (plan deferred, never attested or pass)' ($c.Text -match '\| reviewer plan \| deferred \|' -and $c.Text -notmatch 'attested')
} finally {
    $listener.Stop(); $listener.Close(); $server | Wait-Job -Timeout 10 | Out-Null; $server | Remove-Job -Force
    Remove-Item -Recurse -Force $scratch -ErrorAction Ignore
    Get-ChildItem (Join-Path $root 'evidence\prod') -Filter 'approval-prod-*.json' -ErrorAction Ignore | Remove-Item -Force
    if ((Test-Path (Join-Path $root 'evidence\prod')) -and -not (Get-ChildItem (Join-Path $root 'evidence\prod'))) { Remove-Item (Join-Path $root 'evidence\prod') }
    if (-not $hadEvidence -and (Test-Path (Join-Path $root 'evidence')) -and -not (Get-ChildItem -Force (Join-Path $root 'evidence'))) { Remove-Item (Join-Path $root 'evidence') }
}

Write-Host "Test-CicdGitHubEnvironments: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0 -or $script:pass -lt 108) { exit 1 }
