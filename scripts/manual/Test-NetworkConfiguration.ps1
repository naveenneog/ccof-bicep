#Requires -Version 7.0
<#
.SYNOPSIS
  Read-only verification of the CCOF private-network configuration. Makes NO changes.

.DESCRIPTION
  Checks, for the given CCOF resources:
    - Subnets: delegation (APIM serverFarms, Flex App/environments), PE subnet undelegated,
      NSG / route table presence.
    - Private DNS zones: exist and are linked to the VNet (and hub VNet if given).
    - Private endpoints: Cosmos (Sql), each storage account (blob), optional Foundry and
      inbound sites endpoints; connection state Approved; DNS zone group attached.
    - Function Apps: VNet integration subnet and route-all setting.
    - APIM: SKU and outbound VNet integration subnet.
    - Public network access state of Cosmos, storage and Foundry (reported, not judged).
    - In-app health probe of the admin app (Cosmos reachable from inside the VNet).
  Each row prints PASS / WARN / FAIL. Exit code 1 if any FAIL. -ResultPath also writes the rows as JSON.
  Every az call names -SubscriptionId (or a full resource ID); the CLI's default subscription is not changed.
  Infra/staged/Invoke-StagedDeployment.ps1 Stage 6 (network.mode verify) runs this script.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$VnetResourceId,
  [string]$ApimSubnet = '',
  [Parameter(Mandatory)][string]$FlexSubnet,
  [Parameter(Mandatory)][string]$PeSubnet,
  [Parameter(Mandatory)][string]$CosmosResourceId,
  [Parameter(Mandatory)][string[]]$StorageAccountIds,
  [Parameter(Mandatory)][string[]]$FunctionAppIds,
  [string]$ApimResourceId = '',
  [string[]]$FoundryResourceId = @(),
  [string[]]$InboundSitesAppIds = @(),
  [string]$HubVnetResourceId = '',
  [string]$AdminAppId = '',
  [string]$ResultPath = ''
)
$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Area, [string]$Item, [string]$State, [string]$Detail) {
  $results.Add([pscustomobject]@{ Area = $Area; Item = $Item; State = $State; Detail = $Detail })
}
# Call the CLI by path: inside function Az a bare `az` resolves to the function itself (names are
# case-insensitive) and recursed without ever reaching Azure.
$script:AzExe = (Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
function Az { $sub = if ($args -contains '--ids') { @() } else { @('--subscription', $SubscriptionId) }; $out = & $script:AzExe @args @sub --only-show-errors -o json 2>$null; if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }; ($out -join "`n") | ConvertFrom-Json -Depth 100 }
function Short([string]$id) { ($id -split '/')[-1] }

$vnetRg = ($VnetResourceId -split '/')[4]; $vnet = Short $VnetResourceId

# ---- Subnets ----
$expect = [ordered]@{}
# APIM outbound integration applies to Standard v2 / Premium v2 only; without -ApimSubnet it is not checked.
if ($ApimSubnet) { $expect[$ApimSubnet] = 'Microsoft.Web/serverFarms' }
if ($FlexSubnet -ne $ApimSubnet) { $expect[$FlexSubnet] = 'Microsoft.App/environments' } else { Add-Result 'Subnet' $FlexSubnet 'FAIL' 'Flex and APIM must use separate subnets' }
if ($PeSubnet -in @($ApimSubnet, $FlexSubnet)) { Add-Result 'Subnet' $PeSubnet 'FAIL' 'private endpoints need their own undelegated subnet' } else { $expect[$PeSubnet] = '' }
foreach ($name in @($expect.Keys)) {
  $s = Az network vnet subnet show -g $vnetRg --vnet-name $vnet -n $name
  if (-not $s) { Add-Result 'Subnet' $name 'FAIL' 'not found'; continue }
  $deleg = @($s.delegations | ForEach-Object serviceName) -join ','
  $want = $expect[$name]
  $state = if ($want) { if ($deleg -eq $want) { 'PASS' } else { 'FAIL' } } else { if (-not $deleg) { 'PASS' } else { 'FAIL' } }
  $extra = "prefix=$($s.addressPrefix); delegation=$(if ($deleg) {$deleg} else {'none'}); nsg=$([bool]$s.networkSecurityGroup); routeTable=$(if ($s.routeTable) {Short $s.routeTable.id} else {'none'})"
  Add-Result 'Subnet' $name $state $extra
  if ($name -eq $ApimSubnet -and -not $s.networkSecurityGroup) { Add-Result 'Subnet' $name 'WARN' 'APIM v2 subnet should have an NSG' }
}

