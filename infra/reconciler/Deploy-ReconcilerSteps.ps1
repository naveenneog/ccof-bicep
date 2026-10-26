#Requires -Version 7.0
# The Azure steps of infra/reconciler/Deploy-Reconciler.ps1, dot-sourced by it after the offline
# validation; they use its $sub, $rg, $repoRoot, $AuditPath, Invoke-Az and Stop-Reconciler.

function Get-ReconcilerIdentity {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Answers)
    $json = Invoke-Az @('identity', 'show', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.identityName, '-o', 'json')
    return $json | ConvertFrom-Json
}

function Invoke-ReconcilerResources {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Answers, [switch] $Apply, [switch] $ConfirmChanges)
    $template = Join-Path $PSScriptRoot 'reconciler-resources.bicep'
    $paramsFile = Join-Path $repoRoot '.env.rec-parameters.json'
    try {
        ConvertTo-ReconcilerDeploymentParameters $Answers | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $paramsFile -Encoding utf8NoBOM
        $whatIf = Invoke-Az @('deployment', 'group', 'what-if', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.deploymentName,
            '--template-file', $template, '--parameters', "@$paramsFile", '--no-pretty-print', '-o', 'json')
        $changes = ($whatIf | ConvertFrom-Json).changes
        $summary = $changes | Group-Object changeType | ForEach-Object { "$($_.Name)=$($_.Count)" }
        $changes | ForEach-Object { '{0,-8} {1}' -f $_.changeType, $_.resourceId } | Write-Output
        Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'what-if'; outcome = 'succeeded'; deploymentName = $Answers.deploymentName; changes = ($summary -join ',') })
        if (-not $Apply) { return }
        # A change to an existing resource is applied only when the operator has read the what-if.
        $risky = @($changes | Where-Object { $_.changeType -in @('Modify', 'Delete') })
        if ($risky.Count -gt 0 -and -not $ConfirmChanges) {
            Stop-Reconciler "The what-if shows $($risky.Count) Modify or Delete change(s) to existing resources; review them above and rerun with -ConfirmChanges." 'changes_not_confirmed'
        }
        $outputs = Invoke-Az @('deployment', 'group', 'create', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.deploymentName,
            '--template-file', $template, '--parameters', "@$paramsFile", '--query', 'properties.outputs', '-o', 'json') | ConvertFrom-Json
        Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'resources'; outcome = 'succeeded'; functionAppId = $outputs.functionAppId.value; principalId = $outputs.principalId.value; storageAccountId = $outputs.storageAccountId.value })
        Write-Output "Created $($outputs.functionAppName.value) (identity principal $($outputs.principalId.value)). Next: -Action LeaseContainer, then Permissions."
    }
    finally { Remove-Item -LiteralPath $paramsFile -ErrorAction SilentlyContinue }
}

function Invoke-ReconcilerLeaseContainer {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Answers)
    $account = @('--subscription', $sub, '--resource-group', $rg, '--account-name', $Answers.cosmosAccountName, '--database-name', $Answers.cosmosDatabaseName, '--name', $Answers.leaseContainerName)
    $exists = (Invoke-Az (@('cosmosdb', 'sql', 'container', 'exists') + $account)).Trim()
    if ($exists -eq 'true') {
        $path = (Invoke-Az (@('cosmosdb', 'sql', 'container', 'show') + $account + @('--query', 'resource.partitionKey.paths[0]', '-o', 'tsv'))).Trim()
        if ($path -ne '/id') { Stop-Reconciler "Container $($Answers.leaseContainerName) exists with partition key $path, not /id." 'lease_container_mismatch' }
        Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'lease-container'; outcome = 'unchanged'; container = $Answers.leaseContainerName })
        return
    }
    Invoke-Az (@('cosmosdb', 'sql', 'container', 'create') + $account + @('--partition-key-path', '/id', '-o', 'none')) | Out-Null
    Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'lease-container'; outcome = 'created'; container = $Answers.leaseContainerName })
}

