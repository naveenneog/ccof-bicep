#Requires -Version 7.0
<#
.SYNOPSIS
    Quick-start for one administrator (ADR-0024, Proposed; docs/QUICKSTART.md): numbered, rerunnable
    steps around infra/quickstart/main.bicep. Phase 2 of three: the Entra prerequisites come before
    (an Entra administrator), the Graph application permissions after (Grant-SyncGraphPermissions.ps1,
    a Privileged Role Administrator). This script never creates or changes an Entra object.

.DESCRIPTION
    Steps: 1 checks (read-only), 2 build, 3 Bicep deployment, 4 code, 5 seed documents, 6 Graph
    permission (prints the post-deployment command), 7 smoke, 8 client.
    State: .env.quickstart.state.json next to the parameters file (git-ignored). A rerun resumes at
    the first step not completed; -From <n> restarts there; -Only <n> runs one step.
    -WhatIfOnly makes step 3 run `az deployment group what-if` and stop.
#>
[CmdletBinding()]
param(
    [string]$ParametersPath = (Join-Path $PSScriptRoot 'main.bicepparam'),
    [ValidateRange(1, 8)] [int]$From,
    [ValidateRange(1, 8)] [int]$Only,
    [switch]$WhatIfOnly,
    [switch]$ConfigureClient,
    [switch]$DotSourceOnly
)

$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Invoke-QuickstartSteps {
    <#
    .SYNOPSIS
        Runs the steps in order from the first one not recorded as completed (or -From), records each
        success in the state file before the next starts, and stops at the first failure.
    #>
    param([Parameter(Mandatory)] [object[]]$Steps, [Parameter(Mandatory)] [string]$StatePath, [hashtable]$Context = @{}, [int]$From, [int]$Only)
    $state = if (Test-Path -LiteralPath $StatePath) { Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable } else { @{ completed = @{} } }
    if (-not $state.completed) { $state.completed = @{} }
    if ($From) { foreach ($k in @($state.completed.Keys)) { if ([int]$k -ge $From) { $state.completed.Remove($k) } } }
    foreach ($step in $Steps) {
        $n = [int]$step.Number
        if ($Only -and $n -ne $Only) { continue }
        if (-not $Only -and $state.completed.Contains([string]$n)) { continue }
        $Context.Step = $n; $Context.State = $state
        Write-Host "== step $n $($step.Name)"
        try { $out = & $step.Action $Context }
        catch {
            Write-Host "FAILED step $n $($step.Name): $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Fix the cause, then run this script again: it resumes at step $n."
            return [pscustomobject]@{ Failed = $n; State = $state }
        }
        $state.completed[[string]$n] = @{ name = $step.Name; at = [DateTime]::UtcNow.ToString('o'); outputs = $out }
        $state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $StatePath -Encoding utf8NoBOM
    }
    return [pscustomobject]@{ Failed = $null; State = $state }
}

function Invoke-QsAz {
    # az with arguments free of ( ) | & < > ^ and quotes (Windows); JSON bodies go through files.
    param([string[]]$Arguments)
    foreach ($a in $Arguments) { if ($a -match '[()|&<>^"]') { throw "refused az argument with a shell metacharacter: $($Arguments[0..1] -join ' ')" } }
    $out = az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0..1] -join ' ') failed: $(@($out) -join ' ')" }
    $text = @($out | Where-Object { $_ -is [string] }) -join "`n"
    if ($text.Trim().StartsWith('{') -or $text.Trim().StartsWith('[')) { return $text | ConvertFrom-Json -AsHashtable -Depth 100 }
    return $text
}

function Read-QsParameters {
    param([string]$Path)
    $built = Invoke-QsAz @('bicep', 'build-params', '--file', $Path, '--stdout')
    $p = ($built.parametersJson | ConvertFrom-Json -AsHashtable -Depth 100).parameters
    $v = @{}; foreach ($k in $p.Keys) { $v[$k] = $p[$k].value }
    return $v
}

function Get-QsGraph { param([string]$Path) Invoke-QsAz @('rest', '--method', 'get', '--url', "https://graph.microsoft.com/v1.0/$Path") }

