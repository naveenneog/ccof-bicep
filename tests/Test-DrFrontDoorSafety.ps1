#Requires -Version 7.0
param(
    [switch]$StubChild,
    [string]$Phase,
    [string]$ConfigPath,
    [switch]$Apply,
    [switch]$PrimaryOnly,
    [switch]$ConfirmStandbyReady,
    [string]$ReviewedConnectionIds
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if ($StubChild) {
    function global:Write-FdFakeLog($Entry) {
        Add-Content -LiteralPath $env:FD_TEST_LOG -Value (ConvertTo-Json -InputObject $Entry -Depth 30 -Compress)
    }
    function global:New-TemporaryFile {
        $path = Join-Path $env:FD_TEST_SCRATCH "legacy-az-error-$([guid]::NewGuid().ToString('N')).txt"
        New-Item -ItemType File -Path $path
    }
    function global:Start-Sleep { param([int]$Seconds) }
    # Runs a real Verify once while a configuration change is in flight, as a concurrent operator session would.
    function global:Invoke-FdConcurrentVerify {
        $marker = Join-Path $env:FD_TEST_SCRATCH 'concurrent-verify.done'
        if ($env:FD_TEST_CASE -ne 'concurrent-verify' -or (Test-Path -LiteralPath $marker)) { return }
        New-Item -ItemType File -Path $marker | Out-Null
        $env:FD_TEST_CASE = ''
        $nested = & pwsh -NoProfile -File $env:FD_TEST_SCRIPT -StubChild -Phase Verify -ConfigPath $env:FD_TEST_CFG 2>&1
        $nestedCode = $LASTEXITCODE
        $env:FD_TEST_CASE = 'concurrent-verify'
        $between = Get-Content -LiteralPath $env:FD_TEST_FD_STATE -Raw | ConvertFrom-Json -AsHashtable -Depth 30
        Write-FdFakeLog @{ kind = 'concurrent-verify'; code = $nestedCode; output = ($nested -join "`n"); verifiedAtPresent = $between.Contains('verifiedAt') }
    }
    function global:az {
        $arguments = @($args)
        Write-FdFakeLog @{ kind = 'az'; args = $arguments }
        $global:LASTEXITCODE = 0
        $command = $arguments[0..1] -join ' '
        switch ($command) {
            'functionapp show' {
                $name = $arguments[[Array]::IndexOf($arguments, '--name') + 1]
                if ($env:FD_TEST_CASE -eq 'no-standby' -and $name -eq 'fixture-b-admin') {
                    throw 'The restore must not read the standby app.'
                }
                return (@{ id = "/subscriptions/$env:FD_TEST_SUB/resourceGroups/workload-rg/providers/Microsoft.Web/sites/$name"
                    properties = @{ defaultHostName = "$name.azurewebsites.net" } } | ConvertTo-Json -Depth 10 -Compress)
            }
            'network private-endpoint-connection' {
                $connections = @(Get-Content -LiteralPath $env:FD_TEST_CONNECTIONS -Raw | ConvertFrom-Json -AsHashtable -Depth 30)
                $id = $arguments[[Array]::IndexOf($arguments, '--id') + 1]
                if ($arguments[2] -eq 'list') {
                    if (-not (Get-Variable -Name FD_TEST_LIST_COUNTS -Scope Global -ErrorAction SilentlyContinue)) { $global:FD_TEST_LIST_COUNTS = @{} }
                    if (-not $global:FD_TEST_LIST_COUNTS.ContainsKey($id)) { $global:FD_TEST_LIST_COUNTS[$id] = 0 }
                    $global:FD_TEST_LIST_COUNTS[$id]++
                    $listed = @($connections | Where-Object {
                        [string]$_.id -like "$id/privateEndpointConnections/*"
                    })
                    if ($global:FD_TEST_LIST_COUNTS[$id] -gt 1 -and $listed.Count) {
                        if ($env:FD_TEST_CASE -eq 'saved-drift' -and $id -like '*/service/fixture-apim') {
                            $listed[0].properties.privateLinkServiceConnectionState.status = 'Pending'
                        }
                        if ($env:FD_TEST_CASE -eq 'reviewed-drift' -and $id -like '*/service/fixture-b-apim') {
                            $listed[0].properties.privateLinkServiceConnectionState.description = 'Different requester'
                        }
                    }
                    return (ConvertTo-Json -InputObject $listed -Depth 30 -Compress)
                }
                if ($arguments[2] -eq 'approve') {
                    $match = @($connections | Where-Object { [string]$_.id -ieq $id })
                    if ($match.Count -ne 1) { throw 'Unexpected fake approval target.' }
                    if ($env:FD_TEST_CASE -ne 'no-approval-readback') {
                        $description = $arguments[[Array]::IndexOf($arguments, '--description') + 1]
                        $match[0].properties.privateLinkServiceConnectionState.status = 'Approved'
                        $match[0].properties.privateLinkServiceConnectionState.description = $description
                        ConvertTo-Json -InputObject $connections -Depth 30 | Set-Content -LiteralPath $env:FD_TEST_CONNECTIONS -Encoding utf8NoBOM
                    }
                    return '{"status":"accepted"}'
                }
                throw 'Unexpected fake private endpoint command.'
            }
            'account get-access-token' { return '{"accessToken":"fake-arm-token"}' }
            'deployment group' {
                if ($arguments -contains 'what-if') { return '{"changes":[]}' }
                $saved = Get-Content -LiteralPath $env:FD_TEST_FD_STATE -Raw | ConvertFrom-Json -AsHashtable -Depth 30
                Write-FdFakeLog @{ kind = 'deployment-observation'; verifiedAtPresent = $saved.Contains('verifiedAt') }
                Invoke-FdConcurrentVerify
                if ($env:FD_TEST_CASE -eq 'deployment-failure') { return '{"properties":{"provisioningState":"Failed"}}' }
                return (@{ properties = @{ provisioningState = 'Succeeded'; outputs = @{
                    profileName = @{ value = 'fixture-edge-fd' }; profileId = @{ value = $env:FD_TEST_PROFILE_ID }
                    endpointHostName = @{ value = 'fixture-edge.test' } } } } | ConvertTo-Json -Depth 20 -Compress)
            }
            'rest --method' {
                $method = $arguments[2]
                $url = $arguments[[Array]::IndexOf($arguments, '--url') + 1]
                if ($method -ne 'get') { throw "Unexpected az REST mutation: $method $url" }
                $path = ([uri]$url).AbsolutePath
                if ($path -ieq $env:FD_TEST_PROFILE_ID) {
                    $id = if ($env:FD_TEST_CASE -eq 'wrong-profile') { "$path-other" } else { $path }
                    return (@{ id = $id; name = 'fixture-edge-fd'; sku = @{ name = 'Premium_AzureFrontDoor' }
                        properties = @{ provisioningState = 'Succeeded' } } | ConvertTo-Json -Depth 10 -Compress)
                }
                if ($path -ieq "/subscriptions/$env:FD_TEST_SUB/resourceGroups/workload-rg/providers/Microsoft.ApiManagement/service/fixture-apim") {
                    return (@{ id = $path; properties = @{ gatewayUrl = 'https://fixture-apim.azure-api.net' } } | ConvertTo-Json -Depth 10 -Compress)
                }
                $origins = Get-Content -LiteralPath $env:FD_TEST_ORIGINS -Raw | ConvertFrom-Json -AsHashtable -Depth 30
                $origin = $origins[$path]
                if (-not $origin) {
                    return '{"properties":{"publicNetworkAccess":"Disabled","provisioningState":"Succeeded"}}'
                }
                if ($env:FD_TEST_CASE -eq 'wrong-origin-id' -and $path -like '*/primary-admin') { $origin.id += '-other' }
                if ($env:FD_TEST_CASE -eq 'wrong-origin-host' -and $path -like '*/primary-admin') { $origin.properties.hostName = 'unexpected.example.invalid' }
                if ($env:FD_TEST_CASE -eq 'wrong-origin-target' -and $path -like '*/primary-admin') { $origin.properties.sharedPrivateLinkResource.privateLink.id += '-other' }
                return (ConvertTo-Json -InputObject $origin -Depth 30 -Compress)
            }
            default { throw "Unexpected fake az command: $($arguments -join ' ')" }
        }
    }
    function global:Invoke-WebRequest {
        [CmdletBinding()]
        param([string]$Uri, [string]$Method, $Headers, $Body, [string]$ContentType,
            [switch]$SkipHttpErrorCheck, [int]$TimeoutSec, [int]$MaximumRedirection)
        if ($Uri -like 'https://fixture-edge.test/*') {
            $saved = Get-Content -LiteralPath $env:FD_TEST_FD_STATE -Raw | ConvertFrom-Json -AsHashtable -Depth 30
            Write-FdFakeLog @{ kind = 'route'; uri = $Uri; verifiedAtPresent = $saved.Contains('verifiedAt') }
            $marker = Join-Path $env:FD_TEST_SCRATCH 'concurrent-approve.done'
            if ($env:FD_TEST_CASE -eq 'concurrent-approve' -and -not (Test-Path -LiteralPath $marker)) {
                New-Item -ItemType File -Path $marker | Out-Null
                $list = @(Get-Content -LiteralPath $env:FD_TEST_CONNECTIONS -Raw | ConvertFrom-Json -AsHashtable -Depth 30)
                $list[1].properties.privateLinkServiceConnectionState.status = 'Pending'
                ConvertTo-Json -InputObject $list -Depth 30 | Set-Content -LiteralPath $env:FD_TEST_CONNECTIONS -Encoding utf8NoBOM
                $env:FD_TEST_CASE = ''
                $nested = & pwsh -NoProfile -File $env:FD_TEST_SCRIPT -StubChild -Phase Approve -ConfigPath $env:FD_TEST_CFG -Apply -ConfirmStandbyReady 2>&1
                $nestedCode = $LASTEXITCODE
                $env:FD_TEST_CASE = 'concurrent-approve'
                $between = Get-Content -LiteralPath $env:FD_TEST_FD_STATE -Raw | ConvertFrom-Json -AsHashtable -Depth 30
                Write-FdFakeLog @{ kind = 'concurrent-approve'; code = $nestedCode; output = ($nested -join "`n")
                    approvedPresent = $between.Contains('approvedConnections'); verifiedAtPresent = $between.Contains('verifiedAt') }
            }
            $status = if ($env:FD_TEST_CASE -eq 'route-failure') { 503 } elseif ($Uri -like '*/api/console') { 302 } else { 200 }
            return [pscustomobject]@{ StatusCode = $status; Headers = @{}; Content = '' }
        }
        if (-not $Uri.StartsWith('https://management.azure.com/', [StringComparison]::OrdinalIgnoreCase)) {
            Write-FdFakeLog @{ kind = 'rejected-http'; method = $Method; uri = $Uri }
            throw "Unexpected fake HTTP target: $Uri"
        }
        if (-not $Headers -or $Headers.Authorization -ne 'Bearer fake-arm-token') { throw 'Expected fake ARM authorization.' }
        $path = ([uri]$Uri).AbsolutePath
        Write-FdFakeLog @{ kind = 'http'; method = $Method; uri = $Uri; body = $Body }
        $origins = Get-Content -LiteralPath $env:FD_TEST_ORIGINS -Raw | ConvertFrom-Json -AsHashtable -Depth 30
        if ($Method -ieq 'Patch') {
            if (-not $origins.Contains($path)) { throw "Unexpected fake origin: $path" }
            Invoke-FdConcurrentVerify
            if ($env:FD_TEST_CASE -eq 'patch-failure') { return [pscustomobject]@{ StatusCode = 500; Headers = @{}; Content = '{}' } }
            $payload = $Body | ConvertFrom-Json -AsHashtable -Depth 20
            $pending = @{ path = $path; properties = $payload.properties; polls = 0 }
            $pending | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env:FD_TEST_OPERATION -Encoding utf8NoBOM
            if ($env:FD_TEST_CASE -eq 'operation-failure') {
                foreach ($key in $payload.properties.Keys) { $origins[$path].properties[$key] = $payload.properties[$key] }
                $origins | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $env:FD_TEST_ORIGINS -Encoding utf8NoBOM
            }
            if ($env:FD_TEST_CASE -eq 'sync') {
                foreach ($key in $payload.properties.Keys) { $origins[$path].properties[$key] = $payload.properties[$key] }
                $origins | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $env:FD_TEST_ORIGINS -Encoding utf8NoBOM
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = ($origins[$path] | ConvertTo-Json -Depth 30 -Compress) }
            }
            $operationUri = "https://management.azure.com/subscriptions/$env:FD_TEST_SUB/providers/Microsoft.Cdn/operationresults/test-operation?api-version=2025-04-15"
            $headersOut = switch ($env:FD_TEST_CASE) {
                'missing-async-header' { @{} }
                'untrusted-async-header' { @{ 'Azure-AsyncOperation' = 'https://example.invalid/stolen-token' } }
                'location' { @{ Location = $operationUri; 'Retry-After' = '1' } }
                'zero-retry' { @{ 'Azure-AsyncOperation' = $operationUri; 'Retry-After' = '0' } }
                default { @{ 'Azure-AsyncOperation' = $operationUri; 'Retry-After' = '1' } }
            }
            return [pscustomobject]@{ StatusCode = 202; Headers = $headersOut; Content = '{"properties":{"provisioningState":"Updating"}}' }
        }
        if ($Method -ieq 'Get' -and $path -like '*/operationresults/*') {
            $pending = Get-Content -LiteralPath $env:FD_TEST_OPERATION -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            $pending.polls++
            $pending | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env:FD_TEST_OPERATION -Encoding utf8NoBOM
            if ($env:FD_TEST_CASE -eq 'operation-failure') {
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{"status":"Failed"}' }
            }
            if ($env:FD_TEST_CASE -eq 'operation-timeout' -or $pending.polls -eq 1) {
                return [pscustomobject]@{ StatusCode = $(if ($env:FD_TEST_CASE -eq 'location') { 202 } else { 200 })
                    Headers = @{ 'Retry-After' = '1' }; Content = '{"status":"InProgress"}' }
            }
            foreach ($key in $pending.properties.Keys) { $origins[$pending.path].properties[$key] = $pending.properties[$key] }
            if ($env:FD_TEST_CASE -eq 'failed-readback') { $origins[$pending.path].properties.provisioningState = 'Failed' }
            if ($env:FD_TEST_CASE -eq 'wrong-readback') { $origins[$pending.path].properties.originHostHeader = 'wrong.example.invalid' }
            if ($env:FD_TEST_CASE -eq 'drift-after-second' -and $pending.path -like '*/primary-admin') {
                $gateway = "$env:FD_TEST_PROFILE_ID/originGroups/apim/origins/primary-gateway"
                $origins[$gateway].properties.originHostHeader = 'wrong.example.invalid'
            }
            $origins | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $env:FD_TEST_ORIGINS -Encoding utf8NoBOM
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{"status":"Succeeded"}' }
        }
        throw "Unexpected fake HTTP request: $Method $Uri"
    }
    try {
        $driverArgs = @{ Phase = $Phase; ConfigPath = $ConfigPath; Apply = $Apply; PrimaryOnly = $PrimaryOnly
            ConfirmStandbyReady = $ConfirmStandbyReady }
        if ($PSBoundParameters.ContainsKey('ReviewedConnectionIds')) { $driverArgs.ReviewedConnectionIds = $ReviewedConnectionIds }
        $driverPath = if ($env:FD_TEST_DRIVER) { $env:FD_TEST_DRIVER } else { Join-Path $root 'infra\dr\Invoke-DrFrontDoor.ps1' }
        & $driverPath @driverArgs
        exit $LASTEXITCODE
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}

if (-not $env:AZURE_CONFIG_DIR) { throw 'Set AZURE_CONFIG_DIR to a logged-out isolated profile before running this test.' }
Import-Module (Join-Path $root 'infra\dr\DrPrerequisites.psm1') -Force
Import-Module (Join-Path $root 'infra\dr\DrStandby.psm1') -Force
$script:passed = 0
$script:failed = 0
function Check([string]$Name, [bool]$Ok, $Result = $null) {
    if ($Ok) { $script:passed++ } else {
        $script:failed++
        Write-Host "FAIL $Name"
        if ($Result -and $Result.output) {
            $start = [Math]::Max(0, $Result.output.Length - 500)
            Write-Host ("  exit=$($Result.code); " + $Result.output.Substring($start))
            $calls = @($Result.calls | Where-Object { $_.kind -eq 'az' } | ForEach-Object { $_.args -join ' ' })
            if ($calls.Count) { Write-Host "  az: $($calls -join ' | ')" }
        }
    }
}
function Write-Fixture([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 50), [Text.UTF8Encoding]::new($false))
}
function Read-Fixture([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 50 }

$scratch = Join-Path $PSScriptRoot ".frontdoor-safety-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $env:FD_TEST_SCRATCH = $scratch
    $env:FD_TEST_SUB = '00000000-0000-4000-8000-000000000002'
    $sub = $env:FD_TEST_SUB
    $tenant = '00000000-0000-4000-8000-000000000001'
    $profile = "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.Cdn/profiles/fixture-edge-fd"
    $env:FD_TEST_PROFILE_ID = $profile
    $primaryDir = Join-Path $scratch 'primary-state'
    $standbyDir = Join-Path $scratch 'standby-state'
    New-Item -ItemType Directory -Path $primaryDir, $standbyDir | Out-Null
    $cfgPath = Join-Path $scratch 'config.json'
    $primaryPath = Join-Path $scratch 'primary.json'
    $statePath = Join-Path $standbyDir 'frontdoor-state.json'
    $evidencePath = Join-Path $standbyDir 'standby.state.json'
    $standbyStagePath = Join-Path $standbyDir 'state.json'
    $env:FD_TEST_FD_STATE = $statePath
    $env:FD_TEST_CFG = $cfgPath
    $env:FD_TEST_SCRIPT = $PSCommandPath
    $env:FD_TEST_LOG = Join-Path $scratch 'calls.jsonl'
    $env:FD_TEST_CONNECTIONS = Join-Path $scratch 'connections.json'
    $env:FD_TEST_ORIGINS = Join-Path $scratch 'origins.json'
    $env:FD_TEST_OPERATION = Join-Path $scratch 'operation.json'
    $vnetId = "/subscriptions/$sub/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/dr-vnet"
    $config = @{
        tenantId = $tenant; subscriptionId = $sub; tags = @{ workload = 'ccof' }
        primary = @{ location = 'eastus2'; addressSpaces = @('10.40.0.0/16'); peer = $false }
        secondary = @{ location = 'centralus'; resourceGroup = 'workload-rg'; vnetName = 'dr-vnet'
            networkMode = 'existing'; existingVnetId = $vnetId; addressSpace = '100.96.5.0/24'
            subnets = @{ apim = @{ name = 'snet-apim'; prefix = '100.96.5.0/27' }
                functions = @{ name = 'snet-functions'; prefix = '100.96.5.32/27' }
                privateEndpoints = @{ name = 'snet-pe'; prefix = '100.96.5.64/26' } } }
        dnsZones = @{ subscriptionId = $sub; resourceGroup = 'network-rg'; zoneNames = @('privatelink.documents.azure.com') }
        identityNames = @('ccof-sync-b', 'ccof-reconciler-b')
        standby = @{ stagedConfigPath = $primaryPath; stagedStateDirectory = $primaryDir; stateDirectory = $standbyDir
            nameSuffix = 'b'; functionsPublicNetworkAccess = 'Disabled'; storagePublicNetworkAccess = 'Disabled'
            apim = @{ publisherEmail = 'admin@example.invalid'; publisherName = 'Example'; sku = 'StandardV2' } }
        frontDoor = @{ stem = 'fixture-edge'; wafMode = 'Detection'; probeIntervalSeconds = 30 }
    }
    $primaryCfg = @{ subscriptionId = $sub; resourceGroup = 'workload-rg' }
    $targets = @(
        "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.ApiManagement/service/fixture-apim",
        "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.ApiManagement/service/fixture-b-apim",
        "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.Web/sites/fixture-admin",
        "/subscriptions/$sub/resourceGroups/workload-rg/providers/Microsoft.Web/sites/fixture-b-admin"
    )
    $names = @('primary-gateway', 'standby-gateway', 'primary-admin', 'standby-admin')
    $hosts = @('fixture-apim.azure-api.net', 'fixture-b-apim.azure-api.net', 'fixture-admin.azurewebsites.net', 'fixture-b-admin.azurewebsites.net')
    $requests = @('CCOF Front Door origin primary-gateway', 'CCOF Front Door origin standby-gateway',
        'CCOF Front Door admin origin primary-admin', 'CCOF Front Door admin origin standby-admin')
    $connectionIds = @($targets | ForEach-Object { "$_/privateEndpointConnections/fixture" })
    $endpointIds = @(0..3 | ForEach-Object { "/subscriptions/$sub/resourceGroups/network-rg/providers/Microsoft.Network/privateEndpoints/fixture-$_" })
    $originIds = @(
        "$profile/originGroups/apim/origins/primary-gateway", "$profile/originGroups/apim/origins/standby-gateway",
        "$profile/originGroups/admin/origins/primary-admin", "$profile/originGroups/admin/origins/standby-admin"
    )
    $primaryState = @{ stages = @{ '1' = @{ outputs = @{ apimId = $targets[0]; apimGatewayUrl = "https://$($hosts[0])"
        names = @{ apps = @{ admin = @{ functionApp = 'fixture-admin' } } } } } } }
    $standbyState = @{ stages = @{ '1' = @{ outputs = @{ apimId = $targets[1]; apimGatewayUrl = "https://$($hosts[1])"
        names = @{ apps = @{ admin = @{ functionApp = 'fixture-b-admin' } } } } } } }
    $evidence = @{ phases = @{
        Data = @{ completedAt = '2026-01-01T00:00:00Z' }; Shells = @{ completedAt = '2026-01-01T00:01:00Z' }
        Grants = @{ completedAt = '2026-01-01T00:02:00Z' }; Config = @{ completedAt = '2026-01-01T00:03:00Z' }
        Network = @{ completedAt = '2026-01-01T00:04:00Z' }; Code = @{ completedAt = '2026-01-01T00:05:00Z' }
        Verify = @{ completedAt = '2026-01-01T00:06:00Z' } } }
    $fdState = @{ mode = 'full'; stem = 'fixture-edge'; subscriptionId = $sub; resourceGroup = 'workload-rg'
        profileName = 'fixture-edge-fd'; profileId = $profile; endpointHostName = 'fixture-edge.test'
        apimIds = @($targets[0], $targets[1]); adminSiteIds = @($targets[2], $targets[3])
        previousApprovedConnections = @($connectionIds[0], $connectionIds[2]); reviewedConnections = @($connectionIds[0], $connectionIds[2]); verifiedAt = 'old' }
    $connections = @(for ($i = 0; $i -lt 4; $i++) {
        @{ id = $connectionIds[$i]; name = 'fixture'; properties = @{ privateEndpoint = @{ id = $endpointIds[$i] }
            privateLinkServiceConnectionState = @{ status = $(if ($i -in 0, 2) { 'Approved' } else { 'Pending' })
                description = $(if ($i -in 0, 2) { 'Prior approval description' } else { $requests[$i] }) } } }
    })
    $origins = @{}
    for ($i = 0; $i -lt 4; $i++) {
        $origins[$originIds[$i]] = @{ id = $originIds[$i]; name = $names[$i]; properties = @{
            hostName = $hosts[$i]; originHostHeader = $(if ($i -in 0, 2) { 'dr-drill.invalid' } else { $hosts[$i] })
            priority = $(if ($i -in 0, 2) { 1 } else { 2 }); weight = 1000; httpPort = 80; httpsPort = 443
            enabledState = 'Disabled'; provisioningState = 'Succeeded'; deploymentStatus = 'Succeeded'
            enforceCertificateNameCheck = $true; sharedPrivateLinkResource = @{ privateLink = @{ id = $targets[$i] }
                groupId = $(if ($i -lt 2) { 'Gateway' } else { 'sites' }); privateLinkLocation = $(if ($i -in 0, 2) { 'eastus2' } else { 'centralus' }) } } }
    }
    function Reset-Fixture {
        Write-Fixture $cfgPath $config; Write-Fixture $primaryPath $primaryCfg
        Write-Fixture (Join-Path $primaryDir 'state.json') $primaryState
        Write-Fixture $standbyStagePath $standbyState; Write-Fixture $evidencePath $evidence
        Write-Fixture $statePath $fdState; Write-Fixture $env:FD_TEST_CONNECTIONS $connections
        Write-Fixture $env:FD_TEST_ORIGINS $origins
        if (Test-Path -LiteralPath $env:FD_TEST_OPERATION) { Remove-Item -LiteralPath $env:FD_TEST_OPERATION }
        $env:FD_TEST_CASE = ''
    }
    function Run-Driver([string]$DriverPhase, [bool]$ShouldApply = $false, [bool]$Primary = $false,
        [bool]$Confirm = $false, [string]$Reviewed = '') {
        if (Test-Path -LiteralPath $env:FD_TEST_LOG) { Remove-Item -LiteralPath $env:FD_TEST_LOG }
        $arguments = @('-NoProfile', '-File', $PSCommandPath, '-StubChild', '-Phase', $DriverPhase, '-ConfigPath', $cfgPath)
        if ($ShouldApply) { $arguments += '-Apply' }
        if ($Primary) { $arguments += '-PrimaryOnly' }
        if ($Confirm) { $arguments += '-ConfirmStandbyReady' }
        if ($Reviewed) { $arguments += @('-ReviewedConnectionIds', $Reviewed) }
        $output = & pwsh @arguments 2>&1
        $code = $LASTEXITCODE
        $calls = if (Test-Path -LiteralPath $env:FD_TEST_LOG) {
            @(Get-Content -LiteralPath $env:FD_TEST_LOG | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable -Depth 30 })
        } else { @() }
        $text = $output -join "`n"
        return @{ code = $code; output = $text; flat = ($text -replace '\x1b\[[0-9;]*m|[\s|]', ''); calls = $calls }
    }
    function Mutations($Result) {
        @($Result.calls | Where-Object {
            ($_.kind -eq 'az' -and (($_.args -join ' ') -match '^network private-endpoint-connection approve |^deployment group create |^rest --method (patch|put|delete) ')) -or
                ($_.kind -eq 'http' -and $_.method -iin @('Patch', 'Put', 'Delete', 'Post'))
        })
    }
    function AzCalls($Result, [string]$Pattern) {
        @($Result.calls | Where-Object { $_.kind -eq 'az' -and ($_.args -join ' ') -match $Pattern })
    }
    function HttpPatches($Result) { @($Result.calls | Where-Object { $_.kind -eq 'http' -and $_.method -ieq 'Patch' }) }

    Check 'both DR modules import and readiness helper is available' ([bool](Get-Command Get-DrFrontDoorReadinessProblem -ErrorAction SilentlyContinue) -and [bool](Get-Command Resolve-DrAzureProfile -ErrorAction SilentlyContinue))
    Reset-Fixture
    $r = Run-Driver 'Deploy' $true
    Check 'full Deploy retains its explicit standby confirmation gate' ($r.code -ne 0 -and $r.output -match 'frontdoor_standby_confirmation_required' -and $r.calls.Count -eq 0) $r
    Reset-Fixture
    $r = Run-Driver 'Deploy'
    Check 'full Deploy preview retains Azure what-if without mutation' ($r.code -eq 0 -and @(AzCalls $r '^deployment group what-if ').Count -eq 1 -and (Mutations $r).Count -eq 0) $r
    Reset-Fixture
    $r = Run-Driver 'Deploy' $true $false $true
    $after = Read-Fixture $statePath
    $observed = @($r.calls | Where-Object { $_.kind -eq 'deployment-observation' })
    Check 'full Deploy invalidates old route evidence before a successful template apply' (
        $r.code -eq 0 -and $observed.Count -eq 1 -and -not $observed[0].verifiedAtPresent -and -not $after.Contains('verifiedAt')) $r
    Reset-Fixture; $env:FD_TEST_CASE = 'deployment-failure'
    $r = Run-Driver 'Deploy' $true $false $true
    Check 'failed full Deploy leaves prior route verification invalidated' ($r.code -ne 0 -and $r.output -match 'frontdoor_deploy_failed' -and -not (Read-Fixture $statePath).Contains('verifiedAt')) $r
    Reset-Fixture
    $state = Read-Fixture $statePath; $state.approvedConnections = $connectionIds; $state.reviewedConnections = $connectionIds
    $state.Remove('previousApprovedConnections'); Write-Fixture $statePath $state
    $r = Run-Driver 'DrainPrimary' $true $false $true
    $after = Read-Fixture $statePath; $observed = @($r.calls | Where-Object { $_.kind -eq 'deployment-observation' })
    Check 'DrainPrimary consumes prior verification and clears it before the drill deployment' (
        $r.code -eq 0 -and $after.Contains('primaryDrainedAt') -and -not $after.Contains('verifiedAt') -and
        $observed.Count -eq 1 -and -not $observed[0].verifiedAtPresent) $r
    Reset-Fixture; Remove-Item -LiteralPath $evidencePath, $standbyStagePath
    $state = Read-Fixture $statePath; $state.mode = 'primaryOnly'; Write-Fixture $statePath $state
    $env:FD_TEST_CASE = 'no-standby'
    $r = Run-Driver 'Deploy' $true $true
    Check 'primary-only Deploy remains available without B metadata or readiness' ($r.code -eq 0 -and @(AzCalls $r '^deployment group create ').Count -eq 1) $r

    Reset-Fixture
    $r = Run-Driver 'Approve' $true
    Check 'full approval requires explicit standby confirmation before any Azure call' ($r.code -ne 0 -and $r.output -match 'frontdoor_standby_confirmation_required' -and $r.calls.Count -eq 0) $r
    Reset-Fixture; Remove-Item -LiteralPath $evidencePath
    $r = Run-Driver 'Approve' $true $false $true
    Check 'full approval requires saved standby evidence before any Azure call' ($r.code -ne 0 -and $r.output -match 'frontdoor_standby_phase_missing' -and $r.calls.Count -eq 0) $r
    Reset-Fixture
    $stale = Read-Fixture $evidencePath; $stale.phases.Verify.completedAt = '2026-01-01T00:04:00Z'; Write-Fixture $evidencePath $stale
    $r = Run-Driver 'Approve' $true $false $true
    Check 'full approval refuses stale dependent standby evidence' ($r.code -ne 0 -and $r.output -match 'frontdoor_standby_phase_stale' -and $r.calls.Count -eq 0) $r
    Reset-Fixture
    $r = Run-Driver 'Lockdown' $true
    Check 'full lockdown requires standby confirmation before any Azure call' ($r.code -ne 0 -and $r.output -match 'frontdoor_standby_confirmation_required' -and $r.calls.Count -eq 0) $r
    Reset-Fixture; Remove-Item -LiteralPath $evidencePath
    $r = Run-Driver 'Lockdown' $true $false $true
    Check 'full lockdown requires current saved standby evidence' ($r.code -ne 0 -and $r.output -match 'frontdoor_standby_phase_missing' -and $r.calls.Count -eq 0) $r

    Reset-Fixture; Remove-Item -LiteralPath $evidencePath
    $before = Get-Content -LiteralPath $statePath -Raw
    $r = Run-Driver 'Approve'
    $allCandidateDetails = $true
    for ($i = 0; $i -lt 4; $i++) {
        foreach ($value in @($targets[$i], $connectionIds[$i], $endpointIds[$i])) {
            if (-not $r.output.Contains($value)) { $allCandidateDetails = $false }
        }
    }
    Check 'approval preview is read-only and shows target, full connection ID, endpoint, description and status for every candidate' (
        $r.code -eq 0 -and (Mutations $r).Count -eq 0 -and $allCandidateDetails -and $r.output.Contains($profile) -and $r.output.Contains('Prior approval description') -and
        $r.output.Contains($requests[1]) -and $r.output -match 'Approved' -and $r.output -match 'Pending' -and
        (Get-Content -LiteralPath $statePath -Raw) -ceq $before) $r

    Reset-Fixture; Remove-Item -LiteralPath $evidencePath
    $state = Read-Fixture $statePath; $state.mode = 'primaryOnly'; $state.apimIds = @($targets[0]); $state.adminSiteIds = @($targets[2])
    $state.Remove('previousApprovedConnections'); Write-Fixture $statePath $state
    $list = Read-Fixture $env:FD_TEST_CONNECTIONS
    foreach ($i in 0, 2) { $list[$i].properties.privateLinkServiceConnectionState.status = 'Pending'; $list[$i].properties.privateLinkServiceConnectionState.description = $requests[$i] }
    Write-Fixture $env:FD_TEST_CONNECTIONS $list
    $r = Run-Driver 'Approve' $true $true $false "$($connectionIds[0]),$($connectionIds[2])"
    Check 'primary-only approval works without B readiness after explicit review' ($r.code -eq 0 -and (AzCalls $r '^network private-endpoint-connection approve ').Count -eq 2) $r

    Reset-Fixture
    $r = Run-Driver 'Approve' $true $false $true
    Check 'new connections cannot be approved from descriptions without reviewed IDs' ($r.code -ne 0 -and $r.output -match 'frontdoor_review' -and (Mutations $r).Count -eq 0) $r
    Check 'an unsuccessful approval attempt invalidates stale route verification' (-not (Read-Fixture $statePath).Contains('verifiedAt')) $r
    Reset-Fixture; $env:FD_TEST_CASE = 'no-standby'
    $r = Run-Driver 'Approve' $true $false $true
    Check 'approval invalidates old verification before prerequisite Azure reads' ($r.code -ne 0 -and -not (Read-Fixture $statePath).Contains('verifiedAt') -and (Mutations $r).Count -eq 0) $r
    Reset-Fixture
    $reviewed = "$($connectionIds[1]),$($connectionIds[3])"
    $r = Run-Driver 'Approve' $true $false $true $reviewed
    $after = Read-Fixture $statePath; $list = Read-Fixture $env:FD_TEST_CONNECTIONS
    Check 'reviewed B IDs and revalidated saved A IDs approve exactly the two pending B links' (
        $r.code -eq 0 -and (AzCalls $r '^network private-endpoint-connection approve ').Count -eq 2 -and @($after.approvedConnections).Count -eq 4) $r
    Check 'new approvals preserve descriptions and invalidate old route verification' (
        $r.code -eq 0 -and -not $after.Contains('verifiedAt') -and $list[1].properties.privateLinkServiceConnectionState.description -ceq $requests[1] -and
        $list[3].properties.privateLinkServiceConnectionState.description -ceq $requests[3]) $r
    $r = Run-Driver 'Approve' $true $false $true
    Check 'revalidated saved approvals are repeatable without resupplying IDs' ($r.code -eq 0 -and (AzCalls $r '^network private-endpoint-connection approve ').Count -eq 0) $r
    foreach ($case in @('saved-drift', 'reviewed-drift')) {
        Reset-Fixture; $env:FD_TEST_CASE = $case
        $r = Run-Driver 'Approve' $true $false $true $reviewed
        Check "approval rechecks $case immediately before the first mutation" ($r.code -ne 0 -and $r.output -match 'frontdoor_connection_changed' -and (Mutations $r).Count -eq 0) $r
    }
    foreach ($case in @('absent-id', 'missing-endpoint')) {
        Reset-Fixture
        $ids = $reviewed
        if ($case -eq 'absent-id') { $ids = "$($targets[1])/privateEndpointConnections/not-found,$($connectionIds[3])" }
        else {
            $list = Read-Fixture $env:FD_TEST_CONNECTIONS; $list[1].properties.privateEndpoint.id = ''
            Write-Fixture $env:FD_TEST_CONNECTIONS $list
        }
        $r = Run-Driver 'Approve' $true $false $true $ids
        Check "approval rejects $case before any mutation" ($r.code -ne 0 -and $r.output -match 'frontdoor_review_id_mismatch' -and (Mutations $r).Count -eq 0) $r
    }

    foreach ($case in @('duplicate', 'extra', 'unrelated', 'two-for-one')) {
        Reset-Fixture
        $list = Read-Fixture $env:FD_TEST_CONNECTIONS
        $other = "$($targets[1])/privateEndpointConnections/other"
        $list += @{ id = $other; name = 'other'; properties = @{ privateEndpoint = @{ id = $endpointIds[1] }
            privateLinkServiceConnectionState = @{ status = 'Pending'; description = $(if ($case -eq 'unrelated') { 'Unrelated request' } else { $requests[1] }) } } }
        Write-Fixture $env:FD_TEST_CONNECTIONS $list
        $ids = switch ($case) {
            'duplicate' { "$($connectionIds[1]),$($connectionIds[1]),$($connectionIds[3])" }
            'extra' { "$reviewed,$($connectionIds[0])" }
            'unrelated' { "$other,$($connectionIds[3])" }
            'two-for-one' { "$reviewed,$other" }
        }
        $r = Run-Driver 'Approve' $true $false $true $ids
        Check "approval rejects $case reviewed IDs before any mutation" ($r.code -ne 0 -and $r.output -match 'frontdoor_review' -and (Mutations $r).Count -eq 0) $r
    }
    Reset-Fixture
    $list = @(Read-Fixture $env:FD_TEST_CONNECTIONS | Where-Object { $_.id -ine $connectionIds[0] })
    $replacement = "$($targets[0])/privateEndpointConnections/replacement"
    $list += @{ id = $replacement; name = 'replacement'; properties = @{ privateEndpoint = @{ id = $endpointIds[0] }
        privateLinkServiceConnectionState = @{ status = 'Pending'; description = $requests[0] } } }
    Write-Fixture $env:FD_TEST_CONNECTIONS $list
    $r = Run-Driver 'Approve' $true $false $true "$replacement,$reviewed"
    Check 'missing saved primary ID is never replaced by a description match' ($r.code -ne 0 -and $r.output -match 'frontdoor_saved_connection' -and (Mutations $r).Count -eq 0) $r
    Reset-Fixture
    $list = Read-Fixture $env:FD_TEST_CONNECTIONS; $list[0].properties.privateLinkServiceConnectionState.status = 'Pending'
    $list[0].properties.privateLinkServiceConnectionState.description = $requests[0]; Write-Fixture $env:FD_TEST_CONNECTIONS $list
    $r = Run-Driver 'Approve' $true $false $true $reviewed
    Check 'previously saved connection must still read back Approved' ($r.code -ne 0 -and $r.output -match 'frontdoor_saved_connection' -and (Mutations $r).Count -eq 0) $r
    Reset-Fixture; $env:FD_TEST_CASE = 'no-approval-readback'
    $r = Run-Driver 'Approve' $true $false $true $reviewed
    $after = Read-Fixture $statePath
    Check 'approval is not recorded unless each exact target ID reads back Approved' ($r.code -ne 0 -and $r.output -match 'frontdoor_connection_not_approved' -and -not $after.Contains('approvedConnections')) $r
    Check 'approval stops before changing the next connection when first readback fails' (@(AzCalls $r '^network private-endpoint-connection approve ').Count -eq 1) $r

    Reset-Fixture
    $state = Read-Fixture $statePath; $state.approvedConnections = $connectionIds; $state.reviewedConnections = $connectionIds; $state.Remove('previousApprovedConnections'); Write-Fixture $statePath $state
    $env:FD_TEST_CASE = 'route-failure'
    $r = Run-Driver 'Verify'
    $after = Read-Fixture $statePath
    $routeCalls = @($r.calls | Where-Object { $_.kind -eq 'route' })
    Check 'failed Verify clears saved verification before the first route request' (
        $r.code -ne 0 -and $r.output -match 'frontdoor_route_unhealthy' -and -not $after.Contains('verifiedAt') -and
        $routeCalls.Count -gt 0 -and -not $routeCalls[0].verifiedAtPresent) $r
    $r = Run-Driver 'Lockdown' $true $false $true
    Check 'Lockdown refuses after a failed Verify instead of trusting stale verification' ($r.code -ne 0 -and $r.output -match 'frontdoor_verify_required' -and (Mutations $r).Count -eq 0) $r
    $env:FD_TEST_CASE = ''
    $r = Run-Driver 'Verify'
    $after = Read-Fixture $statePath
    Check 'successful Verify records fresh verification after both route checks' ($r.code -eq 0 -and $after.Contains('verifiedAt')) $r
    Reset-Fixture
    $r = Run-Driver 'Verify'
    $after = Read-Fixture $statePath
    Check 'Verify invalidates old route evidence even when its approval precondition fails' (
        $r.code -ne 0 -and $r.output -match 'frontdoor_approval_missing' -and -not $after.Contains('verifiedAt')) $r
    Reset-Fixture
    $state = Read-Fixture $statePath; $state.approvedConnections = $connectionIds; $state.reviewedConnections = $connectionIds; Write-Fixture $statePath $state
    $env:FD_TEST_CASE = 'no-standby'
    $r = Run-Driver 'Verify'
    Check 'Verify invalidates old evidence before a prerequisite Azure read can fail' (
        $r.code -ne 0 -and -not (Read-Fixture $statePath).Contains('verifiedAt') -and
        @($r.calls | Where-Object { $_.kind -eq 'route' }).Count -eq 0) $r

    Reset-Fixture; Remove-Item -LiteralPath $evidencePath, $standbyStagePath
    $env:FD_TEST_CASE = 'no-standby'; $before = Get-Content -LiteralPath $statePath -Raw
    $r = Run-Driver 'RestorePrimary'
    Check 'restore preview needs no B state, shows both exact A origins and makes no mutation' (
        $r.code -eq 0 -and (Mutations $r).Count -eq 0 -and $r.output.Contains($originIds[0]) -and $r.output.Contains($originIds[2]) -and
        (Get-Content -LiteralPath $statePath -Raw) -ceq $before) $r

    Reset-Fixture; Remove-Item -LiteralPath $evidencePath, $standbyStagePath
    $env:FD_TEST_CASE = 'no-standby'
    $r = Run-Driver 'RestorePrimary' $true
    $patches = @(HttpPatches $r); $resultOrigins = Read-Fixture $env:FD_TEST_ORIGINS; $after = Read-Fixture $statePath
    $patchesCorrect = $patches.Count -eq 2
    foreach ($patch in $patches) {
        $payload = $patch.body | ConvertFrom-Json -AsHashtable -Depth 20
        $path = ([uri]$patch.uri).AbsolutePath
        if ($path -in @($originIds[0], $originIds[2])) {
            $index = if ($path -ieq $originIds[0]) { 0 } else { 2 }
            if (@($payload.Keys).Count -ne 1 -or @($payload.properties.Keys).Count -ne 2 -or
                $payload.properties.originHostHeader -ine $hosts[$index] -or $payload.properties.enabledState -cne 'Enabled' -or
                $patch.uri -notmatch 'api-version=2025-04-15') { $patchesCorrect = $false }
        } else { $patchesCorrect = $false }
    }
    Check 'restore PATCHes only A host headers and enabled states using the documented API' (
        $r.code -eq 0 -and $patchesCorrect -and (AzCalls $r '^deployment group create ').Count -eq 0) $r
    Check 'restore leaves disabled B origins unchanged and succeeds without B metadata' (
        $r.code -eq 0 -and $resultOrigins[$originIds[1]].properties.enabledState -ceq 'Disabled' -and
        $resultOrigins[$originIds[3]].properties.enabledState -ceq 'Disabled' -and
        @($r.calls | Where-Object { $_.kind -eq 'az' -and (($_.args -join ' ') -match 'fixture-b-admin|standby-gateway|standby-admin') }).Count -eq 0) $r
    Check 'restore polls each asynchronous operation and verifies A readback before recording success' (
        $r.code -eq 0 -and @($r.calls | Where-Object { $_.kind -eq 'http' -and $_.method -ieq 'Get' }).Count -ge 4 -and
        $after.Contains('primaryRestoredAt') -and -not $after.Contains('verifiedAt') -and
        $resultOrigins[$originIds[0]].properties.originHostHeader -ieq $hosts[0] -and
        $resultOrigins[$originIds[2]].properties.enabledState -ceq 'Enabled') $r

    foreach ($case in @('wrong-profile', 'wrong-origin-id', 'wrong-origin-host', 'wrong-origin-target')) {
        Reset-Fixture; $env:FD_TEST_CASE = $case
        $r = Run-Driver 'RestorePrimary' $true
        Check "restore refuses $case before either origin is patched" (
            $r.code -ne 0 -and $r.output -match 'frontdoor_restore' -and (Mutations $r).Count -eq 0 -and
            -not (Read-Fixture $statePath).Contains('primaryRestoredAt')) $r
    }
    foreach ($case in @('patch-failure', 'operation-failure', 'operation-timeout', 'missing-async-header', 'untrusted-async-header', 'failed-readback', 'wrong-readback', 'drift-after-second')) {
        Reset-Fixture; $env:FD_TEST_CASE = $case
        $r = Run-Driver 'RestorePrimary' $true
        Check "restore fails closed on $case without recording success" (
            $r.code -ne 0 -and $r.output -match 'frontdoor_restore' -and (HttpPatches $r).Count -ge 1 -and
            -not (Read-Fixture $statePath).Contains('primaryRestoredAt') -and
            @($r.calls | Where-Object { $_.kind -eq 'rejected-http' }).Count -eq 0) $r
    }
    foreach ($case in @('sync', 'location', 'zero-retry')) {
        Reset-Fixture; $env:FD_TEST_CASE = $case
        $r = Run-Driver 'RestorePrimary' $true
        Check "restore handles documented $case completion and verifies readback" ($r.code -eq 0 -and (HttpPatches $r).Count -eq 2 -and (Read-Fixture $statePath).Contains('primaryRestoredAt')) $r
    }
    Reset-Fixture; Remove-Item -LiteralPath $evidencePath, $standbyStagePath
    $restored = Read-Fixture $env:FD_TEST_ORIGINS
    foreach ($i in 0, 2) { $restored[$originIds[$i]].properties.originHostHeader = $hosts[$i]; $restored[$originIds[$i]].properties.enabledState = 'Enabled' }
    Write-Fixture $env:FD_TEST_ORIGINS $restored
    $env:FD_TEST_CASE = 'no-standby'
    $r = Run-Driver 'RestorePrimary' $true
    Check 'already-restored A origins are revalidated without any PATCH or B state' ($r.code -eq 0 -and (HttpPatches $r).Count -eq 0 -and (Read-Fixture $statePath).Contains('primaryRestoredAt')) $r

    # Legacy state written by the base driver has saved IDs selected by description, with no review provenance.
    Reset-Fixture
    $state = Read-Fixture $statePath; $state.Remove('reviewedConnections'); Write-Fixture $statePath $state
    $r = Run-Driver 'Approve' $true $false $true $reviewed
    Check 'legacy saved IDs without review provenance are not trusted for approval' (
        $r.code -ne 0 -and $r.flat -match 'frontdoor_review_ids_required' -and $r.flat -match 'legacy' -and
        (Mutations $r).Count -eq 0 -and -not (Read-Fixture $statePath).Contains('approvedConnections')) $r
    $r = Run-Driver 'Approve' $true $false $true ($connectionIds -join ',')
    $after = Read-Fixture $statePath
    Check 'legacy saved IDs are accepted after explicit re-review and gain provenance' (
        $r.code -eq 0 -and @(AzCalls $r '^network private-endpoint-connection approve ').Count -eq 2 -and
        @($after.approvedConnections).Count -eq 4 -and @($after.reviewedConnections).Count -eq 4) $r
    $r = Run-Driver 'Approve' $true $false $true
    Check 'reviewed approvals are idempotent without supplying IDs again' (
        $r.code -eq 0 -and (Mutations $r).Count -eq 0 -and @((Read-Fixture $statePath).approvedConnections).Count -eq 4) $r
    Reset-Fixture
    $state = Read-Fixture $statePath; $state.Remove('reviewedConnections'); Write-Fixture $statePath $state
    $list = Read-Fixture $env:FD_TEST_CONNECTIONS
    $list += @{ id = "$($targets[0])/privateEndpointConnections/legacy-other"; name = 'legacy-other'; properties = @{
        privateEndpoint = @{ id = "$($endpointIds[0])-other" }; privateLinkServiceConnectionState = @{ status = 'Approved'; description = $requests[0] } } }
    Write-Fixture $env:FD_TEST_CONNECTIONS $list
    $r = Run-Driver 'Approve' $true $false $true "$($targets[0])/privateEndpointConnections/legacy-other,$($connectionIds[1]),$($connectionIds[2]),$($connectionIds[3])"
    Check 'a different reviewed ID never silently replaces a legacy saved ID' (
        $r.code -ne 0 -and $r.flat -match 'frontdoor_review_id_mismatch' -and $r.flat -match 'legacysavedID' -and
        (Mutations $r).Count -eq 0 -and -not (Read-Fixture $statePath).Contains('approvedConnections')) $r
    foreach ($legacyPhase in 'Verify', 'Lockdown', 'DrainPrimary') {
        Reset-Fixture
        $state = Read-Fixture $statePath; $state.approvedConnections = $connectionIds; $state.Remove('previousApprovedConnections')
        $state.Remove('reviewedConnections'); $state.verifiedAt = '2026-01-01T00:00:00Z'; Write-Fixture $statePath $state
        $r = Run-Driver $legacyPhase $true $false $true
        Check "$legacyPhase refuses legacy approvals that lack review provenance" (
            $r.code -ne 0 -and $r.flat -match 'frontdoor_approval_unreviewed' -and (Mutations $r).Count -eq 0 -and
            @($r.calls | Where-Object { $_.kind -eq 'route' }).Count -eq 0) $r
    }

    # A long Verify must not write back a stale snapshot after a concurrent Approve invalidated approvals.
    Reset-Fixture
    $state = Read-Fixture $statePath; $state.approvedConnections = $connectionIds; $state.reviewedConnections = $connectionIds
    $state.Remove('previousApprovedConnections'); Write-Fixture $statePath $state
    $env:FD_TEST_CASE = 'concurrent-approve'
    $r = Run-Driver 'Verify'
    $after = Read-Fixture $statePath
    $nested = @($r.calls | Where-Object { $_.kind -eq 'concurrent-approve' })
    Check 'concurrent Approve really ran during Verify and invalidated approval' (
        $nested.Count -eq 1 -and $nested[0].code -ne 0 -and -not $nested[0].approvedPresent -and -not $nested[0].verifiedAtPresent) $r
    Check 'stale Verify cannot restore evidence invalidated by a concurrent Approve' (
        $r.code -ne 0 -and $r.flat -match 'frontdoor_state_changed' -and
        -not $after.Contains('verifiedAt') -and -not $after.Contains('approvedConnections')) $r
    Remove-Item -LiteralPath (Join-Path $scratch 'concurrent-approve.done') -ErrorAction SilentlyContinue

    Reset-Fixture
    $before = Get-Content -LiteralPath $statePath -Raw
    $lock = [IO.File]::Open((Join-Path $standbyDir 'frontdoor-state.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $r = Run-Driver 'Approve' $true $false $true $reviewed } finally { $lock.Dispose() }
    Check 'state writers refuse to proceed while another run holds the state lock' (
        $r.code -ne 0 -and $r.flat -match 'frontdoor_state_locked' -and (Mutations $r).Count -eq 0 -and
        (Get-Content -LiteralPath $statePath -Raw) -ceq $before) $r
    # A Verify that completes while Deploy, DrainPrimary or RestorePrimary is changing the configuration must not
    # leave route evidence behind for Lockdown or DrainPrimary to use.
    foreach ($changePhase in 'Deploy', 'DrainPrimary', 'RestorePrimary') {
        Reset-Fixture
        $state = Read-Fixture $statePath; $state.approvedConnections = $connectionIds; $state.reviewedConnections = $connectionIds
        $state.Remove('previousApprovedConnections'); Write-Fixture $statePath $state
        Remove-Item -LiteralPath (Join-Path $scratch 'concurrent-verify.done') -ErrorAction SilentlyContinue
        $env:FD_TEST_CASE = 'concurrent-verify'
        $r = Run-Driver $changePhase $true $false ($changePhase -ne 'RestorePrimary')
        $env:FD_TEST_CASE = ''
        $changeRun = $r
        $after = Read-Fixture $statePath
        $nested = @($r.calls | Where-Object { $_.kind -eq 'concurrent-verify' })
        Check "concurrent Verify really recorded verification during $changePhase" (
            $nested.Count -eq 1 -and $nested[0].code -eq 0 -and $nested[0].verifiedAtPresent) $r
        Check "$changePhase fails and clears verification recorded during its configuration change" (
            $r.code -ne 0 -and $r.flat -match 'frontdoor_state_changed' -and -not $after.Contains('verifiedAt') -and
            $after.Contains('verificationInvalidatedAt') -and -not $after.Contains('primaryDrainedAt') -and
            -not $after.Contains('primaryRestoredAt') -and -not $after.Contains('deployedAt')) $r
        $r = Run-Driver 'Lockdown' $true $false $true
        Check "Lockdown refuses after the concurrent Verify during $changePhase" (
            $r.code -ne 0 -and $r.output -match 'frontdoor_verify_required' -and (Mutations $r).Count -eq 0) $r
        # The failure message's Next: commands must be runnable exactly as given and complete the change.
        $nextText = if ($changeRun.flat -match 'Next:([^.]*)\.') { $Matches[1] } else { '' }
        $steps = @($nextText -split ';then' | Where-Object { $_ } | ForEach-Object {
            $tokens = @($_ -split '-' | Where-Object { $_ })
            @{ phase = ($tokens[0] -replace '^Phase', ''); flags = @($tokens | Select-Object -Skip 1) } })
        $stepResults = @(foreach ($step in $steps) {
            $unknown = @($step.flags | Where-Object { $_ -notin 'Apply', 'PrimaryOnly', 'ConfirmStandbyReady' })
            if ($unknown.Count) { @{ code = 99; output = "unknown flags: $unknown" } } else {
                Run-Driver $step.phase ($step.flags -contains 'Apply') ($step.flags -contains 'PrimaryOnly') ($step.flags -contains 'ConfirmStandbyReady') } })
        $completed = Read-Fixture $statePath
        $doneField = @{ Deploy = 'deployedAt'; DrainPrimary = 'primaryDrainedAt'; RestorePrimary = 'primaryRestoredAt' }[$changePhase]
        Check "$changePhase failure message gives runnable next steps that complete the change" (
            $steps.Count -eq 2 -and $steps[-1].phase -ceq $(if ($changePhase -eq 'DrainPrimary') { 'DrainPrimary' } else { 'Verify' }) -and
            @($stepResults | Where-Object { $_.code -ne 0 }).Count -eq 0 -and $completed.Contains($doneField) -and
            ($changePhase -eq 'DrainPrimary' -or $completed.Contains('verifiedAt'))) @{ output = "$nextText`n$(($stepResults | ForEach-Object { $_.output }) -join "`n")" }
    }

    Import-Module (Join-Path $root 'infra\dr\DrFrontDoorState.psm1') -Force
    $unitPath = Join-Path $scratch 'unit-frontdoor-state.json'
    Write-Fixture $unitPath @{ verifiedAt = 'old'; stem = 'fixture-edge' }
    $read = Read-DrFrontDoorState -StatePath $unitPath
    Write-Fixture $unitPath @{ verifiedAt = 'concurrent'; stem = 'fixture-edge' }
    $changedBefore = Get-Content -LiteralPath $unitPath -Raw
    $err = ''; try { $null = Save-DrFrontDoorState -StatePath $unitPath -Value $read.State -ExpectedHash $read.Hash } catch { $err = $_.Exception.Message }
    Check 'shared state save refuses a file changed since it was read and writes nothing' (
        $err -match '^frontdoor_state_changed' -and (Get-Content -LiteralPath $unitPath -Raw) -ceq $changedBefore)
    $read = Read-DrFrontDoorState -StatePath $unitPath; $read.State.Remove('verifiedAt')
    $hash = Save-DrFrontDoorState -StatePath $unitPath -Value $read.State -ExpectedHash $read.Hash
    Check 'shared state save writes when unchanged and returns the hash of what it wrote' (
        $hash -ceq (Read-DrFrontDoorState -StatePath $unitPath).Hash -and -not (Read-Fixture $unitPath).Contains('verifiedAt'))
    $before = Get-Content -LiteralPath $unitPath -Raw
    $null = Clear-DrFrontDoorStateEvidence -StatePath $unitPath -Fields @('verifiedAt')
    Check 'evidence clearing always changes the file so in-flight saves fail' (
        (Get-Content -LiteralPath $unitPath -Raw) -cne $before -and (Read-Fixture $unitPath).Contains('verificationInvalidatedAt'))
    $read = Read-DrFrontDoorState -StatePath $unitPath; $before = Get-Content -LiteralPath $unitPath -Raw
    $cleared = Clear-DrFrontDoorStateEvidence -StatePath $unitPath -Fields @('verifiedAt') -ExpectedHash $read.Hash
    Check 'compare-and-clear writes nothing while the file is unchanged' ($cleared -eq $false -and (Get-Content -LiteralPath $unitPath -Raw) -ceq $before)
    Write-Fixture $unitPath @{ verifiedAt = 'during-standby'; stem = 'fixture-edge' }
    $cleared = Clear-DrFrontDoorStateEvidence -StatePath $unitPath -Fields @('verifiedAt') -ExpectedHash $read.Hash
    Check 'compare-and-clear removes verification recorded after the expected state' (
        $cleared -eq $true -and -not (Read-Fixture $unitPath).Contains('verifiedAt') -and (Read-Fixture $unitPath).Contains('verificationInvalidatedAt'))
    Check 'shared state helpers leave no temporary files' (@(Get-ChildItem -LiteralPath $scratch, $standbyDir -Filter '*.tmp').Count -eq 0)
} finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
Write-Host "Front Door safety: $script:passed passed, $script:failed failed, $($script:passed + $script:failed) total"
if ($script:failed) { exit 1 }
