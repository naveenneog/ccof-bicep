#Requires -Version 7.0
<#
.SYNOPSIS
    D2 steps for the gateway (docs/DEPLOYMENT-STAGES.md): the APIM API, its operation and backend
    entities, the check that each second-tenant backend's secret named value exists, the gateway
    configuration for WP-GW's renderer, the policy revision through WP-GW's
    infra/gateway/Deploy-GatewayRevision.ps1 (non-current, smoke-tested on its revision URL, made
    current only when gateway.promoteAfterSmoke is true), and the final smoke tests.
    Never calls `az apim update` (it removes the managed identity) and never writes a secret.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.D2Steps.psm1')

$script:Arm = 'https://management.azure.com'
$script:ApiVersion = '2024-05-01'
# The Anthropic Messages operation of the live PoC API (docs/DEPLOYMENT-GUIDE.md, Step 4).
$script:Operation = @{ id = 'create-message'; displayName = 'Create message'; method = 'POST'; urlTemplate = '/v1/messages' }
# Revision 1 answers 503 until WP-GW's rendered policy is made current: the gateway never serves unchecked.
$script:InitialPolicy = '<policies><inbound><return-response><set-status code="503" reason="Service Unavailable" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"type":"error","error":{"type":"api_error","message":"The gateway is not configured yet."}}</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

function Invoke-CoreD2Apim {
    param($Ctx)
    $apim = "$script:Arm$($Ctx.D1.apim.id)"
    $a = $Ctx.Answers.apim
    $writes = 0
    $apiUrl = "$apim/apis/$($a.apiId)?api-version=$script:ApiVersion"
    $desired = @{ displayName = $a.apiDisplayName; path = $a.apiPath; protocols = @('https'); subscriptionRequired = $false }
    $api = & $Ctx.Send 'GET' $apiUrl $null
    $created = $false
    if ($api.Status -eq 404) { $created = $true }
    elseif ($api.Status -ne 200) { return New-CoreStepResult 'failed' -ReasonCode "api_read_$($api.Status)" }
    $p = if ($api.Status -eq 200) { $api.Content.properties } else { $null }
    if ($created -or $p.path -cne $desired.path -or $p.displayName -cne $desired.displayName -or [bool]$p.subscriptionRequired -ne $false -or (@($p.protocols) -join ',') -ne 'https') {
        $put = & $Ctx.Send 'PUT' $apiUrl @{ properties = $desired }
        if ($put.Status -notin @(200, 201, 202)) { return New-CoreStepResult 'failed' -ReasonCode "api_write_$($put.Status)_$($put.ErrorCode)" }
        $writes++
    }
    if ($created) {
        $policy = & $Ctx.Send 'PUT' "$apim/apis/$($a.apiId)/policies/policy?api-version=$script:ApiVersion" @{ properties = @{ format = 'rawxml'; value = $script:InitialPolicy } }
        if ($policy.Status -notin @(200, 201)) { return New-CoreStepResult 'failed' -ReasonCode "initial_policy_$($policy.Status)" }
        $writes++
    }
    $opUrl = "$apim/apis/$($a.apiId)/operations/$($script:Operation.id)?api-version=$script:ApiVersion"
    $op = & $Ctx.Send 'GET' $opUrl $null
    if ($op.Status -notin @(200, 404)) { return New-CoreStepResult 'failed' -ReasonCode "operation_read_$($op.Status)" -Lines @("The $($script:Operation.id) operation could not be read (HTTP $($op.Status)), so it is not verified. Nothing was changed for it.") }
    if ($op.Status -eq 404 -or ($op.Content.properties.method -ne 'POST' -or $op.Content.properties.urlTemplate -cne $script:Operation.urlTemplate)) {
        $put = & $Ctx.Send 'PUT' $opUrl @{ properties = @{ displayName = $script:Operation.displayName; method = $script:Operation.method; urlTemplate = $script:Operation.urlTemplate; templateParameters = @(); responses = @() } }
        if ($put.Status -notin @(200, 201, 202)) { return New-CoreStepResult 'failed' -ReasonCode "operation_write_$($put.Status)" }
        $writes++
    }
    foreach ($b in @($Ctx.Answers.backends)) {
        $url = "$apim/backends/$($b.id)?api-version=$script:ApiVersion"
        $current = & $Ctx.Send 'GET' $url $null
        if ($current.Status -notin @(200, 404)) { return New-CoreStepResult 'failed' -ReasonCode "backend_read_$($current.Status)_$($b.id)" -Lines @("Backend $($b.id) could not be read (HTTP $($current.Status)); an unreadable backend is never taken as absent. Nothing was changed for it.") }
        if ($current.Status -eq 200 -and $current.Content.properties.url -ceq $b.url) { continue }
        $put = & $Ctx.Send 'PUT' $url @{ properties = @{ url = $b.url; protocol = 'http'; tls = @{ validateCertificateChain = $true; validateCertificateName = $true } } }
        if ($put.Status -notin @(200, 201)) { return New-CoreStepResult 'failed' -ReasonCode "backend_write_$($put.Status)_$($b.id)" }
        $writes++
    }
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($b in @($Ctx.Answers.backends | Where-Object { $_.backendMode -eq 'second-tenant' })) {
        $nv = & $Ctx.Send 'GET' "$apim/namedValues/$($b.secretNamedValue)?api-version=$script:ApiVersion" $null
        if ($nv.Status -ne 200 -or $nv.Content.properties.secret -ne $true) { $missing.Add("$($b.id): secret named value $($b.secretNamedValue)") }
    }
    if ($missing.Count) {
        return New-CoreStepResult 'failed' -ReasonCode 'secret_named_value_missing' -Lines (@('Each second-tenant backend needs its client secret in APIM as a secret named value, created by the backend owner (docs/DEPLOYMENT-GUIDE.md, Step 4; APIM > Named values > Add, type Secret). Missing:') + @($missing | ForEach-Object { "  - $_" }))
    }
    New-CoreStepResult $(if ($writes) { 'applied' } else { 'unchanged' }) -Outputs @{ apiId = $a.apiId; operation = $script:Operation.id; backends = @($Ctx.Answers.backends | ForEach-Object id); createdApi = $created } -Writes $writes
}