function Invoke-ReconcilerPermissions {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Answers)
    $data = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'reconciler-permissions.json') -Raw | ConvertFrom-Json -AsHashtable
    # The data names the LLD containers; refuse if these answers use other names.
    $named = @($Answers.projectsContainerName, $Answers.entitlementContainerName, $Answers.budgetStateContainerName, $Answers.aggregateStateContainerName, $Answers.leaseContainerName)
    $expected = @('projects', 'entitlement', 'budgetState', 'aggregateBudgetState', 'reconcilerLease')
    if (Compare-Object $named $expected -CaseSensitive) { Stop-Reconciler 'The answers name containers other than those in reconciler-permissions.json.' 'container_names_differ' }
    $identity = Get-ReconcilerIdentity $Answers
    $storageId = (Invoke-Az @('storage', 'account', 'show', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.storageAccountName, '--query', 'id', '-o', 'tsv')).Trim()
    $values = @{
        'd1.apps.reconciler.principalId'               = [string]$identity.principalId
        'd1.apps.reconciler.storageAccountId'          = $storageId
        'd1.workspace.id'                              = $Answers.logAnalyticsWorkspaceId
        'answers.names.cosmosDatabase'                 = $Answers.cosmosDatabaseName
        'answers.names.cosmosRoles.reconcilerWriter'   = $Answers.cosmosWriterRoleName
    }
    $resolved = Resolve-ReconcilerPermissions -Data $data -Values $values
    $account = @('--subscription', $sub, '--resource-group', $rg, '--account-name', $Answers.cosmosAccountName)
    $definitionIds = @{}
    foreach ($definition in $resolved.cosmosRoleDefinitions) {
        $existing = (Invoke-Az (@('cosmosdb', 'sql', 'role', 'definition', 'list') + $account + @('-o', 'json')) | ConvertFrom-Json) |
            Where-Object { [string]::Equals($_.roleName, $definition.roleName, 'Ordinal') }
        if ($existing) {
            # A role of that name is reused only if it grants exactly these actions, never more.
            $actions = @($existing[0].permissions | ForEach-Object { $_.dataActions } | Sort-Object)
            if (Compare-Object $actions @($definition.dataActions | Sort-Object) -CaseSensitive) {
                Stop-Reconciler "A Cosmos role named '$($definition.roleName)' exists with other data actions; rename it in the answers or remove it." 'cosmos_role_differs'
            }
            $definitionIds[$definition.key] = [string]$existing[0].name
            continue
        }
        $id = New-ReconcilerStableGuid "cosmos-role:$($Answers.cosmosAccountName):$($definition.roleName)"
        $bodyFile = Join-Path $repoRoot '.env.rec-role-definition.json'
        try {
            [ordered]@{ Id = $id; RoleName = $definition.roleName; Type = 'CustomRole'; AssignableScopes = @('/'); Permissions = @(@{ DataActions = $definition.dataActions }) } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
            Invoke-Az (@('cosmosdb', 'sql', 'role', 'definition', 'create') + $account + @('--body', "@$bodyFile", '-o', 'none')) | Out-Null
        }
        finally { Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue }
        $definitionIds[$definition.key] = $id
        Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'permissions'; outcome = 'created'; item = "cosmos-role-definition:$($definition.key)"; id = $id })
    }
    foreach ($a in $resolved.assignments) {
        if ($a.plane -eq 'azure-rbac') {
            $found = Invoke-Az @('role', 'assignment', 'list', '--subscription', $sub, '--assignee', $a.principal, '--scope', $a.scope, '--role', $a.roleDefinitionId, '--query', '[].id', '-o', 'tsv')
            $outcome = 'unchanged'
            if (-not $found.Trim()) {
                Invoke-Az @('role', 'assignment', 'create', '--subscription', $sub, '--assignee-object-id', $a.principal, '--assignee-principal-type', $a.principalType,
                    '--role', $a.roleDefinitionId, '--scope', $a.scope, '-o', 'none') | Out-Null
                $found = Invoke-Az @('role', 'assignment', 'list', '--subscription', $sub, '--assignee', $a.principal, '--scope', $a.scope, '--role', $a.roleDefinitionId, '--query', '[].id', '-o', 'tsv')
                if (-not $found.Trim()) { Stop-Reconciler "The role assignment $($a.id) was not found after it was created." 'assignment_not_verified' }
                $outcome = 'created'
            }
        }
        elseif ($a.plane -eq 'cosmos-data') {
            $definitionId = if ($a.roleDefinitionId -like 'custom:*') { $definitionIds[$a.roleDefinitionId.Substring(7)] } else { $a.roleDefinitionId }
            $assignments = Invoke-Az (@('cosmosdb', 'sql', 'role', 'assignment', 'list') + $account + @('-o', 'json')) | ConvertFrom-Json
            $match = $assignments | Where-Object {
                [string]::Equals($_.principalId, $a.principal, 'OrdinalIgnoreCase') -and $_.scope.EndsWith($a.scope, [StringComparison]::Ordinal) -and $_.roleDefinitionId.EndsWith("/$definitionId", [StringComparison]::OrdinalIgnoreCase)
            }
            $outcome = 'unchanged'
            if (-not $match) {
                $assignmentId = New-ReconcilerStableGuid "cosmos-assignment:$($Answers.cosmosAccountName):$($a.id):$($a.principal)"
                Invoke-Az (@('cosmosdb', 'sql', 'role', 'assignment', 'create') + $account + @('--scope', $a.scope, '--principal-id', $a.principal,
                        '--role-definition-id', $definitionId, '--role-assignment-id', $assignmentId, '-o', 'none')) | Out-Null
                $outcome = 'created'
            }
        }
        else { Stop-Reconciler "Plane $($a.plane) is not applied by this script." 'plane_not_supported' }
        Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'permissions'; outcome = $outcome; item = $a.id; principalId = $a.principal })
    }
}

