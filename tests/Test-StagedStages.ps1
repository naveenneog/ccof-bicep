#Requires -Version 7.0
<#
.SYNOPSIS
    Offline contract tests for the staged deployment entry points (infra/staged/stage*.bicep and
    Invoke-StagedDeployment.ps1). No Azure call: Bicep compiles locally and the driver is dot-sourced.
#>
[CmdletBinding()]
param([string]$BicepPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $BicepPath) {
    $command = Get-Command bicep -ErrorAction SilentlyContinue
    if ($command) { $BicepPath = $command.Source }
    elseif (Test-Path (Join-Path $HOME '.azure\bin\bicep.exe')) { $BicepPath = Join-Path $HOME '.azure\bin\bicep.exe' }
    else { throw 'Offline Bicep CLI required. Supply -BicepPath; this test does not install tools or call Azure.' }
}
$passed = 0
function Assert-Contract([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
function Build-Arm([string]$Relative) {
    $out = & $BicepPath build (Join-Path $root $Relative) --stdout 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Bicep compilation failed: $Relative" }
    return ($out -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100
}
function Get-Resources($Template) {
    foreach ($resource in $Template.resources) {
        $resource
        if ($resource.properties.template) { Get-Resources $resource.properties.template }
    }
}
function Test-StageBoundary($Arm, [string[]]$Allowed, [string]$Stage) {
    foreach ($r in @(Get-Resources $Arm)) {
        if ($r.type -notin $Allowed) { throw "$Stage declares a resource outside its boundary: $($r.type)" }
    }
}

# Stage boundaries: each entry point declares only its own kind of resource.
$boundaries = [ordered]@{
    'infra\staged\stage6-network.bicep' = @('Microsoft.Resources/deployments', 'Microsoft.Network/networkSecurityGroups', 'Microsoft.Network/virtualNetworks',
        'Microsoft.Network/privateDnsZones', 'Microsoft.Network/privateDnsZones/virtualNetworkLinks', 'Microsoft.Network/privateEndpoints',
        'Microsoft.Network/privateEndpoints/privateDnsZoneGroups')
    'infra\staged\stage2-schema.bicep' = @('Microsoft.DocumentDB/databaseAccounts/sqlDatabases', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers')
    'infra\staged\stage3-grants.bicep' = @('Microsoft.Resources/deployments', 'Microsoft.Authorization/roleAssignments',
        'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions', 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments')
    'infra\staged\stage5-config.bicep' = @('Microsoft.Resources/deployments', 'Microsoft.Web/sites/config', 'Microsoft.ApiManagement/service/apis',
        'Microsoft.ApiManagement/service/backends', 'Microsoft.ApiManagement/service/apis/policies', 'Microsoft.ApiManagement/service/apis/operations', 'Microsoft.ApiManagement/service/loggers',
        'Microsoft.ApiManagement/service/apis/diagnostics', 'Microsoft.Insights/workbooks')
}
$arms = @{}
foreach ($path in $boundaries.Keys) {
    $arms[$path] = Build-Arm $path
    Test-StageBoundary $arms[$path] $boundaries[$path] $path
    $passed++
}

# Negative control: the same check rejects a role assignment injected into the network stage.
$mutated = $arms['infra\staged\stage6-network.bicep'] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
$mutated.resources += @{ type = 'Microsoft.Authorization/roleAssignments'; apiVersion = '2022-04-01'; name = 'injected' }
$caught = $false
try { Test-StageBoundary $mutated $boundaries['infra\staged\stage6-network.bicep'] 'mutated stage 6' } catch { $caught = $_.Exception.Message -match 'roleAssignments' }
Assert-Contract $caught 'Negative control: an injected role assignment was not rejected by the boundary check.'

# Stage 5 (configuration) must never grant: no Authorization resource anywhere, including the reused modules.
Assert-Contract (-not (@(Get-Resources $arms['infra\staged\stage5-config.bicep']) | Where-Object type -Match 'Authorization|sqlRole')) 'Stage 5 contains a grant.'
# Stage 5 must not repeat Stage 1's resource-log diagnostic settings (Azure Monitor refuses duplicates).
Assert-Contract (-not (@(Get-Resources $arms['infra\staged\stage5-config.bicep']) | Where-Object type -EQ 'Microsoft.Insights/diagnosticSettings')) 'Stage 5 repeats a diagnostic setting.'

# Stage 3 and Stage 4 keep the quickstart's Cosmos data contract.
$quick = Build-Arm 'infra\quickstart\modules\cosmos-data.bicep'
$schema = $arms['infra\staged\stage2-schema.bicep']; $grants = $arms['infra\staged\stage3-grants.bicep']
$quickContainers = $quick.variables.cosmosContainers | ConvertTo-Json -Compress
$stagedContainers = $schema.variables.cosmosContainers | ConvertTo-Json -Compress
Assert-Contract ($quickContainers -ceq $stagedContainers) 'Stage 3 containers differ from the quickstart.'
foreach ($d in $quick.variables.cosmosRoleDefinitions) {
    $m = @($grants.variables.cosmosRoleDefinitions | Where-Object { $_.key -ceq $d.key })
    Assert-Contract ($m.Count -eq 1 -and (($m[0].dataActions | ConvertTo-Json -Compress) -ceq ($d.dataActions | ConvertTo-Json -Compress))) "Stage 4 role definition $($d.key) differs from the quickstart."
}
$admin = @($grants.variables.cosmosRoleDefinitions | Where-Object key -CEQ 'adminProjectEditor')[0]
Assert-Contract (-not ($admin.dataActions -match '/delete$|/upsert$')) 'Admin editor role must not delete or upsert.'
foreach ($a in $quick.variables.cosmosAssignments | Where-Object principal -NE 'runner') {
    $m = @($grants.variables.cosmosAssignments | Where-Object { $_.id -ceq $a.id })
    Assert-Contract ($m.Count -eq 1 -and $m[0].role -ceq $a.role -and $m[0].container -ceq $a.container -and $m[0].principal -ceq $a.principal) "Stage 4 assignment $($a.id) differs from the quickstart."
}
# Every client the admin API accepts (ADMIN_ALLOWED_CLIENT_IDS) is preauthorized by Stage 4 and read back.
$entraText = Get-Content -Raw (Join-Path $root 'infra\staged\Staged.Entra.ps1')
Assert-Contract ($entraText -match '\$adminClients = @\(\$adm\.appId\) \+ @\(\$Cfg\.admin\.extraAllowedClientIds' -and $entraText -match 'Merge-StgPreauthorized \$adm \$adminClients' -and $entraText -match 'foreach \(\$cid in \$adminClients\)') 'Stage 4 must preauthorize and verify admin.extraAllowedClientIds.'
$adminScopes = @($grants.variables.cosmosAssignments | Where-Object principal -EQ 'admin' | ForEach-Object { $_.container })
Assert-Contract ((($adminScopes | Sort-Object) -join ',') -ceq 'adminConfig,projects') 'Admin Cosmos access must be limited to projects and adminConfig.'
# The sync reads the admin console's removal-limit override: read-only, adminConfig only, and only with the admin app.
$syncConfig = @($grants.variables.cosmosAssignments | Where-Object { $_.principal -ceq 'sync' -and $_.container -ceq 'adminConfig' })
Assert-Contract ($syncConfig.Count -eq 1 -and $syncConfig[0].role -ceq '00000000-0000-0000-0000-000000000001') 'Sync access to adminConfig must be the built-in Data Reader only.'
Assert-Contract ($grants.variables.activeAssignments -match "not\(equals\(lambdaVariables\('a'\)\.container, 'adminConfig'\)\), not\(empty\(coalesce\(tryGet\(parameters\('principals'\), 'admin'\)") 'adminConfig assignments must require the admin principal.'
$settingsArm = Build-Arm 'infra\quickstart\modules\app-settings.bicep'
Assert-Contract (($settingsArm.parameters.syncLimitsContainer.defaultValue -ceq '') -and ((Get-Content -Raw 'infra\staged\stage5-config.bicep') -match "syncLimitsContainer: \(admin\.\?enabled \?\? false\) \? 'adminConfig' : ''")) 'Stage 5 must set SYNC_LIMITS_CONTAINER=adminConfig only with the admin app.'

# Stage 1 publishes the names later stages read.
$s1 = Build-Arm 'infra\staged\main.bicep'
Assert-Contract ($s1.outputs.ContainsKey('names') -and $s1.outputs.ContainsKey('apimName')) 'Stage 1 must output names and apimName.'
Assert-Contract (($s1.parameters.apimSku.allowedValues -join ',') -ceq 'BasicV2,StandardV2' -and $s1.parameters.apimSku.defaultValue -ceq 'StandardV2') 'APIM SKU choice changed.'

# Driver: parses, every stage has an entry function, no az argument holds a cmd.exe metacharacter,
# preview is the default, and later stages read earlier stage state.
$driverPath = Join-Path $root 'infra\staged\Invoke-StagedDeployment.ps1'
$driverFiles = @($driverPath) + @('Staged.Common.ps1', 'Staged.Resources.ps1', 'Staged.Entra.ps1', 'Staged.Application.ps1' | ForEach-Object { Join-Path $root "infra\staged\$_" })
$functionAsts = @()
foreach ($file in $driverFiles) {
    $tokens = $null; $errors = $null
    $fileAst = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    Assert-Contract (-not $errors.Count) "Driver file $file does not parse: $($errors.Message -join '; ')"
    $functionAsts += @($fileAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
}
$functions = @($functionAsts | ForEach-Object Name)
foreach ($n in 0..8) { Assert-Contract ($functions -contains "Invoke-Stage$n") "Driver lacks Invoke-Stage$n." }
$driver = ($driverFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
Assert-Contract (-not $driver.Contains('}`n} finally')) 'Driver must not contain a literal escaped newline after its Stage 7 lock try block.'
foreach ($line in ($driver -split "`n" | Where-Object { $_ -match "Invoke-Qs(Az|AzJson)|Invoke-StgAzJson|Get-StgGraph|Get-StgArm" })) {
    foreach ($literal in [regex]::Matches($line, "'[^']*'")) {
        Assert-Contract ($literal.Value -notmatch '[&|<>^]') "Driver passes a cmd.exe metacharacter to az: $($literal.Value)"
    }
}
Assert-Contract ($driver -match '\[switch\]\$Apply' -and $driver -match "what-if") 'Driver must preview by default.'
foreach ($n in 2..8) {
    $body = @($functionAsts | Where-Object Name -EQ "Invoke-Stage$n")[0].Body.Extent.Text
    Assert-Contract ($body -match 'Get-StgStage \$Cfg 1') "Invoke-Stage$n does not require Stage 1 state."
}

# Configuration: the committed example is refused until its placeholders are replaced; a filled copy passes.
. $driverPath -DotSourceOnly
$action = Get-StgNetworkAction -Mode 'create' -VnetExists $false -StageStateExists $false
Assert-Contract ($action -ceq 'deploy') 'First Stage 6 create-mode deployment must deploy the network.'
$action = Get-StgNetworkAction -Mode 'create' -VnetExists $true -StageStateExists $true
Assert-Contract ($action -ceq 'reuse') 'A saved Stage 6 create-mode retry must skip the authoritative network deployment.'
$action = Get-StgNetworkAction -Mode 'existing' -VnetExists $true -StageStateExists $false
Assert-Contract ($action -ceq 'deploy') 'Existing-network mode must not be blocked by a pre-existing VNet.'
$unsafeCreateRetry = $false
try { $null = Get-StgNetworkAction -Mode 'create' -VnetExists $true -StageStateExists $false } catch { $unsafeCreateRetry = $_.Exception.Message -match 'network_create_existing_vnet' }
Assert-Contract $unsafeCreateRetry 'Create mode without Stage 2 state must refuse to rewrite an existing VNet subnet list.'
$dnsConfig = @{ subscriptionId = '00000000-0000-4000-8000-000000000001'; resourceGroup = 'rg'; network = @{ mode = 'create' } }
$dnsOutputs = @{ functionsSubnetId = '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/functions'; privateDnsZoneIds = @{ cosmos = 'cosmos-zone'; blob = 'blob-zone' } }
$dnsTargets = Get-StgNetworkDnsTargets -Cfg $dnsConfig -Outputs $dnsOutputs -HasFoundry $true
Assert-Contract ($dnsTargets.vnetId -ceq '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet' -and $dnsTargets.zoneIds.Count -eq 5) 'Stage 6 must derive DNS targets when earlier deployment outputs lack VNet and Foundry zone IDs.'
$headers = New-StgGatewayHeaders -Token 'token-placeholder' -Project 'PROJECT01' -ProjectHeader 'x-customer-project'
Assert-Contract ($headers['x-customer-project'] -ceq 'PROJECT01' -and -not $headers.ContainsKey('x-ccof-project')) 'Stage 8 must use the configured project selector header.'
$priorResourceId = '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/shared/providers/Microsoft.Storage/storageAccounts/prefix-owned/blobServices/default'
$changes = @(
    @{ changeType = 'Create'; resourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/prefix-new' }
    @{ changeType = 'Modify'; resourceId = $priorResourceId }
    @{ changeType = 'Modify'; resourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.ApiManagement/service/prefix-unrelated' }
)
$unsafe = @(Get-StgUnsafeSharedChanges -Changes $changes -PriorStage1TargetIds @($priorResourceId))
Assert-Contract ($unsafe.Count -eq 1 -and $unsafe[0].resourceId -like '*prefix-unrelated') 'Shared Stage 1 must use exact prior operation IDs, not a colliding prefix.'
Assert-Contract ((Test-StgExactResourceScope $priorResourceId @($priorResourceId)) -and -not (Test-StgExactResourceScope '/subscriptions/s/resourceGroups/rg/providers/Microsoft.ApiManagement/service/prefix-unrelated' @($priorResourceId))) 'Stage 1 and Stage 4 grant inventory must use exact resource IDs, not matching names.'
$delete = @(Get-StgUnsafeSharedChanges -Changes @(@{ changeType = 'Delete'; resourceId = $priorResourceId }) -PriorStage1TargetIds @($priorResourceId))
Assert-Contract ($delete.Count -eq 1) 'Shared Stage 1 must always refuse Delete, even for a prior target.'
$example = Join-Path $root 'infra\staged\staged.config.example.json'
$refused = $false
try { $null = Read-StgConfig $example } catch { $refused = $_.Exception.Message -match 'tenantId must be a GUID' }
Assert-Contract $refused 'Example configuration with placeholders must be refused.'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "staged-config-$([guid]::NewGuid().ToString('N')).json"
try {
    $c = Get-Content -LiteralPath $example -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $c.tenantId = '00000000-0000-4000-8000-000000000001'; $c.subscriptionId = '00000000-0000-4000-8000-000000000002'; $c.resourceGroup = 'rg-new'
    $vnetPath = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets'
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $placeholderRefused = $false
    try { $null = Read-StgConfig $tmp } catch { $placeholderRefused = $_.Exception.Message -match 'network.mode verify requires' }
    Assert-Contract $placeholderRefused 'The example''s placeholder subnet IDs must be refused in verify mode.'
    $c.network.existing = @{ functionsSubnetId = "$vnetPath/functions"; privateEndpointSubnetId = "$vnetPath/private"; apimSubnetId = "$vnetPath/apim" }
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $read = Read-StgConfig $tmp
    Assert-Contract ($read.network.mode -ceq 'verify') 'The example network mode must be verify: the customer builds the network.'
    Assert-Contract ($read.stage1.prefix -ceq 'ccofstg' -and $read.stage1.functionsPublicNetworkAccess -ceq 'Disabled' -and $read.stage1.approveNewPublicApimBootstrap -eq $false) 'Example defaults must stay private and defer APIM.'
    $stage1Parameters = Get-Stage1Parameters $read
    $recordedParameters = @{ properties = @{ parameters = @{} } }
    foreach ($key in $stage1Parameters.Keys) { $recordedParameters.properties.parameters[$key] = @{ value = $stage1Parameters[$key] } }
    Assert-StgStage1Parameters $recordedParameters $read
    $recordedParameters.properties.parameters.storagePublicNetworkAccess.value = 'Enabled'
    $mismatch = $false
    try { Assert-StgStage1Parameters $recordedParameters $read } catch { $mismatch = $_.Exception.Message -match 'stage1_parameters_changed' }
    Assert-Contract $mismatch 'A completed Stage 1 deployment with different parameters must not be adopted.'
    $c.stage1.prefix = 'BAD_PREFIX'; $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'prefix' }
    Assert-Contract $bad 'An invalid prefix must be refused.'
    $c.stage1.prefix = 'ccofstg'
    $c.stage1.foundry.create = $true
    $c.stage1.foundry.modelProviderData = @{ organizationName = 'Example Corp'; countryCode = 'US'; industry = 'Technology' }
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'industry' }
    Assert-Contract $bad 'Anthropic model-provider industry must use a supported lowercase value.'
    $c.stage1.foundry.modelProviderData.industry = 'technology'
    $c.stage1.foundry.deployments[1].name = $c.stage1.foundry.deployments[0].name
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'unique' }
    Assert-Contract $bad 'Duplicate Foundry deployment names must be refused.'
    $c.stage1.foundry.deployments[1].name = 'claude-sonnet-5'
    if (-not $c.entra.existing) { $c.entra.existing = @{} }
    $c.entra.existing.Remove('adminAppId')
    $c.entra.adminEditors = @()
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'adminEditors' }
    Assert-Contract $bad 'A new assignment-required admin app must have at least one editor.'
    $c.entra.existing.adminAppId = '00000000-0000-4000-8000-000000000003'
    $c.entra.adminEditors = @()
    $c.stage1.foundry.create = $false
    $c.network.mode = 'existing'
    $c.network.existing = @{
        privateEndpointSubnetId = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/private'
        functionsSubnetId = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/functions'
        apimSubnetId = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/apim'
        privateDnsZoneIds = @{ cosmos = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com'; blob = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net' }
    }
    $c.backends[0].privateEndpoint = $true
    $c.backends[0].subscriptionId = $c.subscriptionId
    $c.backends[0].resourceGroup = $c.resourceGroup
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'private Foundry.*requires' }
    Assert-Contract $bad 'Existing-network private Foundry configuration must require all three zone IDs.'
} finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
# State is bound to its tenant/subscription/RG: another target's outputs are refused, not reused.
$stateDir = Join-Path ([IO.Path]::GetTempPath()) "staged-state-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $stateDir | Out-Null
try {
    $script:StateDir = $stateDir
    $cfgA = @{
        tenantId = '00000000-0000-4000-8000-00000000000a'
        subscriptionId = '00000000-0000-4000-8000-00000000000b'
        resourceGroup = 'rg-a'
        location = 'eastus2'
        tags = @{}
        sharedResourceGroup = $false
        stage1 = @{ prefix = 'abc123'; includeAdmin = $true }
        cosmos = @{ databaseName = 'ccof'; capacityMode = 'serverless' }
        sync = @{ mode = 'delegated-snapshot' }
        backends = @()
    }
    Save-StgStage $cfgA 1 @{ marker = 'a'; durationSeconds = 1 }
    Assert-Contract ((Get-StgStage $cfgA 1).marker -ceq 'a') 'State must return its own target outputs.'
    $cfgB = $cfgA.Clone()
    $cfgB.subscriptionId = '00000000-0000-4000-8000-00000000000c'
    $mismatch = $false
    try { $null = Get-StgStage $cfgB 1 } catch { $mismatch = $_.Exception.Message -match 'state_target_mismatch' }
    Assert-Contract $mismatch 'State of another subscription must be refused.'
    $cfgA.stage1.prefix = 'xyz789'
    $changed = $false
    try { $null = Get-StgStage $cfgA 1 } catch { $changed = $_.Exception.Message -match 'stage_config_changed' }
    Assert-Contract $changed 'Stage outputs must not be reused after that stage config changes.'
    $cfgA.stage1.prefix = 'abc123'
    # Network-last order: 2 schema, 3 grants (needs 2), 4 Entra, 5 configuration, 6 network, 7 code (needs 6).
    Assert-Contract ((@(Get-StgStageDependencies 3) -join ',') -ceq '1,2') 'Grants (Stage 3) must depend on Stage 1 and the schema (Stage 2).'
    Assert-Contract ((@(Get-StgStageDependencies 6) -join ',') -ceq '1') 'The network (Stage 6) must need only Stage 1 resources.'
    Assert-Contract ((@(Get-StgStageDependencies 7) -join ',') -ceq '1,4,5,6') 'Publishing (Stage 7) must require Entra, configuration and the verified network.'
    foreach ($n in 2..5) { Assert-Contract (@(Get-StgStageDependencies $n) -notcontains 6) "Stage $n must not need the network: it runs before Stage 6." }
    Save-StgStage $cfgA 2 @{ marker = 'schema-a' }
    Save-StgStage $cfgA 3 @{ marker = 'grants-a' }
    Save-StgStage $cfgA 1 @{ marker = 'a'; durationSeconds = 999 }
    Assert-Contract ((Get-StgStage $cfgA 3).marker -ceq 'grants-a') 'A duration-only change must not invalidate dependent stages.'
    Save-StgStage $cfgA 2 @{ marker = 'schema-a'; verify = @{ containers = 9; readAt = 'later' } }
    Assert-Contract ((Get-StgStage $cfgA 3).marker -ceq 'grants-a') 'A changed read-back snapshot (verify) must not invalidate dependent stages.'
    $state = Read-StgState $cfgA
    $legacyOutput = ConvertTo-StgCanonical $state.stages['1'].outputs | ConvertTo-Json -Depth 100 -Compress
    $state.stages['3'].dependencyHashes['1'] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($legacyOutput))).ToLowerInvariant()
    $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Get-StgStatePath $cfgA) -Encoding utf8NoBOM
    $null = Get-StgStage $cfgA 3
    $state = Read-StgState $cfgA
    Assert-Contract ($state.stages['3'].dependencyHashes['1'] -ceq (Get-StgDependencyHashes $state 3)['1']) 'Legacy duration-inclusive dependency hashes must migrate only when the saved output matches exactly.'
    Save-StgStage $cfgA 2 @{ marker = 'schema-b' }
    $dependencyChanged = $false
    try { $null = Get-StgStage $cfgA 3 } catch { $dependencyChanged = $_.Exception.Message -match 'stage_dependency_changed' }
    Assert-Contract $dependencyChanged 'Downstream outputs must not be reused after a prerequisite stage is reapplied.'

    # Layout 1 state (network was Stage 2) moves to the network-last keys, hashes untouched, with a backup.
    $legacyDir = Join-Path $stateDir 'layout1'; New-Item -ItemType Directory -Path $legacyDir | Out-Null
    $script:StateDir = $legacyDir
    $layout1 = @{ schemaVersion = 1; target = (Get-StgTarget $cfgA); stages = @{
        '1' = @{ configHash = 'h1'; outputs = @{ marker = 'resources' } }
        '2' = @{ configHash = 'h2'; dependencyHashes = @{ '1' = 'd1' }; outputs = @{ marker = 'network' } }
        '3' = @{ configHash = 'h3'; dependencyHashes = @{ '1' = 'd1' }; outputs = @{ marker = 'schema' } }
        '4' = @{ configHash = 'h4'; dependencyHashes = @{ '1' = 'd1'; '3' = 'd3' }; outputs = @{ marker = 'grants' } }
        '6' = @{ configHash = 'h6'; dependencyHashes = @{ '1' = 'd1'; '4' = 'd4'; '5' = 'd5' }; outputs = @{ marker = 'config' } }
        '7' = @{ configHash = 'h7'; dependencyHashes = @{ '1' = 'd1'; '2' = 'd2'; '5' = 'd5'; '6' = 'd6' }; outputs = @{ marker = 'code' } } } }
    $layout1 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $legacyDir 'state.json') -Encoding utf8NoBOM
    $moved = Read-StgState $cfgA
    Assert-Contract ($moved.stageLayout -eq 2 -and $moved.stages['6'].outputs.marker -ceq 'network' -and $moved.stages['2'].outputs.marker -ceq 'schema' -and
        $moved.stages['3'].outputs.marker -ceq 'grants' -and $moved.stages['5'].outputs.marker -ceq 'config' -and -not $moved.stages['4']) 'Layout 1 stage keys must move to the network-last numbers.'
    Assert-Contract ((($moved.stages['3'].dependencyHashes.Keys | Sort-Object) -join ',') -ceq '1,2' -and $moved.stages['3'].dependencyHashes['2'] -ceq 'd3') 'Moved dependency hashes must keep their values under the new keys.'
    Assert-Contract ((($moved.stages['7'].dependencyHashes.Keys | Sort-Object) -join ',') -ceq '1,4,5,6' -and $moved.stages['7'].dependencyHashes['6'] -ceq 'd2') 'Stage 7 must keep its network dependency under Stage 6.'
    Assert-Contract (Test-Path -LiteralPath (Join-Path $legacyDir 'state.layout1.json')) 'Layout migration must keep a backup of the original state.'
    Assert-Contract ((Read-StgState $cfgA).stages['6'].outputs.marker -ceq 'network') 'A migrated state must not be migrated twice.'

    # Stage 6 verify mode: the customer network check decides; a FAIL row stops the stage and nothing is created.
    $fakeRepo = Join-Path $stateDir 'repo'; New-Item -ItemType Directory -Path (Join-Path $fakeRepo 'scripts/manual') -Force | Out-Null
    $fakeCheck = Join-Path $fakeRepo 'scripts/manual/Test-NetworkConfiguration.ps1'
    $savedRepo = $script:Repo; $script:Repo = $fakeRepo; $script:StateDir = $stateDir
    try {
        $netCfg = @{ subscriptionId = '00000000-0000-4000-8000-00000000000b'; resourceGroup = 'rg-a'; stage1 = @{ apimSku = 'StandardV2' }
            network = @{ mode = 'verify'; existing = @{ functionsSubnetId = "$vnetPath/functions"; privateEndpointSubnetId = "$vnetPath/private"; apimSubnetId = "$vnetPath/apim" } }
            backends = @(@{ subscriptionId = 's2'; resourceGroup = 'rg-f'; accountName = 'fd1'; privateEndpoint = $true }, @{ subscriptionId = 's2'; resourceGroup = 'rg-f'; accountName = 'fd2'; privateEndpoint = $false }) }
        $stage1Out = @{ cosmosAccountId = '/x/cosmos'; apimName = 'apim1'; apimId = '/x/apim1'
            names = @{ apps = @{ sync = @{ functionApp = 'app-sync'; storageAccount = 'stsync' }; resolver = @{ functionApp = 'app-res'; storageAccount = 'stres' } } } }
        $verifyArgs = Get-StgNetworkVerifyArguments $netCfg $stage1Out
        Assert-Contract ($verifyArgs.VnetResourceId -ceq ($vnetPath -replace '/subnets$', '') -and $verifyArgs.FlexSubnet -ceq 'functions' -and $verifyArgs.PeSubnet -ceq 'private' -and $verifyArgs.ApimSubnet -ceq 'apim') 'Verify mode must check the configured VNet and subnets.'
        Assert-Contract (@($verifyArgs.FunctionAppIds).Count -eq 2 -and @($verifyArgs.StorageAccountIds).Count -eq 2 -and @($verifyArgs.FoundryResourceId).Count -eq 1 -and $verifyArgs.FoundryResourceId[0] -like '*/accounts/fd1') 'Verify mode must check every app, its storage and each private Foundry backend only.'
        $stage1Out.apimName = ''
        Assert-Contract (-not (Get-StgNetworkVerifyArguments $netCfg $stage1Out).Contains('ApimSubnet')) 'Without a Stage 1 Standard v2 APIM, the APIM subnet is not checked.'
        $stage1Out.apimName = 'apim1'
        $fakeBody = @(
            'param([string]$SubscriptionId, [string]$VnetResourceId, [string]$ApimSubnet, [string]$FlexSubnet, [string]$PeSubnet, [string]$CosmosResourceId, [string[]]$StorageAccountIds, [string[]]$FunctionAppIds, [string]$ApimResourceId, [string[]]$FoundryResourceId, [string]$ResultPath)'
            "ConvertTo-Json -InputObject @(@{ Area = 'Subnet'; Item = `$FlexSubnet; State = 'PASS'; Detail = '' }, @{ Area = 'PrivateEndpoint'; Item = 'cosmos [Sql]'; State = 'FAIL'; Detail = 'no private endpoint' }) | Set-Content -LiteralPath `$ResultPath"
            'exit 1')
        Set-Content -LiteralPath $fakeCheck -Encoding utf8NoBOM -Value $fakeBody
        $refused = $false
        try { $null = Invoke-StgNetworkVerify -Cfg $netCfg -Stage1 $stage1Out -Apply } catch { $refused = $_.Exception.Message -match 'verify_failed: the customer network check reported 1 FAIL rows: PrivateEndpoint cosmos' }
        Assert-Contract $refused 'Stage 6 verify must stop on a FAIL row from the network check.'
        Set-Content -LiteralPath $fakeCheck -Encoding utf8NoBOM -Value ($fakeBody -replace "State = 'FAIL'", "State = 'PASS'" -replace '^exit 1$', 'exit 0')
        $ok = Invoke-StgNetworkVerify -Cfg $netCfg -Stage1 $stage1Out -Apply
        Assert-Contract ($ok.mode -ceq 'verify' -and $ok.functionsSubnetId -ceq "$vnetPath/functions" -and $ok.verify.fail -eq 0 -and $ok.verify.pass -eq 2) 'Stage 6 verify must record the subnets and the check result when every row passes.'
    } finally { $script:Repo = $savedRepo }
    # The network check wraps the CLI in a function named Az; a bare `& az` resolves to that function
    # (names are case-insensitive) and recursed forever. Every CLI call must use the resolved executable.
    $checkAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\manual\Test-NetworkConfiguration.ps1'), [ref]$null, [ref]$null)
    $bareAz = @($checkAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Ampersand' -and $n.CommandElements[0].Extent.Text -ieq 'az' }, $true))
    Assert-Contract ($bareAz.Count -eq 0) "Test-NetworkConfiguration.ps1 calls the bare az name, which resolves to its own Az function: $($bareAz.Extent.Text -join '; ')"
    $badVnet = (Get-Content -LiteralPath $example -Raw | ConvertFrom-Json -AsHashtable -Depth 100)
    $badVnet.tenantId = '00000000-0000-4000-8000-000000000001'; $badVnet.subscriptionId = '00000000-0000-4000-8000-000000000002'
    $badVnet.network.existing = @{ functionsSubnetId = "$vnetPath/functions"; privateEndpointSubnetId = ($vnetPath -replace 'vnet/subnets', 'other/subnets') + '/private' }
    $badPath = Join-Path $stateDir 'bad-vnet.json'; $badVnet | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $badPath -Encoding utf8NoBOM
    $refused = $false; try { $null = Read-StgConfig $badPath } catch { $refused = $_.Exception.Message -match 'same VNet' }
    Assert-Contract $refused 'Verify mode must refuse subnets from different VNets.'

    $lockPath = Join-Path $stateDir 'stage7.lock'
    $lock = Enter-StgStage7Lock $lockPath
    $busy = $false
    try { $second = Enter-StgStage7Lock $lockPath; $second.Dispose() } catch { $busy = $_.Exception.Message -match 'stage7_busy' }
    Assert-Contract $busy 'Concurrent Stage 7 package builds must fail fast.'
    $lock.Dispose()
    $reacquired = Enter-StgStage7Lock $lockPath
    Assert-Contract ($null -ne $reacquired) 'Stage 7 lock must be released for a later retry.'
    $reacquired.Dispose()
} finally { Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue }
$s1Params = @($s1.parameters.Keys)
foreach ($k in $c.stage1.Keys) { Assert-Contract ($s1Params -contains $k) "Example stage1.$k is not a Stage 1 template parameter." }

"Staged stages: $passed checks passed (4 stage boundaries, negative control, Cosmos contract, network-last order and layout migration, network verify mode, driver and configuration). No Azure calls."
