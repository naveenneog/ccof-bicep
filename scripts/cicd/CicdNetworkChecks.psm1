# Read-only network prerequisite checks (subnets, delegations, sizes, NSGs, private DNS zones and links,
# VNet peering) for docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md. Uses CicdChecks.psm1 for every Azure read.
Set-StrictMode -Version Latest

$script:NetSource = 'docs/runbooks/CICD-NETWORK-ENTRA-CHECKLIST.md'
$script:Rules = @{
    functions        = @{ delegation = 'Microsoft.App/environments'; maxPrefix = 27; nsg = $false; ref = 'https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#virtual-network-integration' }
    apim             = @{ delegation = 'Microsoft.Web/serverFarms'; maxPrefix = 27; nsg = $true; ref = 'https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound' }
    privateEndpoints = @{ delegation = ''; maxPrefix = 28; nsg = $false; ref = 'https://learn.microsoft.com/azure/private-link/private-endpoint-overview' }
}

function Get-CicdIdPart { param([string]$Id, [string]$Name)
    $parts = $Id.Trim('/') -split '/'
    for ($i = 0; $i -lt $parts.Count - 1; $i++) { if ($parts[$i] -ieq $Name) { return $parts[$i + 1] } }
    return $null
}

# One subnet: exists, delegated as the role needs, prefix length at most the limit, NSG where required.
function Test-CicdSubnet {
    param([string]$Role, [string]$SubnetId, [string]$Label)
    $rule = $script:Rules[$Role]
    $id = "network.subnet.$Label.$Role"
    if (-not $SubnetId) { return @(New-CicdCheck $id 'network' "Subnet $Label/$Role" 'fail' 'subnet ID not configured' $script:NetSource) }
    $r = Invoke-CicdArmGet $SubnetId '2024-05-01'
    if (-not $r.Ok) { return @(New-CicdCheck $id 'network' "Subnet $Label/$Role" $(if (Test-CicdDenied $r.Error) { 'manual' } else { 'fail' }) "$SubnetId : $(Get-CicdAzReason $r.Error)" $script:NetSource) }
    $p = $r.Data.properties
    $prefix = [string](@(Get-CicdValue $p 'addressPrefix') + @(Get-CicdValue $p 'addressPrefixes') | Where-Object { $_ } | Select-Object -First 1)
    $len = if ($prefix -match '/(\d+)$') { [int]$Matches[1] } else { 99 }
    $delegations = @(@(Get-CicdValue $p 'delegations') | Where-Object { $_ } | ForEach-Object { [string](Get-CicdValue $_ 'properties.serviceName') })
    $nsg = [string](Get-CicdValue $p 'networkSecurityGroup.id')
    $problems = [Collections.Generic.List[string]]::new()
    if ($rule.delegation -and $delegations -notcontains $rule.delegation) { $problems.Add("delegation $($rule.delegation) missing (has: $(if ($delegations) { $delegations -join ',' } else { 'none' }))") }
    if (-not $rule.delegation -and $delegations.Count) { $problems.Add("must not be delegated (has $($delegations -join ','))") }
    if ($len -gt $rule.maxPrefix) { $problems.Add("prefix $prefix smaller than /$($rule.maxPrefix)") }
    if ($rule.nsg -and -not $nsg) { $problems.Add('no network security group attached') }
    $ev = "$prefix; delegation $(if ($delegations) { $delegations -join ',' } else { 'none' }); NSG $(if ($nsg) { ($nsg -split '/')[-1] } else { 'none' })"
    $status = if ($problems.Count) { 'fail' } else { 'pass' }
    return @(New-CicdCheck $id 'network' "Subnet $Label/$Role ($(($SubnetId -split '/')[-1]))" $status $(if ($problems.Count) { "$($problems -join '; '). Found: $ev" } else { $ev }) "$script:NetSource; $($rule.ref)")
}