# ---- Private endpoints (by target) ----
$peAll = @(Az network private-endpoint list -g $vnetRg)
function Check-Pe([string]$Area, [string]$TargetId, [string]$Group) {
  $match = @($peAll | Where-Object {
    $c = @($_.privateLinkServiceConnections) + @($_.manualPrivateLinkServiceConnections) | Where-Object { $_ }
    $c | Where-Object { $_.privateLinkServiceId -ieq $TargetId -and (@($_.groupIds) -contains $Group) }
  })
  if (-not $match) { Add-Result $Area "$(Short $TargetId) [$Group]" 'FAIL' 'no private endpoint in this VNet resource group'; return }
  foreach ($pe in $match) {
    $conn = @(@($pe.privateLinkServiceConnections) + @($pe.manualPrivateLinkServiceConnections) | Where-Object { $_ })[0]
    $status = $conn.privateLinkServiceConnectionState.status
    $subnetOk = ($pe.subnet.id -split '/')[-1] -eq $PeSubnet
    $zg = Az network private-endpoint dns-zone-group list -g $vnetRg --endpoint-name $pe.name
    $zones = @($zg | ForEach-Object { $_.privateDnsZoneConfigs } | ForEach-Object { Short $_.privateDnsZoneId }) -join ','
    $state = if ($status -eq 'Approved' -and $subnetOk -and $zones) { 'PASS' } elseif ($status -eq 'Approved') { 'WARN' } else { 'FAIL' }
    Add-Result $Area "$(Short $TargetId) [$Group]" $state "pe=$($pe.name); status=$status; peSubnet=$subnetOk; dnsZones=$(if ($zones) {$zones} else {'NONE'})"
  }
}
Check-Pe 'PrivateEndpoint' $CosmosResourceId 'Sql'
foreach ($sa in $StorageAccountIds) { Check-Pe 'PrivateEndpoint' $sa 'blob' }
foreach ($fid in $FoundryResourceId) { Check-Pe 'PrivateEndpoint' $fid 'account' }
foreach ($site in $InboundSitesAppIds) { Check-Pe 'PrivateEndpoint' $site 'sites' }

# ---- Private DNS zones and links ----
$zones = @('privatelink.documents.azure.com','privatelink.blob.core.windows.net')
if ($FoundryResourceId) { $zones += 'privatelink.cognitiveservices.azure.com','privatelink.openai.azure.com','privatelink.services.ai.azure.com' }
if ($InboundSitesAppIds.Count) { $zones += 'privatelink.azurewebsites.net' }
$allZones = @(Az network private-dns zone list)
foreach ($z in $zones) {
  $found = @($allZones | Where-Object name -eq $z)
  if (-not $found) { Add-Result 'PrivateDNS' $z 'FAIL' 'zone not found in subscription'; continue }
  # The VNet resolves a name through the one zone of that name linked to it (or to its hub). Other
  # zones of the same name elsewhere in the subscription do not affect this VNet.
  $linkedZones = @()
  foreach ($zone in $found) {
    $zrg = ($zone.id -split '/')[4]
    $links = @(Az network private-dns link vnet list -g $zrg -z $z)
    $linkedIds = @($links | ForEach-Object { $_.virtualNetwork.id })
    $spoke = $linkedIds -contains $VnetResourceId
    $hub = $HubVnetResourceId -and ($linkedIds -contains $HubVnetResourceId)
    if ($spoke -or $hub) { $linkedZones += $zone; Add-Result 'PrivateDNS' "$z ($zrg)" 'PASS' "linkedToVnet=$spoke; linkedToHub=$hub; records=$($zone.numberOfRecordSets)" }
    elseif ($found.Count -gt 1) { Add-Result 'PrivateDNS' "$z ($zrg)" 'INFO' "another zone of this name; not linked to this VNet (does not affect it); records=$($zone.numberOfRecordSets)" }
  }
  if (-not $linkedZones.Count) { Add-Result 'PrivateDNS' $z 'FAIL' "no zone of this name is linked to the VNet$(if ($HubVnetResourceId) { ' or the hub VNet' }) ($($found.Count) found)" }
  elseif ($linkedZones.Count -gt 1) { Add-Result 'PrivateDNS' $z 'WARN' "$($linkedZones.Count) zones with this name are linked; a VNet can resolve through only one" }
}

