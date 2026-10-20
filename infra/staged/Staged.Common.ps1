# Staged deployment: configuration, state, evidence and Azure/Graph helpers. Dot-sourced by Invoke-StagedDeployment.ps1; not run directly.

# ---------------------------------------------------------------- configuration and state

function Read-StgConfig {
    param([Parameter(Mandatory)] [string]$Path)
    $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    $c = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $problems = [Collections.Generic.List[string]]::new()
    if ($c.schemaVersion -ne 1) { $problems.Add('schemaVersion must be 1') }
    foreach ($k in 'tenantId', 'subscriptionId') { if ($c[$k] -notmatch $script:Guid) { $problems.Add("$k must be a GUID") } }
    if ($c.resourceGroup -notmatch '^[A-Za-z0-9_.-]{1,90}$') { $problems.Add('resourceGroup is invalid') }
    if ($c.stage1.prefix -cnotmatch '^[a-z0-9]{3,8}$') { $problems.Add('stage1.prefix must be 3-8 lowercase letters or digits') }
    if ($c.network.mode -notin 'create', 'existing') { $problems.Add('network.mode must be create or existing') }
    if (-not $c.cosmos.databaseName) { $problems.Add('cosmos.databaseName is required') }
    foreach ($b in @($c.backends)) { foreach ($k in 'id', 'subscriptionId', 'resourceGroup', 'accountName', 'url') { if (-not $b[$k]) { $problems.Add("backends[$($b.id)].$k is required") } } }
    foreach ($g in @($c.groups)) {
        if (-not $g.projectId -or -not $g.classification) { $problems.Add('every group needs projectId and classification') }
        if (-not $g.groupId -and -not $g.groupDisplayName) { $problems.Add("group $($g.projectId)/$($g.classification) needs groupId or groupDisplayName") }
    }
    if ($full -match '[&|<>^()]') { $problems.Add('config path holds a cmd.exe metacharacter') }
    # Entra names travel in Graph $filter URLs through az.cmd (cmd.exe): letters, digits, space . _ - only.
    $existingApps = $c.entra.existing ?? @{}
    $entraNames = @(
        $(if (-not $existingApps.gatewayAppId) { $c.entra.gatewayAppDisplayName })
        $(if (-not $existingApps.resolverAppId) { $c.entra.resolverAppDisplayName })
        $(if (-not $existingApps.adminAppId) { $c.entra.adminAppDisplayName })) + @($c.groups | Where-Object { -not $_.groupId } | ForEach-Object { $_.groupDisplayName })
    foreach ($k in 'gatewayAppId', 'resolverAppId', 'adminAppId') { if ($existingApps[$k] -and $existingApps[$k] -notmatch $script:Guid) { $problems.Add("entra.existing.$k must be a GUID") } }
    foreach ($n in @($entraNames | Where-Object { $_ })) { if ($n -notmatch '^[A-Za-z0-9 ._-]{1,120}$') { $problems.Add("Entra display name '$n' may hold only letters, digits, space . _ -") } }
    $fd = $c.stage1.foundry
    if ($fd -and $fd.create) {
        if ($fd.accountName -cnotmatch '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$') { $problems.Add('stage1.foundry.accountName must be 3-64 lowercase letters, digits or -') }
        if (-not @($fd.deployments).Count -and -not $fd.modelDeploymentsBlocked) { $problems.Add('stage1.foundry.deployments needs at least one model deployment (or modelDeploymentsBlocked with the reason)') }
        $mpd = $fd.modelProviderData
        if (@($fd.deployments).Count -and (-not $mpd -or -not $mpd.organizationName -or "$($mpd.organizationName)" -match '^REPLACE' -or "$($mpd.countryCode)" -cnotmatch '^[A-Z]{2}$' -or -not $mpd.industry)) {
            $problems.Add('stage1.foundry.modelProviderData { organizationName, countryCode (ISO 3166 alpha-2), industry } is required: it is the Anthropic attestation that accepts the Claude Marketplace offer for the real organization')
        }
    }
    if ($c.sharedResourceGroup -and $c.sharedResourceGroup -isnot [bool]) { $problems.Add('sharedResourceGroup must be true or false') }
    if ($problems.Count) { throw "invalid staged configuration:`n  - $($problems -join "`n  - ")" }
    $c.__path = $full
    return $c
}

function Get-StgStatePath { param($Cfg) Join-Path $script:StateDir 'state.json' }
function Get-StgTarget { param($Cfg) [ordered]@{ tenantId = "$($Cfg.tenantId)".ToLowerInvariant(); subscriptionId = "$($Cfg.subscriptionId)".ToLowerInvariant(); resourceGroup = "$($Cfg.resourceGroup)".ToLowerInvariant() } }
function Read-StgState { param($Cfg)
    $p = Get-StgStatePath $Cfg
    if (Test-Path -LiteralPath $p) {
        $state = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        # A state file belongs to one tenant/subscription/RG: outputs of another target are never reused.
        $t = Get-StgTarget $Cfg
        if ($state.target -and (($state.target.tenantId -ne $t.tenantId) -or ($state.target.subscriptionId -ne $t.subscriptionId) -or ($state.target.resourceGroup -ne $t.resourceGroup))) {
            throw "state_target_mismatch: $p belongs to $($state.target.tenantId)/$($state.target.subscriptionId)/$($state.target.resourceGroup), not this configuration's $($t.tenantId)/$($t.subscriptionId)/$($t.resourceGroup). Use -StateDirectory for each target."
        }
        return $state
    }
    return @{ schemaVersion = 1; target = (Get-StgTarget $Cfg); stages = @{} }
}
function Save-StgStage { param($Cfg, [int]$Number, $Outputs)
    $state = Read-StgState $Cfg
    $state.target = Get-StgTarget $Cfg
    $state.stages["$Number"] = @{ completedAt = [DateTime]::UtcNow.ToString('o'); outputs = $Outputs }
    $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Get-StgStatePath $Cfg) -Encoding utf8NoBOM
}
function Get-StgStage { param($Cfg, [int]$Number)
    $s = (Read-StgState $Cfg).stages["$Number"]
    if (-not $s) { throw "stage_order: stage $Number has not completed in $script:StateDir; run it with -Apply first." }
    return $s.outputs
}

function Write-StgEvidence { param([string]$Name, $Value)
    $dir = Join-Path $script:StateDir 'evidence'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir $Name
    if ($Value -is [string]) { $Value | Set-Content -LiteralPath $file -Encoding utf8NoBOM } else { $Value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $file -Encoding utf8NoBOM }
    return $file
}

# Names of the resources this deployment owns (Stage 1 outputs), for read-back in a shared RG.
function Get-StgOwnedNames { param($Cfg)
    $s1 = (Read-StgState $Cfg).stages['1'].outputs
    $n = $s1.names
    $list = @($n.logAnalyticsWorkspace, $n.cosmosAccount) + @($n.identities.Values) + @($n.apps.Values | ForEach-Object { $_.functionApp, $_.plan, $_.storageAccount, $_.appInsights })
    if ($s1.apimName) { $list += $s1.apimName }
    if ($Cfg.stage1.foundry.create) { $list += $Cfg.stage1.foundry.accountName }
    return @($list | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() })
}
function Test-StgOwnedScope { param([string]$Scope, [string[]]$Owned)
    $parts = $Scope.ToLowerInvariant() -split '/'
    return [bool](@($parts | Where-Object { $Owned -contains $_ }).Count)
}

function Assert-Stg { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw "verify_failed: $Message" } }

function Invoke-StgAzJson {
    # az with JSON output parsed, retried by Invoke-QsAz on transient token errors.
    param([string[]]$Arguments)
    $r = Invoke-QsAz ($Arguments + @('--output', 'json'))
    return $r
}

function Write-StgParameters {
    param($Cfg, [string]$Name, $Parameters)
    $doc = [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = [ordered]@{} }
    foreach ($k in $Parameters.Keys) { $doc.parameters[$k] = @{ value = $Parameters[$k] } }
    $file = Join-Path $script:StateDir "$Name.parameters.json"
    $doc | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
    return $file
}

function Invoke-StgBicep {
    <# what-if (preview) or create (apply) of one stage template; returns the outputs as a hashtable. #>
    param($Cfg, [string]$Template, [string]$Name, [hashtable]$Parameters, [switch]$Apply)
    $file = Write-StgParameters $Cfg $Name $Parameters
    $common = @('--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', $Name, '--template-file', (Join-Path $script:StagedDir $Template), '--parameters', "@$file")
    if (-not $Apply) {
        $raw = Invoke-QsAz (@('deployment', 'group', 'what-if') + $common + @('--no-pretty-print', '--output', 'json'))
        $changes = @($raw.changes | ForEach-Object { [ordered]@{ change = $_.changeType; id = $_.resourceId } })
        $null = Write-StgEvidence "$Name.what-if.json" $changes
        $byType = $changes | Group-Object { $_.change } | ForEach-Object { "$($_.Name)=$($_.Count)" }
        Write-Host "what-if $Name : $($byType -join ', ')"
        foreach ($c in $changes) { Write-Host ("  {0,-8} {1}" -f $c.change, ($c.id -replace '^/subscriptions/[^/]+/resourceGroups/', '')) }
        return $null
    }
    $started = [DateTime]::UtcNow
    $result = Invoke-QsAz (@('deployment', 'group', 'create', '--mode', 'Incremental') + $common + @('--output', 'json'))
    Assert-Stg ($result.properties.provisioningState -ceq 'Succeeded') "$Name provisioning state is $($result.properties.provisioningState)"
    $out = @{}; foreach ($k in $result.properties.outputs.Keys) { $out[$k] = $result.properties.outputs[$k].value }
    $null = Write-StgEvidence "$Name.deployment.json" ([ordered]@{ name = $Name; startedAt = $started.ToString('o'); completedAt = [DateTime]::UtcNow.ToString('o'); duration = $result.properties.duration; state = $result.properties.provisioningState; outputs = $out })
    Write-Host "deployed $Name ($($result.properties.duration))"
    return $out
}

function Get-StgSite {
    # az functionapp show returns Flex Consumption values under properties; other plans at the top level.
    param($Cfg, [string]$Name)
    $site = Invoke-StgAzJson @('functionapp', 'show', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', $Name)
    $pick = { param($k) if ($site.properties -and $null -ne $site.properties[$k]) { $site.properties[$k] } else { $site[$k] } }
    return @{ name = $site.name; publicNetworkAccess = (& $pick 'publicNetworkAccess'); virtualNetworkSubnetId = (& $pick 'virtualNetworkSubnetId') }
}

function Get-StgArm { param([string]$Path, [string]$ApiVersion) Invoke-QsAz @('rest', '--method', 'get', '--url', "https://management.azure.com$Path`?api-version=$ApiVersion") }
function Get-StgGraph { param([string]$Path) Invoke-QsAz @('rest', '--method', 'get', '--url', "https://graph.microsoft.com/v1.0/$Path") }
function Send-StgGraph {
    param([string]$Method, [string]$Path, $Body)
    $f = Join-Path $script:StateDir "graph-$([guid]::NewGuid().ToString('N')).json"
    try {
        $Body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $f -Encoding utf8NoBOM
        Invoke-QsAz @('rest', '--method', $Method, '--url', "https://graph.microsoft.com/v1.0/$Path", '--headers', 'Content-Type=application/json', '--body', "@$f")
    } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
}

# The quickstart parameter object (infra/quickstart/main.bicepparam shape) assembled from the config
# and the completed stages, so the quickstart's functions work unchanged.
function Get-StgQuickstartParameters {
    param($Cfg)
    $s1 = Get-StgStage $Cfg 1; $s5 = Get-StgStage $Cfg 5
    $names = $s1.names | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $names.cosmosDatabase = $Cfg.cosmos.databaseName
    $names.cosmosRoles = $Cfg.cosmos.roleNames
    $names.resourceGroupMode = 'existing'
    $groups = foreach ($g in $Cfg.groups) {
        $copy = $g | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $copy.groupId = $s5.groups["$($g.projectId)/$($g.classification)"].id
        $copy.Remove('groupDisplayName'); $copy.Remove('members')
        $copy
    }
    $rate = @{}; foreach ($k in $Cfg.rateCard.Keys) { $rate[$k] = Join-Path $script:Repo $Cfg.rateCard[$k] }
    return @{
        tenantId = $Cfg.tenantId; location = $Cfg.location; tags = $Cfg.tags; names = $names
        apim = (Get-StgApim $Cfg); network = $Cfg.network; groups = @($groups); client = $Cfg.client
        registrations = $s5.registrations; backends = @($Cfg.backends); cosmos = $Cfg.cosmos
        resolver = $Cfg.resolver; sync = $Cfg.sync; reconciler = $Cfg.reconciler; budgetState = $Cfg.budgetState
        gateway = $Cfg.gateway; rateCard = $rate; workbook = $Cfg.workbook; runner = @{ enabled = $false }
        logRetentionDays = $Cfg.stage1.retentionInDays
    }
}

function Get-StgApim {
    param($Cfg)
    $s1 = Get-StgStage $Cfg 1
    $base = if ($s1.apimName) { @{ name = $s1.apimName; subscriptionId = $Cfg.subscriptionId; resourceGroup = $Cfg.resourceGroup } }
            elseif ($Cfg.apim.existing) { @{ name = $Cfg.apim.existing.name; subscriptionId = $Cfg.apim.existing.subscriptionId; resourceGroup = $Cfg.apim.existing.resourceGroup } }
            else { throw 'apim_missing: Stage 1 deferred APIM and config apim.existing is empty.' }
    return $base + @{ apiId = $Cfg.apim.apiId; apiPath = $Cfg.apim.apiPath; apiDisplayName = $Cfg.apim.apiDisplayName }
}

function Get-StgApimIdentity {
    param($Cfg)
    $a = Get-StgApim $Cfg
    $apim = Get-StgArm "/subscriptions/$($a.subscriptionId)/resourceGroups/$($a.resourceGroup)/providers/Microsoft.ApiManagement/service/$($a.name)" '2024-05-01'
    $principal = [string]$apim.identity.principalId
    if ($principal -notmatch $script:Guid) { throw "apim_identity_missing: $($a.name) has no system-assigned identity." }
    return @{ id = $apim.id; principalId = $principal; gatewayUrl = $apim.properties.gatewayUrl; name = $a.name }
}
