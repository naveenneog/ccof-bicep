#Requires -Version 7.0
param(
    [switch]$StubChild,
    [string]$ConfigPath,
    [string]$EvidenceDirectory,
    [string]$Phase,
    [switch]$Apply,
    [switch]$ApproveExistingVnetUpdate,
    [switch]$ApprovePublicFunctionAccess,
    [switch]$StubStandby,
    [switch]$StubFrontDoor,
    [string]$ReviewedConnectionIds
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($StubChild) {
    function global:az {
        $arguments = @($args)
        Add-Content -LiteralPath $env:DR_STUB_LOG -Value ($arguments | ConvertTo-Json -Compress)
        $global:LASTEXITCODE = 0
        $command = $arguments[0..1] -join ' '
        switch ($command) {
            'account show' {
                return (@{ tenantId = $env:DR_STUB_TENANT; id = $env:DR_STUB_SUB; user = @{ type = 'user' } } | ConvertTo-Json -Compress)
            }
            'group show' { return '{"location":"centralus"}' }
            'network vnet' {
                if ($env:DR_STUB_CASE -eq 'missing') {
                    Write-Error 'ResourceNotFound: VNet does not exist' -ErrorAction Continue
                    $global:LASTEXITCODE = 3
                    return
                }
                $vnet = Get-Content -LiteralPath $env:DR_STUB_VNET -Raw | ConvertFrom-Json
                if ($env:DR_STUB_CASE -eq 'wrong-id') { $vnet.id = $vnet.id -replace 'dr-vnet$', 'other-vnet' }
                if ($env:DR_STUB_CASE -eq 'wrong-location') { $vnet.location = 'westus2' }
                if ($env:DR_STUB_CASE -eq 'wrong-prefix') { $vnet.subnets[0].addressPrefix = '100.96.5.32/27' }
                if ($env:DR_STUB_CASE -eq 'wrong-delegation') { $vnet.subnets[1].delegations = @() }
                if ($env:DR_STUB_CASE -in @('plural-prefix', 'multiple-prefixes', 'missing-prefix', 'duplicate-prefix')) {
                    foreach ($sn in $vnet.subnets) {
                        $prefix = $sn.addressPrefix
                        $sn | Add-Member -NotePropertyName addressPrefixes -NotePropertyValue @($prefix)
                        if ($env:DR_STUB_CASE -ne 'duplicate-prefix') { $sn.PSObject.Properties.Remove('addressPrefix') }
                    }
                    if ($env:DR_STUB_CASE -eq 'multiple-prefixes') { $vnet.subnets[0].addressPrefixes += '100.96.6.0/27' }
                    if ($env:DR_STUB_CASE -eq 'missing-prefix') { $vnet.subnets[0].PSObject.Properties.Remove('addressPrefixes') }
                }
                return ($vnet | ConvertTo-Json -Depth 20 -Compress)
            }
            'network private-dns' {
                if ($env:DR_STUB_CASE -eq 'missing-dns-link') { return '[]' }
                return (@(@{ virtualNetwork = @{ id = $env:DR_STUB_VNET_ID }; provisioningState = 'Succeeded' }) | ConvertTo-Json -Depth 10 -Compress -AsArray)
            }
            'network private-endpoint-connection' {
                $connections = @(Get-Content -LiteralPath $env:DR_STUB_FD_CONNECTIONS -Raw | ConvertFrom-Json -AsHashtable -Depth 30)
                $index = [Array]::IndexOf($arguments, '--id')
                $id = $arguments[$index + 1]
                if ($arguments[2] -eq 'list') {
                    return (@($connections | Where-Object { $_.id.StartsWith("$id/privateEndpointConnections/", [StringComparison]::OrdinalIgnoreCase) }) | ConvertTo-Json -Depth 30 -Compress -AsArray)
                }
                if ($arguments[2] -eq 'approve') {
                    if ($env:DR_STUB_FD_NO_APPROVE -eq '1') { return '{"status":"accepted"}' }
                    $descriptionIndex = [Array]::IndexOf($arguments, '--description')
                    $connection = @($connections | Where-Object { $_.id -ieq $id })
                    if ($connection.Count -ne 1 -or $descriptionIndex -lt 0) { throw 'Unexpected fake private endpoint approval' }
                    $connection[0].properties.privateLinkServiceConnectionState.status = 'Approved'
                    $connection[0].properties.privateLinkServiceConnectionState.description = $arguments[$descriptionIndex + 1]
                    $connections | ConvertTo-Json -Depth 30 -AsArray | Set-Content -LiteralPath $env:DR_STUB_FD_CONNECTIONS
                    return '{"status":"approved"}'
                }
                throw 'Unexpected fake private endpoint command'
            }
            'identity show' {
                $index = [Array]::IndexOf($arguments, '--name')
                $name = $arguments[$index + 1]
                if ($env:DR_STUB_IDENTITIES -eq 'missing' -or ($env:DR_STUB_IDENTITIES -eq 'one-missing' -and $name -eq 'ccof-reconciler-b')) {
                    Write-Error 'ResourceNotFound: identity does not exist' -ErrorAction Continue
                    $global:LASTEXITCODE = 3
                    return
                }
                $location = if ($env:DR_STUB_IDENTITIES -eq 'wrong-location') { 'eastus2' } else { 'centralus' }
                $identityId = "/subscriptions/$env:DR_STUB_SUB/resourceGroups/workload-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"
                if ($env:DR_STUB_IDENTITIES -eq 'wrong-id') { $identityId = $identityId -replace 'workload-rg', 'other-rg' }
                $principal = if ($env:DR_STUB_IDENTITIES -eq 'missing-principal') { '' } else { '00000000-0000-4000-8000-000000000003' }
                return (@{ id = $identityId; name = $name; principalId = $principal; clientId = '00000000-0000-4000-8000-000000000004'; location = $location } | ConvertTo-Json -Compress)
            }
            'apim list' {
                if ($env:DR_STUB_APIM -eq 'forbidden') {
                    Write-Error 'AuthorizationFailed: listing API Management services is not allowed' -ErrorAction Continue
                    $global:LASTEXITCODE = 1
                    return
                }
                if ($env:DR_STUB_APIM -eq 'absent') { return '[]' }
                return (@(@{ name = 'fixture-b-apim'; id = "/subscriptions/$env:DR_STUB_SUB/resourceGroups/workload-rg/providers/Microsoft.ApiManagement/service/fixture-b-apim" }) | ConvertTo-Json -Compress -AsArray)
            }
            'rest --method' {
                if ($arguments -join ' ' -match 'Microsoft\.Web/sites/fixture-b-resolver') {
                    $siteId = "/subscriptions/$env:DR_STUB_SUB/resourceGroups/workload-rg/providers/Microsoft.Web/sites/fixture-b-resolver"
                    $access = if ($env:DR_STUB_FUNCTION -eq 'unknown') { '' } else { $env:DR_STUB_FUNCTION }
                    return (@{ id = $siteId; name = 'fixture-b-resolver'; properties = @{ publicNetworkAccess = $access } } | ConvertTo-Json -Depth 10 -Compress)
                }
                $access = if ($env:DR_STUB_APIM -eq 'unknown') { '' } else { $env:DR_STUB_APIM }
                return (@{ id = "/subscriptions/$env:DR_STUB_SUB/resourceGroups/workload-rg/providers/Microsoft.ApiManagement/service/fixture-b-apim"
                    name = 'fixture-b-apim'; properties = @{ publicNetworkAccess = $access } } | ConvertTo-Json -Depth 10 -Compress)
            }
            'resource list' {
                if ($env:DR_STUB_FUNCTION -eq 'forbidden') {
                    Write-Error 'AuthorizationFailed: listing Function Apps is not allowed' -ErrorAction Continue
                    $global:LASTEXITCODE = 1
                    return
                }
                if ($env:DR_STUB_FUNCTION -eq 'absent') { return '[]' }
                return (@(@{ name = 'fixture-b-resolver'; id = "/subscriptions/$env:DR_STUB_SUB/resourceGroups/workload-rg/providers/Microsoft.Web/sites/fixture-b-resolver" }) | ConvertTo-Json -Compress -AsArray)
            }
            'functionapp show' {
                $index = [Array]::IndexOf($arguments, '--name')
                $name = $arguments[$index + 1]
                return (@{ id = "/subscriptions/$env:DR_STUB_SUB/resourceGroups/workload-rg/providers/Microsoft.Web/sites/$name"
                    properties = @{ defaultHostName = "$name.azurewebsites.net" } } | ConvertTo-Json -Depth 10 -Compress)
            }
            'deployment group' {
                if ($arguments -contains 'what-if') { return '{"changes":[]}' }
                if ($StubStandby -or $StubFrontDoor) {
                    Write-Error 'test_sentinel_reached_deployment: fake deployment not executed' -ErrorAction Continue
                    $global:LASTEXITCODE = 9
                    return
                }
                return '{"properties":{"provisioningState":"Succeeded","outputs":{}}}'
            }
            default { throw "Unexpected az call in offline test: $($arguments -join ' ')" }
        }
    }
    if ($StubFrontDoor) {
        $reviewedArgs = @{}
        if ($ReviewedConnectionIds) { $reviewedArgs.ReviewedConnectionIds = $ReviewedConnectionIds }
        & (Join-Path $root 'infra\dr\Invoke-DrFrontDoor.ps1') -Phase $Phase -ConfigPath $ConfigPath -Apply:$Apply -ConfirmStandbyReady @reviewedArgs
    } elseif ($StubStandby) {
        & (Join-Path $root 'infra\dr\Invoke-DrStandby.ps1') -Phase $Phase -ConfigPath $ConfigPath -Apply:$Apply -ApprovePublicApimBootstrap -ApprovePublicFunctionAccess:$ApprovePublicFunctionAccess
    } else {
        $optional = @{}
        if ($ApproveExistingVnetUpdate) { $optional.ApproveExistingVnetUpdate = $true }
        & (Join-Path $root 'infra\dr\Invoke-DrPrerequisites.ps1') -Phase $Phase -ConfigPath $ConfigPath -EvidenceDirectory $EvidenceDirectory -Apply:$Apply @optional
    }
    exit $LASTEXITCODE
}

$script:passed = 0
$script:failed = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $Name" -ForegroundColor Red }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) "ccof-dr-byo-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $sub = '00000000-0000-4000-8000-000000000002'
    $tenant = '00000000-0000-4000-8000-000000000001'
    $vnetId = "/subscriptions/$sub/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/dr-vnet"
    $config = @{
        tenantId = $tenant; subscriptionId = $sub; tags = @{ workload = 'ccof' }
        primary = @{ location = 'eastus2'; addressSpaces = @('10.40.0.0/16'); peer = $false }
        secondary = @{
            location = 'centralus'; resourceGroup = 'workload-rg'; vnetName = 'dr-vnet'
            networkMode = 'existing'; existingVnetId = $vnetId; addressSpace = '100.96.5.0/24'
            subnets = @{
                apim = @{ name = 'snet-apim'; prefix = '100.96.5.0/27' }
                functions = @{ name = 'snet-functions'; prefix = '100.96.5.32/27' }
                privateEndpoints = @{ name = 'snet-pe'; prefix = '100.96.5.64/26' }
            }
        }
        dnsZones = @{ subscriptionId = $sub; resourceGroup = 'network-rg'; zoneNames = @('privatelink.documents.azure.com') }
        identityNames = @('ccof-sync-b', 'ccof-reconciler-b')
        standby = @{ stagedConfigPath = 'absent-primary.json'; stagedStateDirectory = 'absent-primary-state'; stateDirectory = 'standby'
            nameSuffix = 'b'; functionsPublicNetworkAccess = 'Disabled'; storagePublicNetworkAccess = 'Disabled'
            apim = @{ publisherEmail = 'admin@example.invalid'; publisherName = 'Example'; sku = 'StandardV2' } }
    }
    $vnet = @{
        id = $vnetId; location = 'centralus'; addressSpace = @{ addressPrefixes = @('100.96.5.0/24') }
        virtualNetworkPeerings = @()
        subnets = @(
            @{ name = 'snet-apim'; addressPrefix = '100.96.5.0/27'; delegations = @(@{ serviceName = 'Microsoft.Web/serverFarms' }); networkSecurityGroup = @{ id = '/nsg/existing' } }
            @{ name = 'snet-functions'; addressPrefix = '100.96.5.32/27'; delegations = @(@{ serviceName = 'Microsoft.App/environments' }) }
            @{ name = 'snet-pe'; addressPrefix = '100.96.5.64/26'; delegations = @() }
            @{ name = 'unrelated-subnet'; addressPrefix = '100.96.5.192/27'; delegations = @() }
        )
    }
    $cfgPath = Join-Path $scratch 'config.json'
    $vnetPath = Join-Path $scratch 'vnet.json'
    $log = Join-Path $scratch 'az-calls.jsonl'
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    $vnet | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $vnetPath
    $env:DR_STUB_TENANT = $tenant; $env:DR_STUB_SUB = $sub; $env:DR_STUB_VNET_ID = $vnetId
    $env:DR_STUB_VNET = $vnetPath; $env:DR_STUB_LOG = $log; $env:DR_STUB_IDENTITIES = 'missing'
    function Run-Prerequisite([string]$Name, [string]$Case, [string]$DriverPhase, [bool]$ShouldApply, [bool]$ApproveVnetUpdate = $false) {
        $env:DR_STUB_CASE = $Case
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }
        $call = @('-NoProfile', '-File', $PSCommandPath, '-StubChild', '-ConfigPath', $cfgPath, '-EvidenceDirectory', (Join-Path $scratch $Name), '-Phase', $DriverPhase)
        if ($ShouldApply) { $call += '-Apply' }
        if ($ApproveVnetUpdate) { $call += '-ApproveExistingVnetUpdate' }
        $output = & pwsh @call 2>&1
        $code = $LASTEXITCODE
        $calls = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log | ForEach-Object { ,($_ | ConvertFrom-Json) }) } else { @() }
        return @{ code = $code; output = "$output"; calls = $calls }
    }

    $good = Run-Prerequisite 'bootstrap' 'good' 'Bootstrap' $true
    $goodCalls = @($good.calls | ForEach-Object { $_ -join ' ' })
    if ($good.code -ne 0 -or -not $goodCalls.Count) { Write-Host "Bootstrap diagnostic: exit $($good.code); $($good.output)" }
    Check 'Bootstrap succeeds with the existing VNet in a different resource group' ($good.code -eq 0)
    Check 'Bootstrap reads the exact existing VNet ID' (@($goodCalls | Where-Object { $_ -like "network vnet show --ids $vnetId*" }).Count -ge 1)
    Check 'Bootstrap deploys the identities-only template' (@($goodCalls | Where-Object { $_ -match 'deployment group create .*dr-existing-identities\.bicep' }).Count -eq 1)
    Check 'Bootstrap makes no direct network write' (@($goodCalls | Where-Object { $_ -match '^network .*\b(create|update|delete)\b' }).Count -eq 0)

    $env:DR_STUB_IDENTITIES = 'present'
    $repeat = Run-Prerequisite 'existing-identities' 'good' 'Bootstrap' $true
    $repeatCalls = @($repeat.calls | ForEach-Object { $_ -join ' ' })
    Check 'Bootstrap reuses already-created identities without deploying or changing them' ($repeat.code -eq 0 -and @($repeatCalls | Where-Object { $_ -match '^identity show ' }).Count -eq 2 -and @($repeatCalls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)
    $env:DR_STUB_IDENTITIES = 'one-missing'
    $partial = Run-Prerequisite 'one-missing-identity' 'good' 'Bootstrap' $true
    $partialCalls = @($partial.calls | ForEach-Object { $_ -join ' ' })
    $partialFile = @(Get-ChildItem -LiteralPath (Join-Path $scratch 'one-missing-identity') -Filter 'dr-bootstrap-*.parameters.json' -ErrorAction SilentlyContinue)
    $partialNames = @(if ($partialFile.Count -eq 1) { (Get-Content -LiteralPath $partialFile[0].FullName -Raw | ConvertFrom-Json).parameters.identityNames.value })
    if ($partial.code -ne 0 -or $partialNames.Count -ne 1 -or $partialNames[0] -cne 'ccof-reconciler-b') {
        Write-Host "Partial identity diagnostic: exit $($partial.code); names $($partialNames -join ','); $($partial.output)"
    }
    Check 'Bootstrap deploys only a missing identity and leaves the existing one out of the template' ($partial.code -eq 0 -and $partialNames.Count -eq 1 -and $partialNames[0] -ceq 'ccof-reconciler-b' -and @($partialCalls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 1)
    foreach ($case in @('wrong-location', 'wrong-id', 'missing-principal')) {
        $env:DR_STUB_IDENTITIES = $case
        $wrongIdentity = Run-Prerequisite "identity-$case" 'good' 'Bootstrap' $true
        $wrongIdentityCalls = @($wrongIdentity.calls | ForEach-Object { $_ -join ' ' })
        $reason = switch ($case) { 'wrong-location' { 'location' } 'wrong-id' { 'id_mismatch' } 'missing-principal' { 'principal' } }
        Check "Bootstrap refuses $case identity before deployment" ($wrongIdentity.code -ne 0 -and $wrongIdentity.output -match "identity:.*:$reason" -and @($wrongIdentityCalls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)
    }
    $env:DR_STUB_IDENTITIES = 'present'
    $verify = Run-Prerequisite 'verify' 'good' 'Verify' $false
    $verifyCalls = @($verify.calls | ForEach-Object { $_ -join ' ' })
    Check 'Verify reads the exact cross-resource-group VNet and accepts unrelated subnets' ($verify.code -eq 0 -and @($verifyCalls | Where-Object { $_ -like "network vnet show --ids $vnetId*" }).Count -ge 1)
    $config.standby.apim.sku = 'PremiumV2'
    $vnet.subnets[0].delegations[0].serviceName = 'Microsoft.ApiManagement/service'
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    $vnet | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $vnetPath
    $premium = Run-Prerequisite 'premium-delegation' 'good' 'Bootstrap' $true
    Check 'existing PremiumV2 network accepts its APIM-specific delegation' ($premium.code -eq 0)
    $vnet.subnets[0].delegations[0].serviceName = 'Microsoft.Web/serverFarms'
    $vnet | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $vnetPath
    $premiumWrong = Run-Prerequisite 'premium-wrong-delegation' 'good' 'Bootstrap' $true
    $premiumWrongCalls = @($premiumWrong.calls | ForEach-Object { $_ -join ' ' })
    Check 'existing PremiumV2 network refuses the StandardV2 delegation before deployment' ($premiumWrong.code -ne 0 -and $premiumWrong.output -match 'subnet:apim:delegation' -and @($premiumWrongCalls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)
    $config.standby.apim.sku = 'UnexpectedV2'
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    $unknownSku = Run-Prerequisite 'unknown-apim-sku' 'good' 'Bootstrap' $true
    $unknownSkuCalls = @($unknownSku.calls | ForEach-Object { $_ -join ' ' })
    Check 'existing network refuses an unknown APIM SKU before deployment' ($unknownSku.code -ne 0 -and $unknownSku.output -match 'subnet:apim:sku_invalid' -and @($unknownSkuCalls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)
    $config.standby.apim.sku = 'StandardV2'
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    $vnet.subnets[0].delegations[0].serviceName = 'Microsoft.ApiManagement/service'
    $vnet | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $vnetPath
    $standardWrong = Run-Prerequisite 'standard-wrong-delegation' 'good' 'Bootstrap' $true
    $standardWrongCalls = @($standardWrong.calls | ForEach-Object { $_ -join ' ' })
    Check 'existing StandardV2 network refuses the PremiumV2 delegation before deployment' ($standardWrong.code -ne 0 -and $standardWrong.output -match 'subnet:apim:delegation' -and @($standardWrongCalls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)
    $vnet.subnets[0].delegations[0].serviceName = 'Microsoft.Web/serverFarms'
    $vnet | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $vnetPath
    foreach ($case in @('plural-prefix', 'duplicate-prefix')) {
        $accepted = Run-Prerequisite "prefix-$case" $case 'Bootstrap' $true
        if ($accepted.code -ne 0) { Write-Host "Prefix diagnostic ($case): $($accepted.output)" }
        Check "Bootstrap accepts a matching single subnet prefix in $case form" ($accepted.code -eq 0)
    }
    $expectedBlockers = [ordered]@{
        'missing' = 'vnet:missing'; 'wrong-id' = 'vnet:id_mismatch'; 'wrong-location' = 'vnet:location_'
        'wrong-prefix' = 'subnet:apim:prefix'; 'wrong-delegation' = 'subnet:functions:delegation'
        'missing-dns-link' = 'dns:privatelink.documents.azure.com:link_missing'
        'multiple-prefixes' = 'subnet:apim:prefix'; 'missing-prefix' = 'subnet:apim:prefix'
    }
    foreach ($case in $expectedBlockers.Keys) {
        $bad = Run-Prerequisite $case $case 'Bootstrap' $true
        $badCalls = @($bad.calls | ForEach-Object { $_ -join ' ' })
        Check "Bootstrap refuses $case for the expected reason before any deployment" ($bad.code -ne 0 -and $bad.output.Contains($expectedBlockers[$case]) -and @($badCalls | Where-Object { $_ -like "network vnet show --ids $vnetId*" }).Count -ge 1 -and @($badCalls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)
    }

    $legacy = $config | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $legacy.secondary.Remove('networkMode'); $legacy.secondary.Remove('existingVnetId')
    $legacy.secondary.resourceGroup = 'network-rg'; $legacy.secondary.apimNsgName = 'legacy-apim-nsg'
    $legacy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    $unsafe = Run-Prerequisite 'legacy-existing' 'good' 'Bootstrap' $true
    $unsafeCalls = @($unsafe.calls | ForEach-Object { $_ -join ' ' })
    Check 'legacy create config refuses an existing VNet without explicit approval' ($unsafe.code -ne 0 -and $unsafe.output -match 'network_create_existing_vnet' -and @($unsafeCalls | Where-Object { $_ -match '^network vnet show ' }).Count -ge 1 -and @($unsafeCalls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)
    $new = Run-Prerequisite 'legacy-new' 'missing' 'Bootstrap' $true
    $newCalls = @($new.calls | ForEach-Object { $_ -join ' ' })
    Check 'legacy create mode can still create a new VNet' ($new.code -eq 0 -and @($newCalls | Where-Object { $_ -match '^deployment group create .*dr-prerequisites\.bicep' }).Count -eq 1)
    $approved = Run-Prerequisite 'legacy-approved' 'good' 'Bootstrap' $true $true
    $approvedCalls = @($approved.calls | ForEach-Object { $_ -join ' ' })
    Check 'legacy create mode updates an existing VNet only with explicit approval' ($approved.code -eq 0 -and @($approvedCalls | Where-Object { $_ -match '^deployment group create .*dr-prerequisites\.bicep' }).Count -eq 1)
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath

    $standby = Join-Path $root 'infra\dr\Invoke-DrStandby.ps1'
    $out = & pwsh -NoProfile -File $standby -Phase Network -ConfigPath $cfgPath -Apply 2>&1
    Check 'Network apply requires explicit approval before state or Azure access' ($LASTEXITCODE -eq 2 -and "$out" -match 'network_changes_approval_required')
    $out = & pwsh -NoProfile -File $standby -Phase Shells -ConfigPath $cfgPath -Apply 2>&1
    Check 'Shells apply requires approval for public APIM bootstrap' ($LASTEXITCODE -eq 2 -and "$out" -match 'public_apim_bootstrap_approval_required')
    $out = & pwsh -NoProfile -File $standby -Phase Network -ConfigPath $cfgPath -Apply -ApprovePrivateNetworkChanges 2>&1
    Check 'approved Network gets past the approval guard' ($LASTEXITCODE -eq 2 -and "$out" -match 'Not found:' -and "$out" -notmatch 'network_changes_approval_required')
    $out = & pwsh -NoProfile -File $standby -Phase Shells -ConfigPath $cfgPath -Apply -ApprovePublicApimBootstrap 2>&1
    Check 'approved Shells gets past the approval guard' ($LASTEXITCODE -eq 2 -and "$out" -match 'Not found:' -and "$out" -notmatch 'public_apim_bootstrap_approval_required')
    $legacy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    $out = & pwsh -NoProfile -File $standby -Phase Network -ConfigPath $cfgPath -Apply 2>&1
    Check 'create-mode Network also requires explicit network approval' ($LASTEXITCODE -eq 2 -and "$out" -match 'network_changes_approval_required')
    $out = & pwsh -NoProfile -File $standby -Phase Shells -ConfigPath $cfgPath -Apply 2>&1
    Check 'create-mode Shells also requires approval for public APIM bootstrap' ($LASTEXITCODE -eq 2 -and "$out" -match 'public_apim_bootstrap_approval_required')
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath

    # Execute the actual Shells driver with fixture state and a fake Azure CLI.
    $primaryCfg = Get-Content -LiteralPath (Join-Path $root 'infra\staged\staged.config.example.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $primaryCfg.tenantId = $tenant; $primaryCfg.subscriptionId = $sub; $primaryCfg.resourceGroup = 'workload-rg'
    $primaryCfg.network.existing = @{ functionsSubnetId = "$vnetId/subnets/snet-functions"; privateEndpointSubnetId = "$vnetId/subnets/snet-pe"; apimSubnetId = "$vnetId/subnets/snet-apim" }
    $primaryPath = Join-Path $scratch 'primary.json'
    $primaryCfg | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $primaryPath
    $primaryStateDir = Join-Path $scratch 'primary-state'; New-Item -ItemType Directory -Path $primaryStateDir | Out-Null
    $primaryS1 = @{ names = @{ deploymentPrefix = 'fixture'; apps = @{ resolver = @{ functionApp = 'fixture-resolver'; storageAccount = 'fixtureres' }; admin = @{ functionApp = 'fixture-admin' } } }
        cosmosAccountId = "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.DocumentDB/databaseAccounts/fixture"
        cosmosEndpoint = 'https://fixture.documents.azure.com'; workspaceId = "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.OperationalInsights/workspaces/fixture"
        workspaceCustomerId = '00000000-0000-4000-8000-000000000006'
        apimId = "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.ApiManagement/service/fixture-apim"; apimGatewayUrl = 'https://fixture-apim.azure-api.net' }
    $primaryState = @{ schemaVersion = 1; stageLayout = 2; target = @{ tenantId = $tenant; subscriptionId = $sub; resourceGroup = 'workload-rg' }
        stages = @{ '1' = @{ outputs = $primaryS1 }; '2' = @{ outputs = @{ marker = 'schema' } }; '4' = @{ outputs = @{ groups = @{} } } } }
    $primaryState | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Join-Path $primaryStateDir 'state.json')
    $shellCfg = $config | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $shellCfg.standby.stagedConfigPath = $primaryPath; $shellCfg.standby.stagedStateDirectory = $primaryStateDir
    $shellCfg.standby.stateDirectory = (Join-Path $scratch 'standby-state')
    $shellCfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    function Run-Shells([string]$ApimState, [bool]$ShouldApply = $true, [bool]$ApproveFunction = $false) {
        $env:DR_STUB_APIM = $ApimState; $env:DR_STUB_IDENTITIES = 'present'
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }
        $arguments = @('-NoProfile', '-File', $PSCommandPath, '-StubChild', '-StubStandby', '-ConfigPath', $cfgPath, '-Phase', 'Shells')
        if ($ShouldApply) { $arguments += '-Apply' }
        if ($ApproveFunction) { $arguments += '-ApprovePublicFunctionAccess' }
        $text = & pwsh @arguments 2>&1
        $code = $LASTEXITCODE
        $calls = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log | ForEach-Object { ,($_ | ConvertFrom-Json) }) } else { @() }
        return @{ code = $code; output = "$text"; calls = @($calls | ForEach-Object { $_ -join ' ' }) }
    }
    $shellCfg.standby.apim.sku = 'PremiumV2'
    $shellCfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    $unsupportedSku = Run-Shells 'absent'
    Check 'Shells refuses unsupported PremiumV2 before Azure access' ($unsupportedSku.code -ne 0 -and $unsupportedSku.output -match 'PremiumV2_not_supported_by_shells' -and @($unsupportedSku.calls).Count -eq 0)
    $shellCfg.standby.apim.sku = 'StandardV2'
    $shellCfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    foreach ($case in @('Disabled', 'unknown', 'forbidden')) {
        $r = Run-Shells $case
        if ($r.output -notmatch 'apim_|AuthorizationFailed') { Write-Host "Shells $case diagnostic: $($r.output)" }
        Check "Shells refuses $case APIM access before any deployment" ($r.code -ne 0 -and $r.output -match 'apim_|AuthorizationFailed' -and @($r.calls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)
    }
    foreach ($case in @('Enabled', 'absent')) {
        $r = Run-Shells $case
        Check "Shells reaches deployment for $case APIM" ($r.output -match 'test_sentinel_reached_deployment' -and @($r.calls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 1)
    }
    $createShellCfg = $shellCfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $createShellCfg.secondary.Remove('networkMode'); $createShellCfg.secondary.Remove('existingVnetId')
    $createShellCfg.secondary.apimNsgName = 'legacy-apim-nsg'
    $createShellCfg.standby.functionsPublicNetworkAccess = 'Enabled'
    $createShellCfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    $env:DR_STUB_FUNCTION = 'absent'
    $r = Run-Shells 'absent'
    Check 'create-mode public Function Apps require explicit approval' ($r.code -ne 0 -and $r.output -match 'public_function_access_approval_required' -and @($r.calls).Count -eq 0)
    foreach ($case in @('Disabled', 'unknown', 'forbidden')) {
        $env:DR_STUB_FUNCTION = $case
        $r = Run-Shells 'absent' $true $true
        Check "create-mode Shells refuses $case Function App before deployment" ($r.code -ne 0 -and $r.output -match 'function_public_access_guard|AuthorizationFailed' -and @($r.calls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)
    }
    foreach ($case in @('Enabled', 'absent')) {
        $env:DR_STUB_FUNCTION = $case
        $r = Run-Shells 'absent' $true $true
        Check "create-mode Shells permits approved $case Function App" ($r.output -match 'test_sentinel_reached_deployment' -and @($r.calls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 1)
    }
    Remove-Item -LiteralPath Env:DR_STUB_FUNCTION
    $shellCfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    Import-Module (Join-Path $root 'infra\dr\DrStandby.psm1') -Force
    $allPhases = @('Data', 'Shells', 'Grants', 'Config', 'Network', 'Code', 'Verify')
    $invalidatedBy = @{
        Data = @('Data', 'Verify'); Shells = @('Shells', 'Grants', 'Config', 'Network', 'Code', 'Verify')
        Grants = @('Grants', 'Config', 'Code', 'Verify'); Config = @('Config', 'Code', 'Verify')
        Network = @('Network', 'Code', 'Verify'); Code = @('Code', 'Verify'); Verify = @('Verify')
    }
    function New-PhaseEvidence {
        $p = @{}; $n = 0
        foreach ($name in $allPhases) {
            $p[$name] = @{ completedAt = ([DateTimeOffset]'2026-01-01T00:00:00Z').AddMinutes($n++).ToString('o'); outputs = @{} }
        }
        return @{ schema = 'ccof.dr.standby.v1'; phases = $p }
    }
    foreach ($phase in $allPhases) {
        $phaseState = New-PhaseEvidence
        try { $null = Clear-DrStandbyPhaseEvidence -State $phaseState -Phase $phase } catch { Write-Host "Invalidation diagnostic: $_" }
        $expectedLeft = @($allPhases | Where-Object { $invalidatedBy[$phase] -notcontains $_ } | Sort-Object)
        $actualLeft = @($phaseState.phases.Keys | Sort-Object)
        Check "$phase invalidates only its own and dependent standby phases" (($expectedLeft -join ',') -ceq ($actualLeft -join ','))
    }
    $shellCfg.frontDoor = @{ stem = 'fixture-edge' }
    $shellCfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    $standbyEvidencePath = Join-Path $shellCfg.standby.stateDirectory 'standby.state.json'
    $fdEvidencePath = Join-Path $shellCfg.standby.stateDirectory 'frontdoor-state.json'
    $fdEvidence = @{ stem = 'fixture-edge'; subscriptionId = $sub; resourceGroup = 'workload-rg'; profileName = 'fixture-edge-fd'; verifiedAt = '2026-01-01T00:07:00Z' }
    New-Item -ItemType Directory -Force -Path $shellCfg.standby.stateDirectory | Out-Null
    (New-PhaseEvidence) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $standbyEvidencePath
    $fdEvidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fdEvidencePath
    $beforeStandby = Get-Content -LiteralPath $standbyEvidencePath -Raw
    $beforeFd = Get-Content -LiteralPath $fdEvidencePath -Raw
    $null = Run-Shells 'absent' $false
    Check 'Shells preview leaves prior standby and Front Door verification unchanged' ((Get-Content -LiteralPath $standbyEvidencePath -Raw) -ceq $beforeStandby -and (Get-Content -LiteralPath $fdEvidencePath -Raw) -ceq $beforeFd)
    $failedShells = Run-Shells 'absent'
    $afterStandby = Get-Content -LiteralPath $standbyEvidencePath -Raw | ConvertFrom-Json -AsHashtable
    $afterFd = Get-Content -LiteralPath $fdEvidencePath -Raw | ConvertFrom-Json -AsHashtable
    Check 'failed Shells apply removes dependent readiness before deployment' ($failedShells.output -match 'test_sentinel_reached_deployment' -and ($afterStandby.phases.Keys -join ',') -ceq 'Data' -and -not $afterFd.Contains('verifiedAt'))
    (New-PhaseEvidence) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $standbyEvidencePath
    $fdEvidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fdEvidencePath
    $verifyFailure = & pwsh -NoProfile -File $PSCommandPath -StubChild -StubStandby -ConfigPath $cfgPath -Phase Verify 2>&1
    $verifyCode = $LASTEXITCODE
    $afterVerify = Get-Content -LiteralPath $standbyEvidencePath -Raw | ConvertFrom-Json -AsHashtable
    $afterFd = Get-Content -LiteralPath $fdEvidencePath -Raw | ConvertFrom-Json -AsHashtable
    Check 'failed standby Verify clears its old evidence and Front Door verification' ($verifyCode -ne 0 -and -not $afterVerify.phases.Contains('Verify') -and $afterVerify.phases.Contains('Code') -and -not $afterFd.Contains('verifiedAt') -and "$(Get-DrFrontDoorReadinessProblem $afterVerify)" -match 'frontdoor_standby_phase_missing: Verify')
    (New-PhaseEvidence) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $standbyEvidencePath
    $fdEvidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fdEvidencePath
    $beforeStandby = Get-Content -LiteralPath $standbyEvidencePath -Raw
    $beforeFd = Get-Content -LiteralPath $fdEvidencePath -Raw
    $fdLock = [IO.File]::Open((Join-Path $shellCfg.standby.stateDirectory 'frontdoor-state.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $lockedVerify = & pwsh -NoProfile -File $PSCommandPath -StubChild -StubStandby -ConfigPath $cfgPath -Phase Verify 2>&1; $lockedCode = $LASTEXITCODE } finally { $fdLock.Dispose() }
    $lockedText = ($lockedVerify -join "`n") -replace '\x1b\[[0-9;]*m|[\s|]', ''
    Check 'standby uses the shared Front Door state lock and changes nothing while another run holds it' ($lockedCode -ne 0 -and $lockedText -match 'frontdoor_state_locked' -and (Get-Content -LiteralPath $fdEvidencePath -Raw) -ceq $beforeFd -and (Get-Content -LiteralPath $standbyEvidencePath -Raw) -ceq $beforeStandby)
    Remove-Item -LiteralPath $standbyEvidencePath, $fdEvidencePath
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath

    Import-Module (Join-Path $root 'infra\dr\DrPrerequisites.psm1') -Force
    Import-Module (Join-Path $root 'infra\dr\DrStandby.psm1') -Force
    $frontDoor = Join-Path $root 'infra\dr\Invoke-DrFrontDoor.ps1'
    foreach ($phase in @('Deploy', 'DrainPrimary')) {
        $out = & pwsh -NoProfile -File $frontDoor -Phase $phase -ConfigPath 'missing.json' -Apply 2>&1
        Check "$phase refuses full Front Door activation without explicit readiness confirmation" ($LASTEXITCODE -ne 0 -and "$out" -match 'frontdoor_standby_confirmation_required')
    }
    $ready = @{ phases = @{
        Data = @{ completedAt = '2026-01-01T00:00:00Z' }; Shells = @{ completedAt = '2026-01-01T00:01:00Z' }
        Grants = @{ completedAt = '2026-01-01T00:02:00Z' }; Config = @{ completedAt = '2026-01-01T00:03:00Z' }
        Network = @{ completedAt = '2026-01-01T00:04:00Z' }; Code = @{ completedAt = '2026-01-01T00:05:00Z' }
        Verify = @{ completedAt = '2026-01-01T00:06:00Z' } } }
    $problem = try { Get-DrFrontDoorReadinessProblem $ready } catch { "missing readiness check: $_" }
    Check 'Front Door accepts complete standby phase evidence in order' ($null -eq $problem)
    $roundTrip = $ready | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    Check 'Front Door accepts timestamps parsed from the saved JSON state' ($null -eq (Get-DrFrontDoorReadinessProblem $roundTrip))
    $notReady = $ready | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $notReady.phases.Remove('Code')
    $problem = try { Get-DrFrontDoorReadinessProblem $notReady } catch { "missing readiness check: $_" }
    Check 'Front Door refuses missing Code phase evidence' ("$problem" -match 'frontdoor_standby_phase_missing.*Code')
    $notReady = $ready | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $notReady.phases.Verify.completedAt = '2026-01-01T00:04:00Z'
    $problem = try { Get-DrFrontDoorReadinessProblem $notReady } catch { "missing readiness check: $_" }
    Check 'Front Door refuses Verify evidence older than Code' ("$problem" -match 'frontdoor_standby_phase_stale.*Verify')
    $notReady.phases.Verify.completedAt = 'not-a-time'
    Check 'Front Door refuses an invalid phase completion timestamp' ("$(Get-DrFrontDoorReadinessProblem $notReady)" -match 'frontdoor_standby_phase_invalid.*Verify')
    $notReady.phases.Verify.completedAt = [DateTime]::SpecifyKind([DateTime]'2026-01-01T00:06:00', [DateTimeKind]::Unspecified)
    Check 'Front Door refuses a timestamp without a time zone' ("$(Get-DrFrontDoorReadinessProblem $notReady)" -match 'frontdoor_standby_phase_invalid.*Verify')
    Check 'RestorePrimary refuses a missing full Front Door deployment state' ("$(Get-DrFrontDoorPhaseProblem -Phase RestorePrimary -State $null)" -match 'frontdoor_deployment_required')
    Check 'RestorePrimary remains available with a full Front Door state even if standby is unhealthy' ($null -eq (Get-DrFrontDoorPhaseProblem -Phase RestorePrimary -State @{ mode = 'full' }))
    $fdTarget = @{ stem = 'fixture-edge'; subscriptionId = $sub; resourceGroup = 'workload-rg'; profileName = 'fixture-edge-fd'
        profileId = "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.Cdn/profiles/fixture-edge-fd" }
    $targetProblem = try { Get-DrFrontDoorTargetProblem -State $fdTarget -Stem 'fixture-edge' -SubscriptionId $sub -ResourceGroup 'workload-rg' } catch { "missing target guard: $_" }
    Check 'Front Door accepts a matching saved profile and stem' ($null -eq $targetProblem)
    $targetProblem = try { Get-DrFrontDoorTargetProblem -State $fdTarget -Stem 'fixture-edge-fd' -SubscriptionId $sub -ResourceGroup 'workload-rg' } catch { "missing target guard: $_" }
    Check 'Front Door refuses a full profile name entered as the stem' ("$targetProblem" -match 'frontdoor_target_mismatch')
    $wrongFdTarget = $fdTarget.Clone(); $wrongFdTarget.profileId = $wrongFdTarget.profileId -replace 'workload-rg', 'other-rg'
    $targetProblem = try { Get-DrFrontDoorTargetProblem -State $wrongFdTarget -Stem 'fixture-edge' -SubscriptionId $sub -ResourceGroup 'workload-rg' } catch { "missing target guard: $_" }
    Check 'Front Door refuses a saved profile in a different resource group' ("$targetProblem" -match 'frontdoor_target_mismatch')
    $wrongFdTarget = $fdTarget.Clone(); $wrongFdTarget.subscriptionId = '00000000-0000-4000-8000-000000000099'
    $targetProblem = Get-DrFrontDoorTargetProblem -State $wrongFdTarget -Stem 'fixture-edge' -SubscriptionId $sub -ResourceGroup 'workload-rg'
    Check 'Front Door refuses a saved profile in a different subscription' ("$targetProblem" -match 'frontdoor_target_mismatch')
    $targetProblem = Get-DrFrontDoorTargetProblem -State @{ profileId = $fdTarget.profileId } -Stem 'fixture-edge' -SubscriptionId $sub -ResourceGroup 'workload-rg'
    Check 'Front Door accepts a complete matching saved profile ID' ($null -eq $targetProblem)
    $targetProblem = Get-DrFrontDoorTargetProblem -State @{ stem = 'fixture-edge' } -Stem 'fixture-edge' -SubscriptionId $sub -ResourceGroup 'workload-rg'
    Check 'Front Door refuses incomplete saved target identity' ("$targetProblem" -match 'frontdoor_target_unknown')
    $previousApprovals = @('first-connection', 'second-connection')
    $movedState = Set-DrFrontDoorStateMode -State @{ mode = 'primaryOnly'; approvedConnections = $previousApprovals; verifiedAt = 'old' } -Mode 'full'
    Check 'Front Door mode change retains prior connection IDs only for rechecking' (@($movedState.previousApprovedConnections).Count -eq 2 -and -not $movedState.Contains('approvedConnections') -and -not $movedState.Contains('verifiedAt'))
    $shellCfg.frontDoor = @{ stem = 'fixture-fd'; wafMode = 'Detection'; probeIntervalSeconds = 30 }
    $shellCfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath
    $bState = @{ stages = @{ '1' = @{ outputs = @{
        apimId = "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.ApiManagement/service/fixture-b-apim"
        apimGatewayUrl = 'https://fixture-b-apim.azure-api.net'; names = @{ apps = @{ admin = @{ functionApp = 'fixture-b-admin' } } }
    } } } }
    $bState | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $shellCfg.standby.stateDirectory 'state.json')
    function Run-FrontDoor([string]$DriverPhase = 'Deploy', [string]$Reviewed = '') {
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }
        $reviewedArgs = if ($Reviewed) { @('-ReviewedConnectionIds', $Reviewed) } else { @() }
        $text = & pwsh -NoProfile -File $PSCommandPath -StubChild -StubFrontDoor -ConfigPath $cfgPath -Phase $DriverPhase -Apply @reviewedArgs 2>&1
        $code = $LASTEXITCODE
        $calls = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log | ForEach-Object { ,($_ | ConvertFrom-Json) }) } else { @() }
        return @{ code = $code; output = "$text"; flat = ("$text" -replace '\x1b\[[0-9;]*m|[\s|]', ''); calls = @($calls | ForEach-Object { $_ -join ' ' }) }
    }
    $fd = Run-FrontDoor
    Check 'actual Front Door deployment refuses absent standby phase evidence' ($fd.code -ne 0 -and $fd.output -match 'frontdoor_standby_phase_missing.*Data' -and @($fd.calls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)
    $ready | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $shellCfg.standby.stateDirectory 'standby.state.json')
    $statePath = Join-Path $shellCfg.standby.stateDirectory 'frontdoor-state.json'
    @{ mode = 'primaryOnly'; stem = 'different'; profileName = 'different-fd'; subscriptionId = $sub; resourceGroup = 'workload-rg' } |
        ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath
    $fd = Run-FrontDoor
    Check 'actual Front Door deployment refuses a changed profile target before Azure calls' ($fd.code -ne 0 -and $fd.output -match 'frontdoor_target_mismatch' -and @($fd.calls).Count -eq 0)
    @{ mode = 'primaryOnly'; stem = 'fixture-fd' } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath
    $fd = Run-FrontDoor
    Check 'actual Front Door deployment refuses incomplete saved target before Azure calls' ($fd.code -ne 0 -and $fd.output -match 'frontdoor_target_unknown' -and @($fd.calls).Count -eq 0)
    Remove-Item -LiteralPath $statePath
    $fd = Run-FrontDoor
    if ($fd.output -notmatch 'test_sentinel_reached_deployment') { Write-Host "Front Door ready diagnostic: $($fd.output)" }
    Check 'actual Front Door deployment reaches the template only with complete evidence and confirmation' ($fd.output -match 'test_sentinel_reached_deployment' -and @($fd.calls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 1)

    $aApimId = $primaryS1.apimId
    $bApimId = $bState.stages['1'].outputs.apimId
    $aAdminId = "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.Web/sites/fixture-admin"
    $bAdminId = "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.Web/sites/fixture-b-admin"
    $fdIds = @($aApimId, $bApimId, $aAdminId, $bAdminId)
    $connectionIds = @($fdIds | ForEach-Object { "$_/privateEndpointConnections/fixture" })
    $requests = @('CCOF Front Door origin primary-gateway', 'CCOF Front Door origin standby-gateway',
        'CCOF Front Door admin origin primary-admin', 'CCOF Front Door admin origin standby-admin')
    $connections = @(for ($i = 0; $i -lt 4; $i++) {
        @{ id = $connectionIds[$i]; name = 'fixture'; properties = @{ privateEndpoint = @{ id = "/privateEndpoints/$i" }
            privateLinkServiceConnectionState = @{ status = $(if ($i -in 0, 2) { 'Approved' } else { 'Pending' })
                description = $(if ($i -in 0, 2) { 'Approved CCOF Front Door origin' } else { $requests[$i] }) } } }
    })
    $env:DR_STUB_FD_CONNECTIONS = Join-Path $scratch 'fd-connections.json'
    $connections | ConvertTo-Json -Depth 30 -AsArray | Set-Content -LiteralPath $env:DR_STUB_FD_CONNECTIONS
    $fdState = @{ mode = 'full'; stem = 'fixture-fd'; subscriptionId = $sub; resourceGroup = 'workload-rg'
        profileName = 'fixture-fd-fd'; profileId = "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.Cdn/profiles/fixture-fd-fd"
        apimIds = @($aApimId, $bApimId); adminSiteIds = @($aAdminId, $bAdminId)
        previousApprovedConnections = @($connectionIds[2]); reviewedConnections = @($connectionIds[0], $connectionIds[2]); verifiedAt = 'old' }
    $fdState | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $statePath
    $reviewedB = "$($connectionIds[1]),$($connectionIds[3])"
    $fd = Run-FrontDoor 'Approve' $reviewedB
    Check 'Front Door refuses an unrecognized generic prior approval before approving anything' ($fd.code -ne 0 -and $fd.flat -match "frontdoor_review_ids_required:[^.]*$([regex]::Escape($aApimId))\." -and @($fd.calls | Where-Object { $_ -match '^network private-endpoint-connection approve ' }).Count -eq 0)
    $fd = Run-FrontDoor 'Approve' "$($connectionIds[0]),$reviewedB"
    Check 'Front Door refuses to adopt a generic prior approval as a reviewed request' ($fd.code -ne 0 -and $fd.flat -match "frontdoor_review_id_mismatch:$([regex]::Escape($connectionIds[0]))isabsent" -and @($fd.calls | Where-Object { $_ -match '^network private-endpoint-connection approve ' }).Count -eq 0)
    $fdState.previousApprovedConnections = @($connectionIds[0], $connectionIds[2])
    $fdState | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $statePath
    $fd = Run-FrontDoor 'Approve' $reviewedB
    $fdAfter = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    $approvalCalls = @($fd.calls | Where-Object { $_ -match '^network private-endpoint-connection approve ' })
    if ($fd.code -ne 0) { Write-Host "Front Door approval diagnostic: $($fd.output)" }
    Check 'full Front Door approval rechecks primary IDs and approves the two standby origins' ($fd.code -eq 0 -and @($fdAfter.approvedConnections).Count -eq 4 -and $approvalCalls.Count -eq 2)
    Check 'Front Door approval invalidates prior route verification' ($fd.code -eq 0 -and -not $fdAfter.Contains('verifiedAt'))
    $afterConnections = @(Get-Content -LiteralPath $env:DR_STUB_FD_CONNECTIONS -Raw | ConvertFrom-Json -AsHashtable -Depth 30)
    Check 'new Front Door approvals preserve the original request descriptions' ($afterConnections[1].properties.privateLinkServiceConnectionState.status -ceq 'Approved' -and $afterConnections[1].properties.privateLinkServiceConnectionState.description -ceq $requests[1] -and $afterConnections[3].properties.privateLinkServiceConnectionState.status -ceq 'Approved' -and $afterConnections[3].properties.privateLinkServiceConnectionState.description -ceq $requests[3])
    $fd = Run-FrontDoor 'Approve'
    Check 'Front Door approval can be safely repeated without approving again' ($fd.code -eq 0 -and @($fd.calls | Where-Object { $_ -match '^network private-endpoint-connection approve ' }).Count -eq 0)
    $duplicates = @($afterConnections)
    $duplicates += @{ id = "$aApimId/privateEndpointConnections/other"; properties = @{ privateEndpoint = @{ id = '/privateEndpoints/other' }; privateLinkServiceConnectionState = @{ status = 'Approved'; description = $requests[0] } } }
    $duplicates | ConvertTo-Json -Depth 30 -AsArray | Set-Content -LiteralPath $env:DR_STUB_FD_CONNECTIONS
    $fd = Run-FrontDoor 'Approve'
    $fdAfter = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    Check 'Front Door keeps exact saved IDs and never adopts a same-description duplicate' ($fd.code -eq 0 -and @($fdAfter.approvedConnections).Count -eq 4 -and @($fdAfter.approvedConnections | Where-Object { $_ -match '/other$' }).Count -eq 0 -and @($fd.calls | Where-Object { $_ -match '^network private-endpoint-connection approve ' }).Count -eq 0)
    $duplicates = @($connections)
    $duplicates += @{ id = "$bApimId/privateEndpointConnections/other"; properties = @{ privateEndpoint = @{ id = '/privateEndpoints/other' }; privateLinkServiceConnectionState = @{ status = 'Pending'; description = $requests[1] } } }
    $duplicates | ConvertTo-Json -Depth 30 -AsArray | Set-Content -LiteralPath $env:DR_STUB_FD_CONNECTIONS
    $fdState | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $statePath
    $fd = Run-FrontDoor 'Approve' "$reviewedB,$bApimId/privateEndpointConnections/other"
    Check 'Front Door refuses an ambiguous origin when all four origins exist' ($fd.code -ne 0 -and $fd.flat -match "frontdoor_review_ids_required:[^.]*$([regex]::Escape($bApimId))\." -and @($fd.calls | Where-Object { $_ -match '^network private-endpoint-connection approve ' }).Count -eq 0)
    $connections | ConvertTo-Json -Depth 30 -AsArray | Set-Content -LiteralPath $env:DR_STUB_FD_CONNECTIONS
    $fdState | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $statePath
    $env:DR_STUB_FD_NO_APPROVE = '1'
    $fd = Run-FrontDoor 'Approve' $reviewedB
    $fdAfter = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    Check 'Front Door refuses approval success until the target reads back Approved' ($fd.code -ne 0 -and $fd.output -match 'frontdoor_connection_not_approved' -and -not $fdAfter.Contains('approvedConnections'))
    Remove-Item -LiteralPath Env:DR_STUB_FD_NO_APPROVE
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cfgPath

    $c = $config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $chosen = try { Get-DrSecondaryVnetId $c } catch { "ERROR: $($_.Exception.Message)" }
    Check 'standby selects the configured VNet ID, not the workload resource group' ($chosen -ceq $vnetId)
    $c.secondary.networkMode = 'create'; $c.secondary.PSObject.Properties.Remove('existingVnetId')
    $chosen = try { Get-DrSecondaryVnetId $c } catch { "ERROR: $($_.Exception.Message)" }
    Check 'legacy create mode keeps the workload resource group' ($chosen -ceq "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.Network/virtualNetworks/dr-vnet")

    $apps = @(
        @{ name = 'example-resolver'; host = 'example-resolver.azurewebsites.net'; endpointAddresses = @('100.96.5.65') }
        @{ name = 'example-admin'; host = 'example-admin.azurewebsites.net'; endpointAddresses = @('100.96.5.65') }
    )
    $private = { param($name) @('100.96.5.65') }
    $mixed = { param($name) @('100.96.5.65', '198.51.100.8') }
    $none = { param($name) @() }
    $online = { param($name) $true }
    $offline = { param($name) $false }
    $privateArgs = @{ Apps = $apps; EndpointSubnetPrefix = '100.96.5.64/26'; Resolve = $private; Connect = $online }
    $problems = try { @(Get-DrPrivatePublisherProblems @privateArgs) } catch { @("ERROR: $($_.Exception.Message)") }
    Check 'private publisher accepts a reachable endpoint in a CGNAT subnet' ($problems.Count -eq 0)
    $privateArgs.Resolve = $mixed
    $problems = try { @(Get-DrPrivatePublisherProblems @privateArgs) } catch { @("ERROR: $($_.Exception.Message)") }
    Check 'private publisher refuses mixed private and public DNS answers' (($problems -join ',') -match 'dns_outside_endpoint_subnet')
    $privateArgs.Resolve = $none
    $problems = try { @(Get-DrPrivatePublisherProblems @privateArgs) } catch { @("ERROR: $($_.Exception.Message)") }
    Check 'private publisher refuses empty DNS answers' (($problems -join ',') -match 'dns_empty')
    $privateArgs.Resolve = $private; $privateArgs.Connect = $offline
    $problems = try { @(Get-DrPrivatePublisherProblems @privateArgs) } catch { @("ERROR: $($_.Exception.Message)") }
    Check 'private publisher refuses an unreachable SCM endpoint' (($problems -join ',') -match 'scm_unreachable')
    $matchedApps = @(@{ name = 'example-resolver'; host = 'example-resolver.azurewebsites.net'; endpointAddresses = @('100.96.5.65') })
    $otherEndpoint = { param($name) @('100.96.5.66') }
    $problems = try { @(Get-DrPrivatePublisherProblems -Apps $matchedApps -EndpointSubnetPrefix '100.96.5.64/26' -Resolve $otherEndpoint -Connect $online) } catch { @("ERROR: $($_.Exception.Message)") }
    Check 'private publisher refuses a different endpoint IP even inside the same subnet' (($problems -join ',') -match 'dns_endpoint_mismatch')
    $noEndpointApps = @(@{ name = 'example-resolver'; host = 'example-resolver.azurewebsites.net' })
    $problems = try { @(Get-DrPrivatePublisherProblems -Apps $noEndpointApps -EndpointSubnetPrefix '100.96.5.64/26' -Resolve $private -Connect $online) } catch { @("ERROR: $($_.Exception.Message)") }
    Check 'private publisher refuses an app without verified endpoint addresses' (($problems -join ',') -match 'endpoint_unverified')

    $siteId = "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.Web/sites/example-resolver"
    $endpointId = "/subscriptions/$sub/resourceGroups/network-rg/providers/Microsoft.Network/privateEndpoints/resolver-pe"
    $nicId = "/subscriptions/$sub/resourceGroups/network-rg/providers/Microsoft.Network/networkInterfaces/resolver-pe-nic"
    $endpointSubnetId = "$vnetId/subnets/snet-pe"
    $script:endpointConnection = @{ properties = @{ privateEndpoint = @{ id = $endpointId }; privateLinkServiceConnectionState = @{ status = 'Approved' } } }
    $script:endpointResource = @{ id = $endpointId; properties = @{ provisioningState = 'Succeeded'; subnet = @{ id = $endpointSubnetId }
        privateLinkServiceConnections = @(@{ properties = @{ privateLinkServiceId = $siteId; groupIds = @('sites'); privateLinkServiceConnectionState = @{ status = 'Approved' } } })
        networkInterfaces = @(@{ id = $nicId }) } }
    $script:endpointNic = @{ id = $nicId; properties = @{ ipConfigurations = @(@{ properties = @{ privateIPAddress = '100.96.5.65' } }) } }
    $listConnections = { param($id) @($script:endpointConnection) }
    $readEndpointResource = { param($id) if ($id -ieq $endpointId) { $script:endpointResource } elseif ($id -ieq $nicId) { $script:endpointNic } else { throw "unexpected resource $id" } }
    $endpointArgs = @{ SiteId = $siteId; SubnetId = $endpointSubnetId; ListConnections = $listConnections; ReadResource = $readEndpointResource }
    $ips = @(try { Get-DrPrivateAppEndpointAddresses @endpointArgs } catch { "ERROR: $($_.Exception.Message)" })
    if ($ips.Count -ne 1 -or $ips[0] -cne '100.96.5.65') { Write-Host "private endpoint fixture: $($ips -join ', ')" }
    Check 'private publisher discovers the approved sites endpoint NIC IP for the exact app' ($ips.Count -eq 1 -and $ips[0] -ceq '100.96.5.65')
    $script:endpointConnection.properties.privateLinkServiceConnectionState.status = 'Pending'
    $errorText = try { $null = Get-DrPrivateAppEndpointAddresses @endpointArgs; '' } catch { "$_" }
    Check 'private publisher refuses a pending app endpoint' ($errorText -match 'private_endpoint_not_verified')
    $script:endpointConnection.properties.privateLinkServiceConnectionState.status = 'Approved'
    $script:endpointResource.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId = "$siteId-other"
    $errorText = try { $null = Get-DrPrivateAppEndpointAddresses @endpointArgs; '' } catch { "$_" }
    Check 'private publisher refuses an endpoint for another app' ($errorText -match 'private_endpoint_not_verified')
    $script:endpointResource.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId = $siteId
    $script:endpointResource.properties.subnet.id = "$endpointSubnetId-other"
    $errorText = try { $null = Get-DrPrivateAppEndpointAddresses @endpointArgs; '' } catch { "$_" }
    Check 'private publisher refuses an endpoint on another subnet' ($errorText -match 'private_endpoint_not_verified')
    $script:endpointResource.properties.subnet.id = $endpointSubnetId; $script:endpointNic.properties.ipConfigurations = @()
    $errorText = try { $null = Get-DrPrivateAppEndpointAddresses @endpointArgs; '' } catch { "$_" }
    Check 'private publisher refuses an endpoint with no NIC addresses' ($errorText -match 'private_endpoint_not_verified')
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
    foreach ($name in 'DR_STUB_TENANT', 'DR_STUB_SUB', 'DR_STUB_VNET_ID', 'DR_STUB_VNET', 'DR_STUB_LOG', 'DR_STUB_CASE', 'DR_STUB_IDENTITIES', 'DR_STUB_APIM', 'DR_STUB_FUNCTION', 'DR_STUB_FD_CONNECTIONS', 'DR_STUB_FD_NO_APPROVE') {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

Write-Host "Test-DrExistingNetwork: $script:passed passed, $script:failed failed"
if ($script:failed -gt 0 -or $script:passed -lt 73) { exit 1 }
