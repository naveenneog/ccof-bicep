#Requires -Version 7.0
# Answers-file validation and helpers for infra/sync/Deploy-SyncFunction.ps1.
# Pure functions: no Azure call, so tests/Test-SyncDeploy.ps1 runs them offline.

$script:Guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:SyncSettingNames = @(
    'SYNC_TENANT_ID', 'SYNC_SCHEDULE', 'SYNC_LEASE_SECONDS', 'SYNC_MEMBER_TYPES',
    'SYNC_MAX_REMOVALS_PER_RUN', 'SYNC_MAX_REMOVAL_FRACTION', 'SYNC_GRAPH_MAX_RETRIES',
    'SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS', 'SYNC_GRAPH_TIMEOUT_SECONDS', 'SYNC_WRITE_MODE'
)

# No parentheses anywhere: az.cmd on Windows re-parses ( ) and a valid name would break every call.
function Get-SyncAnswerRules {
    $rid = '^/subscriptions/{0}/resourceGroups/[A-Za-z0-9._-]+/providers/'
    [ordered]@{
        tenantId                   = $script:Guid
        subscriptionId             = $script:Guid
        resourceGroup              = '^[A-Za-z0-9._-]{1,90}$'
        location                   = '^[a-z0-9]{2,40}$'
        deploymentName             = '^[A-Za-z0-9._-]{1,64}$'
        functionAppName            = '^[a-z0-9][a-z0-9-]{0,58}[a-z0-9]$'
        planName                   = '^[A-Za-z0-9][A-Za-z0-9-]{0,58}[A-Za-z0-9]$'
        storageAccountName         = '^[a-z0-9]{3,24}$'
        storageSku                 = '^(Standard_LRS|Standard_ZRS)$'
        deploymentContainerName    = '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'
        storagePrivateEndpointName = '^[A-Za-z0-9][A-Za-z0-9._-]{0,78}[A-Za-z0-9_]$'
        appInsightsName            = '^[A-Za-z0-9][A-Za-z0-9._-]{0,253}$'
        logAnalyticsWorkspaceId    = ($rid + 'Microsoft\.OperationalInsights/workspaces/[A-Za-z0-9-]+$')
        identityName               = '^[A-Za-z0-9][A-Za-z0-9_-]{1,127}$'
        identityPrincipalId        = $script:Guid
        integrationSubnetId        = ($rid + 'Microsoft\.Network/virtualNetworks/[A-Za-z0-9._-]+/subnets/[A-Za-z0-9.-]+$')
        privateEndpointSubnetId    = ($rid + 'Microsoft\.Network/virtualNetworks/[A-Za-z0-9._-]+/subnets/[A-Za-z0-9._-]+$')
        blobPrivateDnsZoneId       = ($rid + 'Microsoft\.Network/privateDnsZones/privatelink\.blob\.core\.windows\.net$')
        cosmosAccountName          = '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'
        cosmosDatabaseName         = '^[A-Za-z0-9][A-Za-z0-9_-]{0,254}$'
        projectsContainerName      = '^[A-Za-z0-9][A-Za-z0-9_-]{0,254}$'
        entitlementContainerName   = '^[A-Za-z0-9][A-Za-z0-9_-]{0,254}$'
        leaseContainerName         = '^[A-Za-z0-9][A-Za-z0-9_-]{0,254}$'
        cosmosWriterRoleName       = '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$'
        decisionSource             = '^\S.{0,199}$'
    }
}