function Test-QsPrerequisites {
    param($Ctx)
    $p = $Ctx.P; $problems = [System.Collections.Generic.List[string]]::new()
    $account = Invoke-QsAz @('account', 'show')
    if ($account.tenantId -ne $p.tenantId) { $problems.Add("tenant_mismatch: az is signed in to $($account.tenantId), parameters say $($p.tenantId)") }
    if ($account.id -ne $p.names.subscriptionId) { $problems.Add("subscription_mismatch: az uses $($account.id); run az account set --subscription $($p.names.subscriptionId)") }
    $placeholders = @(($Ctx.ParametersText -split "`n") | Where-Object { $_ -match 'REPLACE-' -and $_ -notmatch '^\s*//' })
    if ($placeholders.Count) { $problems.Add("placeholders_left: $($placeholders.Count) value(s) still say REPLACE in the parameters file") }
    if ($p.sync.mode -eq 'delegated-snapshot' -and -not $p.runner.enabled) { $problems.Add('runner_required_for_delegated_snapshot: sync.mode delegated-snapshot needs the private runner VM; set runner.enabled to true (with a VM image the tenant allows) or use application-permission') }
    $apimId = "/subscriptions/$($p.apim.subscriptionId)/resourceGroups/$($p.apim.resourceGroup)/providers/Microsoft.ApiManagement/service/$($p.apim.name)"
    $apim = Invoke-QsAz @('rest', '--method', 'get', '--url', "https://management.azure.com$apimId`?api-version=2024-05-01")
    $principalId = $apim.identity.principalId
    if (-not $principalId -or $apim.identity.type -notmatch 'SystemAssigned') { $problems.Add('apim_identity_missing: the APIM has no system-assigned identity. Turn it on in the portal (APIM > Managed identities); never use az apim update, which strips it.') }
    $apimAppId = $null
    if ($principalId) { $apimAppId = (Get-QsGraph "servicePrincipals/$principalId").appId }
    $r = $p.registrations
    $gw = @((Get-QsGraph "applications?`$filter=appId eq '$($r.gatewayApi.appId)'").value)[0]
    if (-not $gw) { $problems.Add('gateway_api_missing: no application with registrations.gatewayApi.appId') }
    else {
        if ($null -eq $gw.api.requestedAccessTokenVersion) { $problems.Add('gateway_api_token_version_unset: set api.requestedAccessTokenVersion explicitly (1 or 2) in the manifest') }
        if (-not @($gw.api.oauth2PermissionScopes | Where-Object { $_.value -ceq $r.gatewayApi.scope -and $_.isEnabled }).Count) { $problems.Add("gateway_api_scope_missing: scope $($r.gatewayApi.scope) is not exposed and enabled") }
    }
    $dev = @((Get-QsGraph "applications?`$filter=appId eq '$($r.developerSignIn.appId)'").value)[0]
    if (-not $dev) { $problems.Add('developer_sign_in_missing: no application with registrations.developerSignIn.appId') }
    elseif (-not $dev.isFallbackPublicClient) { $problems.Add('developer_sign_in_not_public: allow public client flows on the Developer Sign-in app') }
    $res = @((Get-QsGraph "applications?`$filter=appId eq '$($r.resolverApi.appId)'").value)[0]
    if (-not $res) { $problems.Add('resolver_api_missing: no application with registrations.resolverApi.appId') }
    else {
        if ($res.api.requestedAccessTokenVersion -ne 2) { $problems.Add('resolver_api_token_version: the Resolver API needs requestedAccessTokenVersion 2 (ADR-0009)') }
        if (@($res.identifierUris) -notcontains "api://$($r.resolverApi.appId)") { $problems.Add("resolver_api_uri: identifier URI api://$($r.resolverApi.appId) is missing") }
    }
    foreach ($g in $p.groups) {
        $group = try { Get-QsGraph "groups/$($g.groupId)" } catch { $null }
        if (-not $group -or -not $group.securityEnabled) { $problems.Add("group_missing: $($g.projectId)/$($g.classification) group $($g.groupId) is not an existing security group") }
    }
    if ($problems.Count) { throw ("prerequisites not met (nothing was changed):`n  - " + ($problems -join "`n  - ")) }
    Write-Host 'Azure roles: Deploy needs Owner, or Contributor plus Role Based Access Control Administrator, on the resource group and on each backend account (docs/QUICKSTART.md, phase 2); ARM refuses the deployment otherwise (AuthorizationFailed).'
    return @{ apimId = $apimId; apimPrincipalId = $principalId; apimIdentityAppId = $apimAppId; gatewayBaseUrl = $apim.properties.gatewayUrl; gatewayIdentifierUri = @($gw.identifierUris)[0] }
}

