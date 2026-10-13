#Requires -Version 7.0
<#
.SYNOPSIS
    Opt-in live smoke suite for the deployed gateway path.

.DESCRIPTION
    Runs only with CCOF_LIVE_SMOKE=1: it queries real Azure resources with the machine's az login, and
    the token check makes one small paid Claude request (gateway.probeModel, at most 16 output tokens).
    scripts/run-tests.ps1 and the gate never call it. The test token comes from
    scripts/Get-E2ETestToken.ps1 and stays in memory.

    Statuses: PASS, FAIL, SKIP (could not run; the reason is shown), INFO (reported; never fails a run).
    Exit codes: 0 no FAIL and no regression; 1 a FAIL, or a check that passed in -BaselinePath and does
    not pass now; 2 refused (CCOF_LIVE_SMOKE is not 1, or the config is invalid).

    Adding a check: add an entry to Get-LiveSmokeCheck with an Id (area.name), a Title, a Kind (check or
    info), NeedsToken, and Run = { param($Context) ... New-SmokeOutcome ... }. Reach Azure only through
    $Context.Probes (Az, Http, RunInVm, GetToken) so tests/Test-LiveSmoke.ps1 can drive it with fakes.

    Config keys (infra/poc/live-test.config.json; for another environment, copy it and pass -ConfigPath):
      tenantId, subscriptionId, resourceGroup   The gateway's tenant, subscription and resource group
      cloud.authorityHost, cloud.graphBaseUrl   Entra and Microsoft Graph endpoints (test token)
      gateway.apimName, gateway.apiId           The APIM instance, and the API whose backends are counted
      gateway.baseUrl, gateway.apiPath, gateway.operationPath   Gateway URL, the API's path, the Messages operation
      gateway.audience                          The gateway's application ID URI
      gateway.probeModel, gateway.probeMaxTokens (1-16), gateway.anthropicVersion   The paid probe
      testClient.appDisplayName, .secretLifetimeHours (1-24), .secretDisplayNamePrefix   Test identity
      resolver.functionAppName, resolver.functionName, resolver.url   The resolver
      cosmos.accountName, cosmos.databaseName, cosmos.containers      The registry
      network.vnetName, network.foundryPrivateEndpointName            The VNet and the Foundry endpoint
      network.jumpboxNamePrefix                 No resource with this name prefix may remain
      network.dnsCheckVmName                    Optional VM inside the VNet for the DNS check

    -ApiRevision N tests a non-current API revision: both gateway checks call
    <baseUrl><apiPath>;rev=N<operationPath>, and the redundancy row reads that revision's policy. 0 (the
    default) is the current revision. The result file records the revision.

.EXAMPLE
    $env:CCOF_LIVE_SMOKE = '1'
    ./scripts/Test-LiveSmoke.ps1 -ResultPath before.json
    ./scripts/Test-LiveSmoke.ps1 -BaselinePath before.json -DnsCheckVmName <a VM in the VNet>
    ./scripts/Test-LiveSmoke.ps1 -ApiRevision 2 -Only gateway.no-token, gateway.with-token, gateway.backend-redundancy
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'infra' 'poc' 'live-test.config.json'),
    [string[]]$Only,
    [string]$DnsCheckVmName,
    [switch]$NoToken,
    [string]$ResultPath,
    [string]$BaselinePath,
    [int]$ApiRevision = 0,
    [switch]$DotSourceOnly
)

# Dot-sourcing the token script rebinds its parameters in this scope, so keep this script's own values.
$smokeOptions = @{ ConfigPath = $ConfigPath; DotSourceOnly = $DotSourceOnly.IsPresent }
. (Join-Path $PSScriptRoot 'Get-E2ETestToken.ps1') -DotSourceOnly -ConfigPath $ConfigPath
$ConfigPath = $smokeOptions.ConfigPath

$script:ArmApiVersion = 'api-version=2024-05-01'
$script:PlainHostName = '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
$script:ResourceIdPattern = '^/subscriptions/[A-Za-z0-9/._-]+$'

