#Requires -Version 7.0
<#
.SYNOPSIS
    Stage 1: explicitly named flat classification groups and project-lead ownership.
    Answers and confirmed discoveries are attributed to the signed-in identity.
#>
[CmdletBinding()]
param(
    [switch]$DotSourceOnly, [string]$AnswersFile, [string]$CheckpointPath,
    [switch]$Interactive, [switch]$DiscoverOnly
)

Import-Module (Join-Path $PSScriptRoot 'Onboarding.Decisions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Schemas.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Azure.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Groups.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Prerequisites.psm1')

function Invoke-Stage1CreateGroups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$CheckpointPath,
        [string]$AnswersFile, [switch]$Interactive, [switch]$DiscoverOnly,
        [scriptblock]$Prompt, [scriptblock]$GetIdentity, [scriptblock]$GetCurrentAssignments,
        [hashtable]$Operations
    )
    $run = @{
        Stage = '1'; Schema = (Get-OnboardingSchema '1'); CheckpointPath = $CheckpointPath
        AnswersFile = $AnswersFile; Interactive = $Interactive; DiscoverOnly = $DiscoverOnly
    }
    if ($Prompt) { $run.Prompt = $Prompt }; if ($GetIdentity) { $run.GetIdentity = $GetIdentity }
    $body = {
        param($c)
        $a = $c.Decisions; $c.StageId = "stage-1-groups:$($a.projectId)"
        Assert-OnboardingPrerequisites $c @('stage-D1')
        $classes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $aliases = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($spec in $a.classifications) {
            if (-not $classes.Add($spec.classification) -or -not $names.Add($spec.groupName) -or -not $aliases.Add($spec.mailNickname)) {
                Stop-Onboarding 'Classification ids, group names and mail nicknames must be distinct within the project.'
            }
        }
        $ops = if ($Operations) { $Operations } else { New-OnboardingGraphOperations $a.subscriptionId }
        $selfService=[string]::Equals($a.creationAuthority,'selfServiceOwner','Ordinal')
        if (-not $selfService) {
            Assert-OnboardingRole $c '/' @('Groups Administrator','Global Administrator') $GetCurrentAssignments 'directory'
        }
        else {
            if (-not @($a.projectLeadIds|Where-Object{[string]::Equals($_,$c.Actor.objectId,'Ordinal')}).Count) {
                Stop-Onboarding 'The self-service creator must be an explicitly chosen project owner.' 'creator_not_selected'
            }
            $creator=& $ops.GetPrincipal $c.Actor.objectId
            if (-not [string]::Equals($creator.id,$c.Actor.objectId,'Ordinal') -or $creator.accountEnabled -ne $true -or
                -not [string]::Equals($creator.userType,'Member','Ordinal')) {
                Stop-Onboarding 'Self-service group creation requires an enabled member user, not a guest or application.' 'creator_not_member'
            }
        }
        foreach ($lead in $a.projectLeadIds) {
            $principal = & $ops.GetPrincipal $lead
            if (-not $principal -or -not [string]::Equals($principal.id, $lead, 'Ordinal') -or $principal.accountEnabled -ne $true) {
                Stop-Onboarding 'Every project lead must resolve to the explicitly supplied, enabled user object.'
            }
        }
        $groups = @(); $ownerMap = @{}
        foreach ($spec in $a.classifications) {
            $found = @(& $ops.FindGroups $spec.groupName)
            if ($found.Count -gt 1) { Stop-Onboarding 'A chosen group name resolves to multiple groups; explicit unambiguous groups are required.' }
            $group = if ($found.Count) { $found[0] } else { $null }
            $receipt=Get-OnboardingCreatedGroupId $c $spec.classification
            if ($receipt) {
                if ($group -and -not [string]::Equals($group.id,$receipt,'Ordinal')) {Stop-Onboarding 'The group name conflicts with its creation receipt.' 'group_receipt_conflict'}
                if (-not $group) {
                    $group=& $ops.GetGroup $receipt
                    if (-not $group) {Stop-Onboarding 'A previously created group is not readable yet; no duplicate will be created.' 'created_group_unavailable'}
                }
            }
            if ($group) {
                Assert-OnboardingGuid $group.id
                if (-not [string]::Equals($group.displayName, $spec.groupName, 'Ordinal') -or
                    -not [string]::Equals($group.mailNickname, $spec.mailNickname, 'Ordinal') -or
                    $group.securityEnabled -ne $true -or $group.mailEnabled -ne $false -or
                    @($group.groupTypes).Count -ne 0 -or $group.isAssignableToRole -eq $true) {
                    Stop-Onboarding 'Existing group conflicts with the chosen name, alias or flat, non-role-assignable security-group requirements.'
                }
                $ownerMap[$group.id] = @(& $ops.GetOwners $group.id)
                if ($selfService -and -not @($ownerMap[$group.id]|Where-Object{[string]::Equals($_,$c.Actor.objectId,'Ordinal')}).Count) {
                    Stop-Onboarding 'Self-service authority does not cover an existing group the signed-in user does not own.' 'group_not_owned'
                }
            }
            $groups += @{ classification = $spec.classification; groupName = $spec.groupName
                mailNickname = $spec.mailNickname; groupId = $group.id }
        }
        $creationAllowed=$null
        if ($selfService -and @($groups|Where-Object{-not $_.groupId}).Count) {
            try {$policy=& $ops.GetCreationPolicy}
            catch {Stop-Onboarding 'The security-group creation policy could not be read. Policy.Read.All delegated access or administrator review is required before creating groups.' 'creation_policy_unavailable'}
            $creationAllowed=$policy.defaultUserRolePermissions.allowedToCreateSecurityGroups
            if ($creationAllowed -isnot [bool]) {Stop-Onboarding 'The security-group creation policy was not verified.' 'creation_policy_unavailable'}
            if (-not $creationAllowed) {Stop-Onboarding 'The security-group creation policy is disabled. A Groups Administrator can create the groups; no group was written.' 'creation_policy_disabled'}
            $creatorRoles={param($scope) if ($creationAllowed) {@{roleDefinitionName='Security Group Creator'}}}.GetNewClosure()
            Assert-OnboardingRole $c '/' @('Security Group Creator') $creatorRoles 'directory'
        }
        if (-not (Confirm-OnboardingDiscovery $c @{ groups = $groups; projectLeadIds = $a.projectLeadIds;creationAuthority=$a.creationAuthority;creationAllowed=$creationAllowed })) { return }
        $created = @(); $added = 0
        foreach ($group in $groups) {
            if (-not $group.groupId) {
                $logicalId="$($a.projectId):$($group.classification)"
                $new = Invoke-OnboardingWrite $c 'create_group' $logicalId ({ & $ops.CreateGroup $group }.GetNewClosure())
                Assert-OnboardingGuid $new.id
                Write-OnboardingAudit $c 'resource_created' @{operation='create_group';target=$logicalId;resourceId=$new.id}
                $group.groupId = $new.id; $ownerMap[$new.id] = @(& $ops.GetOwners $new.id); $created += $group.groupName
                if ($selfService -and -not @($ownerMap[$new.id]|Where-Object{[string]::Equals($_,$c.Actor.objectId,'Ordinal')}).Count) {
                    Stop-Onboarding 'Created group ownership is not verified. The creation receipt is retained; an administrator can review ownership before retry.' 'created_group_not_owned'
                }
            }
            foreach ($lead in $a.projectLeadIds) {
                if (-not @($ownerMap[$group.groupId] | Where-Object { [string]::Equals($_, $lead, 'Ordinal') }).Count) {
                    Invoke-OnboardingWrite $c 'add_group_owner' $group.groupId ({ & $ops.AddOwner $group.groupId $lead }.GetNewClosure()) | Out-Null
                    $added++
                }
            }
        }
        @{ projectId = $a.projectId; groups = $groups; createdGroups = $created; ownersAdded = $added
            alreadyComplete = ($created.Count -eq 0 -and $added -eq 0) }
    }.GetNewClosure()
    $result = Invoke-OnboardingRun @run -Body $body
    $result | Add-Member -NotePropertyName AlreadyComplete -NotePropertyValue ([bool]$result.Evidence.alreadyComplete)
    $result | Add-Member -NotePropertyName CreatedGroups -NotePropertyValue @($result.Evidence.createdGroups)
    return $result
}

if (-not $DotSourceOnly) {
    $result = Invoke-Stage1CreateGroups -AnswersFile $AnswersFile -CheckpointPath $CheckpointPath -Interactive:$Interactive -DiscoverOnly:$DiscoverOnly
    $result | ConvertTo-Json -Depth 64
    if (-not $result.Satisfied) { exit 1 }
}
