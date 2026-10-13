#Requires -Version 7.0
foreach($module in @('Decisions','Schemas','Projects')){Import-Module (Join-Path $PSScriptRoot "Onboarding.$module.psm1")}

function Get-OnboardingDependencyHash {
    param($Value)
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-OnboardingCanonical $Value))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-OnboardingDependencyEvidence {
    param([hashtable]$Project,[hashtable]$Operations,[string]$BackendMode)
    $groups=Get-OnboardingProjectGroups $Project $Operations
    $backend=& $Operations.GetBackend $Project.backendId
    if($BackendMode -eq 'designated_foundry'){Assert-OnboardingProjectBackend $Project $backend}
    elseif(-not $backend -or -not [string]::Equals($backend.name,$Project.backendId,'Ordinal')){
        Stop-Onboarding 'The selected existing APIM backend was not found under that entity name.' 'backend_not_found'
    }
    $summary=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($key in $groups.Keys){
        $summary[$key]=@{groupId=$groups[$key].groupId;displayName=$groups[$key].displayName;memberCount=$groups[$key].memberIds.Count}
    }
    $uri=$null;$url=$null;$resourceId=$null
    if([uri]::TryCreate([string]$backend.properties.url,[UriKind]::Absolute,[ref]$uri) -and
        $uri.Scheme -eq 'https' -and -not $uri.UserInfo -and -not $uri.Query -and -not $uri.Fragment){$url=$uri.AbsoluteUri}
    if($backend.properties.resourceId -match '^/subscriptions/[0-9a-fA-F-]{36}/[A-Za-z0-9/._-]+$'){$resourceId=$backend.properties.resourceId}
    @{groups=$summary;backend=@{id=$Project.backendId;url=$url;resourceId=$resourceId}}
}

function Assert-OnboardingPlanDeadline {
    param([hashtable]$Decisions,[DateTimeOffset]$Now)
    $deadline=[DateTimeOffset]::MinValue
    if(-not $Decisions.dependencyValidation.validUntil -or
        -not [DateTimeOffset]::TryParse($Decisions.dependencyValidation.validUntil,[ref]$deadline) -or $deadline -le $Now){
        Stop-Onboarding 'dependencyValidation.validUntil must be an explicitly chosen future UTC deadline; no plan lifetime is assumed.' 'plan_deadline_required'
    }
    return $deadline
}

function New-OnboardingDependencyPlan {
    param($Context,[hashtable]$Evidence,[DateTimeOffset]$Now)
    $null=Assert-OnboardingPlanDeadline $Context.Decisions $Now
    $plan=@{schemaVersion=1;kind='project_dependency_preflight';tenantId=$Context.Actor.tenantId;preparedBy=$Context.Actor.objectId
        preparedAt=$Now.ToUniversalTime().ToString('o');validUntil=$Context.Decisions.dependencyValidation.validUntil
        decisionsHash=(Get-OnboardingDependencyHash $Context.Decisions);evidence=$Evidence}
    $plan.digest=Get-OnboardingDependencyHash $plan
    return $plan
}

function Read-OnboardingDependencyPlan {
    param([string]$Path,[hashtable]$Decisions,[DateTimeOffset]$Now)
    if(-not $Path -or -not (Test-Path -LiteralPath $Path)){Stop-Onboarding 'A reviewed dependency plan is required for private apply.' 'dependency_plan_required'}
    try{$plan=ConvertFrom-OnboardingJson (Get-Content -LiteralPath $Path -Raw)}
    catch{Stop-Onboarding 'The dependency plan is not readable JSON.' 'dependency_plan_invalid'}
    $hash=@{type='string';pattern='^[a-f0-9]{64}$'}
    $guid=@{type='string';pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'}
    $group=New-OnboardingObjectSchema @{groupId=$guid;displayName=@{type='string'};memberCount=@{type='integer';minimum=0}}
    $evidence=New-OnboardingObjectSchema @{
        groups=@{type='object';minProperties=1;additionalProperties=$group}
        backend=(New-OnboardingObjectSchema @{id=@{type='string'};url=@{type=@('string','null')};resourceId=@{type=@('string','null')}})
    }
    Assert-OnboardingSchema $plan (New-OnboardingObjectSchema @{
        schemaVersion=@{const=1};kind=@{const='project_dependency_preflight'};tenantId=$guid;preparedBy=$guid
        preparedAt=@{type='string'};validUntil=@{type='string'};decisionsHash=$hash;digest=$hash;evidence=$evidence
    })
    $copy=ConvertFrom-OnboardingJson ($plan|ConvertTo-Json -Depth 64)
    $copy.Remove('digest')
    if(-not [string]::Equals($plan.digest,(Get-OnboardingDependencyHash $copy),'Ordinal') -or
        -not [string]::Equals($plan.decisionsHash,(Get-OnboardingDependencyHash $Decisions),'Ordinal') -or
        -not [string]::Equals($plan.tenantId,$Decisions.tenantId,'Ordinal') -or
        -not [string]::Equals($plan.validUntil,$Decisions.dependencyValidation.validUntil,'Ordinal')){
        Stop-Onboarding 'The dependency plan or its decisions changed; a new reviewed preflight is required.' 'dependency_plan_mismatch'
    }
    $created=[DateTimeOffset]::MinValue;$until=$created
    if(-not [DateTimeOffset]::TryParse($plan.preparedAt,[ref]$created) -or
        -not [DateTimeOffset]::TryParse($plan.validUntil,[ref]$until) -or $created -gt $Now -or $until -le $Now -or $until -le $created){
        Stop-Onboarding 'The dependency plan is expired or has invalid timestamps.' 'dependency_plan_expired'
    }
    if(-not [string]::Equals($plan.evidence.backend.id,$Decisions.project.backendId,'Ordinal') -or
        $plan.evidence.groups.Count -ne $Decisions.project.classifications.Count){Stop-Onboarding 'The plan does not cover the selected project dependencies.' 'dependency_plan_mismatch'}
    foreach($key in $Decisions.project.classifications.Keys){
        if(-not @($plan.evidence.groups.Keys|Where-Object{[string]::Equals($_,$key,'Ordinal')}).Count -or
            -not [string]::Equals($plan.evidence.groups[$key].groupId,$Decisions.project.classifications[$key].groupId,'Ordinal')){
            Stop-Onboarding 'The plan classification group does not match the project.' 'dependency_plan_mismatch'
        }
    }
    return $plan
}
Export-ModuleMember -Function Get-OnboardingDependencyHash, Get-OnboardingDependencyEvidence, Assert-OnboardingPlanDeadline, New-OnboardingDependencyPlan, Read-OnboardingDependencyPlan
