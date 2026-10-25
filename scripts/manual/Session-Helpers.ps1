#Requires -Version 7.0
# Dot-source only. No command runs against Azure when this file is loaded.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Azure.Response.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Onboarding.Azure.psm1') -DisableNameChecking

function Invoke-CcofRestJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    for ($i = 1; $i -lt $Arguments.Count; $i += 2) {
        if ($Arguments[$i] -notin @('--method','--url','--body') -or $i + 1 -ge $Arguments.Count) {
            throw 'REST helper accepts explicit --method, --url and optional --body pairs only.'
        }
    }
    $urlIndex = [array]::IndexOf($Arguments, '--url')
    $methodIndex = [array]::IndexOf($Arguments, '--method')
    if ($urlIndex -lt 0 -or $methodIndex -lt 0) { throw 'REST requires an explicit approved URL and method.' }
    $url = $Arguments[$urlIndex + 1]
    Assert-OnboardingProviderUri $url
    $subscription = if ($url -match '/subscriptions/([0-9a-f-]{36})/') { $Matches[1] } else {
        $account = Invoke-CcofAzJson @('account','show')
        [string]$account.id
    }
    $body = $null
    $bodyIndex = [array]::IndexOf($Arguments, '--body')
    if ($bodyIndex -ge 0) {
        $bodyArg = $Arguments[$bodyIndex + 1]
        $text = if ($bodyArg.StartsWith('@')) { Get-Content -LiteralPath $bodyArg.Substring(1) -Raw } else { $bodyArg }
        $body = $text | ConvertFrom-Json -AsHashtable -Depth 100
    }
    $result = Invoke-OnboardingRest -SubscriptionId $subscription -Method $Arguments[$methodIndex + 1] -Url $url -Body $body
    if ($null -eq $result -and $Arguments[$methodIndex + 1] -ieq 'GET') { throw 'REST resource not found; do not reinterpret this as empty configuration.' }
    return $result
}

function Invoke-CcofAzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if ($Arguments[0] -ceq 'rest') { return Invoke-CcofRestJson $Arguments }
    $text = & az @Arguments --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..([Math]::Min(2,$Arguments.Count-1))] -join ' '). Stop this step." }
    if (-not $text) { throw 'Azure CLI returned no JSON. Do not proceed with missing values.' }
    return ($text -join "`n" | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Invoke-CcofAzWrite {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if ($Arguments[0] -ceq 'rest') { Invoke-CcofRestJson $Arguments | Out-Null; return }
    & az @Arguments --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) { throw 'Azure write failed or timed out. Inspect live state before retrying this step.' }
}

function Save-CcofJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    ConvertTo-Json -InputObject $Value -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Assert-CcofSession {
    param([Parameter(Mandatory)]$C, [switch]$AccountOnly)
    if ($C -isnot [System.Collections.IDictionary] -or -not $C.subscriptionId -or -not $C.tenantId) { throw 'Load a complete private customer-values.json before using write helpers.' }
    if (-not $AccountOnly) {
        foreach ($k in 'cosmosResourceId','cosmosEndpoint','apimPrincipalId','workspaceCustomerId') {
            if (-not $C[$k]) { throw "`$C.$k is empty. Load `$C from the customer-values.json written by a successful Read-CcofCustomerValues (Step 01.3), not from customer-inputs.json." }
        }
        foreach ($app in 'resolver','sync','reconciler') {
            if (-not $C.apps[$app].principalId) { throw "`$C.apps.$app.principalId is empty. Rerun Read-CcofCustomerValues (Step 01.3) until it prints 'Customer values read and verified'." }
        }
    }
    $account = Invoke-CcofAzJson @('account','show')
    if ($account.id -ine $C.subscriptionId -or $account.tenantId -ine $C.tenantId) {
        throw 'Wrong subscription or tenant. Select the approved subscription; do not continue.'
    }
}

