#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys, packages, enables or rolls back the group-sync Function App (docs/SYNC.md, ADR-0016).

.DESCRIPTION
    Every value comes from the answers file (-AnswersFile), validated before any Azure call by
    infra/sync/SyncDeploy.psm1 and by the app's own validator (src/sync/config.ts). The script never
    signs in, never switches subscription, and passes --subscription to every command. Each step
    writes one JSON audit line (ids and outcomes only) to -AuditPath.

    Proof-of-concept tool. The authoritative stage scripts are WP-CORE's (D1-D3); the actions below
    follow the same checkpointed stages of docs/PILOT.md C-9:
      Validate     offline checks only
      WhatIf       D1: Validate, then ARM what-if of infra/sync/sync-resources.bicep; no change
      Deploy       D1: WhatIf, then the deployment (resources only: no settings, roles or Cosmos objects)
      Schema       D2: the lease container in the existing Cosmos database
      Settings     D2: every app setting (host, sync, timer switch); checks the Graph grant first
                   when timerEnabled is true
      Package      D2: build dist/sync, stage it with production dependencies, deploy with OneDeploy
      EnableTimer  D3 last step: check the Graph app role assignment exists, then enable the timer
      Rollback     delete what the sync added (needs -ConfirmRollback); entitlement documents stay
    D3's role and data-plane assignments are data, infra/sync/sync.assignments.json, applied by the
    D3 permissions script (WP-CORE).

.EXAMPLE
    pwsh -NoProfile -File infra/sync/Deploy-SyncFunction.ps1 -AnswersFile infra/sync/sync.answers.pilot.json -Action WhatIf -AuditPath .env.sync-audit.jsonl
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AnswersFile,
    [Parameter(Mandatory)] [ValidateSet('Validate', 'WhatIf', 'Deploy', 'Schema', 'Settings', 'Package', 'EnableTimer', 'Rollback')] [string] $Action,
    [Parameter(Mandatory)] [string] $AuditPath,
    [switch] $ConfirmRollback
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'SyncDeploy.psm1') -Force

function Stop-Sync {
    param([string] $Message, [string] $Reason)
    Write-SyncAudit -Path $AuditPath -Record ([ordered]@{ action = $Action; outcome = 'refused'; reason = $Reason })
    throw $Message
}

function Invoke-Az {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0..2] -join ' ') failed: $(($output | Select-Object -Last 3) -join ' ')" }
    return ($output | Where-Object { $_ -is [string] }) -join "`n"
}

# The identity's Graph token is cached about 24 hours: a run before the grant would keep a token
# without the role in use (Learn, "Best practice recommendations for managed system identities",
# retrieved 2026-10-11). Every path that can enable the timer checks the grant first.
function Assert-SyncGraphGrant {
    $url = "https://graph.microsoft.com/v1.0/servicePrincipals/$($answers.identityPrincipalId)/appRoleAssignments"
    $assignments = (Invoke-Az @('rest', '--method', 'get', '--url', $url, '-o', 'json') | ConvertFrom-Json).value
    $grant = @($assignments | Where-Object {
            [string]::Equals($_.appRoleId, $answers.graphPermission.appRoleId, 'OrdinalIgnoreCase') -and
            [string]::Equals($_.resourceId, $answers.graphPermission.graphServicePrincipalId, 'OrdinalIgnoreCase')
        })
    if ($grant.Count -eq 0) { Stop-Sync 'The Graph app role is not assigned to the sync identity, so the timer stays disabled. A Privileged Role Administrator or Global Administrator grants it first (docs/PILOT.md, owner action 1); or set timerEnabled to false.' 'graph_permission_missing' }
    return $grant[0]
}

