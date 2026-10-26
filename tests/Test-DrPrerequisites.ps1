# Offline tests for the DR prerequisite checks (infra/dr/DrPrerequisites.psm1) and template build.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\infra\dr\DrPrerequisites.psm1') -Force
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }

Check 'cidr parses' ((ConvertTo-CidrRange '10.70.0.0/22').End -eq (ConvertTo-CidrRange '10.70.3.255/32').Start)
Check 'misaligned cidr refused' ($null -eq (ConvertTo-CidrRange '10.70.1.0/22'))
Check 'octet over 255 refused' ($null -eq (ConvertTo-CidrRange '10.300.0.0/16'))
Check 'overlap detected' (Test-CidrOverlap '10.66.0.0/16' '10.66.128.0/22')
Check 'adjacent ranges do not overlap' (-not (Test-CidrOverlap '10.66.0.0/16' '10.67.0.0/16'))
Check 'within' (Test-CidrWithin '10.70.0.0/27' '10.70.0.0/22')
Check 'not within' (-not (Test-CidrWithin '10.71.0.0/27' '10.70.0.0/22'))

function New-Config {
    '{"tenantId":"00000000-0000-4000-8000-00000000dd01","subscriptionId":"00000000-0000-4000-8000-00000000dd02",
      "tags":{"workload":"ccof","stage":"dr-p2"},
      "primary":{"location":"eastus2","vnetId":"/subscriptions/00000000-0000-4000-8000-00000000dd02/resourceGroups/rg-lab-shared/providers/Microsoft.Network/virtualNetworks/lab1-vnet","addressSpaces":["10.66.0.0/16"],"peer":true},
      "secondary":{"location":"centralus","resourceGroup":"ccof-dr-cus-rg","vnetName":"dr-vnet","apimNsgName":"dr-nsg-apim","addressSpace":"10.70.0.0/22",
        "subnets":{"apim":{"name":"snet-apim","prefix":"10.70.0.0/27"},"functions":{"name":"snet-functions","prefix":"10.70.0.32/27"},"privateEndpoints":{"name":"snet-pe","prefix":"10.70.1.0/26"}}},
      "dnsZones":{"subscriptionId":"00000000-0000-4000-8000-00000000dd02","resourceGroup":"rg-lab-shared","zoneNames":["privatelink.documents.azure.com","privatelink.services.ai.azure.com"]},
      "identityNames":["lab1-sync-b","lab1-reconciler-b"],
      "foundryAccounts":[{"subscriptionId":"00000000-0000-4000-8000-00000000dd02","resourceGroup":"rg-lab-shared","name":"lab1-foundry"}],
      "entra":{"gatewayAppId":"00000000-0000-4000-8000-00000000dd03","resolverAppId":"00000000-0000-4000-8000-00000000dd04","adminAppId":"00000000-0000-4000-8000-00000000dd05"}}' | ConvertFrom-Json
}
$ok = @(Get-DrConfigProblems (New-Config))
Check "valid config has no problems ($($ok -join ','))" ($ok.Count -eq 0)
function Has($mutate, [string]$problem) { $c = New-Config; & $mutate $c; $got = @(Get-DrConfigProblems $c); if ($got -notcontains $problem) { Write-Host "  got: $($got -join ',')" }; $got -contains $problem }
Check 'overlap with primary' (Has { param($c) $c.secondary.addressSpace = '10.66.4.0/22'; $c.secondary.subnets.apim.prefix = '10.66.4.0/27'; $c.secondary.subnets.functions.prefix = '10.66.4.32/27'; $c.secondary.subnets.privateEndpoints.prefix = '10.66.5.0/26' } 'secondary.addressSpace:overlaps_primary_10.66.0.0/16')
Check 'same region' (Has { param($c) $c.secondary.location = 'eastus2' } 'secondary.location:same_as_primary')
Check 'subnet outside space' (Has { param($c) $c.secondary.subnets.privateEndpoints.prefix = '10.71.0.0/26' } 'secondary.subnets.privateEndpoints.prefix:outside_address_space')
Check 'subnets overlap' (Has { param($c) $c.secondary.subnets.functions.prefix = '10.70.0.0/27' } 'secondary.subnets:apim_overlaps_functions')
Check 'apim subnet too small' (Has { param($c) $c.secondary.subnets.apim.prefix = '10.70.0.0/28' } 'secondary.subnets.apim.prefix:too_small')
Check 'cmd metacharacter in rg' (Has { param($c) $c.secondary.resourceGroup = 'rg&calc' } 'secondary.resourceGroup:invalid')
Check 'cmd metacharacter in tag' (Has { param($c) $c.tags.stage = 'a|b' } 'tags:invalid_stage')
Check 'unapproved dns zone' (Has { param($c) $c.dnsZones.zoneNames = @('evil.example.com') } 'dnsZones.zoneNames:not_approved_evil.example.com')
Check 'bad tenant' (Has { param($c) $c.tenantId = 'contoso' } 'tenantId:invalid')
Check 'bad primary vnet id' (Has { param($c) $c.primary.vnetId = '/subscriptions/x/resourceGroups/a(b)/providers/Microsoft.Network/virtualNetworks/v' } 'primary.vnetId:invalid')
Check 'bad identity name' (Has { param($c) $c.identityNames = @('sync b') } 'identityNames:invalid_sync b')

