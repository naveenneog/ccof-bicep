#Requires -Version 7.0
<#
.SYNOPSIS
    Quick-start for one administrator (ADR-0024, Proposed; docs/QUICKSTART.md): numbered, rerunnable
    steps around infra/quickstart/main.bicep. Phase 2 of three: the Entra prerequisites come before
    (an Entra administrator), the Graph application permissions after (Grant-SyncGraphPermissions.ps1,
    a Privileged Role Administrator). This script never creates or changes an Entra object.

.DESCRIPTION
    Steps: 1 checks (read-only), 2 build, 3 Bicep deployment, 4 code, 5 seed documents (through the
    sync app's registrySeed function, or the runner VM when runner.enabled is true), 6 Graph
    permission (prints the post-deployment command), 7 smoke, 8 client.
    State: .env.quickstart.state.json next to the parameters file (git-ignored). A rerun resumes at
    the first step not completed; -From <n> restarts there; -Only <n> runs one step.
    -WhatIfOnly makes step 3 run `az deployment group what-if` and stop. The same script runs in
    Azure Cloud Shell (Linux) and on Windows; a relative -ParametersPath is resolved against the
    current PowerShell location.
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
$script:QsDirectory = $PSScriptRoot
# D2's packaging (step 4) and onboarding Stage 3's project schema (step 5).
Import-Module (Join-Path $script:RepoRoot 'scripts/Core.D2Code.psm1') -DisableNameChecking
Import-Module (Join-Path $script:RepoRoot 'scripts/Onboarding.Projects.psm1') -DisableNameChecking

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

function Resolve-QsParametersPath {
    <#
    .SYNOPSIS
        The full path of -ParametersPath. A relative path is resolved against the PowerShell location
        ($PWD, which cd changes in Azure Cloud Shell as on Windows), never against the process working
        directory that [System.IO.Path]::GetFullPath would use for it.
    #>
    param([Parameter(Mandatory)] [string]$Path)
    return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
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
    $warnings = [System.Collections.Generic.List[string]]::new()
    # "Allow public client flows" is needed only by the device code flow (ccof-token login
    # --device-code); WAM and the browser sign-in use the app's public-client redirect URIs
    # (docs/CLIENTS.md). So it is a warning and the deployment goes on.
    if (-not $dev) { $problems.Add('developer_sign_in_missing: no application with registrations.developerSignIn.appId') }
    elseif (-not $dev.isFallbackPublicClient) { $warnings.Add('developer_sign_in_not_public: "Allow public client flows" is off on the Developer Sign-in app, so `ccof-token login --device-code` will fail; WAM and browser sign-in are unaffected. An Entra administrator turns it on (docs/QUICKSTART-PREREQUISITES.md).') }
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
    foreach ($w in $warnings) { Write-Host "WARNING: $w" -ForegroundColor Yellow }
    Write-Host 'Azure roles: Deploy needs Owner, or Contributor plus Role Based Access Control Administrator, on the resource group and on each backend account (docs/QUICKSTART.md, phase 2); ARM refuses the deployment otherwise (AuthorizationFailed).'
    return @{ apimId = $apimId; apimPrincipalId = $principalId; apimIdentityAppId = $apimAppId; gatewayBaseUrl = $apim.properties.gatewayUrl; gatewayIdentifierUri = @($gw.identifierUris)[0]; warnings = @($warnings) }
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
    $rg = $p.names.resourceGroup; $sub = $p.names.subscriptionId
    if (-not $WhatIfOnly -and $p.names.resourceGroupMode -eq 'create') { $null = Invoke-QsAz @('group', 'create', '--subscription', $sub, '--name', $rg, '--location', $p.location) }
    $verb = if ($WhatIfOnly) { 'what-if' } else { 'create' }
    $template = Join-Path $PSScriptRoot 'main.bicep'
    $result = Invoke-QsAz @('deployment', 'group', $verb, '--subscription', $sub, '--resource-group', $rg, '--name', "$($p.names.deploymentPrefix)-quickstart", '--template-file', $template, '--parameters', "@$file")
    if ($WhatIfOnly) { Write-Host $result; throw 'what_if_only: what-if printed; no deployment was made (rerun without -WhatIfOnly).' }
    $outputs = @{}; foreach ($k in $result.properties.outputs.Keys) { $outputs[$k] = $result.properties.outputs[$k].value }
    return $outputs
}

function Invoke-QsNpmCi {
    <# Production dependencies of one staged package, from its lock file. #>
    param([string]$Directory, [string]$App)
    Push-Location $Directory
    try { npm ci --omit=dev --no-audit --no-fund --quiet | Out-Null; if ($LASTEXITCODE -ne 0) { throw "npm_ci_failed_${App}: npm ci --omit=dev failed in $Directory." } }
    finally { Pop-Location }
}

function Invoke-QsCode {
    <#
    .SYNOPSIS
        Step 4: each app's package as D2's code step builds it (scripts/Core.D2Code.psm1: the files its
        entry point reaches, host.json, rate card and contract schedule for the reconciler, production
        dependencies, a zip with "/" names), deployed with OneDeploy (az functionapp deployment source
        config-zip; Flex Consumption deploys only this way, U-14). Then waits until each app lists its
        functions.
    #>
    param($Ctx)
    $p = $Ctx.P; $stage = Join-Path $Ctx.GeneratedDir 'packages'
    $sub = $p.names.subscriptionId; $rg = $p.names.resourceGroup
    $answers = @{ rateCard = $p.rateCard }
    $digests = [ordered]@{}
    foreach ($app in @('resolver', 'sync', 'reconciler')) {
        $pkg = New-CoreAppPackage -RepositoryRoot $script:RepoRoot -App $app -Answers $answers -AnswersDirectory $script:QsDirectory -StageRoot $stage
        if ($pkg.Missing.Count) { throw "package_files_missing for ${app}: $($pkg.Missing -join ', ') (run step 2, which builds dist/)." }
        Invoke-QsNpmCi -Directory $pkg.Directory -App $app
        $zip = Join-Path $stage "$app.zip"; New-CoreZip -Directory $pkg.Directory -ZipPath $zip
        Write-Host "Deploying the $app package to $($p.names.apps[$app].functionApp) (OneDeploy)."
        $null = Invoke-QsAz @('functionapp', 'deployment', 'source', 'config-zip', '--subscription', $sub, '--resource-group', $rg, '--name', $p.names.apps[$app].functionApp, '--src', $zip)
        $digests[$app] = $pkg.Digest
    }
    $expected = [ordered]@{ resolver = @('resolve', 'health'); sync = @('syncEntitlement'); reconciler = @('reconcileBudgets') }
    $listed = [ordered]@{}
    foreach ($app in $expected.Keys) {
        $url = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$($p.names.apps[$app].functionApp)/functions?api-version=2024-04-01"
        $names = @()
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            $names = @(@((Invoke-QsAz @('rest', '--method', 'get', '--url', $url)).value) | ForEach-Object { ([string]$_.name).Split('/')[-1] })
            if (@($expected[$app] | Where-Object { $names -cnotcontains $_ }).Count -eq 0) { break }
            if ($attempt -lt 20) { Start-Sleep -Seconds $(if ($Ctx.PollSeconds -is [int]) { $Ctx.PollSeconds } else { 15 }) }
        }
        $absent = @($expected[$app] | Where-Object { $names -cnotcontains $_ })
        if ($absent.Count) { throw "functions_not_listed: $($p.names.apps[$app].functionApp) lists $(if ($names.Count) { $names -join ', ' } else { 'no function' }), not $($absent -join ', '), five minutes after the deployment." }
        $listed[$app] = $names
    }
    return @{ deployed = @($digests.Keys); digests = $digests; functions = $listed }
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

function New-QsSeedEntries {
    <# The documents with the container and partition key value each one goes to (partition keys: /projectId, /backendId). #>
    param([Parameter(Mandatory)] $Documents)
    @(@($Documents.projects) | ForEach-Object { [ordered]@{ container = 'projects'; partitionKey = $_.projectId; document = $_ } }) +
    @(@($Documents.backends) | ForEach-Object { [ordered]@{ container = 'backends'; partitionKey = $_.backendId; document = $_ } })
}

function New-QsSeedScript {
    <#
    .SYNOPSIS
        The Run Command script of step 5: bash that writes infra/quickstart/runner/seed-cosmos.py and
        the entries from base64 blocks into a private work folder, runs them with the image's python3
        and removes the folder. The endpoint and database are checked here, so no quote or shell
        character reaches the script.
    #>
    param([Parameter(Mandatory)] [object[]]$Entries, [Parameter(Mandatory)] [string]$Endpoint, [Parameter(Mandatory)] [string]$Database)
    if ($Endpoint -cnotmatch '^https://[a-z0-9][a-z0-9-]{1,48}[a-z0-9]\.documents\.azure\.com(:443)?/?$') { throw "seed_endpoint_invalid: '$Endpoint' is not a Cosmos DB account endpoint (https://<account>.documents.azure.com:443/)." }
    if ($Database -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,254}$') { throw 'seed_database_invalid: names.cosmosDatabase may hold letters, digits, _ and - only.' }
    $python = (Get-Content -LiteralPath (Join-Path $script:QsDirectory 'runner/seed-cosmos.py') -Raw).Replace("`r`n", "`n")
    $json = ConvertTo-Json -InputObject @($Entries) -Depth 30 -Compress
    $block = { param([string]$Text) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text), [Base64FormattingOptions]::InsertLineBreaks).Replace("`r`n", "`n") }
    $lines = @(
        '#!/bin/bash'
        'set -euo pipefail'
        'umask 077'
        'WORK=/var/lib/ccof-qs-seed'
        'rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"'
        "trap 'cd /; rm -rf `"`$WORK`"' EXIT"
        'if ! command -v python3 >/dev/null 2>&1; then echo ''CCOF_SEED_DONE {"ok":false,"reason":"python3_missing"}''; exit 5; fi'
        "base64 -d > seed-cosmos.py <<'CCOF_B64'"
        (& $block $python)
        'CCOF_B64'
        "base64 -d > documents.json <<'CCOF_B64'"
        (& $block $json)
        'CCOF_B64'
        "python3 seed-cosmos.py '$Endpoint' '$Database' documents.json"
    )
    return ($lines -join "`n") + "`n"
}

