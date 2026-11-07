# Offline end-to-end DR standby regression on a synthetic, customer-shaped deployment
# (tests/fixtures/dr-customer-shape; every identifier is fictional). Shape: primary APIM deferred and named
# only by apim.existing, manual Entra verification, shared database throughput, existing network in another
# resource group (Cosmos and blob DNS zones only), Foundry in another subscription without a private endpoint,
# public standby Function Apps, legacy Front Door approvals. Drives Invoke-DrStandby.ps1 Data to Verify.
#Requires -Version 7.0
param([switch]$Child, [string]$Phase, [switch]$PreviewRun)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($Child) {
    $dir = $env:DR_SHAPE_DIR
    if ($Phase -ceq 'Load') {
        . (Join-Path $root 'infra/staged/Invoke-StagedDeployment.ps1') -DotSourceOnly
        $cfg = Read-StgConfig (Join-Path $dir 'staged.config.json')
        $script:StateDir = Join-Path $dir '.staged-state'
        foreach ($n in 0..7) { $null = Get-StgStage $cfg $n; Write-Host "shape_stage_loaded $n" }
        exit 0
    }
    $p = Get-Content -LiteralPath (Join-Path $dir 'staged.config.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $dr = Get-Content -LiteralPath (Join-Path $dir 'dr.config.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $s1 = (Get-Content -LiteralPath (Join-Path $dir '.staged-state/state.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100).stages['1'].outputs
    $sub = $p.subscriptionId; $rg = $p.resourceGroup
    $stem = ($s1.names.apps.resolver.functionApp -replace '-resolver$', '') + '-b'
    $storageStem = ($s1.names.apps.resolver.storageAccount -replace 'res$', '') + 'b'
    $vnetId = $dr.secondary.existingVnetId
    $zonePrefix = "/subscriptions/$($dr.dnsZones.subscriptionId)/resourceGroups/$($dr.dnsZones.resourceGroup)/providers/Microsoft.Network/privateDnsZones"
    $apimName = "$stem-apim"
    # Global: a function called from the driver resolves variables through the driver's scopes.
    $global:DrShape = @{
        mockPath = Join-Path $dir 'mock.json'; sub = $sub; rg = $rg; db = $p.cosmos.databaseName
        accountId = $s1.cosmosAccountId; account = ($s1.cosmosAccountId -split '/')[-1]
        primaryLocation = 'East US 2'; secondaryLocation = 'Central US'
        containers = @((Get-Content -LiteralPath (Join-Path $dir '.staged-state/state.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100).stages['2'].outputs.containers | ForEach-Object { $_.name })
        stem = $stem; storageStem = $storageStem; apimName = $apimName
        apimId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apimName"
        apimPrincipal = '5d0c6a1e-7b2f-4c39-9e84-1a2b3c4d5e01'; apimClient = '5d0c6a1e-7b2f-4c39-9e84-1a2b3c4d5e02'
        identities = @{
            sync = @{ principalId = '5d0c6a1e-7b2f-4c39-9e84-1a2b3c4d5e03'; clientId = '5d0c6a1e-7b2f-4c39-9e84-1a2b3c4d5e04' }
            reconciler = @{ principalId = '5d0c6a1e-7b2f-4c39-9e84-1a2b3c4d5e05'; clientId = '5d0c6a1e-7b2f-4c39-9e84-1a2b3c4d5e06' }
        }
        vnetId = $vnetId; functionsSubnetId = "$vnetId/subnets/$($dr.secondary.subnets.functions.name)"
        apimSubnetId = "$vnetId/subnets/$($dr.secondary.subnets.apim.name)"
        privateEndpointSubnetId = "$vnetId/subnets/$($dr.secondary.subnets.privateEndpoints.name)"
        cosmosZone = "$zonePrefix/privatelink.documents.azure.com"; blobZone = "$zonePrefix/privatelink.blob.core.windows.net"
        apiPath = $p.apim.apiPath
    }
    function global:Start-Sleep { }
    function global:npm { $global:LASTEXITCODE = 0 }
    function global:npx {
        # The package build needs dist/ and npm ci; reaching it proves Code passed its access checks.
        if ($env:DR_SHAPE_PHASE -ceq 'Code') { throw 'shape_test_build_reached' }
        $global:LASTEXITCODE = 0
    }
    function global:node {
        $a = @($args)
        if ($a[0] -like '*render.ts') {
            $config = Get-Content -LiteralPath $a[[Array]::IndexOf($a, '--config') + 1] -Raw | ConvertFrom-Json
            $out = $a[[Array]::IndexOf($a, '--out') + 1]
            New-Item -ItemType Directory -Force -Path $out | Out-Null
            '<policies />' | Set-Content -LiteralPath (Join-Path $out "$($config.apim.apiId).policy.xml")
        } elseif ($a[0] -like '*chargeback.ts') {
            New-Item -ItemType Directory -Force -Path '.env.qs-workbook' | Out-Null
            '{"parameters":{"workbookContent":{"value":{}},"contentTags":{"value":{}}}}' | Set-Content -LiteralPath '.env.qs-workbook/parameters.json'
            '{"outcome":"validated","contentSha256":"00"}'
        }
        $global:LASTEXITCODE = 0
    }
    function global:az {
        $a = @($args | Where-Object { $_ -cne '--only-show-errors' })
        Add-Content -LiteralPath $env:DR_SHAPE_LOG -Value (ConvertTo-Json -InputObject $a -Compress)
        $global:LASTEXITCODE = 0
        $k = $global:DrShape
        $cmd = $a -join ' '
        $arg = { param($name) $i = [Array]::IndexOf($a, $name); if ($i -ge 0) { $a[$i + 1] } }
        $mock = Get-Content -LiteralPath $k.mockPath -Raw | ConvertFrom-Json -AsHashtable
        $saveMock = { $mock | ConvertTo-Json | Set-Content -LiteralPath $k.mockPath }
        $account = {
            $locations = @(@{ locationName = $k.primaryLocation; failoverPriority = 0; isZoneRedundant = $false })
            if ($mock.regionAdded) { $locations += @{ locationName = $k.secondaryLocation; failoverPriority = 1; isZoneRedundant = $false } }
            @{ id = $k.accountId; name = $k.account; properties = @{ provisioningState = 'Succeeded'; capacityMode = 'Provisioned'; capabilities = @()
                    locations = $locations; writeLocations = @(@{ locationName = $k.primaryLocation }); enableAutomaticFailover = [bool]$mock.failover } } |
                ConvertTo-Json -Depth 20 -Compress
        }
        $dbId = "$($k.accountId)/sqlDatabases/$($k.db)"
        if ($cmd -match '^cosmosdb sql database show ') { return (@{ name = $k.db; id = $dbId; type = 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases'; resource = @{ id = $k.db }; options = $null } | ConvertTo-Json -Depth 10 -Compress) }
        if ($cmd -match '^cosmosdb sql database throughput show ') {
            # Real Azure CLI 2.92 shape (lab capture): name is the offer's internal resource ID, not 'default'.
            return ([ordered]@{ id = "$dbId/throughputSettings/default"; identity = $null; location = $null; name = 'Tb7w'
                resource = [ordered]@{ autoscaleSettings = @{ autoUpgradePolicy = $null; maxThroughput = 1000; targetMaxThroughput = $null }; etag = $null
                    instantMaximumThroughput = '10000'; minimumThroughput = '1000'; offerReplacePending = $null; rid = $null
                    softAllowedMaximumThroughput = '1000000'; throughput = 100; ts = $null }
                resourceGroup = $k.rg; systemData = $null; tags = $null; type = 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/throughputSettings' } |
                ConvertTo-Json -Depth 10 -Compress)
        }
        if ($cmd -match '^cosmosdb sql container list ') { return (ConvertTo-Json -InputObject @($k.containers | ForEach-Object { @{ name = $_; id = "$dbId/containers/$_"; type = 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers'; resource = @{ id = $_ }; options = $null } }) -Compress) }
        if ($cmd -match '^cosmosdb sql container show ') {
            $name = & $arg '--name'
            return (@{ name = $name; id = "$dbId/containers/$name"; type = 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers'; resource = @{ id = $name }; options = $null } | ConvertTo-Json -Depth 10 -Compress)
        }
        if ($cmd -match '^cosmosdb sql container throughput show ') {
            # Azure CLI 2.92 multi-line NotFound for a container on shared database throughput (lab capture, ActivityId replaced).
            foreach ($line in @(
                'ERROR: (NotFound) Entity with the specified id does not exist in the system. More info: https://aka.ms/cosmosdb-tsg-not-found',
                'ActivityId: 6f1d2c3b-4a59-11f1-8a7b-9c0d1e2f3a4b, Microsoft.Azure.Documents.Common/2.14.0',
                'Code: NotFound',
                'Message: Entity with the specified id does not exist in the system. More info: https://aka.ms/cosmosdb-tsg-not-found',
                'ActivityId: 6f1d2c3b-4a59-11f1-8a7b-9c0d1e2f3a4b, Microsoft.Azure.Documents.Common/2.14.0')) {
                Write-Error $line -ErrorAction Continue
            }
            $global:LASTEXITCODE = 3
            return
        }
        if ($cmd -match '^cosmosdb update ') { $mock.failover = $true; & $saveMock; return (& $account) }
        if ($cmd -match '^cosmosdb sql role assignment list ') { return '[]' }
        if ($cmd -match '^(apim list|resource list) ') { return '[]' }
        if ($cmd -match '^identity show ') {
            $name = & $arg '--name'; $key = if ($name -match 'reconciler') { 'reconciler' } else { 'sync' }
            $id = $k.identities[$key]
            return (@{ id = "/subscriptions/$($k.sub)/resourceGroups/$($k.rg)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"; name = $name; principalId = $id.principalId; clientId = $id.clientId } | ConvertTo-Json -Compress)
        }
        if ($cmd -match '^deployment group create ') {
            $name = & $arg '--name'
            $outputs = switch -Regex ($name) {
                'shells$' {
                    $apps = [ordered]@{}; $functionApps = @()
                    foreach ($key in 'resolver', 'sync', 'reconciler', 'admin') {
                        $apps[$key] = @{ functionApp = "$($k.stem)-$key"; storageAccount = "$($k.storageStem)$($key.Substring(0, 3))" }
                        $service = if ($k.identities[$key]) { $k.identities[$key] } else { @{ principalId = [guid]::NewGuid().ToString(); clientId = [guid]::NewGuid().ToString() } }
                        $functionApps += @{ key = $key; service = $service }
                    }
                    @{ apimId = $k.apimId; apimName = $k.apimName; apimPrincipalId = $k.apimPrincipal; apimGatewayUrl = "https://$($k.apimName).azure-api.net"; apps = $apps; functionApps = $functionApps }
                }
                'grants$' { @{ storageOwnerDetails = @(); metricsPublisherDetails = @(); workspaceReaderDetails = @(); cosmosAssignmentDetails = @(); cosmosAssignmentIds = @() } }
                'config$' { @{ gatewayUrl = "https://$($k.apimName).azure-api.net/$($k.apiPath)"; settingsWritten = $true; workbookDeployed = $false } }
                'network$' {
                    $prefix = "/subscriptions/$($k.sub)/resourceGroups/$($k.rg)/providers/Microsoft.Network/privateEndpoints"
                    $file = (& $arg '--parameters').Substring(1)
                    $names = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -Depth 100).parameters.names.value
                    @{ vnetId = $k.vnetId; functionsSubnetId = $k.functionsSubnetId; apimSubnetId = $k.apimSubnetId; privateEndpointSubnetId = $k.privateEndpointSubnetId
                        storagePrivateEndpointIds = @($names.apps.Values | ForEach-Object { "$prefix/$($_.storageAccount)-blob-pe-b" })
                        cosmosPrivateEndpointId = "$prefix/$($names.cosmosAccount)-sql-pe-b"
                        foundryPrivateEndpointIds = @(); foundryPrivateDnsZoneIds = @('', '', '')
                        privateDnsZoneIds = @{ cosmos = $k.cosmosZone; blob = $k.blobZone } }
                }
                default { throw "Unexpected deployment: $name" }
            }
            $wrapped = @{}; foreach ($key in $outputs.Keys) { $wrapped[$key] = @{ value = $outputs[$key] } }
            return (@{ properties = @{ provisioningState = 'Succeeded'; duration = 'PT1S'; outputs = $wrapped } } | ConvertTo-Json -Depth 50 -Compress)
        }
        if ($cmd -match '^functionapp show ') {
            $name = & $arg '--name'
            return (@{ name = $name; properties = @{ defaultHostName = "$name.azurewebsites.net"; publicNetworkAccess = 'Enabled'; virtualNetworkSubnetId = $k.functionsSubnetId } } | ConvertTo-Json -Depth 10 -Compress)
        }
        if ($cmd -match '^functionapp config show ') { return '{"ftpsState":"Disabled"}' }
        if ($cmd -match '^functionapp config appsettings list ') {
            $settings = @('AzureWebJobsStorage__accountName', 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', 'APPLICATIONINSIGHTS_CONNECTION_STRING', 'COSMOS_ENDPOINT', 'AzureWebJobs.syncEntitlement.Disabled', 'AzureWebJobs.reconcileBudgets.Disabled')
            return (ConvertTo-Json -InputObject @($settings | ForEach-Object { @{ name = $_; value = $(if ($_ -like '*.Disabled') { 'true' } else { 'fixture' }) } }) -Compress)
        }
        if ($cmd -match '^rest --method (\S+) ') {
            $method = $Matches[1]
            $path = ([Uri](& $arg '--url')).AbsolutePath
            if ($path -match 'graph') { throw "Unexpected Graph call: $method $path" }
            if ($path -ieq $k.accountId) {
                if ($method -ceq 'patch') { $mock.regionAdded = $true; & $saveMock }
                return (& $account)
            }
            if ($method -cne 'get') { throw "Unexpected ARM write: $method $path" }
            if ($path -match '/providers/Microsoft\.ManagedIdentity/identities/default$') {
                return (@{ properties = @{ principalId = $k.apimPrincipal; clientId = $k.apimClient } } | ConvertTo-Json -Compress)
            }
            if ($path -match '/Microsoft\.ApiManagement/service/[^/]+/apis/[^/]+$') { return (@{ properties = @{ path = $k.apiPath } } | ConvertTo-Json -Compress) }
            if ($path -match '/Microsoft\.ApiManagement/service/([^/]+)$') {
                $sku = if ($Matches[1] -match '-b-apim$' -and $mock.standbyApimSku) { $mock.standbyApimSku } else { 'StandardV2' }
                return (@{ id = $path; name = $Matches[1]; sku = @{ name = $sku }
                    identity = @{ type = 'SystemAssigned'; principalId = $k.apimPrincipal }
                    properties = @{ provisioningState = 'Succeeded'; gatewayUrl = "https://$($Matches[1]).azure-api.net"; publicNetworkAccess = 'Enabled'
                        virtualNetworkType = 'External'; virtualNetworkConfiguration = @{ subnetResourceId = $k.apimSubnetId } } } | ConvertTo-Json -Depth 10 -Compress)
            }
            if ($path -match '/Microsoft\.CognitiveServices/accounts/[^/]+/providers/Microsoft\.Authorization/roleAssignments$') {
                return (@{ value = @(@{ properties = @{ principalId = $k.apimPrincipal; scope = $path; roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908' } }) } | ConvertTo-Json -Depth 10 -Compress)
            }
            if ($path -match '/providers/Microsoft\.Authorization/roleAssignments$') { return '{"value":[]}' }
            if ($path -match '/config/authsettingsV2/list$') {
                return (@{ properties = @{ platform = @{ enabled = $true }; globalValidation = @{ unauthenticatedClientAction = 'Return401' }
                    identityProviders = @{ azureActiveDirectory = @{ validation = @{ defaultAuthorizationPolicy = @{ allowedApplications = @($k.apimClient) } } } } } } | ConvertTo-Json -Depth 20 -Compress)
            }
            if ($path -match '/Microsoft\.Web/sites/([^/]+)/functions$') { return (@{ value = @(@{ name = "$($Matches[1])/fixture" }) } | ConvertTo-Json -Depth 5 -Compress) }
            if ($path -match '/privateEndpointConnections$') { return '{"value":[]}' }
            if ($path -match '/Microsoft\.Resources/deployments/[^/]+/operations$') { return '{"value":[]}' }
            if ($path -match '/privateDnsZones/[^/]+/virtualNetworkLinks$') {
                return (@{ value = @(@{ properties = @{ virtualNetwork = @{ id = $k.vnetId }; registrationEnabled = $false } }) } | ConvertTo-Json -Depth 10 -Compress)
            }
            if ($path -match '/privateEndpoints/[^/]+/privateDnsZoneGroups/default$') {
                return '{"properties":{"privateDnsZoneConfigs":[{"properties":{"recordSets":[{"fqdn":"fixture.internal","ipAddresses":["100.80.60.70"]}]}}]}}'
            }
            if ($path -match '/privateEndpoints/([^/]+)$') {
                return (@{ name = $Matches[1]; properties = @{ privateLinkServiceConnections = @(@{ properties = @{ privateLinkServiceConnectionState = @{ status = 'Approved' } } }) } } | ConvertTo-Json -Depth 10 -Compress)
            }
        }
        throw "Unexpected az call in customer-shape test: $cmd"
    }
    $drArgs = @{ Phase = $Phase; ConfigPath = (Join-Path $dir 'dr.config.json'); Apply = (-not $PreviewRun)
        ApprovePrivateNetworkChanges = $true; ApprovePublicApimBootstrap = $true; ApprovePublicFunctionAccess = $true }
    & (Join-Path $root 'infra/dr/Invoke-DrStandby.ps1') @drArgs
    exit $LASTEXITCODE
}

$script:passed = 0; $script:failed = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $Name $Detail" -ForegroundColor Red }
}
$fixture = Join-Path $PSScriptRoot 'fixtures/dr-customer-shape'
$scratch = Join-Path $root ".env.public-test-scratch\dr-customer-shape-$PID"
if (Test-Path -LiteralPath $scratch) { throw "Fixture path already exists: $scratch" }
New-Item -ItemType Directory -Path (Join-Path $scratch '.staged-state'), (Join-Path $scratch '.dr-state') -Force | Out-Null
$savedEnv = @{ dir = $env:DR_SHAPE_DIR; log = $env:DR_SHAPE_LOG; phase = $env:DR_SHAPE_PHASE }
try {
    Copy-Item -LiteralPath (Join-Path $fixture 'staged.config.json'), (Join-Path $fixture 'dr.config.json') -Destination $scratch
    Copy-Item -LiteralPath (Join-Path $fixture 'staged-state/state.json') -Destination (Join-Path $scratch '.staged-state')
    Copy-Item -LiteralPath (Join-Path $fixture 'dr-state/frontdoor-state.json') -Destination (Join-Path $scratch '.dr-state')
    '{"regionAdded":false,"failover":false}' | Set-Content -LiteralPath (Join-Path $scratch 'mock.json')
    $env:DR_SHAPE_DIR = $scratch
    $env:DR_SHAPE_LOG = Join-Path $scratch 'az.log'
    $primary = Get-Content -LiteralPath (Join-Path $scratch 'staged.config.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $dr = Get-Content -LiteralPath (Join-Path $scratch 'dr.config.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $primaryStatePath = Join-Path $scratch '.staged-state/state.json'
    $primaryState = Get-Content -LiteralPath $primaryStatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $primaryStateHash = (Get-FileHash -LiteralPath $primaryStatePath -Algorithm SHA256).Hash
    $fdPath = Join-Path $scratch '.dr-state/frontdoor-state.json'
    $standbyDir = Join-Path $scratch '.dr-state'
    $existingApimId = "/subscriptions/$($primary.apim.existing.subscriptionId)/resourceGroups/$($primary.apim.existing.resourceGroup)/providers/Microsoft.ApiManagement/service/$($primary.apim.existing.name)"
    $zonePrefix = "/subscriptions/$($dr.dnsZones.subscriptionId)/resourceGroups/$($dr.dnsZones.resourceGroup)/providers/Microsoft.Network/privateDnsZones"
    $expectedZones = @("$zonePrefix/privatelink.documents.azure.com", "$zonePrefix/privatelink.blob.core.windows.net")

    # The fixture keeps the customer's shape traits; a regenerated fixture that lost one would weaken this test.
    $ps1 = $primaryState.stages['1'].outputs
    Check 'shape: primary APIM deferred and blank' ((@('apimId', 'apimName', 'apimGatewayUrl', 'apimPrincipalId', 'foundryAccountId') | Where-Object { $ps1[$_] -ne '' }).Count -eq 0 -and $ps1.apimStatus -ceq 'deferred-no-public-bootstrap-approved')
    Check 'shape: apim.existing configured' ([bool]$primary.apim.existing.name)
    Check 'shape: state target group is lowercase, config group uppercase' ($primaryState.target.resourceGroup -ceq $primary.resourceGroup.ToLowerInvariant() -and $primary.resourceGroup -cne $primaryState.target.resourceGroup)
    Check 'shape: stage 4 manual without service principals' ($primaryState.stages['4'].outputs.verification -ceq 'manual' -and $null -eq $primaryState.stages['4'].outputs.gatewayServicePrincipalId -and $null -eq $primaryState.stages['4'].outputs.resolverServicePrincipalId)
    $ps6 = $primaryState.stages['6'].outputs
    Check 'shape: stage 6 empty Foundry outputs' ((@($ps6.foundryPrivateDnsZoneIds) -join '|') -ceq '||' -and @($ps6.foundryPrivateDnsZoneIds).Count -eq 3 -and @($ps6.foundryPrivateEndpointIds).Count -eq 0)
    Check 'shape: stages 0-7, no stage 8' ((@($primaryState.stages.Keys | Sort-Object) -join ',') -ceq '0,1,2,3,4,5,6,7')
    Check 'shape: network in another group with only Cosmos and blob zones' ($primary.network.mode -ceq 'existing' -and $primary.network.existing.functionsSubnetId -notmatch "/resourceGroups/$([regex]::Escape($primary.resourceGroup))/" -and (@($primary.network.existing.privateDnsZoneIds.Keys | Sort-Object) -join ',') -ceq 'blob,cosmos')
    Check 'shape: backend in another subscription without private endpoint' (@($primary.backends | Where-Object { $_.subscriptionId -ine $primary.subscriptionId -and $_.privateEndpoint -eq $false }).Count -eq @($primary.backends).Count)
    Check 'shape: public standby Function Apps' ($dr.standby.functionsPublicNetworkAccess -ceq 'Enabled')
    $fdBefore = Get-Content -LiteralPath $fdPath -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    Check 'shape: legacy verified Front Door approvals' ($fdBefore.Contains('verifiedAt') -and $fdBefore.Contains('approvedConnections') -and -not $fdBefore.Contains('reviewedConnections'))

    $script:allCalls = [Collections.Generic.List[string]]::new()
    function Invoke-Shape([string]$Name, [switch]$Preview) {
        if (Test-Path -LiteralPath $env:DR_SHAPE_LOG) { Remove-Item -LiteralPath $env:DR_SHAPE_LOG }
        $env:DR_SHAPE_PHASE = $Name
        $arguments = @('-NoProfile', '-File', $PSCommandPath, '-Child', '-Phase', $Name)
        if ($Preview) { $arguments += '-PreviewRun' }
        $output = & pwsh @arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        $calls = if (Test-Path -LiteralPath $env:DR_SHAPE_LOG) { @(Get-Content -LiteralPath $env:DR_SHAPE_LOG | ForEach-Object { @($_ | ConvertFrom-Json) -join ' ' }) } else { @() }
        foreach ($c in $calls) { $script:allCalls.Add($c) }
        return @{ code = $code; output = $output; calls = $calls }
    }
    function Check-Run([string]$Name, $Run) {
        Check "$Name completes without an exception" ($Run.code -eq 0) "(exit $($Run.code)): $(($Run.output -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 4) -join ' | ')"
    }

    $load = Invoke-Shape 'Load'
    Check-Run 'primary stages 0-7 load' $load
    Check 'Get-StgStage loads stages 1-7' ((1..7 | Where-Object { $load.output -match "shape_stage_loaded $_\b" }).Count -eq 7)

    $data = Invoke-Shape 'Data' -Preview
    Check-Run 'Data preview' $data
    Check 'Data preview classifies every container as shared' (@([regex]::Matches($data.output, 'container \S+: shared database throughput')).Count -eq @($primaryState.stages['2'].outputs.containers).Count)
    $data = Invoke-Shape 'Data'
    Check-Run 'Data apply' $data
    Check 'Data apply adds the standby region once' (@($data.calls | Where-Object { $_ -match '^rest --method patch .*databaseAccounts/' }).Count -eq 1)
    Check 'Data apply enables service-managed failover' (@($data.calls | Where-Object { $_ -match '^cosmosdb update .*--enable-automatic-failover true' }).Count -eq 1)
    $fdAfter = Get-Content -LiteralPath $fdPath -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    Check 'Front Door verifiedAt invalidated by standby work' (-not $fdAfter.Contains('verifiedAt') -and $data.output -match 'Prior Front Door verification was cleared')
    Check 'Front Door legacy approvals preserved' ((@($fdAfter.approvedConnections) -join '|') -ceq (@($fdBefore.approvedConnections) -join '|'))

    $shells = Invoke-Shape 'Shells'
    Check-Run 'Shells apply' $shells
    $grants = Invoke-Shape 'Grants'
    Check-Run 'Grants apply' $grants
    Check 'primary APIM resolved from apim.existing' ($grants.output -match "Primary APIM resolved from apim\.existing: $([regex]::Escape($existingApimId))")
    $bCfgPath = Join-Path $standbyDir 'standby.staged.config.json'
    $bCfg = if (Test-Path -LiteralPath $bCfgPath) { Get-Content -LiteralPath $bCfgPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { @{} }
    $ledgerIds = @(if ($bCfg.reconciler) { $bCfg.reconciler.ledgerGatewayResourceIds })
    Check 'standby reads both gateways, primary from apim.existing' ($ledgerIds.Count -eq 2 -and $ledgerIds -icontains $existingApimId -and @($ledgerIds | Where-Object { $_ -match '-b-apim$' }).Count -eq 1)
    Check 'Grants verifies the Foundry grant in the backend subscription' (@($grants.calls | Where-Object { $_ -match "/subscriptions/$($primary.backends[0].subscriptionId)/.*/roleAssignments" }).Count -ge 1)

    $config = Invoke-Shape 'Config'
    Check-Run 'Config apply' $config
    Check 'Config uses manual Entra redirects' ($config.output -match 'manual Entra verification: .*No Microsoft Graph call')

    $setStandbySku = { param($sku) $m = Get-Content -LiteralPath (Join-Path $scratch 'mock.json') -Raw | ConvertFrom-Json -AsHashtable; $m.standbyApimSku = $sku; $m | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $scratch 'mock.json') }
    & $setStandbySku 'BasicV2'
    foreach ($skuRun in @(@{ name = 'preview'; run = (Invoke-Shape 'Network' -Preview) }, @{ name = 'apply'; run = (Invoke-Shape 'Network') })) {
        $r = $skuRun.run
        Check "Network $($skuRun.name) refuses a BasicV2 standby APIM" ($r.code -ne 0 -and $r.output -match 'apim_sku_unsupported: standby APIM \S+-b-apim is BasicV2' -and $r.output -match 'StandardV2') "(exit $($r.code)): $(($r.output -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 3) -join ' | ')"
        Check "Network $($skuRun.name) with BasicV2 stops before any deployment or write" (-not @($r.calls | Where-Object { $_ -match '^deployment group (create|what-if)|vnet-integration add|^rest --method (put|patch|post|delete) ' }).Count) "calls: $(@($r.calls | Where-Object { $_ -match 'deployment|vnet-integration|--method (put|patch|post|delete)' }) -join ' ; ')"
    }
    Check 'refused Network records no phase' (-not ((Get-Content -LiteralPath (Join-Path $standbyDir 'standby.state.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100).phases.Contains('Network')))
    & $setStandbySku 'StandardV2'
    $network = Invoke-Shape 'Network'
    Check-Run 'Network apply' $network
    $dnsReads = @($network.calls | Where-Object { $_ -match '^rest --method get .*privateDnsZones/.*/virtualNetworkLinks' } | ForEach-Object { ([Uri]($_ -split ' ')[4]).AbsolutePath -replace '/virtualNetworkLinks$', '' })
    Check 'Network checks exactly the Cosmos and blob DNS zones' ($dnsReads.Count -eq 2 -and @($expectedZones | Where-Object { $dnsReads -icontains $_ }).Count -eq 2) "read: $($dnsReads -join ', ')"
    $paramsPath = Join-Path $standbyDir 'dr-standby-stage6-network.parameters.json'
    $networkParams = if (Test-Path -LiteralPath $paramsPath) { (Get-Content -LiteralPath $paramsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100).parameters } else { @{} }
    $deployedZones = if ($networkParams.network) { $networkParams.network.value.existing.privateDnsZoneIds } else { @{} }
    Check 'Network deploys only Cosmos and blob DNS targets, no Foundry endpoint' ((@($deployedZones.Keys | Sort-Object) -join ',') -ceq 'blob,cosmos' -and $deployedZones.cosmos -ieq $expectedZones[0] -and $deployedZones.blob -ieq $expectedZones[1] -and $networkParams.foundryAccounts -and @($networkParams.foundryAccounts.value).Count -eq 0)

    $code = Invoke-Shape 'Code'
    Check 'Code reaches the public package build' ($code.output -match 'shape_test_build_reached') "$(($code.output -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 3) -join ' | ')"
    Check 'Code reads every standby app before publishing' (@($code.calls | Where-Object { $_ -match '^functionapp show ' }).Count -eq 4)
    Check 'Code does not take the private-publisher path' ($code.output -notmatch 'Private publisher|private_publisher' -and -not @($code.calls | Where-Object { $_ -match 'privateEndpointConnections' }).Count)

    $verify = Invoke-Shape 'Verify'
    Check-Run 'Verify' $verify
    Check 'Verify records both writers off' ($verify.output -match 'phase Verify completed')

    $graph = @($script:allCalls | Where-Object { $_ -match 'graph\.microsoft\.com' })
    Check 'no Microsoft Graph write' (-not @($graph | Where-Object { $_ -notmatch '^rest --method get ' }).Count) ($graph -join '; ')
    Check 'no Cosmos throughput write' (-not @($script:allCalls | Where-Object { $_ -match '^cosmosdb sql \S+ throughput (update|migrate) ' }).Count)
    Check 'primary staged state is never written' ((Get-FileHash -LiteralPath $primaryStatePath -Algorithm SHA256).Hash -ceq $primaryStateHash)
} finally {
    $env:DR_SHAPE_DIR = $savedEnv.dir; $env:DR_SHAPE_LOG = $savedEnv.log; $env:DR_SHAPE_PHASE = $savedEnv.phase
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "customer-shape DR standby: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
