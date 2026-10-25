#Requires -Version 7.0
# DR-05 (docs/DR-ACTIVE-PASSIVE.md, "Required changes", Accounting): every deployment path that writes the
# reconciler's settings accepts an optional list of APIM ids for RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS.
# Without the list each deployment path omits RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS. The staged
# reconciler now also receives its workspace-based App Insights connection (previously missing,
# which prevented continuity-gate telemetry); its default settings digest is pinned below. Offline.

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$root = Split-Path $PSScriptRoot -Parent

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green; $script:Pass++ }
    else { Write-Host "FAIL: $Name $Detail" -ForegroundColor Red; $script:Fail++ }
}
function Get-Digest([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n", "`n"))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$sub = '00000000-0000-4000-8000-000000000110'
$apimA = "/subscriptions/$sub/resourceGroups/rg-a/providers/Microsoft.ApiManagement/service/apim-a"
$apimB = "/subscriptions/$sub/resourceGroups/rg-b/providers/Microsoft.ApiManagement/service/apim-b"
$listName = 'RECONCILER_LEDGER_GATEWAY_RESOURCE_IDS'

# --- infra/reconciler/ReconcilerDeploy.psm1 ---
Import-Module (Join-Path $root 'infra' 'reconciler' 'ReconcilerDeploy.psm1') -Force -DisableNameChecking
function New-ReconcilerAnswers {
    $rid = "/subscriptions/$sub/resourceGroups/rg-a/providers"
    [ordered]@{
        schemaVersion = 1; tenantId = '00000000-0000-4000-8000-0000000000aa'; subscriptionId = $sub; resourceGroup = 'rg-a'
        location = 'eastus2'; deploymentName = 'reconciler-1'; functionAppName = 'ccof-reconciler'; planName = 'ccof-reconciler-plan'
        storageAccountName = 'ccofreconciler'; storageSku = 'Standard_LRS'; deploymentContainerName = 'deploy'
        storagePrivateEndpointName = 'pe-blob'; identityName = 'id-reconciler'
        integrationSubnetId = "$rid/Microsoft.Network/virtualNetworks/vnet/subnets/functions"
        privateEndpointSubnetId = "$rid/Microsoft.Network/virtualNetworks/vnet/subnets/pe"
        blobPrivateDnsZoneId = "$rid/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
        logAnalyticsWorkspaceId = "$rid/Microsoft.OperationalInsights/workspaces/law"
        logAnalyticsWorkspaceCustomerId = '00000000-0000-4000-8000-0000000000bb'; logAnalyticsEndpoint = 'https://api.loganalytics.io'
        gatewayResourceId = $apimA; cosmosAccountName = 'ccof-cosmos'; cosmosDatabaseName = 'ccof'
        projectsContainerName = 'projects'; entitlementContainerName = 'entitlement'; budgetStateContainerName = 'budgetState'
        aggregateStateContainerName = 'aggregateBudgetState'; leaseContainerName = 'reconcilerLease'
        cosmosWriterRoleName = 'CCOF reconciler writer'; decisionSource = 'DR-05 test'
        alwaysReadyInstanceCount = 0; maximumInstanceCount = 1; instanceMemoryMB = 2048; zoneRedundant = $false; timerEnabled = $false
        reconcilerSettings = [ordered]@{
            RECONCILER_SCHEDULE = '0 */2 * * * *'; RECONCILER_VALIDITY_SECONDS = '600'; RECONCILER_LEASE_SECONDS = '300'
            RECONCILER_LEDGER_TIMEOUT_SECONDS = '60'; RECONCILER_LEDGER_MAX_ROWS = '100000'; RECONCILER_MAX_STATES = '10000'
            RECONCILER_WRITE_CONCURRENCY = '8'
        }
    }
}
function Get-Problems($Answers) { $r = Test-ReconcilerAnswers -Answers $Answers; return @($r | ForEach-Object { $_ }) }
$answers = New-ReconcilerAnswers
Assert-True 'ReconcilerDeploy: the sample answers are valid' ((Get-Problems $answers).Count -eq 0) ((Get-Problems $answers) -join ',')
$default = Get-ReconcilerAppSettings -Answers $answers -IdentityClientId '00000000-0000-4000-8000-0000000000cc'
$digest = Get-Digest ($default | ConvertTo-Json -Compress)
Assert-True 'ReconcilerDeploy: without gatewayResourceIds the settings are byte-identical to before DR-05' ($digest -eq '85730ed60eb11e241150481f6b37a4f0605cbff1f1aef5c0eedfcbee6fc4a677') $digest

$answers.gatewayResourceIds = @($apimA, $apimB)
Assert-True 'ReconcilerDeploy: a valid gatewayResourceIds is accepted' ((Get-Problems $answers).Count -eq 0) ((Get-Problems $answers) -join ',')
$listed = Get-ReconcilerAppSettings -Answers $answers -IdentityClientId '00000000-0000-4000-8000-0000000000cc'
Assert-True "ReconcilerDeploy: gatewayResourceIds is written comma-joined as $listName" ($listed[$listName] -ceq "$apimA,$apimB") "got '$($listed[$listName])'"
Assert-True 'ReconcilerDeploy: the single id is still written' ($listed.RECONCILER_LEDGER_GATEWAY_RESOURCE_ID -ceq $apimA)
$otherSub = $apimB.Replace($sub, '00000000-0000-4000-8000-000000000111')
$cases = @(
    @{ value = @($apimB); code = 'gatewayResourceIds:single_not_in_list' },
    @{ value = @($apimA, $apimA.Replace('apim-a', 'APIM-A')); code = 'gatewayResourceIds:duplicate' },
    @{ value = @($apimA, "$apimB'"); code = 'gatewayResourceIds:invalid' },
    @{ value = @($apimA, ''); code = 'gatewayResourceIds:invalid' },
    @{ value = @($apimA, 5); code = 'gatewayResourceIds:invalid' },
    @{ value = 'not-a-list'; code = 'gatewayResourceIds:invalid' },
    @{ value = @(); code = 'gatewayResourceIds:invalid' },
    @{ value = @($apimA, "$($apimB)1", "$($apimB)2", "$($apimB)3", "$($apimB)4"); code = 'gatewayResourceIds:too_many' }
)
foreach ($case in $cases) {
    $answers.gatewayResourceIds = $case.value
    $problems = Get-Problems $answers
    Assert-True "ReconcilerDeploy: refuses $($case.code) for $(ConvertTo-Json $case.value -Compress)" ($problems -contains $case.code) ($problems -join ',')
}
$answers.gatewayResourceIds = @($apimA, $otherSub)
Assert-True 'ReconcilerDeploy: the standby APIM may be in another subscription' ((Get-Problems $answers).Count -eq 0) ((Get-Problems $answers) -join ',')

# --- scripts/Core.D2Steps.psm1 (staged D2) ---
Import-Module (Join-Path $root 'scripts' 'Core.D2Steps.psm1') -Force -DisableNameChecking
function New-CoreInputs {
    $a = [ordered]@{
        target = @{ tenantId = '00000000-0000-0000-0000-0000000000aa' }
        names = @{ cosmosDatabase = 'ccof' }
        availability = @{ sync = @{ schedule = 's'; leaseSeconds = 1; maxRemovalsPerRun = 1; maxRemovalFraction = 0.1 }; budgetState = @{ graceSeconds = 1; hardLimitSeconds = 2 } }
        resolver = @{ budgetEnforcement = 'budget-state'; cosmosRequestTimeoutMs = 1; cosmosRetryAttempts = 1; cosmosRetryMaxWaitSeconds = 1; requestDeadlineMs = 1 }
        sync = @{ memberTypes = 'user'; graphMaxRetries = 1; graphMaxRetryAfterSeconds = 1; graphTimeoutSeconds = 1; writeMode = 'apply' }
        reconciler = @{ schedule = 's'; validitySeconds = 1; leaseSeconds = 1; logAnalyticsEndpoint = 'e'; ledgerTimeoutSeconds = 1; ledgerMaxRows = 1; maxStates = 1; writeConcurrency = 1; timerEnabled = $false }
    }
    $d = [ordered]@{
        cosmos = @{ endpoint = 'https://example-x.documents.azure.com:443/' }; workspace = @{ customerId = 'w' }; apim = @{ id = $apimA }
        apps = @{
            resolver = @{ storageAccountId = '/s/r'; appInsightsId = '/ai/r'; clientId = $null }
            sync = @{ storageAccountId = '/s/s'; appInsightsId = '/ai/s'; clientId = 'c-s' }
            reconciler = @{ storageAccountId = '/s/c'; appInsightsId = $null; clientId = 'c-c' }
        }
    }
    return $a, $d
}
$coreAnswers, $coreD1 = New-CoreInputs
$core = Get-CoreAppSettings -Answers $coreAnswers -D1 $coreD1 -Connections @{ resolver = 'cs'; sync = 'cs' }
$digest = Get-Digest ($core | ConvertTo-Json -Compress -Depth 5)
Assert-True 'Core D2: without reconciler.ledgerGatewayResourceIds every app''s settings are byte-identical to before DR-05' ($digest -eq '293ef402704064e7674417f3076492c880136c920ebf32af7d73d23ae87dbb4f') $digest
$coreAnswers.reconciler.ledgerGatewayResourceIds = @($apimA, $apimB)
$core = Get-CoreAppSettings -Answers $coreAnswers -D1 $coreD1 -Connections @{ resolver = 'cs'; sync = 'cs' }
Assert-True "Core D2: reconciler.ledgerGatewayResourceIds is written comma-joined as $listName" ($core.reconciler[$listName] -ceq "$apimA,$apimB") "got '$($core.reconciler[$listName])'"
Assert-True 'Core D2: the list is written only to the reconciler' (-not $core.resolver.Contains($listName) -and -not $core.sync.Contains($listName))

# --- scripts/manual/Session-Helpers.ps1 (manual path) ---
. (Join-Path $root 'scripts' 'manual' 'Session-Helpers.ps1')
$scratch = Join-Path $PSScriptRoot ".env.dr-ledger-$(Get-Random)"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $C = @{
        apps = @{ reconciler = @{ storageAccount = 'ccofreconciler'; clientId = '00000000-0000-4000-8000-0000000000cc' } }
        cosmosEndpoint = 'https://ccof-cosmos.documents.azure.com:443/'; database = 'ccof'
        workspaceCustomerId = '00000000-0000-4000-8000-0000000000bb'; apimResourceId = $apimA
    }
    New-CcofAppSettings -C $C -App reconciler -Directory $scratch 6>$null | Out-Null
    $object = Get-Content (Join-Path $scratch 'reconciler-settings.object.json') -Raw
    $portal = (Get-Content (Join-Path $scratch 'reconciler-settings.portal.json') -Raw | ConvertFrom-Json | ForEach-Object { "$($_.name)=$($_.value)=$($_.slotSetting)" }) -join "`n"
    # The portal file's entries are hashtables, whose key order varies between runs: its content is compared by entry.
    $digest = Get-Digest ($object + $portal)
    Assert-True 'Manual: without ledgerGatewayResourceIds both settings files are byte-identical to before DR-05' ($digest -eq '64dc90878a560226b3816468d5b2b5000d925925171130bd71b1a20cd9cea80b') $digest
    $C.ledgerGatewayResourceIds = @($apimA, $apimB)
    New-CcofAppSettings -C $C -App reconciler -Directory $scratch 6>$null | Out-Null
    $written = Get-Content (Join-Path $scratch 'reconciler-settings.object.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-True "Manual: ledgerGatewayResourceIds is written comma-joined as $listName" ($written[$listName] -ceq "$apimA,$apimB") "got '$($written[$listName])'"
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }

# --- infra/quickstart/modules/app-settings.bicep (quick-start, manual and staged Stage 5) ---
$stderrFile = Join-Path $PSScriptRoot ".env.dr-bicep-$(Get-Random).txt"
$text = az bicep build --file (Join-Path $root 'infra' 'quickstart' 'modules' 'app-settings.bicep') --stdout 2> $stderrFile
$exit = $LASTEXITCODE
Remove-Item $stderrFile -ErrorAction SilentlyContinue
Assert-True 'app-settings.bicep compiles' ($exit -eq 0)
if ($exit -eq 0) {
    $arm = ($text -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100
    $digest = Get-Digest ($arm.variables.reconcilerSettings | ConvertTo-Json -Compress -Depth 20)
    Assert-True 'app-settings.bicep: the reconciler has App Insights connection/auth and no APIM list by default' ($digest -eq '4c49814f0470bb81ef75f1c6548d2a03cab5a108278c1d160f6d788a828d17ad') $digest
    $site = @($arm.resources | Where-Object { $_.name -match 'apps\.reconciler\.functionApp' -and $_.name -match 'appsettings' })
    $properties = if ($site.Count) { [string]$site[0].properties } else { '' }
    Assert-True 'app-settings.bicep: the reconciler''s settings union the optional ledger list' ($properties -ceq "[union(variables('reconcilerSettings'), variables('reconcilerPacing'), variables('reconcilerLedgerGateways'))]") $properties
    $ledger = [string]$arm.variables.reconcilerLedgerGateways
    Assert-True 'app-settings.bicep: absent reconciler.ledgerGatewayResourceIds adds no setting' ($ledger -ceq "[if(contains(parameters('reconciler'), 'ledgerGatewayResourceIds'), createObject('$listName', join(parameters('reconciler').ledgerGatewayResourceIds, ',')), createObject())]") $ledger
}

Write-Host "Test-DrLedgerGateways: $script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