function New-QsGatewayConfig {
    param($P, $Checks)
    $g = $P.gateway; $r = $P.registrations
    $inference = [ordered]@{}; foreach ($b in $P.backends) { $inference[$b.id] = $b.deploymentInferenceGeo }
    [ordered]@{
        schemaVersion = 1; configurationId = $g.configurationId
        apim = [ordered]@{ subscriptionId = $P.apim.subscriptionId; resourceGroup = $P.apim.resourceGroup; serviceName = $P.apim.name; apiId = $P.apim.apiId; gatewayBaseUrl = $Checks.gatewayBaseUrl; apiPath = $P.apim.apiPath }
        entra = [ordered]@{
            tenantId = $P.tenantId; authorityHost = 'https://login.microsoftonline.com'; v1IssuerHost = 'https://sts.windows.net'
            audiences = @(@($Checks.gatewayIdentifierUri, $r.gatewayApi.appId) | Where-Object { $_ } | Select-Object -Unique)
            delegatedScope = $r.gatewayApi.scope; delegatedClientAppIds = @(([string]$r.developerSignIn.appId).ToLowerInvariant())
            testIdentities = [ordered]@{ allowAppOnlyTokens = $false; clientAppIds = @(); appRole = $null }
        }
        admission = $g.admission
        resolver = [ordered]@{ url = "https://$($P.names.apps.resolver.functionApp).azurewebsites.net/api/resolve"; tokenAudience = $r.resolverApi.appId; timeoutSeconds = $g.resolverTimeoutSeconds; projectHeaderName = $g.projectHeaderName }
        entitlementCache = [ordered]@{ keyVersion = $g.keyVersion } + $g.entitlementCache
        tokenLimits = $g.tokenLimits; backends = @(); inferenceGeo = $inference
        forwarding = [ordered]@{ defaultAnthropicVersion = $g.defaultAnthropicVersion }
    }
}

function Invoke-QsBuild {
    param($Ctx)
    $checks = $Ctx.State.completed['1'].outputs
    $gen = $Ctx.GeneratedDir
    $config = New-QsGatewayConfig -P $Ctx.P -Checks $checks
    $configPath = Join-Path $gen 'gateway-config.json'
    $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
    node (Join-Path $script:RepoRoot 'infra/gateway/render.ts') --config $configPath --out (Join-Path $gen 'gateway') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'render_failed: infra/gateway/render.ts refused the generated configuration; see its message.' }
    Push-Location $script:RepoRoot
    try { npx tsc -p tsconfig.json | Out-Host; if ($LASTEXITCODE -ne 0) { throw 'build_failed: npx tsc -p tsconfig.json failed (run npm ci first).' } } finally { Pop-Location }
    return @{ policyPath = (Join-Path $gen "gateway/$($Ctx.P.apim.apiId).policy.xml"); gatewayConfig = $configPath }
}

function Invoke-QsDeploy {
    param($Ctx)
    $p = $Ctx.P; $checks = $Ctx.State.completed['1'].outputs; $build = $Ctx.State.completed['2'].outputs
    $built = Invoke-QsAz @('bicep', 'build-params', '--file', $Ctx.ParametersPath, '--stdout')
    $doc = $built.parametersJson | ConvertFrom-Json -AsHashtable -Depth 100
    if ($build.policyPath -and (Test-Path -LiteralPath $build.policyPath)) { $doc.parameters.policyXml = @{ value = (Get-Content -LiteralPath $build.policyPath -Raw) } }
    $doc.parameters.apimIdentityAppId = @{ value = [string]$checks.apimIdentityAppId }
    $file = Join-Path $Ctx.GeneratedDir 'main.parameters.json'
    $doc | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
    $rg = $p.names.resourceGroup
    if (-not $WhatIfOnly -and $p.names.resourceGroupMode -eq 'create') { $null = Invoke-QsAz @('group', 'create', '--name', $rg, '--location', $p.location) }
    $verb = if ($WhatIfOnly) { 'what-if' } else { 'create' }
    $template = Join-Path $PSScriptRoot 'main.bicep'
    $result = Invoke-QsAz @('deployment', 'group', $verb, '--resource-group', $rg, '--name', "$($p.names.deploymentPrefix)-quickstart", '--template-file', $template, '--parameters', "@$file")
    if ($WhatIfOnly) { Write-Host $result; throw 'what_if_only: what-if printed; no deployment was made (rerun without -WhatIfOnly).' }
    $outputs = @{}; foreach ($k in $result.properties.outputs.Keys) { $outputs[$k] = $result.properties.outputs[$k].value }
    return $outputs
}

