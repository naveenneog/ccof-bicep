# Staged deployment: configuration, state, evidence and Azure/Graph helpers. Dot-sourced by Invoke-StagedDeployment.ps1; not run directly.

# ---------------------------------------------------------------- configuration and state

function Get-StgCoverageStartAtFromJson {
    param([Parameter(Mandatory)] [string]$Json)
    $document = [System.Text.Json.JsonDocument]::Parse($Json)
    try {
        $reconcilerProperty = @($document.RootElement.EnumerateObject() | Where-Object Name -CEQ 'reconciler')
        if ($reconcilerProperty.Count -eq 0) { return @{ present = $false; isString = $false; value = $null } }
        $coverageProperty = @($reconcilerProperty[0].Value.EnumerateObject() | Where-Object Name -CEQ 'ledgerCoverageStartAt')
        if ($coverageProperty.Count -eq 0) { return @{ present = $false; isString = $false; value = $null } }
        $isString = $coverageProperty[0].Value.ValueKind -eq [System.Text.Json.JsonValueKind]::String
        return @{
            present = $true
            isString = $isString
            value = if ($isString) { $coverageProperty[0].Value.GetString() } else { $null }
        }
    } finally {
        $document.Dispose()
    }
}

function Get-StgClientAliasProblems {
    # The same rule Stage 7 applies when it writes the client file (Invoke-QsClient,
    # infra/quickstart/Deploy-Quickstart.ps1): four aliases, each an exact model that the selected
    # project/classification admits and its backend deploys. Checked here so Stage 0 reports it.
    param([Parameter(Mandatory)] [Collections.IDictionary]$Cfg)
    $client = $Cfg.client
    if ($null -eq $client) { return @() }
    $problems = @()
    $group = @($Cfg.groups | Where-Object { $_.projectId -ceq $client.projectId -and $_.classification -ceq $client.classification })
    if ($group.Count -ne 1) { return @("client.projectId/client.classification must select exactly one configured group (found $($group.Count))") }
    $backend = @($Cfg.backends | Where-Object { $_.id -ceq $group[0].backendId })
    if ($backend.Count -ne 1) { return @("group $($client.projectId)/$($client.classification) backendId '$($group[0].backendId)' must match one backends[].id") }
    $deployed = @(($backend[0].deploymentInferenceGeo ?? @{}).Keys)
    $admitted = @(foreach ($family in @(($group[0].familyPolicy.families ?? @{}).Values)) { foreach ($m in @($family.models)) { if ($deployed -ccontains $m) { $m } } })
    $aliases = $client.models
    if ($aliases -isnot [Collections.IDictionary] -or $aliases.Count -ne 4 -or @($aliases.Keys | Where-Object { $_ -cnotin 'default', 'opus', 'sonnet', 'haiku' }).Count) {
        return @('client.models must name exactly default, opus, sonnet and haiku')
    }
    foreach ($alias in 'default', 'opus', 'sonnet', 'haiku') {
        if ($aliases[$alias] -isnot [string] -or $admitted -cnotcontains $aliases[$alias]) {
            $problems += "client.models.$alias '$($aliases[$alias])' is not admitted for $($client.projectId)/$($client.classification): admitted models deployed on backend $($backend[0].id) are [$($admitted -join ', ')]"
        }
    }
    return $problems
}

function Test-StgUtcCoverageStartAt {
    param([AllowNull()] $Value)
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$') { return $false }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParseExact(
        $Value, "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )
}

