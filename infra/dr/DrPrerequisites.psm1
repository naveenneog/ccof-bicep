# Pure checks for the DR prerequisite driver (infra/dr/Invoke-DrPrerequisites.ps1, ADR 0034 P0-P2).
# No Azure call happens here; tests/Test-DrPrerequisites.ps1 runs them offline.

Set-StrictMode -Version Latest

$script:Guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# Names reach az.cmd, which cmd.exe re-parses: letters, digits, '.', '_' and '-' only.
$script:Name = '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$'
$script:Location = '^[a-z][a-z0-9]{2,30}$'
$script:VnetId = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]{1,90}/providers/Microsoft\.Network/virtualNetworks/[A-Za-z0-9._-]{1,64}$'
$script:Zones = @(
    'privatelink.services.ai.azure.com', 'privatelink.cognitiveservices.azure.com', 'privatelink.openai.azure.com',
    'privatelink.documents.azure.com', 'privatelink.blob.core.windows.net', 'privatelink.azurewebsites.net'
)
# Smallest subnets accepted: APIM v2 VNet integration and Flex Consumption integration (/27, Learn
# "Virtual network integration" for each service), private endpoints (/28).
$script:MaxPrefix = @{ apim = 27; functions = 27; privateEndpoints = 28 }

function ConvertTo-CidrRange {
    param([Parameter(Mandatory)] [string]$Cidr)
    $m = [regex]::Match($Cidr, '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$')
    if (-not $m.Success) { return $null }
    $octets = 1..4 | ForEach-Object { [int]$m.Groups[$_].Value }
    $bits = [int]$m.Groups[5].Value
    if (@($octets | Where-Object { $_ -gt 255 }).Count -or $bits -gt 32 -or $bits -lt 8) { return $null }
    [uint64]$ip = ([uint64]$octets[0] -shl 24) + ([uint64]$octets[1] -shl 16) + ([uint64]$octets[2] -shl 8) + [uint64]$octets[3]
    [uint64]$size = [uint64]1 -shl (32 - $bits)
    if ($ip % $size -ne 0) { return $null }
    [pscustomobject]@{ Start = $ip; End = $ip + $size - 1; Bits = $bits }
}

function Test-CidrOverlap([string]$A, [string]$B) {
    $x = ConvertTo-CidrRange $A; $y = ConvertTo-CidrRange $B
    if ($null -eq $x -or $null -eq $y) { return $true }
    $x.Start -le $y.End -and $y.Start -le $x.End
}

function Test-CidrWithin([string]$Inner, [string]$Outer) {
    $i = ConvertTo-CidrRange $Inner; $o = ConvertTo-CidrRange $Outer
    $null -ne $i -and $null -ne $o -and $i.Start -ge $o.Start -and $i.End -le $o.End
}