function Invoke-QsRunCommand {
    <# Runs a bash script on the private runner (action Run Command) and returns its output message (the last 4,096 bytes). #>
    param([Parameter(Mandatory)] $P, [Parameter(Mandatory)] [string]$Script, [Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [string]$GeneratedDir)
    $file = Join-Path $GeneratedDir "runner-$Name.sh"
    [IO.File]::WriteAllText($file, $Script.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    try {
        $result = Invoke-QsAz @('vm', 'run-command', 'invoke', '--subscription', $P.names.subscriptionId, '--resource-group', $P.names.resourceGroup, '--name', $P.names.runnerVm, '--command-id', 'RunShellScript', '--scripts', "@$file", '--output', 'json')
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    return [string](@($result.value)[0].message)
}

function ConvertFrom-QsSeedOutput {
    <# The CCOF_SEED lines and the CCOF_SEED_DONE line of the runner's output. #>
    param([string]$Message)
    $items = [System.Collections.Generic.List[object]]::new(); $done = $null
    foreach ($line in @(([string]$Message) -split "`r?`n")) {
        if ($line.StartsWith('CCOF_SEED_DONE ')) { $done = try { $line.Substring(15) | ConvertFrom-Json -AsHashtable } catch { $null } }
        elseif ($line.StartsWith('CCOF_SEED ')) { $item = try { $line.Substring(10) | ConvertFrom-Json -AsHashtable } catch { $null }; if ($item) { $items.Add($item) } }
    }
    [pscustomobject]@{ Items = $items.ToArray(); Done = $done }
}

function New-QsSeedPayload {
    <#
    .SYNOPSIS
        The CCOF_SEED_DOCUMENTS value the sync app's registrySeed function reads
        (src/sync/registry-seed.ts): base64 of the UTF-8 JSON { seedId, projects, backends }. Base64
        holds only letters, digits, + / and =, so it passes Invoke-QsAz's metacharacter guard.
    #>
    param([Parameter(Mandatory)] $Documents, [Parameter(Mandatory)] [string]$SeedId)
    $json = [ordered]@{ seedId = $SeedId; projects = @($Documents.projects); backends = @($Documents.backends) } | ConvertTo-Json -Depth 30 -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function Get-QsSeedResultLines {
    <#
    .SYNOPSIS
        The registrySeed result lines of one seed (schema ccof.seed.result.v1, this seedId) in the sync
        app's Application Insights, oldest first. Query - Execute of the Application Insights REST API:
        POST https://api.applicationinsights.io/v1/apps/{appId}/query with { query, timespan } and an
        Entra token for the resource https://api.applicationinsights.io (Learn, "Query - Execute" and
        "Microsoft Entra authentication for Application Insights", Query section, retrieved
        2026-10-13). The query travels in a JSON body, so no quote passes through a shell. A 400, 401,
        403 or 404 answer throws seed_query_failed; any other error is the caller's to retry.
    #>
    param([Parameter(Mandatory)] [string]$AppId, [Parameter(Mandatory)] [string]$SeedId, [Parameter(Mandatory)] [string]$Token, [scriptblock]$InvokeRest)
    if ($SeedId -cnotmatch '^[0-9a-f]{32}$') { throw "seed_id_invalid: '$SeedId'" }
    $query = "traces | where timestamp > ago(1h) | where message has '$SeedId' and message contains 'ccof.seed.result' | project timestamp, message | order by timestamp asc | take 50"
    $body = @{ query = $query; timespan = 'PT1H' } | ConvertTo-Json -Compress
    $uri = "https://api.applicationinsights.io/v1/apps/$AppId/query"
    $invoke = if ($InvokeRest) { $InvokeRest } else { { param($Uri, $Body, $Token) Invoke-RestMethod -Method Post -Uri $Uri -Body $Body -ContentType 'application/json' -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 60 } }
    try { $response = & $invoke $uri $body $Token }
    catch {
        $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($status -in 400, 401, 403, 404) { throw "seed_query_failed: Application Insights answered HTTP $status to the query of app $AppId; the deployer needs read access to the sync app's Application Insights (Reader on the resource group is enough)." }
        throw
    }
    $table = @($response.tables)[0]
    $column = [array]::IndexOf(@($table.columns | ForEach-Object { [string]$_.name }), 'message')
    if ($column -lt 0) { return }
    foreach ($row in @($table.rows)) {
        $line = try { [string]@($row)[$column] | ConvertFrom-Json -AsHashtable -Depth 20 } catch { $null }
        if ($line -is [System.Collections.IDictionary] -and $line.schema -ceq 'ccof.seed.result.v1' -and $line.seedId -ceq $SeedId) { $line }
    }
}

function Wait-QsSeedResult {
    <#
    .SYNOPSIS
        Polls for the result line of this seed: every PollSeconds (20) for SeedPollAttempts (30) polls,
        10 minutes, with a fresh token each time (az account get-access-token --resource
        https://api.applicationinsights.io; Learn, az account get-access-token, retrieved 2026-10-13).
        A run with a failed document is retried by the function's next run a minute later, so a later
        line counts; the last line is returned once it has no failed document, or after three runs.
    #>
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] [string]$AppId, [Parameter(Mandatory)] [string]$SeedId)
    $attempts = if ($Ctx.SeedPollAttempts -is [int]) { $Ctx.SeedPollAttempts } else { 30 }
    $pause = if ($Ctx.PollSeconds -is [int]) { $Ctx.PollSeconds } else { 20 }
    $latest = $null; $lastError = $null
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $token = [string](Invoke-QsAz @('account', 'get-access-token', '--resource', 'https://api.applicationinsights.io')).accessToken
        $lines = @()
        try { $lines = @(Get-QsSeedResultLines -AppId $AppId -SeedId $SeedId -Token $token -InvokeRest $Ctx.InvokeRest); $lastError = $null }
        catch {
            if ($_.Exception.Message -like 'seed_query_failed*') { throw }
            $lastError = $_.Exception.Message
        }
        if ($lines.Count) {
            $latest = $lines[-1]
            if ($latest.outcome -cne 'failed' -or $lines.Count -ge 3) { return $latest }
        }
        if ($attempt -lt $attempts) { Start-Sleep -Seconds $pause }
    }
    if ($latest) { return $latest }
    throw "seed_result_timeout: no ccof.seed.result line for seed $SeedId in the sync app's Application Insights after $attempts polls $pause seconds apart$(if ($lastError) { " (last query error: $lastError)" }). The function runs every minute once the app has restarted with the new settings; look at the sync app's registrySeed function and its logs, then run this step again: it is safe to rerun (create only)."
}

function Write-QsSeedOutcomes {
    param($Result)
    foreach ($d in @($Result.documents)) {
        $detail = if ($d.fields) { " ($(@($d.fields) -join ', '))" } elseif ($d.code) { " ($($d.code)$(if ($d.problems) { ': ' + (@($d.problems) -join ', ') }))" } else { '' }
        Write-Host "  $($d.container)/$($d.id): $($d.outcome)$detail"
    }
}

function Invoke-QsSeedThroughFunction {
    <#
    .SYNOPSIS
        Step 5 without the runner VM (runner.enabled false, the default; a tenant whose policy denies
        marketplace VM images has no VM inside the VNet): the sync app's registrySeed function
        (src/sync/registry-seed.ts) creates the documents with the sync identity's create-only role
        (ADR-0024, D-7). Sets CCOF_SEED_DOCUMENTS and AzureWebJobs.registrySeed.Disabled=false on the
        sync app (one restart), asks for a trigger sync (Learn, "Deployment technologies in Azure
        Functions", Trigger syncing, retrieved 2026-10-13), polls the app's Application Insights for
        the function's line with this seedId (up to 10 minutes), prints each document's outcome, and
        then always sets AzureWebJobs.registrySeed.Disabled=true and deletes CCOF_SEED_DOCUMENTS.
        present-differs, failed, a refusal or a missing document fails the step by name; a rerun is
        safe (create only).
    #>
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] $Documents)
    $p = $Ctx.P; $sub = $p.names.subscriptionId; $rg = $p.names.resourceGroup; $app = $p.names.apps.sync.functionApp
    $entries = @(New-QsSeedEntries -Documents $Documents)
    $seedId = [guid]::NewGuid().ToString('N')
    $payload = New-QsSeedPayload -Documents $Documents -SeedId $seedId
    # cmd.exe, which runs az.cmd on Windows, takes at most 8,191 characters per command line; Linux takes
    # 128 KiB per argument. The function refuses more than 96 KiB.
    $limit = if ($Ctx.SeedSettingLimit -is [int]) { $Ctx.SeedSettingLimit } elseif ($IsWindows) { 7000 } else { 98304 }
    if ($payload.Length -gt $limit) { throw "seed_documents_too_large: the seed documents take $($payload.Length) characters in base64, more than the $limit this platform's az command line takes. Run the quick-start from Azure Cloud Shell, or seed fewer groups." }
    $component = Invoke-QsAz @('rest', '--method', 'get', '--url', "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Insights/components/$($p.names.apps.sync.appInsights)?api-version=2020-02-02")
    $appId = [string]$component.properties.AppId
    if ($appId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw "seed_app_insights_missing: $($p.names.apps.sync.appInsights) has no Application Insights app id (properties.AppId); step 3 creates it." }
    $settings = @('functionapp', 'config', 'appsettings')
    $target = @('--subscription', $sub, '--resource-group', $rg, '--name', $app)
    Write-Host "Seeding $($entries.Count) documents through the sync app's registrySeed function (seed $seedId; up to 10 minutes)."
    $result = $null; $failure = $null; $cleanup = [System.Collections.Generic.List[string]]::new()
    try {
        $null = Invoke-QsAz ($settings + @('set') + $target + @('--settings', "CCOF_SEED_DOCUMENTS=$payload", 'AzureWebJobs.registrySeed.Disabled=false', '--output', 'none'))
        try { $null = Invoke-QsAz @('rest', '--method', 'post', '--url', "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$app/syncfunctiontriggers?api-version=2024-04-01") }
        catch { Write-Host "WARNING: the trigger sync failed ($($_.Exception.Message)); the app's own sync after its restart has to do." -ForegroundColor Yellow }
        $result = Wait-QsSeedResult -Ctx $Ctx -AppId $appId -SeedId $seedId
        Write-QsSeedOutcomes $result
    }
    catch { $failure = $_.Exception.Message }
    finally {
        try { $null = Invoke-QsAz ($settings + @('set') + $target + @('--settings', 'AzureWebJobs.registrySeed.Disabled=true', '--output', 'none')) }
        catch { $cleanup.Add("az functionapp config appsettings set --subscription $sub --resource-group $rg --name $app --settings AzureWebJobs.registrySeed.Disabled=true") }
        try { $null = Invoke-QsAz ($settings + @('delete') + $target + @('--setting-names', 'CCOF_SEED_DOCUMENTS', '--output', 'none')) }
        catch { $cleanup.Add("az functionapp config appsettings delete --subscription $sub --resource-group $rg --name $app --setting-names CCOF_SEED_DOCUMENTS") }
    }
    $cleanupText = if ($cleanup.Count) { "seed_cleanup_failed: the seed settings are still on the sync app; run: $($cleanup -join '; then ') (or run this step again)." } else { $null }
    if ($failure) { throw "$failure$(if ($cleanupText) { " Also $cleanupText" })" }
    if ($cleanupText) { throw $cleanupText }
    if ($result.outcome -ceq 'refused') { throw "seed_refused: the registrySeed function refused the documents ($($result.reason)$(if ($result.problems) { ': ' + (@($result.problems) -join ', ') })) and wrote nothing." }
    $differs = @($result.documents | Where-Object { $_.outcome -ceq 'present-differs' })
    if ($differs.Count) { throw "seed_documents_differ: these existing documents differ from the parameters and were left unchanged: $(@($differs | ForEach-Object { "$($_.container)/$($_.id) ($(@($_.fields) -join ', '))" }) -join '; '). The sync identity may create but not replace (ADR-0024, D-7): change them through onboarding, or correct the parameters." }
    $failed = @($result.documents | Where-Object { $_.outcome -cnotin @('created', 'present-equal') })
    if ($failed.Count) { throw "seed_failed: $(@($failed | ForEach-Object { "$($_.container)/$($_.id) ($($_.code))" }) -join '; '). A create_http_403 means the sync identity's Cosmos role (step 3) is missing or still applying: run this step again." }
    $missing = @($entries | Where-Object { $e = $_; -not @($result.documents | Where-Object { $_.container -ceq $e.container -and $_.id -ceq $e.document.id }).Count })
    if ($missing.Count) { throw "seed_incomplete: the function's line has no outcome for $(@($missing | ForEach-Object { "$($_.container)/$($_.document.id)" }) -join ', ')." }
    return @{ mechanism = 'registrySeed'; seedId = $seedId; documents = @($result.documents | ForEach-Object { "$($_.container)/$($_.id): $($_.outcome)" }) }
}