function Read-CcofCustomerValues {
    param([Parameter(Mandatory)][string]$InputPath, [Parameter(Mandatory)][string]$OutputPath)
    $raw = Get-Content -LiteralPath $InputPath -Raw
    if ($raw -match 'REPLACE-') { throw 'Complete customer-inputs.json; do not invent missing values.' }
    $c = $raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-CcofSession $c -AccountOnly
    $cos = Invoke-CcofAzJson @('cosmosdb','show','--subscription',$c.subscriptionId,'-g',$c.resourceGroup,'-n',$c.cosmosAccount)
    $c.cosmosResourceId = $cos.id
    $c.cosmosEndpoint = $cos.documentEndpoint
    $c.cosmosDisableLocalAuth = $cos.disableLocalAuth
    $database = Invoke-CcofAzJson @('cosmosdb','sql','database','show','--subscription',$c.subscriptionId,'-g',$c.resourceGroup,'-a',$c.cosmosAccount,'-n',$c.database)
    if ($database.resource.id -cne $c.database) { throw 'Cosmos database ID differs.' }
    $w = Invoke-CcofAzJson @('resource','show','--ids',$c.workspaceResourceId,'--api-version','2023-09-01')
    $c.workspaceCustomerId = $w.properties.customerId
    $c.retentionDays = $w.properties.retentionInDays
    $ap = Invoke-CcofAzJson @('resource','show','--ids',$c.apimResourceId,'--api-version','2024-05-01')
    $c.apimName = $ap.name
    $c.apimResourceGroup = ($ap.id -split '/')[4]
    $c.apimGatewayUrl = $ap.properties.gatewayUrl
    $c.apimPrincipalId = $ap.identity.principalId
    if (-not $c.apimPrincipalId) { throw 'APIM system-assigned identity is missing. Do not use az apim update to fix it.' }
    $sp = Invoke-CcofAzJson @('ad','sp','show','--id',$c.apimPrincipalId)
    $c.apimClientId = $sp.appId
    $locations = @(Invoke-CcofAzJson @('account','list-locations','--subscription',$c.subscriptionId))
    foreach ($app in 'resolver','sync','reconciler') {
        $a = $c.apps[$app]
        $site = Invoke-CcofAzJson @('resource','show','--subscription',$c.subscriptionId,'-g',$c.resourceGroup,'-n',$a.name,'--resource-type','Microsoft.Web/sites','--api-version','2024-04-01')
        $a.id = $site.id
        $a.defaultHostName = $site.properties.defaultHostName
        $a.location = Get-CcofCanonicalLocation -Location $site.location -Locations $locations
        $a.deployment = $site.properties.functionAppConfig.deployment.storage
        $a.runtime = $site.properties.functionAppConfig.runtime
        if ($a.runtime.name -ine 'node' -or [string]$a.runtime.version -cne '22') {
            throw "$app must use the reviewed Flex Node 22 runtime. Review runtime configuration before publishing."
        }
        $storage = Invoke-CcofAzJson @('storage','account','show','--subscription',$c.subscriptionId,'-g',$c.resourceGroup,'-n',$a.storageAccount)
        $a.storageId = $storage.id
        $a.storageAllowSharedKeyAccess = $storage.allowSharedKeyAccess
        if (-not $a.deployment.value) { throw "$app has no Flex deployment storage URL. Check its deployment configuration." }
        $uri = [uri]$a.deployment.value
        if ($uri.Host.Split('.')[0] -cne $a.storageAccount) {
            throw "$app deployment storage differs from the supplied storageAccount. Confirm host versus deployment accounts before proceeding."
        }
        $a.deploymentContainer = $uri.AbsolutePath.Trim('/')
        if ($app -eq 'resolver') {
            $a.principalId = $site.identity.principalId
            $a.clientId = $null
            if (-not $a.principalId) { throw 'Resolver system-assigned identity is absent.' }
            if ($a.deployment.authentication.type -cne 'SystemAssignedIdentity') {
                throw 'Resolver deployment authentication is not SystemAssignedIdentity. Review the Portal configuration.'
            }
        } else {
            $attached = $site.identity.userAssignedIdentities
            $wantedId = ([string]$a.identityResourceId).Trim().TrimEnd('/')
            # ARM returns IDs with varying case (resourceGroups vs resourcegroups); compare case-insensitively.
            $match = @(if ($attached) { $attached.Keys | Where-Object { ([string]$_).TrimEnd('/') -ieq $wantedId } })
            if ($match.Count -ne 1) {
                throw "$app does not have exactly one matching user-assigned identity attached. Compare the configured resource ID with the app's Identity page."
            }
            $a.identityResourceId = $wantedId
            # The attachment map supplies the identity IDs without a second directory lookup.
            $mi = $attached[$match[0]]
            if (-not $mi -or -not $mi.principalId -or -not $mi.clientId) {
                $res = Invoke-CcofAzJson @('resource','show','--ids',$wantedId,'--api-version','2023-01-31')
                $mi = @{ principalId = $res.properties.principalId; clientId = $res.properties.clientId }
            }
            $a.principalId = $mi.principalId
            $a.clientId = $mi.clientId
            if (-not $a.principalId -or -not $a.clientId) { throw "$app identity principal/client ID could not be read." }
            $deployId = ([string]$a.deployment.authentication.userAssignedIdentityResourceId).Trim().TrimEnd('/')
            if ($a.deployment.authentication.type -cne 'UserAssignedIdentity' -or $deployId -ine $wantedId) {
                throw "$app deployment identity differs from the supplied user-assigned identity."
            }
        }
        $live = @(Invoke-CcofAzJson @('functionapp','config','appsettings','list','--subscription',$c.subscriptionId,'-g',$c.resourceGroup,'-n',$a.name))
        $a.existingSettingNames = @($live | ForEach-Object { $_.name })
        $hostAccount = @($live | Where-Object name -CEQ 'AzureWebJobsStorage__accountName')
        if ($hostAccount.Count -and $hostAccount[0].value -cne $a.storageAccount) {
            throw "$app host storage differs. Do not overwrite host storage until the two-account design is reviewed."
        }
        if ($a.appInsightsResourceId) {
            $ai = Invoke-CcofAzJson @('resource','show','--ids',$a.appInsightsResourceId,'--api-version','2020-02-02')
            if ($ai.properties.WorkspaceResourceId -ine $c.workspaceResourceId) {
                throw "$app Insights is not linked to the chosen workspace. Review it before changing settings."
            }
            if (-not $ai.properties.ConnectionString) { throw "$app Insights connection string is missing." }
            $a.connectionString = $ai.properties.ConnectionString
        }
    }
    $gateway = Invoke-CcofAzJson @('ad','app','show','--id',$c.gatewayAppId)
    if ($gateway.signInAudience -cne 'AzureADMyOrg') { throw 'Gateway registration must be single-tenant for this workbook.' }
    if (@($gateway.identifierUris) -cnotcontains $c.gatewayIdentifierUri) { throw 'Gateway identifier URI is not registered on the specified app.' }
    if ($gateway.api.requestedAccessTokenVersion -ne 2 -or
        -not @($gateway.api.oauth2PermissionScopes | Where-Object { $_.value -ceq 'access_as_user' -and $_.isEnabled }).Count) {
        throw 'Gateway app requires v2 access tokens and an enabled access_as_user scope.'
    }
    $resolver = Invoke-CcofAzJson @('ad','app','show','--id',$c.resolverApiAppId)
    if ($resolver.signInAudience -cne 'AzureADMyOrg') { throw 'Resolver registration must be single-tenant for this workbook.' }
    if ($resolver.api.requestedAccessTokenVersion -ne 2 -or
        @($resolver.identifierUris) -cnotcontains "api://$($c.resolverApiAppId)") {
        throw 'Resolver registration requires v2 tokens and its api://<client-id> URI.'
    }
    Save-CcofJson $c $OutputPath
    Write-Host 'Customer values read and verified. Nothing was deployed. Keep the output private.'
}