function Invoke-ReconcilerSettings {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Answers)
    $identity = Get-ReconcilerIdentity $Answers
    $values = Get-ReconcilerAppSettings $Answers -IdentityClientId ([string]$identity.clientId)
    $settingsFile = Join-Path $repoRoot '.env.rec-appsettings.json'
    try {
        $values | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding utf8NoBOM
        Invoke-Az @('functionapp', 'config', 'appsettings', 'set', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.functionAppName, '--settings', "@$settingsFile", '-o', 'none') | Out-Null
    }
    finally { Remove-Item -LiteralPath $settingsFile -ErrorAction SilentlyContinue }
    Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'settings'; outcome = 'succeeded'; functionAppName = $Answers.functionAppName; timerEnabled = $Answers.timerEnabled; schedule = $Answers.reconcilerSettings.RECONCILER_SCHEDULE; validitySeconds = $Answers.reconcilerSettings.RECONCILER_VALIDITY_SECONDS })
}

function Invoke-ReconcilerPackage {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Answers)
    $stage = Join-Path $repoRoot '.env.rec-package'
    $zip = Join-Path $repoRoot '.env.rec-package.zip'
    Remove-Item -LiteralPath $stage, $zip -Recurse -Force -ErrorAction SilentlyContinue
    try {
        New-Item -ItemType Directory -Path (Join-Path $stage 'dist'), (Join-Path $stage 'config'), (Join-Path $stage 'analytics') | Out-Null
        # contracts: registry.ts and settings.ts import src/contracts (model families, gateway id list).
        foreach ($dir in @('reconciler', 'cost', 'contracts')) { Copy-Item -Path (Join-Path $repoRoot "dist/$dir") -Destination (Join-Path $stage "dist/$dir") -Recurse }
        Copy-Item -Path (Join-Path $repoRoot 'config/rate-card.json'), (Join-Path $repoRoot 'config/contract-schedule.json') -Destination (Join-Path $stage 'config')
        Copy-Item -Path (Join-Path $repoRoot 'analytics/ledger.kql') -Destination (Join-Path $stage 'analytics')
        # The reconciler's own host.json (WP-CORE's D2 code step packages the same file).
        Copy-Item -Path (Join-Path $PSScriptRoot 'host.json'), (Join-Path $repoRoot 'package-lock.json') -Destination $stage
        # Only the reconciler's entry point: the repository's "main" glob would also load the resolver.
        $package = Get-Content (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json -AsHashtable
        $package.main = 'dist/reconciler/function-app.js'
        $package | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $stage 'package.json') -Encoding utf8NoBOM
        Push-Location $stage
        try { npm ci --omit=dev --no-audit --no-fund --quiet | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'npm ci --omit=dev failed in the package stage' } }
        finally { Pop-Location }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        # Flex Consumption deploys only through OneDeploy, which replaces the whole package (U-14).
        Invoke-Az @('functionapp', 'deployment', 'source', 'config-zip', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.functionAppName, '--src', $zip) | Out-Null
        Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'package'; outcome = 'succeeded'; functionAppName = $Answers.functionAppName; packageSha256 = $hash; rateCardVersion = (Get-Content (Join-Path $repoRoot 'config/rate-card.json') -Raw | ConvertFrom-Json).version })
        Write-Output "Deployed package sha256 $hash to $($Answers.functionAppName)."
    }
    finally { Remove-Item -LiteralPath $stage, $zip -Recurse -Force -ErrorAction SilentlyContinue }
}

function Test-ReconcilerOwned {
    param([Parameter(Mandatory)] [string] $ResourceId)
    try { $tags = Invoke-Az @('resource', 'show', '--ids', $ResourceId, '--query', 'tags', '-o', 'json') | ConvertFrom-Json -AsHashtable }
    catch { return $false }
    return ($tags -is [System.Collections.IDictionary]) -and [string]::Equals([string]$tags['ccof-package'], 'WP-REC', 'Ordinal')
}