function Invoke-QsSeed {
    <#
    .SYNOPSIS
        Step 5: creates the projects and backends documents (Cosmos public access is off). Without
        the runner VM (runner.enabled false, the default), the sync app's registrySeed function does it
        with the sync identity (Invoke-QsSeedThroughFunction). With the runner, the runner does it
        through Run Command with its managed identity, reads each back and compares it. Create only,
        as both roles allow (ADR-0024, D-7): a rerun finds them present; a document that differs is
        named and never overwritten.
    #>
    param($Ctx)
    $p = $Ctx.P
    $docs = New-QsSeedDocuments -P $p
    foreach ($project in @($docs.projects)) {
        try { $null = ConvertTo-OnboardingProjectDocument -Project ($project | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable) }
        catch { throw "seed_document_invalid: the projects document $($project.id) built from the groups parameter fails onboarding Stage 3's schema: $($_.Exception.Message)" }
    }
    if (-not $p.runner.enabled) { return Invoke-QsSeedThroughFunction -Ctx $Ctx -Documents $docs }
    $entries = @(New-QsSeedEntries -Documents $docs)
    $script = New-QsSeedScript -Entries $entries -Endpoint ([string]$Ctx.State.completed['3'].outputs.cosmosEndpoint) -Database $p.names.cosmosDatabase
    $run = if ($Ctx.RunCommand) { $Ctx.RunCommand } else { ${function:Invoke-QsRunCommand} }
    Write-Host "Seeding $($entries.Count) documents through the runner $($p.names.runnerVm) (Run Command; a few minutes)."
    $message = & $run $p $script 'seed' $Ctx.GeneratedDir
    $result = ConvertFrom-QsSeedOutput $message
    foreach ($item in $result.Items) { Write-Host "  $($item.container)/$($item.id): $($item.outcome)$(if ($item.fields) { " ($(@($item.fields) -join ', '))" })$(if ($item.outcome -eq 'failed') { " at $($item.step), HTTP $($item.status)" })" }
    if (-not $result.Done) { throw "seed_no_result: the runner printed no CCOF_SEED_DONE line. Its output ends: $(([string]$message).Trim() -split "`n" | Select-Object -Last 5)" }
    $differs = @($result.Items | Where-Object { $_.outcome -eq 'differs' })
    if ($differs.Count) { throw "seed_documents_differ: these existing documents differ from the parameters and were left unchanged: $(@($differs | ForEach-Object { "$($_.container)/$($_.id) ($(@($_.fields) -join ', '))" }) -join '; '). The runner may create but not replace (ADR-0024, D-7): change them through onboarding, or correct the parameters." }
    $failed = @($result.Items | Where-Object { $_.outcome -notin @('created', 'present') })
    if ($failed.Count -or -not $result.Done.ok) { throw "seed_failed: $(@($failed | ForEach-Object { "$($_.container)/$($_.id) at $($_.step), HTTP $($_.status)" }) -join '; '). A 403 means the runner's Cosmos role (step 3) is missing or still applying: run this step again." }
    $missing = @($entries | Where-Object { $e = $_; -not @($result.Items | Where-Object { $_.container -ceq $e.container -and $_.id -ceq $e.document.id }).Count })
    if ($missing.Count) { throw "seed_incomplete: no result for $(@($missing | ForEach-Object { "$($_.container)/$($_.document.id)" }) -join ', ')." }
    return @{ documents = @($result.Items | ForEach-Object { "$($_.container)/$($_.id): $($_.outcome)" }) }
}

function Show-QsGraphStep {
    param($Ctx)
    $sync = $Ctx.State.completed['3'].outputs.syncPrincipalId
    Write-Host 'Post-deployment, by a Privileged Role Administrator (PIM) or Global Administrator - not part of this run:'
    Write-Host "  pwsh -File infra/quickstart/Grant-SyncGraphPermissions.ps1 -SyncPrincipalId $sync"
    Write-Host '  then set syncTimerEnabled = true in the parameters file and run: pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -Only 3'
    Write-Host '  (-Only 3 redeploys the template alone, which writes the sync timer setting; the code and the seed stay as they are).'
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
$paramsFull = Resolve-QsParametersPath $ParametersPath
$generated = Join-Path (Split-Path $paramsFull -Parent) '.generated'
New-Item -ItemType Directory -Path $generated -Force | Out-Null
$ctx = @{ ParametersPath = $paramsFull; ParametersText = (Get-Content -LiteralPath $paramsFull -Raw); P = (Read-QsParameters $paramsFull); GeneratedDir = $generated }
$statePath = Join-Path (Split-Path $paramsFull -Parent) '.env.quickstart.state.json'
$run = Invoke-QuickstartSteps -Steps (Get-QsSteps) -StatePath $statePath -Context $ctx -From $From -Only $Only
if ($run.Failed) { exit 1 }
Write-Host 'Quick-start steps completed.'
