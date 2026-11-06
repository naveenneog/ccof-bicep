# Offline Grants-preview tests against the actual DR standby driver.
#Requires -Version 7.0
param([switch]$Child, [switch]$Apply, [string]$ConfigPath)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($Child) {
    function global:az {
        $arguments = @($args)
        Add-Content -LiteralPath $env:DR_APIM_LOG -Value ($arguments | ConvertTo-Json -Compress)
        $global:LASTEXITCODE = 0
        $command = $arguments -join ' '
        if ($command -match '^rest --method get ' -and $command.Contains("$($env:DR_STANDBY_APIM_ID)?api-version=")) {
            return (@{
                id = $env:DR_STANDBY_APIM_ID
                identity = @{ principalId = '00000000-0000-4000-8000-000000000003' }
                properties = @{ gatewayUrl = 'https://fixture-b-apim.azure-api.net' }
            } | ConvertTo-Json -Depth 10 -Compress)
        }
        if ($command -match '^deployment group what-if ') { return '{"changes":[]}' }
        throw "Unexpected az call in offline APIM test: $command"
    }
    & (Join-Path $root 'infra\dr\Invoke-DrStandby.ps1') -Phase Grants -ConfigPath $ConfigPath -Apply:$Apply
    exit $LASTEXITCODE
}