function Read-SyncAnswers {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Answers file not found: $Path" }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

# Returns the problems as "<key>:<code>" strings; empty when the answers are complete and valid.
function Test-SyncAnswers {
    param([Parameter(Mandatory)] [AllowNull()] $Answers)
    if ($Answers -isnot [System.Collections.IDictionary]) { return @('answers:not_an_object') }
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($Answers['schemaVersion'] -ne 1) { $problems.Add('schemaVersion:unsupported') }
    $rules = Get-SyncAnswerRules
    $subscription = [string]$Answers['subscriptionId']
    foreach ($key in $rules.Keys) {
        $value = $Answers[$key]
        # Resource ids must be in the answers' subscription. Replace, not -f: the patterns contain {n,m}.
        $pattern = $rules[$key].Replace('{0}', [regex]::Escape($subscription))
        if ($null -eq $value -or $value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { $problems.Add("${key}:missing"); continue }
        if ($value -notmatch $pattern) { $problems.Add("${key}:invalid") }
    }
    # Fixed by docs/LLD.md §1 and C-9 D2, and named in infra/sync/sync.assignments.json (D3).
    foreach ($pair in @(@('projectsContainerName', 'projects'), @('entitlementContainerName', 'entitlement'), @('leaseContainerName', 'syncLease'))) {
        if ($Answers[$pair[0]] -is [string] -and -not [string]::Equals($Answers[$pair[0]], $pair[1], 'Ordinal')) { $problems.Add("$($pair[0]):not_the_registry_name") }
    }
    foreach ($key in @('alwaysReadyInstanceCount', 'maximumInstanceCount', 'instanceMemoryMB')) {
        $value = $Answers[$key]
        if ($null -eq $value) { $problems.Add("${key}:missing"); continue }
        if ($value -isnot [long] -and $value -isnot [int]) { $problems.Add("${key}:invalid"); continue }
        $ok = switch ($key) {
            'alwaysReadyInstanceCount' { $value -ge 0 -and $value -le 1000 }
            'maximumInstanceCount' { $value -ge 1 -and $value -le 1000 }
            'instanceMemoryMB' { $value -in @(512, 2048, 4096) }
        }
        if (-not $ok) { $problems.Add("${key}:out_of_range") }
    }
    foreach ($key in @('zoneRedundant', 'timerEnabled')) {
        if ($null -eq $Answers[$key]) { $problems.Add("${key}:missing") }
        elseif ($Answers[$key] -isnot [bool]) { $problems.Add("${key}:invalid") }
    }
    $graph = $Answers['graphPermission']
    if ($graph -isnot [System.Collections.IDictionary]) { $problems.Add('graphPermission:missing') }
    else {
        foreach ($key in @('graphServicePrincipalId', 'appRoleId')) {
            if ([string]$graph[$key] -notmatch $script:Guid) { $problems.Add("graphPermission.${key}:invalid") }
        }
    }
    $settings = $Answers['syncSettings']
    if ($settings -isnot [System.Collections.IDictionary]) { $problems.Add('syncSettings:missing') }
    else {
        foreach ($name in $script:SyncSettingNames) {
            if (-not $settings.Contains($name)) { $problems.Add("syncSettings.${name}:missing") }
            elseif ($settings[$name] -isnot [string]) { $problems.Add("syncSettings.${name}:not_a_string") }
        }
        foreach ($name in $settings.Keys) {
            if ($name -notin $script:SyncSettingNames) { $problems.Add("syncSettings.${name}:unexpected") }
        }
        if ($settings['SYNC_TENANT_ID'] -is [string] -and -not [string]::Equals($settings['SYNC_TENANT_ID'], [string]$Answers['tenantId'], 'OrdinalIgnoreCase')) {
            $problems.Add('syncSettings.SYNC_TENANT_ID:not_the_answers_tenant')
        }
    }
    return , $problems.ToArray()
}

# The full set of sync settings the app will see, for validation by the app's own code (src/sync/config.ts).
function Get-SyncAppSettings {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Answers)
    $settings = [ordered]@{
        COSMOS_ENDPOINT            = "https://$($Answers.cosmosAccountName).documents.azure.com:443/"
        COSMOS_DATABASE            = $Answers.cosmosDatabaseName
        SYNC_PROJECTS_CONTAINER    = $Answers.projectsContainerName
        SYNC_ENTITLEMENT_CONTAINER = $Answers.entitlementContainerName
        SYNC_LEASE_CONTAINER       = $Answers.leaseContainerName
    }
    foreach ($name in $script:SyncSettingNames) { $settings[$name] = $Answers.syncSettings[$name] }
    return $settings
}

function ConvertTo-SyncDeploymentParameters {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Answers)
    # D1 resource creation only (infra/sync/sync-resources.bicep): no settings, no role, no Cosmos object.
    $names = @('location', 'functionAppName', 'planName', 'storageAccountName', 'storageSku', 'deploymentContainerName',
        'storagePrivateEndpointName', 'appInsightsName', 'logAnalyticsWorkspaceId', 'identityName', 'integrationSubnetId',
        'privateEndpointSubnetId', 'blobPrivateDnsZoneId', 'alwaysReadyInstanceCount', 'maximumInstanceCount',
        'instanceMemoryMB', 'zoneRedundant')
    $parameters = [ordered]@{}
    foreach ($name in $names) { $parameters[$name] = @{ value = $Answers[$name] } }
    [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $parameters
    }
}

# One JSON line per step: ids, actions and outcomes only.
function Write-SyncAudit {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [System.Collections.IDictionary] $Record)
    $line = [ordered]@{ schema = 'ccof.sync.setup.v1'; at = [DateTime]::UtcNow.ToString('o') }
    foreach ($key in $Record.Keys) { $line[$key] = $Record[$key] }
    Add-Content -Force -LiteralPath $Path -Value ($line | ConvertTo-Json -Compress -Depth 6) -Encoding utf8NoBOM
}

Export-ModuleMember -Function Read-SyncAnswers, Test-SyncAnswers, Get-SyncAppSettings, ConvertTo-SyncDeploymentParameters, Write-SyncAudit