function Read-StgConfig {
    param([Parameter(Mandatory)] [string]$Path)
    $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    $raw = Get-Content -LiteralPath $full -Raw
    # The driver reads the file with strict System.Text.Json (Get-StgCoverageStartAtFromJson); a
    # trailing comma that ConvertFrom-Json tolerates is refused there, so name the file as the cause.
    try { $strict = [System.Text.Json.JsonDocument]::Parse($raw); $strict.Dispose() }
    catch { throw "staged configuration is not strict JSON ($full): $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }
    $c = $raw | ConvertFrom-Json -AsHashtable -Depth 100
    $problems = [Collections.Generic.List[string]]::new()
    if ($c.schemaVersion -ne 1) { $problems.Add('schemaVersion must be 1') }
    $continuityGatePresent = $c.reconciler -is [System.Collections.IDictionary] -and $c.reconciler.Contains('continuityGate')
    $continuityGate = $c.reconciler.continuityGate
    $coverageSetting = Get-StgCoverageStartAtFromJson $raw
    $coverageStartAt = $coverageSetting.value
    if ($continuityGatePresent -and ($continuityGate -isnot [string] -or $continuityGate -cnotin @('on', 'off'))) {
        $problems.Add('reconciler.continuityGate must be on or off')
    }
    if ($coverageSetting.present) {
        if (-not $coverageSetting.isString -or -not (Test-StgUtcCoverageStartAt $coverageStartAt)) {
            $problems.Add('reconciler.ledgerCoverageStartAt must be a valid UTC timestamp in YYYY-MM-DDTHH:mm:ss.fffZ form')
        } else {
            $c.reconciler.ledgerCoverageStartAt = $coverageStartAt
        }
    }
    if ($continuityGate -ceq 'on' -and -not $coverageSetting.present) {
        $problems.Add('reconciler.ledgerCoverageStartAt is required when reconciler.continuityGate is on')
    }
    foreach ($k in 'tenantId', 'subscriptionId') { if ($c[$k] -notmatch $script:Guid) { $problems.Add("$k must be a GUID") } }
    if ($c.resourceGroup -notmatch '^[A-Za-z0-9_.-]{1,90}$') { $problems.Add('resourceGroup is invalid') }
    if ($c.stage1.prefix -cnotmatch '^[a-z0-9]{3,8}$') { $problems.Add('stage1.prefix must be 3-8 lowercase letters or digits') }
    if ($c.network.mode -notin 'verify', 'existing', 'create') { $problems.Add('network.mode must be verify (customer-built, checked only), existing or create') }
    $subnetPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+/subnets/[^/]+$'
    if ($c.network.mode -eq 'verify') {
        # The customer builds the network; Stage 6 only reads it. The checks need the subnets, all in one VNet.
        $subnets = @($c.network.existing.privateEndpointSubnetId, $c.network.existing.functionsSubnetId)
        if ($c.stage1.approveNewPublicApimBootstrap -and $c.stage1.apimSku -in 'StandardV2', 'PremiumV2') { $subnets += $c.network.existing.apimSubnetId }
        elseif ($c.apim.existing -is [Collections.IDictionary] -and $c.apim.existing.integrateOutboundVnet -is [bool] -and $c.apim.existing.integrateOutboundVnet) { $subnets += $c.network.existing.apimSubnetId }
        if (@($subnets | Where-Object { -not $_ -or $_ -notmatch $subnetPattern }).Count) {
            $problems.Add('network.mode verify requires network.existing.privateEndpointSubnetId, functionsSubnetId and (for a new Standard v2/Premium v2 APIM) apimSubnetId as full subnet resource IDs')
        } elseif (@($subnets | ForEach-Object { ($_ -replace '/subnets/[^/]+$', '').ToLowerInvariant() } | Select-Object -Unique).Count -ne 1) {
            $problems.Add('network.mode verify requires every network.existing subnet to be in the same VNet')
        }
    }
    if ($c.network.mode -eq 'existing') {
        foreach ($id in @($c.network.existing.privateEndpointSubnetId, $c.network.existing.functionsSubnetId)) {
            if (-not $id -or $id -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+/subnets/[^/]+$') {
                $problems.Add('network.existing requires full privateEndpointSubnetId and functionsSubnetId resource IDs')
            }
        }
        foreach ($key in 'cosmos', 'blob') {
            $zoneIds = $c.network.existing.privateDnsZoneIds
            if ($zoneIds -isnot [Collections.IDictionary]) {
                $hint = if ($c.network -is [Collections.IDictionary] -and $c.network.Contains('privateDnsZoneIds')) { ' (it is under network, not under network.existing)' } else { '' }
                $problems.Add("network.existing.privateDnsZoneIds { cosmos, blob } is required in network.mode existing$hint")
                break
            }
            if (-not $zoneIds[$key] -or $zoneIds[$key] -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/privateDnsZones/[^/]+$') {
                $problems.Add("network.existing.privateDnsZoneIds.$key must be a full Private DNS zone resource ID")
            }
        }
        if (@($c.backends | Where-Object privateEndpoint).Count) {
            $foundryZones = ($c.network.existing.privateDnsZoneIds ?? @{}).foundry ?? @{}
            foreach ($key in 'cognitiveServices', 'openAi', 'aiServices') {
                $id = $foundryZones[$key]
                if (-not $id -or $id -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/privateDnsZones/[^/]+$') {
                    $problems.Add("private Foundry with network.mode existing requires network.existing.privateDnsZoneIds.foundry.$key")
                }
            }
            if ($c.stage1.approveNewPublicApimBootstrap -and $c.stage1.apimSku -in 'StandardV2', 'PremiumV2' -and
                $c.network.existing.apimSubnetId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+/subnets/[^/]+$') {
                $problems.Add('a new Standard v2/Premium v2 APIM with network.mode existing requires network.existing.apimSubnetId')
            }
        }
    }
    if (-not $c.cosmos.databaseName) { $problems.Add('cosmos.databaseName is required') }
    foreach ($b in @($c.backends)) { foreach ($k in 'id', 'subscriptionId', 'resourceGroup', 'accountName', 'url') { if (-not $b[$k]) { $problems.Add("backends[$($b.id)].$k is required") } } }
    foreach ($b in @($c.backends | Where-Object { $_.privateEndpoint -and $c.network.mode -ne 'verify' })) {
        if ($b.subscriptionId -ine $c.subscriptionId -or $b.resourceGroup -ine $c.resourceGroup) {
            $problems.Add("backend $($b.id) requests privateEndpoint but Stage 6 creates endpoints (modes existing/create) only for accounts in the deployment subscription and resource group")
        }
    }
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
        if (@($fd.deployments).Count -and $mpd.industry -cnotin @('technology','finance','healthcare','education','retail','manufacturing','government','media','other')) {
            $problems.Add('stage1.foundry.modelProviderData.industry must be one of the supported lowercase Anthropic values')
        }
        $deploymentNames = @($fd.deployments | ForEach-Object { $_.name })
        if (@($deploymentNames | Select-Object -Unique).Count -ne $deploymentNames.Count) { $problems.Add('stage1.foundry.deployments names must be unique') }
        foreach ($d in @($fd.deployments)) {
            if (-not $d.model -or -not $d.version -or $d.sku -notin @('GlobalStandard','DataZoneStandard') -or [int]$d.capacity -lt 1) {
                $problems.Add("stage1.foundry deployment '$($d.name)' needs model, version, eligible sku and positive capacity")
            }
        }
        if ($fd.modelDeploymentsBlocked -and @($fd.deployments).Count) { $problems.Add('modelDeploymentsBlocked cannot be combined with model deployments') }
    }
    if ($c.stage1.includeAdmin -and -not $existingApps.adminAppId -and -not @($c.entra.adminEditors).Count) {
        $problems.Add('a newly created admin registration requires at least one entra.adminEditors assignment; assignment-required is enabled')
    }
    if ($c.sharedResourceGroup -and $c.sharedResourceGroup -isnot [bool]) { $problems.Add('sharedResourceGroup must be true or false') }
    foreach ($p in @(Get-StgClientAliasProblems $c)) { $problems.Add($p) }
    if ($c.stage1 -is [Collections.IDictionary] -and $c.stage1.Contains('apimZoneRedundant')) {
        # Standard v2 / Premium v2 only, chosen at creation; one unit is allowed but two are recommended (docs/UNKNOWNS.md APIM-ZR-01, APIM-ZR-03).
        $zoneRedundant = $c.stage1.apimZoneRedundant
        $apimSku = $c.stage1.apimSku ?? 'StandardV2'
        $apimUnits = $c.stage1.apimUnits ?? 1
        if ($zoneRedundant -isnot [bool]) { $problems.Add('stage1.apimZoneRedundant must be true or false') }
        elseif ($zoneRedundant -and $apimSku -cnotin 'StandardV2', 'PremiumV2') { $problems.Add("stage1.apimZoneRedundant requires stage1.apimSku StandardV2 or PremiumV2 (got $apimSku)") }
        elseif ($zoneRedundant -and [int]$apimUnits -lt 2) {
            Write-Warning "stage1.apimZoneRedundant with stage1.apimUnits $apimUnits is allowed; Microsoft recommends at least two units so a zone outage does not reduce gateway capacity (https://learn.microsoft.com/azure/reliability/reliability-api-management)."
        }
    }
    # Opt-in changes to a customer's existing APIM (apim.existing): Stage 5 gateway diagnostics, Stage 6 outbound VNet integration.
    $apimExisting = $c.apim.existing
    if ($apimExisting -is [Collections.IDictionary]) {
        foreach ($k in 'configureGatewayDiagnostics', 'integrateOutboundVnet') {
            if ($apimExisting.Contains($k) -and $apimExisting[$k] -isnot [bool]) { $problems.Add("apim.existing.$k must be true or false") }
        }
        $diagnosticsOn = $apimExisting.configureGatewayDiagnostics -is [bool] -and $apimExisting.configureGatewayDiagnostics
        $outboundOn = $apimExisting.integrateOutboundVnet -is [bool] -and $apimExisting.integrateOutboundVnet
        if (($diagnosticsOn -or $outboundOn) -and $c.stage1.approveNewPublicApimBootstrap) {
            $problems.Add('apim.existing.configureGatewayDiagnostics and integrateOutboundVnet apply only to an existing APIM; with stage1.approveNewPublicApimBootstrap Stage 1 creates the APIM and Stages 1 and 6 already configure it')
        }
        if ($outboundOn) {
            $apimSubnet = $c.network.existing.apimSubnetId
            if ($c.network.mode -notin 'verify', 'existing') { $problems.Add('apim.existing.integrateOutboundVnet needs network.mode verify or existing') }
            if (-not $apimSubnet -or $apimSubnet -notmatch $subnetPattern) {
                $problems.Add('apim.existing.integrateOutboundVnet requires network.existing.apimSubnetId as a full subnet resource ID')
            } elseif (($apimSubnet -split '/')[2] -ine $apimExisting.subscriptionId) {
                $problems.Add('apim.existing.integrateOutboundVnet: network.existing.apimSubnetId must be in the same subscription as the existing APIM (Microsoft Learn, integrate-vnet-outbound)')
            }
        }
    }
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
        if (-not $state.stageLayout -or $state.stageLayout -lt 2) { $state = Convert-StgStateLayout $state $p }
        return $state
    }
    return @{ schemaVersion = 1; stageLayout = 2; target = (Get-StgTarget $Cfg); stages = @{} }
}
# Layout 1 numbered network as Stage 2. Layout 2 runs it last (Stage 6), after schema 2, grants 3,
# Entra 4 and configuration 5, because the customer usually builds the network. Stage outputs and
# hashes are unchanged; only the stage keys move. The original file is kept as state.layout1.json.
function Convert-StgStateLayout {
    param($State, [string]$Path)
    $map = @{ '0' = '0'; '1' = '1'; '2' = '6'; '3' = '2'; '4' = '3'; '5' = '4'; '6' = '5'; '7' = '7'; '8' = '8' }
    $stages = @{}
    foreach ($old in @($State.stages.Keys)) {
        if (-not $map.ContainsKey("$old")) { throw "state_layout_unknown_stage: $old in $Path" }
        $record = $State.stages[$old]
        if ($null -ne $record.dependencyHashes) {
            $deps = [ordered]@{}
            foreach ($d in @($record.dependencyHashes.Keys)) { $deps[$map["$d"]] = $record.dependencyHashes[$d] }
            $record.dependencyHashes = $deps
        }
        $stages[$map["$old"]] = $record
    }
    $backup = Join-Path (Split-Path $Path -Parent) 'state.layout1.json'
    if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $Path -Destination $backup }
    $State.stages = $stages; $State.stageLayout = 2
    $State | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
    Write-Host "state migration: stage keys moved to the network-last order (backup $backup)."
    return $State
}
function ConvertTo-StgCanonical {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($Value.Keys | Where-Object { $_ -ne '__path' } | Sort-Object -CaseSensitive)) { $o[$k] = ConvertTo-StgCanonical $Value[$k] }
        return $o
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return , @($Value | ForEach-Object { ConvertTo-StgCanonical $_ })
    }
    return $Value
}
function Get-StgStageInput {
    param($Cfg, [int]$Number)
    $input = [ordered]@{ tenantId = $Cfg.tenantId; subscriptionId = $Cfg.subscriptionId; resourceGroup = $Cfg.resourceGroup }
    switch ($Number) {
        0 { $input += @{ location=$Cfg.location; stage1=$Cfg.stage1; backends=$Cfg.backends; groups=$Cfg.groups } }
        1 { $input += @{ location=$Cfg.location; tags=$Cfg.tags; sharedResourceGroup=$Cfg.sharedResourceGroup; stage1=$Cfg.stage1 } }
        2 { $input += @{ stage1=$Cfg.stage1; cosmos=$Cfg.cosmos } }
        3 { $input += @{ stage1=$Cfg.stage1; cosmos=$Cfg.cosmos; syncMode=$Cfg.sync.mode; backends=$Cfg.backends } }
        4 { $input += @{ stage1=$Cfg.stage1; entra=$Cfg.entra; groups=$Cfg.groups } }
        6 { $input += @{ location=$Cfg.location; tags=$Cfg.tags; stage1=$Cfg.stage1; network=$Cfg.network; backends=@($Cfg.backends | ForEach-Object { @{subscriptionId=$_.subscriptionId;resourceGroup=$_.resourceGroup;accountName=$_.accountName;privateEndpoint=$_.privateEndpoint} }) } }
        5 { $input += @{ stage1=$Cfg.stage1; apim=$Cfg.apim; backends=$Cfg.backends; resolver=$Cfg.resolver; sync=$Cfg.sync; reconciler=$Cfg.reconciler; budgetState=$Cfg.budgetState; syncTimerEnabled=$Cfg.syncTimerEnabled; gateway=$Cfg.gateway; workbook=$Cfg.workbook; rateCard=$Cfg.rateCard; admin=$Cfg.admin; groups=$Cfg.groups } }
        7 { $input += @{ stage1=$Cfg.stage1; groups=$Cfg.groups; client=$Cfg.client; rateCard=$Cfg.rateCard; sync=$Cfg.sync; entra=$Cfg.entra } }
        8 { $input += @{ stage1=$Cfg.stage1; acceptance=$Cfg.acceptance; gateway=$Cfg.gateway; admin=$Cfg.admin } }
        default { throw "invalid stage number $Number" }
    }
    # Only an opted-in existing-APIM integration enters the Stage 6 hash, so completed deployments keep theirs.
    if ($Number -eq 6 -and $Cfg.apim.existing -is [Collections.IDictionary] -and $Cfg.apim.existing.integrateOutboundVnet -is [bool] -and $Cfg.apim.existing.integrateOutboundVnet) {
        $input.existingApimOutbound = [ordered]@{ subscriptionId = $Cfg.apim.existing.subscriptionId; resourceGroup = $Cfg.apim.existing.resourceGroup; name = $Cfg.apim.existing.name }
    }
    $canonical = ConvertTo-StgCanonical $input | ConvertTo-Json -Depth 100 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
}
function Get-StgStageDependencies {
    param([int]$Number)
    switch ($Number) {
        0 { @() }
        1 { @() }
        2 { @(1) }
        3 { @(1,2) }
        4 { @(1) }
        5 { @(1,3,4) }
        6 { @(1) }
        7 { @(1,4,5,6) }
        8 { @(1,4,5,7) }
        default { throw "invalid stage number $Number" }
    }
}
function Get-StgNetworkAction {
    param([string]$Mode, [bool]$VnetExists, [bool]$StageStateExists)
    if ($Mode -eq 'create' -and $VnetExists) {
        if (-not $StageStateExists) {
            throw 'network_create_existing_vnet: create mode owns an authoritative subnet list. The VNet exists without matching Stage 6 state; stop and recover with network.mode verify (customer-built) or existing, with explicit resource IDs.'
        }
        return 'reuse'
    }
    return 'deploy'
}
function Get-StgNetworkDnsTargets {
    param($Cfg, $Outputs, [bool]$HasFoundry)
    $vnetId = if ($Outputs.vnetId) { [string]$Outputs.vnetId } else { [string]($Outputs.functionsSubnetId -replace '/subnets/[^/]+$', '') }
    if ($vnetId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+$') {
        throw 'network_vnet_output: cannot determine a valid VNet ID from the Stage 6 outputs.'
    }
    $foundryZones = @($Outputs.foundryPrivateDnsZoneIds | Where-Object { $_ })
    if ($HasFoundry -and -not $foundryZones.Count) {
        if ($Cfg.network.mode -eq 'create') {
            $foundryZoneNames = @('privatelink.cognitiveservices.azure.com', 'privatelink.openai.azure.com', 'privatelink.services.ai.azure.com')
            $foundryZones = @($foundryZoneNames | ForEach-Object {
                "/subscriptions/$($Cfg.subscriptionId)/resourceGroups/$($Cfg.resourceGroup)/providers/Microsoft.Network/privateDnsZones/$_"
            })
        } else {
            $foundryZones = @($Cfg.network.existing.privateDnsZoneIds.foundry.Values | Where-Object { $_ })
        }
    }
    $zoneIds = @($Outputs.privateDnsZoneIds.cosmos, $Outputs.privateDnsZoneIds.blob) + $foundryZones
    return [ordered]@{ vnetId = $vnetId; zoneIds = @($zoneIds | Where-Object { $_ }) }
}
# Dependency hashes cover a stage's operational outputs only: `verify` (read-back snapshots, which
# change when later stages add resources) and `durationSeconds` are excluded.
function Get-StgOutputHash {
    param($Outputs, [string[]]$Exclude = @('durationSeconds', 'verify'))
    $stable = [ordered]@{}
    foreach ($key in $Outputs.Keys) { if ($Exclude -cnotcontains $key) { $stable[$key] = $Outputs[$key] } }
    $canonical = ConvertTo-StgCanonical $stable | ConvertTo-Json -Depth 100 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
}
function Get-StgDependencyHashes {
    param($State, [int]$Number)
    $result = [ordered]@{}
    foreach ($dependency in Get-StgStageDependencies $Number) {
        $record = $State.stages["$dependency"]
        if (-not $record) { throw "stage_order: stage $Number requires stage $dependency to be completed first." }
        $result["$dependency"] = Get-StgOutputHash $record.outputs
    }
    return $result
}function Save-StgStage { param($Cfg, [int]$Number, $Outputs)
    $state = Read-StgState $Cfg
    $state.target = Get-StgTarget $Cfg
    $state.stages["$Number"] = @{ completedAt = [DateTime]::UtcNow.ToString('o'); configHash=(Get-StgStageInput $Cfg $Number); dependencyHashes=(Get-StgDependencyHashes $state $Number); outputs = $Outputs }
    $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Get-StgStatePath $Cfg) -Encoding utf8NoBOM
}
function Get-StgStage { param($Cfg, [int]$Number)
    $state = Read-StgState $Cfg
    $s = $state.stages["$Number"]
    if (-not $s) { throw "stage_order: stage $Number has not completed in $script:StateDir; run it with -Apply first." }
    $currentHash = Get-StgStageInput $Cfg $Number
    if ($s.configHash -and $s.configHash -cne $currentHash) { throw "stage_config_changed: inputs for stage $Number changed after it was verified; preview and apply stage $Number again." }
    $currentDependencies = Get-StgDependencyHashes $state $Number
    if ($null -ne $s.dependencyHashes) {
        foreach ($dependency in $currentDependencies.Keys) {
            if ($s.dependencyHashes[$dependency] -cne $currentDependencies[$dependency]) {
                # Earlier versions hashed every output, or every output except durationSeconds. A
                # saved hash is accepted only if the dependency's current outputs reproduce it exactly
                # under one of those rules, which means the outputs have not changed.
                $record = $state.stages["$dependency"]
                $rebased = (Get-StgOutputHash $record.outputs -Exclude @()) -ceq $s.dependencyHashes[$dependency] -or
                    (Get-StgOutputHash $record.outputs -Exclude @('durationSeconds')) -ceq $s.dependencyHashes[$dependency]
                if ($rebased) {
                    $s.dependencyHashes[$dependency] = $currentDependencies[$dependency]
                    $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Get-StgStatePath $Cfg) -Encoding utf8NoBOM
                    Write-Host "state migration: stage $dependency outputs are unchanged; dependency hash moved to the current rule."
                }
                if (-not $rebased) { throw "stage_dependency_changed: stage $dependency was re-run or its verified output changed; preview and apply stage $Number again." }
            }
        }
    }
    # One-time migration for the live runs performed before config/output binding was added.
    if (-not $s.configHash -or $null -eq $s.dependencyHashes) {
        $s.configHash = $currentHash
        $s.dependencyHashes = $currentDependencies
        $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Get-StgStatePath $Cfg) -Encoding utf8NoBOM
    }
    return $s.outputs
}