function Grant-CcofAzureRole {
    param([Parameter(Mandatory)]$C, [Parameter(Mandatory)][string]$PrincipalId,
          [Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$Scope, [switch]$Apply)
    Assert-CcofSession $C
    $args = @('role','assignment','list','--subscription',$C.subscriptionId,'--scope',$Scope,'--include-inherited','--all')
    $held = @((Invoke-CcofAzJson $args) | Where-Object { $_.principalId -ieq $PrincipalId -and $_.roleDefinitionName -ceq $Role -and (Test-CcofArmScopeCovers $_.scope $Scope) })
    Write-Host "$Role : $PrincipalId : $Scope"
    if ($held.Count) { Write-Host 'Existing or inherited assignment verified; no write.'; return }
    if (-not $Apply) { Write-Host 'PLAN: one assignment would be created. Review scope and identity.'; return }
    Invoke-CcofAzWrite @('role','assignment','create','--subscription',$C.subscriptionId,'--assignee-object-id',$PrincipalId,'--assignee-principal-type','ServicePrincipal','--role',$Role,'--scope',$Scope)
    $verified = @((Invoke-CcofAzJson $args) | Where-Object { $_.principalId -ieq $PrincipalId -and $_.roleDefinitionName -ceq $Role -and (Test-CcofArmScopeCovers $_.scope $Scope) })
    if (-not $verified.Count) { throw 'Role assignment not verified. Do not proceed.' }
    Write-Host 'One assignment verified. Data-plane propagation may still take time.'
}

function Get-CcofCosmosActions {
    param([Parameter(Mandatory)][ValidateSet('sync','reconciler','seed')][string]$Kind)
    $prefix = 'Microsoft.DocumentDB/databaseAccounts'
    switch ($Kind) {
        sync { return @("$prefix/readMetadata","$prefix/sqlDatabases/containers/executeQuery","$prefix/sqlDatabases/containers/readChangeFeed","$prefix/sqlDatabases/containers/items/read","$prefix/sqlDatabases/containers/items/create","$prefix/sqlDatabases/containers/items/replace") }
        reconciler { return @("$prefix/readMetadata","$prefix/sqlDatabases/containers/items/read","$prefix/sqlDatabases/containers/items/create","$prefix/sqlDatabases/containers/items/replace","$prefix/sqlDatabases/containers/items/upsert") }
        seed { return @("$prefix/readMetadata","$prefix/sqlDatabases/containers/items/read","$prefix/sqlDatabases/containers/items/create") }
    }
}

function Set-CcofCosmosRole {
    param([Parameter(Mandatory)]$C, [Parameter(Mandatory)][ValidateSet('sync','reconciler','seed')][string]$Kind,
          [Parameter(Mandatory)][string]$Directory, [switch]$Apply,
          [ValidateRange(0,600)][int]$VerificationTimeoutSeconds = 180,
          [scriptblock]$Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds })
    Assert-CcofSession $C
    $names = @{ sync='ccof sync entitlement writer'; reconciler='ccof reconciler budget writer'; seed='ccof onboarding project writer' }
    $name = $names[$Kind]
    $expected = @(Get-CcofCosmosActions $Kind)
    $base = @('cosmosdb','sql','role','definition')
    $listArgs = $base + @('list','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-a',$C.cosmosAccount)
    $found = @((Invoke-CcofAzJson $listArgs) | Where-Object roleName -CEQ $name)
    if ($found.Count -gt 1) { throw "Duplicate role name: $name. Review IDs instead of selecting the first." }
    if ($found.Count) {
        $actual = @($found[0].permissions | ForEach-Object { $_.dataActions } | Sort-Object -Unique)
        $notActions = @($found[0].permissions | ForEach-Object { $_.notDataActions } | Where-Object { $null -ne $_ })
        $knownTypes = @('CustomRole','Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions')
        $scopeMatch = @($found[0].assignableScopes | Where-Object { Test-CcofArmIdEqual $_ $C.cosmosResourceId })
        if (@(Compare-Object ($expected | Sort-Object -Unique) $actual).Count -or $notActions.Count -or
            $found[0].type -notin $knownTypes -or -not $scopeMatch.Count) {
            throw "Existing custom role differs: $name. Do not overwrite it or grant a broader role."
        }
        Write-Host "Role verified: $name"; return
    }
    Write-Host "PLAN: create only '$name' with these actions:"; $expected | ForEach-Object { Write-Host $_ }
    if (-not $Apply) { return }
    $file = Join-Path $Directory "cosmos-role-$Kind.json"
    $definitionId = New-CcofStableId -Parts @($C.cosmosResourceId.TrimEnd('/').ToLowerInvariant(), 'role-definition', $name)
    Save-CcofJson @{ Id=$definitionId; RoleName=$name; Type='CustomRole'; AssignableScopes=@($C.cosmosResourceId); Permissions=@(@{ DataActions=$expected }) } $file
    Invoke-CcofAzWrite ($base + @('create','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-a',$C.cosmosAccount,'--body',"@$file"))
    $after = @((Invoke-CcofAzJson $listArgs) | Where-Object roleName -CEQ $name)
    $waited = 0
    while (-not $after.Count -and $waited -lt $VerificationTimeoutSeconds) {
        $pause = [Math]::Min(5, $VerificationTimeoutSeconds - $waited)
        & $Sleep $pause
        $waited += $pause
        $after = @((Invoke-CcofAzJson $listArgs) | Where-Object roleName -CEQ $name)
    }
    if ($after.Count -ne 1) { throw 'Cosmos role read-back not verified. The write may have succeeded; inspect the deterministic definition ID before retrying.' }
    Set-CcofCosmosRole -C $C -Kind $Kind -Directory $Directory
}

