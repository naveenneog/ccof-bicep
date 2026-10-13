#Requires -Version 7.0
<#
.SYNOPSIS
    D2 steps for the gateway (docs/DEPLOYMENT-STAGES.md): the APIM API, its operation and backend
    entities, the check that each second-tenant backend's secret named value exists, the gateway
    configuration for WP-GW's renderer, the policy revision through WP-GW's
    infra/gateway/Deploy-GatewayRevision.ps1 (non-current, smoke-tested on its revision URL, made
    current only when gateway.promoteAfterSmoke is true), and the final smoke tests. A recorded
    revision with the render's digest is unchanged only when the live gateway still holds it: current
    if it was made current, with a stored policy equal to the render (WP-SEC C7).
    Never calls `az apim update` (it removes the managed identity) and never writes a secret.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.D2Steps.psm1')
# WP-GW's comparison of a stored policy with a render: whitespace ignored, as APIM reformats the text.
Import-Module (Join-Path $PSScriptRoot '../infra/gateway/GatewayDeploy.psm1')

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

function Test-CoreD2PolicyLive {
    <#
    .SYNOPSIS
        WP-SEC C7: whether the live gateway still holds what the policy step's record says. The recorded
        revision is current when the record says it was made current, and its stored policy equals the
        render, whitespace and line ends ignored as WP-GW compares them (APIM stores the text
        reformatted: docs/status/WP-GW.md, live change G23). Returns Verified, and Lines that say why not.
    #>
    param($Ctx, $Previous, [string]$RenderedPolicy)
    $no = { param([string]$Why) [pscustomobject]@{ Verified = $false; Lines = @($Why) } }
    $api = "$script:Arm$($Ctx.D1.apim.id)/apis/$($Ctx.Answers.apim.apiId)"
    $revision = [string]$Previous.revision
    # The revision goes into the read's ARM path, so only a revision number is read.
    if ($revision -cnotmatch '^[1-9][0-9]{0,5}\z') { return & $no "The recorded revision '$revision' is not a revision number." }
    if ([string]::IsNullOrWhiteSpace($RenderedPolicy)) { return & $no 'The render gave no policy text to compare.' }
    $policyUrl = "$api;rev=$revision/policies/policy?api-version=$script:ApiVersion&format=rawxml"
    if ($Previous.promoted) {
        $list = & $Ctx.Send 'GET' "$api/revisions?api-version=$script:ApiVersion" $null
        if ($list.Status -ne 200) { return & $no "The API's revisions could not be read (HTTP $($list.Status))." }
        $current = @($list.Content.value | Where-Object { $_.isCurrent -eq $true })
        if ($current.Count -ne 1) { return & $no "The API has $($current.Count) current revisions, not one." }
        if ([string]$current[0].apiRevision -cne $revision) { return & $no "Revision $($current[0].apiRevision) is current, not the recorded revision $revision." }
        # The API id without ;rev=N names the current revision (Learn, "Api Policy - Get").
        $policyUrl = "$api/policies/policy?api-version=$script:ApiVersion&format=rawxml"
    }
    $stored = & $Ctx.Send 'GET' $policyUrl $null
    $text = if ($stored.Status -eq 200) { $stored.Content.properties.value } else { $null }
    if ($text -isnot [string]) { return & $no "The stored policy of revision $revision could not be read (HTTP $($stored.Status))." }
    if (-not [string]::Equals((Format-PolicyForCompare $text), (Format-PolicyForCompare $RenderedPolicy), [StringComparison]::Ordinal)) {
        return & $no "The stored policy of revision $revision differs from the render."
    }
    [pscustomobject]@{ Verified = $true; Lines = @() }
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
    $redeploy = @()
    if ($previous -and $previous.policySha256 -eq $render.policySha256 -and ([bool]$previous.promoted -eq $promote -or -not $promote)) {
        # WP-SEC C7: the recorded digest sits in the shared record, so only a live revision that holds the
        # render is unchanged. Any other answer, an error included, deploys the policy again.
        $check = try {
            $rendered = if ($render.policyPath -and (Test-Path -LiteralPath $render.policyPath -PathType Leaf)) { Get-Content -LiteralPath $render.policyPath -Raw } else { $null }
            Test-CoreD2PolicyLive -Ctx $Ctx -Previous $previous -RenderedPolicy $rendered
        }
        catch { [pscustomobject]@{ Verified = $false; Lines = @("The live check failed: $($_.Exception.Message)") } }
        if ($check.Verified -is [bool] -and $check.Verified) { return New-CoreStepResult 'unchanged' -Outputs $previous }
        $redeploy = @("The recorded policy revision $($previous.revision) was not verified live, so D2 deployed the policy again:") + @($check.Lines | ForEach-Object { "  $_" })
    }
    $result = Publish-CoreD2PolicyRevision -Ctx $Ctx -Config $config -ConfigPath $configPath -Render $render -GatewayDir $gatewayDir -Promote $promote
    if ($redeploy.Count) {
        $result.Lines = @($redeploy) + @($result.Lines)
        if ($result.State -eq 'applied') { $result.ReasonCode = 'policy_not_verified_redeployed' }
    }
    $result
}