function Write-StgEvidence { param([string]$Name, $Value)
    $dir = Join-Path $script:StateDir 'evidence'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir $Name
    if ($Value -is [string]) { $Value | Set-Content -LiteralPath $file -Encoding utf8NoBOM } else { $Value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $file -Encoding utf8NoBOM }
    return $file
}

function Test-StgExactResourceScope { param([string]$Scope, [string[]]$ResourceIds)
    return [bool](@($ResourceIds | Where-Object { $_ -ieq $Scope }).Count)
}

function Get-StgStage1TargetIds {
    param($Cfg)
    $root = "/subscriptions/$($Cfg.subscriptionId)/resourceGroups/$($Cfg.resourceGroup)/providers/Microsoft.Resources/deployments/$(Get-StgStage1DeploymentName $Cfg)"
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($root)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($queue.Count) {
        $deploymentId = $queue.Dequeue()
        if (-not $seen.Add($deploymentId)) { continue }
        $page = Get-StgArm "$deploymentId/operations" '2022-09-01'
        foreach ($operation in @($page.value)) {
            $target = $operation.properties.targetResource
            if (-not $target.id) { continue }
            [void]$ids.Add([string]$target.id)
            if ($target.resourceType -ieq 'Microsoft.Resources/deployments') { $queue.Enqueue([string]$target.id) }
        }
    }
    return @($ids)
}

