#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'infra\quickstart\Deploy-Quickstart.ps1') -DotSourceOnly
Import-Module (Join-Path $root 'scripts\Onboarding.Projects.psm1') -Force -DisableNameChecking
$pass = 0
function Check($name, $ok) { if (-not $ok) { throw "FAIL: $name" }; $script:pass++; Write-Host "PASS: $name" }
function Limits { @{ tokensPerMinute = 1000000; tokenQuota = 500000; tokenQuotaPeriod = 'Daily' } }
function Parameters {
    @{ groups = @(@{
        groupId = '22222222-2222-2222-2222-222222222222'; projectId = 'EXAMPLE01'; classification = 'STD'
        displayName = 'Informational group name'
        familyPolicy = @{ aggregateLimits = @{ person = (Limits); group = (Limits) }
            families = @{ haiku = @{ models = @('claude-haiku-4-5'); person = (Limits); group = (Limits) } } }
        personBudget = @{ amount = 25000; currency = 'CCU'; period = 'monthly' }; aggregateBudget = $null
        aggregateMode = 'notify'; onboardingMode = 'warn'
    }); backends = @(@{ id = 'foundry-example'; subscriptionId = '11111111-1111-1111-1111-111111111111'; resource = 'https://cognitiveservices.azure.com' }) }
}
function Refused($p) {
    try { $null = New-QsSeedDocuments $p; return $false } catch { return $true }
}
$p = Parameters
$docs = New-QsSeedDocuments $p
$c = $docs.projects[0].classifications.STD
Check 'seed copies entire familyPolicy and aggregate limits verbatim' (($c.familyPolicy | ConvertTo-Json -Depth 30 -Compress) -ceq ($p.groups[0].familyPolicy | ConvertTo-Json -Depth 30 -Compress))
Check 'seed no longer emits old admission fields' (-not $c.Contains('modelAllowList') -and -not $c.Contains('tokenLimits'))
Check 'new project passes staged onboarding boundary' ([bool](ConvertTo-OnboardingProjectDocument ($docs.projects[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable)))
foreach ($classification in @('STD','PRM','cyb','CYB-extra')) {
    foreach ($family in @('fable','mythos')) {
        $p = Parameters; $p.groups[0].classification = $classification
        $p.groups[0].familyPolicy.families[$family] = @{}
        Check "$classification rejects even empty $family" (Refused $p)
    }
}
foreach ($mutate in @(
    { param($g) $g.Remove('familyPolicy') },
    { param($g) $g.modelAllowList = @('claude-haiku-4-5') },
    { param($g) $g.familyPolicy.families.haiku.models = @('claude-sonnet-5') },
    { param($g) $g.familyPolicy.families.haiku.models = @('claude-haikux-5') },
    { param($g) $g.familyPolicy.families.haiku.models = @('alias','alias') },
    { param($g) $g.familyPolicy.families.sonnet = @{ models = @('claude-haiku-4-5'); person = (Limits); group = (Limits) } },
    { param($g) $g.familyPolicy.families.haiku.person.tokensPerMinute = 2147483648 },
    { param($g) $g.familyPolicy.families.haiku.person.tokenQuota = 9007199254740992 },
    { param($g) $g.familyPolicy.families.haiku.person.extra = 1 },
    { param($g) $g.familyPolicy.families.haiku.person.tokenQuotaPeriod = $null },
    { param($g) $g.familyPolicy.families = @{} },
    { param($g) $g.familyPolicy.families.HAIKU = $g.familyPolicy.families.haiku; $g.familyPolicy.families.Remove('haiku') }
)) {
    $p = Parameters; & $mutate $p.groups[0]
    Check "seed rejects malformed policy: $mutate" (Refused $p)
}
$p = Parameters; $p.groups += $p.groups[0].Clone()
Check 'duplicate classification cannot silently overwrite' (Refused $p)
$p = Parameters; $p.groups[0].familyPolicy.families.haiku.models = @('approved-alias')
$null = New-QsSeedDocuments $p
Check 'explicit deployment alias accepted without prefix inference' $true
$p = Parameters
$p.groups[0].familyPolicy.families.haiku.person = @{tokensPerMinute=$null;tokenQuota=$null;tokenQuotaPeriod=$null}
$null = New-QsSeedDocuments $p
Check 'all-null family limits retain explicit model admission' $true
$p = Parameters; $p.groups[0].classification = 'CYB'
$p.groups[0].familyPolicy.families.fable = @{ models = @('operator-established-alias'); person = (Limits); group = (Limits) }
$null = New-QsSeedDocuments $p
Check 'exact CYB accepts explicitly registered operator deployment alias' $true
$p = Parameters; $p.backends += @{id='foundry-other';subscriptionId='33333333-3333-3333-3333-333333333333';resource='https://cognitiveservices.azure.com'}
Check 'multiple backends require explicit project routing' (Refused $p)
$p.groups[0].backendId='foundry-other'
$docs=New-QsSeedDocuments $p
Check 'project routing copies selected backend and subscription' ($docs.projects[0].backendId -ceq 'foundry-other' -and $docs.projects[0].designatedSubscriptionId -ceq $p.backends[1].subscriptionId)
$p.groups[0].backendId='absent'
Check 'unknown backend fails closed' (Refused $p)
$p=Parameters; $p.groups[0].backendId='foundry-example'
$p.groups += $p.groups[0].Clone(); $p.groups[1].classification='PRM';$p.groups[1].groupId='44444444-4444-4444-4444-444444444444';$p.groups[1].backendId='other'
$p.backends += @{id='other';subscriptionId='33333333-3333-3333-3333-333333333333';resource='https://cognitiveservices.azure.com'}
Check 'classifications of one project cannot route to different backends' (Refused $p)
$p=Parameters; $p.backends += $p.backends[0].Clone()
Check 'duplicate backend ids fail closed' (Refused $p)
$p=Parameters; $p.groups += $p.groups[0].Clone();$p.groups[1].projectId='example01'
$docs=New-QsSeedDocuments $p
Check 'project identity is ordinal, not case-folded' ($docs.projects.Count -eq 2)
$p=Parameters;$p.groups[0].classificationGroupDisplayName=' CYB "Approved" Ω '
$docs=New-QsSeedDocuments $p
Check 'group display snapshot preserves exact informational text' ($docs.projects[0].classifications.STD.classificationGroupDisplayName -ceq ' CYB "Approved" Ω ')
$p.groups[0].classificationGroupDisplayName=''
Check 'empty group snapshot rejected' (Refused $p)
$script:azureCalls=0
function Invoke-QsAz {param($Arguments);$script:azureCalls++;throw 'unexpected Azure call'}
$p=Parameters;$p.backends += @{id='other';subscriptionId='33333333-3333-3333-3333-333333333333';resource='https://cognitiveservices.azure.com'}
$refused=try {$null=Test-QsPrerequisites @{P=$p};$false}catch{$true}
Check 'ambiguous routing preflight refuses before any Azure call' ($refused -and $script:azureCalls -eq 0)
foreach($model in @("claude-haiku-4-5`n","approved-alias`n")) {
    $p=Parameters;$p.groups[0].familyPolicy.families.haiku.models=@($model)
    Check 'whole model ID rejects final newline' (Refused $p)
}
$p=Parameters;$names=@{$p.groups[0].groupId='Captured Ω name'}
$docs=New-QsSeedDocuments -P $p -ClassificationGroupDisplayNames $names
Check 'saved preflight snapshot survives resumed seed invocation' ($docs.projects[0].classifications.STD.classificationGroupDisplayName -ceq 'Captured Ω name')
$p=Parameters;$p.backends += @{id='other';subscriptionId='33333333-3333-3333-3333-333333333333';resource='https://cognitiveservices.azure.com'}
$script:azureCalls=0
$refused=try {$null=Invoke-QsDeploy @{P=$p;State=@{completed=@{}}};$false}catch{$true}
Check 'resumed deployment rejects ambiguous routing before any Azure call' ($refused -and $script:azureCalls -eq 0)
Write-Host "$pass passed, 0 failed"
