#Requires -Version 7.0
# Offline tests of scripts/cicd prerequisite checks: every Azure and Graph read is answered by a fake az
# invoker. Each negative case breaks one input and expects that one check to fail (or become manual).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cicd = Join-Path $root 'scripts\cicd'
Import-Module (Join-Path $cicd 'CicdChecks.psm1') -Force
Import-Module (Join-Path $cicd 'CicdNetworkChecks.psm1') -Force
Import-Module (Join-Path $cicd 'CicdPrereqs.psm1') -Force
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }

$SUB = '00000000-0000-4000-8000-0000000000aa'; $T = '00000000-0000-4000-8000-0000000000bb'; $OID = '00000000-0000-4000-8000-0000000000cc'
$net = "/subscriptions/$SUB/resourceGroups/net-rg/providers/Microsoft.Network"
$vA = "$net/virtualNetworks/vnet-a"; $vB = "$net/virtualNetworks/vnet-b"
$rgId = "/subscriptions/$SUB/resourceGroups/app-rg"
$readerDef = '/providers/Microsoft.Authorization/roleDefinitions/reader'; $contribDef = '/providers/Microsoft.Authorization/roleDefinitions/contrib'; $uaaDef = '/providers/Microsoft.Authorization/roleDefinitions/uaa'
$claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ oid = $OID } | ConvertTo-Json))).TrimEnd('=').Replace('+', '-').Replace('/', '_')

function New-Subnet([string]$Prefix, [string]$Delegation, [bool]$Nsg) {
    @{ properties = @{ addressPrefix = $Prefix; delegations = @(if ($Delegation) { @{ properties = @{ serviceName = $Delegation } } }); networkSecurityGroup = $(if ($Nsg) { @{ id = "$net/networkSecurityGroups/nsg" } } else { $null }) } }
}
function Reset-World {
    $script:calls = [Collections.Generic.List[string]]::new()
    $script:W = @{
        account = @{ id = $SUB; tenantId = $T; user = @{ name = 'uami-client'; type = 'servicePrincipal' } }
        group = @{ location = 'eastus2' }
        providers = @($script:ProviderList | ForEach-Object { @{ ns = $_; state = 'Registered' } })
        flex = @(@{ name = 'East US 2' }, @{ name = 'Central US' })
        apimLocations = @('East US 2', 'Central US')
        cosmos = @{ eastus2 = $true; centralus = $true }
        assignments = @(@{ properties = @{ scope = $rgId; roleDefinitionId = $readerDef } })
        subnets = @{
            "$vA/subnets/func" = New-Subnet '10.0.0.0/27' 'Microsoft.App/environments' $true
            "$vA/subnets/pe" = New-Subnet '10.0.0.64/26' '' $true
            "$vA/subnets/apim" = New-Subnet '10.0.0.32/27' 'Microsoft.Web/serverFarms' $true
            "$vB/subnets/apim" = New-Subnet '10.1.0.0/27' 'Microsoft.Web/serverFarms' $true
            "$vB/subnets/func" = New-Subnet '10.1.0.128/27' 'Microsoft.App/environments' $false
            "$vB/subnets/pe" = New-Subnet '10.1.0.64/26' '' $false
        }
        links = @{ 'privatelink.documents.azure.com' = @($vA, $vB); 'privatelink.blob.core.windows.net' = @($vA, $vB) }
        peerings = @{ 'vnet-a' = @(@{ name = 'a-to-b'; properties = @{ remoteVirtualNetwork = @{ id = $vB }; peeringState = 'Connected' } }); 'vnet-b' = @(@{ name = 'b-to-a'; properties = @{ remoteVirtualNetwork = @{ id = $vA }; peeringState = 'Connected' } }) }
        deployments = @('claude-haiku-4-5', 'claude-sonnet-5')
        fdAvailable = $true
        graph = 'ok'
        healthTargets = @('x-law', 'x-apim', 'x-cosmos', 'x-b-apim')
    }
}
$script:ProviderList = @('Microsoft.Web', 'Microsoft.DocumentDB', 'Microsoft.Storage', 'Microsoft.Network', 'Microsoft.OperationalInsights', 'Microsoft.Insights',
    'Microsoft.ManagedIdentity', 'Microsoft.ApiManagement', 'Microsoft.AlertsManagement', 'Microsoft.App', 'Microsoft.Cdn', 'Microsoft.CognitiveServices')
