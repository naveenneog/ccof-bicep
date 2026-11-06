<#
.SYNOPSIS
  DR standby region (region B) for an existing staged CCOF deployment (ADR 0033, docs/DR-ACTIVE-PASSIVE.md).

.DESCRIPTION
  Runs after the DR prerequisites (infra/dr/Invoke-DrPrerequisites.ps1, P0-P2) on the same dr.config.json,
  which adds a `standby` and a `cosmos` section. One phase per run; each phase previews without -Apply,
  changes Azure with -Apply, reads back what it changed and records it in standby.stateDirectory. Every
  phase can be run again: it skips what is already in place, so a phase cut off (for example by a Cloud
  Shell timeout) is resumed by running the same command again.

  -Phase Data      Cosmos DB: change a serverless account to provisioned throughput (one-way, only with
                   cosmos.convertServerless true), set each container to autoscale (cosmos.autoscaleMaxThroughput),
                   add the standby region, turn on service-managed failover.
  -Phase Shells    infra/dr/standby.bicep: region B Function Apps (resolver, sync, reconciler, admin) and API
                   Management, logging to the primary workspace, sync/reconciler on the P1 identities.
  -Phase Grants    The primary's Stage 3 template for region B (salted names on shared resources).
  -Phase Config    The primary's Stage 5 for region B: settings with both writers off, resolver
                   authentication, APIM API and policy rendered for resolver B; the admin app's redirect
                   URIs for admin B.
  -Phase Network   The primary's Stage 6 for region B: private endpoints in the standby subnet, Function App
                   and APIM outbound VNet integration.
  -Phase Code      The same packages as region A, deployed to region B's apps. No seed and no snapshot:
                   region B reads the shared Cosmos account.
  -Phase Verify    Read-only: apps list their functions, both writers are off, APIM B has the API.

  The primary's staged state (standby.stagedStateDirectory) is read, never written.

.EXAMPLE
  pwsh -NoProfile -File infra/dr/Invoke-DrStandby.ps1 -Phase Data -ConfigPath dr.config.json
  pwsh -NoProfile -File infra/dr/Invoke-DrStandby.ps1 -Phase Data -ConfigPath dr.config.json -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Data', 'Shells', 'Grants', 'Config', 'Network', 'Code', 'Verify')] [string]$Phase,
    [Parameter(Mandatory)] [string]$ConfigPath,
    [switch]$Apply,
    [switch]$ApprovePrivateNetworkChanges,
    [switch]$ApprovePublicApimBootstrap,
    [switch]$ApprovePublicFunctionAccess,
    [switch]$PrivatePublisher
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path (Split-Path $here -Parent) -Parent
function Stop-Dr([string]$Message, [int]$Code) { [Console]::Error.WriteLine($Message); exit $Code }
if (-not (Test-Path -LiteralPath $ConfigPath)) { Stop-Dr "No configuration file at ${ConfigPath}: copy infra/dr/dr.config.example.json and replace every REPLACE- value (docs/runbooks/DR-STANDBY.md)." 2 }
$drPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$dr = Get-Content -LiteralPath $drPath -Raw | ConvertFrom-Json
Import-Module (Join-Path $here 'DrPrerequisites.psm1') -Force
Import-Module (Join-Path $here 'DrStandby.psm1') -Force
$problems = @(Get-DrConfigProblems $dr) + @(Get-DrStandbyProblems $dr)
if ($problems.Count) { Stop-Dr "Configuration refused: $($problems -join ', ')" 2 }
if ($Phase -ceq 'Network' -and $Apply -and -not $ApprovePrivateNetworkChanges) {
    Stop-Dr 'network_changes_approval_required: Network creates private endpoints and DNS records and attaches services to subnets. Obtain network-team approval and rerun with -ApprovePrivateNetworkChanges.' 2
}
if ($Phase -ceq 'Shells') {
    Write-Host 'Shells creates a new APIM with public network access Enabled. Function App access is configured separately.'
    if ($Apply -and -not $ApprovePublicApimBootstrap) {
        Stop-Dr 'public_apim_bootstrap_approval_required: the standby APIM is initially public. Obtain security approval and rerun with -ApprovePublicApimBootstrap, or stop.' 2
    }
    if ($Apply -and $dr.standby.functionsPublicNetworkAccess -ceq 'Enabled' -and -not $ApprovePublicFunctionAccess) {
        Stop-Dr 'public_function_access_approval_required: Shells would enable public access for the standby Function Apps. Obtain security approval and rerun with -ApprovePublicFunctionAccess, or set Disabled.' 2
    }
}
$azProfile = Resolve-DrAzureProfile -ConfigDir $env:AZURE_CONFIG_DIR -CloudShell $env:ACC_CLOUD -HomePath $HOME
if (-not $azProfile.Ok) { Stop-Dr $azProfile.Message 2 }
$env:AZURE_CONFIG_DIR = $azProfile.ConfigDir

