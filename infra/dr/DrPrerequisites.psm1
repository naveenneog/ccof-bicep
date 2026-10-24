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
    $has = { param($o, $n) $null -ne $o -and $o.PSObject.Properties[$n] -and $null -ne $o.$n }
    foreach ($k in 'tenantId', 'subscriptionId') { if (-not (& $has $Config $k) -or "$($Config.$k)" -notmatch $script:Guid) { $p.Add("${k}:invalid") } }
    $s = if (& $has $Config 'secondary') { $Config.secondary } else { $null }
    if ($null -eq $s) { $p.Add('secondary:required'); return $p.ToArray() }
    if ("$($s.location)" -cnotmatch $script:Location) { $p.Add('secondary.location:invalid') }
    foreach ($k in 'resourceGroup', 'vnetName', 'apimNsgName') { if ("$($s.$k)" -cnotmatch $script:Name) { $p.Add("secondary.${k}:invalid") } }
    if ($null -eq (ConvertTo-CidrRange "$($s.addressSpace)")) { $p.Add('secondary.addressSpace:invalid') }
    $subnetPrefixes = @{}
    foreach ($k in 'apim', 'functions', 'privateEndpoints') {
        $sn = if (& $has $s.subnets $k) { $s.subnets.$k } else { $null }
        if ($null -eq $sn -or "$($sn.name)" -cnotmatch $script:Name) { $p.Add("secondary.subnets.${k}.name:invalid"); continue }
        $r = ConvertTo-CidrRange "$($sn.prefix)"
        if ($null -eq $r) { $p.Add("secondary.subnets.${k}.prefix:invalid"); continue }
        if ($r.Bits -gt $script:MaxPrefix[$k]) { $p.Add("secondary.subnets.${k}.prefix:too_small") }
        if (-not (Test-CidrWithin $sn.prefix $s.addressSpace)) { $p.Add("secondary.subnets.${k}.prefix:outside_address_space") }
        $subnetPrefixes[$k] = "$($sn.prefix)"
    }
    $keys = @($subnetPrefixes.Keys | Sort-Object)
    for ($i = 0; $i -lt $keys.Count; $i++) { for ($j = $i + 1; $j -lt $keys.Count; $j++) {
            if (Test-CidrOverlap $subnetPrefixes[$keys[$i]] $subnetPrefixes[$keys[$j]]) { $p.Add("secondary.subnets:$($keys[$i])_overlaps_$($keys[$j])") } } }
    $primary = if (& $has $Config 'primary') { $Config.primary } else { $null }
    if ($null -eq $primary -or "$($primary.location)" -cnotmatch $script:Location) { $p.Add('primary.location:invalid') }
    elseif ($primary.location -ceq $s.location) { $p.Add('secondary.location:same_as_primary') }
    if ($null -ne $primary -and (& $has $primary 'vnetId') -and "$($primary.vnetId)" -cnotmatch $script:VnetId) { $p.Add('primary.vnetId:invalid') }
    if ($null -ne $primary -and (& $has $primary 'addressSpaces')) {
        foreach ($a in @($primary.addressSpaces)) { if (Test-CidrOverlap $a $s.addressSpace) { $p.Add("secondary.addressSpace:overlaps_primary_$a") } }
    }
    $z = if (& $has $Config 'dnsZones') { $Config.dnsZones } else { $null }
    if ($null -ne $z) {
        if ("$($z.subscriptionId)" -notmatch $script:Guid) { $p.Add('dnsZones.subscriptionId:invalid') }
        if ("$($z.resourceGroup)" -cnotmatch $script:Name) { $p.Add('dnsZones.resourceGroup:invalid') }
        foreach ($n in @($z.zoneNames)) { if ($script:Zones -cnotcontains $n) { $p.Add("dnsZones.zoneNames:not_approved_$n") } }
    }
    if (& $has $Config 'tags') { foreach ($tag in $Config.tags.PSObject.Properties) { if ($tag.Name -cnotmatch $script:Name -or "$($tag.Value)" -cnotmatch '^[A-Za-z0-9._:/-]{1,256}$') { $p.Add("tags:invalid_$($tag.Name)") } } }
    foreach ($n in @(if (& $has $Config 'identityNames') { $Config.identityNames })) { if ("$n" -cnotmatch $script:Name) { $p.Add("identityNames:invalid_$n") } }
    foreach ($f in @(if (& $has $Config 'foundryAccounts') { $Config.foundryAccounts })) {
        if ("$($f.subscriptionId)" -notmatch $script:Guid -or "$($f.resourceGroup)" -cnotmatch $script:Name -or "$($f.name)" -cnotmatch $script:Name) { $p.Add('foundryAccounts:invalid') }
    }
    $e = if (& $has $Config 'entra') { $Config.entra } else { $null }
    if ($null -ne $e) { foreach ($k in 'gatewayAppId', 'resolverAppId', 'adminAppId') { if ((& $has $e $k) -and "$($e.$k)" -notmatch $script:Guid) { $p.Add("entra.${k}:invalid") } } }
    $p.ToArray()
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

Export-ModuleMember -Function ConvertTo-CidrRange, Test-CidrOverlap, Test-CidrWithin, Get-DrConfigProblems, Get-EntraAppProblems