# A partial configuration lists what is missing instead of failing on the first absent field.
$partial = '{"tenantId":"00000000-0000-4000-8000-000000000001","subscriptionId":"00000000-0000-4000-8000-000000000002","secondary":{"location":"centralus"}}' | ConvertFrom-Json
$got = @(); $threw = $null
try { $got = @(Get-DrConfigProblems $partial) } catch { $threw = $_.Exception.Message }
Check "partial config does not throw ($threw)" ($null -eq $threw)
foreach ($p in 'secondary.resourceGroup:invalid', 'secondary.vnetName:invalid', 'secondary.addressSpace:invalid', 'secondary.subnets.apim.name:invalid', 'primary.location:invalid') {
    Check "partial config reports $p" ($got -contains $p)
}

# The example configuration names every field: refused as shipped, valid once the REPLACE- values are filled.
$examplePath = Join-Path $PSScriptRoot '..\infra\dr\dr.config.example.json'
Check 'example config exists' (Test-Path $examplePath)
if (Test-Path $examplePath) {
    $raw = Get-Content $examplePath -Raw
    Check 'example config is refused as shipped' (@(Get-DrConfigProblems ($raw | ConvertFrom-Json)).Count -gt 0)
    $filled = @(Get-DrConfigProblems (($raw -replace 'REPLACE-', '') | ConvertFrom-Json))
    Check "example config is valid once filled ($($filled -join ','))" ($filled.Count -eq 0)
}

# Azure CLI profile: an explicit AZURE_CONFIG_DIR, or Cloud Shell's own signed-in profile.
$r = Resolve-DrAzureProfile -ConfigDir 'C:\p' -CloudShell $null -HomePath '/home/a'
Check 'explicit profile kept' ($r.Ok -and $r.ConfigDir -eq 'C:\p')
$r = Resolve-DrAzureProfile -ConfigDir $null -CloudShell 'true' -HomePath '/home/a'
Check 'cloud shell uses its own profile' ($r.Ok -and $r.ConfigDir -eq '/home/a/.azure')
$r = Resolve-DrAzureProfile -ConfigDir $null -CloudShell $null -HomePath '/home/a'
Check 'workstation without profile refused, message names both options' (-not $r.Ok -and $r.Message -match 'isolated profile' -and $r.Message -match 'Cloud Shell')

# Reusing a resource group in another region: the blocker names the override.
$sec = [pscustomobject]@{ location = 'centralus' }
Check 'same-region group accepted' ($null -eq (Get-DrResourceGroupLocationBlocker $sec 'centralus'))
$b = Get-DrResourceGroupLocationBlocker $sec 'eastus2'
Check 'other-region group blocked with override hint' ($b -match '^resourceGroup:location_is_eastus2' -and $b -match 'allowResourceGroupInOtherRegion')
$sec = [pscustomobject]@{ location = 'centralus'; allowResourceGroupInOtherRegion = $true }
Check 'override accepts other-region group' ($null -eq (Get-DrResourceGroupLocationBlocker $sec 'eastus2'))