# Each private DNS zone exists and has a virtual network link to every listed VNet.
function Test-CicdDnsZones {
    param([string[]]$ZoneIds, [string[]]$VnetIds)
    $out = [Collections.Generic.List[object]]::new()
    foreach ($zone in $ZoneIds) {
        $name = ($zone -split '/')[-1]
        $r = Invoke-CicdArmGet "$zone/virtualNetworkLinks" '2024-06-01'
        if (-not $r.Ok) { $out.Add((New-CicdCheck "network.dns.$name" 'network' "Private DNS zone $name" $(if (Test-CicdDenied $r.Error) { 'manual' } else { 'fail' }) "$zone : $(Get-CicdAzReason $r.Error)" "$script:NetSource; https://learn.microsoft.com/azure/private-link/private-endpoint-dns")); continue }
        $linked = @(@($r.Data.value) | Where-Object { $_ } | ForEach-Object { ([string](Get-CicdValue $_ 'properties.virtualNetwork.id')).ToLowerInvariant() })
        $missing = @($VnetIds | Where-Object { $_ -and $linked -notcontains $_.ToLowerInvariant() } | ForEach-Object { ($_ -split '/')[-1] })
        $out.Add((New-CicdCheck "network.dns.$name" 'network' "Private DNS zone $name linked to every VNet" $(if ($missing.Count) { 'fail' } else { 'pass' }) $(if ($missing.Count) { "no link to $($missing -join ', '); $($linked.Count) link(s) present" } else { "linked to $(@($VnetIds | ForEach-Object { ($_ -split '/')[-1] }) -join ', ')" }) "$script:NetSource; https://learn.microsoft.com/azure/private-link/private-endpoint-dns"))
    }
    return $out.ToArray()
}

# Peering between region A and region B VNets, both directions. A missing peering is "manual" when the DR
# prerequisites Bootstrap creates it (primary.peer true), else "fail".
function Test-CicdPeering {
    param([string]$VnetA, [string]$VnetB, [bool]$BootstrapCreates)
    $out = [Collections.Generic.List[object]]::new()
    foreach ($pair in @(@($VnetA, $VnetB), @($VnetB, $VnetA))) {
        $from = ($pair[0] -split '/')[-1]; $to = ($pair[1] -split '/')[-1]
        $r = Invoke-CicdArmGet "$($pair[0])/virtualNetworkPeerings" '2024-05-01'
        $id = "network.peering.$from"
        if (-not $r.Ok) { $out.Add((New-CicdCheck $id 'network' "Peering $from -> $to" $(if (Test-CicdDenied $r.Error) { 'manual' } else { 'fail' }) (Get-CicdAzReason $r.Error) $script:NetSource)); continue }
        $peer = @(@($r.Data.value) | Where-Object { $_ -and ([string](Get-CicdValue $_ 'properties.remoteVirtualNetwork.id')) -ieq $pair[1] }) | Select-Object -First 1
        if (-not $peer) {
            $out.Add((New-CicdCheck $id 'network' "Peering $from -> $to" $(if ($BootstrapCreates) { 'manual' } else { 'fail' }) $(if ($BootstrapCreates) { 'absent; DR prerequisites Bootstrap creates it (primary.peer true) after gate network' } else { 'absent; the network team creates it' }) "$script:NetSource; infra/dr/Invoke-DrPrerequisites.ps1"))
            continue
        }
        $state = [string](Get-CicdValue $peer 'properties.peeringState')
        $out.Add((New-CicdCheck $id 'network' "Peering $from -> $to" $(if ($state -ceq 'Connected') { 'pass' } else { 'fail' }) "$($peer.name) peeringState $state" $script:NetSource))
    }
    return $out.ToArray()
}

