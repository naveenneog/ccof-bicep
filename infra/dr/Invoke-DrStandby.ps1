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
    [switch]$Apply
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
$script:StateDir = $primaryStateDir
$pS1 = Get-StgStage $primaryCfg 1; $pS2 = Get-StgStage $primaryCfg 2; $pS4 = Get-StgStage $primaryCfg 4
if ($dr.secondary.resourceGroup -ine $primaryCfg.resourceGroup) {
    Stop-Dr "standby_resource_group: region B must use the primary's resource group ($($primaryCfg.resourceGroup)): the Stage 3, 5 and 6 templates reference the shared Cosmos account and workspace in their own group. Set secondary.resourceGroup to it and secondary.allowResourceGroupInOtherRegion to true." 2
}
$sub = $primaryCfg.subscriptionId; $rg = $primaryCfg.resourceGroup
$names = Get-DrStandbyNames $pS1.names $dr.standby.nameSuffix
$vnetId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/$($dr.secondary.vnetName)"
$zone = { param($n) "/subscriptions/$($dr.dnsZones.subscriptionId)/resourceGroups/$($dr.dnsZones.resourceGroup)/providers/Microsoft.Network/privateDnsZones/$n" }
$zoneIds = @{ cosmos = (& $zone 'privatelink.documents.azure.com'); blob = (& $zone 'privatelink.blob.core.windows.net')
    foundry = @{ cognitiveServices = (& $zone 'privatelink.cognitiveservices.azure.com'); openAi = (& $zone 'privatelink.openai.azure.com'); aiServices = (& $zone 'privatelink.services.ai.azure.com') } }
$bCfg = New-DrStandbyStagedConfig -Primary $primaryCfg -Dr $dr -VnetId $vnetId -ZoneIds $zoneIds
$bCfg.__path = Join-Path $standbyStateDir 'standby.staged.config.json'
$bCfg | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $bCfg.__path -Encoding utf8NoBOM
$script:StateDir = $standbyStateDir
$mode = if ($Apply) { 'apply' } else { 'preview' }
Write-Host "== DR standby phase $Phase ($mode): $rg, region B $($dr.secondary.location) ($($names.stem)); state $standbyStateDir"

function Save-DrPhase([string]$Name, $Value) {
    $file = Join-Path $standbyStateDir 'standby.state.json'
    $s = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { @{ schema = 'ccof.dr.standby.v1'; phases = @{} } }
    $s.phases[$Name] = @{ completedAt = [DateTime]::UtcNow.ToString('o'); outputs = $Value }
    $s | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
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
        apim = @{ sku = $bCfg.stage1.apimSku; units = $(if ($dr.standby.apim.PSObject.Properties['units']) { [int]$dr.standby.apim.units } else { 1 }); publisherEmail = $dr.standby.apim.publisherEmail; publisherName = $dr.standby.apim.publisherName } }
    $out = Invoke-StgBicep -Cfg $bCfg -Template '../dr/standby.bicep' -Name 'dr-standby-shells' -Apply:$Apply -Parameters $params
    if (-not $Apply) { return }
    $s1 = New-DrStandbyStage1Outputs -Primary $pS1 -Shells $out -Identities $ids -StandbyNames $names
    # Region B's stage state: its own Stage 1, and the primary's Stage 2 (schema) and Stage 4 (Entra),
    # which both regions share.
    Save-StgStage $bCfg 1 $s1; Save-StgStage $bCfg 2 $pS2; Save-StgStage $bCfg 4 $pS4
    Save-DrPhase 'Shells' @{ apim = $s1.apimName; apimPrincipalId = $s1.apimPrincipalId; apps = @($s1.names.apps.Values | ForEach-Object { $_.functionApp }) }
}
'Grants' { $null = Get-DrPhase 'Shells'; $o = Invoke-Stage3 $bCfg -Apply:$Apply; if ($Apply) { Save-StgStage $bCfg 3 $o; Save-DrPhase 'Grants' @{ cosmosAssignments = @($o.cosmosAssignmentIds).Count } } }
'Config' {
    $null = Get-DrPhase 'Grants'
    $o = Invoke-Stage5 $bCfg -Apply:$Apply
    $s1 = Get-StgStage $bCfg 1
    $adminHost = if ($s1.names.apps.Contains('admin')) { (Get-StgSite $bCfg $s1.names.apps.admin.functionApp).defaultHostName } else { '' }
    if ($adminHost) {
        $app = Get-StgAppById $pS4.admin.appId
        $want = @("https://$adminHost/api/console", "https://$adminHost/api/console-v3")
        $merged = Join-StgUnique $app.spa.redirectUris $want
        if (@($want | Where-Object { @($app.spa.redirectUris) -notcontains $_ }).Count) {
            if ($Apply) { Send-StgGraph 'PATCH' "applications/$($app.id)" @{ spa = @{ redirectUris = $merged } } | Out-Null; Write-Host "admin app: added SPA redirects for $adminHost" }
            else { Write-Host "preview: admin app SPA redirects add $($want -join ', ')" }
        }
    }
    if ($Apply) { Save-StgStage $bCfg 5 $o; Save-DrPhase 'Config' @{ gatewayUrl = $o.gatewayUrl; adminHost = $adminHost; timers = $o.verify.timers } }
}
'Network' { $null = Get-DrPhase 'Shells'; $o = Invoke-Stage6 $bCfg -Apply:$Apply; if ($Apply) { Save-StgStage $bCfg 6 $o; Save-DrPhase 'Network' @{ privateEndpoints = @($o.verify.privateEndpoints | ForEach-Object { $_.name }); apim = $o.verify.apim } } }
'Code' {
    $null = Get-DrPhase 'Config'; $null = Get-DrPhase 'Network'
    $ctx = New-StgQsContext $bCfg; $ctx.PollSeconds = 15
    if (-not $Apply) { Write-Host 'preview: build and deploy resolver, sync, reconciler and admin packages (same commit as region A) to region B; no seed, no snapshot.'; return }
    Push-Location $repo; try { npx tsc -p tsconfig.json | Out-Host; if ($LASTEXITCODE) { throw 'build_failed' } } finally { Pop-Location }
    $code = Invoke-QsCode $ctx
    $s1 = Get-StgStage $bCfg 1
    $admin = $null
    if ($s1.names.apps.Contains('admin')) {
        $zip = Join-Path $ctx.GeneratedDir 'admin.zip'
        & (Join-Path $repo 'admin/Build-AdminPackage.ps1') -OutFile $zip | Out-Host
        if ($LASTEXITCODE) { throw 'admin_build_failed' }
        $null = Invoke-QsAz @('functionapp', 'deployment', 'source', 'config-zip', '--subscription', $sub, '--resource-group', $rg, '--name', $s1.names.apps.admin.functionApp, '--src', $zip)
        $admin = (Get-FileHash $zip -Algorithm SHA256).Hash
    }
    Save-DrPhase 'Code' @{ code = $code; adminSha256 = $admin; commit = (git -C $repo rev-parse HEAD) }
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