# Offline validation: the answers, then the app's own validator over the settings the app will see.
$answers = Read-SyncAnswers -Path $AnswersFile
$problems = Test-SyncAnswers $answers
if ($problems.Count -gt 0) { Stop-Sync "The answers file is incomplete or invalid: $($problems -join ', ')" 'answers_invalid' }
Push-Location $repoRoot
try {
    npx tsc -p tsconfig.json | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Sync 'The TypeScript build failed; run npm ci and npx tsc -p tsconfig.json.' 'build_failed' }
    $settingsFile = Join-Path $repoRoot '.env.sync-validate.json'
    Get-SyncAppSettings $answers | ConvertTo-Json | Set-Content -Force -LiteralPath $settingsFile -Encoding utf8NoBOM
    $check = "import { readSyncConfig } from './dist/sync/config.js'; import { readFileSync } from 'node:fs'; const r = readSyncConfig(JSON.parse(readFileSync(process.argv[1], 'utf8'))); console.log(r.ok ? 'ok' : r.problems.map((p) => p.setting + ':' + p.problem).join(', '));"
    $verdict = node --input-type=module -e $check $settingsFile
    Remove-Item -Force -LiteralPath $settingsFile -ErrorAction SilentlyContinue
    if ($verdict -ne 'ok') { Stop-Sync "The sync settings are refused by the app's validator: $verdict" 'settings_invalid' }
}
finally { Pop-Location }
$sub = $answers.subscriptionId
$rg = $answers.resourceGroup
Write-SyncAudit -Path $AuditPath -Record ([ordered]@{ action = 'validate'; outcome = 'succeeded'; subscriptionId = $sub; resourceGroup = $rg; decisionSource = $answers.decisionSource })
if ($Action -eq 'Validate') { return }

# The signed-in tenant must be the answers' tenant; the subscription is passed explicitly, never set.
$tenant = Invoke-Az @('account', 'show', '--subscription', $sub, '--query', 'tenantId', '-o', 'tsv')
if (-not [string]::Equals($tenant.Trim(), $answers.tenantId, 'OrdinalIgnoreCase')) {
    Stop-Sync "The Azure CLI login is in tenant $($tenant.Trim()), not the answers' tenant $($answers.tenantId). Sign in to that tenant with your own profile, then rerun." 'tenant_mismatch'
}