function New-CoreGatewayConfig {
    <#
    .SYNOPSIS
        The WP-GW gateway configuration (infra/gateway/gateway-config.schema.json, main 59a55b2) from
        the answers and the D1 record. Static backends are the second-tenant ones only; managed
        identity backends come by data from the resolver (C-8). entra.testIdentities is the answers'
        test-identity decision (WP-NET S1): appRole is null whenever app-only tokens are refused.
        entra.delegatedClientAppIds is the developer sign-in app from the D1 record: the one client a
        person's token may come from (WP-SEC A3).
    #>
    param([System.Collections.IDictionary]$Answers, [System.Collections.IDictionary]$D1)
    $a = $Answers; $g = $a.gateway; $cache = $a.availability.entitlementCache; $reg = $D1.registrations
    $inference = [ordered]@{}
    foreach ($b in @($a.backends)) { if ($b.deploymentInferenceGeo -and $b.deploymentInferenceGeo.Count) { $inference[$b.id] = $b.deploymentInferenceGeo } }
    [ordered]@{
        schemaVersion = 1
        configurationId = $g.configurationId
        apim = [ordered]@{ subscriptionId = $a.target.subscriptionId; resourceGroup = $a.target.resourceGroup.name; serviceName = ([string]$D1.apim.id).Split('/')[-1]; apiId = $a.apim.apiId; gatewayBaseUrl = [string]$D1.apim.gatewayUrl; apiPath = $a.apim.apiPath }
        entra = [ordered]@{
            tenantId = $a.target.tenantId; authorityHost = $a.target.cloud.authorityHost; v1IssuerHost = $a.target.cloud.v1IssuerHost
            audiences = @(@($reg.gatewayApi.identifierUri, $reg.gatewayApi.appId) | Where-Object { $_ } | Select-Object -Unique)
            delegatedScope = $a.identity.gatewayApi.scope
            delegatedClientAppIds = @(([string]$reg.developerSignIn.appId).ToLowerInvariant())
            testIdentities = [ordered]@{ allowAppOnlyTokens = [bool]$a.identity.allowAppOnlyTestTokens; clientAppIds = @($a.identity.testClientAppIds); appRole = $a.identity.testClientAppRole }
        }
        admission = $g.admission
        resolver = [ordered]@{ url = "https://$($D1.apps.resolver.hostName)/api/resolve"; tokenAudience = $reg.resolverApi.appId; timeoutSeconds = $g.resolverTimeoutSeconds; projectHeaderName = $g.projectHeaderName }
        entitlementCache = [ordered]@{ keyVersion = $g.keyVersion; cachingType = $cache.cachingType; allowTtlSeconds = $cache.allowTtlSeconds; refusalTtlSeconds = $cache.refusalTtlSeconds; lastKnownGoodGraceSeconds = $cache.lastKnownGoodGraceSeconds; refreshBackoffSeconds = $cache.refreshBackoffSeconds; unavailableRetryAfterSeconds = $cache.unavailableRetryAfterSeconds }
        tokenLimits = $g.tokenLimits
        backends = @($a.backends | Where-Object { $_.backendMode -eq 'second-tenant' } | ForEach-Object {
                [ordered]@{ id = $_.id; credential = [ordered]@{ type = 'crossTenantClientCredentials'; tenantId = $_.tenantId; clientId = $_.clientId; clientSecretNamedValue = $_.secretNamedValue; authorityHost = $a.target.cloud.authorityHost; scope = $_.scope; tokenRequestTimeoutSeconds = $_.tokenRequestTimeoutSeconds } }
            })
        inferenceGeo = $inference
        forwarding = [ordered]@{ defaultAnthropicVersion = $g.defaultAnthropicVersion }
    }
}

