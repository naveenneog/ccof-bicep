#Requires -Version 7.0
<#
.SYNOPSIS
Read-only APIM-to-Foundry private-path configuration check (not a traffic test).
.DESCRIPTION
Uses Azure CLI management-plane GETs only. Requires Reader access to the named
resources, their subnets, peerings, NICs, NSGs, routes and private DNS resources.
Exit 1 means a static failure or failed query, 2 a DNS permission gap.
Exit 0 does NOT prove connectivity.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApimResourceId,
    [Parameter(Mandatory)][string]$FoundryResourceId,
    [string]$BackendHost,
    [string]$PrivateEndpointId,
    [Alias('PrivateDnsZoneId')][string[]]$PrivateDnsZoneIds = @(),
    [string]$DnsVnetResourceId
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$script:failures = 0
$script:permissionGaps = 0
function Report([string]$State, [string]$Check, [string]$Detail) {
    if ($State -eq 'FAIL') { $script:failures++ }
    Write-Output "[$State] ${Check}: $Detail"
}
function Read-Arm([string]$Id, [string]$Version = '2024-05-01', [string]$Query) {
    if ($Id -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/[^/]+/.+') {
        throw "Expected a full ARM resource ID: $Id"
    }
    $url = "https://management.azure.com${Id}?api-version=$Version"
    do {
        $cli = @('rest', '--method', 'get', '--url', $url, '--subscription', ($Id -split '/')[2], '--only-show-errors', '--output', 'json')
        if ($Query) { $cli += @('--query', $Query) }
        $raw = @(& az @cli 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $code = [regex]::Match(($raw -join ' '), 'LinkedAuthorizationFailed|AuthorizationFailed|AuthorizationPermissionMismatch|Authorization_RequestDenied|AccessDenied|Forbidden|ResourceNotFound|InvalidApiVersionParameter|AuthenticationFailed|ExpiredAuthenticationToken|SubscriptionNotFound').Value
            if ($code -in @('LinkedAuthorizationFailed', 'AuthorizationFailed', 'AuthorizationPermissionMismatch', 'Authorization_RequestDenied', 'AccessDenied', 'Forbidden')) {
                $action = [regex]::Match(($raw -join ' '), "perform action '(Microsoft\.[a-zA-Z0-9./]+)'").Groups[1].Value
                throw [UnauthorizedAccessException]::new("Azure CLI GET denied (exit=$LASTEXITCODE; code=$code; action=$action); scope=$Id. Reader access is required at this scope (raw diagnostics withheld).")
            }
            throw "Azure CLI GET failed (exit=$LASTEXITCODE; code=$code) for $Id. Check login, Reader access and ID/API version. Raw diagnostics withheld to avoid leaking secrets."
        }
        try { $data = ($raw -join "`n") | ConvertFrom-Json -Depth 100 }
        catch { throw "Azure CLI returned invalid JSON for $Id (response withheld)." }
        if ($null -eq $data) { throw "Azure CLI returned no JSON for $Id." }
        if ($data.PSObject.Properties.Name -contains 'value') {
            $data.value
            $url = $data.nextLink
            if ($url -and $url -notlike 'https://management.azure.com/*') { throw 'Unexpected ARM pagination host.' }
        } else { $data; $url = $null }
    } while ($url)
}
function Vnet-Id([string]$SubnetId) {
    if ($SubnetId -notmatch '^(.+)/subnets/[^/]+$') { throw "Invalid subnet ID: $SubnetId" }
    $Matches[1]
}
function Check-State($Resource, [string]$Label) {
    $state = $Resource.properties.provisioningState
    Report $(if ($state -eq 'Succeeded') { 'PASS' } else { 'FAIL' }) $Label "provisioningState=$state"
}
function Check-Subnet($Subnet, [string]$Label) {
    $p = $Subnet.properties
    Report 'INFO' $Label "id=$($Subnet.id); prefixes=$(@($p.addressPrefix) + @($p.addressPrefixes) -join ','); privateEndpointNetworkPolicies=$($p.privateEndpointNetworkPolicies)"
    if ($p.networkSecurityGroup.id) {
        $nsg = Read-Arm $p.networkSecurityGroup.id
        Report 'INFO' "$Label NSG" $nsg.id
        foreach ($rule in @($nsg.properties.securityRules) + @($nsg.properties.defaultSecurityRules) | Where-Object { $_ }) {
            $r = $rule.properties
            Report 'INFO' "NSG $($rule.name)" "priority=$($r.priority); $($r.direction) $($r.access) $($r.protocol); source=$(@($r.sourceAddressPrefix) + @($r.sourceAddressPrefixes) -join ','); sourcePorts=$(@($r.sourcePortRange) + @($r.sourcePortRanges) -join ','); destination=$(@($r.destinationAddressPrefix) + @($r.destinationAddressPrefixes) -join ','); ports=$(@($r.destinationPortRange) + @($r.destinationPortRanges) -join ',')"
        }
    } else { Report 'WARN' "$Label NSG" 'No NSG attached (required for APIM v2).' }
    if ($p.routeTable.id) {
        $table = Read-Arm $p.routeTable.id
        Report 'INFO' "$Label UDR" "id=$($table.id); disableBgpRoutePropagation=$($table.properties.disableBgpRoutePropagation)"
        foreach ($route in $table.properties.routes) {
            $r = $route.properties
            Report 'INFO' "Route $($route.name)" "$($r.addressPrefix) -> $($r.nextHopType) $($r.nextHopIpAddress)"
        }
    } else { Report 'INFO' "$Label UDR" 'No subnet route table attached; system/BGP/effective routes not inspected.' }
}