function Grant-CcofCosmosRole {
    param([Parameter(Mandatory)]$C, [Parameter(Mandatory)][ValidateSet('resolver','sync','reconciler')][string]$App,
          [Parameter(Mandatory)][ValidateSet('reader','sync','reconciler','seed')][string]$Kind,
          [string]$Container, [switch]$Apply,
          [ValidateRange(0,600)][int]$VerificationTimeoutSeconds = 180,
          [scriptblock]$Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds })
    $allowed = @(
        'resolver/reader/','sync/sync/entitlement','sync/sync/syncLease','sync/reader/projects',
        'sync/seed/projects','sync/seed/backends','reconciler/reader/projects','reconciler/reader/entitlement',
        'reconciler/reconciler/budgetState','reconciler/reconciler/aggregateBudgetState','reconciler/reconciler/reconcilerLease'
    )
    if ($allowed -cnotcontains "$App/$Kind/$Container") { throw 'This app/role/scope is not an approved repository assignment.' }
    Assert-CcofSession $C
    $definitions = @(Invoke-CcofAzJson @('cosmosdb','sql','role','definition','list','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-a',$C.cosmosAccount))
    if ($Kind -eq 'reader') {
        $shortId = '00000000-0000-0000-0000-000000000001'
        $roleId = "$($C.cosmosResourceId)/sqlRoleDefinitions/$shortId"
    } else {
        $names = @{ sync='ccof sync entitlement writer'; reconciler='ccof reconciler budget writer'; seed='ccof onboarding project writer' }
        $found = @($definitions | Where-Object roleName -CEQ $names[$Kind])
        if ($found.Count -ne 1) { throw 'Required custom role is missing or ambiguous.' }
        $actual = @($found[0].permissions | ForEach-Object { $_.dataActions } | Sort-Object -Unique)
        if (@(Compare-Object (@(Get-CcofCosmosActions $Kind) | Sort-Object -Unique) $actual).Count -or
            @($found[0].permissions | ForEach-Object { $_.notDataActions }).Count) { throw 'Custom role actions differ. Stop.' }
        $roleId = $found[0].id
    }
    $relative = "/dbs/$($C.database)"
    if ($Container) { $relative += "/colls/$Container" }
    $scope = "$($C.cosmosResourceId)$relative"
    $principal = $C.apps[$App].principalId
    $list = @('cosmosdb','sql','role','assignment','list','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-a',$C.cosmosAccount)
    $held = @((Invoke-CcofAzJson $list) | Where-Object { $_.principalId -ieq $principal -and $_.roleDefinitionId -ieq $roleId -and (Test-CcofCosmosScopeEqual $_.scope $scope) })
    Write-Host "$App : $Kind : $relative : $principal"
    if ($held.Count) { Write-Host 'Existing exact assignment verified; no write.'; return }
    if (-not $Apply) { Write-Host 'PLAN: one native Cosmos assignment would be created.'; return }
    $assignmentId = New-CcofCosmosAssignmentId -Scope $scope -PrincipalId $principal -RoleId $roleId
    Invoke-CcofAzWrite @('cosmosdb','sql','role','assignment','create','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-a',$C.cosmosAccount,'--role-assignment-id',$assignmentId,'--role-definition-id',$roleId,'--principal-id',$principal,'--scope',$relative)
    $verified = @((Invoke-CcofAzJson $list) | Where-Object { $_.principalId -ieq $principal -and $_.roleDefinitionId -ieq $roleId -and (Test-CcofCosmosScopeEqual $_.scope $scope) })
    $waited = 0
    while (-not $verified.Count -and $waited -lt $VerificationTimeoutSeconds) {
        $pause = [Math]::Min(5, $VerificationTimeoutSeconds - $waited)
        & $Sleep $pause
        $waited += $pause
        $verified = @((Invoke-CcofAzJson $list) | Where-Object { $_.principalId -ieq $principal -and $_.roleDefinitionId -ieq $roleId -and (Test-CcofCosmosScopeEqual $_.scope $scope) })
    }
    if (-not $verified.Count) { throw "Native Cosmos assignment not verified after bounded read-back. Write may have succeeded; inspect assignment $assignmentId before retrying. No duplicate ID will be generated." }
    Write-Host 'One native Cosmos assignment verified.'
}

