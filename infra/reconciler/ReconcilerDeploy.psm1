#Requires -Version 7.0
# Answers-file validation and helpers for infra/reconciler/Deploy-Reconciler.ps1.
# Pure functions: no Azure call, so tests/Test-ReconcilerDeploy.ps1 runs them offline.
# Mirrors infra/sync/SyncDeploy.psm1 (WP-SYNC).

$script:Guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# The administrator's per-run decisions; every other setting is derived from the answers.
$script:ReconcilerSettingNames = @(
    'RECONCILER_SCHEDULE', 'RECONCILER_VALIDITY_SECONDS', 'RECONCILER_LEASE_SECONDS',
    'RECONCILER_LEDGER_TIMEOUT_SECONDS', 'RECONCILER_LEDGER_MAX_ROWS', 'RECONCILER_MAX_STATES',
    'RECONCILER_WRITE_CONCURRENCY'
)

function Get-ReconcilerAnswerRules {
    $rid = '^/subscriptions/{0}/resourceGroups/[A-Za-z0-9._-]+/providers/'
    $container = '^[A-Za-z0-9][A-Za-z0-9_-]{0,254}$'
    [ordered]@{
        tenantId                        = $script:Guid
        subscriptionId                  = $script:Guid
        resourceGroup                   = '^[A-Za-z0-9._-]{1,90}$'
        location                        = '^[a-z0-9]{2,40}$'
        deploymentName                  = '^[A-Za-z0-9._-]{1,64}$'
        functionAppName                 = '^[a-z0-9][a-z0-9-]{0,58}[a-z0-9]$'
        planName                        = '^[A-Za-z0-9][A-Za-z0-9-]{0,58}[A-Za-z0-9]$'
        storageAccountName              = '^[a-z0-9]{3,24}$'
        storageSku                      = '^(Standard_LRS|Standard_ZRS)$'
        deploymentContainerName         = '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'
        storagePrivateEndpointName      = '^[A-Za-z0-9][A-Za-z0-9._-]{0,78}[A-Za-z0-9_]$'
        identityName                    = '^[A-Za-z0-9][A-Za-z0-9_-]{1,127}$'
        integrationSubnetId             = ($rid + 'Microsoft\.Network/virtualNetworks/[A-Za-z0-9._-]+/subnets/[A-Za-z0-9._-]+$')
        privateEndpointSubnetId         = ($rid + 'Microsoft\.Network/virtualNetworks/[A-Za-z0-9._-]+/subnets/[A-Za-z0-9._-]+$')
        blobPrivateDnsZoneId            = ($rid + 'Microsoft\.Network/privateDnsZones/privatelink\.blob\.core\.windows\.net$')
        logAnalyticsWorkspaceId         = ($rid + 'Microsoft\.OperationalInsights/workspaces/[A-Za-z0-9-]+$')
        logAnalyticsWorkspaceCustomerId = $script:Guid
        logAnalyticsEndpoint            = '^https://[a-z0-9.-]+$'
        gatewayResourceId               = ($rid + 'Microsoft\.ApiManagement/service/[A-Za-z0-9-]+$')
        cosmosAccountName               = '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'
        cosmosDatabaseName              = $container
        projectsContainerName           = $container
        entitlementContainerName        = $container
        budgetStateContainerName        = $container
        aggregateStateContainerName     = $container
        leaseContainerName              = $container
        cosmosWriterRoleName            = '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$'
        decisionSource                  = '^\S.{0,199}$'
    }
}

