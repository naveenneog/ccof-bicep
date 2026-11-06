# Offline Stage 6 and DR Network tests: DNS targets and partial-apply retries.
#Requires -Version 7.0
param([switch]$Child, [switch]$PreviewRun, [ValidateSet('standby', 'primary')] [string]$Mode = 'standby', [string]$ConfigPath, [string]$StateDirectory)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($Child) {
    function global:az {
        $arguments = @($args)
        Add-Content -LiteralPath $env:DR_NETWORK_LOG -Value ($arguments | ConvertTo-Json -Compress)
        $global:LASTEXITCODE = 0
        $command = $arguments -join ' '
        $fixture = Get-Content -LiteralPath $env:DR_NETWORK_FIXTURE -Raw | ConvertFrom-Json -AsHashtable -Depth 50
        if ($command -match '^deployment group what-if ') { return '{"changes":[]}' }
        if ($command -match '^deployment group create ') {
            if ($command -notmatch '--mode Incremental') { throw 'Fixture requires an incremental deployment.' }
            $file = $arguments[[Array]::IndexOf($arguments, '--parameters') + 1].Substring(1)
            $p = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -Depth 100).parameters
            $network = $p.network.value.existing
            $names = $p.names.value
            $suffix = if ($p.endpointNameSuffix) { $p.endpointNameSuffix.value } else { '' }
            $endpointPrefix = "$($fixture.resourcePrefix)/providers/Microsoft.Network/privateEndpoints"
            $storageIds = @($names.apps.Values | ForEach-Object { "$endpointPrefix/$($_.storageAccount)-blob-pe$suffix" })
            $cosmosId = "$endpointPrefix/$($names.cosmosAccount)-sql-pe$suffix"
            $foundryAccounts = @($p.foundryAccounts.value | Where-Object { $_ })
            $foundryIds = @($foundryAccounts | ForEach-Object { "$endpointPrefix/$_-account-pe$suffix" })
            foreach ($id in @($storageIds) + @($cosmosId) + @($foundryIds)) {
                if ($fixture.endpoints -notcontains $id) { $fixture.endpoints += $id; $fixture.createdEndpoints++ }
            }
            $fixture.deploymentCount++
            $fixture.parameterSnapshots += ($p | ConvertTo-Json -Depth 100 -Compress)
            $fixture | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $env:DR_NETWORK_FIXTURE -Encoding utf8NoBOM
            # Also model older deployment outputs containing unused Foundry IDs, as a partial retry may encounter.
            $outputs = @{
                vnetId = $fixture.vnetId
                functionsSubnetId = $network.functionsSubnetId
                privateEndpointSubnetId = $network.privateEndpointSubnetId
                apimSubnetId = $network.apimSubnetId
                storagePrivateEndpointIds = $storageIds
                cosmosPrivateEndpointId = $cosmosId
                foundryPrivateEndpointIds = $foundryIds
                foundryPrivateDnsZoneIds = @($fixture.reportedFoundryZones)
                privateDnsZoneIds = @{ cosmos = $fixture.outputCosmosZone; blob = $fixture.outputBlobZone }
            }
            $wrapped = @{}; foreach ($key in $outputs.Keys) { $wrapped[$key] = @{ value = $outputs[$key] } }
            return (@{ properties = @{ provisioningState = 'Succeeded'; duration = 'PT1S'; outputs = $wrapped } } | ConvertTo-Json -Depth 50 -Compress)
        }
        if ($command -match '^functionapp show ') {
            $name = $arguments[[Array]::IndexOf($arguments, '--name') + 1]
            return (@{ name = $name; properties = @{ virtualNetworkSubnetId = $fixture.functionsSubnetId; publicNetworkAccess = 'Disabled' } } | ConvertTo-Json -Depth 10 -Compress)
        }
        if ($command -match '^functionapp config show ') { return '{"ftpsState":"Disabled"}' }
        if ($command -match '^rest --method get ') {
            $url = $arguments[[Array]::IndexOf($arguments, '--url') + 1]
            $path = ([Uri]$url).AbsolutePath
            if ($path -match '/providers/Microsoft.ApiManagement/service/[^/]+$') {
                return (@{
                    id = $path; name = ($path -split '/')[-1]; sku = @{ name = 'StandardV2' }
                    identity = @{ type = 'SystemAssigned'; principalId = $fixture.apimPrincipalId }
                    properties = @{ provisioningState = 'Succeeded'; virtualNetworkType = 'External'
                        virtualNetworkConfiguration = @{ subnetResourceId = $fixture.apimSubnetId }; publicNetworkAccess = 'Enabled' }
                } | ConvertTo-Json -Depth 10 -Compress)
            }
            if ($path -match '^(.*?/privateDnsZones/[^/]+)/virtualNetworkLinks$') {
                $zone = $Matches[1]
                if ($fixture.deniedZones -contains $zone) {
                    $global:LASTEXITCODE = 3
                    [Console]::Error.WriteLine("ERROR: (AuthorizationFailed) cannot read private DNS zone $zone")
                    return
                }
                if ($fixture.unavailableZones -contains $zone) {
                    $global:LASTEXITCODE = 3
                    [Console]::Error.WriteLine("ERROR: (ResourceNotFound) private DNS zone $zone does not exist")
                    return
                }
                if ($zone -notin (@($fixture.cosmosZone, $fixture.blobZone) + @($fixture.foundryZones))) { throw "Unexpected DNS zone: $zone" }
                return (@{ value = @(@{ properties = @{ virtualNetwork = @{ id = $fixture.vnetId }; registrationEnabled = $false } }) } | ConvertTo-Json -Depth 10 -Compress)
            }
            if ($path -match '/privateEndpoints/[^/]+/privateDnsZoneGroups/default$') {
                return '{"properties":{"privateDnsZoneConfigs":[{"properties":{"recordSets":[{"fqdn":"fixture.internal","ipAddresses":["10.80.0.10"]}]}}]}}'
            }
            if ($path -match '/privateEndpoints/[^/]+$') {
                if ($fixture.endpoints -notcontains $path) { throw "Unexpected endpoint: $path" }
                return (@{ name = ($path -split '/')[-1]; properties = @{ privateLinkServiceConnections = @(@{ properties = @{ privateLinkServiceConnectionState = @{ status = 'Approved' } } }) } } | ConvertTo-Json -Depth 10 -Compress)
            }
        }
        throw "Unexpected az call in offline network test: $command"
    }
    if ($Mode -eq 'standby') {
        & (Join-Path $root 'infra\dr\Invoke-DrStandby.ps1') -Phase Network -ConfigPath $ConfigPath -Apply:(-not $PreviewRun) -ApprovePrivateNetworkChanges:(-not $PreviewRun)
    } else {
        & (Join-Path $root 'infra\staged\Invoke-StagedDeployment.ps1') -Stage 6 -ConfigPath $ConfigPath -StateDirectory $StateDirectory -Apply:(-not $PreviewRun)
    }
    exit $LASTEXITCODE
}