function New-CcofAppSettings {
    param([Parameter(Mandatory)]$C, [Parameter(Mandatory)][ValidateSet('resolver','sync','reconciler')][string]$App,
          [Parameter(Mandatory)][string]$Directory)
    $a = $C.apps[$App]
    $s = [ordered]@{
        AzureWebJobsStorage__accountName=$a.storageAccount
        AzureWebJobsStorage__credential='managedidentity'
        CCOF_APP_ROLE=$App; COSMOS_ENDPOINT=$C.cosmosEndpoint; COSMOS_DATABASE=$C.database
    }
    if ($App -ne 'resolver') { $s.AzureWebJobsStorage__clientId = $a.clientId }
    switch ($App) {
        resolver {
            $s.APPLICATIONINSIGHTS_CONNECTION_STRING=$a.connectionString
            $s.APPLICATIONINSIGHTS_AUTHENTICATION_STRING='Authorization=AAD'
            $s.RESOLVER_COSMOS_REQUEST_TIMEOUT_MS='2000'; $s.RESOLVER_COSMOS_RETRY_ATTEMPTS='2'
            $s.RESOLVER_COSMOS_RETRY_MAX_WAIT_SECONDS='2'; $s.RESOLVER_REQUEST_DEADLINE_MS='4000'
            $s.RESOLVER_BUDGET_ENFORCEMENT='token-limits-only'
        }
        sync {
            $s.APPLICATIONINSIGHTS_CONNECTION_STRING=$a.connectionString
            $s.APPLICATIONINSIGHTS_AUTHENTICATION_STRING="Authorization=AAD;ClientId=$($a.clientId)"
            $s.SYNC_MANAGED_IDENTITY_CLIENT_ID=$a.clientId; $s.SYNC_TENANT_ID=$C.tenantId
            $s.SYNC_PROJECTS_CONTAINER='projects'; $s.SYNC_ENTITLEMENT_CONTAINER='entitlement'; $s.SYNC_LEASE_CONTAINER='syncLease'
            $s.SYNC_SCHEDULE='0 */1 * * * *'; $s.SYNC_LEASE_SECONDS='300'
            $s.SYNC_MAX_REMOVALS_PER_RUN='5'; $s.SYNC_MAX_REMOVAL_FRACTION='0.1'; $s.SYNC_MEMBER_TYPES='user'
            $s.SYNC_GRAPH_MAX_RETRIES='3'; $s.SYNC_GRAPH_MAX_RETRY_AFTER_SECONDS='30'; $s.SYNC_GRAPH_TIMEOUT_SECONDS='30'
            $s.SYNC_WRITE_MODE='apply'
            $s.'AzureWebJobs.syncEntitlement.Disabled'='true'; $s.'AzureWebJobs.registrySeed.Disabled'='true'
        }
        reconciler {
            $s.RECONCILER_MANAGED_IDENTITY_CLIENT_ID=$a.clientId
            $s.RECONCILER_SCHEDULE='0 */2 * * * *'; $s.RECONCILER_VALIDITY_SECONDS='600'; $s.RECONCILER_LEASE_SECONDS='300'
            $s.RECONCILER_LOG_ANALYTICS_WORKSPACE_ID=$C.workspaceCustomerId
            $s.RECONCILER_LOG_ANALYTICS_ENDPOINT='https://api.loganalytics.io'; $s.RECONCILER_LEDGER_GATEWAY_RESOURCE_ID=$C.apimResourceId
            $s.RECONCILER_LEDGER_TIMEOUT_SECONDS='60'; $s.RECONCILER_LEDGER_MAX_ROWS='100000'
            $s.RECONCILER_MAX_STATES='10000'; $s.RECONCILER_WRITE_CONCURRENCY='8'
            $s.RECONCILER_PROJECTS_CONTAINER='projects'; $s.RECONCILER_ENTITLEMENT_CONTAINER='entitlement'
            $s.RECONCILER_BUDGET_STATE_CONTAINER='budgetState'; $s.RECONCILER_AGGREGATE_STATE_CONTAINER='aggregateBudgetState'
            $s.RECONCILER_LEASE_CONTAINER='reconcilerLease'; $s.'AzureWebJobs.reconcileBudgets.Disabled'='true'
            # DR-05: the optional list of APIM ids whose logs hold this deployment's usage.
            if ($C.ledgerGatewayResourceIds) { $s.RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS = @($C.ledgerGatewayResourceIds) -join ',' }
        }
    }
    foreach ($key in @($s.Keys)) {
        if ($null -eq $s[$key] -or [string]$s[$key] -eq '' -or [string]$s[$key] -match 'REPLACE-') { throw "Missing setting value: $key" }
        $s[$key] = [string]$s[$key]
    }
    Save-CcofJson $s (Join-Path $Directory "$App-settings.object.json")
    $portal = @($s.GetEnumerator() | ForEach-Object { @{name=$_.Key;value=$_.Value;slotSetting=$false} })
    Save-CcofJson $portal (Join-Path $Directory "$App-settings.portal.json")
    Write-Host "Local settings for $App created; no Azure write. Review both files privately."
}