function Invoke-QsCode {
    param($Ctx)
    Import-Module (Join-Path $script:RepoRoot 'scripts/Core.D2Code.psm1') -Force -DisableNameChecking
    $p = $Ctx.P; $stage = Join-Path $Ctx.GeneratedDir 'packages'
    $answers = @{ rateCard = $p.rateCard }
    foreach ($app in @('resolver', 'sync', 'reconciler')) {
        $pkg = New-CoreAppPackage -RepositoryRoot $script:RepoRoot -App $app -Answers $answers -AnswersDirectory $PSScriptRoot -StageRoot $stage
        if ($pkg.Missing.Count) { throw "package_files_missing for ${app}: $($pkg.Missing -join ', ')" }
        Push-Location $pkg.Directory; try { npm ci --omit=dev --no-audit --no-fund --quiet | Out-Null; if ($LASTEXITCODE -ne 0) { throw "npm_ci_failed_$app" } } finally { Pop-Location }
        $zip = Join-Path $stage "$app.zip"; New-CoreZip -Directory $pkg.Directory -ZipPath $zip
        $null = Invoke-QsAz @('functionapp', 'deployment', 'source', 'config-zip', '--resource-group', $p.names.resourceGroup, '--name', $p.names.apps[$app].functionApp, '--src', $zip)
    }
    return @{ deployed = @('resolver', 'sync', 'reconciler') }
}

function New-QsSeedDocuments {
    <#
    .SYNOPSIS
        The projects documents (one per projectId, a classification per group) in the shape of
        onboarding Stage 3 (docs/examples/pilot01-stage3.answers.json), and one backends document per
        backend (src/resolver/backend.ts BackendRecord).
    #>
    param($P)
    $projects = [ordered]@{}
    foreach ($g in $P.groups) {
        if (-not $projects.Contains($g.projectId)) {
            $projects[$g.projectId] = [ordered]@{ id = $g.projectId; projectId = $g.projectId; displayName = $g.projectId; status = 'active'; backendId = $P.backends[0].id; designatedSubscriptionId = $P.backends[0].subscriptionId; supersedes = $null; retiredAt = $null; classifications = [ordered]@{} }
        }
        $projects[$g.projectId].classifications[$g.classification] = [ordered]@{ groupId = $g.groupId; modelAllowList = $g.modelAllowList; personBudget = $g.personBudget; aggregateBudget = $g.aggregateBudget; aggregateMode = $g.aggregateMode; onboardingMode = $g.onboardingMode; tokenLimits = $g.tokenLimits }
    }
    $backends = @($P.backends | ForEach-Object { [ordered]@{ id = $_.id; backendId = $_.id; status = 'active'; apiFormat = 'anthropic-messages'; auth = [ordered]@{ mode = 'managed-identity'; resource = $_.resource } } })
    return @{ projects = @($projects.Values); backends = $backends }
}

function Invoke-QsSeed {
    param($Ctx)
    $docs = New-QsSeedDocuments -P $Ctx.P
    $file = Join-Path $Ctx.GeneratedDir 'seed-documents.json'
    $docs | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
    Write-Host "Seed documents written to $file ($($docs.projects.Count) projects, $($docs.backends.Count) backends)."
    throw 'seed_not_automated: this version writes the documents above but does not store them in Cosmos (public access is off; a later version stores them without a VM). Steps 6-8 do not depend on it: run them with -Only 6, -Only 7 and -Only 8. After the update, a run without -Only resumes here.'
}

function Show-QsGraphStep {
    param($Ctx)
    $sync = $Ctx.State.completed['3'].outputs.syncPrincipalId
    Write-Host 'Post-deployment, by a Privileged Role Administrator (PIM) or Global Administrator - not part of this run:'
    Write-Host "  pwsh -File infra/quickstart/Grant-SyncGraphPermissions.ps1 -SyncPrincipalId $sync"
    Write-Host 'Until then the sync cannot read the groups; or use sync.mode delegated-snapshot (docs/SYNC.md), which needs no application permission.'
    return @{ syncPrincipalId = $sync }
}