function Get-StgUnsafeSharedChanges {
    param([object[]]$Changes, [string[]]$PriorStage1TargetIds)
    $owned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $PriorStage1TargetIds) { [void]$owned.Add($id) }
    return @($Changes | Where-Object {
        $_.changeType -eq 'Delete' -or
        ($_.changeType -in @('Modify', 'Deploy') -and -not $owned.Contains([string]$_.resourceId))
    })
}

function Enter-StgStage7Lock {
    param([Parameter(Mandatory)] [string]$LockPath)
    try {
        $stream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $stream.SetLength(0)
        $bytes = [Text.Encoding]::UTF8.GetBytes("pid=$PID started=$([DateTime]::UtcNow.ToString('o'))`n")
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        return $stream
    } catch [IO.IOException] {
        throw "stage7_busy: another Stage 7 is using this checkout (lock: $LockPath); wait for it to finish before building/publishing."
    }
}

function Assert-Stg { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw "verify_failed: $Message" } }

# Role assignments (ARM: properties.principalId; Cosmos SQL: principalId) held by this deployment's
# principals. A standby region (infra/dr) adds its own grants to the shared workspace and Cosmos account.
function Select-StgOwnAssignments {
    param([object[]]$Assignments, [Parameter(Mandatory)] $Principals)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($Principals.Values)) { if ($p) { [void]$ids.Add([string]$p) } }
    return @($Assignments | Where-Object {
        if (-not $_) { return $false }
        $holder = if ($_ -is [Collections.IDictionary]) { if ($_.Contains('properties')) { $_['properties'] } else { $_ } }
                  elseif ($_.PSObject.Properties['properties']) { $_.properties } else { $_ }
        $id = if ($holder -is [Collections.IDictionary]) { $holder['principalId'] } elseif ($holder.PSObject.Properties['principalId']) { $holder.principalId } else { $null }
        $ids.Contains([string]$id)
    })
}

