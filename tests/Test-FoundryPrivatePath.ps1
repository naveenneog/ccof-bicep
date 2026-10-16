#Requires -Version 7.0
# Offline ARM-shaped fixtures; no Azure access or dependencies.
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot '..\scripts\manual\Test-FoundryPrivatePath.ps1'
$script:cases = 0
$root = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/gateway/providers'
$other = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/shared/providers'
$central = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/central-dns/providers'
$script:ids = @{
    apim = "$root/Microsoft.ApiManagement/service/gateway"
    foundry = "$other/Microsoft.CognitiveServices/accounts/foundry"
    vnet = "$root/Microsoft.Network/virtualNetworks/spoke"
    peVnet = "$other/Microsoft.Network/virtualNetworks/endpoint"
    pe = "$other/Microsoft.Network/privateEndpoints/foundry-pe"
    nic = "$other/Microsoft.Network/networkInterfaces/foundry-nic"
    zone = "$central/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com"
    nsg = "$root/Microsoft.Network/networkSecurityGroups/gateway"
    route = "$root/Microsoft.Network/routeTables/gateway"
}
function Fixture([string]$Id, [string]$Type, [hashtable]$Properties) {
    @{ id = $Id; name = ($Id -split '/')[-1]; type = $Type; location = 'eastus'; properties = $Properties }
}
function New-Fixtures {
    $i = $script:ids
    $script:resources = @{}
    $script:resources[$i.apim] = Fixture $i.apim 'Microsoft.ApiManagement/service' @{
        provisioningState = 'Succeeded'; virtualNetworkType = 'None'
        virtualNetworkConfiguration = @{ subnetResourceId = "$($i.vnet)/subnets/apim" }
    }
    $script:resources[$i.apim].sku = @{ name = 'StandardV2' }
    $script:resources[$i.foundry] = Fixture $i.foundry 'Microsoft.CognitiveServices/accounts' @{
        provisioningState = 'Succeeded'; customSubDomainName = 'foundry'; publicNetworkAccess = 'Disabled'
        privateEndpointConnections = @(@{ properties = @{ privateEndpoint = @{ id = $i.pe } } })
    }
    $script:resources["$($i.vnet)/subnets/apim"] = Fixture "$($i.vnet)/subnets/apim" '' @{
        addressPrefix = '172.20.0.0/27'; networkSecurityGroup = @{ id = $i.nsg }; routeTable = @{ id = $i.route }
        delegations = @(@{ properties = @{ serviceName = 'Microsoft.Web/serverFarms' } })
    }
    $script:resources[$i.vnet] = Fixture $i.vnet '' @{ dhcpOptions = @{ dnsServers = @() } }
    $script:resources[$i.pe] = Fixture $i.pe '' @{
        provisioningState = 'Succeeded'; subnet = @{ id = "$($i.vnet)/subnets/pe" }
        privateLinkServiceConnections = @(@{ properties = @{
            provisioningState = 'Succeeded'; privateLinkServiceId = $i.foundry; groupIds = @('account')
            privateLinkServiceConnectionState = @{ status = 'Approved' }
        } })
        networkInterfaces = @(@{ id = $i.nic })
        customDnsConfigs = @(@{ fqdn = 'foundry.services.ai.azure.com'; ipAddresses = @('172.20.1.4') })
    }
    $script:resources["$($i.vnet)/subnets/pe"] = Fixture "$($i.vnet)/subnets/pe" '' @{
        delegations = @(); addressPrefix = '172.20.1.0/24'; privateEndpointNetworkPolicies = 'Disabled'
    }
    $script:resources[$i.nic] = Fixture $i.nic '' @{
        ipConfigurations = @(@{ properties = @{
            privateIPAddress = '172.20.1.4'
            privateLinkConnectionProperties = @{ fqdns = @('foundry.services.ai.azure.com') }
        } })
    }
    $script:resources[$i.nsg] = Fixture $i.nsg '' @{
        securityRules = @(@{ name = 'allow-private'; properties = @{
            priority = 100; direction = 'Outbound'; access = 'Allow'; protocol = 'Tcp'
            sourceAddressPrefix = '*'; sourcePortRange = '*'; destinationAddressPrefixes = @('172.20.1.0/24'); destinationPortRange = '443'
        } })
    }
    $script:resources[$i.route] = Fixture $i.route '' @{
        routes = @(@{ name = 'firewall'; properties = @{ addressPrefix = '0.0.0.0/0'; nextHopType = 'VirtualAppliance'; nextHopIpAddress = '172.20.2.4' } })
    }
    $script:resources["$($i.apim)/backends"] = @{
        value = @(@{ name = 'model'; url = 'https://foundry.services.ai.azure.com/api/projects/demo?credential=DO-NOT-PRINT' })
    }
    $script:resources["$($i.pe)/privateDnsZoneGroups"] = @{
        value = @(@{ name = 'default'; properties = @{
            provisioningState = 'Succeeded'; privateDnsZoneConfigs = @(@{ properties = @{ privateDnsZoneId = $i.zone } })
        } })
    }
    $script:resources[$i.zone] = Fixture $i.zone 'Microsoft.Network/privateDnsZones' @{}
    $script:resources["$($i.zone)/A"] = @{
        value = @(@{ name = 'foundry'; properties = @{ aRecords = @(@{ ipv4Address = '172.20.1.4' }) } })
    }
    $script:resources["$($i.zone)/virtualNetworkLinks"] = @{
        value = @(@{ properties = @{
            virtualNetwork = @{ id = $i.vnet }; provisioningState = 'Succeeded'; virtualNetworkLinkState = 'Completed'
        } })
    }
    $global:CcofPrivatePathTest = @{ resources = $script:resources; ids = $script:ids; denied = ''; invalidJson = ''; pages = 0
        subscriptions = @(
            @{ id = '11111111-1111-1111-1111-111111111111'; name = 'Gateway Prod' }
            @{ id = '33333333-3333-3333-3333-333333333333'; name = 'Connectivity-DNS' }
        ) }
    $dnsZoneList = @{ value = @(
        @{ id = $script:ids.zone; name = 'privatelink.services.ai.azure.com' }
        @{ id = "$central/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"; name = 'privatelink.openai.azure.com' }
    ) }
    $script:resources['/subscriptions/33333333-3333-3333-3333-333333333333/providers/Microsoft.Network/privateDnsZones'] = $dnsZoneList
    $script:resources['/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/central-dns/providers/Microsoft.Network/privateDnsZones'] = $dnsZoneList
}
function global:az {
    $fixture = $global:CcofPrivatePathTest
    $argv = @($args)
    if ($argv[0] -eq 'account' -and $argv[1] -eq 'list') {
        $global:LASTEXITCODE = 0
        return ($fixture.subscriptions | ConvertTo-Json -Depth 5 -AsArray -Compress)
    }
    if ($argv[0] -ne 'rest' -or $argv[2] -ne 'get') { throw 'Checker attempted a non-GET Azure command.' }
    $url = $argv[[array]::IndexOf($argv, '--url') + 1]
    $id = ([uri]$url).AbsolutePath
    $subscription = $argv[[array]::IndexOf($argv, '--subscription') + 1]
    if ($argv -notcontains '--subscription' -or $subscription -ne ($id -split '/')[2]) {
        throw "Missing/wrong explicit subscription for $id"
    }
    $global:LASTEXITCODE = 0
    if ($id -eq $fixture.denied) {
        $global:LASTEXITCODE = 1
        "ERROR: (AuthorizationFailed) does not have authorization to perform action 'Microsoft.Network/privateDnsZones/A/read' over scope '$id' DO-NOT-PRINT"
        return
    }
    if ($id -eq $fixture.invalidJson) { 'not-json DO-NOT-PRINT'; return }
    if (-not $fixture.resources.ContainsKey($id)) { throw "Unexpected read: $id" }
    if ($id -eq "$($fixture.ids.apim)/backends" -and $argv -notcontains '--query') {
        throw 'Backend read must project URLs only.'
    }
    if ($url -match 'page=2') { $fixture.pages++ }
    $fixture.resources[$id] | ConvertTo-Json -Depth 30 -Compress
}
function Run-Case([string]$Name, [bool]$Fails, [string[]]$Contains, [hashtable]$Parameters = @{}, [int]$ExpectedExit = -1) {
    $global:LASTEXITCODE = 0
    $lines = @(& $checker -ApimResourceId $script:ids.apim -FoundryResourceId $script:ids.foundry @Parameters)
    $code = $LASTEXITCODE
    $text = $lines -join "`n"
    if (($code -ne 0) -ne $Fails) { throw "$Name unexpected exit=$code`n$text" }
    if ($ExpectedExit -ge 0 -and $code -ne $ExpectedExit) { throw "$Name unexpected exit=$code; expected $ExpectedExit`n$text" }
    if ($code -eq 2 -and $text.Contains('[FAIL]')) { throw "$Name misreported a permission gap as a static FAIL.`n$text" }
    foreach ($snippet in $Contains + @('[UNVERIFIED] Live APIM path', 'NOT proof of a working private path')) {
        if (-not $text.Contains($snippet)) { throw "$Name missing '$snippet'`n$text" }
    }
    if ($text.Contains('DO-NOT-PRINT')) { throw "$Name exposed a URL/diagnostic secret." }
    $script:cases++
    Write-Output "PASS: $Name"
}
try {
    New-Fixtures
    Run-Case 'Static configuration, cross-subscription PE/DNS and 172.20 private IP' $false @('[PASS] Private DNS A record', '[PASS] DNS visibility (static)', '[INFO] Route firewall', '[INFO] NSG allow-private')
    New-Fixtures
    $script:resources["$($ids.zone)/A"].value[0].properties.aRecords[0].ipv4Address = '20.1.2.3'
    Run-Case 'Public/wrong A record' $true @('[FAIL] Private DNS A record')
    New-Fixtures
    $script:resources[$ids.apim].properties.virtualNetworkConfiguration = $null
    Run-Case 'Inbound Private Link cannot replace outbound integration' $true @('APIM has no outbound VNet subnet')
    New-Fixtures
    $global:CcofPrivatePathTest.denied = "$($ids.zone)/A"
    Run-Case 'Central A-record permission failure is explicit and unverified' $true @('[UNVERIFIED] Central DNS access', 'AuthorizationFailed', "scope=$($ids.zone)/A", 'Microsoft.Network/privateDnsZones/A/read') -ExpectedExit 2
    New-Fixtures
    $global:CcofPrivatePathTest.denied = $ids.zone
    Run-Case 'Central zone permission denial is not a missing-zone failure' $true @('[UNVERIFIED] Central DNS access', "scope=$($ids.zone)") -ExpectedExit 2
    New-Fixtures
    $global:CcofPrivatePathTest.denied = "$($ids.zone)/virtualNetworkLinks"
    Run-Case 'Central VNet-link permission denial is not visibility success' $true @('[PASS] Private DNS A record', '[UNVERIFIED] Central DNS access', "scope=$($ids.zone)/virtualNetworkLinks") -ExpectedExit 2
    New-Fixtures
    $global:CcofPrivatePathTest.denied = "$($ids.pe)/privateDnsZoneGroups"
    Run-Case 'Explicit central zone array works without zone-group permission' $true @('[UNVERIFIED] PE DNS zone-group access', '[PASS] Private DNS A record') @{ PrivateDnsZoneIds = @($ids.zone, "$central/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com") } -ExpectedExit 2
    New-Fixtures
    $global:CcofPrivatePathTest.denied = "$($ids.pe)/privateDnsZoneGroups"
    Run-Case 'Unreadable zone group without explicit IDs stays unverified' $true @('[UNVERIFIED] Private DNS', 'Supply -PrivateDnsZoneIds') -ExpectedExit 2
    New-Fixtures
    $global:CcofPrivatePathTest.invalidJson = $ids.nic
    Run-Case 'Invalid CLI JSON is explicit and redacted' $true @('invalid JSON')
    New-Fixtures
    $global:CcofPrivatePathTest.denied = "$($ids.apim)/backends"
    Run-Case 'Non-DNS query failure remains explicit FAIL, not empty discovery' $true @('[FAIL] Check incomplete', 'Azure CLI GET denied', 'AuthorizationFailed') -ExpectedExit 1
    New-Fixtures
    $script:resources[$ids.vnet].properties.dhcpOptions.dnsServers = @('172.20.2.5')
    Run-Case 'Custom DNS with linked zone remains unverified' $false @('[WARN] DNS visibility', 'Customer DNS forwarding')
    New-Fixtures
    $script:resources["$($ids.zone)/virtualNetworkLinks"].value[0].properties.virtualNetwork.id = $ids.peVnet
    Run-Case 'Hub link alone does not propagate DNS visibility' $false @('[WARN] DNS visibility')
    New-Fixtures
    $script:resources[$ids.peVnet] = Fixture $ids.peVnet '' @{ dhcpOptions = @{ dnsServers = @() } }
    $script:resources[$ids.vnet].properties.dhcpOptions.dnsServers = @('172.20.2.5')
    $script:resources["$($ids.zone)/virtualNetworkLinks"].value[0].properties.virtualNetwork.id = $ids.peVnet
    Run-Case 'Explicit resolver hub and custom DNS are still not a resolution verdict' $false @('[WARN] DNS visibility', 'completedLink=True', 'Customer DNS forwarding') @{ DnsVnetResourceId = $ids.peVnet }
    New-Fixtures
    $script:resources[$ids.pe].properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status = 'Pending'
    Run-Case 'Unapproved Foundry connection' $true @('[FAIL] Foundry PE approval')
    New-Fixtures
    $script:resources[$ids.pe].properties.privateLinkServiceConnections[0].properties.privateLinkServiceId = "$($ids.foundry)-wrong"
    Run-Case 'PE must target the exact account' $true @('must target this exact Foundry account')
    New-Fixtures
    $script:resources[$ids.apim].sku.name = 'BasicV2'
    Run-Case 'Unsupported SKU is not a static pass' $true @('[FAIL] APIM SKU/mode')
    New-Fixtures
    $script:resources[$ids.pe].properties.manualPrivateLinkServiceConnections = $script:resources[$ids.pe].properties.privateLinkServiceConnections
    $script:resources[$ids.pe].properties.privateLinkServiceConnections = @()
    Run-Case 'Manual connection ARM response shape and explicit host' $false @('[PASS] Foundry PE approval') @{ BackendHost = 'foundry.services.ai.azure.com' }
    New-Fixtures
    $script:resources["$($ids.pe)/privateDnsZoneGroups"].value = @()
    Run-Case 'Central DNS zone array explicitly selected without zone group' $false @('[WARN] DNS zone group') @{ PrivateDnsZoneIds = @($ids.zone) }
    New-Fixtures
    $script:resources[$ids.apim].location = 'East US'
    Run-Case 'APIM display region is normalized against VNet region' $false @('[PASS] APIM delegation')
    New-Fixtures
    $script:resources["$($ids.zone)/A"].value = @()
    Run-Case 'Readable empty A-record list is a genuine static failure' $true @('[FAIL] Private DNS A record') -ExpectedExit 1
    New-Fixtures
    $script:resources["$($ids.vnet)/subnets/apim"].properties.delegations = @()
    Run-Case 'Missing v2 delegation is detected' $true @('[FAIL] APIM delegation')
    New-Fixtures
    $script:resources[$ids.nic].properties.ipConfigurations += @(@{ properties = @{
        privateIPAddress = '172.20.1.5'; privateLinkConnectionProperties = @{ fqdns = @('foundry.cognitiveservices.azure.com') }
    } })
    $script:resources["$($ids.zone)/A"].value[0].properties.aRecords[0].ipv4Address = '172.20.1.5'
    Run-Case 'Other hostname IP on the same PE is not an A-record match' $true @('[FAIL] Private DNS A record')
    New-Fixtures
    $cogZone = $ids.zone -replace 'services.ai.azure.com$', 'cognitiveservices.azure.com'
    $script:resources[$cogZone] = Fixture $cogZone 'Microsoft.Network/privateDnsZones' @{}
    $script:resources["$cogZone/A"] = $script:resources["$($ids.zone)/A"]
    $script:resources["$cogZone/virtualNetworkLinks"] = $script:resources["$($ids.zone)/virtualNetworkLinks"]
    $script:resources["$($ids.pe)/privateDnsZoneGroups"].value[0].properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId = $cogZone
    $script:resources[$ids.nic].properties.ipConfigurations[0].properties.privateLinkConnectionProperties.fqdns = @('foundry.cognitiveservices.azure.com')
    $script:resources[$ids.pe].properties.customDnsConfigs[0].fqdn = 'foundry.cognitiveservices.azure.com'
    Run-Case 'Cognitive Services hostname requires only its own central zone' $false @('expectedZone=privatelink.cognitiveservices.azure.com', '[PASS] Private DNS A record') @{ BackendHost = 'foundry.cognitiveservices.azure.com' }
    New-Fixtures
    $script:resources[$ids.pe].properties.subnet.id = "$($ids.peVnet)/subnets/pe"
    $script:resources["$($ids.peVnet)/subnets/pe"] = $script:resources["$($ids.vnet)/subnets/pe"]
    foreach ($pair in @(@($ids.vnet, $ids.peVnet), @($ids.peVnet, $ids.vnet))) {
        $script:resources["$($pair[0])/virtualNetworkPeerings"] = @{ value = @(@{ properties = @{
            remoteVirtualNetwork = @{ id = $pair[1] }; peeringState = 'Connected'; allowVirtualNetworkAccess = $true
        } }) }
    }
    Run-Case 'Direct peering must be connected in both directions' $false @('[PASS] Direct peering')
    $script:resources["$($ids.peVnet)/virtualNetworkPeerings"].value[0].properties.allowVirtualNetworkAccess = $false
    Run-Case 'One-way peering access is a static failure' $true @('[FAIL] Direct peering')
    New-Fixtures
    $script:resources["$($ids.zone)/A"] = @{ value = @(); nextLink = "https://management.azure.com$($ids.zone)/A-page?api-version=2024-06-01&page=2" }
    $script:resources["$($ids.zone)/A-page"] = @{ value = @(@{ name = 'foundry'; properties = @{ aRecords = @(@{ ipv4Address = '172.20.1.4' }) } }) }
    Run-Case 'Paginated ARM list reads the second page' $false @('[PASS] Private DNS A record')
    if ($global:CcofPrivatePathTest.pages -ne 1) { throw 'Second ARM page was not queried.' }
    $subList = '/subscriptions/33333333-3333-3333-3333-333333333333/providers/Microsoft.Network/privateDnsZones'
    New-Fixtures
    $script:resources["$($ids.pe)/privateDnsZoneGroups"].value = @()
    Run-Case 'DNS subscription by display name finds the central zone' $false @("'Connectivity-DNS' = 33333333-3333-3333-3333-333333333333", 'found 1', '[PASS] Private DNS A record') @{ DnsSubscription = 'connectivity-dns' }
    New-Fixtures
    $script:resources["$($ids.pe)/privateDnsZoneGroups"].value = @()
    Run-Case 'DNS subscription plus resource group narrows discovery' $false @('resourceGroups/central-dns', '[PASS] Private DNS A record') @{ DnsSubscription = '33333333-3333-3333-3333-333333333333'; DnsResourceGroup = 'central-dns' }
    New-Fixtures
    $global:CcofPrivatePathTest.subscriptions += @{ id = '44444444-4444-4444-4444-444444444444'; name = 'Connectivity-DNS' }
    Run-Case 'Ambiguous DNS subscription name asks for the GUID' $true @('Pass the GUID instead') @{ DnsSubscription = 'Connectivity-DNS' } -ExpectedExit 1
    New-Fixtures
    Run-Case 'Unknown DNS subscription name is explicit' $true @('not visible to this login') @{ DnsSubscription = 'No-Such-Sub' } -ExpectedExit 1
    New-Fixtures
    $global:CcofPrivatePathTest.denied = $subList
    Run-Case 'Denied DNS subscription listing is unverified, zone group still used' $true @('[UNVERIFIED] Central DNS access', '[PASS] Private DNS A record') @{ DnsSubscription = 'Connectivity-DNS' } -ExpectedExit 2
    New-Fixtures
    $script:resources[$subList] = @{ value = @() }
    $script:resources["$($ids.pe)/privateDnsZoneGroups"].value = @()
    Run-Case 'Zone absent from named DNS subscription fails' $true @('[FAIL] Private DNS zone') @{ DnsSubscription = 'Connectivity-DNS' } -ExpectedExit 1
    Write-Output "$script:cases offline cases passed. No Azure calls made."
} finally {
    Remove-Item Function:\az
    Remove-Variable CcofPrivatePathTest -Scope Global
}
