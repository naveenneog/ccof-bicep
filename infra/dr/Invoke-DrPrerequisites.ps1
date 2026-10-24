<#
.SYNOPSIS
  DR prerequisites for the standby region (ADR 0034, docs/design/DR-IMPLEMENTATION.md stages P0-P2).

.DESCRIPTION
  -Phase Discover   Read-only (P0). Checks the signed-in tenant and subscription, resource providers and
                    secondary-region availability, the primary VNet address space against the proposed
                    secondary CIDRs, the private DNS zones to link, Foundry deployments of every listed
                    account and the Entra app registrations. Any denial or mismatch is a blocker.
  -Phase Bootstrap  P1/P2: deploys infra/dr/dr-prerequisites.bicep (secondary VNet and subnets, links to
                    the existing private DNS zones, optional peering, user-assigned identity shells).
                    Without -Apply it runs what-if only.
  -Phase Verify     Reads back what Bootstrap created and checks it against the configuration.

  Every phase writes evidence JSON to -EvidenceDirectory. Use an isolated AZURE_CONFIG_DIR signed in to
  the target tenant; the script never signs in or changes the default account.

.EXAMPLE
  $env:AZURE_CONFIG_DIR = '<isolated profile>'
  pwsh -NoProfile -File infra/dr/Invoke-DrPrerequisites.ps1 -Phase Discover -ConfigPath dr.config.json -EvidenceDirectory out
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Discover', 'Bootstrap', 'Verify')] [string]$Phase,
    [Parameter(Mandatory)] [string]$ConfigPath,
    [Parameter(Mandatory)] [string]$EvidenceDirectory,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DrPrerequisites.psm1') -Force
# Write-Error would throw under ErrorActionPreference Stop before the intended exit code.
function Stop-Dr([string]$Message, [int]$Code) { [Console]::Error.WriteLine($Message); exit $Code }

$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$problems = @(Get-DrConfigProblems $cfg)
if ($problems.Count) { Stop-Dr "Configuration refused: $($problems -join ', ')" 2 }
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$sec = $cfg.secondary
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidence = [ordered]@{ schema = 'ccof.dr.prerequisites.v1'; phase = $Phase; at = (Get-Date).ToUniversalTime().ToString('o'); azureConfigDir = [bool]$env:AZURE_CONFIG_DIR; checks = [ordered]@{}; blockers = @() }
$blockers = [System.Collections.Generic.List[string]]::new()

function Invoke-AzJson([string[]]$Arguments, [switch]$AllowMissing) {
    # stderr (warnings) is kept apart from the JSON on stdout.
    $errFile = New-TemporaryFile
    try { $out = & az @Arguments --output json 2>$errFile; $code = $LASTEXITCODE; $err = Get-Content -LiteralPath $errFile -Raw } finally { Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue }
    if ($code -ne 0) {
        $text = "$err $out"
        if ($AllowMissing -and $text -match 'NotFound|could not be found|ResourceGroupNotFound|does not exist') { return $null }
        throw [System.Exception]::new("az $($Arguments[0..1] -join ' '): $($text.Substring(0, [Math]::Min(400, $text.Length)))")
    }
    $j = ($out -join "`n").Trim()
    if (-not $j) { return $null }
    $j | ConvertFrom-Json
}

function Save-Evidence {
    $evidence.blockers = $blockers.ToArray()
    $path = Join-Path $EvidenceDirectory "dr-$($Phase.ToLowerInvariant())-$stamp.json"
    $evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    Write-Host "evidence: $path"
}

if (-not $env:AZURE_CONFIG_DIR) { Stop-Dr 'Set AZURE_CONFIG_DIR to an isolated profile for the target tenant.' 2 }