function Test-LiveSmokeOptIn {
    param([AllowNull()] [AllowEmptyString()] [string]$Value)
    if ($Value -eq '1') { return [pscustomobject]@{ Run = $true; Message = '' } }
    $why = if ([string]::IsNullOrEmpty($Value) -or $Value -eq '0') { 'it queries real Azure resources and makes one small paid Claude request' }
    else { "CCOF_LIVE_SMOKE is ""$Value"", and only 1 runs it" }
    [pscustomobject]@{ Run = $false; Message = "Live smoke suite refused: $why. Set CCOF_LIVE_SMOKE=1 to run it." }
}

function New-SmokeOutcome {
    param([Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL', 'SKIP', 'INFO')] [string]$Status, [string]$Detail = '')
    [pscustomobject]@{ Status = $Status; Detail = $Detail }
}

function Get-AzJson {
    <# Runs an az probe and returns its JSON, or throws with az's own message. #>
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] [string[]]$Arguments)
    $result = & $Context.Probes.Az $Arguments
    if ($result.ExitCode -ne 0) { throw "az $($Arguments[0..1] -join ' ') failed: $($result.Error)" }
    $result.Json
}

function Get-Excerpt([string]$Text) { $flat = ($Text -replace '\s+', ' ').Trim(); if ($flat.Length -gt 200) { $flat.Substring(0, 200) + '...' } else { $flat } }

function Get-GatewayRequest($Config, [int]$ApiRevision) {
    $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    # A non-current revision is addressed as <api path>;rev=<n><operation path> (MS Learn, "Revisions in Azure API Management").
    $revision = if ($ApiRevision -gt 0) { ";rev=$ApiRevision" } else { '' }
    [pscustomobject]@{
        Uri     = "$($Config.gateway.baseUrl.TrimEnd('/'))$($Config.gateway.apiPath)$revision$($Config.gateway.operationPath)?ccof_probe=live-smoke-$stamp"
        Headers = @{ 'anthropic-version' = $Config.gateway.anthropicVersion }
        Body    = @{ model = $Config.gateway.probeModel; max_tokens = [int]$Config.gateway.probeMaxTokens
            messages = @(@{ role = 'user'; content = 'Reply with the single word OK.' })
        } | ConvertTo-Json -Depth 5 -Compress
    }
}

function Get-ServiceId($Config) {
    "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroup)/providers/Microsoft.ApiManagement/service/$($Config.gateway.apimName)"
}

function Get-EndpointAddress {
    <# Host name -> private IP, read from the Foundry private endpoint's NIC (the source of truth). #>
    param($Context)
    $cfg = $Context.Config
    $endpoint = Get-AzJson $Context @('network', 'private-endpoint', 'show', '--subscription', $cfg.subscriptionId, '-g', $cfg.resourceGroup, '-n', $cfg.network.foundryPrivateEndpointName)
    $map = [ordered]@{}
    foreach ($nicId in @($endpoint.networkInterfaces | Where-Object { $_ } | ForEach-Object id)) {
        if ($nicId -notmatch $script:ResourceIdPattern) { throw "unexpected NIC id: $nicId" }
        $nic = Get-AzJson $Context @('network', 'nic', 'show', '--ids', $nicId)
        foreach ($ipConfiguration in @($nic.ipConfigurations | Where-Object { $_ })) {
            foreach ($fqdn in @($ipConfiguration.privateLinkConnectionProperties.fqdns | Where-Object { $_ })) {
                $map["$fqdn".ToLowerInvariant()] = $ipConfiguration.privateIPAddress
            }
        }
    }
    if ($map.Count -eq 0) { throw 'the private endpoint lists no host names' }
    $map
}

function ConvertFrom-GetentOutput([string]$Text) {
    $answers = @{}
    $current = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^BEGIN (\S+)') { $current = $Matches[1].ToLowerInvariant(); $answers[$current] = @(); continue }
        if ($current -and $line -match '^(\d{1,3}(\.\d{1,3}){3})\s' -and $answers[$current] -notcontains $Matches[1]) { $answers[$current] += $Matches[1] }
    }
    $answers
}