$script:passed = 0; $script:failed = 0
. (Join-Path $root 'infra\staged\Staged.Common.ps1')
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $Name" -ForegroundColor Red }
}
$scratch = Join-Path $root ".env.public-test-scratch\dr-network-dns-$PID"
if (Test-Path -LiteralPath $scratch) { throw "Fixture path already exists: $scratch" }
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $sub = '00000000-0000-4000-8000-000000000002'
    $tenant = '00000000-0000-4000-8000-000000000001'
    $resourcePrefix = "/subscriptions/$sub/resourceGroups/fixture-rg"
    $vnetId = "/subscriptions/$sub/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/fixture-vnet"
    $zonePrefix = "/subscriptions/$sub/resourceGroups/network-rg/providers/Microsoft.Network/privateDnsZones"
    $cosmosZone = "$zonePrefix/privatelink.documents.azure.com"
    $blobZone = "$zonePrefix/privatelink.blob.core.windows.net"
    $foundryZones = @("$zonePrefix/privatelink.cognitiveservices.azure.com", "$zonePrefix/privatelink.openai.azure.com", "$zonePrefix/privatelink.services.ai.azure.com")
    $functionsSubnet = "$vnetId/subnets/functions"; $apimSubnet = "$vnetId/subnets/apim"
    $apimPrincipal = '00000000-0000-4000-8000-000000000003'
    $primaryPath = Join-Path $scratch 'primary.json'
    $primaryStateDir = Join-Path $scratch 'primary-state'
    $standbyDir = Join-Path $scratch 'standby'
    New-Item -ItemType Directory -Path $primaryStateDir, $standbyDir | Out-Null
    $primary = Get-Content -LiteralPath (Join-Path $root 'infra\staged\staged.config.example.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $primary.tenantId = $tenant; $primary.subscriptionId = $sub; $primary.resourceGroup = 'fixture-rg'
    $primary.backends[0].privateEndpoint = $false
    $primary.network.mode = 'existing'
    $primary.network.existing = @{
        functionsSubnetId = $functionsSubnet; privateEndpointSubnetId = "$vnetId/subnets/private-endpoints"
        apimSubnetId = $apimSubnet; privateDnsZoneIds = @{ cosmos = $cosmosZone; blob = $blobZone }
    }
    $primaryS1 = @{
        names = @{ deploymentPrefix = 'fixture'; cosmosAccount = 'fixture-cosmos'; logAnalyticsWorkspace = 'fixture-workspace'
            apps = @{ resolver = @{ functionApp = 'fixture-resolver'; storageAccount = 'fixtureres' } } }
        cosmosAccountId = "$resourcePrefix/providers/Microsoft.DocumentDB/databaseAccounts/fixture-cosmos"
        apimId = "$resourcePrefix/providers/Microsoft.ApiManagement/service/fixture-apim"
        apimName = 'fixture-apim'; apimPrincipalId = $apimPrincipal
    }
    $standbyS1 = @{
        names = @{ deploymentPrefix = 'fixtureb'; cosmosAccount = 'fixture-cosmos'; logAnalyticsWorkspace = 'fixture-workspace'
            apps = @{ resolver = @{ functionApp = 'fixture-b-resolver'; storageAccount = 'fixturebres' } } }
        apimId = "$resourcePrefix/providers/Microsoft.ApiManagement/service/fixture-b-apim"
        apimName = 'fixture-b-apim'; apimPrincipalId = $apimPrincipal
    }
    $dr = @{
        tenantId = $tenant; subscriptionId = $sub; tags = @{ workload = 'fixture' }
        primary = @{ location = 'eastus2'; addressSpaces = @('10.40.0.0/16'); peer = $false }
        secondary = @{ location = 'westus2'; resourceGroup = 'fixture-rg'; vnetName = 'fixture-vnet'
            networkMode = 'existing'; existingVnetId = $vnetId; addressSpace = '10.80.0.0/24'
            subnets = @{ apim = @{ name = 'apim'; prefix = '10.80.0.0/27' }; functions = @{ name = 'functions'; prefix = '10.80.0.32/27' }
                privateEndpoints = @{ name = 'private-endpoints'; prefix = '10.80.0.64/26' } } }
        dnsZones = @{ subscriptionId = $sub; resourceGroup = 'network-rg'; zoneNames = @('privatelink.documents.azure.com', 'privatelink.blob.core.windows.net') }
        standby = @{ stagedConfigPath = $primaryPath; stagedStateDirectory = $primaryStateDir; stateDirectory = $standbyDir
            nameSuffix = 'b'; functionsPublicNetworkAccess = 'Disabled'; storagePublicNetworkAccess = 'Disabled'
            apim = @{ publisherEmail = 'admin@example.invalid'; publisherName = 'Example'; sku = 'StandardV2' } }
        cosmos = @{ convertServerless = $false; autoscaleMaxThroughput = 1000 }
    }
    $drPath = Join-Path $scratch 'dr.json'
    $dr | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $drPath
    $env:DR_NETWORK_LOG = Join-Path $scratch 'az.log'
    $env:DR_NETWORK_FIXTURE = Join-Path $scratch 'fixture.json'
    function Save-Primary {
        $primary | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $primaryPath
        @{ stageLayout = 2; stages = @{ '1' = @{ outputs = $primaryS1 }; '2' = @{ outputs = @{ marker = 'schema' } }; '4' = @{ outputs = @{ groups = @{} } } } } |
            ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $primaryStateDir 'state.json')
    }
    function Reset-Fixture([string[]]$UnavailableZones, [string[]]$Endpoints = @()) {
        @{ resourcePrefix = $resourcePrefix; vnetId = $vnetId; functionsSubnetId = $functionsSubnet; apimSubnetId = $apimSubnet
            apimPrincipalId = $apimPrincipal; cosmosZone = $cosmosZone; blobZone = $blobZone; foundryZones = $foundryZones
            outputCosmosZone = $cosmosZone; outputBlobZone = $blobZone
            reportedFoundryZones = $foundryZones; deniedZones = @(); unavailableZones = $UnavailableZones
            endpoints = $Endpoints; createdEndpoints = 0; deploymentCount = 0; parameterSnapshots = @() } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env:DR_NETWORK_FIXTURE
    }
    function Change-Fixture($Changes) {
        $fixture = Get-Content -LiteralPath $env:DR_NETWORK_FIXTURE -Raw | ConvertFrom-Json -AsHashtable -Depth 50
        foreach ($key in $Changes.Keys) { $fixture[$key] = $Changes[$key] }
        $fixture | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $env:DR_NETWORK_FIXTURE
    }
    function Run-Network([string]$Which, [bool]$PreviewOnly = $false) {
        if (Test-Path -LiteralPath $env:DR_NETWORK_LOG) { Remove-Item -LiteralPath $env:DR_NETWORK_LOG }
        $target = if ($Which -eq 'standby') { $drPath } else { $primaryPath }
        $arguments = @('-NoProfile', '-File', $PSCommandPath, '-Child', '-Mode', $Which, '-ConfigPath', $target, '-StateDirectory', $primaryStateDir)
        if ($PreviewOnly) { $arguments += '-PreviewRun' }
        $output = & pwsh @arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        $calls = if (Test-Path -LiteralPath $env:DR_NETWORK_LOG) {
            @(Get-Content -LiteralPath $env:DR_NETWORK_LOG | ForEach-Object { ($_ | ConvertFrom-Json) -join ' ' })
        } else { @() }
        $fixture = Get-Content -LiteralPath $env:DR_NETWORK_FIXTURE -Raw | ConvertFrom-Json -AsHashtable -Depth 50
        return @{ code = $code; output = $output; calls = $calls; fixture = $fixture }
    }
    function Dns-Reads($Result) { return @($Result.calls | Where-Object { $_ -match '^rest --method get .*privateDnsZones/.*/virtualNetworkLinks' }) }

    Save-Primary
    @{ stageLayout = 2; stages = @{ '1' = @{ outputs = $standbyS1 } } } |
        ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $standbyDir 'state.json')
    @{ schema = 'ccof.dr.standby.v1'; phases = @{ Shells = @{ completedAt = '2026-01-01T00:00:00Z'; outputs = @{ ready = $true } } } } |
        ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $standbyDir 'standby.state.json')
    $existingEndpoints = @("$resourcePrefix/providers/Microsoft.Network/privateEndpoints/fixturebres-blob-pe-b",
        "$resourcePrefix/providers/Microsoft.Network/privateEndpoints/fixture-cosmos-sql-pe-b")
    Reset-Fixture $foundryZones $existingEndpoints
    $preview = Run-Network 'standby' $true
    $previewSafe = (
        $preview.code -eq 0 -and @($preview.calls).Count -eq 1 -and @($preview.calls)[0] -match '^deployment group what-if ' -and
        $preview.fixture.deploymentCount -eq 0 -and $preview.fixture.createdEndpoints -eq 0)
    if (-not $previewSafe) { Write-Host "Preview diagnostic: $($preview.output)`nCalls: $($preview.calls -join "`n")" }
    Check 'standby Network preview performs only what-if and no Azure writes' $previewSafe
    $first = Run-Network 'standby'
    if ($first.code -ne 0) { Write-Host "Standby Network diagnostic: $($first.output)" }
    $firstDns = @(Dns-Reads $first)
    Check 'standby Network succeeds with only Cosmos/blob zones despite old unused Foundry outputs' (
        $first.code -eq 0 -and $firstDns.Count -eq 2 -and
        @($firstDns | Where-Object { $_ -match 'privatelink\.(cognitiveservices|openai|services\.ai)\.azure\.com' }).Count -eq 0)
    $generatedPath = Join-Path $standbyDir 'standby.staged.config.json'
    $generated = if (Test-Path -LiteralPath $generatedPath) { Get-Content -LiteralPath $generatedPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { @{} }
    Check 'standby configuration does not invent unmanaged Foundry zone IDs' (
        $generated.network.existing.privateDnsZoneIds -and -not $generated.network.existing.privateDnsZoneIds.ContainsKey('foundry'))
    $firstParameters = $first.fixture.parameterSnapshots[0] | ConvertFrom-Json -AsHashtable -Depth 100
    Check 'standby deployment requests no Foundry endpoints or Foundry DNS zones' (
        @($firstParameters.foundryAccounts.value).Count -eq 0 -and
        -not $firstParameters.network.value.existing.privateDnsZoneIds.ContainsKey('foundry'))
    $phasePath = Join-Path $standbyDir 'standby.state.json'
    $phase = Get-Content -LiteralPath $phasePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Check 'the reconciled partial apply records Network complete' (
        $first.code -eq 0 -and [bool]$phase.phases.Network.completedAt -and @($phase.phases.Network.outputs.privateEndpoints).Count -eq 2)
    $second = Run-Network 'standby'
    if ($second.code -ne 0) { Write-Host "Standby retry diagnostic: $($second.output)" }
    $snapshot1 = (ConvertTo-StgCanonical ($second.fixture.parameterSnapshots[0] | ConvertFrom-Json -AsHashtable -Depth 100)) | ConvertTo-Json -Depth 100 -Compress
    $snapshot2 = (ConvertTo-StgCanonical ($second.fixture.parameterSnapshots[1] | ConvertFrom-Json -AsHashtable -Depth 100)) | ConvertTo-Json -Depth 100 -Compress
    $retrySafe = (
        $first.code -eq 0 -and $second.code -eq 0 -and $second.fixture.createdEndpoints -eq 0 -and
        $second.fixture.deploymentCount -eq 2 -and @($second.fixture.endpoints).Count -eq 2 -and
        $snapshot1 -ceq $snapshot2 -and
        @($first.calls + $second.calls | Where-Object { $_ -match '^functionapp vnet-integration add |^rest --method patch ' }).Count -eq 0)
    if (-not $retrySafe) {
        Write-Host "Retry diagnostic: new endpoints=$($second.fixture.createdEndpoints), deployments=$($second.fixture.deploymentCount), endpoints=$(@($second.fixture.endpoints).Count), same parameters=$($snapshot1 -ceq $snapshot2)."
    }
    Check 'matching existing endpoints and integrations are safely reused on partial and completed retries' $retrySafe

    Reset-Fixture @($cosmosZone) $existingEndpoints
    $missingCosmos = Run-Network 'standby'
    $phase = Get-Content -LiteralPath $phasePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Check 'missing required Cosmos DNS fails and clears prior Network completion' (
        $missingCosmos.code -ne 0 -and $missingCosmos.output -match 'ResourceNotFound' -and -not $phase.phases.ContainsKey('Network'))
    foreach ($field in 'outputCosmosZone', 'outputBlobZone') {
        Reset-Fixture @() $existingEndpoints
        Change-Fixture @{ $field = '' }
        $missingOutput = Run-Network 'standby'
        $phase = Get-Content -LiteralPath $phasePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        Check "missing $field in deployment outputs fails closed" (
            $missingOutput.code -ne 0 -and $missingOutput.output -match 'network_dns_output_invalid' -and -not $phase.phases.ContainsKey('Network'))
    }
    Reset-Fixture @() $existingEndpoints
    Change-Fixture @{ outputBlobZone = $cosmosZone }
    $duplicateBase = Run-Network 'standby'
    Check 'duplicate Cosmos/blob zone outputs fail closed' (
        $duplicateBase.code -ne 0 -and $duplicateBase.output -match 'network_dns_output_invalid')

    $primary.backends[0].subscriptionId = $sub; $primary.backends[0].resourceGroup = 'fixture-rg'
    $primary.backends[0].accountName = 'fixture-foundry'; $primary.backends[0].privateEndpoint = $true
    $primary.network.existing.privateDnsZoneIds.foundry = @{
        cognitiveServices = $foundryZones[0]; openAi = $foundryZones[1]; aiServices = $foundryZones[2]
    }
    Save-Primary
    Reset-Fixture @()
    $managed = Run-Network 'primary'
    if ($managed.code -ne 0) { Write-Host "Primary Foundry Network diagnostic: $($managed.output)" }
    $managedDns = @(Dns-Reads $managed)
    Check 'primary Stage 6 verifies all three Foundry zones when it manages a Foundry endpoint' (
        $managed.code -eq 0 -and $managedDns.Count -eq 5 -and
        @($foundryZones | Where-Object { $zone = $_; @($managedDns | Where-Object { $_.Contains($zone) }).Count -eq 1 }).Count -eq 3)
    Check 'primary Stage 6 also verifies the managed Foundry private endpoint' (
        $managed.code -eq 0 -and @($managed.calls | Where-Object { $_ -match 'privateEndpoints/fixture-foundry-account-pe\?api-version=' }).Count -eq 1)

    Reset-Fixture @($foundryZones[1])
    $missingZone = Run-Network 'primary'
    Check 'a missing managed Foundry DNS zone fails closed instead of being skipped' (
        $missingZone.code -ne 0 -and $missingZone.output -match 'ResourceNotFound' -and
        @((Dns-Reads $missingZone) | Where-Object { $_.Contains($foundryZones[1]) }).Count -eq 1)

    Reset-Fixture @()
    Change-Fixture @{ deniedZones = @($foundryZones[2]) }
    $deniedZone = Run-Network 'primary'
    Check 'authorization errors while reading a managed Foundry zone fail closed' (
        $deniedZone.code -ne 0 -and $deniedZone.output -match 'AuthorizationFailed')

    Reset-Fixture @()
    Change-Fixture @{ reportedFoundryZones = @($foundryZones[0], $foundryZones[1]) }
    $partialOutput = Run-Network 'primary'
    Check 'incomplete managed Foundry DNS deployment outputs fail closed' (
        $partialOutput.code -ne 0 -and $partialOutput.output -match 'network_foundry_dns_incomplete')

    Reset-Fixture @()
    Change-Fixture @{ reportedFoundryZones = @($foundryZones[0], $foundryZones[0], $foundryZones[2]) }
    $duplicateOutput = Run-Network 'primary'
    Check 'duplicate managed Foundry DNS deployment outputs fail closed' (
        $duplicateOutput.code -ne 0 -and $duplicateOutput.output -match 'network_foundry_dns_incomplete')

    $primary.network.existing.privateDnsZoneIds.foundry.Remove('aiServices')
    Save-Primary
    Reset-Fixture @()
    $missingConfig = Run-Network 'primary'
    Check 'a managed Foundry endpoint requires all three configured zone IDs before Azure calls' (
        $missingConfig.code -ne 0 -and $missingConfig.output -match 'privateDnsZoneIds\.foundry\.aiServices' -and @($missingConfig.calls).Count -eq 0)
} finally {
    Remove-Item Env:\DR_NETWORK_LOG, Env:\DR_NETWORK_FIXTURE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "DR network DNS: $script:passed passed, $script:failed failed."
if ($script:failed) { exit 1 }