$roleDefs = @{
    $readerDef = @{ properties = @{ roleName = 'Reader'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }
    $contribDef = @{ properties = @{ roleName = 'Contributor'; permissions = @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Write', 'Microsoft.Authorization/*/Delete') }) } }
    $uaaDef = @{ properties = @{ roleName = 'User Access Administrator'; permissions = @(@{ actions = @('*/read', 'Microsoft.Authorization/*'); notActions = @() }) } }
}
$ok = { param($d) @{ Ok = $true; Data = $d; Error = '' } }
$err = { param($e) @{ Ok = $false; Data = $null; Error = $e } }
Set-CicdAzInvoker {
    param([string[]]$A)
    $line = $A -join ' '; $script:calls.Add($line); $W = $script:W
    if ($line -eq 'account show') { if ($W.account) { return & $ok $W.account } else { return & $err 'Please run az login' } }
    if ($line -like 'account get-access-token*') { return & $ok @{ accessToken = "h.$claims.s" } }
    if ($line -like 'group show*') { if ($W.group) { return & $ok $W.group } else { return & $err "(ResourceGroupNotFound) Resource group 'app-rg' could not be found." } }
    if ($line -like 'provider list*') { return & $ok $W.providers }
    if ($line -like 'provider show*') { return & $ok $W.apimLocations }
    if ($line -like 'functionapp list-flexconsumption-locations*') { return & $ok $W.flex }
    if ($line -like 'cosmosdb locations show*') { $loc = $A[$A.IndexOf('--location') + 1]; return & $ok @{ properties = @{ isSubscriptionRegionAccessAllowedForRegular = $W.cosmos[$loc] } } }
    $url = if ($A -contains '--url') { $A[$A.IndexOf('--url') + 1] } else { '' }
    if ($url -like 'https://graph.microsoft.com/*') {
        if ($W.graph -eq 'denied') { return & $err 'Forbidden (403) Authorization_RequestDenied Insufficient privileges' }
        if ($W.graph -eq 'missing') { return & $err "Not Found (404) Resource 'x' does not exist" }
        return & $ok @{ displayName = 'fixture'; securityEnabled = ($W.graph -ne 'notsecurity') }
    }
    $path = ([uri]$url).AbsolutePath
    if ($path -like '*/roleAssignments') { if ($W.assignments -eq 'denied') { return & $err '(AuthorizationFailed) does not have authorization' }; return & $ok @{ value = $W.assignments } }
    if ($path -like '/providers/Microsoft.Authorization/roleDefinitions/*') { return & $ok $roleDefs[$path] }
    if ($path -like '*/subnets/*') { $stg = $W.subnets[$path]; if ($stg) { return & $ok $stg } else { return & $err '(NotFound) subnet not found' } }
    if ($path -like '*/virtualNetworkLinks') { $z = ($path -split '/')[-2]; return & $ok @{ value = @($W.links[$z] | ForEach-Object { @{ properties = @{ virtualNetwork = @{ id = $_ } } } }) } }
    if ($path -like '*/virtualNetworkPeerings') { return & $ok @{ value = @($W.peerings[($path -split '/')[-2]]) } }
    if ($path -like '*/accounts/*/deployments') { return & $ok @{ value = @($W.deployments | ForEach-Object { @{ name = $_ } }) } }
    if ($path -like '*/workspaces/*' -or $path -like '*/Microsoft.ApiManagement/service/*' -or $path -like '*/databaseAccounts/*') { if (@($W.healthTargets) -contains ($path -split '/')[-1]) { return & $ok @{ id = $path } } else { return & $err '(ResourceNotFound) The Resource was not found.' } }
    if ($path -like '*/checkEndpointNameAvailability') { return & $ok @{ nameAvailable = $W.fdAvailable; message = $(if ($W.fdAvailable) { '' } else { 'Name not available' }) } }
    throw "unexpected az call: $line"
}

function New-Staged {
    @{ tenantId = $T; subscriptionId = $SUB; resourceGroup = 'app-rg'; location = 'eastus2'
        stage1 = @{ includeAdmin = $true; foundry = @{ create = $false } }
        network = @{ mode = 'existing'; existing = @{ functionsSubnetId = "$vA/subnets/func"; privateEndpointSubnetId = "$vA/subnets/pe"; apimSubnetId = "$vA/subnets/apim"
            privateDnsZoneIds = @{ cosmos = "$net/privateDnsZones/privatelink.documents.azure.com"; blob = "$net/privateDnsZones/privatelink.blob.core.windows.net" } } }
        entra = @{ existing = @{ gatewayAppId = '11111111-1111-4111-8111-111111111111'; resolverAppId = '22222222-2222-4222-8222-222222222222'; adminAppId = '33333333-3333-4333-8333-333333333333' }
            manualVerification = @{ confirmedBy = 'Entra team'; confirmedOn = '2026-11-17' } }
        groups = @(@{ projectId = 'P1'; classification = 'STD'; groupId = '44444444-4444-4444-8444-444444444444' })
        backends = @(@{ id = 'be1'; subscriptionId = $SUB; resourceGroup = 'f-rg'; accountName = 'acct'; deploymentInferenceGeo = @{ 'claude-haiku-4-5' = 'global' }; assignCognitiveServicesUser = $true }) }
}
function New-Dr {
    @{ tenantId = $T; subscriptionId = $SUB; primary = @{ location = 'eastus2'; vnetId = $vA; peer = $true }
        secondary = @{ location = 'centralus'; resourceGroup = 'app-rg'; networkMode = 'existing'; existingVnetId = $vB; subnets = @{ apim = @{ name = 'apim' }; functions = @{ name = 'func' }; privateEndpoints = @{ name = 'pe' } } }
        dnsZones = @{ subscriptionId = $SUB; resourceGroup = 'net-rg'; zoneNames = @('privatelink.documents.azure.com') }
        standby = @{ stagedConfigPath = 'staged.config.json'; stagedStateDirectory = '.staged-state'; stateDirectory = '.dr-state' }
        failover = @{ ledgerCoverageStartAt = '' }
        frontDoor = @{ stem = 'ccof-fd'; wafMode = 'Prevention' } }
}
function New-Health([string]$Stem = 'x') { @{ subscriptionId = $SUB; resourceGroup = 'app-rg'; stem = $Stem; frontDoor = @{ host = 'REPLACE-endpoint.z01.azurefd.net' } } }
# Region B (DR standby): shared primary workspace and Cosmos account; shared and idle-standby rules off.
function New-HealthB {
    $off = { @{ enabled = $false } }
    @{ subscriptionId = $SUB; resourceGroup = 'app-rg'; stem = 'x-b'
        workspaceId = "$rgId/providers/Microsoft.OperationalInsights/workspaces/x-law"; cosmosId = "$rgId/providers/Microsoft.DocumentDB/databaseAccounts/x-cosmos"
        rules = @{ cosmosThrottled = & $off; cosmosServerErrors = & $off; cosmosAvailability = & $off; frontDoorOriginHealth = & $off; frontDoor5xx = & $off; foundryServerErrors = & $off; reconcilerStale = & $off; gatewayTelemetrySilent = & $off } }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ccof-cicd-prereq-' + [guid]::NewGuid().ToString('N'))
function Write-Env([hashtable]$Files) {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $scratch | Out-Null
    foreach ($k in $Files.Keys) { if ($null -ne $Files[$k]) { $Files[$k] | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $scratch $k) -Encoding utf8NoBOM } }
}
function Get-Run([string]$Mode = 'preview', [hashtable]$Override = @{}) {
    $files = @{ 'staged.config.json' = (New-Staged); 'dr-standby.config.json' = (New-Dr); 'health-a.json' = (New-Health); 'health-b.json' = (New-HealthB); 'health-b.optout.json' = $null }
    foreach ($k in $Override.Keys) { $files[$k] = $Override[$k] }
    Write-Env $files
    return @(Invoke-CicdPrerequisites $scratch $Mode @('primary', 'frontdoor', 'standby', 'health'))
}
function Get-C([object[]]$Checks, [string]$Id) { @($Checks | Where-Object { $_.id -eq $Id })[0] }
function St([object[]]$Checks, [string]$Id) { $c = Get-C $Checks $Id; if ($c) { $c.status } else { '<absent>' } }

try {
    # Happy path.
    Reset-World
    $r = Get-Run
    Check 'happy: no failing check' (@($r | Where-Object status -EQ 'fail').Count -eq 0)
    if (@($r | Where-Object status -EQ 'fail').Count) { $r | Where-Object status -EQ 'fail' | ForEach-Object { Write-Host "  $($_.id): $($_.evidence)" } }
    Check 'happy: every check has evidence and a source' (@($r | Where-Object { -not $_.evidence -or -not $_.source }).Count -eq 0)
    Check 'happy: health placeholders for Front Door are manual' ((St $r 'config.health-a') -eq 'manual')
    Check 'happy: preview identity with Reader passes' ((St $r 'access.rg.read') -eq 'pass')
    Check 'happy: subnets, zones and peering pass' ((St $r 'network.subnet.A.functions') -eq 'pass' -and (St $r 'network.subnet.B.apim') -eq 'pass' -and (St $r 'network.dns.privatelink.documents.azure.com') -eq 'pass' -and (St $r 'network.peering.vnet-a') -eq 'pass')
    Check 'happy: Graph readable -> app and group pass' ((St $r 'entra.adminAppId') -eq 'pass' -and (St $r 'entra.group.P1-STD') -eq 'pass')
    Check 'happy: Foundry deployment present, model quota manual' ((St $r 'foundry.be1') -eq 'pass' -and (St $r 'quota.foundry') -eq 'manual')
    $writes = @($script:calls | Where-Object { $_ -match '--method (put|patch|delete)|\b(create|update|delete|set|assign)\b' -or ($_ -match '--method post' -and $_ -notmatch 'checkEndpointNameAvailability') })
    Check 'read-only: no write az call' ($writes.Count -eq 0)
    Check 'read-only: Graph only GET' (@($script:calls | Where-Object { $_ -match 'graph.microsoft.com' -and $_ -notmatch '--method get' }).Count -eq 0)
    Check 'read-only: token never in a check' (@($r | Where-Object { $_.evidence -match "h\.$claims" }).Count -eq 0)

    # Negative: access and identity.
    Reset-World; $r = Get-Run 'apply'
    Check 'neg: Reader in apply mode fails (missing deployments/write)' ((St $r 'access.rg.deploy') -eq 'fail' -and (Get-C $r 'access.rg.deploy').evidence -match 'Microsoft.Resources/deployments/write')
    Reset-World; $W.assignments = @(@{ properties = @{ scope = "/subscriptions/$SUB"; roleDefinitionId = $contribDef } }); $r = Get-Run 'apply'
    Check 'neg: Contributor alone lacks roleAssignments/write (notActions honoured)' ((St $r 'access.rg.deploy') -eq 'fail' -and (Get-C $r 'access.rg.deploy').evidence -match 'roleAssignments/write' -and (Get-C $r 'access.rg.deploy').evidence -notmatch 'deployments/write')
    Reset-World; $W.assignments = @(@{ properties = @{ scope = "/subscriptions/$SUB"; roleDefinitionId = $contribDef } }, @{ properties = @{ scope = $rgId; roleDefinitionId = $uaaDef } }); $r = Get-Run 'apply'
    Check 'apply: Contributor + User Access Administrator passes at the RG' ((St $r 'access.rg.deploy') -eq 'pass')
    Check 'apply: subscription Contributor covers subnet join in the network RG' ((St $r 'access.subnet.functionsSubnetId') -eq 'pass')
    Reset-World; $W.assignments = @(@{ properties = @{ scope = $rgId; roleDefinitionId = $contribDef } }, @{ properties = @{ scope = $rgId; roleDefinitionId = $uaaDef } }); $r = Get-Run 'apply'
    Check 'neg: roles on the app RG do not cover the network RG subnet' ((St $r 'access.subnet.functionsSubnetId') -eq 'fail' -and (St $r 'access.foundry.be1') -eq 'fail')
    Reset-World; $W.assignments = 'denied'; $r = Get-Run
    Check 'neg: unreadable role assignments -> manual, not pass' ((St $r 'access.rg.read') -eq 'manual')
    Reset-World; $W.account = $null; $r = Get-Run
    Check 'neg: signed out -> fail' ((St $r 'access.signed-in') -eq 'fail')
    Reset-World; $W.account.tenantId = '00000000-0000-4000-8000-000000000999'; $r = Get-Run
    Check 'neg: wrong tenant -> fail' ((St $r 'access.signed-in') -eq 'fail')
    Reset-World; $W.group = $null; $r = Get-Run
    Check 'neg: resource group missing -> fail' ((St $r 'access.resource-group') -eq 'fail')

    # Negative: subscription and region.
    Reset-World; $W.providers[10].state = 'NotRegistered'; $r = Get-Run
    Check 'neg: Microsoft.Cdn not registered -> fail' ((St $r 'providers.Microsoft.Cdn') -eq 'fail')
    Reset-World; $W.flex = @(@{ name = 'East US 2' }); $r = Get-Run
    Check 'neg: Flex not offered in region B -> fail' ((St $r 'region.flex.B') -eq 'fail' -and (St $r 'region.flex.A') -eq 'pass')
    Reset-World; $W.cosmos.centralus = $false; $r = Get-Run
    Check 'neg: Cosmos regional access denied -> fail' ((St $r 'region.cosmos.B') -eq 'fail')
    Reset-World; $W.apimLocations = @('East US 2'); $r = Get-Run
    Check 'neg: APIM not offered in region B -> fail' ((St $r 'region.apim.B') -eq 'fail')

    # Negative: network.
    Reset-World; $W.subnets["$vA/subnets/func"] = New-Subnet '10.0.0.0/27' 'Microsoft.Web/serverFarms' $true; $r = Get-Run
    Check 'neg: Functions subnet with the wrong delegation -> fail' ((St $r 'network.subnet.A.functions') -eq 'fail' -and (Get-C $r 'network.subnet.A.functions').evidence -match 'Microsoft.App/environments missing')
    Reset-World; $W.subnets["$vB/subnets/apim"] = New-Subnet '10.1.0.0/27' 'Microsoft.Web/serverFarms' $false; $r = Get-Run
    Check 'neg: APIM subnet without NSG -> fail' ((St $r 'network.subnet.B.apim') -eq 'fail')
    Reset-World; $W.subnets["$vA/subnets/apim"] = New-Subnet '10.0.0.32/28' 'Microsoft.Web/serverFarms' $true; $r = Get-Run
    Check 'neg: APIM subnet /28 -> fail' ((St $r 'network.subnet.A.apim') -eq 'fail')
    Reset-World; $W.subnets["$vA/subnets/pe"] = New-Subnet '10.0.0.64/26' 'Microsoft.Web/serverFarms' $false; $r = Get-Run
    Check 'neg: delegated private endpoint subnet -> fail' ((St $r 'network.subnet.A.privateEndpoints') -eq 'fail')
    Reset-World; $W.subnets.Remove("$vB/subnets/func"); $r = Get-Run
    Check 'neg: missing region B subnet -> fail' ((St $r 'network.subnet.B.functions') -eq 'fail')
    Reset-World; $W.links['privatelink.blob.core.windows.net'] = @($vA); $r = Get-Run
    Check 'neg: DNS zone not linked to region B -> fail' ((St $r 'network.dns.privatelink.blob.core.windows.net') -eq 'fail' -and (Get-C $r 'network.dns.privatelink.blob.core.windows.net').evidence -match 'vnet-b')
    Reset-World; $W.peerings['vnet-b'] = @(); $r = Get-Run
    Check 'peering absent with primary.peer true -> manual (Bootstrap creates it)' ((St $r 'network.peering.vnet-b') -eq 'manual')
    Reset-World; $W.peerings['vnet-a'][0].properties.peeringState = 'Disconnected'; $r = Get-Run
    Check 'neg: peering Disconnected -> fail' ((St $r 'network.peering.vnet-a') -eq 'fail')

    # Negative: Entra (never a Graph write; a denied read is manual).
    Reset-World; $stg = New-Staged; $stg.entra.Remove('manualVerification'); $r = Get-Run 'preview' @{ 'staged.config.json' = $stg }
    Check 'neg: no entra.manualVerification -> fail' ((St $r 'entra.manual-mode') -eq 'fail')
    Reset-World; $stg = New-Staged; $stg.entra.existing.resolverAppId = 'resolver'; $r = Get-Run 'preview' @{ 'staged.config.json' = $stg }
    Check 'neg: app ID not a GUID -> fail' ((St $r 'entra.resolverAppId') -eq 'fail')
    Reset-World; $W.graph = 'denied'; $r = Get-Run
    Check 'Graph denied -> manual (verify manually)' ((St $r 'entra.gatewayAppId') -eq 'manual' -and (St $r 'entra.group.P1-STD') -eq 'manual')
    Reset-World; $W.graph = 'missing'; $r = Get-Run
    Check 'neg: Graph 404 -> fail' ((St $r 'entra.gatewayAppId') -eq 'fail')
    Reset-World; $W.graph = 'notsecurity'; $r = Get-Run
    Check 'neg: group not security-enabled -> fail' ((St $r 'entra.group.P1-STD') -eq 'fail' -and (St $r 'entra.gatewayAppId') -eq 'pass')

    # Negative: Foundry, Front Door, configs.
    Reset-World; $W.deployments = @('claude-sonnet-5'); $r = Get-Run
    Check 'neg: Foundry deployment missing -> fail, Marketplace manual' ((St $r 'foundry.be1') -eq 'fail' -and (St $r 'marketplace.be1') -eq 'manual')
    Reset-World; $W.fdAvailable = $false; $r = Get-Run
    Check 'neg: Front Door endpoint name taken -> fail' ((St $r 'names.frontdoor-endpoint') -eq 'fail')
    Reset-World; $null = Get-Run; New-Item -ItemType Directory (Join-Path $scratch '.dr-state') | Out-Null
    '{"profileName":"ccof-fd-fd","endpointHostName":"h.azurefd.net"}' | Set-Content (Join-Path $scratch '.dr-state/frontdoor-state.json')
    $W.fdAvailable = $false; $script:calls.Clear(); $r = @(Invoke-CicdPrerequisites $scratch 'preview' @('frontdoor'))
    Check 'owned Front Door (state file) -> pass without availability call' ((St $r 'names.frontdoor-endpoint') -eq 'pass' -and @($script:calls | Where-Object { $_ -match 'checkEndpointName' }).Count -eq 0)
    Reset-World; $d = New-Dr; $d.frontDoor.stem = 'CCOF_fd'; $r = Get-Run 'preview' @{ 'dr-standby.config.json' = $d }
    Check 'neg: invalid Front Door stem -> fail' ((St $r 'frontdoor.stem') -eq 'fail')
    Reset-World; $d = New-Dr; $d.frontDoor.wafMode = 'Block'; $r = Get-Run 'preview' @{ 'dr-standby.config.json' = $d }
    Check 'neg: invalid WAF mode -> fail' ((St $r 'frontdoor.waf') -eq 'fail')
    Reset-World; $d = New-Dr; $d.standby.stateDirectory = 'dr-state'; $r = Get-Run 'preview' @{ 'dr-standby.config.json' = $d }
    Check 'neg: DR state folder outside the layout -> fail' ((St $r 'config.dr.paths') -eq 'fail')
    Reset-World; $r = Get-Run 'preview' @{ 'dr-standby.config.json' = (New-Dr) }
    Check 'DR config without entra (manual Entra) -> pass' ((St $r 'config.dr.entra') -eq 'pass')
    Reset-World; $d = New-Dr; $d.entra = @{ gatewayAppId = '11111111-1111-4111-8111-111111111111' }; $r = Get-Run 'preview' @{ 'dr-standby.config.json' = $d }
    Check 'neg: DR config with entra (Discover reads Graph) -> manual' ((St $r 'config.dr.entra') -eq 'manual')
    Reset-World; $stg = New-Staged; $stg.resourceGroup = 'REPLACE-rg'; $r = Get-Run 'preview' @{ 'staged.config.json' = $stg }
    Check 'neg: REPLACE- placeholder in staged config -> fail' ((St $r 'config.staged.placeholders') -eq 'fail')
    Reset-World; $d = New-Dr; $d.failover.ledgerCoverageStartAt = 'REPLACE-2026-01-01T00:00:00.000Z'; $r = Get-Run 'preview' @{ 'dr-standby.config.json' = $d }
    Check 'neg: REPLACE ledgerCoverageStartAt (failover Status refuses it) -> fail' ((St $r 'config.dr.placeholders') -eq 'fail' -and (Get-C $r 'config.dr.placeholders').evidence -match 'empty')
    Reset-World; $stg = New-Staged; $stg.stage1 = @{ foundry = @{ create = $false; accountName = 'REPLACE-foundry' } }; $r = Get-Run 'preview' @{ 'staged.config.json' = $stg }
    Check 'unused Foundry block (create false) placeholders ignored' ((St $r 'config.staged.placeholders') -eq 'pass')
    Reset-World; $stg = New-Staged; $stg.stage1 = @{ foundry = @{ create = $true; accountName = 'REPLACE-foundry' } }; $r = Get-Run 'preview' @{ 'staged.config.json' = $stg }
    Check 'neg: Foundry create true with placeholder -> fail' ((St $r 'config.staged.placeholders') -eq 'fail')
    Reset-World; $h = New-Health; $h.subscriptionId = 'REPLACE-sub'; $r = Get-Run 'preview' @{ 'health-b.json' = $h }
    Check 'neg: health placeholder outside frontDoor -> fail' ((St $r 'config.health-b') -eq 'fail')
    # Health alert targets: the driver stops with apim_missing / workspace_missing / cosmos_missing when they do not resolve.
    Reset-World; $r = Get-Run 'apply'
    Check 'health A targets resolve by stem -> pass' ((St $r 'health.a.targets') -eq 'pass')
    Check 'region B with cosmosId and workspaceId of the primary -> targets, scope, shared and standby checks pass' ((St $r 'config.health-b') -eq 'pass' -and (St $r 'health.b.targets') -eq 'pass' -and (St $r 'health.b.scope') -eq 'pass' -and (St $r 'health.shared-duplicates') -eq 'pass' -and (St $r 'health.b.standby-rules') -eq 'pass')
    Check 'region B Cosmos target is the configured cosmosId' ((Get-C $r 'health.b.targets').evidence -match 'cosmos x-cosmos found')
    Reset-World; $hb = New-HealthB; $hb.Remove('cosmosId'); $r = Get-Run 'apply' @{ 'health-b.json' = $hb }
    Check 'neg: region B without cosmosId (no <stem>-b-cosmos for a standby) -> fail, hint cosmosId' ((St $r 'health.b.targets') -eq 'fail' -and (Get-C $r 'health.b.targets').evidence -match 'set cosmosId' -and (St $r 'health.b.scope') -eq 'fail')
    Reset-World; $hb = New-HealthB; $hb.cosmosId = "$rgId/providers/Microsoft.DocumentDB/databaseAccounts/gone-cosmos"; $r = Get-Run 'apply' @{ 'health-b.json' = $hb }
    Check 'neg: cosmosId that does not resolve -> fail (configured ID)' ((St $r 'health.b.targets') -eq 'fail' -and (Get-C $r 'health.b.targets').evidence -match 'gone-cosmos not found \(configured ID\)')
    Reset-World; $hb = New-HealthB; $hb.Remove('workspaceId'); $r = Get-Run 'apply' @{ 'health-b.json' = $hb }
    Check 'neg: region B without workspaceId (standby logs to the primary workspace) -> fail' ((St $r 'health.b.targets') -eq 'fail' -and (Get-C $r 'health.b.targets').evidence -match 'workspaceId' -and (Get-C $r 'health.b.scope').evidence -match 'workspace')
    # A DR environment must deploy region B alerts or opt out explicitly and visibly.
    Reset-World; $r = Get-Run 'apply' @{ 'health-b.json' = $null }
    Check 'neg: DR environment without health-b.json and no opt-out -> fail' ((St $r 'config.health-b') -eq 'fail' -and (Get-C $r 'config.health-b').evidence -match 'health-b\.optout\.json' -and (St $r 'health.b.targets') -eq '<absent>')
    $optOut = @{ reason = 'region B watched by failover Status'; approvedBy = 'Ops lead'; approvedOn = '2026-11-20' }
    Reset-World; $r = Get-Run 'apply' @{ 'health-b.json' = $null; 'health-b.optout.json' = $optOut }
    Check 'explicit opt-out -> manual, evidence says NO region B monitoring' ((St $r 'config.health-b') -eq 'manual' -and (Get-C $r 'config.health-b').evidence -match 'NO region B health monitoring' -and (Get-C $r 'config.health-b').evidence -match 'Ops lead')
    Reset-World; $o = $optOut.Clone(); $o.Remove('approvedBy'); $r = Get-Run 'apply' @{ 'health-b.json' = $null; 'health-b.optout.json' = $o }
    Check 'neg: opt-out without approvedBy -> fail' ((St $r 'config.health-b') -eq 'fail' -and (Get-C $r 'config.health-b').evidence -match 'approvedBy')
    Reset-World; $o = $optOut.Clone(); $o.approvedOn = '20 Nov'; $r = Get-Run 'apply' @{ 'health-b.json' = $null; 'health-b.optout.json' = $o }
    Check 'neg: opt-out with a malformed approvedOn -> fail' ((St $r 'config.health-b') -eq 'fail')
    Reset-World; $r = Get-Run 'apply' @{ 'health-b.optout.json' = $optOut }
    Check 'neg: health-b.json and health-b.optout.json together -> fail' ((St $r 'config.health-b') -eq 'fail' -and (Get-C $r 'config.health-b').evidence -match 'both')
    Reset-World; $r = Get-Run 'apply' @{ 'health-b.json' = $null; 'dr-standby.config.json' = $null }
    Check 'no DR config: region B not applicable -> pass' ((St $r 'config.health-b') -eq 'pass' -and (Get-C $r 'config.health-b').evidence -match 'not applicable')
    # Region B scope: secondary resource group, <A stem>-<nameSuffix>, the primary workspace and Cosmos, its own APIM.
    Reset-World; $hb = New-HealthB; $hb.stem = 'y-b'; $script:W.healthTargets += 'y-b-apim'; $r = Get-Run 'apply' @{ 'health-b.json' = $hb }
    Check 'neg: region B stem not <A stem>-<nameSuffix> -> scope fail' ((St $r 'health.b.scope') -eq 'fail' -and (Get-C $r 'health.b.scope').evidence -match 'stem')
    Reset-World; $d = New-Dr; $d.standby.nameSuffix = 'c'; $r = Get-Run 'apply' @{ 'dr-standby.config.json' = $d }
    Check 'neg: stem uses the DR nameSuffix -> x-b against suffix c fails' ((St $r 'health.b.scope') -eq 'fail' -and (Get-C $r 'health.b.scope').evidence -match 'x-c')
    Reset-World; $hb = New-HealthB; $hb.resourceGroup = 'other-rg'; $r = Get-Run 'apply' @{ 'health-b.json' = $hb }
    Check 'neg: region B resource group not the DR secondary group -> scope fail' ((St $r 'health.b.scope') -eq 'fail' -and (Get-C $r 'health.b.scope').evidence -match 'resourceGroup')
    Reset-World; $hb = New-HealthB; $hb.apim = @{ id = "$rgId/providers/Microsoft.ApiManagement/service/x-apim" }; $r = Get-Run 'apply' @{ 'health-b.json' = $hb }
    Check 'neg: region B APIM is the region A APIM -> scope fail' ((St $r 'health.b.scope') -eq 'fail' -and (Get-C $r 'health.b.scope').evidence -match 'APIM')
    Reset-World; $hb = New-HealthB; $hb.workspaceId = "$rgId/providers/Microsoft.OperationalInsights/workspaces/x-b-law"; $script:W.healthTargets += 'x-b-law'; $r = Get-Run 'apply' @{ 'health-b.json' = $hb }
    Check 'neg: region B workspace not the primary workspace -> scope fail' ((St $r 'health.b.scope') -eq 'fail' -and (Get-C $r 'health.b.scope').evidence -match 'workspace')
    # Shared targets alert once (region A); idle-standby rules stay off in region B.
    Reset-World; $hb = New-HealthB; $hb.rules.Remove('cosmosThrottled'); $r = Get-Run 'apply' @{ 'health-b.json' = $hb }
    Check 'neg: cosmosThrottled on in A and B for the shared account -> duplicate fail' ((St $r 'health.shared-duplicates') -eq 'fail' -and (Get-C $r 'health.shared-duplicates').evidence -match 'cosmosThrottled')
    $fdA = @{ host = 'ccof-fd-abc.z01.azurefd.net'; profileId = "$rgId/providers/Microsoft.Cdn/profiles/ccof-fd" }
    Reset-World; $ha = New-Health; $ha.frontDoor = $fdA; $hb = New-HealthB; $hb.frontDoor = $fdA.Clone(); $r = Get-Run 'apply' @{ 'health-a.json' = $ha; 'health-b.json' = $hb }
    Check 'neg: same Front Door host probed from A and B -> duplicate fail (web tests)' ((St $r 'health.shared-duplicates') -eq 'fail' -and (Get-C $r 'health.shared-duplicates').evidence -match 'frontDoorGateway')
    $hb.probes = @{ frontDoorGateway = 'off'; frontDoorAdmin = 'off' }; $r = Get-Run 'apply' @{ 'health-a.json' = $ha; 'health-b.json' = $hb }
    Check 'same Front Door with B probes off and FD rules off -> pass' ((St $r 'health.shared-duplicates') -eq 'pass')
    $hb.rules.Remove('frontDoor5xx'); $r = Get-Run 'apply' @{ 'health-a.json' = $ha; 'health-b.json' = $hb }
    Check 'neg: frontDoor5xx on in A and B for one profile -> duplicate fail' ((St $r 'health.shared-duplicates') -eq 'fail' -and (Get-C $r 'health.shared-duplicates').evidence -match 'frontDoor5xx')
    $fa = "/subscriptions/$SUB/resourceGroups/f-rg/providers/Microsoft.CognitiveServices/accounts/acct"
    Reset-World; $ha = New-Health; $ha.foundryAccountIds = @($fa); $hb = New-HealthB; $hb.foundryAccountIds = @($fa.ToUpper()); $hb.rules.Remove('foundryServerErrors'); $r = Get-Run 'apply' @{ 'health-a.json' = $ha; 'health-b.json' = $hb }
    Check 'neg: one Foundry account alerted from A and B -> duplicate fail' ((St $r 'health.shared-duplicates') -eq 'fail' -and (Get-C $r 'health.shared-duplicates').evidence -match 'foundryServerErrors')
    Reset-World; $hb = New-HealthB; $hb.rules.Remove('reconcilerStale'); $r = Get-Run 'apply' @{ 'health-b.json' = $hb }
    Check 'neg: reconcilerStale on for the idle standby -> fail' ((St $r 'health.b.standby-rules') -eq 'fail' -and (Get-C $r 'health.b.standby-rules').evidence -match 'reconcilerStale')
    Reset-World; $hb = New-HealthB; $hb.rules.gatewayTelemetrySilent = @{ enabled = $true }; $r = Get-Run 'apply' @{ 'health-b.json' = $hb }
    Check 'neg: gatewayTelemetrySilent on for the idle standby -> fail' ((St $r 'health.b.standby-rules') -eq 'fail')
    Reset-World; $script:W.healthTargets = @('x-law', 'x-cosmos', 'x-b-apim'); $stg = New-Staged; $stg.apim = @{ existing = @{ name = 'corp-apim' } }; $r = Get-Run 'apply' @{ 'staged.config.json' = $stg }
    Check 'neg: existing APIM without health apim.id -> fail' ((St $r 'health.a.targets') -eq 'fail' -and (Get-C $r 'health.a.targets').evidence -match 'apim\.id')
    Reset-World; $script:W.healthTargets = @(); $r = Get-Run 'apply'
    Check 'new environment: stem targets not created yet -> manual' ((St $r 'health.a.targets') -eq 'manual')
    Reset-World; $r = Get-Run 'preview' @{ 'dr-standby.config.json' = $null }
    Check 'neg: missing DR config -> fail' ((St $r 'config.dr') -eq 'fail')

    # Report helpers.
    Check 'invalid status rejected' ($(try { New-CicdCheck 'x' 'a' 't' 'ok' 'e' 's'; $false } catch { $true }))
    Check 'empty evidence rejected' ($(try { New-CicdCheck 'x' 'a' 't' 'pass' '' 's'; $false } catch { $true }))
    $md = ConvertTo-CicdMarkdown @((New-CicdCheck 'p' 'a' 'P' 'pass' 'e|1' 's'), (New-CicdCheck 'f' 'a' 'F' 'fail' 'e2' 's')) 'T'
    Check 'markdown: fail first, pipes escaped' ($md.IndexOf('**FAIL**') -lt $md.IndexOf('| PASS') -and $md -match 'e\\\|1')

    # Script end to end (offline: no Azure call), exit codes and report files.
    Write-Env @{ 'staged.config.json' = (New-Staged); 'dr-standby.config.json' = (New-Dr); 'health-a.json' = (New-Health); 'health-b.json' = (New-HealthB) }
    $outDir = Join-Path $scratch 'out'
    $null = & pwsh -NoProfile -File (Join-Path $cicd 'Test-CicdPrerequisites.ps1') -DeployDirectory $scratch -OutputDirectory $outDir -Offline
    $code = $LASTEXITCODE
    $json = Get-Content (Join-Path $outDir 'prereqs.json') -Raw | ConvertFrom-Json
    Check 'script offline: exit 0 and prereqs.json + prereqs.md written' ($code -eq 0 -and $json.offline -and $json.summary.fail -eq 0 -and (Test-Path (Join-Path $outDir 'prereqs.md')))
    $stg = New-Staged; $stg.entra.Remove('manualVerification'); $stg | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $scratch 'staged.config.json')
    $null = & pwsh -NoProfile -File (Join-Path $cicd 'Test-CicdPrerequisites.ps1') -DeployDirectory $scratch -OutputDirectory $outDir -Offline
    Check 'neg script offline: missing manual Entra mode exits 1' ($LASTEXITCODE -eq 1 -and (Get-Content (Join-Path $outDir 'prereqs.md') -Raw) -match 'entra.manual-mode')
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# Windows: cmd.exe would split "&$filter=" in az.cmd arguments; the launcher starts the CLI's Python instead.
$cli = Join-Path ([IO.Path]::GetTempPath()) "cicd-az-$PID"
try {
    New-Item -ItemType Directory (Join-Path $cli 'wbin') -Force | Out-Null
    Set-Content (Join-Path $cli 'wbin\az.cmd') '@echo off'; Set-Content (Join-Path $cli 'python.exe') ''
    $l = @(Get-CicdAzLauncher -OnWindows $true -AzCmdPath (Join-Path $cli 'wbin\az.cmd'))
    Check 'az launcher on Windows: CLI Python with -IBm azure.cli' ($l.Count -eq 3 -and $l[0] -eq (Join-Path $cli 'python.exe') -and $l[2] -eq 'azure.cli')
    Remove-Item (Join-Path $cli 'python.exe')
    Check 'neg: az launcher on Windows without the CLI Python -> az' ((@(Get-CicdAzLauncher -OnWindows $true -AzCmdPath (Join-Path $cli 'wbin\az.cmd')) -join ' ') -eq 'az')
    Check 'az launcher on Linux -> az' ((@(Get-CicdAzLauncher -OnWindows $false) -join ' ') -eq 'az')
} finally { Remove-Item -LiteralPath $cli -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "Test-CicdPrerequisites: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 60) { exit 1 }
