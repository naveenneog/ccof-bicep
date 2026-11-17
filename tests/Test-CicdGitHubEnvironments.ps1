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
function Base([string]$Visibility = 'private', [string]$OwnerType = 'Organization', $Plan = 'enterprise') {
    $m = @{}
    $m["/repos/$R"] = @{ Status = 200; Body = (J @{ visibility = $Visibility; default_branch = 'main'; owner = @{ login = 'org1'; type = $OwnerType } }) }
    $m['/orgs/org1'] = if ($Plan) { @{ Status = 200; Body = (J @{ login = 'org1'; plan = @{ name = $Plan } }) } } else { @{ Status = 200; Body = (J @{ login = 'org1' }) } }
    $m["/repos/$R/branches/main"] = @{ Status = 200; Body = (J @{ name = 'main'; protected = $true }) }
    foreach ($e in 'prod-preview', 'prod-apply', 'prod-gate-network') {
        $m["/repos/$R/environments/$e"] = @{ Status = 200; Body = (Env-Body $e $custom ($e -ne 'prod-preview')) }
        $m["/repos/$R/environments/$e/deployment-branch-policies?per_page=100"] = @{ Status = 200; Body = (J @{ total_count = 1; branch_policies = @(@{ id = 1; name = 'main'; type = 'branch' }) }) }
    }
    return $m
}
function Run($m, [string[]]$Gates = @('apply', 'gate-network'), [string]$Attested = '') {
    $get = { param($p) if ($m.ContainsKey($p)) { $m[$p] } else { @{ Status = 404; Body = $null } } }.GetNewClosure()
    @(Test-CicdGhProtections -Get $get -Repository $R -Environment 'prod' -ReviewedGate $Gates -AttestedPlan $Attested)
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
Check 'preview-only run checks only the preview environment' ((NoFail $f) -and -not (F $f 'reviewer plan') -and @($f).Count -eq 1)

# Plans that cannot enforce required reviewers on private repositories.
foreach ($plan in 'free', 'team', 'pro') {
    $f = Run (Base 'private' 'Organization' $plan)
    Check "neg: private repo on org plan '$plan' fails" ((F $f 'reviewer plan').Status -eq 'fail' -and (F $f 'reviewer plan').Evidence -match "plan '$plan'")
}
$f = Run (Base 'private' 'User' $null)
Check 'neg: private user-owned repository fails (Free/Pro)' ((F $f 'reviewer plan').Status -eq 'fail' -and (F $f 'reviewer plan').Evidence -match 'user account')
$f = Run (Base 'internal' 'Organization' $null)
Check 'neg: unreadable org plan fails closed' ((F $f 'reviewer plan').Status -eq 'fail' -and (F $f 'reviewer plan').Evidence -match 'cannot prove')
$f = Run (Base 'private' 'Organization' $null) -Attested 'enterprise'
Check 'unreadable plan + attestation is attested (NOT PROVED), not pass' ((F $f 'reviewer plan').Status -eq 'attested' -and (F $f 'reviewer plan').Evidence -match 'NOT PROVED' -and (NoFail $f))
$f = Run (Base 'private' 'Organization' 'team') -Attested 'enterprise'
Check 'neg: attestation cannot override a readable non-enterprise plan' ((F $f 'reviewer plan').Status -eq 'fail')
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

# Environments and reviewers.
$m = Base; $m.Remove("/repos/$R/environments/prod-gate-network"); $f = Run $m
Check 'neg: missing gate environment fails' ((F $f 'prod-gate-network').Status -eq 'fail' -and (F $f 'prod-gate-network').Evidence -match 'missing')
$m = Base; $m["/repos/$R/environments/prod-apply"].Body.protection_rules = @(); $f = Run $m
Check 'neg: apply without required reviewers fails' ((F $f 'prod-apply reviewers').Status -eq 'fail')
$m = Base; $m["/repos/$R/environments/prod-apply"].Body.protection_rules = @(J @{ type = 'wait_timer'; wait_timer = 5 }); $f = Run $m
Check 'neg: a wait timer is not a reviewer' ((F $f 'prod-apply reviewers').Status -eq 'fail')
$m = Base; $m["/repos/$R/environments/prod-apply"].Body.can_admins_bypass = $true; $f = Run $m
Check 'admin bypass is reported' ((F $f 'prod-apply reviewers').Evidence -match 'bypass')
$f = Run (Base) -Gates @('apply') ; $throwGet = { param($p) throw 'network down' }
$t = @(Test-CicdGhProtections -Get $throwGet -Repository $R -Environment 'prod' -ReviewedGate 'apply')
Check 'neg: transport error fails closed' ($t.Count -eq 1 -and $t[0].Status -eq 'fail')

Write-Host "Test-CicdGitHubEnvironments: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0 -or $script:pass -lt 26) { exit 1 }