# All network checks from the staged config (region A) and the DR config (region B).
function Test-CicdNetwork {
    param($Staged, $Dr)
    $out = [Collections.Generic.List[object]]::new()
    $mode = [string](Get-CicdValue $Staged 'network.mode')
    $e = Get-CicdValue $Staged 'network.existing'
    if ($mode -ceq 'create') {
        $out.Add((New-CicdCheck 'network.mode' 'network' 'Region A network mode' 'manual' 'network.mode create: Stage 6 creates the VNet; a customer network team normally owns the network (use existing or verify)' 'docs/runbooks/STAGED-CUSTOMER-DEPLOYMENT.md'))
    } else {
        $out.Add((New-CicdCheck 'network.mode' 'network' 'Region A network mode' 'pass' "network.mode $(if ($mode) { $mode } else { 'verify (default)' }): the pipeline creates no VNet, subnet, NSG or DNS zone in region A" 'docs/runbooks/STAGED-CUSTOMER-DEPLOYMENT.md'))
        foreach ($c in (Test-CicdSubnet 'functions' ([string](Get-CicdValue $e 'functionsSubnetId')) 'A')) { $out.Add($c) }
        foreach ($c in (Test-CicdSubnet 'privateEndpoints' ([string](Get-CicdValue $e 'privateEndpointSubnetId')) 'A')) { $out.Add($c) }
        if (Get-CicdValue $e 'apimSubnetId') { foreach ($c in (Test-CicdSubnet 'apim' ([string](Get-CicdValue $e 'apimSubnetId')) 'A')) { $out.Add($c) } }
    }
    $vnetA = if ($Dr) { [string](Get-CicdValue $Dr 'primary.vnetId') } else { '' }
    if (-not $vnetA -and $e) { $sn = [string](Get-CicdValue $e 'functionsSubnetId'); if ($sn -match '^(.+/virtualNetworks/[^/]+)/subnets/') { $vnetA = $Matches[1] } }
    $vnetB = if ($Dr) { [string](Get-CicdValue $Dr 'secondary.existingVnetId') } else { '' }
    if ($Dr) {
        $sec = Get-CicdValue $Dr 'secondary'
        if ([string](Get-CicdValue $sec 'networkMode') -ceq 'existing' -and $vnetB) {
            foreach ($role in 'apim', 'functions', 'privateEndpoints') {
                $name = [string](Get-CicdValue $sec "subnets.$role.name")
                foreach ($c in (Test-CicdSubnet $role "$vnetB/subnets/$name" 'B')) { $out.Add($c) }
            }
        } else {
            $out.Add((New-CicdCheck 'network.mode.B' 'network' 'Region B network mode' 'manual' "secondary.networkMode $([string](Get-CicdValue $sec 'networkMode')): DR prerequisites Bootstrap creates the region B VNet; confirm the address space with the network team" 'docs/runbooks/DR-STANDBY-CLOUD-SHELL.md'))
        }
    }
    $vnets = @($vnetA, $vnetB | Where-Object { $_ })
    $zoneIds = [Collections.Generic.List[string]]::new()
    $dz = Get-CicdValue $Staged 'network.existing.privateDnsZoneIds'
    if ($dz -is [Collections.IDictionary]) { foreach ($v in $dz.Values) { if ($v) { $zoneIds.Add([string]$v) } } }
    if ($Dr -and (Get-CicdValue $Dr 'dnsZones')) {
        $z = Get-CicdValue $Dr 'dnsZones'
        foreach ($n in @(Get-CicdValue $z 'zoneNames')) { $zid = "/subscriptions/$($z.subscriptionId)/resourceGroups/$($z.resourceGroup)/providers/Microsoft.Network/privateDnsZones/$n"; if ($zoneIds -inotcontains $zid) { $zoneIds.Add($zid) } }
    }
    if ($zoneIds.Count) { foreach ($c in (Test-CicdDnsZones $zoneIds.ToArray() $vnets)) { $out.Add($c) } }
    else { $out.Add((New-CicdCheck 'network.dns' 'network' 'Private DNS zones' 'manual' 'no zone IDs configured; confirm privatelink.documents.azure.com and privatelink.blob.core.windows.net are linked to both VNets' $script:NetSource)) }
    $out.Add((New-CicdCheck 'network.dns.sites' 'network' 'privatelink.azurewebsites.net for Function App private endpoints' 'manual' 'the network team creates the Function App private endpoints and DNS records in region B (DR runbook 7.4) after the DR Network phase' 'docs/runbooks/DR-STANDBY-CLOUD-SHELL.md'))
    if ($vnetA -and $vnetB) { foreach ($c in (Test-CicdPeering $vnetA $vnetB ([bool](Get-CicdValue $Dr 'primary.peer')))) { $out.Add($c) } }
    return $out.ToArray()
}

Export-ModuleMember -Function Get-CicdIdPart, Test-CicdSubnet, Test-CicdDnsZones, Test-CicdPeering, Test-CicdNetwork