# Every phase starts with the tenant/subscription check. The configured subscription is resolved
# explicitly (never the profile default, which another sign-in can swap) and every subscription-scoped
# command below passes --subscription.
try { $account = Invoke-AzJson @('account', 'show', '--subscription', $cfg.subscriptionId) } catch { Stop-Dr "Subscription $($cfg.subscriptionId) is not available in this profile: $($_.Exception.Message)" 2 }
$evidence.checks.account = [ordered]@{ tenantId = $account.tenantId; subscriptionId = $account.id; user = $account.user.type }
if ($account.tenantId -ne $cfg.tenantId) { $blockers.Add("account:tenant_mismatch") }
if ($account.id -ne $cfg.subscriptionId) { $blockers.Add("account:subscription_mismatch") }
if ($blockers.Count) { Save-Evidence; Stop-Dr "Wrong account: $($blockers -join ', ')" 2 }
$sub = @('--subscription', $cfg.subscriptionId)

switch ($Phase) {
    'Discover' {
        $providers = [ordered]@{}
        $need = [ordered]@{
            'Microsoft.Network' = 'virtualNetworks'; 'Microsoft.ManagedIdentity' = 'userAssignedIdentities'; 'Microsoft.ApiManagement' = 'service'
            'Microsoft.Web' = 'sites'; 'Microsoft.App' = 'managedEnvironments'; 'Microsoft.DocumentDB' = 'databaseAccounts'; 'Microsoft.OperationalInsights' = 'workspaces'
        }
        foreach ($ns in $need.Keys) {
            try {
                $prov = Invoke-AzJson (@('provider', 'show', '--namespace', $ns) + $sub)
                $type = @($prov.resourceTypes | Where-Object { $_.resourceType -eq $need[$ns] })[0]
                $norm = { param($l) ($l -replace '\s', '').ToLowerInvariant() }
                $inRegion = $null -ne $type -and (@($type.locations | ForEach-Object { & $norm $_ }) -contains $sec.location -or @($type.locations).Count -eq 0)
                $providers[$ns] = [ordered]@{ registrationState = $prov.registrationState; type = $need[$ns]; availableInSecondary = $inRegion }
                if ($prov.registrationState -ne 'Registered') { $blockers.Add("provider:${ns}:$($prov.registrationState)") }
                if (-not $inRegion) { $blockers.Add("provider:${ns}/$($need[$ns]):not_in_$($sec.location)") }
            } catch { $providers[$ns] = [ordered]@{ error = $_.Exception.Message }; $blockers.Add("provider:${ns}:read_denied") }
        }
        $evidence.checks.providers = $providers

        $rg = Invoke-AzJson (@('group', 'show', '--name', $sec.resourceGroup) + $sub) -AllowMissing
        $evidence.checks.secondaryResourceGroup = if ($rg) { [ordered]@{ exists = $true; location = $rg.location } } else { [ordered]@{ exists = $false; createdBy = 'Bootstrap -Apply' } }

        if ($cfg.primary.PSObject.Properties['vnetId'] -and $cfg.primary.vnetId) {
            try {
                $pv = Invoke-AzJson @('network', 'vnet', 'show', '--ids', $cfg.primary.vnetId)
                $spaces = @($pv.addressSpace.addressPrefixes)
                $overlaps = @($spaces | Where-Object { Test-CidrOverlap $_ $sec.addressSpace })
                $evidence.checks.primaryVnet = [ordered]@{ id = $pv.id; location = $pv.location; addressSpaces = $spaces; secondaryAddressSpace = $sec.addressSpace; overlaps = $overlaps
                    peerings = @($pv.virtualNetworkPeerings | ForEach-Object { [ordered]@{ name = $_.name; remote = $_.remoteVirtualNetwork.id; state = $_.peeringState } }) }
                if ($overlaps.Count) { $blockers.Add("network:secondary_overlaps_primary_$($overlaps -join '+')") }
            } catch { $evidence.checks.primaryVnet = [ordered]@{ error = $_.Exception.Message }; $blockers.Add('network:primary_vnet_read_denied') }
        }

        $zones = [ordered]@{}
        if ($cfg.PSObject.Properties['dnsZones'] -and $cfg.dnsZones) {
            foreach ($z in @($cfg.dnsZones.zoneNames)) {
                try {
                    $zone = Invoke-AzJson @('network', 'private-dns', 'zone', 'show', '--name', $z, '--resource-group', $cfg.dnsZones.resourceGroup, '--subscription', $cfg.dnsZones.subscriptionId) -AllowMissing
                    $links = if ($zone) { @(Invoke-AzJson @('network', 'private-dns', 'link', 'vnet', 'list', '--zone-name', $z, '--resource-group', $cfg.dnsZones.resourceGroup, '--subscription', $cfg.dnsZones.subscriptionId) | ForEach-Object { $_.virtualNetwork.id }) } else { @() }
                    $zones[$z] = [ordered]@{ exists = $null -ne $zone; recordSets = if ($zone) { $zone.numberOfRecordSets } else { 0 }; linkedVnets = $links }
                    if (-not $zone) { $blockers.Add("dns:${z}:missing") }
                } catch { $zones[$z] = [ordered]@{ error = $_.Exception.Message }; $blockers.Add("dns:${z}:read_denied") }
            }
        }
        $evidence.checks.dnsZones = $zones

        $foundry = @()
        foreach ($f in @(if ($cfg.PSObject.Properties['foundryAccounts']) { $cfg.foundryAccounts })) {
            try {
                $acct = Invoke-AzJson @('cognitiveservices', 'account', 'show', '--name', $f.name, '--resource-group', $f.resourceGroup, '--subscription', $f.subscriptionId)
                $deps = @(Invoke-AzJson @('cognitiveservices', 'account', 'deployment', 'list', '--name', $f.name, '--resource-group', $f.resourceGroup, '--subscription', $f.subscriptionId))
                $foundry += [ordered]@{ name = $f.name; location = $acct.location; publicNetworkAccess = $acct.properties.publicNetworkAccess; endpoint = "https://$($f.name).services.ai.azure.com/anthropic"
                    deployments = @($deps | ForEach-Object { [ordered]@{ name = $_.name; model = $_.properties.model.name; version = $_.properties.model.version; sku = $_.sku.name; state = $_.properties.provisioningState } }) }
                if (@($deps | Where-Object { $_.properties.model.name -like 'claude-*' }).Count -eq 0) { $blockers.Add("foundry:$($f.name):no_claude_deployment") }
            } catch { $foundry += [ordered]@{ name = $f.name; error = $_.Exception.Message }; $blockers.Add("foundry:$($f.name):read_denied") }
        }
        $evidence.checks.foundry = $foundry

        $entra = [ordered]@{}
        if ($cfg.PSObject.Properties['entra'] -and $cfg.entra) {
            foreach ($role in 'gateway', 'resolver', 'admin') {
                $id = $cfg.entra."${role}AppId"
                if (-not $id) { continue }
                try {
                    $app = Invoke-AzJson @('ad', 'app', 'show', '--id', $id) -AllowMissing
                    $ap = @(Get-EntraAppProblems $role $app)
                    $entra[$role] = [ordered]@{ appId = $id; displayName = if ($app) { $app.displayName } else { $null }; problems = $ap }
                    foreach ($x in $ap) { $blockers.Add($x) }
                } catch { $entra[$role] = [ordered]@{ appId = $id; error = $_.Exception.Message }; $blockers.Add("entra.${role}:read_denied") }
            }
        }
        $evidence.checks.entra = $entra
    }
    'Bootstrap' {
        $params = [ordered]@{
            location = @{ value = $sec.location }; tags = @{ value = $cfg.tags }; vnetName = @{ value = $sec.vnetName }; addressSpace = @{ value = $sec.addressSpace }
            apimNsgName = @{ value = $sec.apimNsgName }; subnets = @{ value = $sec.subnets }
            dnsZones = @{ value = if ($cfg.PSObject.Properties['dnsZones'] -and $cfg.dnsZones) { $cfg.dnsZones } else { @{ subscriptionId = $cfg.subscriptionId; resourceGroup = $sec.resourceGroup; zoneNames = @() } } }
            primaryVnetId = @{ value = if ($cfg.primary.PSObject.Properties['vnetId'] -and $cfg.primary.PSObject.Properties['peer'] -and $cfg.primary.peer) { $cfg.primary.vnetId } else { '' } }
            identityNames = @{ value = @(if ($cfg.PSObject.Properties['identityNames']) { $cfg.identityNames }) }
        }
        $paramFile = Join-Path $EvidenceDirectory "dr-bootstrap-$stamp.parameters.json"
        @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $params } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $paramFile -Encoding utf8NoBOM
        $template = Join-Path $PSScriptRoot 'dr-prerequisites.bicep'
        $rg = Invoke-AzJson (@('group', 'show', '--name', $sec.resourceGroup) + $sub) -AllowMissing
        if (-not $rg) {
            if (-not $Apply) { Write-Host "preview: resource group $($sec.resourceGroup) ($($sec.location)) would be created"; $evidence.checks.resourceGroup = 'would_create' }
            else { $null = Invoke-AzJson (@('group', 'create', '--name', $sec.resourceGroup, '--location', $sec.location, '--tags') + @($cfg.tags.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) + $sub); $evidence.checks.resourceGroup = 'created' }
        } elseif ($rg.location -ne $sec.location) {
            # A resource group's location is metadata only; the template places every resource in the
            # secondary location. Reusing an existing group elsewhere (a subscription without
            # resource-group create rights) is an explicit, recorded choice: its metadata is not
            # reachable while its own region is down.
            if ($sec.PSObject.Properties['allowResourceGroupInOtherRegion'] -and $sec.allowResourceGroupInOtherRegion -eq $true) { $evidence.checks.resourceGroupWarning = "metadata_in_$($rg.location)" }
            else { $blockers.Add("resourceGroup:location_is_$($rg.location)") }
        }
        if ($blockers.Count) { break }
        $name = "ccof-dr-prereq-$stamp"
        if (-not $Apply) {
            if (-not $rg) { Write-Host 'preview: what-if needs the resource group; template and parameters were validated offline.'; $evidence.checks.whatIf = 'skipped_no_resource_group' }
            else {
                $wi = Invoke-AzJson (@('deployment', 'group', 'what-if', '--resource-group', $sec.resourceGroup, '--name', $name, '--template-file', $template, '--parameters', "@$paramFile", '--no-pretty-print') + $sub)
                $evidence.checks.whatIf = @($wi.changes | ForEach-Object { [ordered]@{ resourceId = $_.resourceId; changeType = $_.changeType } })
                $evidence.checks.whatIf | Where-Object changeType -ne 'Ignore' | ForEach-Object { Write-Host "what-if: $($_.changeType) $($_.resourceId)" }
                # Owned by this template, by exact name: the secondary VNet (and its subnets/peering), its NSG,
                # the identity shells, its DNS links and the primary-side peering to it. The secondary may
                # share a resource group with the primary, so the group alone proves nothing. A Modify or
                # Delete of anything else is a blocker.
                $names = @(if ($cfg.PSObject.Properties['identityNames']) { $cfg.identityNames }) | ForEach-Object { [regex]::Escape($_) }
                $e = { param($s) [regex]::Escape($s) }
                $ownedPattern = "/virtualNetworks/$(& $e $sec.vnetName)(/|$)|/networkSecurityGroups/$(& $e $sec.apimNsgName)$|/virtualNetworkLinks/$(& $e $sec.vnetName)-link$|/virtualNetworkPeerings/to-$(& $e $sec.vnetName)$" + $(if ($names) { "|/userAssignedIdentities/($($names -join '|'))$" } else { '' })
                $owned = { param($id) $id -match $ownedPattern }
                $destructive = @($evidence.checks.whatIf | Where-Object { $_.changeType -in 'Delete', 'Modify' -and -not (& $owned $_.resourceId) })
                if ($destructive.Count) { $blockers.Add("whatIf:changes_existing_$($destructive.Count)") }
            }
        } else {
            $dep = Invoke-AzJson (@('deployment', 'group', 'create', '--resource-group', $sec.resourceGroup, '--name', $name, '--template-file', $template, '--parameters', "@$paramFile") + $sub)
            $evidence.checks.deployment = [ordered]@{ name = $name; state = $dep.properties.provisioningState; outputs = $dep.properties.outputs }
            if ($dep.properties.provisioningState -ne 'Succeeded') { $blockers.Add("deployment:$($dep.properties.provisioningState)") }
        }
    }
    'Verify' {
        $vnet = Invoke-AzJson (@('network', 'vnet', 'show', '--resource-group', $sec.resourceGroup, '--name', $sec.vnetName) + $sub) -AllowMissing
        if (-not $vnet) { $blockers.Add('vnet:missing') } else {
            if ($vnet.location -ne $sec.location) { $blockers.Add("vnet:location_$($vnet.location)") }
            if (@($vnet.addressSpace.addressPrefixes) -notcontains $sec.addressSpace) { $blockers.Add('vnet:address_space') }
            $want = @{ apim = 'Microsoft.Web/serverFarms'; functions = 'Microsoft.App/environments'; privateEndpoints = $null }
            $subnets = [ordered]@{}
            foreach ($k in $want.Keys) {
                $sn = @($vnet.subnets | Where-Object { $_.name -ceq $sec.subnets.$k.name })[0]
                if (-not $sn) { $blockers.Add("subnet:${k}:missing"); continue }
                $del = @($sn.delegations | ForEach-Object serviceName)
                $subnets[$k] = [ordered]@{ prefix = $sn.addressPrefix; delegations = $del; nsg = if ($sn.PSObject.Properties['networkSecurityGroup'] -and $sn.networkSecurityGroup) { $sn.networkSecurityGroup.id } else { $null } }
                if ($sn.addressPrefix -ne $sec.subnets.$k.prefix) { $blockers.Add("subnet:${k}:prefix") }
                if ($want[$k] -and $del -notcontains $want[$k]) { $blockers.Add("subnet:${k}:delegation") }
                if (-not $want[$k] -and $del.Count) { $blockers.Add("subnet:${k}:unexpected_delegation") }
                if ($k -eq 'apim' -and -not $subnets[$k].nsg) { $blockers.Add('subnet:apim:nsg_missing') }
            }
            $evidence.checks.vnet = [ordered]@{ id = $vnet.id; subnets = $subnets; peerings = @($vnet.virtualNetworkPeerings | ForEach-Object { [ordered]@{ name = $_.name; state = $_.peeringState; remote = $_.remoteVirtualNetwork.id } }) }
            if ($cfg.primary.PSObject.Properties['peer'] -and $cfg.primary.peer -and @($vnet.virtualNetworkPeerings | Where-Object { $_.remoteVirtualNetwork.id -eq $cfg.primary.vnetId -and $_.peeringState -eq 'Connected' }).Count -ne 1) { $blockers.Add('peering:not_connected') }
            $links = [ordered]@{}
            if ($cfg.PSObject.Properties['dnsZones'] -and $cfg.dnsZones) {
                foreach ($z in @($cfg.dnsZones.zoneNames)) {
                    $l = @(Invoke-AzJson @('network', 'private-dns', 'link', 'vnet', 'list', '--zone-name', $z, '--resource-group', $cfg.dnsZones.resourceGroup, '--subscription', $cfg.dnsZones.subscriptionId) | Where-Object { $_.virtualNetwork.id -eq $vnet.id })
                    $links[$z] = if ($l.Count) { $l[0].provisioningState } else { 'missing' }
                    if (-not $l.Count -or $l[0].provisioningState -ne 'Succeeded') { $blockers.Add("dns:${z}:link_missing") }
                }
            }
            $evidence.checks.dnsLinks = $links
        }
        $ids = @()
        foreach ($n in @(if ($cfg.PSObject.Properties['identityNames']) { $cfg.identityNames })) {
            $mi = Invoke-AzJson (@('identity', 'show', '--resource-group', $sec.resourceGroup, '--name', $n) + $sub) -AllowMissing
            if (-not $mi) { $blockers.Add("identity:${n}:missing"); continue }
            $ids += [ordered]@{ name = $n; principalId = $mi.principalId; clientId = $mi.clientId; location = $mi.location }
        }
        $evidence.checks.identities = $ids
    }
}

Save-Evidence
if ($blockers.Count) { Write-Host "BLOCKERS ($($blockers.Count)):" -ForegroundColor Yellow; $blockers | ForEach-Object { Write-Host "  $_" }; exit 1 }
Write-Host "$Phase passed."
