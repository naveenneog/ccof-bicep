# Offline behavioral tests for the actual DR Data driver. The child replaces az with an in-memory
# management-plane fixture and never invokes the real Azure CLI.
#Requires -Version 7.0
param([switch]$Child, [switch]$Apply, [switch]$ApproveReduction, [string]$ConfigPath)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($Child) {
    $global:DR_COSMOS_ACCOUNT_READS = 0
    function global:Start-Sleep { param($Seconds) }
    function global:az {
        $arguments = @($args)
        Add-Content -LiteralPath $env:DR_COSMOS_LOG -Value ($arguments | ConvertTo-Json -Compress)
        $global:LASTEXITCODE = 0
        $s = Get-Content -LiteralPath $env:DR_COSMOS_FIXTURE -Raw | ConvertFrom-Json -AsHashtable -Depth 50
        $command = $arguments -join ' '
        $index = [Array]::IndexOf($arguments, '--name')
        $name = if ($index -ge 0) { $arguments[$index + 1] } else { '' }
        $accountId = "/subscriptions/$($s.subscription)/resourceGroups/fixture-rg/providers/Microsoft.DocumentDB/databaseAccounts/fixture-cosmos"
        $dbId = "$accountId/sqlDatabases/fixturedb"
        if ($command -match '^rest --method get ') {
            $global:DR_COSMOS_ACCOUNT_READS++
            if ($env:DR_COSMOS_FAULT -eq 'account-drift' -and $global:DR_COSMOS_ACCOUNT_READS -eq 2) {
                $s.regions += @{ locationName = 'North Europe'; failoverPriority = 1; isZoneRedundant = $false }
                $s | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $env:DR_COSMOS_FIXTURE
            }
            $capacity = if ($s.capacity) { $s.capacity } else { 'Provisioned' }
            $accountState = if ($env:DR_COSMOS_FAULT -eq 'account-pending') { 'Updating' } else { 'Succeeded' }
            $props = @{
                capacityMode = $capacity; capabilities = @(); provisioningState = $accountState
                locations = @($s.regions); writeLocations = @($s.regions[0])
                enableAutomaticFailover = [bool]$s.failover
            }
            if ($capacity -eq 'Serverless') { $props.capabilities = @(@{ name = 'EnableServerless' }) }
            return (@{ name = 'fixture-cosmos'; id = $accountId; properties = $props } | ConvertTo-Json -Depth 30 -Compress)
        }
        if ($command -match '^rest --method patch ') {
            $bodyIndex = [Array]::IndexOf($arguments, '--body')
            $body = Get-Content -LiteralPath $arguments[$bodyIndex + 1].Substring(1) -Raw | ConvertFrom-Json -AsHashtable -Depth 30
            if ($body.properties.capacityMode -eq 'Provisioned') { $s.capacity = 'Provisioned' }
            else { $s.regions = @($body.properties.locations) }
            $s | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $env:DR_COSMOS_FIXTURE
            return '{}'
        }
        if ($command -match '^cosmosdb update ') {
            $s.failover = $true
            $s | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $env:DR_COSMOS_FIXTURE
            return '{}'
        }
        if ($command -match '^cosmosdb sql database show ') {
            if ($env:DR_COSMOS_FAULT -eq 'database-missing') {
                Write-Error 'ERROR: (NotFound) Entity with the specified id does not exist in the system' -ErrorAction Continue
                $global:LASTEXITCODE = 3
                return
            }
            $databaseId = if ($env:DR_COSMOS_FAULT -eq 'database-id-case-mismatch') { $dbId.Replace('fixturedb', 'FIXTUREDB') } else { $dbId }
            $database = @{ name = 'fixturedb'; id = $databaseId; type = 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases'; resource = @{ id = 'fixturedb' }; options = $null }
            if ($env:DR_COSMOS_FAULT -eq 'database-offer-option') { $database.options = @{ throughput = 400 } }
            return ($database | ConvertTo-Json -Depth 20 -Compress)
        }
        if ($command -match '^cosmosdb sql container list ') {
            if ($env:DR_COSMOS_FAULT -eq 'list-forbidden') {
                Write-Error 'ERROR: (Forbidden) AuthorizationFailed to list containers' -ErrorAction Continue
                $global:LASTEXITCODE = 3
                return
            }
            return (@($s.containers | ForEach-Object { @{ name = $_.name; id = "$dbId/containers/$($_.name)"; type = 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers'; resource = @{ id = $_.name }; options = $null } }) | ConvertTo-Json -Depth 20 -Compress -AsArray)
        }
        if ($command -match '^cosmosdb sql container show ') {
            $found = @($s.containers | Where-Object name -CEQ $name)
            if ($env:DR_COSMOS_FAULT -eq 'container-disappeared' -and $name -ceq 'container0') { $found = @() }
            if ($found.Count -eq 1) {
                $containerId = "$dbId/containers/$name"
                if ($env:DR_COSMOS_FAULT -eq 'container-id-case-mismatch') { $containerId = "$dbId/containers/$($name.ToUpperInvariant())" }
                $container = @{ name = $name; id = $containerId; type = 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers'; resource = @{ id = $name }; options = $null }
                if ($env:DR_COSMOS_FAULT -eq 'container-dedicated-option') { $container.options = @{ throughput = 400 } }
                return ($container | ConvertTo-Json -Depth 20 -Compress)
            }
            Write-Error 'ERROR: (NotFound) Entity with the specified id does not exist in the system' -ErrorAction Continue
            $global:LASTEXITCODE = 3
            return
        }
        if ($command -match '^cosmosdb sql (database|container) throughput (show|migrate|update) ') {
            $kind = $Matches[1]; $operation = $Matches[2]
            $offer = if ($kind -eq 'database') { $s.database } else { @($s.containers | Where-Object name -CEQ $name)[0] }
            if ($operation -eq 'show' -and (
                ($kind -eq 'database' -and $env:DR_COSMOS_FAULT -eq 'database-forbidden') -or
                ($kind -eq 'container' -and $name -ceq 'container0' -and $env:DR_COSMOS_FAULT -eq 'container-forbidden') -or
                ($kind -eq 'container' -and $name -ceq 'container1' -and $env:DR_COSMOS_FAULT -eq 'container1-forbidden')
            )) {
                Write-Error 'ERROR: (Forbidden) AuthorizationFailed: insufficient rights' -ErrorAction Continue
                $global:LASTEXITCODE = 3
                return
            }
            if ($operation -eq 'show' -and $kind -eq 'container' -and $name -ceq 'container0' -and $env:DR_COSMOS_FAULT -eq 'other-notfound') {
                Write-Error 'ERROR: (NotFound) Some other endpoint could not be found' -ErrorAction Continue
                $global:LASTEXITCODE = 3
                return
            }
            if ($operation -eq 'show' -and $kind -eq 'container' -and $name -ceq 'container0' -and $env:DR_COSMOS_FAULT -eq 'container-network') {
                Write-Error 'ERROR: connection timed out' -ErrorAction Continue
                $global:LASTEXITCODE = 3
                return
            }
            if ($operation -eq 'show' -and $kind -eq 'container' -and $name -ceq 'container0' -and $env:DR_COSMOS_FAULT -eq 'container-throttled') {
                Write-Error 'ERROR: (TooManyRequests) Retry after 5 seconds' -ErrorAction Continue
                $global:LASTEXITCODE = 3
                return
            }
            if ($operation -eq 'show' -and $kind -eq 'container' -and $name -ceq 'container0' -and $env:DR_COSMOS_FAULT -eq 'notfound-with-forbidden') {
                Write-Error 'ERROR: (NotFound) Entity with the specified id does not exist in the system AuthorizationFailed' -ErrorAction Continue
                $global:LASTEXITCODE = 3
                return
            }
            if ($operation -eq 'show' -and $kind -eq 'container' -and $name -ceq 'container0' -and $env:DR_COSMOS_FAULT -in @('known-notfound-suffix', 'notfound-suffix-with-forbidden')) {
                $message = 'ERROR: (NotFound) Entity with the specified id does not exist in the system. More info: https://aka.ms/cosmosdb-tsg-not-found'
                if ($env:DR_COSMOS_FAULT -eq 'notfound-suffix-with-forbidden') { $message += ' AuthorizationFailed' }
                Write-Error $message -ErrorAction Continue
                $global:LASTEXITCODE = 3
                return
            }
            if ($operation -eq 'show' -and $kind -eq 'container' -and $name -ceq 'container0' -and $env:DR_COSMOS_FAULT -like 'core-notfound-*') {
                $message = 'Entity with the specified id does not exist in the system. More info: https://aka.ms/cosmosdb-tsg-not-found'
                if ($env:DR_COSMOS_FAULT -in @('core-notfound-diagnostics', 'core-notfound-auth', 'core-notfound-network', 'core-notfound-status', 'core-notfound-transport')) {
                    $status = if ($env:DR_COSMOS_FAULT -eq 'core-notfound-status') { 403 } else { 404 }
                    $transport = if ($env:DR_COSMOS_FAULT -eq 'core-notfound-transport') { 'SocketException' } else { 'null' }
                    $message += ", ActivityId: 00000000-0000-4000-8000-000000000001, RequestStartTime: 2026-01-01T00:00:00Z, StatusCode: $status, SubStatusCode: 0, TransportException: $transport, Microsoft.Azure.Documents.Common/2.14.0"
                }
                if ($env:DR_COSMOS_FAULT -eq 'core-notfound-auth') { $message += ', AuthorizationFailed' }
                if ($env:DR_COSMOS_FAULT -eq 'core-notfound-auth-substring') { $message += ', AuthorizationFailedException' }
                if ($env:DR_COSMOS_FAULT -eq 'core-notfound-network') { $message += ', connection timed out' }
                if ($env:DR_COSMOS_FAULT -eq 'core-notfound-network-dns') { $message += ', DNS name resolution failed' }
                Write-Error "ERROR: (NotFound) $message" -ErrorAction Continue
                Write-Error 'Code: NotFound' -ErrorAction Continue
                if ($env:DR_COSMOS_FAULT -eq 'core-notfound-other-code') { Write-Error 'Code: BadRequest' -ErrorAction Continue }
                if ($env:DR_COSMOS_FAULT -eq 'core-notfound-other-equals') { Write-Error 'ErrorCode=Conflict' -ErrorAction Continue }
                if ($env:DR_COSMOS_FAULT -eq 'core-notfound-status-error-code') { Write-Error 'Status Error Code: Conflict' -ErrorAction Continue }
                if ($env:DR_COSMOS_FAULT -eq 'core-notfound-prefixed-error-code') { Write-Error 'BackendErrorCode: Conflict' -ErrorAction Continue }
                if ($env:DR_COSMOS_FAULT -eq 'core-notfound-other-message') { $message = 'Some other endpoint could not be found' }
                Write-Error "Message: $message" -ErrorAction Continue
                $global:LASTEXITCODE = 3
                return
            }
            if ($operation -eq 'show' -and $kind -eq 'database' -and $env:DR_COSMOS_FAULT -eq 'database-malformed') {
                return '{"name":"Tb7w","resource":{}}'
            }
            if ($operation -eq 'show' -and (-not $offer -or $offer.mode -eq 'shared')) {
                # Azure CLI 2.92 stderr for an offer that does not exist (lab capture, ActivityId replaced).
                foreach ($line in @(
                    'ERROR: (NotFound) Entity with the specified id does not exist in the system. More info: https://aka.ms/cosmosdb-tsg-not-found',
                    'ActivityId: 0a1b2c3d-0000-4000-8000-00000000c05d, Microsoft.Azure.Documents.Common/2.14.0',
                    'Code: NotFound',
                    'Message: Entity with the specified id does not exist in the system. More info: https://aka.ms/cosmosdb-tsg-not-found',
                    'ActivityId: 0a1b2c3d-0000-4000-8000-00000000c05d, Microsoft.Azure.Documents.Common/2.14.0')) {
                    Write-Error $line -ErrorAction Continue
                }
                $global:LASTEXITCODE = 3
                return
            }
            if ($operation -eq 'migrate') { $offer.mode = 'autoscale'; $offer.max = if ($env:DR_COSMOS_FAULT -eq 'migration-high') { 4000 } else { 1000 } }
            if ($operation -eq 'update') {
                $maxIndex = [Array]::IndexOf($arguments, '--max-throughput')
                if ($env:DR_COSMOS_FAULT -eq 'update-not-applied-fd-corrupt') { Set-Content -LiteralPath $env:DR_COSMOS_FD_STATE -Value '{not json' }
                if ($env:DR_COSMOS_FAULT -notin @('update-not-applied', 'update-not-applied-fd-corrupt')) {
                    $offer.mode = 'autoscale'; $offer.max = [int]$arguments[$maxIndex + 1]
                }
            }
            if ($operation -ne 'show') { $s | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $env:DR_COSMOS_FIXTURE }
            # Shape of real Azure CLI 2.92 throughput show output (lab captures): name is the offer's
            # internal resource ID, not 'default'; numbers other than throughput are strings.
            $resource = [ordered]@{
                autoscaleSettings = $null; etag = $null; instantMaximumThroughput = '10000'
                minimumThroughput = '400'; offerReplacePending = $null; rid = $null
                softAllowedMaximumThroughput = '1000000'; throughput = [int]$offer.manual; ts = $null
            }
            if ($offer.mode -eq 'autoscale') {
                $resource.throughput = [int]($offer.max / 10); $resource.minimumThroughput = '1000'
                $resource.autoscaleSettings = [ordered]@{ autoUpgradePolicy = $null; maxThroughput = [int]$offer.max; targetMaxThroughput = $null }
            }
            if ($env:DR_COSMOS_FAULT -eq 'pending' -and $operation -eq 'show') { $resource.offerReplacePending = 'true' }
            $offerId = if ($kind -eq 'database') { "$dbId/throughputSettings/default" } else { "$dbId/containers/$name/throughputSettings/default" }
            $offerType = if ($kind -eq 'database') { 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/throughputSettings' } else { 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/throughputSettings' }
            $offerName = if ($kind -eq 'database') { 'Tb7w' } else { "Rk$($name.Length)q" }
            if ($kind -eq 'container' -and $env:DR_COSMOS_FAULT -eq 'offer-type-database') {
                $offerType = 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/throughputSettings'
            }
            if ($kind -eq 'container' -and $env:DR_COSMOS_FAULT -eq 'offer-type-missing') { $offerType = $null }
            if ($kind -eq 'database' -and $env:DR_COSMOS_FAULT -eq 'offer-id-other-database') {
                $offerId = $dbId.Replace('/sqlDatabases/fixturedb', '/sqlDatabases/otherdb') + '/throughputSettings/default'
            }
            if ($kind -eq 'container' -and $env:DR_COSMOS_FAULT -eq 'offer-id-not-throughput') { $offerId = "$dbId/containers/$name" }
            if ($kind -eq 'container' -and $env:DR_COSMOS_FAULT -eq 'offer-id-sqlcontainers') {
                $offerId = "$dbId/sqlContainers/$name/throughputSettings/default"
            }
            if ($kind -eq 'container' -and $env:DR_COSMOS_FAULT -eq 'offer-id-other-container') {
                $offerId = "$dbId/sqlContainers/other-container/throughputSettings/default"
            }
            if ($kind -eq 'container' -and $env:DR_COSMOS_FAULT -eq 'offer-id-case-mismatch') {
                $offerId = "$dbId/sqlContainers/$($name.ToUpperInvariant())/throughputSettings/default"
            }
            return ([ordered]@{
                id = $offerId; identity = $null; location = $null; name = $offerName; resource = $resource
                resourceGroup = 'fixture-rg'; systemData = $null; tags = $null; type = $offerType
            } | ConvertTo-Json -Depth 20 -Compress)
        }
        throw "Unexpected az call in offline test: $command"
    }
    $optional = @{}
    if ($ApproveReduction) { $optional.ApproveCosmosThroughputReduction = $true }
    & (Join-Path $root 'infra\dr\Invoke-DrStandby.ps1') -Phase Data -ConfigPath $ConfigPath -Apply:$Apply @optional
    exit $LASTEXITCODE
}

$script:passed = 0; $script:failed = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $Name" -ForegroundColor Red }
}
$scratch = Join-Path $root ".env.public-test-scratch\dr-cosmos-$PID"
if (Test-Path -LiteralPath $scratch) { throw "Fixture path already exists: $scratch" }
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $sub = '00000000-0000-4000-8000-000000000002'
    $tenant = '00000000-0000-4000-8000-000000000001'
    $vnetId = "/subscriptions/$sub/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/fixture-vnet"
    $primary = Get-Content -LiteralPath (Join-Path $root 'infra\staged\staged.config.example.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $primary.tenantId = $tenant; $primary.subscriptionId = $sub; $primary.resourceGroup = 'fixture-rg'
    $primary.cosmos.databaseName = 'fixturedb'
    $primary.network.existing = @{
        functionsSubnetId = "$vnetId/subnets/functions"; privateEndpointSubnetId = "$vnetId/subnets/private-endpoints"
        apimSubnetId = "$vnetId/subnets/apim"
    }
    $primaryPath = Join-Path $scratch 'primary.json'
    $primary | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $primaryPath
    $primaryStateDir = Join-Path $scratch 'primary-state'
    New-Item -ItemType Directory -Path $primaryStateDir | Out-Null
    $primaryS1 = @{
        names = @{ deploymentPrefix = 'fixture'; apps = @{ resolver = @{ functionApp = 'fixture-resolver'; storageAccount = 'fixtureres' } } }
        cosmosAccountId = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.DocumentDB/databaseAccounts/fixture-cosmos"
        apimId = ''; cosmosEndpoint = 'https://fixture-cosmos.documents.azure.com'
    }
    @{ stageLayout = 2; stages = @{ '1' = @{ outputs = $primaryS1 }; '2' = @{ outputs = @{ marker = 'schema' } }; '4' = @{ outputs = @{ groups = @{} } } } } |
        ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $primaryStateDir 'state.json')
    $standbyDir = Join-Path $scratch 'standby'
    $config = @{
        tenantId = $tenant; subscriptionId = $sub; tags = @{ workload = 'fixture' }
        primary = @{ location = 'eastus2'; addressSpaces = @('10.40.0.0/16'); peer = $false }
        secondary = @{
            location = 'westus2'; resourceGroup = 'fixture-rg'; vnetName = 'fixture-vnet'
            networkMode = 'existing'; existingVnetId = $vnetId; addressSpace = '10.80.0.0/24'
            subnets = @{
                apim = @{ name = 'apim'; prefix = '10.80.0.0/27' }
                functions = @{ name = 'functions'; prefix = '10.80.0.32/27' }
                privateEndpoints = @{ name = 'private-endpoints'; prefix = '10.80.0.64/26' }
            }
        }
        dnsZones = @{ subscriptionId = $sub; resourceGroup = 'network-rg'; zoneNames = @('privatelink.documents.azure.com') }
        standby = @{
            stagedConfigPath = $primaryPath; stagedStateDirectory = $primaryStateDir; stateDirectory = $standbyDir
            nameSuffix = 'b'; functionsPublicNetworkAccess = 'Disabled'; storagePublicNetworkAccess = 'Disabled'
            apim = @{ publisherEmail = 'admin@example.invalid'; publisherName = 'Example'; sku = 'StandardV2' }
        }
        cosmos = @{ convertServerless = $false; autoscaleMaxThroughput = 1000 }
    }
    $configPath = Join-Path $scratch 'dr.json'
    $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath
    $env:DR_COSMOS_FIXTURE = Join-Path $scratch 'fixture.json'
    $env:DR_COSMOS_LOG = Join-Path $scratch 'az.log'
    $env:DR_COSMOS_FAULT = ''
    $fixture = @{
        subscription = $sub; database = @{ mode = 'autoscale'; max = 1000 }; failover = $false
        regions = @(@{ locationName = 'East US 2'; failoverPriority = 0; isZoneRedundant = $false })
        containers = @(0..8 | ForEach-Object { @{ name = "container$_"; mode = 'shared' } })
    }
    $fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $env:DR_COSMOS_FIXTURE
    function Run-Data([bool]$ShouldApply, [bool]$ApproveReduction = $false) {
        if (Test-Path -LiteralPath $env:DR_COSMOS_LOG) { Remove-Item -LiteralPath $env:DR_COSMOS_LOG }
        $childArgs = @('-NoProfile', '-File', $PSCommandPath, '-Child', '-ConfigPath', $configPath)
        if ($ShouldApply) { $childArgs += '-Apply' }
        if ($ApproveReduction) { $childArgs += '-ApproveReduction' }
        $output = & pwsh @childArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
        $calls = if (Test-Path -LiteralPath $env:DR_COSMOS_LOG) {
            @(Get-Content -LiteralPath $env:DR_COSMOS_LOG | ForEach-Object { ($_ | ConvertFrom-Json) -join ' ' })
        } else { @() }
        return @{ code = $code; output = $output; calls = $calls }
    }
    $preview = Run-Data $false
    Check 'preview reports database autoscale and a shared container without mutations' (
        $preview.code -eq 0 -and $preview.output -match '(?s)database.*fixturedb.*1000' -and
        $preview.output -match '(?s)container0.*shared' -and
        @($preview.calls | Where-Object { $_ -match '^rest --method patch |^cosmosdb .* (migrate|update) ' }).Count -eq 0)
    $applyResult = Run-Data $true
    if ($applyResult.code -ne 0) { Write-Host "Shared database diagnostic: $($applyResult.output)" }
    $after = Get-Content -LiteralPath $env:DR_COSMOS_FIXTURE -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    Check 'shared database Data Apply succeeds without changing container offers' (
        $applyResult.code -eq 0 -and @($after.regions).Count -eq 2 -and $after.failover -and
        @($applyResult.calls | Where-Object { $_ -match '^cosmosdb sql (database|container) throughput (migrate|update) ' }).Count -eq 0 -and
        (Test-Path -LiteralPath (Join-Path $standbyDir 'standby.state.json')))

    function Reset-Fixture($Database, [object[]]$Containers, [int]$Max = 1000, [string]$Fault = '') {
        $fixture.database = $Database; $fixture.containers = $Containers; $fixture.failover = $false; $fixture.capacity = 'Provisioned'
        $fixture.regions = @(@{ locationName = 'East US 2'; failoverPriority = 0; isZoneRedundant = $false })
        $fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $env:DR_COSMOS_FIXTURE
        $config.cosmos.autoscaleMaxThroughput = $Max; $config.cosmos.convertServerless = $false
        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath
        $env:DR_COSMOS_FAULT = $Fault
        if (Test-Path -LiteralPath $standbyDir) { Remove-Item -LiteralPath $standbyDir -Recurse -Force }
    }
    function Get-Writes($Result) {
        @($Result.calls | Where-Object { $_ -match '^rest --method patch |^cosmosdb update |^cosmosdb sql (database|container) throughput (migrate|update) ' })
    }

    $repeat = Run-Data $true
    Check 'repeating completed shared Data Apply is idempotent' ($repeat.code -eq 0 -and @(Get-Writes $repeat).Count -eq 0)
    Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(
        @{ name = 'container0'; mode = 'manual'; manual = 400 },
        @{ name = 'container1'; mode = 'shared' }
    ) 2000
    $mixedPreview = Run-Data $false
    Check 'mixed preview enumerates database increase, dedicated migration, and shared container' (
        $mixedPreview.code -eq 0 -and $mixedPreview.output -match '(?s)database.*1000.*2000' -and
        $mixedPreview.output -match '(?s)container0.*manual.*400.*2000' -and $mixedPreview.output -match '(?s)container1.*shared' -and
        @(Get-Writes $mixedPreview).Count -eq 0)
    $mixedBlocked = Run-Data $true
    Check 'manual to autoscale reduction of guaranteed throughput needs explicit approval' (
        $mixedBlocked.code -ne 0 -and $mixedBlocked.output -match 'cosmos_throughput_reduction_approval_required' -and
        @(Get-Writes $mixedBlocked).Count -eq 0)
    $mixed = Run-Data $true $true
    if ($mixed.code -ne 0) { Write-Host "Mixed diagnostic: $($mixed.output)" }
    $mixedAfter = Get-Content -LiteralPath $env:DR_COSMOS_FIXTURE -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    Check 'mixed Apply changes the database and dedicated container, never the shared container' (
        $mixed.code -eq 0 -and $mixedAfter.database.max -eq 2000 -and $mixedAfter.containers[0].max -eq 2000 -and
        $mixedAfter.containers[1].mode -ceq 'shared' -and
        @($mixed.calls | Where-Object { $_ -match '^cosmosdb sql database throughput update ' }).Count -eq 1 -and
        @($mixed.calls | Where-Object { $_ -match '^cosmosdb sql container throughput migrate .*--name container0\b' }).Count -eq 1 -and
        @($mixed.calls | Where-Object { $_ -match '^cosmosdb sql container throughput update .*--name container1\b' }).Count -eq 0)

    Reset-Fixture $null @(@{ name = 'container0'; mode = 'manual'; manual = 400 }) 4000
    $migrationPreview = Run-Data $false
    $migrationBlocked = Run-Data $true
    Check 'manual migration warns about a possible temporary reduction and requires explicit approval' (
        $migrationPreview.code -eq 0 -and $migrationPreview.output -match '(?s)temporary.*reduction' -and
        $migrationBlocked.code -ne 0 -and $migrationBlocked.output -match 'cosmos_throughput_reduction_approval_required' -and
        @(Get-Writes $migrationBlocked).Count -eq 0)
    $migrationApproved = Run-Data $true $true
    Check 'approved manual migration reaches the reviewed maximum' (
        $migrationApproved.code -eq 0 -and
        @($migrationApproved.calls | Where-Object { $_ -match '^cosmosdb sql container throughput migrate ' }).Count -eq 1 -and
        @($migrationApproved.calls | Where-Object { $_ -match '^cosmosdb sql container throughput update ' }).Count -eq 1)

    Reset-Fixture $null @(@{ name = 'container0'; mode = 'autoscale'; max = 1000 })
    $dedicatedPreview = Run-Data $false
    $dedicated = Run-Data $true
    if ($dedicatedPreview.code -ne 0 -or $dedicated.code -ne 0) {
        Write-Host "Dedicated diagnostic: preview exit $($dedicatedPreview.code) $($dedicatedPreview.output); apply exit $($dedicated.code) $($dedicated.output)"
    }
    Check 'dedicated-only database accepts absent shared offer when every container has its own' (
        $dedicatedPreview.code -eq 0 -and $dedicatedPreview.output -match '(?s)container0.*1000' -and
        $dedicated.code -eq 0 -and @($dedicated.calls | Where-Object { $_ -match '^cosmosdb sql database throughput (migrate|update) ' }).Count -eq 0)

    Reset-Fixture $null @(@{ name = 'container0'; mode = 'autoscale'; max = 1000 }) 1000 'database-offer-option'
    $contradictoryDatabase = Run-Data $false
    Check 'database offer options contradicting a missing offer fail closed' (
        $contradictoryDatabase.code -ne 0 -and $contradictoryDatabase.output -match 'cosmos_throughput_scope_unknown' -and
        @(Get-Writes $contradictoryDatabase).Count -eq 0)

    Reset-Fixture $null @(@{ name = 'container0'; mode = 'autoscale'; max = 1000 }) 1000 'offer-id-sqlcontainers'
    $documentedOfferPreview = Run-Data $false
    $documentedOfferApply = Run-Data $true
    Check 'dedicated throughput accepts the documented sqlContainers response ID' (
        $documentedOfferPreview.code -eq 0 -and $documentedOfferPreview.output -match '(?s)container0.*1000' -and
        $documentedOfferApply.code -eq 0)
    Reset-Fixture $null @(@{ name = 'container0'; mode = 'autoscale'; max = 1000 }) 1000 'offer-id-other-container'
    $wrongOffer = Run-Data $false
    Check 'throughput response for a different container fails closed' (
        $wrongOffer.code -ne 0 -and $wrongOffer.output -match 'cosmos_throughput_invalid' -and @(Get-Writes $wrongOffer).Count -eq 0)
    Reset-Fixture $null @(@{ name = 'container0'; mode = 'autoscale'; max = 1000 }) 1000 'offer-id-case-mismatch'
    $wrongOfferCase = Run-Data $false
    Check 'throughput response for a differently cased container fails closed' (
        $wrongOfferCase.code -ne 0 -and $wrongOfferCase.output -match 'cosmos_throughput_invalid' -and @(Get-Writes $wrongOfferCase).Count -eq 0)
    foreach ($fault in 'offer-type-database', 'offer-type-missing', 'offer-id-not-throughput') {
        Reset-Fixture $null @(@{ name = 'container0'; mode = 'autoscale'; max = 1000 }) 1000 $fault
        $badOffer = Run-Data $false
        Check "$fault container throughput response fails closed" (
            $badOffer.code -ne 0 -and $badOffer.output -match 'cosmos_throughput_invalid' -and @(Get-Writes $badOffer).Count -eq 0)
    }
    Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(@{ name = 'container0'; mode = 'shared' }) 1000 'offer-id-other-database'
    $otherDatabaseOffer = Run-Data $false
    Check 'database throughput response for another database fails closed' (
        $otherDatabaseOffer.code -ne 0 -and $otherDatabaseOffer.output -match 'cosmos_throughput_invalid' -and @(Get-Writes $otherDatabaseOffer).Count -eq 0)

    Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(@{ name = 'container0'; mode = 'shared' }) 1000 'known-notfound-suffix'
    $knownSuffix = Run-Data $false
    Check 'the documented NotFound help-link suffix is accepted only with a verified shared database' (
        $knownSuffix.code -eq 0 -and $knownSuffix.output -match '(?s)container0.*shared' -and @(Get-Writes $knownSuffix).Count -eq 0)

    foreach ($fault in 'core-notfound-basic', 'core-notfound-diagnostics') {
        Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(@{ name = 'container0'; mode = 'shared' }) 1000 $fault
        $corePreview = Run-Data $false
        $coreApply = Run-Data $true
        Check "$fault previews and applies shared throughput without changing its offer" (
            $corePreview.code -eq 0 -and $corePreview.output -match '(?s)container0.*shared' -and
            @(Get-Writes $corePreview).Count -eq 0 -and $coreApply.code -eq 0 -and
            @($coreApply.calls | Where-Object { $_ -match '^cosmosdb sql (database|container) throughput (migrate|update) ' }).Count -eq 0)
    }

    foreach ($fault in 'database-forbidden', 'list-forbidden', 'container-forbidden', 'container-network', 'container-throttled', 'other-notfound', 'notfound-with-forbidden', 'notfound-suffix-with-forbidden', 'core-notfound-auth', 'core-notfound-auth-substring', 'core-notfound-network', 'core-notfound-network-dns', 'core-notfound-status', 'core-notfound-transport', 'core-notfound-other-code', 'core-notfound-other-equals', 'core-notfound-status-error-code', 'core-notfound-prefixed-error-code', 'core-notfound-other-message', 'database-malformed', 'database-missing', 'database-id-case-mismatch', 'container-disappeared', 'container-id-case-mismatch', 'container-dedicated-option', 'pending') {
        Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(@{ name = 'container0'; mode = 'shared' }) 1000 $fault
        $bad = Run-Data $false
        $expect = switch ($fault) {
            'database-forbidden' { 'AuthorizationFailed' }
            'list-forbidden' { 'AuthorizationFailed' }
            'container-forbidden' { 'AuthorizationFailed' }
            'container-network' { 'connection timed out' }
            'container-throttled' { 'TooManyRequests' }
            'other-notfound' { 'Some other endpoint' }
            'notfound-with-forbidden' { 'AuthorizationFailed' }
            'notfound-suffix-with-forbidden' { 'AuthorizationFailed' }
            'core-notfound-auth' { 'AuthorizationFailed' }
            'core-notfound-auth-substring' { 'AuthorizationFailedException' }
            'core-notfound-network' { 'connection timed out' }
            'core-notfound-network-dns' { 'DNS name resolution failed' }
            'core-notfound-status' { 'StatusCode: 403' }
            'core-notfound-transport' { 'TransportException: SocketException' }
            'core-notfound-other-code' { 'BadRequest' }
            'core-notfound-other-equals' { 'ErrorCode=Conflict' }
            'core-notfound-status-error-code' { 'Status Error Code: Conflict' }
            'core-notfound-prefixed-error-code' { 'BackendErrorCode: Conflict' }
            'core-notfound-other-message' { 'Some other endpoint' }
            'database-malformed' { 'cosmos_throughput_invalid' }
            'database-missing' { 'cosmos_resource_unverified' }
            'database-id-case-mismatch' { 'cosmos_resource_unverified' }
            'container-disappeared' { 'cosmos_resource_unverified' }
            'container-id-case-mismatch' { 'cosmos_resource_unverified' }
            'container-dedicated-option' { 'cosmos_throughput_scope_unknown' }
            'pending' { 'cosmos_throughput_pending' }
        }
        Check "$fault fails closed with useful diagnosis and no writes" (
            $bad.code -ne 0 -and $bad.output -match $expect -and @(Get-Writes $bad).Count -eq 0)
    }
    Reset-Fixture $null @(@{ name = 'container0'; mode = 'shared' })
    $noParentOffer = Run-Data $false
    Check 'a 404 without a verified database offer is not treated as shared' (
        $noParentOffer.code -ne 0 -and $noParentOffer.output -match 'cosmos_throughput_scope_unknown' -and @(Get-Writes $noParentOffer).Count -eq 0)

    Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(
        @{ name = 'container0'; mode = 'manual'; manual = 400 },
        @{ name = 'container1'; mode = 'shared' }
    ) 2000
    $null = Run-Data $false
    $env:DR_COSMOS_FAULT = 'container1-forbidden'
    $lateReadError = Run-Data $true $true
    Check 'a late container read failure stops before earlier offer mutations' (
        $lateReadError.code -ne 0 -and $lateReadError.output -match 'AuthorizationFailed' -and @(Get-Writes $lateReadError).Count -eq 0)

    Reset-Fixture @{ mode = 'autoscale'; max = 4000 } @(@{ name = 'container0'; mode = 'shared' })
    $reductionPreview = Run-Data $false
    $reductionBlocked = Run-Data $true
    Check 'preview reports an autoscale reduction and Apply requires explicit approval' (
        $reductionPreview.code -eq 0 -and $reductionPreview.output -match '(?s)4000.*1000' -and
        $reductionPreview.output -match 'reduc' -and $reductionBlocked.code -ne 0 -and
        $reductionBlocked.output -match 'cosmos_throughput_reduction_approval_required' -and @(Get-Writes $reductionBlocked).Count -eq 0)
    $approvedReduction = Run-Data $true $true
    Check 'reviewed reduction is possible only with explicit approval' (
        $approvedReduction.code -eq 0 -and @($approvedReduction.calls | Where-Object { $_ -match '^cosmosdb sql database throughput update ' }).Count -eq 1)

    Reset-Fixture @{ mode = 'autoscale'; max = 4000 } @(@{ name = 'container0'; mode = 'shared' })
    $null = Run-Data $false
    $drifted = Get-Content -LiteralPath $env:DR_COSMOS_FIXTURE -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    $drifted.database.max = 5000
    $drifted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $env:DR_COSMOS_FIXTURE
    $stale = Run-Data $true $true
    Check 'a changed offer invalidates preview approval before any write' (
        $stale.code -ne 0 -and $stale.output -match 'cosmos_preview_stale' -and @(Get-Writes $stale).Count -eq 0)
    Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(@{ name = 'container0'; mode = 'shared' })
    $withoutPreview = Run-Data $true
    Check 'Apply requires an up-to-date throughput preview' (
        $withoutPreview.code -ne 0 -and $withoutPreview.output -match 'cosmos_preview_required' -and @(Get-Writes $withoutPreview).Count -eq 0)

    Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(@{ name = 'container0'; mode = 'shared' })
    $null = Run-Data $false
    $env:DR_COSMOS_FAULT = 'container-network'
    $failedPreview = Run-Data $false
    $env:DR_COSMOS_FAULT = ''
    $afterFailedPreview = Run-Data $true
    Check 'a failed preview invalidates an older successful preview' (
        $failedPreview.code -ne 0 -and $failedPreview.output -match 'connection timed out' -and
        $afterFailedPreview.code -ne 0 -and $afterFailedPreview.output -match 'cosmos_preview_required' -and
        @(Get-Writes $afterFailedPreview).Count -eq 0)

    Reset-Fixture $null @(@{ name = 'container0'; mode = 'manual'; manual = 400 }) 1000 'migration-high'
    $null = Run-Data $false
    $highMigration = Run-Data $true $true
    Check 'unexpectedly high migration result stops for new review instead of silently lowering' (
        $highMigration.code -ne 0 -and $highMigration.output -match 'cosmos_migration_repreview_required' -and
        @($highMigration.calls | Where-Object { $_ -match '^cosmosdb sql container throughput migrate ' }).Count -eq 1 -and
        @($highMigration.calls | Where-Object { $_ -match '^cosmosdb sql container throughput update |^rest --method patch ' }).Count -eq 0)

    Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(@{ name = 'container0'; mode = 'shared' }) 2000 'update-not-applied'
    $null = Run-Data $false
    $unverified = Run-Data $true
    Check 'unverified throughput update stops before regional changes' (
        $unverified.code -ne 0 -and $unverified.output -match 'cosmos_throughput_readback_failed' -and
        @($unverified.calls | Where-Object { $_ -match '^rest --method patch |^cosmosdb update ' }).Count -eq 0)
    # A Front Door state cleanup failure in the driver's finally must not hide the phase failure.
    Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(@{ name = 'container0'; mode = 'shared' }) 2000 ''
    $null = Run-Data $false
    $env:DR_COSMOS_FD_STATE = Join-Path $standbyDir 'frontdoor-state.json'
    Set-Content -LiteralPath $env:DR_COSMOS_FD_STATE -Value '{"approvedConnections":[]}'
    $env:DR_COSMOS_FAULT = 'update-not-applied-fd-corrupt'
    $bothFailed = Run-Data $true
    Check 'a Front Door cleanup failure keeps the phase failure and reports both' (
        $bothFailed.code -ne 0 -and $bothFailed.output -match 'cosmos_throughput_readback_failed' -and
        $bothFailed.output -match 'frontdoor_state_cleanup_failed')
    Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(@{ name = 'container0'; mode = 'shared' }) 2000 'update-not-applied'
    $null = Run-Data $false
    $null = Run-Data $true
    $env:DR_COSMOS_FAULT = ''
    $afterPartialApply = Run-Data $true
    Check 'a failed Apply cannot reuse its earlier preview for another mutation' (
        $afterPartialApply.code -ne 0 -and $afterPartialApply.output -match 'cosmos_preview_required' -and
        @(Get-Writes $afterPartialApply).Count -eq 0)

    Reset-Fixture @{ mode = 'autoscale'; max = 1000 } @(@{ name = 'container0'; mode = 'shared' })
    $null = Run-Data $false
    $env:DR_COSMOS_FAULT = 'account-drift'
    $accountDrift = Run-Data $true
    Check 'account location drift after inventory stops before regional mutation' (
        $accountDrift.code -ne 0 -and $accountDrift.output -match 'cosmos_account_changed' -and
        @($accountDrift.calls | Where-Object { $_ -match '^rest --method patch |^cosmosdb update ' }).Count -eq 0)

    Reset-Fixture $null @(@{ name = 'container0'; mode = 'manual'; manual = 5000 })
    $serverless = Get-Content -LiteralPath $env:DR_COSMOS_FIXTURE -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    $serverless.capacity = 'Serverless'
    $serverless | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $env:DR_COSMOS_FIXTURE
    $config.cosmos.convertServerless = $true
    $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath
    $serverlessPreview = Run-Data $false
    $serverlessApply = Run-Data $true
    Check 'serverless conversion pauses for a fresh throughput preview before further writes' (
        $serverlessPreview.code -eq 0 -and $serverlessPreview.output -match '(?s)5000.*preview' -and
        @(Get-Writes $serverlessPreview).Count -eq 0 -and $serverlessApply.code -ne 0 -and
        $serverlessApply.output -match 'cosmos_conversion_repreview_required' -and
        @($serverlessApply.calls | Where-Object { $_ -match '^rest --method patch ' }).Count -eq 1 -and
        @($serverlessApply.calls | Where-Object { $_ -match '^cosmosdb sql .* throughput (migrate|update) |^cosmosdb update ' }).Count -eq 0)

    Reset-Fixture $null @(@{ name = 'container0'; mode = 'manual'; manual = 5000 }) 1000 'account-pending'
    $serverless = Get-Content -LiteralPath $env:DR_COSMOS_FIXTURE -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    $serverless.capacity = 'Serverless'
    $serverless | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $env:DR_COSMOS_FIXTURE
    $config.cosmos.convertServerless = $true
    $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath
    $pendingPreview = Run-Data $false
    $pendingApply = Run-Data $true
    Check 'a non-succeeded serverless account cannot be converted' (
        $pendingPreview.code -ne 0 -and $pendingPreview.output -match 'cosmos_account_pending' -and
        $pendingApply.code -ne 0 -and $pendingApply.output -match 'cosmos_account_pending' -and
        @(Get-Writes $pendingApply).Count -eq 0)

    $wrapperWorks = $false
    try {
        $runbook = Get-Content -LiteralPath (Join-Path $root 'docs\runbooks\DR-STANDBY-CLOUD-SHELL.md') -Raw
        $wrapper = [regex]::Match($runbook, '(?ms)^function Invoke-DrPhase \{.*?^\}').Value
        if (-not $wrapper) { throw 'Invoke-DrPhase wrapper not found in runbook.' }
        $wrapperWorks = & {
            param($Definition, $FixtureRoot, $RepoRoot)
            $logs = $FixtureRoot; $repo = $RepoRoot; $cfg = 'fixture.json'
            function pwsh { $script:DR_COSMOS_WRAPPER_ARGS = @($args); $global:LASTEXITCODE = 0 }
            . ([scriptblock]::Create($Definition))
            Invoke-DrPhase -Phase Data -Apply -ApproveCosmosThroughputReduction | Out-Null
            return ($script:DR_COSMOS_WRAPPER_ARGS -contains '-ApproveCosmosThroughputReduction')
        } $wrapper $scratch $root
    } catch { $wrapperWorks = $false }
    Check 'Cloud Shell wrapper forwards explicit throughput reduction approval' $wrapperWorks

    # Real Azure CLI 2.92 captures (identifiers replaced): offers are named by an internal ID, not 'default'.
    $cli = Join-Path $PSScriptRoot 'fixtures\dr-cosmos-cli'
    $cosmosModule = Import-Module (Join-Path $root 'infra\dr\DrCosmosThroughput.psm1') -Force -DisableNameChecking -PassThru
    $captureContext = @{
        subscription = '00000000-0000-4000-8000-0000000000c1'; resourceGroup = 'fixture-rg'; account = 'fixture-cosmos'; database = 'fixturedb'
        accountId = '/subscriptions/00000000-0000-4000-8000-0000000000c1/resourceGroups/fixture-rg/providers/Microsoft.DocumentDB/databaseAccounts/fixture-cosmos'
    }
    $readCapture = { param($Kind, $Name, $File)
        $json = Get-Content -LiteralPath (Join-Path $cli $File) -Raw
        & $cosmosModule { param($c, $k, $n, $j) Get-DrCosmosOffer $c $k $n { $j | ConvertFrom-Json -AsHashtable -Depth 100 }.GetNewClosure() } $captureContext $Kind $Name $json
    }
    try { $realDatabase = & $readCapture 'database' 'fixturedb' 'database-throughput-show.autoscale.json' } catch { $realDatabase = $_.Exception.Message }
    Check 'real CLI database offer (internal-ID name) reads as autoscale 1000 with minimum 1000' (
        $realDatabase -is [Collections.IDictionary] -and $realDatabase.mode -ceq 'autoscale' -and $realDatabase.value -eq 1000 -and $realDatabase.minimum -eq 1000)
    try { $realContainer = & $readCapture 'container' 'container0' 'container-throughput-show.manual.json' } catch { $realContainer = $_.Exception.Message }
    Check 'real CLI dedicated container offer reads as manual 400' (
        $realContainer -is [Collections.IDictionary] -and $realContainer.mode -ceq 'manual' -and $realContainer.value -eq 400 -and $realContainer.minimum -eq 400)
    try { $null = & $readCapture 'container' 'container1' 'container-throughput-show.manual.json'; $otherParent = 'accepted' } catch { $otherParent = $_.Exception.Message }
    Check 'real CLI container offer fails closed for a different container' ($otherParent -match 'cosmos_throughput_invalid')
    try { $null = & $readCapture 'database' 'fixturedb' 'container-throughput-show.manual.json'; $wrongKind = 'accepted' } catch { $wrongKind = $_.Exception.Message }
    Check 'real CLI container offer fails closed where a database offer is expected' ($wrongKind -match 'cosmos_throughput_invalid')
    $realNotFound = Get-Content -LiteralPath (Join-Path $cli 'container-throughput-show.notfound.txt') -Raw
    Check 'real CLI NotFound for a shared-throughput container is recognised as no dedicated offer' (
        (& $cosmosModule { param($m) Test-DrCosmosMissingOffer $m } $realNotFound) -eq $true)

    Write-Host "DR Cosmos throughput: $script:passed passed, $script:failed failed."
    if ($script:failed) { exit 1 }
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