$script:passed = 0; $script:failed = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $Name" -ForegroundColor Red }
}
$scratch = Join-Path $root ".env.public-test-scratch\dr-apim-$PID"
if (Test-Path -LiteralPath $scratch) { throw "Fixture path already exists: $scratch" }
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $sub = '00000000-0000-4000-8000-000000000002'
    $tenant = '00000000-0000-4000-8000-000000000001'
    $apimSub = '00000000-0000-4000-8000-000000000005'
    $vnetId = "/subscriptions/$sub/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/fixture-vnet"
    $primary = Get-Content -LiteralPath (Join-Path $root 'infra\staged\staged.config.example.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $primary.tenantId = $tenant; $primary.subscriptionId = $sub; $primary.resourceGroup = 'fixture-rg'
    $primary.network.existing = @{
        functionsSubnetId = "$vnetId/subnets/functions"; privateEndpointSubnetId = "$vnetId/subnets/private-endpoints"
        apimSubnetId = "$vnetId/subnets/apim"
    }
    $primaryPath = Join-Path $scratch 'primary.json'
    $primaryStateDir = Join-Path $scratch 'primary-state'
    $standbyDir = Join-Path $scratch 'standby'
    New-Item -ItemType Directory -Path $primaryStateDir | Out-Null
    $primaryS1 = @{
        names = @{ deploymentPrefix = 'fixture'; apps = @{ resolver = @{ functionApp = 'fixture-resolver'; storageAccount = 'fixtureres' } } }
        cosmosAccountId = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.DocumentDB/databaseAccounts/fixture-cosmos"
        cosmosEndpoint = 'https://fixture-cosmos.documents.azure.com'; apimId = ''; apimName = ''
    }
    $standbyId = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.ApiManagement/service/fixture-b-apim"
    $standbyS1 = @{
        names = @{ deploymentPrefix = 'fixtureb'; subscriptionId = $sub; resourceGroup = 'fixture-rg'
            cosmosAccount = 'fixture-cosmos'; logAnalyticsWorkspace = 'fixture-workspace'
            apps = @{ resolver = @{ functionApp = 'fixture-b-resolver'; storageAccount = 'fixturebres' } } }
        principals = @{ resolver = '00000000-0000-4000-8000-000000000004' }
        apimId = $standbyId; apimName = 'fixture-b-apim'
    }
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
    $env:DR_APIM_LOG = Join-Path $scratch 'az.log'
    $env:DR_STANDBY_APIM_ID = $standbyId
    $existing = @{ subscriptionId = $apimSub; resourceGroup = 'shared-apim-rg'; name = 'shared-primary' }
    $existingId = "/subscriptions/$apimSub/resourceGroups/shared-apim-rg/providers/Microsoft.ApiManagement/service/shared-primary"
    function Reset-Case([string]$StateId, [string]$StateName, $Existing) {
        $primary.apim.existing = $Existing
        $primary | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $primaryPath
        $primaryS1.apimId = $StateId; $primaryS1.apimName = $StateName
        @{ stageLayout = 2; stages = @{ '1' = @{ outputs = $primaryS1 }; '2' = @{ outputs = @{ marker = 'schema' } }; '4' = @{ outputs = @{ groups = @{} } } } } |
            ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $primaryStateDir 'state.json')
        if (Test-Path -LiteralPath $standbyDir) { Remove-Item -LiteralPath $standbyDir -Recurse -Force }
        New-Item -ItemType Directory -Path $standbyDir | Out-Null
        @{ stageLayout = 2; stages = @{ '1' = @{ outputs = $standbyS1 }; '2' = @{ outputs = @{ marker = 'schema' } } } } |
            ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $standbyDir 'state.json')
        @{ schema = 'ccof.dr.standby.v1'; phases = @{ Shells = @{ completedAt = '2026-01-01T00:00:00Z'; outputs = @{ ready = $true } } } } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $standbyDir 'standby.state.json')
    }
    function Run-Grants([bool]$ShouldApply = $false) {
        if (Test-Path -LiteralPath $env:DR_APIM_LOG) { Remove-Item -LiteralPath $env:DR_APIM_LOG }
        $arguments = @('-NoProfile', '-File', $PSCommandPath, '-Child', '-ConfigPath', $configPath)
        if ($ShouldApply) { $arguments += '-Apply' }
        $output = & pwsh @arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        $calls = if (Test-Path -LiteralPath $env:DR_APIM_LOG) {
            @(Get-Content -LiteralPath $env:DR_APIM_LOG | ForEach-Object { ($_ | ConvertFrom-Json) -join ' ' })
        } else { @() }
        $generatedPath = Join-Path $standbyDir 'standby.staged.config.json'
        $generated = if (Test-Path -LiteralPath $generatedPath) { Get-Content -LiteralPath $generatedPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { @{} }
        return @{ code = $code; output = $output; calls = $calls; generated = $generated }
    }

    Reset-Case '' '' $existing
    $result = Run-Grants
    if ($result.code -ne 0) { Write-Host "Existing primary APIM Grants preview diagnostic: $($result.output)" }
    Check 'Grants previews with blank primary Stage 1 APIM outputs and both correct gateway IDs' (
        $result.code -eq 0 -and $result.output -match 'what-if dr-standby-stage3-grants' -and
        $result.output -match [regex]::Escape($existingId) -and
        ($result.generated.reconciler.ledgerGatewayResourceIds -join '|') -ceq "$existingId|$standbyId" -and
        ($result.generated.admin.gatewayResourceIds -join '|') -ceq "$existingId|$standbyId" -and
        @($result.calls | Where-Object { $_ -match '^deployment group what-if ' }).Count -eq 1 -and
        @($result.calls | Where-Object { $_ -match '^deployment group create ' }).Count -eq 0)

    Reset-Case '   ' '' $existing
    $result = Run-Grants
    Check 'a whitespace-only primary APIM ID uses the complete existing APIM configuration' (
        $result.code -eq 0 -and ($result.generated.admin.gatewayResourceIds -join '|') -ceq "$existingId|$standbyId")

    foreach ($missing in 'all', 'subscriptionId', 'resourceGroup', 'name') {
        $partial = if ($missing -eq 'all') { $null } else { @{} + $existing }
        if ($partial) { $partial[$missing] = ' ' }
        Reset-Case '' '' $partial
        $result = Run-Grants
        Check "Grants refuses missing primary APIM $missing with actionable guidance and no Azure call" (
            $result.code -ne 0 -and $result.output -match 'primary_apim_configuration_missing' -and
            $result.output -match 'apim\.existing' -and @($result.calls).Count -eq 0)
    }
    Reset-Case '' '' $null
    $result = Run-Grants $true
    Check 'Grants Apply refuses a missing primary APIM configuration before any Azure call' (
        $result.code -ne 0 -and $result.output -match 'primary_apim_configuration_missing' -and @($result.calls).Count -eq 0)

    $invalid = @{} + $existing; $invalid.name = 'bad/name'
    Reset-Case '' '' $invalid
    $result = Run-Grants
    Check 'invalid existing APIM resource components do not reach Grants preview' (
        $result.code -ne 0 -and $result.output -match 'standby_gateway_id_invalid' -and @($result.calls).Count -eq 0)

    foreach ($case in @(
        @{ field = 'subscriptionId'; value = '------------------------------------' },
        @{ field = 'resourceGroup'; value = 'REPLACE-resource-group' },
        @{ field = 'name'; value = 'REPLACE-apim-name' }
    )) {
        $invalid = @{} + $existing; $invalid[$case.field] = $case.value
        Reset-Case '' '' $invalid
        $result = Run-Grants
        Check "invalid or placeholder APIM $($case.field) stops before Azure" (
            $result.code -ne 0 -and $result.output -match 'primary_apim_configuration_invalid' -and @($result.calls).Count -eq 0)
    }

    Reset-Case '' 'different-primary' $existing
    $result = Run-Grants
    Check 'a conflicting primary Stage 1 APIM name and existing configuration fail closed' (
        $result.code -ne 0 -and $result.output -match 'primary_apim_configuration_conflict' -and @($result.calls).Count -eq 0)

    Reset-Case '' 'shared-primary' $existing
    $result = Run-Grants
    Check 'matching APIM names in different subscriptions or groups are not treated as the same resource' (
        $result.code -ne 0 -and $result.output -match 'primary_apim_configuration_conflict' -and @($result.calls).Count -eq 0)

    $sameScope = @{ subscriptionId = $sub; resourceGroup = 'fixture-rg'; name = 'same-primary' }
    $sameScopeId = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.ApiManagement/service/same-primary"
    Reset-Case '' 'same-primary' $sameScope
    $result = Run-Grants
    Check 'consistent Stage 1 and existing APIM references resolve the same resource' (
        $result.code -eq 0 -and ($result.generated.admin.gatewayResourceIds -join '|') -ceq "$sameScopeId|$standbyId")

    $recordedId = "/subscriptions/$sub/resourceGroups/fixture-rg/providers/Microsoft.ApiManagement/service/recorded-primary"
    Reset-Case $recordedId 'recorded-primary' $existing
    $result = Run-Grants
    Check 'an existing valid Stage 1 APIM ID remains authoritative' (
        $result.code -eq 0 -and ($result.generated.admin.gatewayResourceIds -join '|') -ceq "$recordedId|$standbyId")

    Reset-Case '/invalid-resource-id' '' $existing
    $result = Run-Grants
    Check 'an invalid recorded APIM ID is not silently replaced by the configured fallback' (
        $result.code -ne 0 -and $result.output -match 'standby_gateway_id_invalid' -and @($result.calls).Count -eq 0)
} finally {
    Remove-Item Env:\DR_APIM_LOG, Env:\DR_STANDBY_APIM_ID -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "DR existing APIM: $script:passed passed, $script:failed failed."
if ($script:failed) { exit 1 }