try {
    $apim = Read-Arm $ApimResourceId '2024-05-01'
    $foundry = Read-Arm $FoundryResourceId '2025-06-01'
    if ($apim.type -ine 'Microsoft.ApiManagement/service' -or $foundry.type -ine 'Microsoft.CognitiveServices/accounts') {
        throw 'Expected an APIM service ID and a Foundry Cognitive Services account ID (not a project ID).'
    }
    Check-State $apim 'APIM'
    Check-State $foundry 'Foundry'
    Report 'INFO' 'Foundry' "id=$FoundryResourceId; publicNetworkAccess=$($foundry.properties.publicNetworkAccess)"
    if ($foundry.properties.publicNetworkAccess -eq 'Enabled') {
        Report 'WARN' 'Foundry public access' 'Enabled: a successful model call could still use the public path.'
    }
    $sku = $apim.sku.name
    $mode = $apim.properties.virtualNetworkType
    $subnetId = $apim.properties.virtualNetworkConfiguration.subnetResourceId
    Report 'INFO' 'APIM networking' "SKU=$sku; virtualNetworkType=$mode; outboundSubnet=$subnetId"
    Report 'INFO' 'APIM inbound private endpoint' 'Inbound Private Link is NOT outbound VNet integration and cannot reach a private Foundry backend by itself.'
    $v2 = $sku -in @('StandardV2', 'PremiumV2')
    $classic = $sku -in @('Developer', 'Premium') -and $mode -in @('Internal', 'External')
    if (-not ($v2 -or $classic)) {
        Report 'FAIL' 'APIM SKU/mode' 'Recommended outbound integration requires StandardV2/PremiumV2; classic Developer/Premium require VNet injection.'
    }
    if (-not $subnetId) { throw 'APIM has no outbound VNet subnet. An inbound private endpoint does not provide this path.' }
    $subnet = Read-Arm $subnetId
    $apimVnetId = Vnet-Id $subnetId
    $apimVnet = Read-Arm $apimVnetId
    $delegations = @($subnet.properties.delegations | ForEach-Object { $_.properties.serviceName })
    $wanted = if ($sku -eq 'PremiumV2' -and $mode -eq 'Internal') { 'Microsoft.Web/hostingEnvironments' } elseif ($v2) { 'Microsoft.Web/serverFarms' } else { '' }
    $delegated = if ($wanted) { $delegations.Count -eq 1 -and $delegations[0] -ieq $wanted } else { $delegations.Count -eq 0 }
    Report $(if ($delegated) { 'PASS' } else { 'FAIL' }) 'APIM delegation' "actual=$($delegations -join ','); expected=$(if ($wanted) {$wanted} else {'none (classic injection)'})"
    if ($v2 -and -not $subnet.properties.networkSecurityGroup.id) { Report 'FAIL' 'APIM v2 NSG' 'The outbound subnet requires an NSG.' }
    if ($v2 -and (($apimVnetId -split '/')[2] -ine ($ApimResourceId -split '/')[2] -or
        ($apim.location -replace '[^a-zA-Z0-9]', '') -ine ($apimVnet.location -replace '[^a-zA-Z0-9]', ''))) {
        Report 'FAIL' 'APIM VNet location' 'APIM v2 integration requires the same subscription and region.'
    }
    Check-Subnet $subnet 'APIM subnet'
    if (-not $BackendHost) {
        # Project URLs only: never return backend credentials, headers or certificates.
        $backends = @(Read-Arm "$ApimResourceId/backends" '2024-05-01' '{value: value[].{name:name,url:properties.url}, nextLink:nextLink}')
        $hosts = @($backends | ForEach-Object {
            $uri = $null
            if ([uri]::TryCreate($_.url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https') { $uri.DnsSafeHost }
        } | Where-Object { $_ -match '\.(services\.ai|cognitiveservices|openai)\.azure\.com$' } | Sort-Object -Unique)
        $account = $foundry.properties.customSubDomainName
        if ($account) { $hosts = @($hosts | Where-Object { ($_ -split '\.')[0] -ieq $account }) }
        if ($hosts.Count -ne 1) { throw "Found $($hosts.Count) candidate Foundry backend hosts. Supply -BackendHost with the actual hostname used by the APIM policy/backend." }
        $BackendHost = $hosts[0]
        Report 'WARN' 'Backend discovery' 'Host from APIM backend URL; per-API policies, literal set-backend-service URLs and runtime overrides are not inspected.'
    }
    if ($BackendHost -notmatch '^(?<record>[^/:\s]+)\.(?<suffix>services\.ai\.azure\.com|cognitiveservices\.azure\.com|openai\.azure\.com)$' -or $BackendHost -match '\.privatelink\.') {
        throw 'BackendHost must be the public-form Foundry hostname only (no scheme/path), using services.ai.azure.com, cognitiveservices.azure.com or openai.azure.com.'
    }
    $recordName = $Matches.record
    $zoneName = "privatelink.$($Matches.suffix)"
    Report 'INFO' 'Backend DNS' "host=$BackendHost; expectedZone=$zoneName; A record=$recordName"
    if ($foundry.properties.customSubDomainName -and $recordName -ine $foundry.properties.customSubDomainName) {
        Report 'FAIL' 'Backend account' 'Backend host does not match the selected Foundry account custom subdomain.'
    }
    if (-not $PrivateEndpointId) {
        $ids = @($foundry.properties.privateEndpointConnections | ForEach-Object { $_.properties.privateEndpoint.id } | Where-Object { $_ } | Sort-Object -Unique)
        if ($ids.Count -ne 1) { throw "Found $($ids.Count) Foundry private endpoints. Supply -PrivateEndpointId to select the intended path. IDs: $($ids -join ', ')" }
        $PrivateEndpointId = $ids[0]
    }
    $pe = Read-Arm $PrivateEndpointId
    $connections = @(@($pe.properties.privateLinkServiceConnections) + @($pe.properties.manualPrivateLinkServiceConnections) | Where-Object {
        $_.properties.privateLinkServiceId -ieq $FoundryResourceId -and $_.properties.groupIds -contains 'account'
    })
    if ($connections.Count -ne 1) { throw 'Private endpoint must target this exact Foundry account ID and account subresource.' }
    Check-State $pe 'Foundry private endpoint'
    Check-State $connections[0] 'Foundry PE connection'
    $approval = $connections[0].properties.privateLinkServiceConnectionState.status
    Report $(if ($approval -eq 'Approved') { 'PASS' } else { 'FAIL' }) 'Foundry PE approval' "target=$FoundryResourceId; group=account; status=$approval"
    $peSubnetId = $pe.properties.subnet.id
    $peSubnet = Read-Arm $peSubnetId
    $peVnetId = Vnet-Id $peSubnetId
    if ($peSubnetId -ieq $subnetId -or @($peSubnet.properties.delegations).Count) { Report 'FAIL' 'PE subnet' 'PE must use a separate, undelegated subnet.' }
    Check-Subnet $peSubnet 'PE subnet'
    if ($apimVnetId -ieq $peVnetId) { Report 'PASS' 'VNet topology' 'APIM integration and Foundry PE are in the same VNet.' }
    else {
        foreach ($direction in @(@($apimVnetId, $peVnetId), @($peVnetId, $apimVnetId))) {
            $peerings = @(Read-Arm "$($direction[0])/virtualNetworkPeerings")
            $match = @($peerings | Where-Object { $_.properties.remoteVirtualNetwork.id -ieq $direction[1] })
            $ok = @($match | Where-Object { $_.properties.peeringState -eq 'Connected' -and $_.properties.allowVirtualNetworkAccess -eq $true }).Count -gt 0
            Report $(if ($ok) { 'PASS' } else { 'FAIL' }) 'Direct peering' "$($direction[0]) -> $($direction[1]); connected/accessAllowed=$ok. Routed hub/NVA alternatives are outside this direct-path check."
        }
    }
    $ips = @()
    $hostIps = @()
    $advertisedHosts = @()
    foreach ($nicRef in $pe.properties.networkInterfaces) {
        $nic = Read-Arm $nicRef.id
        foreach ($ip in $nic.properties.ipConfigurations) {
            $ips += $ip.properties.privateIPAddress
            $fqdns = @($ip.properties.privateLinkConnectionProperties.fqdns)
            $advertisedHosts += $fqdns
            Report 'INFO' 'PE NIC' "IP=$($ip.properties.privateIPAddress); FQDNs=$($fqdns -join ',')"
            if ($fqdns -icontains $BackendHost) { $hostIps += $ip.properties.privateIPAddress }
        }
    }
    foreach ($dns in $pe.properties.customDnsConfigs) {
        $advertisedHosts += $dns.fqdn
        Report 'INFO' 'PE DNS metadata' "FQDN=$($dns.fqdn); IPs=$($dns.ipAddresses -join ',')"
        if ($dns.fqdn -ieq $BackendHost) { $hostIps += @($dns.ipAddresses) }
    }
    $ips = @($ips | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $ips.Count) { throw 'No private endpoint NIC IPs were returned.' }
    if (@($advertisedHosts | Where-Object { $_ }).Count -and $advertisedHosts -inotcontains $BackendHost) {
        Report 'FAIL' 'PE backend hostname' 'The selected PE advertises other hostnames, not this backend hostname.'
    }
    $expectedIps = @($hostIps | Where-Object { $_ -in $ips } | Sort-Object -Unique)
    if (-not $expectedIps.Count) {
        $expectedIps = $ips
        Report 'WARN' 'PE hostname/IP mapping' 'No hostname-specific NIC/DNS metadata; comparing against all IPs of the selected PE only.'
    }
    $groupsReadable = $true
    try { $groups = @(Read-Arm "$PrivateEndpointId/privateDnsZoneGroups") }
    catch [UnauthorizedAccessException] {
        $script:permissionGaps++
        Report 'UNVERIFIED' 'PE DNS zone-group access' $_.Exception.Message
        $groupsReadable = $false
        $groups = @()
    }
    foreach ($group in $groups) {
        Check-State $group 'PE DNS zone group'
        Report 'INFO' 'PE DNS zone group' "name=$($group.name)"
    }
    $attached = @($groups | ForEach-Object { $_.properties.privateDnsZoneConfigs } |
        ForEach-Object { $_.properties.privateDnsZoneId } | Where-Object { $_ -like '/subscriptions/*' })
    Report 'INFO' 'Attached private DNS zones' ($attached -join ', ')
    if ($PrivateDnsZoneIds.Count) {
        $candidates = @($PrivateDnsZoneIds | Where-Object { ($_ -split '/')[-1] -ieq $zoneName } | Sort-Object -Unique)
    } else {
        $candidates = @($attached | Where-Object { ($_ -split '/')[-1] -ieq $zoneName } | Sort-Object -Unique)
    }
    if (-not $candidates.Count) {
        if ($groupsReadable -or $PrivateDnsZoneIds.Count) {
            throw "No $zoneName zone ID identified. Supply -PrivateDnsZoneIds with the central DNS subscription's full zone IDs; no workload-subscription DNS discovery is assumed."
        }
        Report 'UNVERIFIED' 'Private DNS' 'Zone groups unreadable and no matching explicit zone IDs. Supply -PrivateDnsZoneIds from central DNS administrators.'
    }
    if ($candidates.Count -gt 1) { Report 'WARN' 'Private DNS candidates' 'Multiple zones with the backend suffix; use explicit IDs to select the intended resolver path. Each zone is checked separately.' }
    foreach ($zoneId in $candidates) {
        if ($groupsReadable -and $zoneId -notin $attached) { Report 'WARN' 'DNS zone group' 'Selected zone is not attached to the PE; manual record lifecycle is unverified.' }
        try {
            $zone = Read-Arm $zoneId '2024-06-01'
            if ($zone.name -ine $zoneName) { throw "Selected zone must be $zoneName for backend $BackendHost." }
            $records = @(Read-Arm "$zoneId/A" '2024-06-01')
            $a = @($records | Where-Object { $_.name -ieq $recordName })
            $actualIps = @($a | ForEach-Object { $_.properties.aRecords } | ForEach-Object { $_.ipv4Address } | Sort-Object -Unique)
            $correct = $actualIps.Count -gt 0 -and @($actualIps | Where-Object { $_ -notin $expectedIps }).Count -eq 0
            Report $(if ($correct) { 'PASS' } else { 'FAIL' }) 'Private DNS A record' "zone=$zoneId; name=$recordName; actual=$($actualIps -join ','); selectedPE=$($expectedIps -join ','). Public/stale/other-PE IPs must not appear."
            $links = @(Read-Arm "$zoneId/virtualNetworkLinks" '2024-06-01')
            foreach ($link in $links) {
                Report 'INFO' 'DNS VNet link' "VNet=$($link.properties.virtualNetwork.id); state=$($link.properties.virtualNetworkLinkState); provisioning=$($link.properties.provisioningState); resolutionPolicy=$($link.properties.resolutionPolicy)"
            }
            $dnsVnet = if ($DnsVnetResourceId) { Read-Arm $DnsVnetResourceId } else { $apimVnet }
            $dnsServers = @($apimVnet.properties.dhcpOptions.dnsServers)
            $linked = @($links | Where-Object {
                $_.properties.virtualNetwork.id -ieq $dnsVnet.id -and $_.properties.provisioningState -eq 'Succeeded' -and $_.properties.virtualNetworkLinkState -eq 'Completed'
            }).Count -gt 0
            if ($linked -and -not $dnsServers.Count -and $dnsVnet.id -ieq $apimVnetId) {
                Report 'PASS' 'DNS visibility (static)' 'Expected zone has a completed direct APIM VNet link; VNet uses Azure-provided DNS.'
            } else {
                Report 'WARN' 'DNS visibility' "selectedDnsVnet=$($dnsVnet.id); completedLink=$linked; APIM customDnsServers=$($dnsServers -join ','). Hub links/peering alone do not provide DNS visibility. Customer DNS forwarding, Private Resolver/rulesets and APIM cached DNS are UNVERIFIED."
            }
        } catch [UnauthorizedAccessException] {
            $script:permissionGaps++
            Report 'UNVERIFIED' 'Central DNS access' $_.Exception.Message
        }
    }
} catch {
    Report 'FAIL' 'Check incomplete' $_.Exception.Message
}
Report 'UNVERIFIED' 'Live APIM path' 'Management-plane checks do not test APIM DNS resolution, TCP 443/TLS or a model call. Even VNet-connected Cloud Shell is not a live APIM gateway probe.'
Report 'UNVERIFIED' 'Effective traffic controls' 'Review both subnet NSGs, effective routes/BGP, firewall/NVA policy and return path for PE IP TCP 443, DNS UDP/TCP 53, and APIM dependencies (including Key Vault 443). Config presence is not an allow verdict.'
Report 'INFO' 'Interpretation' 'A policy may wrap upstream 401/403 as 502; that message alone does not diagnose credentials. Test the actual APIM backend request separately without exposing tokens.'
Write-Output "Static failures: $script:failures; DNS permission gaps: $script:permissionGaps. Read-only: nothing changed. Zero failures is NOT proof of a working private path."
if ($script:failures) { exit 1 }
if ($script:permissionGaps) { exit 2 }
exit 0