# A DR standby region (infra/dr/Invoke-DrStandby.ps1) runs these stage functions with a `standby`
# section in its derived configuration. Without that section nothing changes.
function Get-StgStandbyOption { param($Cfg, [string]$Name)
    if (-not ($Cfg -is [Collections.IDictionary] -and $Cfg.Contains('standby') -and $Cfg.standby)) { return '' }
    return [string]$Cfg.standby[$Name]
}
function Get-StgStage1DeploymentName { param($Cfg)
    $n = Get-StgStandbyOption $Cfg 'stage1DeploymentName'
    if ($n) { return $n } else { return 'stage1-services' }
}
function Get-StgDeploymentName { param($Cfg, [string]$Name)
    if (Get-StgStandbyOption $Cfg 'stage1DeploymentName') { return "dr-standby-$Name" } else { return $Name }
}
function Add-StgStandbyParameters {
    param($Cfg, [int]$Stage, [hashtable]$Parameters)
    if (-not (Get-StgStandbyOption $Cfg 'stage1DeploymentName')) { return $Parameters }
    switch ($Stage) {
        3 { $Parameters.assignmentNameSalt = Get-StgStandbyOption $Cfg 'assignmentNameSalt' }
        5 { $Parameters.workbookContent = @{}; $Parameters.workbookContentTags = @{} }
        6 { $Parameters.endpointNameSuffix = Get-StgStandbyOption $Cfg 'endpointNameSuffix' }
    }
    return $Parameters
}

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
    $config = Invoke-StgAzJson @('functionapp', 'config', 'show', '--subscription', $Cfg.subscriptionId, '--resource-group', $Cfg.resourceGroup, '--name', $Name)
    $pick = { param($k) if ($site.properties -and $null -ne $site.properties[$k]) { $site.properties[$k] } else { $site[$k] } }
    return @{
        name = $site.name
        publicNetworkAccess = (& $pick 'publicNetworkAccess')
        # A Flex app without VNet integration returns null; '' keeps the read-back's string comparisons valid.
        virtualNetworkSubnetId = "$(& $pick 'virtualNetworkSubnetId')"
        httpsOnly = (& $pick 'httpsOnly')
        runtimeName = (& $pick 'functionAppConfig').runtime.name
        runtimeVersion = (& $pick 'functionAppConfig').runtime.version
        ftpsState = $config.ftpsState
    }
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
    $s1 = Get-StgStage $Cfg 1; $entra = Get-StgStage $Cfg 4
    $names = $s1.names | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $names.cosmosDatabase = $Cfg.cosmos.databaseName
    $names.cosmosRoles = $Cfg.cosmos.roleNames
    $names.resourceGroupMode = 'existing'
    $groups = foreach ($g in $Cfg.groups) {
        $copy = $g | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $copy.groupId = $entra.groups["$($g.projectId)/$($g.classification)"].id
        $copy.Remove('groupDisplayName'); $copy.Remove('members')
        $copy
    }
    $rate = @{}; foreach ($k in $Cfg.rateCard.Keys) { $rate[$k] = Join-Path $script:Repo $Cfg.rateCard[$k] }
    return @{
        tenantId = $Cfg.tenantId; location = $Cfg.location; tags = $Cfg.tags; names = $names
        apim = (Get-StgApim $Cfg); network = $Cfg.network; groups = @($groups); client = $Cfg.client
        registrations = $entra.registrations; backends = @($Cfg.backends); cosmos = $Cfg.cosmos
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