function Publish-CoreD2PolicyRevision {
    <#
    .SYNOPSIS
        The rendered policy as a new non-current revision through WP-GW's deploy script, smoke-tested on
        its revision URL, and made current when -Promote. Returns the step result.
    #>
    param($Ctx, $Config, [string]$ConfigPath, $Render, [string]$GatewayDir, [bool]$Promote)
    $current = Get-CoreCurrentRevision $Ctx
    if (-not $current) { return New-CoreStepResult 'failed' -ReasonCode 'revisions_unreadable' }
    $answersPath = Join-Path $GatewayDir 'create-revision.answers.json'
    [ordered]@{ action = 'createRevision'; apiId = $Ctx.Answers.apim.apiId; configurationId = $Config.configurationId; expectedCurrentRevision = $current; policySha256 = $Render.policySha256; approvedBy = $Ctx.Actor.objectId } | ConvertTo-Json | Set-Content -LiteralPath $answersPath -Encoding utf8NoBOM
    $deployed = & $Ctx.Pieces.GatewayDeploy $ConfigPath $answersPath (Join-Path $GatewayDir 'out') $false $null
    if (-not $deployed -or -not $deployed.Revision -or -not $deployed.StoredMatchesRendered) { return New-CoreStepResult 'failed' -ReasonCode 'revision_not_created' }
    # The record of the revision D2 will test and make current must be this run's: this render, made from
    # the revision D2 found current.
    if ([string]$deployed.PolicySha256 -cne [string]$Render.policySha256 -or [string]$deployed.CurrentRevision -cne [string]$current) {
        return New-CoreStepResult 'failed' -ReasonCode 'revision_record_mismatch' -Lines @("The createRevision record (deployment.json in $(Join-Path $GatewayDir 'out')) names revision $($deployed.Revision) with policy $([string]$deployed.PolicySha256), made from revision $([string]$deployed.CurrentRevision); this run rendered $($Render.policySha256) with revision $current current. Revision $($deployed.Revision) stays non-current; nothing was made current.")
    }
    $base = ([string]$Ctx.D1.apim.gatewayUrl).TrimEnd('/')
    $revisionStatus = & $Ctx.Pieces.Http 'POST' "$base/$($Ctx.Answers.apim.apiPath);rev=$($deployed.Revision)/v1/messages"
    if ($revisionStatus -ne 401) { return New-CoreStepResult 'failed' -ReasonCode 'revision_smoke_failed' -Lines @("The new revision $($deployed.Revision) answered $revisionStatus without a token, not 401. It stays non-current.") }
    $outputs = [ordered]@{ policySha256 = $Render.policySha256; revision = [string]$deployed.Revision; previousRevision = $current; promoted = $false; configurationId = $Config.configurationId }
    if ($Promote) {
        $note = "D2 stage: configuration $($Config.configurationId), policy $($Render.policySha256.Substring(0, 12)); revision URL answered 401 without a token."
        $makePath = Join-Path $GatewayDir 'make-current.answers.json'
        [ordered]@{ action = 'makeCurrent'; apiId = $Ctx.Answers.apim.apiId; revision = [string]$deployed.Revision; expectedCurrentRevision = $current; releaseNote = $note; approvedBy = $Ctx.Actor.objectId } | ConvertTo-Json | Set-Content -LiteralPath $makePath -Encoding utf8NoBOM
        $made = & $Ctx.Pieces.GatewayDeploy $ConfigPath $makePath (Join-Path $GatewayDir 'out') $true ([string]$deployed.Revision)
        # make-current's own record must name the revision D2 made current, and that revision as current.
        if (-not $made -or [string]$made.Revision -cne [string]$deployed.Revision -or [string]$made.CurrentRevision -cne [string]$deployed.Revision) {
            return New-CoreStepResult 'failed' -ReasonCode 'make_current_failed' -Lines @("Deploy-GatewayRevision.ps1 -MakeCurrent did not record revision $($deployed.Revision) as current (make-current.json in $(Join-Path $GatewayDir 'out')). Check the API's releases; to roll back: infra/gateway/Deploy-GatewayRevision.ps1 -MakeCurrent -Revision $current.")
        }
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
