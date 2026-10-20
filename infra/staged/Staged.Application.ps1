# Staged deployment: stages 6-8 (configuration, code and data, acceptance). Dot-sourced by Invoke-StagedDeployment.ps1; not run directly.

# ---------------------------------------------------------------- stage 6: configuration

function New-StgQsContext {
    # Adapter: the quickstart functions read $Ctx.P and the outputs of its steps 1 and 3.
    param($Cfg)
    $p = Get-StgQuickstartParameters $Cfg; $s1 = Get-StgStage $Cfg 1; $s5 = Get-StgStage $Cfg 5
    $apim = Get-StgApimIdentity $Cfg
    $gen = Join-Path $script:StateDir 'generated'; New-Item -ItemType Directory -Force -Path $gen | Out-Null
    $displayNames = @{}; foreach ($g in $s5.groups.Values) { $displayNames[$g.id] = $g.displayName }
    $gatewayUrl = "$($apim.gatewayUrl)/$($Cfg.apim.apiPath)"
    $state = @{ completed = @{
        '1' = @{ outputs = @{ apimId = $apim.id; apimPrincipalId = $apim.principalId; gatewayBaseUrl = $apim.gatewayUrl; gatewayIdentifierUri = $s5.gatewayIdentifierUri; classificationGroupDisplayNames = $displayNames } }
        '3' = @{ outputs = @{ cosmosEndpoint = $s1.cosmosEndpoint; gatewayUrl = $gatewayUrl; syncPrincipalId = $s1.principals.sync } } } }
    return @{ P = $p; GeneratedDir = $gen; State = $state; Apim = $apim; GatewayUrl = $gatewayUrl }
}

