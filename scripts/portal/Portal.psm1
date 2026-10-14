#Requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot '../Core.Permissions.psm1') -DisableNameChecking
$script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Assert-PortalEvidence {
    param([System.Collections.IDictionary]$P, [System.Collections.IDictionary]$Evidence)
    $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z'
    foreach ($id in @($P.tenantId, $P.names.subscriptionId, $Evidence.workspace.customerId, $Evidence.apim.principalId, $Evidence.apim.appId)) {
        if ([string]$id -notmatch $guid) { throw 'portal_evidence_invalid: tenant, subscription, workspace and APIM identity IDs must be actual GUIDs.' }
    }
    $base = "/subscriptions/$($P.names.subscriptionId)/resourceGroups/$($P.names.resourceGroup)/providers"
    $expected = @{
        cosmos = "$base/Microsoft.DocumentDB/databaseAccounts/$($P.names.cosmosAccount)"
        workspace = "$base/Microsoft.OperationalInsights/workspaces/$($P.names.logAnalyticsWorkspace)"
        apim = "/subscriptions/$($P.apim.subscriptionId)/resourceGroups/$($P.apim.resourceGroup)/providers/Microsoft.ApiManagement/service/$($P.apim.name)"
    }
    if ($Evidence.target.subscriptionId -ine $P.names.subscriptionId) { throw 'portal_evidence_subscription_mismatch' }
    foreach ($key in $expected.Keys) {
        if ([string]$Evidence[$key].id -ine $expected[$key]) { throw "portal_evidence_resource_mismatch: $key" }
    }
    if ($Evidence.cosmos.endpoint -cne "https://$($P.names.cosmosAccount).documents.azure.com:443/") { throw 'portal_evidence_cosmos_endpoint_mismatch: use the account URI with :443/.' }
    $gateway = [uri]$Evidence.apim.gatewayUrl
    if (-not $gateway.IsAbsoluteUri -or $gateway.Scheme -ne 'https' -or $gateway.UserInfo -or $gateway.Query -or $gateway.Fragment) { throw 'portal_evidence_gateway_url_invalid' }
    foreach ($app in @('resolver', 'sync', 'reconciler')) {
        $record = $Evidence.apps[$app]; $names = $P.names.apps[$app]
        if ([string]$record.principalId -notmatch $guid) { throw "portal_evidence_principal_invalid: $app" }
        if ($app -eq 'resolver') {
            if ($record.clientId) { throw 'portal_evidence_resolver_identity: the resolver uses its system-assigned identity.' }
        } elseif ([string]$record.clientId -notmatch $guid) { throw "portal_evidence_client_invalid: $app requires its user-assigned identity client ID." }
        foreach ($field in @('functionAppId', 'storageAccountId', 'appInsightsId')) {
            $wanted = switch ($field) {
                'functionAppId' { "$base/Microsoft.Web/sites/$($names.functionApp)" }
                'storageAccountId' { "$base/Microsoft.Storage/storageAccounts/$($names.storageAccount)" }
                'appInsightsId' { if ($names.appInsights) { "$base/Microsoft.Insights/components/$($names.appInsights)" } else { '' } }
            }
            if ([string]$record[$field] -ine $wanted) { throw "portal_evidence_resource_mismatch: $app.$field" }
        }
        if ($app -eq 'resolver' -and [string]$record.defaultHostName -cnotmatch '^[a-z0-9][a-z0-9.-]*\.azurewebsites\.net\z') {
            throw 'portal_evidence_resolver_hostname_invalid: copy the actual Default domain from the app Overview.'
        }
    }
}

function New-PortalAccessPlan {
    param(
        [System.Collections.IDictionary]$P, [System.Collections.IDictionary]$Evidence,
        [ValidateSet('resolver', 'sync', 'reconciler')] [string]$App
    )
    Assert-PortalEvidence -P $P -Evidence $Evidence
    $source = switch ($App) {
        resolver { 'infra/poc/resolver-auth.assignments.json' }
        sync { 'infra/sync/sync.assignments.json' }
        reconciler { 'infra/reconciler/reconciler-permissions.json' }
    }
    $document = Get-Content -LiteralPath (Join-Path $script:Root $source) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $document.assignments = @($document.assignments | Where-Object { $_.plane -ne 'graph-app-role' -and -not $_.Contains('principals') })
    if ($App -eq 'sync') {
        $seed = Get-Content -LiteralPath (Join-Path $script:Root 'docs/examples/onboarding.permissions.json') -Raw | ConvertFrom-Json -AsHashtable
        $document.cosmosRoleDefinitions += @($seed.cosmosRoleDefinitions)
        foreach ($container in @('projects', 'backends')) {
            $document.assignments += @{
                id = "portal-seed-$container"; plane = 'cosmos-data'; principal = '${d1.apps.sync.principalId}'
                role = 'custom:onbProjectWriter'; roleDefinitionId = 'custom:onbProjectWriter'
                scope = "/dbs/$($P.names.cosmosDatabase)/colls/$container"
                why = 'Create-only registry seed inside the VNet; no replace, upsert or delete.'
            }
        }
    }
    $answers = @{ names = $P.names; sync = @{ mode = 'application-permission' } }
    $plan = Get-CoreAssignmentPlan -Documents @([pscustomobject]@{ File = $source; Doc = $document }) -D1 $Evidence -Answers $answers
    if ($plan.Problems.Count) { throw "portal_access_plan_invalid: $($plan.Problems | ConvertTo-Json -Depth 10 -Compress)" }
    return $plan
}

Export-ModuleMember -Function Assert-PortalEvidence, New-PortalAccessPlan