function Test-CcofAppSettings {
    param([Parameter(Mandatory)]$C, [Parameter(Mandatory)][ValidateSet('resolver','sync','reconciler')][string]$App,
          [Parameter(Mandatory)][string]$Directory)
    Assert-CcofSession $C
    $expected = Get-Content (Join-Path $Directory "$App-settings.object.json") -Raw | ConvertFrom-Json -AsHashtable
    $live = @(Invoke-CcofAzJson @('functionapp','config','appsettings','list','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-n',$C.apps[$App].name))
    foreach ($key in $expected.Keys) {
        $held = @($live | Where-Object name -CEQ $key)
        if ($held.Count -ne 1 -or [string]$held[0].value -cne [string]$expected[$key]) {
            throw "Missing or differing setting: $key. Values are not printed."
        }
    }
    Write-Host "All expected settings match: $App. Unrelated settings were not assessed or removed."
}

function Assert-CcofSeedResult {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$SeedId, [Parameter(Mandatory)]$Documents)
    $expected = @(@($Documents.projects | ForEach-Object { "projects/$($_.id)" }) + @($Documents.backends | ForEach-Object { "backends/$($_.id)" })) | Sort-Object
    $actual = @($Result.documents | ForEach-Object { "$($_.container)/$($_.id)" }) | Sort-Object
    if ($SeedId -cnotmatch '^[a-f0-9]{32}$' -or $Result.schema -cne 'ccof.seed.result.v1' -or $Result.seedId -cne $SeedId -or
        $Result.outcome -cne 'succeeded' -or -not $expected.Count -or $actual.Count -ne $expected.Count -or
        @(Compare-Object $expected $actual).Count -or
        @($Result.documents | Where-Object { $_.outcome -cnotin @('created','present-equal') }).Count) {
        throw 'Seed did not verify every expected document for this seed ID. Do not overwrite existing documents.'
    }
}
