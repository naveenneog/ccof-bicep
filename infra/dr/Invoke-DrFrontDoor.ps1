<#
.SYNOPSIS
  Deploy and verify Azure Front Door Premium for the active/passive CCOF gateways.

.DESCRIPTION
  -Phase Deploy    Preview without -Apply; deploy profile, WAF, APIM and admin origins and routes with -Apply.
  -Phase Approve   Approve only pending private endpoint connections whose request message identifies a CCOF origin.
  -Phase Verify    Read back Front Door origins, APIM connections, and gateway/admin routes through the FD hostname.
  -Phase Lockdown  After Verify passes, disable direct public access to both APIM origins.

  Each phase is idempotent and stores its result in standby.stateDirectory/frontdoor-state.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Deploy', 'Approve', 'Verify', 'Lockdown')] [string]$Phase,
    [Parameter(Mandatory)] [string]$ConfigPath,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path (Split-Path $here -Parent) -Parent
function Stop-Dr([string]$Message, [int]$Code = 2) { [Console]::Error.WriteLine($Message); exit $Code }
function Invoke-DrAz([string[]]$Arguments, [switch]$AllowMissing) {
    $errFile = New-TemporaryFile
    try {
        $out = & az @Arguments --output json 2>$errFile
        $code = $LASTEXITCODE
        $err = Get-Content -LiteralPath $errFile -Raw
    } finally { Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue }
    if ($code -ne 0) {
        $message = "$err $out"
        if ($AllowMissing -and $message -match 'NotFound|ResourceNotFound|could not be found|ResourceGroupNotFound') { return $null }
        throw "az $($Arguments[0..([Math]::Min(1, $Arguments.Count - 1))] -join ' ') failed: $($message.Substring(0, [Math]::Min(500, $message.Length)))"
    }
    $json = ($out -join "`n").Trim()
    if (-not $json) { return $null }
    return $json | ConvertFrom-Json -AsHashtable -Depth 100
}
function Save-FdState($Value) {
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
    Write-Host "Front Door state: $statePath"
}
function Get-FdState {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { Stop-Dr "No DR config at $ConfigPath." }
$drPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$dr = Get-Content -LiteralPath $drPath -Raw | ConvertFrom-Json
Import-Module (Join-Path $here 'DrPrerequisites.psm1') -Force
Import-Module (Join-Path $here 'DrStandby.psm1') -Force
$problems = @(Get-DrConfigProblems $dr) + @(Get-DrStandbyProblems $dr)
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
foreach ($p in $primaryConfigPath, $primaryStatePath, $standbyStageState) { if (-not (Test-Path -LiteralPath $p)) { Stop-Dr "Required state/config missing: $p" } }
$statePath = Join-Path $standbyStateDir 'frontdoor-state.json'
$primaryCfg = Get-Content -LiteralPath $primaryConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$primaryState = Get-Content -LiteralPath $primaryStatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$standbyState = Get-Content -LiteralPath $standbyStageState -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$a = $primaryState.stages['1'].outputs
$b = $standbyState.stages['1'].outputs
$sub = [string]$primaryCfg.subscriptionId
$rg = [string]$primaryCfg.resourceGroup
$apimIds = @(Get-DrGatewayResourceIds -PrimaryApimId ([string]$a.apimId) -StandbyApimId ([string]$b.apimId))
$aHost = ([uri]$a.apimGatewayUrl).Host
$bHost = ([uri]$b.apimGatewayUrl).Host
$aAdmin = [string]$a.names.apps.admin.functionApp
$bAdmin = [string]$b.names.apps.admin.functionApp
if (-not $aAdmin -or -not $bAdmin) { Stop-Dr 'Front Door admin origins require an admin Function App in both regions.' }
$aAdminSite = Invoke-DrAz @('functionapp', 'show', '--subscription', $sub, '--resource-group', $rg, '--name', $aAdmin)
$bAdminSite = Invoke-DrAz @('functionapp', 'show', '--subscription', $sub, '--resource-group', $rg, '--name', $bAdmin)
$fdTags = @{}
foreach ($tag in $dr.tags.PSObject.Properties) { $fdTags[$tag.Name] = [string]$tag.Value }

$parameters = New-DrFrontDoorParameters -Stem $profileStem `
    -PrimaryApimId $a.apimId -PrimaryApimHost $aHost -PrimaryApimLocation ([string]$dr.primary.location) `
    -StandbyApimId $b.apimId -StandbyApimHost $bHost -StandbyApimLocation ([string]$dr.secondary.location) `
    -PrimaryAdminSiteId $aAdminSite.id -PrimaryAdminHost $aAdminSite.properties.defaultHostName -PrimaryAdminLocation ([string]$dr.primary.location) `
    -StandbyAdminSiteId $bAdminSite.id -StandbyAdminHost $bAdminSite.properties.defaultHostName -StandbyAdminLocation ([string]$dr.secondary.location) `
    -WafMode $(if ($dr.frontDoor.wafMode) { [string]$dr.frontDoor.wafMode } else { 'Detection' }) `
    -ProbeIntervalSeconds $(if ($dr.frontDoor.probeIntervalSeconds) { [int]$dr.frontDoor.probeIntervalSeconds } else { 30 }) -Tags $fdTags

$mode = if ($Apply) { 'apply' } else { 'preview' }
Write-Host "== Front Door $Phase ($mode), profile $profileStem, resource group $rg"

switch ($Phase) {
    'Deploy' {
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
        $state = @{ stem = $profileStem; subscriptionId = $sub; resourceGroup = $rg; profileName = $out.profileName; profileId = $out.profileId; endpointHostName = $out.endpointHostName; apimIds = $apimIds; adminSiteIds = @($aAdminSite.id, $bAdminSite.id); deployedAt = [DateTime]::UtcNow.ToString('o'); outputs = $out }
        Save-FdState $state
        Write-Host "Front Door deployed: https://$($out.endpointHostName)"
        Write-Host 'Private Link requests are not yet approved. Run -Phase Approve after reviewing the pending origins.'
    }
    'Approve' {
        $state = Get-FdState
        if (-not $state) { Stop-Dr 'frontdoor_state_missing: run -Phase Deploy -Apply first.' 3 }
        $approved = @(); $pending = @()
        $originResourceIds = @($state.apimIds) + @($state.adminSiteIds)
        foreach ($originResourceId in $originResourceIds) {
            $connections = Invoke-DrAz @('network', 'private-endpoint-connection', 'list', '--id', $originResourceId)
            foreach ($c in @($connections)) {
                $desc = [string]$c.properties.privateLinkServiceConnectionState.description
                $status = [string]$c.properties.privateLinkServiceConnectionState.status
                if ($desc -notmatch '^CCOF Front Door (origin|admin origin) ') { continue }
                if ($status -ceq 'Approved') { $approved += [string]$c.id; continue }
                if ($status -cne 'Pending') { throw "frontdoor_connection_refused: $($c.name) status=$status description=$desc" }
                $pending += [string]$c.id
                Write-Host "Pending CCOF origin: $($c.name) -> $($c.properties.privateEndpoint.id) ($desc)"
                if ($Apply) {
                    $null = Invoke-DrAz @('network', 'private-endpoint-connection', 'approve', '--id', $c.id, '--description', 'Approved CCOF Front Door origin')
                    $approved += [string]$c.id
                }
            }
        }
        if (-not $Apply) { Write-Host "Preview only: $($pending.Count) approvals pending; run -Phase Approve -Apply after confirming names."; return }
        if ($approved.Count -lt 4) { throw "frontdoor_connections_missing: only $($approved.Count) of 4 APIM/admin Private Link connections are approved." }
        $state.approvedConnections = $approved; $state.approvedAt = [DateTime]::UtcNow.ToString('o'); Save-FdState $state
        Write-Host "Approved $($approved.Count) Front Door private links."
    }
    'Verify' {
        $state = Get-FdState
        if (-not $state) { Stop-Dr 'frontdoor_state_missing: run -Phase Deploy -Apply first.' 3 }
        if (@($state.approvedConnections).Count -lt 4) { Stop-Dr 'frontdoor_approval_missing: run -Phase Approve -Apply first.' 3 }
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
        if (-not $state -or -not $state.verifiedAt) { Stop-Dr 'frontdoor_verify_required: Verify both routes before disabling APIM public access.' 3 }
        if (-not $Apply) { Write-Host 'Preview only: set publicNetworkAccess Disabled on both APIM origins after Front Door private routes passed.'; return }
        $origins = @()
        foreach ($id in @($state.apimIds)) { $origins += @{ id = $id; apiVersion = '2024-05-01'; type = 'Microsoft.ApiManagement/service' } }
        foreach ($id in @($state.adminSiteIds)) { $origins += @{ id = $id; apiVersion = '2024-04-01'; type = 'Microsoft.Web/sites' } }
        foreach ($origin in $origins) {
            $resource = Invoke-DrAz @('rest', '--method', 'get', '--url', "https://management.azure.com$($origin.id)`?api-version=$($origin.apiVersion)")
            if ($resource.properties.publicNetworkAccess -ceq 'Disabled') { Write-Host "$($resource.name): already private"; continue }
            if ($resource.properties.provisioningState -cne 'Updating') {
                $body = Join-Path $standbyStateDir 'frontdoor-origin-private.json'
                @{ properties = @{ publicNetworkAccess = 'Disabled' } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $body -Encoding utf8NoBOM
                $null = Invoke-DrAz @('rest', '--method', 'patch', '--url', "https://management.azure.com$($origin.id)`?api-version=$($origin.apiVersion)", '--headers', 'Content-Type=application/json', '--body', "@$body")
                Write-Host "$($resource.name): publicNetworkAccess Disabled requested"
            } else { Write-Host "$($resource.name): update already in progress; polling read-back" }
            $private = $false
            for ($attempt = 1; $attempt -le 90; $attempt++) {
                Start-Sleep -Seconds 30
                $resource = Invoke-DrAz @('rest', '--method', 'get', '--url', "https://management.azure.com$($origin.id)`?api-version=$($origin.apiVersion)")
                if ($resource.properties.publicNetworkAccess -ceq 'Disabled' -and $resource.properties.provisioningState -ceq 'Succeeded') { $private = $true; break }
                if ($resource.properties.provisioningState -ceq 'Failed') { throw "frontdoor_lockdown_failed: $($resource.name) provisioningState Failed" }
                if ($attempt % 4 -eq 0) { Write-Host "$($resource.name): waiting for publicNetworkAccess Disabled ($($resource.properties.provisioningState))" }
            }
            if (-not $private) { throw "frontdoor_lockdown_timeout: $($resource.name) did not read back publicNetworkAccess Disabled after 45 minutes; rerun -Phase Lockdown." }
            Write-Host "$($resource.name): publicNetworkAccess Disabled verified"
        }
        $state.lockedDownAt = [DateTime]::UtcNow.ToString('o'); Save-FdState $state
    }
}