function Resolve-DrPath([string]$Path) { if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Split-Path $drPath -Parent) $Path } }
$primaryConfigPath = Resolve-DrPath $dr.standby.stagedConfigPath
$primaryStateDir = Resolve-DrPath $dr.standby.stagedStateDirectory
$standbyStateDir = Resolve-DrPath $dr.standby.stateDirectory
foreach ($p in $primaryConfigPath, (Join-Path $primaryStateDir 'state.json')) { if (-not (Test-Path -LiteralPath $p)) { Stop-Dr "Not found: $p (standby.stagedConfigPath / standby.stagedStateDirectory: the primary's staged configuration and state)." 2 } }
New-Item -ItemType Directory -Force -Path $standbyStateDir | Out-Null

# The staged functions (Stages 3, 5, 6 and the quickstart helpers), library only.
$drApply = [bool]$Apply; $drPhase = $Phase  # the staged driver's param block resets $Apply/$ConfigPath when dot-sourced
. (Join-Path $repo 'infra/staged/Invoke-StagedDeployment.ps1') -DotSourceOnly
$Apply = [switch]$drApply; $Phase = $drPhase
$ErrorActionPreference = 'Stop'
$primaryCfg = Read-StgConfig $primaryConfigPath
if ($dr.subscriptionId -ine $primaryCfg.subscriptionId -or $dr.tenantId -ine $primaryCfg.tenantId) {
    Stop-Dr 'primary_account_mismatch: dr.config.json and the primary staged configuration must name the same tenant and subscription.' 2
}
if ($dr.secondary.resourceGroup -ine $primaryCfg.resourceGroup) {
    Stop-Dr "standby_resource_group: region B must use the primary's resource group ($($primaryCfg.resourceGroup)): the Stage 3, 5 and 6 templates reference the shared Cosmos account and workspace in their own group. Set secondary.resourceGroup to it and secondary.allowResourceGroupInOtherRegion to true." 2
}
$sub = $primaryCfg.subscriptionId; $rg = $primaryCfg.resourceGroup
function Write-DrStandbyJson([string]$Path, $Value) {
    $tmp = Join-Path (Split-Path $Path -Parent) (".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp")
    try {
        $json = $Value | ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tmp, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}
if ($Apply -or $Phase -ceq 'Verify') {
    $fdPath = Join-Path $standbyStateDir 'frontdoor-state.json'
    if (Test-Path -LiteralPath $fdPath) {
        Import-Module (Join-Path $here 'DrFrontDoorState.psm1') -Force
        $fdRead = try { Read-DrFrontDoorState -StatePath $fdPath } catch { Stop-Dr $_.Exception.Message 3 }
        $fdState = $fdRead.State
        if ($fdState -isnot [Collections.IDictionary]) { Stop-Dr 'frontdoor_state_invalid: inspect and restore the Front Door state before continuing.' 3 }
        if ($fdState.Contains('verifiedAt')) {
            $stem = [string](Get-DrValue $dr 'frontDoor.stem')
            if (-not $stem) { Stop-Dr 'frontdoor_target_unknown: set the verified Front Door stem before changing standby readiness.' 3 }
            $targetProblem = Get-DrFrontDoorTargetProblem -State $fdState -Stem $stem -SubscriptionId $sub -ResourceGroup $rg
            if ($targetProblem) { Stop-Dr $targetProblem 3 }
            $fdState.Remove('verifiedAt')
            $null = Save-DrFrontDoorState -StatePath $fdPath -Value $fdState -ExpectedHash $fdRead.Hash
            Write-Host 'Prior Front Door verification was cleared; verify the routes again after standby work.'
        }
    }
    $phasePath = Join-Path $standbyStateDir 'standby.state.json'
    if (Test-Path -LiteralPath $phasePath) {
        $phaseState = Get-Content -LiteralPath $phasePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        if ($phaseState -isnot [Collections.IDictionary]) { Stop-Dr 'standby_phase_state_invalid: inspect and restore the standby state before continuing.' 3 }
        $removed = @(Clear-DrStandbyPhaseEvidence -State $phaseState -Phase $Phase)
        if ($removed.Count) {
            Write-DrStandbyJson $phasePath $phaseState
            Write-Host "Prior standby evidence cleared: $($removed -join ', ')."
        }
    }
}
$script:StateDir = $primaryStateDir
$pS1 = Get-StgStage $primaryCfg 1; $pS2 = Get-StgStage $primaryCfg 2; $pS4 = Get-StgStage $primaryCfg 4
$names = Get-DrStandbyNames $pS1.names $dr.standby.nameSuffix
$vnetId = Get-DrSecondaryVnetId $dr
$zone = { param($n) "/subscriptions/$($dr.dnsZones.subscriptionId)/resourceGroups/$($dr.dnsZones.resourceGroup)/providers/Microsoft.Network/privateDnsZones/$n" }
$zoneIds = @{ cosmos = (& $zone 'privatelink.documents.azure.com'); blob = (& $zone 'privatelink.blob.core.windows.net')
    foundry = @{ cognitiveServices = (& $zone 'privatelink.cognitiveservices.azure.com'); openAi = (& $zone 'privatelink.openai.azure.com'); aiServices = (& $zone 'privatelink.services.ai.azure.com') } }
$standbyStageState = Join-Path $standbyStateDir 'state.json'
$standbyApimId = ''
if (Test-Path -LiteralPath $standbyStageState) {
    $bState = Get-Content -LiteralPath $standbyStageState -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    if ($bState.stages['1']) { $standbyApimId = [string]$bState.stages['1'].outputs.apimId }
}
$gatewayIds = @(if ($standbyApimId) { Get-DrGatewayResourceIds -PrimaryApimId $pS1.apimId -StandbyApimId $standbyApimId })
$bCfg = New-DrStandbyStagedConfig -Primary $primaryCfg -Dr $dr -VnetId $vnetId -ZoneIds $zoneIds -GatewayResourceIds $gatewayIds
$bCfg.__path = Join-Path $standbyStateDir 'standby.staged.config.json'
$bCfg | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $bCfg.__path -Encoding utf8NoBOM
$script:StateDir = $standbyStateDir
$mode = if ($Apply) { 'apply' } else { 'preview' }
Write-Host "== DR standby phase $Phase ($mode): $rg, region B $($dr.secondary.location) ($($names.stem)); state $standbyStateDir"

function Save-DrPhase([string]$Name, $Value) {
    $file = Join-Path $standbyStateDir 'standby.state.json'
    $s = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { @{ schema = 'ccof.dr.standby.v1'; phases = @{} } }
    $s.phases[$Name] = @{ completedAt = [DateTime]::UtcNow.ToString('o'); outputs = $Value }
    Write-DrStandbyJson $file $s
    Write-Host "phase $Name completed and verified; state $file" -ForegroundColor Green
}
function Get-DrPhase([string]$Name) {
    $file = Join-Path $standbyStateDir 'standby.state.json'
    $s = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { $null }
    if (-not $s -or -not $s.phases[$Name]) { Stop-Dr "phase_order: run -Phase $Name -Apply first." 3 }
    return $s.phases[$Name].outputs
}

switch ($Phase) {
'Data' {
    $acctId = $pS1.cosmosAccountId
    $url = "https://management.azure.com$acctId`?api-version=2024-05-15-preview"
    $acct = Invoke-QsAz @('rest', '--method', 'get', '--url', $url)
    $steps = @(Get-DrCosmosSteps $acct $dr.secondary.location)
    Write-Host "Cosmos $($acct.name): capacity $($acct.properties.capacityMode); regions $(@($acct.properties.locations.locationName) -join ', '); steps: $(if ($steps.Count) { $steps -join ', ' } else { 'none' })"
    $max = if ($dr.cosmos.PSObject.Properties['autoscaleMaxThroughput']) { [int]$dr.cosmos.autoscaleMaxThroughput } else { 1000 }
    if (-not $Apply) { Write-Host "preview: then each container autoscale with maximum $max RU/s. Rerun with -Apply."; return }
    if ($steps -contains 'convert_to_provisioned') {
        if ($dr.cosmos.convertServerless -ne $true) { Stop-Dr 'cosmos_serverless: the account is serverless, which runs in one region only. The change to provisioned throughput cannot be undone; set cosmos.convertServerless to true to allow it.' 4 }
        Write-Host 'Changing the account to provisioned throughput (one-way; no management change is possible until it finishes).'
        $body = Join-Path $standbyStateDir 'cosmos-capacity.json'; '{"properties":{"capacityMode":"Provisioned"}}' | Set-Content -LiteralPath $body
        $null = Invoke-QsAz @('rest', '--method', 'patch', '--url', $url, '--headers', 'Content-Type=application/json', '--body', "@$body")
        $steps = @('wait_capacity_change')
    }
    for ($i = 0; $steps -contains 'wait_capacity_change' -and $i -lt 240; $i++) {
        Start-Sleep 30; $acct = Invoke-QsAz @('rest', '--method', 'get', '--url', $url); $steps = @(Get-DrCosmosSteps $acct $dr.secondary.location)
        if ($i % 4 -eq 0) { Write-Host "  waiting: $($acct.properties.capacityModeChangeTransitionState.capacityModeTransitionStatus)" }
    }
    if ($steps -contains 'wait_capacity_change') { Stop-Dr 'cosmos_capacity_change_running: still in progress after 2 hours; run this phase again later.' 5 }
    # Autoscale before the second region: its throughput is billed in every region.
    $db = $primaryCfg.cosmos.databaseName
    $containers = @(Invoke-StgAzJson @('cosmosdb', 'sql', 'container', 'list', '--subscription', $sub, '--resource-group', $rg, '--account-name', $acct.name, '--database-name', $db) | ForEach-Object { $_.name })
    foreach ($c in $containers) {
        $t = Invoke-StgAzJson @('cosmosdb', 'sql', 'container', 'throughput', 'show', '--subscription', $sub, '--resource-group', $rg, '--account-name', $acct.name, '--database-name', $db, '--name', $c)
        $autoMax = Get-DrValue $t 'resource.autoscaleSettings.maxThroughput'; $auto = [bool]$autoMax
        if ($auto -and [int]$autoMax -eq $max) { continue }
        if (-not $auto) { $null = Invoke-StgAzJson @('cosmosdb', 'sql', 'container', 'throughput', 'migrate', '--subscription', $sub, '--resource-group', $rg, '--account-name', $acct.name, '--database-name', $db, '--name', $c, '--throughput-type', 'autoscale') }
        $null = Invoke-StgAzJson @('cosmosdb', 'sql', 'container', 'throughput', 'update', '--subscription', $sub, '--resource-group', $rg, '--account-name', $acct.name, '--database-name', $db, '--name', $c, '--max-throughput', "$max")
        Write-Host "  $c autoscale maximum $max RU/s"
    }
    if ($steps -contains 'add_secondary_region') {
        $locs = @($acct.properties.locations | Sort-Object failoverPriority | ForEach-Object { @{ locationName = $_.locationName; failoverPriority = [int]$_.failoverPriority; isZoneRedundant = [bool]$_.isZoneRedundant } })
        $locs += @{ locationName = $dr.secondary.location; failoverPriority = $locs.Count; isZoneRedundant = $false }
        $body = Join-Path $standbyStateDir 'cosmos-locations.json'; @{ properties = @{ locations = $locs } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $body
        Write-Host "Adding $($dr.secondary.location) as a read region (data is copied; typically tens of minutes)."
        $null = Invoke-QsAz @('rest', '--method', 'patch', '--url', $url, '--headers', 'Content-Type=application/json', '--body', "@$body")
        for ($i = 0; $i -lt 240; $i++) { Start-Sleep 30; $acct = Invoke-QsAz @('rest', '--method', 'get', '--url', $url); if ($acct.properties.provisioningState -ceq 'Succeeded') { break }; if ($i % 4 -eq 0) { Write-Host "  waiting: $($acct.properties.provisioningState)" } }
    }
    if (@(Get-DrCosmosSteps $acct $dr.secondary.location) -contains 'enable_service_managed_failover') {
        $null = Invoke-StgAzJson @('cosmosdb', 'update', '--subscription', $sub, '--resource-group', $rg, '--name', $acct.name, '--enable-automatic-failover', 'true')
    }
    $acct = Invoke-QsAz @('rest', '--method', 'get', '--url', $url)
    $left = @(Get-DrCosmosSteps $acct $dr.secondary.location)
    Assert-Stg ($left.Count -eq 0 -and $acct.properties.provisioningState -ceq 'Succeeded') "Cosmos still needs: $($left -join ', ') (state $($acct.properties.provisioningState))"
    $regions = @($acct.properties.locations | Sort-Object failoverPriority | ForEach-Object { "$($_.locationName)=$($_.failoverPriority)" })
    Save-DrPhase 'Data' @{ account = $acct.name; capacityMode = $acct.properties.capacityMode; regions = $regions; writeRegion = @($acct.properties.writeLocations)[0].locationName; serviceManagedFailover = [bool]$acct.properties.enableAutomaticFailover; autoscaleMaxThroughput = $max; containers = $containers }
}
'Shells' {
    if ($Apply) {
        $apimName = "$($names.stem)-apim"
        $apimId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apimName"
        $matches = @(Invoke-StgAzJson @('apim', 'list', '--subscription', $sub, '--resource-group', $rg) | Where-Object { $_.name -ieq $apimName })
        if ($matches.Count -gt 1) { Stop-Dr "apim_inventory_ambiguous: multiple API Management services matched $apimName; inspect the resource group before applying Shells." 3 }
        if ($matches.Count -eq 1) {
            if ([string](Get-DrValue $matches[0] 'id') -ine $apimId) { Stop-Dr "apim_inventory_mismatch: the listed ID for $apimName differs from $apimId; stop and inspect the target." 3 }
            $current = Get-StgArm $apimId '2024-05-01'
            $access = [string](Get-DrValue $current 'properties.publicNetworkAccess')
            if ([string](Get-DrValue $current 'id') -ine $apimId -or $access -ine 'Enabled') {
                Stop-Dr "apim_public_access_guard: $apimName is already present with publicNetworkAccess '$access' or an unexpected ID. Shells would enable public access; do not rerun it. Inspect the APIM and use later phases without reopening it." 3
            }
        }
        if ($dr.standby.functionsPublicNetworkAccess -ceq 'Enabled') {
            $sites = @(Invoke-StgAzJson @('resource', 'list', '--subscription', $sub, '--resource-group', $rg, '--resource-type', 'Microsoft.Web/sites'))
            $keys = @('resolver', 'sync', 'reconciler')
            if ($primaryCfg.stage1.includeAdmin) { $keys += 'admin' }
            foreach ($key in $keys) {
                $siteName = "$($names.stem)-$key"
                $siteId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$siteName"
                $found = @($sites | Where-Object { $_.name -ieq $siteName })
                if ($found.Count -gt 1) { Stop-Dr "function_inventory_ambiguous: multiple sites matched $siteName; inspect the resource group before applying Shells." 3 }
                if ($found.Count -eq 1) {
                    if ([string](Get-DrValue $found[0] 'id') -ine $siteId) { Stop-Dr "function_public_access_guard: the listed ID for $siteName differs from $siteId; inspect the site." 3 }
                    $current = Get-StgArm $siteId '2024-04-01'
                    $access = [string](Get-DrValue $current 'properties.publicNetworkAccess')
                    if ([string](Get-DrValue $current 'id') -ine $siteId -or $access -ine 'Enabled') {
                        Stop-Dr "function_public_access_guard: $siteName already exists with publicNetworkAccess '$access' or an unexpected ID. Shells would enable public access; do not reopen it." 3
                    }
                }
            }
        }
    }
    $ids = @{}
    foreach ($k in 'sync', 'reconciler') {
        $n = @($dr.identityNames | Where-Object { $_ -match "-$k-[a-z0-9]+$|$k" } | Where-Object { $_ -match $k })[0]
        if (-not $n) { Stop-Dr "identity_missing: no name for the $k identity in identityNames" 2 }
        $mi = Invoke-StgAzJson @('identity', 'show', '--subscription', $sub, '--resource-group', $rg, '--name', $n)
        $ids[$k] = @{ id = $mi.id; principalId = $mi.principalId; clientId = $mi.clientId; name = $mi.name }
    }
    $params = @{ location = $dr.secondary.location; tags = $primaryCfg.tags; stem = $names.stem; storageStem = $names.storageStem; workspaceId = $pS1.workspaceId
        identities = $ids; includeAdmin = [bool]$primaryCfg.stage1.includeAdmin; functionsPublicNetworkAccess = [string]$dr.standby.functionsPublicNetworkAccess
        storagePublicNetworkAccess = [string]$dr.standby.storagePublicNetworkAccess
        apim = @{ sku = $bCfg.stage1.apimSku; zoneRedundant = [bool]$bCfg.stage1.apimZoneRedundant; units = $(if ($dr.standby.apim.PSObject.Properties['units']) { [int]$dr.standby.apim.units } else { 1 }); publisherEmail = $dr.standby.apim.publisherEmail; publisherName = $dr.standby.apim.publisherName } }
    $out = Invoke-StgBicep -Cfg $bCfg -Template '../dr/standby.bicep' -Name 'dr-standby-shells' -Apply:$Apply -Parameters $params
    if (-not $Apply) { return }
    $null = Assert-StgApimZoneRedundancy -Cfg $bCfg -ApimId $out.apimId
    $s1 = New-DrStandbyStage1Outputs -Primary $pS1 -Shells $out -Identities $ids -StandbyNames $names
    # Region B's stage state: its own Stage 1, and the primary's Stage 2 (schema) and Stage 4 (Entra),
    # which both regions share.
    Save-StgStage $bCfg 1 $s1; Save-StgStage $bCfg 2 $pS2; Save-StgStage $bCfg 4 $pS4
    Save-DrPhase 'Shells' @{ apimId = $s1.apimId; apim = $s1.apimName; apimPrincipalId = $s1.apimPrincipalId; apps = @($s1.names.apps.Values | ForEach-Object { $_.functionApp }) }
}
'Grants' { $null = Get-DrPhase 'Shells'; $o = Invoke-Stage3 $bCfg -Apply:$Apply; if ($Apply) { Save-StgStage $bCfg 3 $o; Save-DrPhase 'Grants' @{ cosmosAssignments = @($o.cosmosAssignmentIds).Count } } }
'Config' {
    $null = Get-DrPhase 'Grants'
    $o = Invoke-Stage5 $bCfg -Apply:$Apply
    $s1 = Get-StgStage $bCfg 1
    $adminHost = if ($s1.names.apps.Contains('admin')) { (Get-StgSite $bCfg $s1.names.apps.admin.functionApp).defaultHostName } else { '' }
    if ($s1.names.apps.Contains('admin') -and [string]::IsNullOrWhiteSpace([string]$adminHost)) {
        Stop-Dr 'admin_hostname_missing: the standby admin app has no default hostname; read its App Service properties before continuing with the Entra redirect handoff.' 3
    }
    if ($adminHost) {
        $null = Invoke-DrAdminRedirects -Stage4 $pS4 -AdminHost $adminHost -Apply:$Apply -GetApp { Get-StgAppById $pS4.admin.appId } `
            -PatchApp { param($app, $merged) Send-StgGraph 'PATCH' "applications/$($app.id)" @{ spa = @{ redirectUris = $merged } } | Out-Null }
    }
    if ($Apply) { Save-StgStage $bCfg 5 $o; Save-DrPhase 'Config' @{ gatewayUrl = $o.gatewayUrl; adminHost = $adminHost; timers = $o.verify.timers } }
}
'Network' { $null = Get-DrPhase 'Shells'; $o = Invoke-Stage6 $bCfg -Apply:$Apply; if ($Apply) { Save-StgStage $bCfg 6 $o; Save-DrPhase 'Network' @{ privateEndpoints = @($o.verify.privateEndpoints | ForEach-Object { $_.name }); apim = $o.verify.apim } } }
'Code' {
    $null = Get-DrPhase 'Config'; $null = Get-DrPhase 'Network'
    $ctx = New-StgQsContext $bCfg; $ctx.PollSeconds = 15
    if (-not $Apply) { Write-Host 'preview: build and deploy resolver, sync, reconciler and admin packages (same commit as region A) to region B; no seed, no snapshot. Disabled public access requires -PrivatePublisher and a working private SCM path.'; return }
    $s1 = Get-StgStage $bCfg 1
    $sites = @()
    foreach ($key in @($s1.names.apps.Keys | Sort-Object)) {
        $name = $s1.names.apps[$key].functionApp
        $site = Get-StgSite $bCfg $name
        if ([string]$site.publicNetworkAccess -cnotin 'Enabled', 'Disabled') {
            Stop-Dr "function_access_unknown: could not determine public network access for $name; read the app before publishing." 3
        }
        if ($site.publicNetworkAccess -ceq 'Disabled' -and -not $PrivatePublisher) {
            Stop-Dr "private_publisher_required: $name has public network access Disabled. Use an approved private runner with -PrivatePublisher; do not enable public access as a workaround." 3
        }
        $sites += @{ name = $name; host = [string]$site.defaultHostName; id = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$name" }
    }
    if ($PrivatePublisher) {
        $subnetId = "$vnetId/subnets/$($dr.secondary.subnets.privateEndpoints.name)"
        $listConnections = {
            param($siteId)
            $result = Get-StgArm "$siteId/privateEndpointConnections" '2024-04-01'
            if ($result -isnot [Collections.IDictionary] -or -not $result.Contains('value')) { throw "private_endpoint_list_invalid: $siteId" }
            if ($result['nextLink']) { throw "private_endpoint_list_paginated: inspect all pages for $siteId before publishing." }
            return $result['value']
        }
        $readNetworkResource = { param($id) Get-StgArm $id '2024-05-01' }
        foreach ($site in $sites) {
            $site.endpointAddresses = @(Get-DrPrivateAppEndpointAddresses -SiteId $site.id -SubnetId $subnetId -ListConnections $listConnections -ReadResource $readNetworkResource)
        }
        $privateProblems = @(Get-DrPrivatePublisherProblems -Apps $sites -EndpointSubnetPrefix $dr.secondary.subnets.privateEndpoints.prefix)
        if ($privateProblems.Count) { Stop-Dr "private_publisher_check_failed: $($privateProblems -join ', ')" 3 }
        Write-Host 'Private publisher: each SCM hostname resolved to its approved Function App private endpoint and accepted TCP 443.'
    }
    Push-Location $repo; try { npx tsc -p tsconfig.json | Out-Host; if ($LASTEXITCODE) { throw 'build_failed' } } finally { Pop-Location }
    $code = Invoke-QsCode $ctx
    $admin = $null
    if ($s1.names.apps.Contains('admin')) {
        $admin = Publish-StgAdminPackage -Subscription $sub -ResourceGroup $rg -App $s1.names.apps.admin.functionApp -ZipPath (Join-Path $ctx.GeneratedDir 'admin.zip') -PrivatePublisher:$PrivatePublisher
        if ($admin.Contains('skipped')) { throw 'admin_publish_incomplete: admin package was not published; Code was not marked complete.' }
    }
    Save-DrPhase 'Code' @{ code = $code; admin = $admin; adminSha256 = $(if ($admin -and $admin.Contains('sha256')) { $admin.sha256 } else { $null }); commit = (git -C $repo rev-parse HEAD) }
}
'Verify' {
    $s1 = Get-StgStage $bCfg 1
    $v = [ordered]@{ apps = [ordered]@{}; writersOff = [ordered]@{} }
    foreach ($k in @($s1.names.apps.Keys | Sort-Object)) {
        $fn = $s1.names.apps[$k].functionApp
        $listed = @((Get-StgArm "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$fn/functions" '2024-04-01').value | ForEach-Object { ([string]$_.name).Split('/')[-1] })
        $v.apps[$k] = $listed
        Assert-Stg ($listed.Count -ge 1) "$fn lists no functions"
    }
    $settings = { param($app) $h = @{}; foreach ($s in @(Invoke-StgAzJson @('functionapp', 'config', 'appsettings', 'list', '--subscription', $sub, '--resource-group', $rg, '--name', $app))) { $h[$s.name] = $s.value }; $h }
    $syncS = & $settings $s1.names.apps.sync.functionApp; $recS = & $settings $s1.names.apps.reconciler.functionApp
    $v.writersOff.sync = $syncS['AzureWebJobs.syncEntitlement.Disabled']; $v.writersOff.reconciler = $recS['AzureWebJobs.reconcileBudgets.Disabled']
    Assert-Stg ("$($v.writersOff.sync)" -ieq 'true' -and "$($v.writersOff.reconciler)" -ieq 'true') "region B writers are not both off: sync $($v.writersOff.sync), reconciler $($v.writersOff.reconciler)"
    $api = Get-StgArm "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$($s1.apimName)/apis/$($primaryCfg.apim.apiId)" '2024-05-01'
    $v.apimApiPath = $api.properties.path
    $null = Write-StgEvidence 'standby.verify.json' $v
    $v | ConvertTo-Json -Depth 5 | Write-Host
    Save-DrPhase 'Verify' $v
}
}