# ---- Function Apps ----
foreach ($appId in $FunctionAppIds) {
  $a = Az resource show --ids $appId --api-version 2024-04-01
  if (-not $a) { Add-Result 'FunctionApp' (Short $appId) 'FAIL' 'not found'; continue }
  $sub = $a.properties.virtualNetworkSubnetId
  $onFlex = $sub -and (($sub -split '/')[-1] -eq $FlexSubnet) -and ($sub -like "$VnetResourceId/*")
  $routeAll = $a.properties.vnetRouteAllEnabled
  $outbound = $a.properties.outboundVnetRouting
  $state = if ($onFlex) { 'PASS' } else { 'FAIL' }
  Add-Result 'FunctionApp' (Short $appId) $state "subnet=$(if ($sub) {Short $sub} else {'none'}); routeAll=$routeAll; outboundVnetRouting=$($outbound | ConvertTo-Json -Compress -Depth 3); publicNetworkAccess=$($a.properties.publicNetworkAccess)"
}

# ---- APIM ----
if ($ApimResourceId) {
  $apim = Az resource show --ids $ApimResourceId --api-version 2024-05-01
  if (-not $apim) { Add-Result 'APIM' (Short $ApimResourceId) 'FAIL' 'not found' }
  else {
    $sn = $apim.properties.virtualNetworkConfiguration.subnetResourceId
    $ok = $sn -and (($sn -split '/')[-1] -eq $ApimSubnet)
    Add-Result 'APIM' $apim.name $(if ($ok) {'PASS'} else {'FAIL'}) "sku=$($apim.sku.name); vnetType=$($apim.properties.virtualNetworkType); subnet=$(if ($sn) {Short $sn} else {'none'}); publicNetworkAccess=$($apim.properties.publicNetworkAccess)"
  }
}

# ---- Public network access (reported) ----
$cos = Az resource show --ids $CosmosResourceId --api-version 2024-11-15
if ($cos) { Add-Result 'PublicAccess' (Short $CosmosResourceId) 'INFO' "cosmos publicNetworkAccess=$($cos.properties.publicNetworkAccess); disableLocalAuth=$($cos.properties.disableLocalAuth)" }
foreach ($sa in $StorageAccountIds) {
  $s = Az resource show --ids $sa --api-version 2024-01-01
  if ($s) { Add-Result 'PublicAccess' (Short $sa) 'INFO' "storage publicNetworkAccess=$($s.properties.publicNetworkAccess); allowSharedKeyAccess=$($s.properties.allowSharedKeyAccess); allowBlobPublicAccess=$($s.properties.allowBlobPublicAccess)" }
}
foreach ($fid in $FoundryResourceId) {
  $f = Az resource show --ids $fid --api-version 2025-06-01
  if ($f) { Add-Result 'PublicAccess' (Short $fid) 'INFO' "foundry publicNetworkAccess=$($f.properties.publicNetworkAccess)" }
}

# ---- Admin app health (in-VNet Cosmos probe) ----
if ($AdminAppId) {
  $admin = Az resource show --ids $AdminAppId --api-version 2024-04-01
  $hostName = $admin.properties.defaultHostName
  $keysJson = & $script:AzExe functionapp keys list --ids $AdminAppId --only-show-errors -o json 2>$null
  $key = if ($keysJson) { (($keysJson -join "`n") | ConvertFrom-Json).functionKeys.default } else { $null }
  try {
    if ($hostName -and $key) {
      $h = Invoke-WebRequest "https://$hostName/api/health" -Headers @{ 'x-functions-key' = $key } -SkipHttpErrorCheck -TimeoutSec 90
      $state = if ($h.Content -match '"cosmos":"ok"' -and $h.Content -match '"auth":"configured"') { 'PASS' } else { 'FAIL' }
      Add-Result 'Health' (Short $AdminAppId) $state "HTTP $($h.StatusCode) $($h.Content)"
    } else { Add-Result 'Health' (Short $AdminAppId) 'WARN' 'hostname or function key not readable from this shell' }
  } catch { Add-Result 'Health' (Short $AdminAppId) 'WARN' "not reachable from this shell (expected if the app is private-only): $($_.Exception.Message)" }
  finally { $key = $null }
}

$results | Format-Table -AutoSize -Wrap
if ($ResultPath) { ConvertTo-Json -InputObject @($results) -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding utf8NoBOM }
$fail = @($results | Where-Object State -eq 'FAIL').Count
$warn = @($results | Where-Object State -eq 'WARN').Count
"`nSummary: $(@($results | Where-Object State -eq 'PASS').Count) PASS, $warn WARN, $fail FAIL. Read-only: nothing was changed."
"Not checked here: DNS resolution from inside the VNet, firewall/UDR egress, and Module 13 end-to-end requests."
if ($fail) { exit 1 }
