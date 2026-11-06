<#
.SYNOPSIS
  Deploy and verify Azure Front Door Premium for the active/passive CCOF gateways.

.DESCRIPTION
  -Phase Deploy    Preview without -Apply; deploy profile, WAF, APIM and admin origins and routes with -Apply.
  -Phase Approve   Approve independently reviewed target-side private endpoint connection IDs.
  -Phase Verify    Read back Front Door origins, APIM connections, and gateway/admin routes through the FD hostname.
  -Phase Lockdown  After Verify passes, disable direct public access to both APIM origins.

  -PrimaryOnly     Before region B exists: Deploy, Approve and Verify region A's APIM and admin origins
                   only. Region B's origins are added later by the same phases without -PrimaryOnly;
                   the profile, endpoint and host name stay the same. Lockdown and the drill phases
                   refuse to run in this mode.

  Each phase is idempotent and stores its result in standby.stateDirectory/frontdoor-state.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Deploy', 'Approve', 'Verify', 'Lockdown', 'DrainPrimary', 'RestorePrimary')] [string]$Phase,
    [Parameter(Mandatory)] [string]$ConfigPath,
    [switch]$Apply,
    [switch]$PrimaryOnly,
    [switch]$ConfirmStandbyReady,
    [string]$ReviewedConnectionIds
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path (Split-Path $here -Parent) -Parent
function Stop-Dr([string]$Message, [int]$Code = 2) { [Console]::Error.WriteLine($Message); exit $Code }
function Invoke-DrAz([string[]]$Arguments, [switch]$AllowMissing) {
    $result = @(& az @Arguments --output json 2>&1)
    $code = $LASTEXITCODE
    $err = @($result | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) -join "`n"
    $out = @($result | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })
    if ($code -ne 0) {
        $message = "$err $out"
        if ($AllowMissing -and $message -match 'NotFound|ResourceNotFound|could not be found|ResourceGroupNotFound') { return $null }
        throw "az $($Arguments[0..([Math]::Min(1, $Arguments.Count - 1))] -join ' ') failed: $($message.Substring(0, [Math]::Min(500, $message.Length)))"
    }
    $json = ($out -join "`n").Trim()
    if (-not $json) { return $null }
    return $json | ConvertFrom-Json -AsHashtable -Depth 100
}
$script:fdStateHash = $null
# State access goes through DrFrontDoorState.psm1 (short exclusive lock, compare-before-write, atomic replace).
# Save-FdState expects the file to be unchanged since the hash given (by default, this run's last read).
function Save-FdState($Value, [string]$ExpectedHash = $script:fdStateHash) {
    $script:fdStateHash = Save-DrFrontDoorState -StatePath $statePath -Value $Value -ExpectedHash $ExpectedHash
    Write-Host "Front Door state: $statePath"
}
# For phases that changed Front Door configuration: if the state changed concurrently, any verification
# recorded meanwhile may describe the old or half-applied configuration, so it is cleared before failing.
function Save-FdChangedConfigState($Value, [string]$ExpectedHash) {
    try { Save-FdState $Value $ExpectedHash }
    catch {
        if ($_.Exception.Message -like 'frontdoor_state_changed:*') {
            Clear-DrFrontDoorStateEvidence -StatePath $statePath -Fields @('verifiedAt')
            throw "$($_.Exception.Message) Route verification recorded meanwhile was cleared; rerun -Phase $Phase."
        }
        throw
    }
}
# Stage 1 records apimId and apimGatewayUrl only when it created the APIM. For an existing APIM the ID
# comes from the staged config the same way as Get-StgApim (Staged.Common.ps1) and the URL from ARM.
function Get-FdApim($Outputs, $Cfg, [string]$Region) {
    $apimId = [string](Get-DrValue $Outputs 'apimId')
    if (-not $apimId) {
        $apimName = [string](Get-DrValue $Outputs 'apimName')
        $ref = if ($apimName) { @{ subscriptionId = [string](Get-DrValue $Cfg 'subscriptionId'); resourceGroup = [string](Get-DrValue $Cfg 'resourceGroup'); name = $apimName } }
               else { @{ subscriptionId = [string](Get-DrValue $Cfg 'apim.existing.subscriptionId'); resourceGroup = [string](Get-DrValue $Cfg 'apim.existing.resourceGroup'); name = [string](Get-DrValue $Cfg 'apim.existing.name') } }
        if (-not $ref.subscriptionId -or -not $ref.resourceGroup -or -not $ref.name) {
            Stop-Dr "Region $Region APIM is unknown: stage 1 state has no apimId and the staged config has no apim.existing subscriptionId, resourceGroup and name."
        }
        $apimId = "/subscriptions/$($ref.subscriptionId)/resourceGroups/$($ref.resourceGroup)/providers/Microsoft.ApiManagement/service/$($ref.name)"
    }
    $url = [string](Get-DrValue $Outputs 'apimGatewayUrl')
    if (-not $url) {
        $apim = Invoke-DrAz @('rest', '--method', 'get', '--url', "https://management.azure.com${apimId}?api-version=2024-05-01")
        $url = [string](Get-DrValue $apim 'properties.gatewayUrl')
    }
    $apimHost = if ($url) { ([uri]$url).Host } else { '' }
    if (-not $apimHost) { Stop-Dr "Region $Region APIM gateway host is unknown: stage 1 state has no apimGatewayUrl and APIM '$apimId' returned no properties.gatewayUrl." }
    return @{ Id = $apimId; Host = $apimHost }
}
function Get-FdState {
    $read = Read-DrFrontDoorState -StatePath $statePath
    $script:fdStateHash = $read.Hash
    return $read.State
}
# Approvals saved before reviewed provenance existed were selected by request description and are not trusted.
function Get-FdApprovalProblem($State, [int]$Expected) {
    $approved = @(Get-DrValue $State 'approvedConnections' | Where-Object { $_ })
    if ($approved.Count -lt $Expected) { return 'frontdoor_approval_missing: run -Phase Approve -Apply first.' }
    $reviewedIds = @(Get-DrValue $State 'reviewedConnections' | Where-Object { $_ })
    foreach ($id in $approved) {
        if (-not @($reviewedIds | Where-Object { [string]$_ -ieq [string]$id }).Count) {
            return "frontdoor_approval_unreviewed: $id was saved without reviewed provenance; rerun -Phase Approve -Apply with -ReviewedConnectionIds."
        }
    }
    return $null
}
function Test-FdConnectionId([string]$Id, [string]$TargetId) {
    $prefix = "$TargetId/privateEndpointConnections/"
    return $Id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
        $Id.Substring($prefix.Length) -cmatch '^[A-Za-z0-9._-]+$'
}
function Get-FdHeader($Headers, [string]$Name) {
    if ($null -eq $Headers) { return '' }
    foreach ($entry in $Headers.GetEnumerator()) {
        if ([string]$entry.Key -ieq $Name) {
            if ($entry.Value -is [string]) { return [string]$entry.Value }
            $values = @($entry.Value)
            if ($values.Count) { return [string]$values[0] }
        }
    }
    return ''
}
function Get-FdRetrySeconds($Response) {
    $retry = Get-FdHeader $Response.Headers 'Retry-After'
    if (-not $retry) { return 5 }
    $seconds = 0
    if (-not [int]::TryParse($retry, [ref]$seconds) -or $seconds -lt 0) {
        throw 'frontdoor_restore_retry_after_invalid: cannot safely poll the operation; inspect it manually.'
    }
    return $seconds
}
function Invoke-FdArmHttp([string]$Method, [string]$Url, [hashtable]$Headers, [string]$Body = '') {
    $request = @{ Method = $Method; Uri = $Url; Headers = $Headers; SkipHttpErrorCheck = $true
        MaximumRedirection = 0; TimeoutSec = 60 }
    if ($Method -ieq 'Patch') { $request.Body = $Body; $request.ContentType = 'application/json' }
    try { return Invoke-WebRequest @request }
    catch { throw "frontdoor_restore_http_error: $Method failed for the verified ARM target; inspect the operation and origin manually." }
}
function ConvertFrom-FdResponse($Response, [switch]$AllowEmpty) {
    $content = [string]$Response.Content
    if (-not $content) {
        if ($AllowEmpty) { return $null }
        throw 'frontdoor_restore_response_invalid: the ARM response has no JSON body; inspect the operation and origin manually.'
    }
    try { return $content | ConvertFrom-Json -AsHashtable -Depth 100 }
    catch { throw 'frontdoor_restore_response_invalid: the ARM response is not valid JSON; inspect the operation and origin manually.' }
}
function Wait-FdRestoreOperation($Response, [hashtable]$Headers, [string]$SubscriptionId) {
    $asyncUrl = Get-FdHeader $Response.Headers 'Azure-AsyncOperation'
    $locationUrl = Get-FdHeader $Response.Headers 'Location'
    $operationUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
    $isAsyncOperation = [bool]$asyncUrl
    $uri = $null
    if (-not $operationUrl -or -not [uri]::TryCreate($operationUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.Host -ine 'management.azure.com' -or -not $uri.IsDefaultPort -or
        $uri.UserInfo -or $uri.Fragment -or
        -not $uri.AbsolutePath.StartsWith("/subscriptions/$SubscriptionId/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'frontdoor_restore_operation_url_invalid: asynchronous status URL is missing or is not the expected ARM subscription; inspect the operation manually.'
    }
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $seconds = Get-FdRetrySeconds $Response
        if ([DateTime]::UtcNow.AddSeconds($seconds) -gt $deadline) { break }
        Start-Sleep -Seconds $seconds
        $Response = Invoke-FdArmHttp 'Get' $operationUrl $Headers
        $httpStatus = [int]$Response.StatusCode
        if ($httpStatus -notin 200, 202, 204) {
            throw "frontdoor_restore_operation_failed: operation status returned HTTP $httpStatus; inspect the origin manually."
        }
        $data = ConvertFrom-FdResponse $Response -AllowEmpty
        $status = [string](Get-DrValue $data 'status')
        if ($status -iin 'Failed', 'Canceled', 'Cancelled') {
            throw "frontdoor_restore_operation_failed: the asynchronous operation reported $status; inspect the origin manually."
        }
        if ($isAsyncOperation) {
            if ($httpStatus -eq 200 -and -not $status) {
                throw 'frontdoor_restore_operation_unknown: Azure-AsyncOperation returned no status; inspect the origin manually.'
            }
            if ($status -ieq 'Succeeded') { return }
        } elseif ($httpStatus -in 200, 204 -and (-not $status -or $status -ieq 'Succeeded')) {
            return
        }
    }
    throw 'frontdoor_restore_operation_timeout: asynchronous completion was not established; inspect the operation and origin manually before retrying.'
}
function Assert-FdRestoreOrigin($Origin, $Spec) {
    $actualId = [string](Get-DrValue $Origin 'id')
    $hostName = [string](Get-DrValue $Origin 'properties.hostName')
    $target = [string](Get-DrValue $Origin 'properties.sharedPrivateLinkResource.privateLink.id')
    $group = [string](Get-DrValue $Origin 'properties.sharedPrivateLinkResource.groupId')
    $priority = Get-DrValue $Origin 'properties.priority'
    if ($actualId -ine $Spec.id -or $hostName -ine $Spec.host -or $target -ine $Spec.target -or
        $group -ine $Spec.group -or "$priority" -cne '1') {
        throw "frontdoor_restore_origin_mismatch: origin ID, host, Private Link target/group or priority differs from the verified primary: $($Spec.id)."
    }
    $provisioning = [string](Get-DrValue $Origin 'properties.provisioningState')
    $deployment = [string](Get-DrValue $Origin 'properties.deploymentStatus')
    if ($provisioning -iin 'Failed', 'Canceled', 'Cancelled', 'Deleting' -or $deployment -ieq 'Failed') {
        throw "frontdoor_restore_origin_failed: $($Spec.id) reports provisioning=$provisioning deployment=$deployment; inspect manually."
    }
    if (-not $provisioning) { throw "frontdoor_restore_origin_unknown: $($Spec.id) has no provisioning state." }
}
function Assert-FdRestorePreserved($Before, $After, $Spec) {
    foreach ($field in 'hostName', 'priority', 'weight', 'httpPort', 'httpsPort', 'enforceCertificateNameCheck',
        'azureOrigin.id', 'sharedPrivateLinkResource.privateLink.id', 'sharedPrivateLinkResource.groupId',
        'sharedPrivateLinkResource.privateLinkLocation', 'sharedPrivateLinkResource.requestMessage') {
        $old = Get-DrValue $Before "properties.$field"
        $new = Get-DrValue $After "properties.$field"
        if ("$old" -ine "$new") { throw "frontdoor_restore_unexpected_change: $($Spec.id) field $field changed; inspect manually." }
    }
}

Import-Module (Join-Path $here 'DrPrerequisites.psm1') -Force
Import-Module (Join-Path $here 'DrStandby.psm1') -Force
Import-Module (Join-Path $here 'DrFrontDoorState.psm1') -Force
if ($PrimaryOnly) {
    $phaseProblem = Get-DrFrontDoorPhaseProblem -Phase $Phase -PrimaryOnly -State $null
    if ($phaseProblem) { Stop-Dr $phaseProblem }
}
$activatingStandby = $Apply -and -not $PrimaryOnly -and $Phase -cin 'Deploy', 'Approve', 'DrainPrimary', 'Lockdown'
if ($activatingStandby -and -not $ConfirmStandbyReady) {
    Stop-Dr 'frontdoor_standby_confirmation_required: region B can receive traffic when region A is unhealthy. After the standby phases, manual Entra changes and end-to-end checks pass, explicitly use -ConfirmStandbyReady.' 3
}
if (-not (Test-Path -LiteralPath $ConfigPath)) { Stop-Dr "No DR config at $ConfigPath." }
$drPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$dr = Get-Content -LiteralPath $drPath -Raw | ConvertFrom-Json
$needsStandbyOrigins = -not $PrimaryOnly -and $Phase -ne 'RestorePrimary'
$problems = @(if (-not $needsStandbyOrigins) { Get-DrFrontDoorPrimaryOnlyProblems $dr } else { @(Get-DrConfigProblems $dr) + @(Get-DrStandbyProblems $dr) })
if ($problems.Count) { Stop-Dr "Configuration refused: $($problems -join ', ')" }
if (-not $dr.PSObject.Properties['frontDoor'] -or -not $dr.frontDoor.stem -or "$($dr.frontDoor.stem)" -match '^REPLACE') {
    Stop-Dr 'Configuration refused: frontDoor.stem is required and must be a globally unique Azure Front Door endpoint prefix.'
}
$profileStem = [string]$dr.frontDoor.stem
if ($profileStem -cnotmatch '^[a-z][a-z0-9-]{2,39}$') { Stop-Dr 'frontDoor.stem must be 3-40 lowercase letters, digits and hyphens.' }
$azProfile = Resolve-DrAzureProfile -ConfigDir $env:AZURE_CONFIG_DIR -CloudShell $env:ACC_CLOUD -HomePath $HOME
if (-not $azProfile.Ok) { Stop-Dr $azProfile.Message }
$env:AZURE_CONFIG_DIR = $azProfile.ConfigDir

$primaryConfigPath = if ([IO.Path]::IsPathRooted([string]$dr.standby.stagedConfigPath)) { [string]$dr.standby.stagedConfigPath } else { Join-Path (Split-Path $drPath -Parent) $dr.standby.stagedConfigPath }
$primaryStateDir = if ([IO.Path]::IsPathRooted([string]$dr.standby.stagedStateDirectory)) { [string]$dr.standby.stagedStateDirectory } else { Join-Path (Split-Path $drPath -Parent) $dr.standby.stagedStateDirectory }
$primaryStatePath = Join-Path $primaryStateDir 'state.json'
$standbyStateDir = if ([IO.Path]::IsPathRooted([string]$dr.standby.stateDirectory)) { [string]$dr.standby.stateDirectory } else { Join-Path (Split-Path $drPath -Parent) $dr.standby.stateDirectory }
$standbyStageState = Join-Path $standbyStateDir 'state.json'
$requiredPaths = if (-not $needsStandbyOrigins) { @($primaryConfigPath, $primaryStatePath) } else { @($primaryConfigPath, $primaryStatePath, $standbyStageState) }
foreach ($p in $requiredPaths) { if (-not (Test-Path -LiteralPath $p)) { Stop-Dr "Required state/config missing: $p" } }
if ($PrimaryOnly) { New-Item -ItemType Directory -Force -Path $standbyStateDir | Out-Null }
$statePath = Join-Path $standbyStateDir 'frontdoor-state.json'
$phaseProblem = Get-DrFrontDoorPhaseProblem -Phase $Phase -PrimaryOnly:$PrimaryOnly -State (Get-FdState)
if ($phaseProblem) { Stop-Dr $phaseProblem 3 }
if ($activatingStandby) {
    $standbyEvidencePath = Join-Path $standbyStateDir 'standby.state.json'
    $standbyEvidence = if (Test-Path -LiteralPath $standbyEvidencePath) { Get-Content -LiteralPath $standbyEvidencePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { $null }
    $readinessProblem = Get-DrFrontDoorReadinessProblem $standbyEvidence
    if ($readinessProblem) { Stop-Dr $readinessProblem 3 }
    Write-Host 'Operator confirmed region B readiness. The saved phase records do not independently verify manual Entra settings or end-to-end traffic.'
}
$fdMode = Get-DrFrontDoorMode -PrimaryOnly:$PrimaryOnly
$expectedConnections = Get-DrFrontDoorExpectedConnections -PrimaryOnly:$PrimaryOnly
$primaryCfg = Get-Content -LiteralPath $primaryConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$primaryState = Get-Content -LiteralPath $primaryStatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$a = $primaryState.stages['1'].outputs
$sub = [string]$primaryCfg.subscriptionId
$rg = [string]$primaryCfg.resourceGroup
$targetProblem = Get-DrFrontDoorTargetProblem -State (Get-FdState) -Stem $profileStem -SubscriptionId $sub -ResourceGroup $rg
if ($targetProblem) { Stop-Dr $targetProblem 3 }
if ($Phase -eq 'Verify' -or ($Apply -and $Phase -cin 'Deploy', 'Approve', 'RestorePrimary')) {
    $phaseState = Get-FdState
    if ($phaseState) {
        if ($Apply -and $Phase -eq 'Approve') {
            $knownBeforeApproval = @(Get-DrValue $phaseState 'approvedConnections' | Where-Object { $_ }) +
                @(Get-DrValue $phaseState 'previousApprovedConnections' | Where-Object { $_ })
            if ($knownBeforeApproval.Count) { $phaseState.previousApprovedConnections = @($knownBeforeApproval) }
            foreach ($field in 'approvedConnections', 'approvedAt') { $phaseState.Remove($field) }
        }
        $phaseState.Remove('verifiedAt')
        if ($Apply -and $Phase -eq 'RestorePrimary') { $phaseState.Remove('primaryRestoredAt') }
        Save-FdState $phaseState
    }
}
$aApim = Get-FdApim $a $primaryCfg 'A'
$aAdmin = [string]$a.names.apps.admin.functionApp
$fdTags = @{}
if ($dr.PSObject.Properties['tags'] -and $dr.tags) { foreach ($tag in $dr.tags.PSObject.Properties) { $fdTags[$tag.Name] = [string]$tag.Value } }
$originArgs = @{
    Stem = $profileStem
    PrimaryApimId = $aApim.Id; PrimaryApimHost = $aApim.Host; PrimaryApimLocation = ([string]$dr.primary.location)
    WafMode = $(if ($dr.frontDoor.PSObject.Properties['wafMode'] -and $dr.frontDoor.wafMode) { [string]$dr.frontDoor.wafMode } else { 'Detection' })
    ProbeIntervalSeconds = $(if ($dr.frontDoor.PSObject.Properties['probeIntervalSeconds'] -and $dr.frontDoor.probeIntervalSeconds) { [int]$dr.frontDoor.probeIntervalSeconds } else { 30 })
    DisablePrimaryOrigins = $false; DisablePrimaryAdminOrigins = $false; SimulatePrimaryFailure = ($Phase -eq 'DrainPrimary'); Tags = $fdTags
}
if (-not $needsStandbyOrigins) {
    if (-not $aAdmin) { Stop-Dr 'Front Door admin origin requires an admin Function App in region A.' }
    $aAdminSite = Invoke-DrAz @('functionapp', 'show', '--subscription', $sub, '--resource-group', $rg, '--name', $aAdmin)
    $apimIds = @($aApim.Id)
    $adminSiteIds = @([string]$aAdminSite.id)
    $parameters = New-DrFrontDoorParameters @originArgs -PrimaryOnly `
        -PrimaryAdminSiteId $aAdminSite.id -PrimaryAdminHost $aAdminSite.properties.defaultHostName -PrimaryAdminLocation ([string]$dr.primary.location)
} else {
    $standbyState = Get-Content -LiteralPath $standbyStageState -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $b = $standbyState.stages['1'].outputs
    $standbyCfgPath = Join-Path $standbyStateDir 'standby.staged.config.json'
    $standbyCfg = if (Test-Path -LiteralPath $standbyCfgPath) { Get-Content -LiteralPath $standbyCfgPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { $null }
    $bApim = Get-FdApim $b $standbyCfg 'B'
    $apimIds = @(Get-DrGatewayResourceIds -PrimaryApimId $aApim.Id -StandbyApimId $bApim.Id)
    $bAdmin = [string]$b.names.apps.admin.functionApp
    if (-not $aAdmin -or -not $bAdmin) { Stop-Dr 'Front Door admin origins require an admin Function App in both regions.' }
    $aAdminSite = Invoke-DrAz @('functionapp', 'show', '--subscription', $sub, '--resource-group', $rg, '--name', $aAdmin)
    $bAdminSite = Invoke-DrAz @('functionapp', 'show', '--subscription', $sub, '--resource-group', $rg, '--name', $bAdmin)
    $adminSiteIds = @($aAdminSite.id, $bAdminSite.id)
    $parameters = New-DrFrontDoorParameters @originArgs `
        -StandbyApimId $bApim.Id -StandbyApimHost $bApim.Host -StandbyApimLocation ([string]$dr.secondary.location) `
        -PrimaryAdminSiteId $aAdminSite.id -PrimaryAdminHost $aAdminSite.properties.defaultHostName -PrimaryAdminLocation ([string]$dr.primary.location) `
        -StandbyAdminSiteId $bAdminSite.id -StandbyAdminHost $bAdminSite.properties.defaultHostName -StandbyAdminLocation ([string]$dr.secondary.location)
}

$mode = if ($Apply) { 'apply' } else { 'preview' }
Write-Host "== Front Door $Phase ($mode, $fdMode), profile $profileStem, resource group $rg"

switch ($Phase) {
        { $_ -in 'Deploy', 'DrainPrimary' } {
            # The pre-deployment snapshot and its hash are kept across the long deployment and the result is
            # saved against that hash. A concurrent change (for example a Verify recording verifiedAt against
            # the old or half-applied configuration) makes the save fail instead of being preserved.
            $state = Get-FdState
            if ($Phase -eq 'DrainPrimary') {
                if (-not $state -or -not (Get-DrValue $state 'verifiedAt')) { Stop-Dr 'frontdoor_verify_required: verify both Front Door routes before draining the primary.' 3 }
                $approvalProblem = Get-FdApprovalProblem $state $expectedConnections
                if ($approvalProblem) { Stop-Dr $approvalProblem 3 }
            }
            if ($Apply -and $state) { $state.Remove('verifiedAt'); Save-FdState $state }
            $deployStateHash = $script:fdStateHash
        $parameterFile = Join-Path $standbyStateDir 'frontdoor.parameters.json'
        $doc = [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = [ordered]@{} }
        foreach ($k in $parameters.Keys) { $doc.parameters[$k] = @{ value = $parameters[$k] } }
        $doc | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parameterFile -Encoding utf8NoBOM
        $args = @('--subscription', $sub, '--resource-group', $rg, '--name', 'ccof-frontdoor', '--template-file', (Join-Path $here 'frontdoor.bicep'), '--parameters', "@$parameterFile")
        if (-not $Apply) {
            $whatIf = Invoke-DrAz (@('deployment', 'group', 'what-if') + $args + @('--no-pretty-print'))
            $changes = @($whatIf.changes | ForEach-Object { [pscustomobject]@{ change = $_.changeType; id = $_.resourceId } })
            $changes | Group-Object change | ForEach-Object { Write-Host "$($_.Name)=$($_.Count)" }
            $changes | ForEach-Object { Write-Host ("  {0,-8} {1}" -f $_.change, $_.id) }
            Write-Host 'Preview only. No changes were made.'
            return
        }
        $deployment = Invoke-DrAz (@('deployment', 'group', 'create', '--mode', 'Incremental') + $args)
        if ($deployment.properties.provisioningState -cne 'Succeeded') { throw "frontdoor_deploy_failed: $($deployment.properties.provisioningState)" }
        $out = @{}; foreach ($k in $deployment.properties.outputs.Keys) { $out[$k] = $deployment.properties.outputs[$k].value }
        if (-not $state) { $state = @{} }
        $state.Remove('verifiedAt')
        $state = Set-DrFrontDoorStateMode -State $state -Mode $fdMode
        $state.stem = $profileStem; $state.subscriptionId = $sub; $state.resourceGroup = $rg
        $state.profileName = $out.profileName; $state.profileId = $out.profileId; $state.endpointHostName = $out.endpointHostName
        $state.apimIds = $apimIds; $state.adminSiteIds = $adminSiteIds
        $state.deployedAt = [DateTime]::UtcNow.ToString('o'); $state.outputs = $out
        if ($activatingStandby) { $state.standbyReadinessConfirmedAt = [DateTime]::UtcNow.ToString('o') }
        if ($Phase -eq 'DrainPrimary') { $state.primaryDrainedAt = [DateTime]::UtcNow.ToString('o') }
        Save-FdChangedConfigState $state $deployStateHash
        Write-Host "Front Door deployed: https://$($out.endpointHostName)"
        if ($Phase -eq 'Deploy') { Write-Host 'Private Link requests are not yet approved. Run -Phase Approve after reviewing the pending origins.' }
        elseif ($Phase -eq 'DrainPrimary') { Write-Host 'The primary APIM and admin origin host headers are faulted; AFD probes should fail and select region B.' }
    }
    'RestorePrimary' {
        $state = Get-FdState
        $restoreStateHash = $script:fdStateHash
        $profileId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Cdn/profiles/$profileStem-fd"
        $savedApims = @(Get-DrValue $state 'apimIds' | Where-Object { $_ })
        $savedSites = @(Get-DrValue $state 'adminSiteIds' | Where-Object { $_ })
        $expectedAdminId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$aAdmin"
        if (-not $savedApims.Count -or -not $savedSites.Count -or $savedApims[0] -ine $aApim.Id -or
            $savedSites[0] -ine $expectedAdminId -or [string]$aAdminSite.id -ine $expectedAdminId) {
            throw 'frontdoor_restore_target_mismatch: saved primary APIM or admin target differs from the verified primary configuration.'
        }
        $profile = Invoke-DrAz @('rest', '--method', 'get', '--url', "https://management.azure.com${profileId}?api-version=2025-04-15")
        if ([string](Get-DrValue $profile 'id') -ine $profileId -or
            [string](Get-DrValue $profile 'sku.name') -cne 'Premium_AzureFrontDoor' -or
            [string](Get-DrValue $profile 'properties.provisioningState') -cne 'Succeeded') {
            throw "frontdoor_restore_profile_mismatch: the target profile $profileId is not a readable, provisioned Front Door Premium profile."
        }
        $apim = Invoke-DrAz @('rest', '--method', 'get', '--url', "https://management.azure.com$($aApim.Id)`?api-version=2024-05-01")
        $liveGatewayUrl = [string](Get-DrValue $apim 'properties.gatewayUrl')
        $liveGateway = $null
        if ([string](Get-DrValue $apim 'id') -ine $aApim.Id -or
            -not [uri]::TryCreate($liveGatewayUrl, [UriKind]::Absolute, [ref]$liveGateway) -or
            $liveGateway.Scheme -cne 'https' -or $liveGateway.Host -ine $aApim.Host) {
            throw 'frontdoor_restore_apim_mismatch: the live primary APIM ID or HTTPS gateway host differs from staged state.'
        }
        $specs = @(
            @{ id = "$profileId/originGroups/apim/origins/primary-gateway"; target = $aApim.Id; host = $aApim.Host; group = 'Gateway' },
            @{ id = "$profileId/originGroups/admin/origins/primary-admin"; target = $expectedAdminId; host = [string]$aAdminSite.properties.defaultHostName; group = 'sites' }
        )
        Write-Host "Restore target profile: $profileId"
        foreach ($spec in $specs) {
            $spec.url = "https://management.azure.com$($spec.id)`?api-version=2025-04-15"
            $origin = Invoke-DrAz @('rest', '--method', 'get', '--url', $spec.url)
            Assert-FdRestoreOrigin $origin $spec
            $provisioning = [string](Get-DrValue $origin 'properties.provisioningState')
            $header = [string](Get-DrValue $origin 'properties.originHostHeader')
            $enabled = [string](Get-DrValue $origin 'properties.enabledState')
            if ($provisioning -cne 'Succeeded' -or $enabled -cnotin 'Enabled', 'Disabled' -or
                ($header -ine $spec.host -and $header -ine 'dr-drill.invalid')) {
                throw "frontdoor_restore_origin_unexpected: $($spec.id) has provisioning=$provisioning, host header '$header', enabledState '$enabled'; inspect before restoring."
            }
            $spec.before = $origin
            $spec.change = $header -ine $spec.host -or $enabled -cne 'Enabled'
            Write-Host "  $($spec.id) -> $($spec.target); host=$($spec.host); originHostHeader='$header' -> '$($spec.host)'; enabledState='$enabled' -> 'Enabled'"
        }
        if (-not $Apply) { Write-Host 'Preview only. No Azure changes were made; standby origins are not modified.'; return }
        $changes = @($specs | Where-Object { $_.change })
        if ($changes.Count) {
            $tokenResult = Invoke-DrAz @('account', 'get-access-token', '--subscription', $sub, '--resource', 'https://management.azure.com/')
            $token = [string](Get-DrValue $tokenResult 'accessToken')
            if (-not $token) { throw 'frontdoor_restore_token_missing: could not obtain an ARM access token; no origin was changed.' }
            $headers = @{ Authorization = "Bearer $token" }
            foreach ($spec in $changes) {
                $body = @{ properties = @{ originHostHeader = $spec.host; enabledState = 'Enabled' } } | ConvertTo-Json -Depth 5 -Compress
                $response = Invoke-FdArmHttp 'Patch' $spec.url $headers $body
                $httpStatus = [int]$response.StatusCode
                if ($httpStatus -notin 200, 202) {
                    throw "frontdoor_restore_patch_failed: $($spec.id) returned HTTP $httpStatus; inspect its current state before retrying."
                }
                $initial = ConvertFrom-FdResponse $response -AllowEmpty
                $initialId = [string](Get-DrValue $initial 'id')
                $initialState = [string](Get-DrValue $initial 'properties.provisioningState')
                if (($initialId -and $initialId -ine $spec.id) -or $initialState -iin 'Failed', 'Canceled', 'Cancelled') {
                    throw "frontdoor_restore_patch_failed: unexpected ID or failed provisioning in the PATCH response for $($spec.id)."
                }
                if ($httpStatus -eq 202) { Wait-FdRestoreOperation $response $headers $sub }
                elseif ($initialState -and $initialState -cne 'Succeeded') {
                    throw "frontdoor_restore_operation_unknown: $($spec.id) returned HTTP 200 with provisioning=$initialState; inspect manually."
                }
                $verified = $false
                for ($attempt = 1; $attempt -le 30; $attempt++) {
                    $current = Invoke-DrAz @('rest', '--method', 'get', '--url', $spec.url)
                    Assert-FdRestoreOrigin $current $spec
                    Assert-FdRestorePreserved $spec.before $current $spec
                    if ([string](Get-DrValue $current 'properties.provisioningState') -ceq 'Succeeded' -and
                        [string](Get-DrValue $current 'properties.originHostHeader') -ieq $spec.host -and
                        [string](Get-DrValue $current 'properties.enabledState') -ceq 'Enabled') {
                        $verified = $true
                        Write-Host "Primary origin read back: $($spec.id), deploymentStatus=$([string](Get-DrValue $current 'properties.deploymentStatus'))"
                        break
                    }
                    if ($attempt -lt 30) { Start-Sleep -Seconds 5 }
                }
                if (-not $verified) {
                    throw "frontdoor_restore_readback_timeout: $($spec.id) did not read back the requested fields in Succeeded state; inspect manually."
                }
            }
        }
        foreach ($spec in $specs) {
            $current = Invoke-DrAz @('rest', '--method', 'get', '--url', $spec.url)
            Assert-FdRestoreOrigin $current $spec
            Assert-FdRestorePreserved $spec.before $current $spec
            if ([string](Get-DrValue $current 'properties.provisioningState') -cne 'Succeeded' -or
                [string](Get-DrValue $current 'properties.originHostHeader') -ine $spec.host -or
                [string](Get-DrValue $current 'properties.enabledState') -cne 'Enabled') {
                throw "frontdoor_restore_final_readback_failed: $($spec.id) is no longer in the requested state; inspect both primary origins."
            }
        }
        $state.primaryRestoredAt = [DateTime]::UtcNow.ToString('o'); $state.Remove('verifiedAt')
        Save-FdChangedConfigState $state $restoreStateHash
        Write-Host 'Primary origin control-plane settings verified. Edge propagation and live traffic must still be checked; standby origins were not changed.'
    }
    'Approve' {
        $state = Get-FdState
        if (-not $state) { Stop-Dr 'frontdoor_state_missing: run -Phase Deploy -Apply first.' 3 }
        $groups = @(
            @{ ids = @(Get-DrValue $state 'apimIds' | Where-Object { $_ }); expected = @($apimIds); prefix = 'CCOF Front Door origin'; names = @('primary-gateway', 'standby-gateway') },
            @{ ids = @(Get-DrValue $state 'adminSiteIds' | Where-Object { $_ }); expected = @($adminSiteIds); prefix = 'CCOF Front Door admin origin'; names = @('primary-admin', 'standby-admin') }
        )
        $perGroup = if ($PrimaryOnly) { 1 } else { 2 }
        $targetIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($group in $groups) {
            if ($group.ids.Count -ne $perGroup -or $group.expected.Count -ne $perGroup) {
                throw 'frontdoor_origin_state_invalid: the saved state must identify each APIM and admin origin exactly once.'
            }
            for ($i = 0; $i -lt $perGroup; $i++) {
                if ([string]$group.ids[$i] -ine [string]$group.expected[$i] -or -not $targetIds.Add([string]$group.ids[$i])) {
                    throw 'frontdoor_origin_state_invalid: saved origin targets must match the current staged APIM and admin identities exactly.'
                }
            }
        }
        $known = @(Get-DrValue $state 'approvedConnections' | Where-Object { $_ }) +
            @(Get-DrValue $state 'previousApprovedConnections' | Where-Object { $_ })
        $provenance = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($id in @(Get-DrValue $state 'reviewedConnections' | Where-Object { $_ })) { $null = $provenance.Add([string]$id) }
        Write-Host "Profile for independent review: /subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Cdn/profiles/$profileStem-fd"
        $targets = [Collections.Generic.List[object]]::new()
        foreach ($group in $groups) {
            for ($i = 0; $i -lt $group.ids.Count; $i++) {
                $originId = [string]$group.ids[$i]
                $request = "$($group.prefix) $($group.names[$i])"
                $connections = @(Invoke-DrAz @('network', 'private-endpoint-connection', 'list', '--id', $originId))
                $targets.Add(@{ originId = $originId; request = $request; connections = $connections })
                Write-Host "Origin target: $originId ($request)"
                if (-not $connections.Count) { Write-Host '  No target-side connections returned.' }
                foreach ($c in $connections) {
                    $id = [string](Get-DrValue $c 'id')
                    $endpoint = [string](Get-DrValue $c 'properties.privateEndpoint.id')
                    $desc = [string](Get-DrValue $c 'properties.privateLinkServiceConnectionState.description')
                    $status = [string](Get-DrValue $c 'properties.privateLinkServiceConnectionState.status')
                    Write-Host "  Connection ID: $id"
                    Write-Host "  Private endpoint ID: $endpoint"
                    Write-Host "  Request description: $(ConvertTo-Json -InputObject $desc -Compress)"
                    Write-Host "  Status: $status"
                }
            }
        }
        Write-Host 'A request description alone does not establish Front Door profile ownership; the connection owner must independently associate IDs with this profile.'
        if (-not $Apply) { Write-Host 'Preview only. No approvals were made. Supply reviewed new connection IDs with -ReviewedConnectionIds.'; return }

        $knownSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($id in $known) {
            if (-not $knownSet.Add([string]$id)) { throw "frontdoor_saved_connection_duplicate: saved connection ID occurs more than once: $id" }
            if (@($targets | Where-Object { Test-FdConnectionId ([string]$id) $_.originId }).Count -ne 1) {
                throw "frontdoor_saved_connection_mismatch: saved connection is not under exactly one expected origin target: $id"
            }
        }
        $reviewed = [Collections.Generic.List[string]]::new()
        $reviewedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($PSBoundParameters.ContainsKey('ReviewedConnectionIds')) {
            foreach ($part in $ReviewedConnectionIds.Split(',')) {
                $id = $part.Trim()
                if (-not $id -or -not $reviewedSet.Add($id)) {
                    throw 'frontdoor_review_ids_invalid: reviewed connection IDs must be nonempty and unique.'
                }
                $reviewed.Add($id)
            }
        }
        $usedReviewed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $plan = [Collections.Generic.List[object]]::new()
        foreach ($target in $targets) {
            $saved = @($known | Where-Object { Test-FdConnectionId ([string]$_) $target.originId })
            if ($saved.Count -gt 1) {
                throw "frontdoor_saved_connection_duplicate: multiple saved IDs refer to $($target.originId)."
            }
            if ($saved.Count -and $provenance.Contains([string]$saved[0])) {
                $id = [string]$saved[0]
                $matches = @($target.connections | Where-Object { [string](Get-DrValue $_ 'id') -ieq $id })
                if ($matches.Count -ne 1 -or [string](Get-DrValue $matches[0] 'properties.privateLinkServiceConnectionState.status') -cne 'Approved') {
                    throw "frontdoor_saved_connection_not_approved: the exact saved ID $id is absent, duplicated or no longer Approved; do not substitute a description match."
                }
            } else {
                $legacy = if ($saved.Count) { [string]$saved[0] } else { '' }
                $forTarget = @($reviewed | Where-Object { Test-FdConnectionId $_ $target.originId })
                if ($forTarget.Count -ne 1) {
                    $why = if ($legacy) { " The saved ID $legacy is legacy state without reviewed provenance; independently review it and supply it." } else { '' }
                    throw "frontdoor_review_ids_required: provide exactly one independently reviewed connection ID for $($target.originId).$why"
                }
                $id = [string]$forTarget[0]
                if ($legacy -and $id -ine $legacy) {
                    throw "frontdoor_review_id_mismatch: $id differs from the legacy saved ID $legacy for $($target.originId); resolve the saved approval before retrying."
                }
                $matches = @($target.connections | Where-Object { [string](Get-DrValue $_ 'id') -ieq $id })
                # A re-reviewed legacy ID is already Approved and may carry the description its approver set.
                $requestOk = if ($matches.Count -ne 1) { $false } elseif ($legacy) {
                    [string](Get-DrValue $matches[0] 'properties.privateLinkServiceConnectionState.status') -ceq 'Approved'
                } else {
                    [string](Get-DrValue $matches[0] 'properties.privateLinkServiceConnectionState.description') -ceq $target.request
                }
                if (-not $requestOk -or
                    -not [string](Get-DrValue $matches[0] 'properties.privateEndpoint.id')) {
                    throw "frontdoor_review_id_mismatch: $id is absent, duplicated, lacks an endpoint, or does not match the expected request for $($target.originId)."
                }
                $null = $usedReviewed.Add($id)
            }
            $c = $matches[0]
            $status = [string](Get-DrValue $c 'properties.privateLinkServiceConnectionState.status')
            $desc = [string](Get-DrValue $c 'properties.privateLinkServiceConnectionState.description')
            $endpoint = [string](Get-DrValue $c 'properties.privateEndpoint.id')
            if ($status -cnotin 'Approved', 'Pending') { throw "frontdoor_connection_refused: $id status=$status" }
            $plan.Add(@{ originId = $target.originId; id = $id; status = $status; description = $desc; endpoint = $endpoint })
        }
        if ($usedReviewed.Count -ne $reviewed.Count) {
            throw 'frontdoor_review_ids_extra: do not supply unrelated IDs or IDs already saved and revalidated.'
        }
        $pending = @($plan | Where-Object { $_.status -ceq 'Pending' })
        foreach ($item in $pending) {
            foreach ($candidate in $plan) {
                $current = @(Invoke-DrAz @('network', 'private-endpoint-connection', 'list', '--id', $candidate.originId) | Where-Object {
                    [string](Get-DrValue $_ 'id') -ieq $candidate.id
                })
                if ($current.Count -ne 1 -or
                    [string](Get-DrValue $current[0] 'properties.privateLinkServiceConnectionState.status') -cne $candidate.status -or
                    [string](Get-DrValue $current[0] 'properties.privateLinkServiceConnectionState.description') -cne $candidate.description -or
                    [string](Get-DrValue $current[0] 'properties.privateEndpoint.id') -ine $candidate.endpoint) {
                    throw "frontdoor_connection_changed: $($candidate.id) changed after review; inspect all connections before retrying."
                }
            }
            $null = Invoke-DrAz @('network', 'private-endpoint-connection', 'approve', '--id', $item.id, '--description', $item.description)
            $current = @(Invoke-DrAz @('network', 'private-endpoint-connection', 'list', '--id', $item.originId) | Where-Object {
                [string](Get-DrValue $_ 'id') -ieq $item.id
            })
            if ($current.Count -ne 1 -or
                [string](Get-DrValue $current[0] 'properties.privateLinkServiceConnectionState.status') -cne 'Approved' -or
                [string](Get-DrValue $current[0] 'properties.privateLinkServiceConnectionState.description') -cne $item.description -or
                [string](Get-DrValue $current[0] 'properties.privateEndpoint.id') -ine $item.endpoint) {
                throw "frontdoor_connection_not_approved: $($item.id) did not read back Approved with its original description and endpoint."
            }
            $item.status = 'Approved'
        }
        $approved = [Collections.Generic.List[string]]::new()
        foreach ($item in $plan) {
            $readback = @(Invoke-DrAz @('network', 'private-endpoint-connection', 'list', '--id', $item.originId) | Where-Object { [string](Get-DrValue $_ 'id') -ieq $item.id })
            if ($readback.Count -ne 1 -or [string](Get-DrValue $readback[0] 'properties.privateLinkServiceConnectionState.status') -cne 'Approved' -or
                [string](Get-DrValue $readback[0] 'properties.privateLinkServiceConnectionState.description') -cne $item.description -or
                [string](Get-DrValue $readback[0] 'properties.privateEndpoint.id') -ine $item.endpoint) {
                throw "frontdoor_connection_not_approved: $($item.id) did not read back Approved; inspect the target and retry only after reviewing its state."
            }
            $approved.Add($item.id)
        }
        $state.approvedConnections = $approved.ToArray(); $state.reviewedConnections = $approved.ToArray(); $state.Remove('previousApprovedConnections')
        $state.approvedAt = [DateTime]::UtcNow.ToString('o'); Save-FdState $state
        Write-Host "Approved $($approved.Count) Front Door private links."
    }
    'Verify' {
        $state = Get-FdState
        if (-not $state) { Stop-Dr 'frontdoor_state_missing: run -Phase Deploy -Apply first.' 3 }
        $approvalProblem = Get-FdApprovalProblem $state $expectedConnections
        if ($approvalProblem) { Stop-Dr $approvalProblem 3 }
        $tests = @(
            @{ path = '/status-0123456789abcdef'; accepted = @(200); label = 'APIM gateway route' }
            @{ path = '/api/console'; accepted = @(200, 302); label = 'admin console route' }
        )
        $passed = $false
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            $failed = @()
            foreach ($test in $tests) {
                try {
                    $response = Invoke-WebRequest -Uri "https://$($state.endpointHostName)$($test.path)" -Method Get -SkipHttpErrorCheck -TimeoutSec 60
                    $code = [int]$response.StatusCode
                } catch { $code = 0 }
                Write-Host "attempt $attempt/30: GET $($test.path) -> $code"
                if ($code -notin $test.accepted) { $failed += "$($test.path)=$code" }
            }
            if (-not $failed.Count) { $passed = $true; break }
            if ($attempt -lt 30) { Start-Sleep -Seconds 30 }
        }
        if (-not $passed) { throw "frontdoor_route_unhealthy: after 15 minutes, $($failed -join ', '); inspect route/origin state and target-side private endpoint approvals." }
        $state.verifiedAt = [DateTime]::UtcNow.ToString('o'); Save-FdState $state
        Write-Host "Front Door routes verified at https://$($state.endpointHostName)"
    }
    'Lockdown' {
        $state = Get-FdState
        if (-not $state -or -not (Get-DrValue $state 'verifiedAt')) { Stop-Dr 'frontdoor_verify_required: Verify both routes before disabling APIM public access.' 3 }
        $approvalProblem = Get-FdApprovalProblem $state $expectedConnections
        if ($approvalProblem) { Stop-Dr $approvalProblem 3 }
        if (-not $Apply) { Write-Host 'Preview only: set publicNetworkAccess Disabled on both APIM origins after Front Door private routes passed.'; return }
        $origins = @()
        foreach ($id in @($state.apimIds)) { $origins += @{ id = $id; apiVersion = '2024-05-01'; type = 'Microsoft.ApiManagement/service' } }
        foreach ($id in @($state.adminSiteIds)) { $origins += @{ id = $id; apiVersion = '2024-04-01'; type = 'Microsoft.Web/sites' } }
        foreach ($origin in $origins) {
            $resource = Invoke-DrAz @('rest', '--method', 'get', '--url', "https://management.azure.com$($origin.id)`?api-version=$($origin.apiVersion)")
            if ($resource.properties.publicNetworkAccess -ceq 'Disabled') { Write-Host "$($resource.name): already private"; continue }
            $provisioningState = Get-DrValue $resource.properties 'provisioningState'
            if ($provisioningState -cne 'Updating') {
                $body = Join-Path $standbyStateDir 'frontdoor-origin-private.json'
                @{ properties = @{ publicNetworkAccess = 'Disabled' } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $body -Encoding utf8NoBOM
                $null = Invoke-DrAz @('rest', '--method', 'patch', '--url', "https://management.azure.com$($origin.id)`?api-version=$($origin.apiVersion)", '--headers', 'Content-Type=application/json', '--body', "@$body")
                Write-Host "$($resource.name): publicNetworkAccess Disabled requested"
            } else { Write-Host "$($resource.name): update already in progress; polling read-back" }
            $private = $false
            for ($attempt = 1; $attempt -le 90; $attempt++) {
                Start-Sleep -Seconds 30
                $resource = Invoke-DrAz @('rest', '--method', 'get', '--url', "https://management.azure.com$($origin.id)`?api-version=$($origin.apiVersion)")
                $provisioningState = Get-DrValue $resource.properties 'provisioningState'
                if ($resource.properties.publicNetworkAccess -ceq 'Disabled' -and ($null -eq $provisioningState -or $provisioningState -ceq 'Succeeded')) { $private = $true; break }
                if ($provisioningState -ceq 'Failed') { throw "frontdoor_lockdown_failed: $($resource.name) provisioningState Failed" }
                if ($attempt % 4 -eq 0) { Write-Host "$($resource.name): waiting for publicNetworkAccess Disabled ($provisioningState)" }
            }
            if (-not $private) { throw "frontdoor_lockdown_timeout: $($resource.name) did not read back publicNetworkAccess Disabled after 45 minutes; rerun -Phase Lockdown." }
            Write-Host "$($resource.name): publicNetworkAccess Disabled verified"
        }
        $state.lockedDownAt = [DateTime]::UtcNow.ToString('o'); Save-FdState $state
    }
}