function Get-BackendRedundancy {
    param($Context)
    $cfg = $Context.Config
    $service = Get-ServiceId $cfg
    $backends = @((Get-AzJson $Context @('rest', '--method', 'get', '--url', "$service/backends", '--url-parameters', $script:ArmApiVersion)).value | Where-Object { $_ })
    $apiId = if ($Context.ApiRevision -gt 0) { "$($cfg.gateway.apiId);rev=$($Context.ApiRevision)" } else { $cfg.gateway.apiId }
    $policies = @((Get-AzJson $Context @('rest', '--method', 'get', '--url', "$service/apis/$apiId/policies", '--url-parameters', $script:ArmApiVersion)).value)
    $xml = ($policies | Where-Object { $_ } | ForEach-Object { $_.properties.value }) -join "`n"
    $ids = @([regex]::Matches($xml, 'set-backend-service[^>]*backend-id="([^"]*)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $targets = foreach ($id in $ids) {
        $backend = $backends | Where-Object { $_.name -eq $id } | Select-Object -First 1
        if ($id.StartsWith('@')) { "a backend id chosen at request time (any of $($backends.Count))" }
        elseif (-not $backend) { "$id (not defined)" }
        elseif ($backend.properties.type -eq 'Pool') { "$id (pool, $(@($backend.properties.pool.services | Where-Object { $_ }).Count) member(s))" }
        else { "$id (single backend, circuit breaker: $(if ($backend.properties.circuitBreaker) { 'yes' } else { 'no' }))" }
    }
    if (-not $ids) { $targets = @('no set-backend-service in the API policy') }
    $pools = @($backends | Where-Object { $_.properties.type -eq 'Pool' }).Count
    New-SmokeOutcome INFO "$apiId routes to $($ids.Count) backend id(s): $($targets -join '; '). Instance: $($backends.Count) backend(s), $pools pool(s)"
}

function New-LiveSmokeCheck([string]$Id, [string]$Title, [string]$Kind, [bool]$NeedsToken, [scriptblock]$Run) {
    [pscustomobject]@{ Id = $Id; Title = $Title; Kind = $Kind; NeedsToken = $NeedsToken; Run = $Run }
}

function Get-LiveSmokeCheck {
    New-LiveSmokeCheck 'apim.provisioning' 'APIM provisioningState is Succeeded' 'check' $false {
        param($Context)
        $cfg = $Context.Config
        $apim = Get-AzJson $Context @('apim', 'show', '--subscription', $cfg.subscriptionId, '-g', $cfg.resourceGroup, '-n', $cfg.gateway.apimName)
        $zones = @($apim.zones | Where-Object { $_ })
        $shape = "$($apim.sku.name) x$($apim.sku.capacity), zones: $(if ($zones) { $zones -join ',' } else { 'none' })"
        if ($apim.provisioningState -eq 'Succeeded') { New-SmokeOutcome PASS "Succeeded; $shape" } else { New-SmokeOutcome FAIL "provisioningState is $($apim.provisioningState)" }
    }
    New-LiveSmokeCheck 'gateway.no-token' 'Gateway refuses a request without a token (401)' 'check' $false {
        param($Context)
        $request = Get-GatewayRequest $Context.Config $Context.ApiRevision
        $response = & $Context.Probes.Http 'POST' $request.Uri $request.Headers $request.Body $null
        if ($response.StatusCode -eq 401) { New-SmokeOutcome PASS 'HTTP 401' } else { New-SmokeOutcome FAIL "expected HTTP 401, got $($response.StatusCode)" }
    }
    New-LiveSmokeCheck 'identity.test-token' 'Test identity issues a token and removes its run secret' 'check' $true {
        param($Context)
        $token = $Context.TokenResult
        # A token that was requested and not issued is a broken test identity; only an unrequested token is a skip.
        if (-not $token) { return New-SmokeOutcome $(if ($Context.TokenFailed) { 'FAIL' } else { 'SKIP' }) $Context.TokenNote }
        if (-not $token.SecretRemoved) { return New-SmokeOutcome FAIL "run secret $($token.SecretKeyId) is still on the test client; remove it with Graph removePassword" }
        New-SmokeOutcome PASS "token issued after $($token.Attempts) attempt(s); run secret removed"
    }
    New-LiveSmokeCheck 'gateway.with-token' 'Gateway returns a Claude message for the test token (200)' 'check' $true {
        param($Context)
        if (-not $Context.TokenResult) { return New-SmokeOutcome SKIP $Context.TokenNote }
        $request = Get-GatewayRequest $Context.Config $Context.ApiRevision
        $response = & $Context.Probes.Http 'POST' $request.Uri $request.Headers $request.Body $Context.TokenResult.AccessToken
        $message = $null
        if ($response.StatusCode -eq 200) { try { $message = $response.Content | ConvertFrom-Json } catch { $message = $null } }
        $revision = if ($Context.ApiRevision -gt 0) { "revision $($Context.ApiRevision), " } else { '' }
        if ($message.type -eq 'message' -and @($message.content).Count -gt 0) {
            $requestId = @($response.Headers['request-id'])[0]
            return New-SmokeOutcome PASS "HTTP 200, $revision$($message.model), $($message.usage.input_tokens)/$($message.usage.output_tokens) tokens, request-id $requestId"
        }
        New-SmokeOutcome FAIL "expected HTTP 200 with a message, got $($response.StatusCode) ($($revision.TrimEnd(', '))): $(Get-Excerpt $response.Content)"
    }
    New-LiveSmokeCheck 'gateway.backend-redundancy' 'Backends and pools the API can route to' 'info' $false { param($Context) Get-BackendRedundancy $Context }
    New-LiveSmokeCheck 'resolver.no-credentials' 'Resolver refuses a request without credentials (401)' 'check' $false {
        param($Context)
        $response = & $Context.Probes.Http 'POST' $Context.Config.resolver.url @{} '{}' $null
        if ($response.StatusCode -eq 401) { New-SmokeOutcome PASS 'HTTP 401' } else { New-SmokeOutcome FAIL "expected HTTP 401, got $($response.StatusCode)" }
    }
    New-LiveSmokeCheck 'resolver.function-listed' 'Function App lists the resolver function' 'check' $false {
        param($Context)
        $cfg = $Context.Config
        $functions = Get-AzJson $Context @('functionapp', 'function', 'list', '--subscription', $cfg.subscriptionId, '-g', $cfg.resourceGroup, '-n', $cfg.resolver.functionAppName)
        $names = @($functions | Where-Object { $_ } | ForEach-Object { ("$($_.name)" -split '/')[-1] })
        if ($names -contains $cfg.resolver.functionName) { New-SmokeOutcome PASS "listed: $($names -join ', ')" }
        else { New-SmokeOutcome FAIL "'$($cfg.resolver.functionName)' is not listed; found: $(if ($names) { $names -join ', ' } else { 'none' })" }
    }
    New-LiveSmokeCheck 'cosmos.containers' 'The registry containers exist' 'check' $false {
        param($Context)
        $cfg = $Context.Config
        $found = @(Get-AzJson $Context @('cosmosdb', 'sql', 'container', 'list', '--subscription', $cfg.subscriptionId, '-g', $cfg.resourceGroup,
                '-a', $cfg.cosmos.accountName, '-d', $cfg.cosmos.databaseName) | Where-Object { $_ } | ForEach-Object name)
        $missing = @($cfg.cosmos.containers | Where-Object { $found -cnotcontains $_ })
        if ($missing) { New-SmokeOutcome FAIL "missing: $($missing -join ', ')" } else { New-SmokeOutcome PASS "$(@($cfg.cosmos.containers).Count) of $(@($cfg.cosmos.containers).Count) present" }
    }
    New-LiveSmokeCheck 'cleanup.no-jumpbox' 'No temporary jump-box resource remains' 'check' $false {
        param($Context)
        $cfg = $Context.Config
        $resources = @(Get-AzJson $Context @('resource', 'list', '--subscription', $cfg.subscriptionId) | Where-Object { $_ })
        $left = @($resources | Where-Object { "$($_.name)".StartsWith($cfg.network.jumpboxNamePrefix, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object name)
        if ($left) { New-SmokeOutcome FAIL "still present: $($left -join ', ')" } else { New-SmokeOutcome PASS "none of $($resources.Count) resources starts with $($cfg.network.jumpboxNamePrefix)" }
    }
    New-LiveSmokeCheck 'network.foundry-private-dns' 'Foundry host names resolve to the private endpoint inside the VNet' 'check' $false {
        param($Context)
        if (-not $Context.DnsCheckVmName) { return New-SmokeOutcome SKIP 'no check host inside the VNet: pass -DnsCheckVmName or set network.dnsCheckVmName' }
        $expected = Get-EndpointAddress $Context
        $unsafe = @($expected.Keys | Where-Object { $_ -notmatch $script:PlainHostName })
        if ($unsafe) { return New-SmokeOutcome FAIL "refused to send a host name that is not a plain DNS name to the check host: $($unsafe -join ', ')" }
        # The check host's local resolver may hold an answer from before a DNS change; ask it to drop it first.
        $lines = @('resolvectl flush-caches') + @(foreach ($name in $expected.Keys) { "echo BEGIN $name"; "getent ahostsv4 $name" }) + 'echo END'
        $answers = ConvertFrom-GetentOutput (& $Context.Probes.RunInVm $Context.DnsCheckVmName $lines)
        $wrong = @(foreach ($name in $expected.Keys) {
                $got = @($answers[$name] | Where-Object { $_ })
                if (-not $got -or @($got | Where-Object { $_ -ne $expected[$name] }).Count) { "$name -> $(if ($got) { $got -join ',' } else { 'no answer' }) (expected $($expected[$name]))" }
            })
        if ($wrong) { New-SmokeOutcome FAIL ($wrong -join '; ') }
        else { New-SmokeOutcome PASS "$($expected.Count) host names resolve to $(@($expected.Values) -join ', ') from $($Context.DnsCheckVmName)" }
    }
    New-LiveSmokeCheck 'network.foundry-pe-traffic' 'Bytes through the Foundry private endpoint, last 60 minutes' 'info' $false {
        param($Context)
        $cfg = $Context.Config
        $id = "/subscriptions/$($cfg.subscriptionId)/resourceGroups/$($cfg.resourceGroup)/providers/Microsoft.Network/privateEndpoints/$($cfg.network.foundryPrivateEndpointName)"
        # Azure Monitor sometimes answers an identical query with no data points at all, in bursts of a few
        # seconds (seen 2026-10-11), so ask up to 4 times, 5 s apart.
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            $metrics = Get-AzJson $Context @('monitor', 'metrics', 'list', '--resource', $id, '--metric', 'PEBytesIn', 'PEBytesOut', '--interval', 'PT1M', '--offset', '1h', '--aggregation', 'Total')
            $points = @($metrics.value | Where-Object { $_ } | ForEach-Object { $_.timeseries } | ForEach-Object { $_.data } | Where-Object { $null -ne $_.total })
            if ($points.Count -gt 0) { break }
            if ($attempt -lt 4) { & $Context.Probes.Sleep 5 }
        }
        if ($points.Count -eq 0) { return New-SmokeOutcome INFO "no data points in $($attempt - 1) answers from Azure Monitor" }
        $sum = @{ PEBytesIn = 0L; PEBytesOut = 0L }
        foreach ($metric in @($metrics.value | Where-Object { $_ })) {
            $sum[$metric.name.value] = [long](@($metric.timeseries | ForEach-Object { $_.data } | Where-Object { $null -ne $_.total }) | Measure-Object -Property total -Sum).Sum
        }
        New-SmokeOutcome INFO "in $($sum.PEBytesIn) bytes, out $($sum.PEBytesOut) bytes (Azure Monitor lags a few minutes)"
    }
}

function Compare-LiveSmokeResult {
    <# A regression is a check that passed in the baseline and does not pass now. INFO rows never regress. #>
    param([object[]]$Baseline = @(), [object[]]$Current = @())
    $before = @{}
    foreach ($row in @($Baseline | Where-Object { $_ })) { $before[$row.Id] = $row.Status }
    @($Current | Where-Object { $_ -and $_.Kind -ne 'info' -and $before[$_.Id] -eq 'PASS' -and $_.Status -ne 'PASS' } |
        ForEach-Object { [pscustomobject]@{ Id = $_.Id; Before = 'PASS'; Now = $_.Status } })
}

function Invoke-LiveSmoke {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [hashtable]$Probes,
        [string[]]$Only,
        [string]$DnsCheckVmName,
        [switch]$NoToken,
        [object[]]$Baseline = @(),
        [int]$ApiRevision = 0
    )
    if ($ApiRevision -lt 0) { throw "ApiRevision must be 0 (the current revision) or a revision number, not $ApiRevision" }
    $Probes = $Probes.Clone()
    if (-not $Probes.Sleep) { $Probes.Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds } }
    $checks = @(Get-LiveSmokeCheck)
    $Only = @($Only | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($Only) {
        $unknown = @($Only | Where-Object { $_ -notin $checks.Id })
        if ($unknown) { throw "Unknown check id(s): $($unknown -join ', '). Known: $($checks.Id -join ', ')" }
        $checks = @($checks | Where-Object { $_.Id -in $Only })
    }
    $context = [pscustomobject]@{ Config = $Config; Probes = $Probes; TokenResult = $null; TokenNote = ''; TokenFailed = $false
        DnsCheckVmName = $DnsCheckVmName; ApiRevision = $ApiRevision
    }
    if ($NoToken) { $context.TokenNote = 'no token requested (-NoToken)' }
    elseif (@($checks | Where-Object NeedsToken).Count -gt 0) {
        try { $context.TokenResult = & $Probes.GetToken }
        catch { $context.TokenNote = "no test token: $($_.Exception.Message)"; $context.TokenFailed = $true }
    }
    $results = foreach ($check in $checks) {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        try { $outcome = & $check.Run $context }
        catch {
            $outcome = if ($check.Kind -eq 'info') { New-SmokeOutcome INFO "could not read: $($_.Exception.Message)" }
            else { New-SmokeOutcome FAIL $_.Exception.Message }
        }
        [pscustomobject]@{ Id = $check.Id; Title = $check.Title; Kind = $check.Kind; Status = $outcome.Status; Detail = $outcome.Detail; DurationMs = $timer.ElapsedMilliseconds }
    }
    $results = @($results)
    $regressions = @(Compare-LiveSmokeResult -Baseline $Baseline -Current $results)
    $failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0
    [pscustomobject]@{ Results = $results; Regressions = $regressions; ExitCode = $(if ($failed -or $regressions.Count -gt 0) { 1 } else { 0 }) }
}

function Format-LiveSmokeTable {
    param([object[]]$Results = @(), [object[]]$Regressions = @())
    $regressed = @($Regressions | Where-Object { $_ } | ForEach-Object Id)
    $rows = foreach ($row in @($Results | Where-Object { $_ })) {
        $status = if ($regressed -contains $row.Id) { "$($row.Status) REGRESSED" } else { $row.Status }
        '{0,-15} {1,-28} {2}' -f $status, $row.Id, $row.Detail
    }
    $summary = (@($Results | Where-Object { $_ }) | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    if ($regressed) { $summary += "; regressed since the baseline: $($regressed -join ', ')" }
    (@(('{0,-15} {1,-28} {2}' -f 'STATUS', 'CHECK', 'DETAIL')) + $rows + '' + "Summary: $summary") -join [Environment]::NewLine
}

function Save-LiveSmokeResult {
    param([Parameter(Mandatory)] [object[]]$Results, [Parameter(Mandatory)] [string]$Path, [int]$ApiRevision = 0)
    [pscustomobject]@{ version = 1; finishedUtc = [datetime]::UtcNow.ToString('o'); apiRevision = $ApiRevision
        results = @($Results | Select-Object Id, Title, Kind, Status, Detail, DurationMs)
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Read-LiveSmokeBaseline {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Baseline not found: $Path" }
    @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).results)
}

function Invoke-AzCli {
    param([string[]]$Arguments)
    $output = & az @Arguments --only-show-errors -o json 2>&1
    $exitCode = $LASTEXITCODE
    $errorText = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' ').Trim()
    $text = (@($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
    $json = if ($exitCode -eq 0 -and $text) { $text | ConvertFrom-Json -Depth 64 -NoEnumerate } else { $null }
    [pscustomobject]@{ ExitCode = $exitCode; Json = $json; Error = $errorText }
}

function Invoke-HttpProbe {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [string]$Body, [securestring]$BearerToken)
    $request = @{ Method = $Method; Uri = $Uri; Headers = $Headers; Body = $Body; ContentType = 'application/json'; SkipHttpErrorCheck = $true
        TimeoutSec = 60; UserAgent = 'ccof-live-smoke/1.0'; ErrorAction = 'Stop'
    }
    if ($BearerToken) { $request.Authentication = 'Bearer'; $request.Token = $BearerToken }
    $response = Invoke-WebRequest @request
    [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Content = "$($response.Content)"; Headers = $response.Headers }
}

if (-not $smokeOptions.DotSourceOnly) {
    $optIn = Test-LiveSmokeOptIn -Value $env:CCOF_LIVE_SMOKE
    if (-not $optIn.Run) { Write-Output $optIn.Message; exit 2 }
    try {
        $overrides = @{}
        if ($DnsCheckVmName) { $overrides['network.dnsCheckVmName'] = $DnsCheckVmName }
        $config = Read-LiveTestConfig -Path $ConfigPath -Overrides $overrides
        $baseline = if ($BaselinePath) { @(Read-LiveSmokeBaseline -Path $BaselinePath) } else { @() }
    }
    catch { Write-Output "Live smoke suite refused: $($_.Exception.Message)"; exit 2 }

    $probes = @{
        Az       = ${function:Invoke-AzCli}
        Http     = ${function:Invoke-HttpProbe}
        RunInVm  = {
            param([string]$VmName, [string[]]$Lines)
            $result = Invoke-AzCli -Arguments (@('vm', 'run-command', 'invoke', '--subscription', $config.subscriptionId, '-g', $config.resourceGroup,
                    '-n', $VmName, '--command-id', 'RunShellScript', '--scripts') + $Lines)
            if ($result.ExitCode -ne 0) { throw "run-command on $VmName failed: $($result.Error)" }
            $message = "$(@($result.Json.value)[0].message)"
            if ($message -match '(?s)\[stdout\]\s*(.*?)\s*\[stderr\]') { $Matches[1] } else { $message }
        }
        GetToken = {
            Get-E2ETestToken -TenantId $config.tenantId -ClientAppName $config.testClient.appDisplayName -Audience $config.gateway.audience `
                -AuthorityHost $config.cloud.authorityHost -GraphBaseUrl $config.cloud.graphBaseUrl `
                -SecretLifetimeHours $config.testClient.secretLifetimeHours -SecretDisplayNamePrefix $config.testClient.secretDisplayNamePrefix
        }
    }
    $run = $null
    try { $run = Invoke-LiveSmoke -Config $config -Probes $probes -Only $Only -DnsCheckVmName $config.network.dnsCheckVmName -NoToken:$NoToken -Baseline $baseline -ApiRevision $ApiRevision }
    catch { Write-Output "Live smoke suite refused: $($_.Exception.Message)"; exit 2 }
    Write-Output (Format-LiveSmokeTable -Results $run.Results -Regressions $run.Regressions)
    if ($ResultPath) { Save-LiveSmokeResult -Results $run.Results -Path $ResultPath -ApiRevision $ApiRevision }
    exit $run.ExitCode
}