function Get-CoreCurrentRevision {
    param($Ctx)
    $r = & $Ctx.Send 'GET' "$script:Arm$($Ctx.D1.apim.id)/apis/$($Ctx.Answers.apim.apiId)/revisions?api-version=$script:ApiVersion" $null
    $current = @($r.Content.value | Where-Object { $_.isCurrent -eq $true })[0]
    if ($current) { return [string]$current.apiRevision }
    return $null
}

function Invoke-CoreD2Policy {
    param($Ctx)
    $gatewayDir = Join-Path $Ctx.OutDir 'gateway'
    New-Item -ItemType Directory -Path $gatewayDir -Force | Out-Null
    $config = New-CoreGatewayConfig -Answers $Ctx.Answers -D1 $Ctx.D1
    $configPath = Join-Path $gatewayDir "$($config.configurationId).json"
    $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
    $render = & $Ctx.Pieces.GatewayRender $configPath (Join-Path $gatewayDir 'render')
    if (-not $render -or $render.policySha256 -notmatch '^[0-9a-f]{64}$') { return New-CoreStepResult 'failed' -ReasonCode 'render_failed' -Lines @('WP-GW render.ts refused the generated configuration; see its message.') }
    $promote = [bool]$Ctx.Answers.gateway.promoteAfterSmoke
    $previous = $Ctx.Previous['policy']
    if ($previous -and $previous.policySha256 -eq $render.policySha256 -and ([bool]$previous.promoted -eq $promote -or -not $promote)) {
        return New-CoreStepResult 'unchanged' -Outputs $previous
    }
    $current = Get-CoreCurrentRevision $Ctx
    if (-not $current) { return New-CoreStepResult 'failed' -ReasonCode 'revisions_unreadable' }
    $answersPath = Join-Path $gatewayDir 'create-revision.answers.json'
    [ordered]@{ action = 'createRevision'; apiId = $Ctx.Answers.apim.apiId; configurationId = $config.configurationId; expectedCurrentRevision = $current; policySha256 = $render.policySha256; approvedBy = $Ctx.Actor.objectId } | ConvertTo-Json | Set-Content -LiteralPath $answersPath -Encoding utf8NoBOM
    $deployed = & $Ctx.Pieces.GatewayDeploy $configPath $answersPath (Join-Path $gatewayDir 'out') $false $null
    if (-not $deployed -or -not $deployed.Revision -or -not $deployed.StoredMatchesRendered) { return New-CoreStepResult 'failed' -ReasonCode 'revision_not_created' }
    $base = ([string]$Ctx.D1.apim.gatewayUrl).TrimEnd('/')
    $revisionStatus = & $Ctx.Pieces.Http 'POST' "$base/$($Ctx.Answers.apim.apiPath);rev=$($deployed.Revision)/v1/messages"
    if ($revisionStatus -ne 401) { return New-CoreStepResult 'failed' -ReasonCode 'revision_smoke_failed' -Lines @("The new revision $($deployed.Revision) answered $revisionStatus without a token, not 401. It stays non-current.") }
    $outputs = [ordered]@{ policySha256 = $render.policySha256; revision = [string]$deployed.Revision; previousRevision = $current; promoted = $false; configurationId = $config.configurationId }
    if ($promote) {
        $note = "D2 stage: configuration $($config.configurationId), policy $($render.policySha256.Substring(0, 12)); revision URL answered 401 without a token."
        $makePath = Join-Path $gatewayDir 'make-current.answers.json'
        [ordered]@{ action = 'makeCurrent'; apiId = $Ctx.Answers.apim.apiId; revision = [string]$deployed.Revision; expectedCurrentRevision = $current; releaseNote = $note; approvedBy = $Ctx.Actor.objectId } | ConvertTo-Json | Set-Content -LiteralPath $makePath -Encoding utf8NoBOM
        $made = & $Ctx.Pieces.GatewayDeploy $configPath $makePath (Join-Path $gatewayDir 'out') $true ([string]$deployed.Revision)
        if (-not $made -or [string]$made.CurrentRevision -ne [string]$deployed.Revision) { return New-CoreStepResult 'failed' -ReasonCode 'make_current_failed' }
        $currentStatus = & $Ctx.Pieces.Http 'POST' "$base/$($Ctx.Answers.apim.apiPath)/v1/messages"
        if ($currentStatus -ne 401) { return New-CoreStepResult 'failed' -ReasonCode 'current_smoke_failed' -Lines @("After make-current the gateway answered $currentStatus without a token. Roll back: infra/gateway/Deploy-GatewayRevision.ps1 -MakeCurrent -Revision $current.") }
        $outputs.promoted = $true
    }
    New-CoreStepResult 'applied' -Outputs $outputs -Writes 1
}