function Invoke-Stage6 {
    param($Cfg, [switch]$Apply)
    $s1 = Get-StgStage $Cfg 1; $null = Get-StgStage $Cfg 4; $s5 = Get-StgStage $Cfg 5
    $ctx = New-StgQsContext $Cfg
    $apimSp = Get-StgGraph "servicePrincipals/$($ctx.Apim.principalId)?`$select=appId"
    # Gateway policy (infra/gateway/render.ts) and workbook (analytics/workbooks/chargeback.ts).
    Push-Location $script:Repo
    try { npx tsc -p tsconfig.json | Out-Host; if ($LASTEXITCODE) { throw 'build_failed: npx tsc -p tsconfig.json' } } finally { Pop-Location }
    $config = New-QsGatewayConfig -P $ctx.P -Checks $ctx.State.completed['1'].outputs
    if ($s5.azureCliClientAllowed) { $config.entra.delegatedClientAppIds = @($config.entra.delegatedClientAppIds) + @($script:AzureCliClientId) }
    $configPath = Join-Path $ctx.GeneratedDir 'gateway-config.json'
    $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
    node (Join-Path $script:Repo 'infra/gateway/render.ts') --config $configPath --out (Join-Path $ctx.GeneratedDir 'gateway') | Out-Host
    if ($LASTEXITCODE) { throw 'render_failed: infra/gateway/render.ts refused the gateway configuration.' }
    $policy = Get-Content -LiteralPath (Join-Path $ctx.GeneratedDir "gateway/$($Cfg.apim.apiId).policy.xml") -Raw
    $answers = New-QsWorkbookAnswers -P $ctx.P -ApimId $ctx.Apim.id -Directory $ctx.GeneratedDir
    $groupsPath = Join-Path $ctx.GeneratedDir 'workbook.groups.json'
    @(Get-QsWorkbookGroups -P $ctx.P) | ConvertTo-Json -Depth 20 -AsArray | Set-Content -LiteralPath $groupsPath -Encoding utf8NoBOM
    $wb = Invoke-QsWorkbookBuild -AnswersPath $answers -GroupsPath $groupsPath -Directory $ctx.GeneratedDir
    $report = (Get-Content -LiteralPath $wb.parametersPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100).parameters
    $admin = @{ enabled = [bool]$Cfg.stage1.includeAdmin }
    if ($admin.enabled) {
        $admin += @{ uiClientId = $s5.admin.appId; editorIds = @(); readerIds = @(); v3Enabled = ($Cfg.admin.v3Enabled -ne $false); extraAllowedClientIds = @($Cfg.admin.extraAllowedClientIds | Where-Object { $_ -match $script:Guid })
            clientId = $s5.registrations.developerSignIn.appId; gatewayUrl = $ctx.GatewayUrl; projectHeader = $Cfg.gateway.projectHeaderName }
    }
    $params = @{
        tenantId = $Cfg.tenantId; location = $Cfg.location; names = $ctx.P.names; cosmosEndpoint = $s1.cosmosEndpoint
        syncClientId = $s1.clientIds.sync; reconcilerClientId = $s1.clientIds.reconciler
        apim = (Get-StgApim $Cfg); backends = @($Cfg.backends | ForEach-Object { @{ id = $_.id; url = $_.url } }); policyXml = $policy
        resolver = $Cfg.resolver; sync = $Cfg.sync; reconciler = $Cfg.reconciler; budgetState = $Cfg.budgetState
        syncTimerEnabled = [bool]$Cfg.syncTimerEnabled; resolverApiAppId = $s5.registrations.resolverApi.appId
        apimIdentityAppId = $apimSp.appId; apimPrincipalId = $ctx.Apim.principalId; admin = $admin
        workbook = $Cfg.workbook; workbookContent = $report.workbookContent.value; workbookContentTags = $report.contentTags.value
    }
    $out = Invoke-StgBicep -Cfg $Cfg -Template 'stage6-config.bicep' -Name 'stage6-config' -Apply:$Apply -Parameters $params
    if (-not $Apply) { return $null }
    $v = [ordered]@{ settings = [ordered]@{} }
    foreach ($k in @($s1.names.apps.Keys | Sort-Object)) {
        $names = @(Invoke-StgAzJson @('functionapp', 'config', 'appsettings', 'list', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', $s1.names.apps[$k].functionApp) | ForEach-Object { $_.name } | Sort-Object)
        Assert-Stg ($names.Count -ge 5) "$k has $($names.Count) settings"
        $v.settings[$k] = $names
    }
    $auth = Get-StgArm "/subscriptions/$($Cfg.subscriptionId)/resourceGroups/$($Cfg.resourceGroup)/providers/Microsoft.Web/sites/$($s1.names.apps.resolver.functionApp)/config/authsettingsV2/list" '2024-04-01'
    Assert-Stg ($auth.properties.platform.enabled -eq $true -and $auth.properties.globalValidation.unauthenticatedClientAction -ceq 'Return401') 'resolver authentication is not enforced'
    $v.resolverAuth = @{ enabled = $true; allowedApplications = @($auth.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications) }
    $a = Get-StgApim $Cfg
    $api = Get-StgArm "/subscriptions/$($a.subscriptionId)/resourceGroups/$($a.resourceGroup)/providers/Microsoft.ApiManagement/service/$($a.name)/apis/$($a.apiId)" '2024-05-01'
    Assert-Stg ($api.properties.path -ceq $a.apiPath) 'APIM API path differs'
    $v.api = @{ id = $a.apiId; path = $api.properties.path; policySha256 = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($policy))) -Algorithm SHA256).Hash }
    $v.timers = @{ sync = [bool]$Cfg.syncTimerEnabled; reconciler = [bool]$Cfg.reconciler.timerEnabled }
    $null = Write-StgEvidence 'stage6.verify.json' $v
    return @{ gatewayUrl = $out.gatewayUrl; settingsWritten = $out.settingsWritten; workbookDeployed = $out.workbookDeployed; apimIdentityAppId = $apimSp.appId; verify = $v }
}

# ---------------------------------------------------------------- stage 7: code and initial data