function Invoke-QsSmoke {
    param($Ctx)
    $url = "$($Ctx.State.completed['3'].outputs.gatewayUrl)/v1/messages"
    $status = [int](Invoke-WebRequest -Uri $url -Method Post -Body '{}' -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 30).StatusCode
    if ($status -ne 401) { throw "smoke_failed: the gateway answered $status without a token, not 401." }
    Write-Host "gateway without a token: 401. With a developer token: run scripts/client/Test-ClientGatewayAccess.ps1 after step 8 (expects 200)."
    return @{ withoutToken = $status }
}

function Invoke-QsClient {
    param($Ctx)
    $p = $Ctx.P; $r = $p.registrations
    $config = [ordered]@{
        schemaVersion = 1; tenantId = $p.tenantId; clientId = $r.developerSignIn.appId
        scope = "$($Ctx.State.completed['1'].outputs.gatewayIdentifierUri)/$($r.gatewayApi.scope)"; gatewayUrl = $Ctx.State.completed['3'].outputs.gatewayUrl
        helperTtlSeconds = 300; minimumTokenLifetimeSeconds = 360; loginTimeoutSeconds = 120; tokenTimeoutSeconds = 30; disableNonessentialTraffic = $true
        models = [ordered]@{ default = 'claude-sonnet-5'; opus = 'claude-opus-5'; sonnet = 'claude-sonnet-5'; haiku = 'claude-haiku-4-5'; available = @($p.backends[0].deploymentInferenceGeo.Keys) }
        desktop = [ordered]@{ profileId = [guid]::NewGuid().ToString(); profileName = 'Claude gateway (quick-start)' }
        project = [ordered]@{ id = $p.groups[0].projectId; selectorHeader = $p.gateway.projectHeaderName }
    }
    $file = Join-Path $Ctx.GeneratedDir 'client-config.json'
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
    $command = "pwsh -File scripts/client/Set-ClaudeCodeGateway.ps1 -ConfigPath $file -Confirmed"
    if ($ConfigureClient) { & (Join-Path $script:RepoRoot 'scripts/client/Set-ClaudeCodeGateway.ps1') -ConfigPath $file -Confirmed }
    else { Write-Host "Configure this machine: $command" }
    return @{ clientConfig = $file }
}

function Get-QsSteps {
    @(
        [pscustomobject]@{ Number = 1; Name = 'checks'; Action = { param($c) Test-QsPrerequisites $c } }
        [pscustomobject]@{ Number = 2; Name = 'build'; Action = { param($c) Invoke-QsBuild $c } }
        [pscustomobject]@{ Number = 3; Name = 'deploy'; Action = { param($c) Invoke-QsDeploy $c } }
        [pscustomobject]@{ Number = 4; Name = 'code'; Action = { param($c) Invoke-QsCode $c } }
        [pscustomobject]@{ Number = 5; Name = 'seed'; Action = { param($c) Invoke-QsSeed $c } }
        [pscustomobject]@{ Number = 6; Name = 'graph-permission'; Action = { param($c) Show-QsGraphStep $c } }
        [pscustomobject]@{ Number = 7; Name = 'smoke'; Action = { param($c) Invoke-QsSmoke $c } }
        [pscustomobject]@{ Number = 8; Name = 'client'; Action = { param($c) Invoke-QsClient $c } }
    )
}

if ($DotSourceOnly) { return }
$ErrorActionPreference = 'Stop'
$paramsFull = [System.IO.Path]::GetFullPath($ParametersPath)
$generated = Join-Path (Split-Path $paramsFull -Parent) '.generated'
New-Item -ItemType Directory -Path $generated -Force | Out-Null
$ctx = @{ ParametersPath = $paramsFull; ParametersText = (Get-Content -LiteralPath $paramsFull -Raw); P = (Read-QsParameters $paramsFull); GeneratedDir = $generated }
$statePath = Join-Path (Split-Path $paramsFull -Parent) '.env.quickstart.state.json'
$run = Invoke-QuickstartSteps -Steps (Get-QsSteps) -StatePath $statePath -Context $ctx -From $From -Only $Only
if ($run.Failed) { exit 1 }
Write-Host 'Quick-start steps completed.'
