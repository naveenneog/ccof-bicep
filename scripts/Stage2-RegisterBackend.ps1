#Requires -Version 7.0
<#
.SYNOPSIS
    Stage 2: confirmed same-tenant Foundry backend, managed-identity grants and cost visibility.
#>
[CmdletBinding()]
param([switch]$DotSourceOnly, [string]$AnswersFile, [string]$CheckpointPath, [switch]$Interactive, [switch]$DiscoverOnly)
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Decisions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Schemas.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Azure.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Backend.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Prerequisites.psm1')

function Invoke-Stage2RegisterBackend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$CheckpointPath,
        [string]$AnswersFile, [switch]$Interactive, [switch]$DiscoverOnly,
        [scriptblock]$Prompt, [scriptblock]$GetIdentity, [scriptblock]$GetCurrentAssignments, [hashtable]$Operations
    )
    $run = @{ Stage='2'; Schema=(Get-OnboardingSchema '2'); CheckpointPath=$CheckpointPath
        AnswersFile=$AnswersFile; Interactive=$Interactive; DiscoverOnly=$DiscoverOnly }
    if ($Prompt) { $run.Prompt=$Prompt }; if ($GetIdentity) { $run.GetIdentity=$GetIdentity }
    $body = {
        param($c)
        $a = $c.Decisions; $c.StageId = "stage-2-backend:$($a.backendId)"
        Assert-OnboardingPrerequisites $c @('stage-D2:apim')
        if(-not $a.apimResourceId.StartsWith("/subscriptions/$($a.subscriptionId)/",'Ordinal')){
            Stop-Onboarding 'The APIM resource must belong to the explicitly selected deployment subscription.' 'apim_subscription_mismatch'
        }
        if([string]::Equals($a.backendAuthMode,'second-tenant','Ordinal')){
            if([string]::Equals($a.backendTenantId,$a.tenantId,'Ordinal')){Stop-Onboarding 'Second-tenant authentication requires a different backend tenant.' 'backend_tenant_mismatch'}
            Assert-OnboardingRole $c $a.apimResourceId @('Reader','Contributor','Owner','API Management Service Reader Role','API Management Service Contributor') $GetCurrentAssignments
            $ops=if($Operations){$Operations}else{New-OnboardingBackendOperations $a}
            $backend=& $ops.GetBackend $a.backendId
            if(-not $backend -or -not [string]::Equals($backend.name,$a.backendId,'Ordinal') -or
                $backend.properties.url -notmatch '^https://[A-Za-z0-9-]+\.services\.ai\.azure\.com/anthropic$'){
                Stop-Onboarding 'D2 must configure the selected existing second-tenant Foundry backend first.' 'backend_not_found'
            }
            $auth=$a.secondTenantAuth
            if(($auth.mode -eq 'credential-manager' -and ($auth.clientId -or $auth.secretNamedValueId)) -or
                ($auth.mode -eq 'existing-named-values' -and ($auth.providerId -or $auth.connectionId))){
                Stop-Onboarding 'Only one second-tenant credential reference shape is permitted.' 'credential_reference_conflict'
            }
            $reference=& $ops.GetCredentialReference $auth
            if($reference.exists -ne $true -or ($auth.mode -eq 'existing-named-values' -and $reference.secure -ne $true)){
                Stop-Onboarding 'The D2 credential reference is missing or is not marked secret.' 'credential_reference_missing'
            }
            $evidence=@{backendId=$a.backendId;backendTenantId=$a.backendTenantId;backendUrl=$backend.properties.url
                auth=$auth;configurationOwner='stage-D2';permissionsOwner='stage-D3';runtimeAuthVerified=$false}
            if(-not (Confirm-OnboardingDiscovery $c $evidence)){return}
            if($auth.mode -eq 'credential-manager'){
                $evidence.backendDescriptor=@{id=$a.backendId;backendId=$a.backendId;status='active';apiFormat='anthropic-messages'
                    auth=@{mode='credential-manager';providerId=$auth.providerId;connectionId=$auth.connectionId}}
            }
            return $evidence
        }
        $subscriptionScope = "/subscriptions/$($a.designatedSubscriptionId)"
        if (-not $a.apimResourceId.StartsWith("/subscriptions/$($a.subscriptionId)/", 'Ordinal') -or
            -not $a.foundryAccountResourceId.StartsWith("$subscriptionScope/", 'Ordinal')) {
            Stop-Onboarding 'The APIM and Foundry resource ids must belong to the explicitly selected gateway and designated subscriptions.'
        }
        if ($a.backendAuthMode -notin @('managedIdentity','managed-identity')) { Stop-Onboarding 'An explicit supported backend authentication mode is required.' }
        if (-not [string]::Equals($a.backendFailoverOrder[0], $a.backendId, 'Ordinal')) { Stop-Onboarding 'backendFailoverOrder must start with the selected primary backendId.' }
        $from = [DateTimeOffset]::MinValue; $to = $from
        if (-not [DateTimeOffset]::TryParse($a.costQueryPeriod.from, [ref]$from) -or
            -not [DateTimeOffset]::TryParse($a.costQueryPeriod.to, [ref]$to) -or $to -le $from) {
            Stop-Onboarding 'costQueryPeriod must contain valid UTC instants with to later than from.'
        }
        Assert-OnboardingRole $c $a.apimResourceId @('Contributor','Owner','API Management Service Contributor') $GetCurrentAssignments
        Assert-OnboardingRole $c $a.foundryAccountResourceId @('Reader','Contributor','Owner') $GetCurrentAssignments
        Assert-OnboardingRole $c $subscriptionScope @('Reader','Contributor','Owner','Cost Management Reader') $GetCurrentAssignments
        Assert-OnboardingRole $c $a.reconcilerResourceId @('Reader','Contributor','Owner') $GetCurrentAssignments
        $ops = if ($Operations) { $Operations } else { New-OnboardingBackendOperations $a }
        $apim = & $ops.GetApim; $account = & $ops.GetFoundry
        $subscription = & $ops.GetSubscription; $reconciler = & $ops.GetReconciler
        $recIdentity = if ($reconciler.identity) { $reconciler.identity } else { $reconciler.properties }
        if (-not [string]::Equals($apim.id, $a.apimResourceId, 'Ordinal') -or
            -not [string]::Equals($reconciler.id, $a.reconcilerResourceId, 'Ordinal') -or
            -not [string]::Equals($subscription.subscriptionId, $a.designatedSubscriptionId, 'Ordinal')) {
            Stop-Onboarding 'Discovered APIM, reconciler and subscription identities must belong to the selected resources.'
        }
        if (-not [string]::Equals($subscription.tenantId, $a.tenantId, 'Ordinal') -or
            -not [string]::Equals($apim.identity.tenantId, $a.tenantId, 'Ordinal') -or
            -not [string]::Equals($recIdentity.tenantId, $a.tenantId, 'Ordinal')) {
            Stop-Onboarding 'The designated subscription, APIM and reconciler identities must all share the selected tenant.'
        }
        Assert-OnboardingGuid $apim.identity.principalId
        Assert-OnboardingGuid $recIdentity.principalId
        if (-not [string]::Equals($account.id, $a.foundryAccountResourceId, 'Ordinal') -or
            $account.properties.customSubDomainName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,63}$') {
            Stop-Onboarding 'The selected Foundry account needs a valid discovered customSubDomainName; no account name or endpoint is inferred.'
        }
        $url = "https://$($account.properties.customSubDomainName).services.ai.azure.com/anthropic"
        $existing = & $ops.GetBackend $a.backendId
        if ($existing -and (-not [string]::Equals($existing.properties.url, $url, 'Ordinal') -or
            -not [string]::Equals($existing.properties.resourceId, $account.id, 'Ordinal') -or $existing.properties.protocol -ne 'http' -or
            $existing.properties.credentials -or $existing.properties.proxy -or
            $existing.properties.tls.validateCertificateChain -eq $false -or $existing.properties.tls.validateCertificateName -eq $false)) {
            Stop-Onboarding 'An existing backendId has a conflicting account, URL or protocol; it will not be overwritten.'
        }
        $failovers = @()
        foreach ($id in $a.backendFailoverOrder | Select-Object -Skip 1) {
            $candidate = & $ops.GetBackend $id
            if (-not $candidate -or -not ([string]$candidate.properties.resourceId).StartsWith("$subscriptionScope/", 'Ordinal') -or
                $candidate.properties.resourceId -notmatch '/providers/Microsoft\.CognitiveServices/accounts/[A-Za-z0-9._-]+$' -or
                $candidate.properties.url -notmatch '^https://[A-Za-z0-9-]+\.services\.ai\.azure\.com/anthropic$' -or
                $candidate.properties.protocol -ne 'http' -or $candidate.properties.credentials -or $candidate.properties.proxy -or
                $candidate.properties.tls.validateCertificateChain -eq $false -or $candidate.properties.tls.validateCertificateName -eq $false) {
                Stop-Onboarding 'Every failover must be a registered Foundry backend in the same designated subscription.'
            }
            $failovers += @{ backendId=$id; resourceId=$candidate.properties.resourceId; url=$candidate.properties.url }
        }
        $grants = @(
            @{ scope=$account.id; principalId=$apim.identity.principalId; roleName='Cognitive Services User' }
            @{ scope=$subscriptionScope; principalId=$recIdentity.principalId; roleName='Cost Management Reader' }
        )
        foreach ($grant in $grants) {
            $definition = & $ops.GetRoleDefinition $a.designatedSubscriptionId $grant.roleName
            if (-not $definition.id -or -not [string]::Equals($definition.properties.roleName, $grant.roleName, 'Ordinal')) { Stop-Onboarding 'The required role definition did not match its declared role name.' }
            $grant.roleDefinitionId = $definition.id
            $grant.exists = [bool](& $ops.HasRoleAssignment $grant)
        }
        $roleAssignments=@($grants|ForEach-Object{@{principal=$_.principalId;role=$_.roleName;scope=$_.scope}})
        if(-not $c.DiscoverOnly -and @($grants|Where-Object{-not $_.exists}).Count){
            Stop-Onboarding 'D3 must apply and verify the declared role assignments before backend registration. DiscoverOnly returns the permission plan.' 'd3_permissions_missing'
        }
        $visibility = @{ status='unavailable'; rowCount=0; queryIdentityId=$c.Actor.objectId; subscriptionId=$a.designatedSubscriptionId }
        try {
            $cost = & $ops.QueryCost
            if ($cost -and $cost.properties.Contains('rows')) {
                $visibility.rowCount = @($cost.properties.rows).Count
                $visibility.status = if ($visibility.rowCount -gt 0) { 'visible' } else { 'no_rows' }
            }
        }
        catch { $visibility.status = 'unavailable' }
        $discovery = @{
            apimPrincipalId=$apim.identity.principalId; reconcilerPrincipalId=$recIdentity.principalId
            foundryAccountResourceId=$account.id; backendUrl=$url; backendExists=($null -ne $existing)
            grants=$grants;roleAssignments=$roleAssignments; failovers=$failovers; costVisibility=$visibility
        }
        if (-not (Confirm-OnboardingDiscovery $c $discovery)) { return }
        if (-not $existing) {
            $backendBody = @{ properties=@{ url=$url; protocol='http'; resourceId=$account.id
                tls=@{ validateCertificateChain=$true; validateCertificateName=$true } } }
            Invoke-OnboardingWrite $c 'create_backend' $a.backendId ({ & $ops.CreateBackend $a.backendId $backendBody }.GetNewClosure()) | Out-Null
        }
        @{ backendId=$a.backendId; designatedSubscriptionId=$a.designatedSubscriptionId; backendUrl=$url
            authMode=$a.backendAuthMode; apimPrincipalId=$apim.identity.principalId; reconcilerPrincipalId=$recIdentity.principalId
            costVisibility=$visibility; backendFailoverOrder=$a.backendFailoverOrder;roleAssignments=$roleAssignments
            backendDescriptor=@{id=$a.backendId;backendId=$a.backendId;status='active';apiFormat='anthropic-messages';auth=@{mode='managed-identity';resource='https://cognitiveservices.azure.com'}} }
    }.GetNewClosure()
    Invoke-OnboardingRun @run -Body $body
}
if (-not $DotSourceOnly) {
    $result = Invoke-Stage2RegisterBackend -AnswersFile $AnswersFile -CheckpointPath $CheckpointPath -Interactive:$Interactive -DiscoverOnly:$DiscoverOnly
    $result | ConvertTo-Json -Depth 64
    if (-not $result.Satisfied) { exit 1 }
}