function Invoke-ReconcilerRollback {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Answers)
    $identity = $null
    try { $identity = Get-ReconcilerIdentity $Answers } catch { $identity = $null }
    # 1. Stop the writer first.
    try {
        Invoke-Az @('functionapp', 'config', 'appsettings', 'set', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.functionAppName, '--settings', 'AzureWebJobs.reconcileBudgets.Disabled=true', '-o', 'none') | Out-Null
    }
    catch { Write-Output 'The app was not found or its timer could not be disabled; continuing.' }
    $account = @('--subscription', $sub, '--resource-group', $rg, '--account-name', $Answers.cosmosAccountName)
    if ($identity) {
        # 2. The identity's Cosmos data-plane and Azure role assignments.
        $assignments = Invoke-Az (@('cosmosdb', 'sql', 'role', 'assignment', 'list') + $account + @('-o', 'json')) | ConvertFrom-Json
        foreach ($a in $assignments | Where-Object { [string]::Equals($_.principalId, $identity.principalId, 'OrdinalIgnoreCase') }) {
            Invoke-Az (@('cosmosdb', 'sql', 'role', 'assignment', 'delete') + $account + @('--role-assignment-id', $a.name, '--yes')) | Out-Null
        }
        Invoke-Az @('role', 'assignment', 'delete', '--subscription', $sub, '--assignee', $identity.principalId, '--scope', $Answers.logAnalyticsWorkspaceId) | Out-Null
        Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'rollback'; outcome = 'succeeded'; step = 'assignments'; principalId = $identity.principalId })
    }
    # The custom role goes only if it is ours (same name and actions) and nothing else uses it.
    $data = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'reconciler-permissions.json') -Raw | ConvertFrom-Json -AsHashtable
    $ourActions = @($data.cosmosRoleDefinitions[0].dataActions | Sort-Object)
    $definitions = Invoke-Az (@('cosmosdb', 'sql', 'role', 'definition', 'list') + $account + @('-o', 'json')) | ConvertFrom-Json
    $remaining = Invoke-Az (@('cosmosdb', 'sql', 'role', 'assignment', 'list') + $account + @('-o', 'json')) | ConvertFrom-Json
    foreach ($d in $definitions | Where-Object { [string]::Equals($_.roleName, $Answers.cosmosWriterRoleName, 'Ordinal') }) {
        $actions = @($d.permissions | ForEach-Object { $_.dataActions } | Sort-Object)
        $inUse = $remaining | Where-Object { $_.roleDefinitionId.EndsWith("/$($d.name)", [StringComparison]::OrdinalIgnoreCase) }
        if ((Compare-Object $actions $ourActions -CaseSensitive) -or $inUse) {
            Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'rollback'; outcome = 'skipped_not_owned'; step = 'cosmos role definition' })
            continue
        }
        Invoke-Az (@('cosmosdb', 'sql', 'role', 'definition', 'delete') + $account + @('--id', $d.name, '--yes')) | Out-Null
    }
    # 3. The resources of D1, each only if it carries this package's ownership tag. The lease
    # container and the budgetState and aggregateBudgetState documents are left in place.
    $base = "/subscriptions/$sub/resourceGroups/$rg/providers"
    $steps = @(
        @{ id = "$base/Microsoft.Web/sites/$($Answers.functionAppName)"; args = @('functionapp', 'delete', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.functionAppName) },
        @{ id = "$base/Microsoft.Web/serverfarms/$($Answers.planName)"; args = @('appservice', 'plan', 'delete', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.planName, '--yes') },
        @{ id = "$base/Microsoft.Network/privateEndpoints/$($Answers.storagePrivateEndpointName)"; args = @('network', 'private-endpoint', 'delete', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.storagePrivateEndpointName) },
        @{ id = "$base/Microsoft.Storage/storageAccounts/$($Answers.storageAccountName)"; args = @('storage', 'account', 'delete', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.storageAccountName, '--yes') },
        @{ id = "$base/Microsoft.ManagedIdentity/userAssignedIdentities/$($Answers.identityName)"; args = @('identity', 'delete', '--subscription', $sub, '--resource-group', $rg, '--name', $Answers.identityName) }
    )
    foreach ($step in $steps) {
        if (-not (Test-ReconcilerOwned $step.id)) {
            Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'rollback'; outcome = 'skipped_not_owned'; resourceId = $step.id })
            continue
        }
        Invoke-Az $step.args | Out-Null
        Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'rollback'; outcome = 'succeeded'; resourceId = $step.id })
    }
    Write-Output "Rolled back. Left in place: the $($Answers.leaseContainerName) container and the budgetState and aggregateBudgetState documents; they go stale under ADR-0008 if the resolver enforces budget state."
}
