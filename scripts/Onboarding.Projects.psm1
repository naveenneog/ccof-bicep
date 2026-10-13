#Requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Decisions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Schemas.psm1')

function ConvertTo-OnboardingProjectDocument {
    param([hashtable]$Project, [switch]$FromCosmos)
    $document = ConvertFrom-OnboardingJson ($Project | ConvertTo-Json -Depth 64)
    if ($FromCosmos) {
        foreach ($field in @('_rid','_self','_etag','_attachments','_ts')) { $document.Remove($field) }
    }
    Assert-OnboardingSchema $document (Get-OnboardingProjectSchema)
    if (-not [string]::Equals($document.id, $document.projectId, 'Ordinal')) { Stop-Onboarding 'Project id must equal projectId ordinally.' }
    $groups = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $document.classifications.Values) {
        if (-not $groups.Add(([guid]$entry.groupId).ToString())) { Stop-Onboarding 'A classification group cannot be reused within the project.' }
    }
    return $document
}

function Assert-OnboardingResilience {
    param([hashtable]$Resilience)
    Assert-OnboardingSchema $Resilience (Get-OnboardingResilienceSchema)
    if ($Resilience.budgetStateHardLimitSeconds -lt $Resilience.budgetStateGraceSeconds) {
        Stop-Onboarding 'resilience.budgetStateHardLimitSeconds must be at least budgetStateGraceSeconds.'
    }
}

function Get-OnboardingProjectGroups {
    param([hashtable]$Project, [hashtable]$Operations)
    $seen = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $result=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($classification in $Project.classifications.Keys) {
        $id=$Project.classifications[$classification].groupId
        $group=& $Operations.GetGroup $id
        if (-not $group -or -not [string]::Equals($group.id,$id,'Ordinal') -or
            $group.securityEnabled -ne $true -or $group.mailEnabled -ne $false -or
            @($group.groupTypes).Count -ne 0 -or $group.isAssignableToRole -eq $true) {
            Stop-Onboarding "Classification '$classification' needs an existing flat, non-role-assignable security group."
        }
        $members=@(& $Operations.GetMembers $id)
        foreach ($member in $members) {
            if ($member.'@odata.type' -notin @('#microsoft.graph.user','#microsoft.graph.servicePrincipal') -or
                $member.id -notmatch '^[0-9a-fA-F-]{36}$') { Stop-Onboarding "Classification '$classification' contains a nested group or unsupported member." }
            if ($seen.ContainsKey($member.id) -and -not [string]::Equals($seen[$member.id],$classification,'Ordinal')) {
                Stop-Onboarding "Conflicting classification groups: '$($seen[$member.id])' and '$classification'."
            }
            $seen[$member.id]=$classification
        }
        $result[$classification]=@{groupId=$id;displayName=$group.displayName;memberIds=@($members|ForEach-Object{$_.id})}
    }
    return $result
}

function Assert-OnboardingProjectBackend {
    param([hashtable]$Project, $Backend)
    $prefix="/subscriptions/$($Project.designatedSubscriptionId)/"
    if (-not $Backend -or -not ([string]$Backend.properties.resourceId).StartsWith($prefix,'Ordinal') -or
        $Backend.properties.resourceId -notmatch '/providers/Microsoft\.CognitiveServices/accounts/[A-Za-z0-9._-]+$' -or
        $Backend.properties.url -notmatch '^https://[A-Za-z0-9-]+\.services\.ai\.azure\.com/anthropic$' -or $Backend.properties.protocol -ne 'http') {
        Stop-Onboarding 'backendId must name a registered Foundry backend in the designated subscription with an /anthropic URL.'
    }
}
Export-ModuleMember -Function ConvertTo-OnboardingProjectDocument, Assert-OnboardingResilience, Get-OnboardingProjectGroups, Assert-OnboardingProjectBackend