$admin = '{"appId":"00000000-0000-4000-8000-00000000dd05","signInAudience":"AzureADMyOrg","identifierUris":["api://00000000-0000-4000-8000-00000000dd05"],
  "api":{"oauth2PermissionScopes":[{"value":"Projects.Manage","isEnabled":true}],"preAuthorizedApplications":[{"appId":"04b07795-8ddb-461a-bbee-02f9e1bf7b46"}]},
  "appRoles":[{"value":"CCOF.Projects.Read","isEnabled":true},{"value":"CCOF.Projects.Write","isEnabled":true}]}'
Check 'admin app passes' (@(Get-EntraAppProblems 'admin' ($admin | ConvertFrom-Json)).Count -eq 0)
$a = $admin | ConvertFrom-Json; $a.api.preAuthorizedApplications = @()
Check 'admin without CLI preauth' (@(Get-EntraAppProblems 'admin' $a) -contains 'entra.admin:azure_cli_not_preauthorized')
$a = $admin | ConvertFrom-Json; $a.signInAudience = 'AzureADMultipleOrgs'
Check 'multi-tenant refused' (@(Get-EntraAppProblems 'admin' $a) -contains 'entra.admin:not_single_tenant')
$a = $admin | ConvertFrom-Json; $a.appRoles[1].isEnabled = $false
Check 'disabled write role' (@(Get-EntraAppProblems 'admin' $a) -contains 'entra.admin:role_missing_CCOF.Projects.Write')
Check 'missing app' (@(Get-EntraAppProblems 'gateway' $null) -contains 'entra.gateway:not_found')

# The driver refuses a bad config before any az call, and refuses to run without an isolated profile.
$tmp = New-TemporaryFile; $c = New-Config; $c.secondary.location = 'eastus2'; $c | ConvertTo-Json -Depth 10 | Set-Content $tmp
$out = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\infra\dr\Invoke-DrPrerequisites.ps1') -Phase Discover -ConfigPath $tmp -EvidenceDirectory ([IO.Path]::GetTempPath()) 2>&1
Check 'driver refuses invalid config (exit 2)' ($LASTEXITCODE -eq 2 -and "$out" -match 'same_as_primary')
New-Config | ConvertTo-Json -Depth 10 | Set-Content $tmp
$saved = $env:AZURE_CONFIG_DIR; $env:AZURE_CONFIG_DIR = $null
$out = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\infra\dr\Invoke-DrPrerequisites.ps1') -Phase Discover -ConfigPath $tmp -EvidenceDirectory ([IO.Path]::GetTempPath()) 2>&1
$env:AZURE_CONFIG_DIR = $saved
Check 'driver refuses without AZURE_CONFIG_DIR' ($LASTEXITCODE -eq 2 -and "$out" -match 'isolated profile')
$out = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\infra\dr\Invoke-DrPrerequisites.ps1') -Phase Discover -ConfigPath (Join-Path ([IO.Path]::GetTempPath()) 'no-such-dr.config.json') -EvidenceDirectory ([IO.Path]::GetTempPath()) 2>&1
Check 'missing config names the example (exit 2)' ($LASTEXITCODE -eq 2 -and "$out" -match 'dr\.config\.example\.json')
Remove-Item $tmp

# Templates build (az bicep build works signed out).
foreach ($t in 'infra\dr\dr-prerequisites.bicep', 'infra\prereqs\network.bicep') {
    $json = & az bicep build --file (Join-Path $PSScriptRoot "..\$t") --stdout 2>$null
    Check "$t builds" ($LASTEXITCODE -eq 0 -and ($json -join '') -match '"\$schema"')
}
$arm = (& az bicep build --file (Join-Path $PSScriptRoot '..\infra\dr\dr-prerequisites.bicep') --stdout 2>$null) -join "`n"
Check 'dr template never creates DNS zones in the secondary' ($arm -match '"createDnsZones":\s*\{\s*"value":\s*false')
Check 'dr template creates no role assignment' ($arm -notmatch 'Microsoft.Authorization/roleAssignments')

Write-Host "Test-DrPrerequisites: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 30) { exit 1 }