# Problems with the DR configuration file; empty means it can be used.
function Get-DrConfigProblems {
    param([Parameter(Mandatory)] $Config)
    $p = [System.Collections.Generic.List[string]]::new()
    # Strict mode throws on a missing property; $get returns $null instead, so a partial file lists
    # every missing field rather than stopping at the first one.
    $get = { param($o, $n) if ($null -ne $o -and $o -isnot [string] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $cidr = { param($v) if ([string]::IsNullOrWhiteSpace("$v")) { $null } else { ConvertTo-CidrRange "$v" } }
    foreach ($k in 'tenantId', 'subscriptionId') { if ("$(& $get $Config $k)" -notmatch $script:Guid) { $p.Add("${k}:invalid") } }
    $s = & $get $Config 'secondary'
    if ($null -eq $s) { $p.Add('secondary:required'); return $p.ToArray() }
    if ("$(& $get $s 'location')" -cnotmatch $script:Location) { $p.Add('secondary.location:invalid') }
    foreach ($k in 'resourceGroup', 'vnetName', 'apimNsgName') { if ("$(& $get $s $k)" -cnotmatch $script:Name) { $p.Add("secondary.${k}:invalid") } }
    $space = & $get $s 'addressSpace'
    $spaceOk = $null -ne (& $cidr $space)
    if (-not $spaceOk) { $p.Add('secondary.addressSpace:invalid') }
    $subnets = & $get $s 'subnets'
    $subnetPrefixes = @{}
    foreach ($k in 'apim', 'functions', 'privateEndpoints') {
        $sn = & $get $subnets $k
        if ("$(& $get $sn 'name')" -cnotmatch $script:Name) { $p.Add("secondary.subnets.${k}.name:invalid"); continue }
        $prefix = & $get $sn 'prefix'
        $r = & $cidr $prefix
        if ($null -eq $r) { $p.Add("secondary.subnets.${k}.prefix:invalid"); continue }
        if ($r.Bits -gt $script:MaxPrefix[$k]) { $p.Add("secondary.subnets.${k}.prefix:too_small") }
        if ($spaceOk -and -not (Test-CidrWithin $prefix $space)) { $p.Add("secondary.subnets.${k}.prefix:outside_address_space") }
        $subnetPrefixes[$k] = "$prefix"
    }
    $keys = @($subnetPrefixes.Keys | Sort-Object)
    for ($i = 0; $i -lt $keys.Count; $i++) { for ($j = $i + 1; $j -lt $keys.Count; $j++) {
            if (Test-CidrOverlap $subnetPrefixes[$keys[$i]] $subnetPrefixes[$keys[$j]]) { $p.Add("secondary.subnets:$($keys[$i])_overlaps_$($keys[$j])") } } }
    $primary = & $get $Config 'primary'
    $primaryLocation = & $get $primary 'location'
    if ("$primaryLocation" -cnotmatch $script:Location) { $p.Add('primary.location:invalid') }
    elseif ($primaryLocation -ceq (& $get $s 'location')) { $p.Add('secondary.location:same_as_primary') }
    $vnetId = & $get $primary 'vnetId'
    if ($null -ne $vnetId -and "$vnetId" -cnotmatch $script:VnetId) { $p.Add('primary.vnetId:invalid') }
    if ($spaceOk) { foreach ($a in @(& $get $primary 'addressSpaces')) { if ($null -ne $a -and (Test-CidrOverlap "$a" $space)) { $p.Add("secondary.addressSpace:overlaps_primary_$a") } } }
    $z = & $get $Config 'dnsZones'
    if ($null -ne $z) {
        if ("$(& $get $z 'subscriptionId')" -notmatch $script:Guid) { $p.Add('dnsZones.subscriptionId:invalid') }
        if ("$(& $get $z 'resourceGroup')" -cnotmatch $script:Name) { $p.Add('dnsZones.resourceGroup:invalid') }
        foreach ($n in @(& $get $z 'zoneNames')) { if ($null -ne $n -and $script:Zones -cnotcontains $n) { $p.Add("dnsZones.zoneNames:not_approved_$n") } }
    }
    $tags = & $get $Config 'tags'
    if ($null -ne $tags) { foreach ($tag in $tags.PSObject.Properties) { if ($tag.Name -cnotmatch $script:Name -or "$($tag.Value)" -cnotmatch '^[A-Za-z0-9._:/-]{1,256}$') { $p.Add("tags:invalid_$($tag.Name)") } } }
    foreach ($n in @(& $get $Config 'identityNames')) { if ($null -ne $n -and "$n" -cnotmatch $script:Name) { $p.Add("identityNames:invalid_$n") } }
    foreach ($f in @(& $get $Config 'foundryAccounts')) {
        if ($null -eq $f) { continue }
        if ("$(& $get $f 'subscriptionId')" -notmatch $script:Guid -or "$(& $get $f 'resourceGroup')" -cnotmatch $script:Name -or "$(& $get $f 'name')" -cnotmatch $script:Name) { $p.Add('foundryAccounts:invalid') }
    }
    $e = & $get $Config 'entra'
    if ($null -ne $e) { foreach ($k in 'gatewayAppId', 'resolverAppId', 'adminAppId') { $v = & $get $e $k; if ($null -ne $v -and "$v" -notmatch $script:Guid) { $p.Add("entra.${k}:invalid") } } }
    $p.ToArray()
}

# Azure CLI profile for the driver: an explicit AZURE_CONFIG_DIR, or, in Azure Cloud Shell (ACC_CLOUD
# set), Cloud Shell's own signed-in profile. Cloud Shell's az login uses device code, which Conditional
# Access policies that require a managed device refuse (docs/DR-NOVICE-WALKTHROUGH-2026-10-25.md N-04).
function Resolve-DrAzureProfile {
    param([string]$ConfigDir, [string]$CloudShell, [string]$HomePath)
    if ($ConfigDir) { return [pscustomobject]@{ Ok = $true; ConfigDir = $ConfigDir; Message = $null } }
    if ($CloudShell) { return [pscustomobject]@{ Ok = $true; ConfigDir = (Join-Path $HomePath '.azure').Replace('\', '/'); Message = $null } }
    [pscustomobject]@{ Ok = $false; ConfigDir = $null
        Message = 'Set AZURE_CONFIG_DIR to an isolated profile for the target tenant (workstation), or run in Azure Cloud Shell, which uses its own signed-in profile.' }
}

# Blocker for reusing an existing resource group in another region; $null when it can be used.
function Get-DrResourceGroupLocationBlocker {
    param([Parameter(Mandatory)] $Secondary, [Parameter(Mandatory)] [string]$GroupLocation)
    if ($GroupLocation -eq $Secondary.location) { return $null }
    if ($Secondary.PSObject.Properties['allowResourceGroupInOtherRegion'] -and $Secondary.allowResourceGroupInOtherRegion -eq $true) { return $null }
    "resourceGroup:location_is_$GroupLocation (set secondary.allowResourceGroupInOtherRegion to true to reuse this group; its metadata stays in $GroupLocation)"
}
# Entra app checks from `az ad app show` JSON (ADR 0034 prerequisite handoff, Entra app registrations).
function Get-EntraAppProblems {
    param([Parameter(Mandatory)] [string]$Role, $App)
    if ($null -eq $App) { return @("entra.${Role}:not_found") }
    $p = [System.Collections.Generic.List[string]]::new()
    if ($App.signInAudience -cne 'AzureADMyOrg') { $p.Add("entra.${Role}:not_single_tenant") }
    if (@($App.identifierUris) -notcontains "api://$($App.appId)") { $p.Add("entra.${Role}:identifier_uri_missing") }
    $scopes = @(if ($App.api -and $App.api.oauth2PermissionScopes) { $App.api.oauth2PermissionScopes | Where-Object { $_.isEnabled } | ForEach-Object value })
    $preauth = @(if ($App.api -and $App.api.preAuthorizedApplications) { $App.api.preAuthorizedApplications | ForEach-Object appId })
    switch ($Role) {
        'gateway' { if ($scopes -cnotcontains 'access_as_user') { $p.Add('entra.gateway:access_as_user_missing') } }
        'admin' {
            if ($scopes -cnotcontains 'Projects.Manage') { $p.Add('entra.admin:projects_manage_missing') }
            $roles = @(if ($App.appRoles) { $App.appRoles | Where-Object { $_.isEnabled } | ForEach-Object value })
            foreach ($r in 'CCOF.Projects.Read', 'CCOF.Projects.Write') { if ($roles -cnotcontains $r) { $p.Add("entra.admin:role_missing_$r") } }
            if ($preauth -notcontains '04b07795-8ddb-461a-bbee-02f9e1bf7b46') { $p.Add('entra.admin:azure_cli_not_preauthorized') }
        }
    }
    $p.ToArray()
}

Export-ModuleMember -Function ConvertTo-CidrRange, Test-CidrOverlap, Test-CidrWithin, Get-DrConfigProblems, Get-EntraAppProblems, Resolve-DrAzureProfile, Get-DrResourceGroupLocationBlocker