function Read-ReconcilerAnswers {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Answers file not found: $Path" }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

# Returns the problems as "<key>:<code>" strings; empty when the answers are complete and valid.
function Test-ReconcilerAnswers {
    param([Parameter(Mandatory)] [AllowNull()] $Answers)
    if ($Answers -isnot [System.Collections.IDictionary]) { return @('answers:not_an_object') }
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($Answers['schemaVersion'] -ne 1) { $problems.Add('schemaVersion:unsupported') }
    $rules = Get-ReconcilerAnswerRules
    $subscription = [string]$Answers['subscriptionId']
    foreach ($key in $rules.Keys) {
        $value = $Answers[$key]
        # Resource ids must be in the answers' subscription. Replace, not -f: the patterns contain {n,m}.
        # \z, not $: .NET's $ also matches before a trailing newline.
        $pattern = $rules[$key].Replace('{0}', [regex]::Escape($subscription))
        if ($pattern.EndsWith('$')) { $pattern = $pattern.Substring(0, $pattern.Length - 1) + '\z' }
        if ($null -eq $value -or $value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { $problems.Add("${key}:missing"); continue }
        if ($value -cnotmatch $pattern) { $problems.Add("${key}:invalid") }
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
    $settings = $Answers['reconcilerSettings']
    if ($settings -isnot [System.Collections.IDictionary]) { $problems.Add('reconcilerSettings:missing') }
    else {
        foreach ($name in $script:ReconcilerSettingNames) {
            if (-not $settings.Contains($name)) { $problems.Add("reconcilerSettings.${name}:missing") }
            elseif ($settings[$name] -isnot [string]) { $problems.Add("reconcilerSettings.${name}:not_a_string") }
        }
        foreach ($name in $settings.Keys) {
            if ($name -notin $script:ReconcilerSettingNames) { $problems.Add("reconcilerSettings.${name}:unexpected") }
        }
    }
    return , $problems.ToArray()
}

# Every app setting the reconciler app gets (D2): host settings for the identity-based
# storage, the role gate, the timer switch, and the settings src/reconciler/settings.ts reads.
function Get-ReconcilerAppSettings {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Answers,
        [Parameter(Mandatory)] [string] $IdentityClientId
    )
    $settings = [ordered]@{
        AzureWebJobsStorage__accountName        = $Answers.storageAccountName
        AzureWebJobsStorage__credential         = 'managedidentity'
        AzureWebJobsStorage__clientId           = $IdentityClientId
        CCOF_APP_ROLE                           = 'reconciler'
        'AzureWebJobs.reconcileBudgets.Disabled' = if ($Answers.timerEnabled) { 'false' } else { 'true' }
        RECONCILER_MANAGED_IDENTITY_CLIENT_ID   = $IdentityClientId
        RECONCILER_LOG_ANALYTICS_WORKSPACE_ID   = $Answers.logAnalyticsWorkspaceCustomerId
        RECONCILER_LOG_ANALYTICS_ENDPOINT       = $Answers.logAnalyticsEndpoint
        RECONCILER_LEDGER_GATEWAY_RESOURCE_ID   = $Answers.gatewayResourceId
        COSMOS_ENDPOINT                         = "https://$($Answers.cosmosAccountName).documents.azure.com:443/"
        COSMOS_DATABASE                         = $Answers.cosmosDatabaseName
        RECONCILER_PROJECTS_CONTAINER           = $Answers.projectsContainerName
        RECONCILER_ENTITLEMENT_CONTAINER        = $Answers.entitlementContainerName
        RECONCILER_BUDGET_STATE_CONTAINER       = $Answers.budgetStateContainerName
        RECONCILER_AGGREGATE_STATE_CONTAINER    = $Answers.aggregateStateContainerName
        RECONCILER_LEASE_CONTAINER              = $Answers.leaseContainerName
    }
    foreach ($name in $script:ReconcilerSettingNames) { $settings[$name] = $Answers.reconcilerSettings[$name] }
    return $settings
}

function ConvertTo-ReconcilerDeploymentParameters {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Answers)
    $names = @('location', 'functionAppName', 'planName', 'storageAccountName', 'storageSku', 'deploymentContainerName',
        'storagePrivateEndpointName', 'identityName', 'integrationSubnetId', 'privateEndpointSubnetId', 'blobPrivateDnsZoneId',
        'alwaysReadyInstanceCount', 'maximumInstanceCount', 'instanceMemoryMB', 'zoneRedundant')
    $parameters = [ordered]@{}
    foreach ($name in $names) { $parameters[$name] = @{ value = $Answers[$name] } }
    [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $parameters
    }
}

# The D3 data (reconciler-permissions.json) with every ${...} placeholder resolved from $Values.
# Each placeholder has the shape of what it stands for (a GUID, an ARM id of the expected type, a
# name), checked to the end of the string (\z: .NET's $ would accept a trailing newline). Refuses
# when one does not resolve or does not fit, so nothing is granted on a partial or widened scope.
$script:PlaceholderShapes = @{
    'd1.apps.reconciler.principalId'             = $script:Guid.Replace('$', '\z')
    'd1.apps.reconciler.storageAccountId'        = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]+/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}\z'
    'd1.workspace.id'                            = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]+/providers/Microsoft\.OperationalInsights/workspaces/[A-Za-z0-9-]+\z'
    'answers.names.cosmosDatabase'               = '^[A-Za-z0-9][A-Za-z0-9_-]{0,254}\z'
    'answers.names.cosmosRoles.reconcilerWriter' = '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}\z'
}

function Resolve-ReconcilerPermissions {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Data,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values
    )
    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $resolved = [regex]::Replace($json, '\$\{([A-Za-z0-9_.]+)\}', {
            param($m)
            $key = $m.Groups[1].Value
            $shape = $script:PlaceholderShapes[$key]
            if ($shape -and $Values.Contains($key) -and $Values[$key] -is [string] -and $Values[$key] -cmatch $shape) { return $Values[$key] }
            $unresolved.Add($key)
            return $m.Value
        })
    if ($unresolved.Count -gt 0) { throw "Unresolved placeholders in the permissions data: $(($unresolved | Sort-Object -Unique) -join ', ')" }
    return $resolved | ConvertFrom-Json -AsHashtable
}

# A stable GUID for a name, so a repeated run finds what it created instead of adding a duplicate.
function New-ReconcilerStableGuid {
    param([Parameter(Mandatory)] [string] $Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text))
    $bytes = $hash[0..15]
    $bytes[7] = ($bytes[7] -band 0x0F) -bor 0x50
    $bytes[8] = ($bytes[8] -band 0x3F) -bor 0x80
    return ([guid]::new([byte[]]$bytes)).ToString()
}

# One JSON line per step: ids, actions and outcomes only.
function Write-ReconcilerAudit {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [System.Collections.IDictionary] $Record)
    $line = [ordered]@{ schema = 'ccof.reconciler.setup.v1'; at = [DateTime]::UtcNow.ToString('o') }
    foreach ($key in $Record.Keys) { $line[$key] = $Record[$key] }
    Add-Content -LiteralPath $Path -Value ($line | ConvertTo-Json -Compress -Depth 6) -Encoding utf8NoBOM
}

Export-ModuleMember -Function Read-ReconcilerAnswers, Test-ReconcilerAnswers, Get-ReconcilerAppSettings, ConvertTo-ReconcilerDeploymentParameters, Resolve-ReconcilerPermissions, New-ReconcilerStableGuid, Write-ReconcilerAudit