function Invoke-CoreD2Smoke {
    param($Ctx)
    $lines = [System.Collections.Generic.List[string]]::new()
    $failed = $false
    $policy = $Ctx.Previous['policy']
    $base = ([string]$Ctx.D1.apim.gatewayUrl).TrimEnd('/')
    $path = if ($policy -and $policy.promoted) { "$base/$($Ctx.Answers.apim.apiPath)/v1/messages" } else { "$base/$($Ctx.Answers.apim.apiPath);rev=$($policy.revision)/v1/messages" }
    $status = & $Ctx.Pieces.Http 'POST' $path
    $lines.Add("gateway without a token: $status (expected 401)"); if ($status -ne 401) { $failed = $true }
    $status = & $Ctx.Pieces.Http 'POST' "https://$($Ctx.D1.apps.resolver.hostName)/api/resolve"
    $lines.Add("resolver without APIM's token: $status (expected 401)"); if ($status -ne 401) { $failed = $true }
    $expected = @{ resolver = @('resolve', 'health'); sync = @('syncEntitlement'); reconciler = @('reconcileBudgets') }
    foreach ($app in $expected.Keys) {
        $list = & $Ctx.Send 'GET' "$script:Arm$($Ctx.D1.apps[$app].functionAppId)/functions?api-version=2024-04-01" $null
        $names = @($list.Content.value | ForEach-Object { ([string]$_.name).Split('/')[-1] })
        $absent = @($expected[$app] | Where-Object { $names -notcontains $_ })
        $lines.Add("$app functions listed: $(if ($absent.Count) { "missing $($absent -join ', ')" } else { 'yes' })"); if ($absent.Count) { $failed = $true }
    }
    New-CoreStepResult $(if ($failed) { 'failed' } else { 'applied' }) -ReasonCode $(if ($failed) { 'smoke_failed' } else { $null }) -Outputs @{ checks = @($lines) } -Lines $lines.ToArray()
}

Export-ModuleMember -Function Invoke-CoreD2Apim, New-CoreGatewayConfig, Invoke-CoreD2Policy, Invoke-CoreD2Smoke, Get-CoreCurrentRevision