$template = Join-Path $PSScriptRoot 'sync-resources.bicep'
$paramsFile = Join-Path $repoRoot '.env.sync-parameters.json'
$appSettingsFile = Join-Path $repoRoot '.env.sync-appsettings.json'
try {
    switch ($Action) {
        { $_ -in 'WhatIf', 'Deploy' } {
            ConvertTo-SyncDeploymentParameters $answers | ConvertTo-Json -Depth 8 | Set-Content -Force -LiteralPath $paramsFile -Encoding utf8NoBOM
            $whatIf = Invoke-Az @('deployment', 'group', 'what-if', '--subscription', $sub, '--resource-group', $rg, '--name', $answers.deploymentName,
                '--template-file', $template, '--parameters', "@$paramsFile", '--no-pretty-print', '-o', 'json')
            $changes = ($whatIf | ConvertFrom-Json).changes
            $summary = $changes | Group-Object changeType | ForEach-Object { "$($_.Name)=$($_.Count)" }
            $changes | ForEach-Object { '{0,-8} {1}' -f $_.changeType, $_.resourceId } | Write-Output
            Write-SyncAudit -Path $AuditPath -Record ([ordered]@{ action = 'what-if'; outcome = 'succeeded'; deploymentName = $answers.deploymentName; changes = ($summary -join ',') })
            if ($Action -eq 'WhatIf') { return }
            $outputs = Invoke-Az @('deployment', 'group', 'create', '--subscription', $sub, '--resource-group', $rg, '--name', $answers.deploymentName,
                '--template-file', $template, '--parameters', "@$paramsFile", '--query', 'properties.outputs', '-o', 'json') | ConvertFrom-Json
            Write-SyncAudit -Path $AuditPath -Record ([ordered]@{ action = 'deploy'; outcome = 'succeeded'; deploymentName = $answers.deploymentName; functionAppId = $outputs.functionAppId.value; storageAccountId = $outputs.storageAccountId.value; appInsightsId = $outputs.appInsightsId.value; principalId = $outputs.principalId.value })
            Write-Output "D1 done. Record the ids above; then D3 applies infra/sync/sync.assignments.json, and D2 runs -Action Schema, Settings and Package."
        }
        'Package' {
            $stage = Join-Path $repoRoot '.env.sync-package'
            $zip = Join-Path $repoRoot '.env.sync-package.zip'
            Remove-Item -LiteralPath $stage, $zip -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path (Join-Path $stage 'dist') | Out-Null
            Copy-Item -Path (Join-Path $repoRoot 'dist/sync') -Destination (Join-Path $stage 'dist/sync') -Recurse
            # The sync's own host.json: Application Insights sampling never drops a run or refusal line.
            Copy-Item -Path (Join-Path $PSScriptRoot 'host.json'), (Join-Path $repoRoot 'package-lock.json') -Destination $stage
            # Only the sync's entry point: the repository's "main" glob would also load the resolver.
            $package = Get-Content (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json -AsHashtable
            $package.main = 'dist/sync/function-app.js'
            $package | ConvertTo-Json -Depth 10 | Set-Content -Force -LiteralPath (Join-Path $stage 'package.json') -Encoding utf8NoBOM
            Push-Location $stage
            try { npm ci --omit=dev --no-audit --no-fund --quiet | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'npm ci --omit=dev failed in the package stage' } }
            finally { Pop-Location }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
            $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            # Flex Consumption deploys only through OneDeploy, which replaces the whole package (U-14).
            Invoke-Az @('functionapp', 'deployment', 'source', 'config-zip', '--subscription', $sub, '--resource-group', $rg, '--name', $answers.functionAppName, '--src', $zip) | Out-Null
            Write-SyncAudit -Path $AuditPath -Record ([ordered]@{ action = 'package'; outcome = 'succeeded'; functionAppName = $answers.functionAppName; packageSha256 = $hash })
            Remove-Item -LiteralPath $stage, $zip -Recurse -Force -ErrorAction SilentlyContinue
            Write-Output "Deployed package sha256 $hash to $($answers.functionAppName)."
        }
        'Schema' {
            $account = @('--subscription', $sub, '--resource-group', $rg, '--account-name', $answers.cosmosAccountName, '--database-name', $answers.cosmosDatabaseName)
            $existing = Invoke-Az (@('cosmosdb', 'sql', 'container', 'list') + $account + @('--query', '[].name', '-o', 'json')) | ConvertFrom-Json
            if ($existing -contains $answers.leaseContainerName) { Write-Output "Lease container $($answers.leaseContainerName) exists." }
            else { Invoke-Az (@('cosmosdb', 'sql', 'container', 'create') + $account + @('--name', $answers.leaseContainerName, '--partition-key-path', '/id', '-o', 'none')) | Out-Null }
            Write-SyncAudit -Path $AuditPath -Record ([ordered]@{ action = 'schema'; outcome = 'succeeded'; leaseContainer = $answers.leaseContainerName; created = -not ($existing -contains $answers.leaseContainerName) })
        }
        'Settings' {
            if ($answers.timerEnabled) { Assert-SyncGraphGrant | Out-Null }
            $aiId = Invoke-Az @('resource', 'show', '--subscription', $sub, '--resource-group', $rg, '--resource-type', 'Microsoft.Insights/components', '--name', $answers.appInsightsName, '--query', 'id', '-o', 'tsv')
            $connection = Invoke-Az @('resource', 'show', '--ids', $aiId.Trim(), '--query', 'properties.ConnectionString', '-o', 'tsv')
            $clientId = (Invoke-Az @('identity', 'show', '--subscription', $sub, '--resource-group', $rg, '--name', $answers.identityName, '--query', 'clientId', '-o', 'tsv')).Trim()
            $values = [ordered]@{
                AzureWebJobsStorage__accountName          = $answers.storageAccountName
                AzureWebJobsStorage__credential           = 'managedidentity'
                AzureWebJobsStorage__clientId             = $clientId
                APPLICATIONINSIGHTS_CONNECTION_STRING     = $connection.Trim()
                APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "Authorization=AAD;ClientId=$clientId"
                CCOF_APP_ROLE                             = 'sync'
                SYNC_MANAGED_IDENTITY_CLIENT_ID           = $clientId
            }
            foreach ($entry in (Get-SyncAppSettings $answers).GetEnumerator()) { $values[$entry.Key] = $entry.Value }
            $values['AzureWebJobs.syncEntitlement.Disabled'] = if ($answers.timerEnabled) { 'false' } else { 'true' }
            $values | ConvertTo-Json | Set-Content -Force -LiteralPath $appSettingsFile -Encoding utf8NoBOM
            Invoke-Az @('functionapp', 'config', 'appsettings', 'set', '--subscription', $sub, '--resource-group', $rg, '--name', $answers.functionAppName, '--settings', "@$appSettingsFile", '-o', 'none') | Out-Null
            Write-SyncAudit -Path $AuditPath -Record ([ordered]@{ action = 'settings'; outcome = 'succeeded'; functionAppName = $answers.functionAppName; writeMode = $answers.syncSettings.SYNC_WRITE_MODE; timerEnabled = $answers.timerEnabled })
        }
        'EnableTimer' {
            if (-not $answers.timerEnabled) { Stop-Sync 'Set timerEnabled to true in the answers file first, so a later Deploy keeps the timer on.' 'answers_timer_disabled' }
            $grant = Assert-SyncGraphGrant
            Invoke-Az @('functionapp', 'config', 'appsettings', 'set', '--subscription', $sub, '--resource-group', $rg, '--name', $answers.functionAppName, '--settings', 'AzureWebJobs.syncEntitlement.Disabled=false', '-o', 'none') | Out-Null
            Write-SyncAudit -Path $AuditPath -Record ([ordered]@{ action = 'enable-timer'; outcome = 'succeeded'; functionAppName = $answers.functionAppName; grantCreated = $grant.createdDateTime })
        }
        'Rollback' {
            if (-not $ConfirmRollback) { Stop-Sync 'Rollback deletes the sync app and its access; rerun with -ConfirmRollback. Entitlement documents are kept and still served (ADR-0008).' 'rollback_not_confirmed' }
            $steps = @(
                @('functionapp', 'delete', '--subscription', $sub, '--resource-group', $rg, '--name', $answers.functionAppName),
                @('appservice', 'plan', 'delete', '--subscription', $sub, '--resource-group', $rg, '--name', $answers.planName, '--yes'),
                @('resource', 'delete', '--subscription', $sub, '--resource-group', $rg, '--resource-type', 'Microsoft.Insights/components', '--name', $answers.appInsightsName),
                @('network', 'private-endpoint', 'delete', '--subscription', $sub, '--resource-group', $rg, '--name', $answers.storagePrivateEndpointName),
                @('storage', 'account', 'delete', '--subscription', $sub, '--resource-group', $rg, '--name', $answers.storageAccountName, '--yes')
            )
            foreach ($step in $steps) { Invoke-Az $step | Out-Null; Write-SyncAudit -Path $AuditPath -Record ([ordered]@{ action = 'rollback'; outcome = 'succeeded'; step = ($step[0..1] -join ' ') }) }
            $account = @('--subscription', $sub, '--resource-group', $rg, '--account-name', $answers.cosmosAccountName)
            $assignments = Invoke-Az (@('cosmosdb', 'sql', 'role', 'assignment', 'list') + $account + @('-o', 'json')) | ConvertFrom-Json
            foreach ($a in $assignments | Where-Object { [string]::Equals($_.principalId, $answers.identityPrincipalId, 'OrdinalIgnoreCase') }) {
                Invoke-Az (@('cosmosdb', 'sql', 'role', 'assignment', 'delete') + $account + @('--role-assignment-id', $a.name, '--yes')) | Out-Null
            }
            # The custom role goes only when no other principal (a private runner) still uses it.
            $remaining = Invoke-Az (@('cosmosdb', 'sql', 'role', 'assignment', 'list') + $account + @('-o', 'json')) | ConvertFrom-Json
            $definitions = Invoke-Az (@('cosmosdb', 'sql', 'role', 'definition', 'list') + $account + @('-o', 'json')) | ConvertFrom-Json
            foreach ($d in $definitions | Where-Object { [string]::Equals($_.roleName, $answers.cosmosWriterRoleName, 'Ordinal') }) {
                if (@($remaining | Where-Object { $_.roleDefinitionId -like "*/$($d.name)" }).Count -gt 0) { Write-Output "Kept role $($d.roleName): still assigned."; continue }
                Invoke-Az (@('cosmosdb', 'sql', 'role', 'definition', 'delete') + $account + @('--id', $d.name, '--yes')) | Out-Null
            }
            Invoke-Az (@('cosmosdb', 'sql', 'container', 'delete') + $account + @('--database-name', $answers.cosmosDatabaseName, '--name', $answers.leaseContainerName, '--yes')) | Out-Null
            Write-SyncAudit -Path $AuditPath -Record ([ordered]@{ action = 'rollback'; outcome = 'succeeded'; step = 'cosmos access and lease container' })
            Write-Output 'Rolled back. The entitlement documents are unchanged and the resolver keeps serving them (ADR-0008).'
        }
    }
}
finally {
    Remove-Item -Force -LiteralPath $paramsFile, $appSettingsFile -ErrorAction SilentlyContinue
}