function Invoke-Stage7 {
    param($Cfg, [switch]$Apply)
    $s1 = Get-StgStage $Cfg 1; $null = Get-StgStage $Cfg 2; $null = Get-StgStage $Cfg 6; $s5 = Get-StgStage $Cfg 5
    $ctx = New-StgQsContext $Cfg
    $ctx.PollSeconds = 15
    $docs = New-QsSeedDocuments -P $ctx.P -ClassificationGroupDisplayNames $ctx.State.completed['1'].outputs.classificationGroupDisplayNames
    if (-not $Apply) {
        Write-Host "preview: publish resolver, sync, reconciler$(if ($Cfg.stage1.includeAdmin) { ', admin' }) packages (OneDeploy), wait for their functions"
        Write-Host "preview: seed $(@($docs.projects).Count) projects and $(@($docs.backends).Count) backends through the sync app's registrySeed function"
        Write-Host "preview: delegated snapshot of $(@($s5.groups.Values).Count) groups, applied through the sync app's snapshotApply function"
        Write-Host 'preview: write the client config.json for client.projectId/classification'
        return $null
    }
    $code = Invoke-QsCode $ctx
    $result = @{ code = $code }
    if ($Cfg.stage1.includeAdmin) {
        $zip = Join-Path $ctx.GeneratedDir 'admin.zip'
        & (Join-Path $script:Repo 'admin/Build-AdminPackage.ps1') -OutFile $zip | Out-Host
        if ($LASTEXITCODE) { throw 'admin_build_failed: admin/Build-AdminPackage.ps1' }
        $null = Invoke-QsAz @('functionapp', 'deployment', 'source', 'config-zip', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', $s1.names.apps.admin.functionApp, '--src', $zip)
        $want = 'projects', 'adminUi', 'adminHealth'
        $url = "/subscriptions/$($Cfg.subscriptionId)/resourceGroups/$($Cfg.resourceGroup)/providers/Microsoft.Web/sites/$($s1.names.apps.admin.functionApp)/functions"
        for ($i = 0; $i -lt 20; $i++) { $listed = @((Get-StgArm $url '2024-04-01').value | ForEach-Object { ([string]$_.name).Split('/')[-1] }); if (-not @($want | Where-Object { $listed -cnotcontains $_ }).Count) { break }; Start-Sleep 15 }
        Assert-Stg (-not @($want | Where-Object { $listed -cnotcontains $_ }).Count) "admin lists $($listed -join ',')"
        $result.admin = @{ sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash; functions = $listed }
    }
    # Invoke-QsSeed validates each projects document against onboarding's schema first; with the runner
    # off it seeds through the sync app's registrySeed function.
    $result.seed = Invoke-QsSeed $ctx
    # Delegated snapshot (docs/runbooks/CLOUD-SHELL-QUICKSTART.md section 5): the operator's own
    # Graph read through Azure CLI; no application permission.
    $groupsFile = Join-Path $ctx.GeneratedDir 'snapshot-groups.json'
    @{ groupIds = @($s5.groups.Values | ForEach-Object { $_.id }) } | ConvertTo-Json | Set-Content -LiteralPath $groupsFile -Encoding utf8NoBOM
    $settingsFile = Join-Path $ctx.GeneratedDir 'snapshot-settings.json'
    @{ SYNC_TENANT_ID = $Cfg.tenantId; SYNC_GRAPH_MAX_RETRIES = '3'; SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS = '30'; SYNC_GRAPH_TIMEOUT_SECONDS = '30' } | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding utf8NoBOM
    $snapshot = Join-Path $ctx.GeneratedDir '.env.sync-snapshot.json'
    $lines = @(& node (Join-Path $script:Repo 'dist/sync/cli.js') snapshot --credential azure-cli --groups $groupsFile --settings $settingsFile --out $snapshot 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE) { throw "snapshot_failed: $($lines -join ' ')" }
    $sha = @($lines | ForEach-Object { [regex]::Matches($_, '\b[0-9a-f]{64}\b') } | ForEach-Object { $_.Value }) | Select-Object -Last 1
    if (-not $sha) { throw "snapshot_hash_missing: the snapshot command printed no SHA-256: $($lines | Select-Object -Last 3)" }
    & (Join-Path $script:Repo 'infra/sync/Invoke-SnapshotApplyThroughFunction.ps1') -Subscription $Cfg.subscriptionId -ResourceGroup $Cfg.resourceGroup `
        -FunctionApp $s1.names.apps.sync.functionApp -AppInsights $s1.names.apps.sync.appInsights -SnapshotPath $snapshot -ExpectedSnapshotSha256 $sha | Out-Host
    if ($LASTEXITCODE) { throw 'snapshot_apply_failed: infra/sync/Invoke-SnapshotApplyThroughFunction.ps1' }
    $result.snapshot = @{ sha256 = $sha; groups = @($s5.groups.Keys) }
    $client = Invoke-QsClient $ctx
    $null = & node (Join-Path $script:Repo 'client/bin/validate-config.mjs') $client.clientConfig
    Assert-Stg ($LASTEXITCODE -eq 0) 'client config failed the client validator'
    $result.client = $client
    $null = Write-StgEvidence 'stage7.verify.json' $result
    return $result
}

# ---------------------------------------------------------------- stage 8: acceptance

function Invoke-StgGateway {
    param([string]$Url, [string]$Token, [string]$Project, [string]$Model)
    $headers = @{ 'anthropic-version' = '2023-06-01'; 'content-type' = 'application/json' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    if ($Project) { $headers['x-ccof-project'] = $Project }
    $body = @{ model = $Model; max_tokens = 24; messages = @(@{ role = 'user'; content = 'Reply with exactly: STAGED OK' }) } | ConvertTo-Json -Depth 5
    $r = Invoke-WebRequest -Uri "$Url/v1/messages" -Method Post -Headers $headers -Body $body -SkipHttpErrorCheck -TimeoutSec 90
    $ccof = [ordered]@{}; foreach ($h in $r.Headers.Keys) { if ($h -like 'x-ccof-*') { $ccof[$h] = "$($r.Headers[$h])" } }
    $text = $null; try { $j = $r.Content | ConvertFrom-Json; $text = if ($j.content) { $j.content[0].text } else { $j.error.type } } catch { }
    return [ordered]@{ status = [int]$r.StatusCode; project = $Project; model = $Model; result = $text; headers = $ccof }
}

function Invoke-Stage8 {
    param($Cfg, [switch]$Apply)
    $s1 = Get-StgStage $Cfg 1; $s6 = Get-StgStage $Cfg 6; $s5 = Get-StgStage $Cfg 5; $null = Get-StgStage $Cfg 7
    $t = $Cfg.acceptance
    if (-not $Apply) { Write-Host "preview: gateway $($s6.gatewayUrl): anonymous 401, $(@($t.allowed).Count) allowed and $(@($t.denied).Count) denied requests, resolver 401, admin console checks, telemetry query"; return $null }
    $checks = [ordered]@{}
    $checks.anonymous = Invoke-StgGateway -Url $s6.gatewayUrl -Project $t.allowed[0].project -Model $t.allowed[0].model
    Assert-Stg ($checks.anonymous.status -eq 401) "anonymous request answered $($checks.anonymous.status)"
    $resolverUrl = "https://$($s1.names.apps.resolver.functionApp).azurewebsites.net/api/resolve"
    $checks.resolverAnonymous = [int](Invoke-WebRequest -Uri $resolverUrl -Method Post -Body '{}' -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 60).StatusCode
    Assert-Stg ($checks.resolverAnonymous -eq 401) "resolver answered $($checks.resolverAnonymous) without the APIM identity"
    if (-not $s5.azureCliClientAllowed) { throw 'acceptance_needs_client: set entra.allowAzureCliClient (or run the client helper) to obtain a gateway token.' }
    $token = (Invoke-QsAz @('account', 'get-access-token', '--scope', "$($s5.gatewayIdentifierUri)/access_as_user", '--query', 'accessToken', '--output', 'tsv')).Trim()
    $checks.allowed = @(); $checks.denied = @()
    foreach ($c in $t.allowed) {
        $r = $null
        for ($i = 0; $i -lt 8; $i++) { $r = Invoke-StgGateway -Url $s6.gatewayUrl -Token $token -Project $c.project -Model $c.model; if ($r.status -eq 200) { break }; Start-Sleep 20 }
        $checks.allowed += $r
        Assert-Stg ($r.status -eq 200) "allowed request $($c.project)/$($c.model) answered $($r.status) $($r.result)"
    }
    foreach ($c in $t.denied) {
        $r = Invoke-StgGateway -Url $s6.gatewayUrl -Token $token -Project $c.project -Model $c.model
        $checks.denied += $r + @{ expected = $c.expectedStatus; reason = $c.reason }
        Assert-Stg ($r.status -eq [int]$c.expectedStatus) "denied request $($c.project)/$($c.model) answered $($r.status), expected $($c.expectedStatus)"
    }
    if ($Cfg.stage1.includeAdmin) {
        $adminHost = "https://$($s1.names.apps.admin.functionApp).azurewebsites.net"
        # Invoke-WebRequest -MaximumRedirection 0 throws on a redirect; read the 302 itself.
        $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler)
        try { $resp = $client.GetAsync("$adminHost/").GetAwaiter().GetResult(); $root = @{ StatusCode = [int]$resp.StatusCode; Headers = @{ Location = "$($resp.Headers.Location)" } } }
        finally { $client.Dispose() }
        $console = Invoke-WebRequest -Uri "$adminHost/api/console-v3" -SkipHttpErrorCheck -TimeoutSec 60
        $api = Invoke-WebRequest -Uri "$adminHost/api/v3/version" -SkipHttpErrorCheck -TimeoutSec 60
        $checks.admin = [ordered]@{ rootStatus = [int]$root.StatusCode; rootLocation = "$($root.Headers.Location)"; consoleStatus = [int]$console.StatusCode; apiWithoutToken = [int]$api.StatusCode }
        Assert-Stg ($checks.admin.rootStatus -in 301, 302 -and $checks.admin.rootLocation -like '*console-v3*') "admin root answered $($checks.admin.rootStatus) $($checks.admin.rootLocation)"
        Assert-Stg ($checks.admin.consoleStatus -eq 200) "admin console answered $($checks.admin.consoleStatus)"
        Assert-Stg ($checks.admin.apiWithoutToken -eq 401) "admin API answered $($checks.admin.apiWithoutToken) without a token"
    }
    # Telemetry: gateway LLM logs reach the workspace (ingestion takes minutes; up to 15 minutes here).
    # The query holds | : sent over REST, never as an az.cmd argument.
    $q = 'ApiManagementGatewayLlmLog | where TimeGenerated > ago(2h) | summarize rows=count(), requests=dcount(CorrelationId)'
    $laToken = (Invoke-QsAz @('account', 'get-access-token', '--resource', 'https://api.loganalytics.io', '--query', 'accessToken', '--output', 'tsv')).Trim()
    $rows = @()
    for ($i = 0; $i -lt 30; $i++) {
        $resp = Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.io/v1/workspaces/$($s1.workspaceCustomerId)/query" -Headers @{ Authorization = "Bearer $laToken" } -ContentType 'application/json' -Body (@{ query = $q } | ConvertTo-Json)
        $table = $resp.tables[0]
        $rows = @($table.rows | ForEach-Object { $r = $_; $o = [ordered]@{}; for ($c = 0; $c -lt $table.columns.Count; $c++) { $o[$table.columns[$c].name] = $r[$c] }; $o })
        if ($rows.Count -and [int]$rows[0].requests -ge @($t.allowed).Count) { break }
        Start-Sleep 30
    }
    $checks.telemetry = @{ query = $q; rows = $rows }
    Assert-Stg ($rows.Count -and [int]$rows[0].requests -ge 1) 'no gateway LLM log rows reached the workspace within 15 minutes'
    $null = Write-StgEvidence 'stage8.verify.json' $checks
    return $checks
}
