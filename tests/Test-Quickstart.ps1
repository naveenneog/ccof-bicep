#Requires -Version 7.0
<#
.SYNOPSIS
    Tests the single-administrator quick-start (ADR-0024, Proposed; infra/quickstart):
    - main.bicep compiles (`az bicep build`, local, no Azure call);
    - parity: its Cosmos containers and partition keys equal D2's schema step (Core.D2Steps.psm1),
      its application setting names per app and their constant values equal D2's settings step
      (Get-CoreAppSettings), and its Cosmos data-plane role definitions and assignments equal D3's
      data (infra/sync, infra/reconciler, infra/poc resolver-auth, docs/examples onboarding);
    - the wrapper resumes: a failed step 4 resumes at step 4 on a rerun, and -From forces a restart.
#>

$ErrorActionPreference = 'Continue'
$script:Pass = 0
$script:Fail = 0
trap { Write-Host "FAIL: unexpected error: $_" -ForegroundColor Red; $script:Fail++; continue }
$root = Split-Path $PSScriptRoot -Parent
$qs = Join-Path $root 'infra' 'quickstart'

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green; $script:Pass++ }
    else { Write-Host "FAIL: $Name $Detail" -ForegroundColor Red; $script:Fail++ }
}

function Find-Variable {
    # The compiled template nests each module's template; return the first variable of that name.
    param($Node, [string]$Name)
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains('variables') -and $Node.variables -is [System.Collections.IDictionary] -and $Node.variables.Contains($Name)) { return , $Node.variables[$Name] }
        foreach ($k in $Node.Keys) { $r = Find-Variable $Node[$k] $Name; if ($null -ne $r) { return , $r } }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($i in $Node) { $r = Find-Variable $i $Name; if ($null -ne $r) { return , $r } }
    }
    return $null
}

$main = Join-Path $qs 'main.bicep'
Assert-True 'infra/quickstart/main.bicep exists' (Test-Path $main)
$compiled = $null
if (Test-Path $main) {
    $stderrFile = Join-Path $PSScriptRoot ".env.qs-bicep-$(Get-Random).txt"
    $text = az bicep build --file $main --stdout 2> $stderrFile
    $exit = $LASTEXITCODE
    $diag = (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue) + ''
    Remove-Item $stderrFile -ErrorAction SilentlyContinue
    Assert-True 'main.bicep compiles (az bicep build exit 0)' ($exit -eq 0) "exit=$exit $diag"
    $compilerDiagnostics = @($diag -split "`r?`n" | Where-Object { $_ -match '\(\d+,\d+\)\s*:\s*(Warning|Error)\s' })
    Assert-True 'main.bicep has no compiler or linter diagnostic' ($compilerDiagnostics.Count -eq 0) ($compilerDiagnostics -join ' | ')
    if ($exit -eq 0) { $compiled = ($text -join "`n") | ConvertFrom-Json -AsHashtable -Depth 200 }
}

# --- Parity 1: containers and partition keys equal D2's schema step ---
Import-Module (Join-Path $root 'scripts' 'Core.D2Steps.psm1') -Force -DisableNameChecking
$d2Containers = Get-CoreCosmosContainers
$bicepContainers = if ($compiled) { Find-Variable $compiled 'cosmosContainers' } else { $null }
Assert-True 'the Bicep declares cosmosContainers' ($null -ne $bicepContainers)
if ($bicepContainers) {
    $got = [ordered]@{}; foreach ($c in $bicepContainers) { $got[$c.name] = $c.partitionKey }
    $same = ($got.Count -eq $d2Containers.Count) -and (@($d2Containers.Keys | Where-Object { $got[$_] -cne $d2Containers[$_] }).Count -eq 0)
    Assert-True 'containers and partition keys equal D2 (Core.D2Steps.psm1)' $same "bicep=$($got | ConvertTo-Json -Compress) d2=$($d2Containers | ConvertTo-Json -Compress)"
}

# --- Parity 2: application settings equal D2's settings step ---
$answers = [ordered]@{
    target = @{ tenantId = '00000000-0000-0000-0000-0000000000aa' }
    names = @{ cosmosDatabase = 'ccof' }
    availability = @{ sync = @{ schedule = 's'; leaseSeconds = 1; maxRemovalsPerRun = 1; maxRemovalFraction = 0.1 }; budgetState = @{ graceSeconds = 1; hardLimitSeconds = 2 } }
    resolver = @{ budgetEnforcement = 'budget-state'; cosmosRequestTimeoutMs = 1; cosmosRetryAttempts = 1; cosmosRetryMaxWaitSeconds = 1; requestDeadlineMs = 1 }
    sync = @{ memberTypes = 'user'; graphMaxRetries = 1; graphMaxRetryAfterSeconds = 1; graphTimeoutSeconds = 1; writeMode = 'apply' }
    reconciler = @{ schedule = 's'; validitySeconds = 1; leaseSeconds = 1; logAnalyticsEndpoint = 'e'; ledgerTimeoutSeconds = 1; ledgerMaxRows = 1; maxStates = 1; writeConcurrency = 1; timerEnabled = $false }
}
$d1 = [ordered]@{
    cosmos = @{ endpoint = 'https://example-x.documents.azure.com:443/' }; workspace = @{ customerId = 'w' }; apim = @{ id = '/a' }
    apps = @{
        resolver = @{ storageAccountId = '/s/r'; appInsightsId = '/ai/r'; clientId = $null }
        sync = @{ storageAccountId = '/s/s'; appInsightsId = '/ai/s'; clientId = 'c-s' }
        reconciler = @{ storageAccountId = '/s/c'; appInsightsId = '/ai/c'; clientId = 'c-c' }
    }
}
$d2Settings = Get-CoreAppSettings -Answers $answers -D1 $d1 -Connections @{ resolver = 'cs'; sync = 'cs'; reconciler = 'cs' }
# The quick-start's own settings, each named in ADR-0024: the switch of the registry seed function
# (src/sync/registry-seed.ts), which the staged path never registers (it never sets CCOF_SEED_DOCUMENTS).
$settingAdditions = @{ resolver = @(); sync = @('AzureWebJobs.registrySeed.Disabled'); reconciler = @() }
$adrText = Get-Content (Join-Path $root 'docs/adr/0024-single-administrator-quick-start.md') -Raw
foreach ($app in @('resolver', 'sync', 'reconciler')) {
    $bicep = if ($compiled) { Find-Variable $compiled "${app}Settings" } else { $null }
    Assert-True "the Bicep declares ${app}Settings" ($null -ne $bicep)
    if (-not $bicep) { continue }
    $want = @(@($d2Settings[$app].Keys) + $settingAdditions[$app] | Sort-Object); $have = @($bicep.Keys | Sort-Object)
    Assert-True "$app setting names equal D2 (Get-CoreAppSettings, budget-state) plus the named quick-start additions" (($want -join ',') -ceq ($have -join ',')) "missing=$(@($want | Where-Object { $have -cnotcontains $_ }) -join ',') extra=$(@($have | Where-Object { $want -cnotcontains $_ }) -join ',')"
    $constants = @($have | Where-Object { $bicep[$_] -is [string] -and -not $bicep[$_].StartsWith('[') })
    $wrong = @($constants | Where-Object { $d2Settings[$app].Contains($_) -and [string]$d2Settings[$app][$_] -cne $bicep[$_] })
    Assert-True "$app constant setting values equal D2" ($wrong.Count -eq 0) "differ: $($wrong -join ',')"
    foreach ($addition in $settingAdditions[$app]) {
        Assert-True "ADR-0024 names the quick-start setting $addition" ($adrText.Contains($addition)) 'the addition is not recorded in the ADR'
    }
    if ($app -eq 'sync') {
        Assert-True 'the registry seed function is disabled by default (AzureWebJobs.registrySeed.Disabled = true)' ($bicep['AzureWebJobs.registrySeed.Disabled'] -ceq 'true') "value '$($bicep['AzureWebJobs.registrySeed.Disabled'])'"
        Assert-True 'the seed documents are no deployment setting (step 5 sets CCOF_SEED_DOCUMENTS for the seed only)' (-not $bicep.Contains('CCOF_SEED_DOCUMENTS'))
    }
}

# --- A fresh deployment never reads a resource that a module creates from main.bicep itself ---
# The function-app modules create the Application Insights components. A reference() to them in
# main.bicep's own template is read when the deployment starts, before the modules ran: the live run
# of 2026-10-13 (samplelab-quickstart) failed with ResourceNotFound on samplelab-resolver-ai and
# samplelab-sync-ai although every module succeeded. The connection strings come from the modules' outputs.
if ($compiled) {
    $topLevel = $compiled.Clone(); $topLevel.Remove('resources')
    $moduleParams = @($compiled.resources | ForEach-Object { $_.properties.parameters | ConvertTo-Json -Depth 50 -Compress })
    $early = @(@(($topLevel | ConvertTo-Json -Depth 100 -Compress)) + $moduleParams | Where-Object { $_ -match "reference\(resourceId\('Microsoft\.Insights/components'" })
    $earlyText = $early -join ' | '
    Assert-True 'main.bicep reads no Application Insights component itself (ARM would read it before the app modules create it)' ($early.Count -eq 0) $earlyText.Substring(0, [Math]::Min(300, $earlyText.Length))
    $settingsModule = @($compiled.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'qs-settings' })[0]
    $settingsParams = if ($settingsModule) { $settingsModule.properties.parameters } else { @{} }
    $fromOutputs = @('resolver', 'sync', 'reconciler') | Where-Object { [string]$settingsParams["${_}AppInsightsConnection"].value -match "outputs\.appInsightsConnectionString\.value" }
    Assert-True 'the settings module takes all three connection strings from the app modules outputs' (@($fromOutputs).Count -eq 3) "resolved=$($fromOutputs -join ',')"
}
# --- Parity 3: Cosmos data-plane roles equal D3's data ---
$sources = @('infra/poc/resolver-auth.assignments.json', 'infra/sync/sync.assignments.json', 'infra/reconciler/reconciler-permissions.json', 'docs/examples/onboarding.permissions.json')
$expectedAssignments = [System.Collections.Generic.List[string]]::new()
$expectedDefinitions = [System.Collections.Generic.List[string]]::new()
foreach ($s in $sources) {
    $data = Get-Content (Join-Path $root $s) -Raw | ConvertFrom-Json -AsHashtable
    foreach ($d in @($data.cosmosRoleDefinitions)) { $expectedDefinitions.Add("$($d.key)|$((@($d.dataActions) | Sort-Object) -join ',')") }
    foreach ($a in @($data.assignments | Where-Object { $_.plane -eq 'cosmos-data' })) {
        $principal = if ($a.principals -eq '${answers.permissions.privateRunnerPrincipalIds}') { 'runner' } elseif ($a.principal -match '^\$\{d1\.apps\.(\w+)\.principalId\}$') { $Matches[1] } else { "unmapped:$($a.principal)" }
        $scope = if ($a.scope -match '/colls/(\w+)$') { $Matches[1] } else { '' }
        $when = if ($a.when -eq 'answers.sync.mode == delegated-snapshot') { 'delegated-snapshot' } elseif ($a.when) { "unmapped:$($a.when)" } else { '' }
        $expectedAssignments.Add("$($a.id)|$principal|$($a.roleDefinitionId)|$scope|$when")
    }
}
$bicepDefinitions = if ($compiled) { Find-Variable $compiled 'cosmosRoleDefinitions' } else { $null }
$bicepAssignments = if ($compiled) { Find-Variable $compiled 'cosmosAssignments' } else { $null }
# The quick-start's own additions, each named in ADR-0024 (never a silent extra), its Proposed answer
# to open decision D-7 (no writer for `backends` in D3's data): the sync identity creates the projects
# and backends documents (step 5, the registrySeed function: no VM in a tenant whose policy denies
# marketplace VM images), and the runner, when enabled, holds the same create-only role on backends.
$quickstartAdditions = @(
    'qs-runner-backends-writer|runner|custom:onbProjectWriter|backends|'
    'qs-sync-projects-writer|sync|custom:onbProjectWriter|projects|'
    'qs-sync-backends-writer|sync|custom:onbProjectWriter|backends|'
)
Assert-True 'the Bicep declares cosmosRoleDefinitions and cosmosAssignments' ($null -ne $bicepDefinitions -and $null -ne $bicepAssignments)
if ($bicepDefinitions -and $bicepAssignments) {
    $gotDefinitions = @($bicepDefinitions | ForEach-Object { "$($_.key)|$((@($_.dataActions) | Sort-Object) -join ',')" } | Sort-Object)
    Assert-True 'Cosmos role definitions (key, data actions) equal D3 data' ((($expectedDefinitions | Sort-Object) -join "`n") -ceq ($gotDefinitions -join "`n")) "bicep=$($gotDefinitions -join ' ; ')"
    $gotAssignments = @($bicepAssignments | ForEach-Object { "$($_.id)|$($_.principal)|$($_.role)|$($_.container)|$($_.when)" } | Sort-Object)
    $want = @(@($expectedAssignments) + $quickstartAdditions | Sort-Object)
    Assert-True 'Cosmos role assignments (principal, role, scope, condition) equal D3 data plus the named quick-start additions' (($want -join "`n") -ceq ($gotAssignments -join "`n")) "missing=$(@($want | Where-Object { $gotAssignments -cnotcontains $_ }) -join ' ; ') extra=$(@($gotAssignments | Where-Object { $want -cnotcontains $_ }) -join ' ; ')"
    $adr = Get-Content (Join-Path $root 'docs/adr/0024-single-administrator-quick-start.md') -Raw
    foreach ($addition in $quickstartAdditions) {
        $id = $addition.Split('|')[0]
        Assert-True "ADR-0024 names the quick-start addition $id and D-7" ($adr.Contains($id) -and $adr -match 'D-7') 'the addition is not recorded in the ADR'
    }
    # The VM-free seed (step 5): the sync identity creates projects and backends documents with
    # onbProjectWriter (readMetadata, items/read, items/create: no upsert, no replace), whatever the
    # runner, and keeps its Data Reader on projects.
    $writer = @($bicepDefinitions | Where-Object { $_.key -ceq 'onbProjectWriter' })[0]
    $writerActions = @($writer.dataActions | ForEach-Object { ($_ -split '/')[-1] } | Sort-Object)
    Assert-True 'onbProjectWriter allows readMetadata, items/read and items/create only' (($writerActions -join ',') -ceq 'create,read,readMetadata') ($writerActions -join ',')
    foreach ($container in 'projects', 'backends') {
        $a = @($bicepAssignments | Where-Object { $_.principal -ceq 'sync' -and $_.role -ceq 'custom:onbProjectWriter' -and $_.container -ceq $container })
        Assert-True "the sync identity holds onbProjectWriter on $container in every sync mode" ($a.Count -eq 1 -and $a[0].when -ceq '') "found $($a.Count)"
    }
    Assert-True 'the sync identity keeps Cosmos DB Built-in Data Reader on projects' (@($bicepAssignments | Where-Object { $_.id -ceq 'sync-projects-reader' -and $_.principal -ceq 'sync' -and $_.role -ceq '00000000-0000-0000-0000-000000000001' -and $_.container -ceq 'projects' }).Count -eq 1)
    # With the runner off, main.bicep passes an empty runner principal and cosmos-data skips its
    # assignments (checked above): the writers left on projects and backends are the sync identity's.
    $writersOff = @($bicepAssignments | Where-Object { $_.role -ceq 'custom:onbProjectWriter' -and $_.principal -cne 'runner' } | ForEach-Object { "$($_.principal)/$($_.container)" } | Sort-Object)
    $runnerWriters = @($bicepAssignments | Where-Object { $_.principal -ceq 'runner' } | ForEach-Object id | Sort-Object)
    Assert-True 'with the runner off the only registry writer is the sync identity, and every runner assignment names the runner principal' (($writersOff -join ',') -ceq 'sync/backends,sync/projects' -and $runnerWriters.Count -eq 5) "writers=$($writersOff -join ',') runner=$($runnerWriters -join ',')"
}

# --- Template behaviour the live run needs (WP-QS r2) ---
function Find-Node {
    # Every dictionary in the compiled template for which the predicate holds.
    param($Node, [scriptblock]$Predicate)
    if ($Node -is [System.Collections.IDictionary]) {
        if (& $Predicate $Node) { , $Node }
        foreach ($k in $Node.Keys) { Find-Node $Node[$k] $Predicate }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) { foreach ($i in $Node) { Find-Node $i $Predicate } }
}
if ($compiled) {
    # 1. The three Flex Consumption apps share one subnet; in parallel ARM answered "Failed to acquire
    #    ServiceAssociationLinkLease" (Validation, 2026-10-13). @batchSize(1) compiles to a serial copy.
    $appsLoop = @(Find-Node $compiled { param($n) $n.Contains('copy') -and $n.copy -is [System.Collections.IDictionary] -and $n.copy.name -ceq 'apps' })
    Assert-True 'the apps module loop exists once' ($appsLoop.Count -eq 1) "found $($appsLoop.Count)"
    if ($appsLoop.Count -eq 1) {
        Assert-True 'the apps module loop deploys one app at a time (copy mode serial, batchSize 1)' ($appsLoop[0].copy.mode -eq 'serial' -and $appsLoop[0].copy.batchSize -eq 1) "mode '$($appsLoop[0].copy.mode)', batchSize '$($appsLoop[0].copy.batchSize)'"
    }

    # 2. Alerts off: ARM evaluates expressions of alert resources it does not deploy, so the APIM child
    #    template may read alertConfiguration only through its guard variable (InvalidTemplate naming
    #    actionGroup on the staged path, 2026-10-13).
    $apimChild = @(Find-Node $compiled { param($n) $n.Contains('variables') -and $n.variables -is [System.Collections.IDictionary] -and $n.variables.Contains('signalQueries') })
    Assert-True 'the APIM telemetry child template is in the compiled quick-start' ($apimChild.Count -eq 1) "found $($apimChild.Count)"
    if ($apimChild.Count -eq 1) {
        $childText = $apimChild[0] | ConvertTo-Json -Depth 100 -Compress
        $reads = ([regex]::Matches($childText, [regex]::Escape("parameters('alertConfiguration')"))).Count
        $guard = $apimChild[0].variables['alerting']
        Assert-True 'with alerts off nothing reads alertConfiguration outside the guard variable' ($reads -eq 1 -and "$guard" -match "parameters\('alertConfiguration'\)") "reads=$reads guard=$guard"
    }

    # 3. A parameters file filled from the public copy (ccof-bicep bbe0041 and fd43222, exported
    #    from 1201de0) still builds: every parameter added since has a default.
    $mainParams = $compiled.parameters
    $requiredAt1201de0 = @('apim', 'backends', 'cosmos', 'functions', 'gateway', 'groups', 'names', 'network', 'rateCard', 'reconciler', 'registrations', 'resolver', 'runner', 'sync', 'tags', 'tenantId', 'workbook')
    $requiredNow = @($mainParams.Keys | Where-Object { -not $mainParams[$_].Contains('defaultValue') } | Sort-Object)
    $newRequired = @($requiredNow | Where-Object { $requiredAt1201de0 -cnotcontains $_ })
    Assert-True 'no parameter added since 1201de0 is required' ($newRequired.Count -eq 0) "new required: $($newRequired -join ', ')"
}

# --- Runner optional (ccof-bicep da86afb): a tenant whose policy denies marketplace VM images deploys
#     everything else; runner.enabled (absent means false) decides whether the VM and its roles exist ---
if ($compiled) {
    $deployments = @($compiled.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' })
    $runnerDeployment = @($deployments | Where-Object { $_.name -match "-qs-runner'" })
    Assert-True 'the runner deployment exists once' ($runnerDeployment.Count -eq 1) "found $($runnerDeployment.Count)"
    $runnerEnabledVar = [string]$compiled.variables['runnerEnabled']
    Assert-True 'runnerEnabled reads runner.enabled through tryGet and defaults to false' ($runnerEnabledVar -match "^\[coalesce\(tryGet\(parameters\('runner'\), 'enabled'\), false\(\)\)\]$") "runnerEnabled = '$runnerEnabledVar'"
    if ($runnerDeployment.Count -eq 1) {
        $r = $runnerDeployment[0]
        Assert-True 'the runner deployment carries the condition runnerEnabled' ($r.condition -ceq "[variables('runnerEnabled')]") "condition '$($r.condition)'"
        $rp = $r.properties.parameters
        Assert-True 'vmSize, adminUsername and sshPublicKey are read through tryGet (absent when the runner is off)' ("$($rp.vmSize.value)" -match "tryGet\(parameters\('runner'\), 'vmSize'\)" -and "$($rp.adminUsername.value)" -match "tryGet\(parameters\('runner'\), 'adminUsername'\)" -and "$($rp.sshPublicKey.value)" -match "tryGet\(parameters\('runner'\), 'sshPublicKey'\)") "$($rp.vmSize.value) | $($rp.adminUsername.value) | $($rp.sshPublicKey.value)"
        Assert-True 'existing mode without runnerSubnetId: the runner subnet is read through tryGet' ("$($rp.subnetId.value)" -match "coalesce\(tryGet\(parameters\('network'\)\.existing, 'runnerSubnetId'\), ''\)") "$($rp.subnetId.value)"
    }
    $netDeployment = @($deployments | Where-Object { $_.name -match "-qs-network'" })
    Assert-True 'the network module gets the runner subnet only through tryGet (union with subnets.?runner)' ($netDeployment.Count -eq 1 -and "$($netDeployment[0].properties.parameters.subnets.value)" -match "^\[union\(parameters\('network'\)\.create\.subnets, createObject\('runner', tryGet\(parameters\('network'\)\.create\.subnets, 'runner'\)\)\)\]$") "$($netDeployment[0].properties.parameters.subnets.value)"
    $emptyWhenOff = "^\[if\(variables\('runnerEnabled'\), reference\(resourceId\('Microsoft\.Resources/deployments', format\('\{0\}-qs-runner', variables\('prefix'\)\)\), '[0-9-]+'\)\.outputs\.OUTPUT\.value, ''\)\]$"
    foreach ($module in 'cosmos-data', 'rbac') {
        $d = @($deployments | Where-Object { $_.name -match "-qs-$module'" })
        $runnerPrincipal = if ($d.Count -eq 1) { "$($d[0].properties.parameters.principals.value.runner)" } else { '' }
        Assert-True "principals.runner passed to $module is empty when the runner is off" ($runnerPrincipal -match $emptyWhenOff.Replace('OUTPUT', 'principalId')) $runnerPrincipal
    }
    Assert-True 'outputs runnerPrincipalId and runnerVmId are empty when the runner is off' ("$($compiled.outputs.runnerPrincipalId.value)" -match $emptyWhenOff.Replace('OUTPUT', 'principalId') -and "$($compiled.outputs.runnerVmId.value)" -match $emptyWhenOff.Replace('OUTPUT', 'vmId')) "$($compiled.outputs.runnerPrincipalId.value) | $($compiled.outputs.runnerVmId.value)"
    $active = [string](Find-Variable $compiled 'activeAssignments')
    Assert-True 'cosmos-data skips every assignment whose principal is empty (the runner''s when it is off)' ($active -match "not\(empty\(parameters\('principals'\)\[lambdaVariables\('a'\)\.principal\]\)\)") $active
    $rbacTemplate = @($deployments | Where-Object { $_.name -match "-qs-rbac'" })[0].properties.template
    $runnerReader = @($rbacTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.name -match "'runner'" })
    Assert-True 'the runner''s Reader role on the Cosmos account exists only with a runner principal' ($runnerReader.Count -eq 1 -and $runnerReader[0].condition -ceq "[not(empty(parameters('principals').runner))]") "condition '$($runnerReader[0].condition)'"
}

# --- infra/prereqs/network.bicep (ccof-bicep 6a2567a): the optional runner subnet is read with .?, so
#     an absent or dropped null property cannot fail the module; a present one builds the same subnet ---
$networkFile = Join-Path $root 'infra' 'prereqs' 'network.bicep'
$netAll = az bicep build --file $networkFile --stdout 2>&1
$netCompiled = if ($LASTEXITCODE -eq 0) { (@($netAll | Where-Object { $_ -is [string] }) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100 } else { $null }
Assert-True 'infra/prereqs/network.bicep compiles' ($null -ne $netCompiled) (@($netAll | Where-Object { $_ -isnot [string] }) -join ' ')
if ($netCompiled) {
    $netText = $netCompiled | ConvertTo-Json -Depth 100 -Compress
    $nullChecks = [regex]::Matches($netText, [regex]::Escape("equals(tryGet(parameters('subnets'), 'runner'), null())")).Count
    $direct = [regex]::Matches($netText, [regex]::Escape("equals(parameters('subnets').runner, null())")).Count
    Assert-True 'network.bicep tests the runner subnet only through tryGet (2 reads, 0 direct null checks)' ($nullChecks -eq 2 -and $direct -eq 0) "tryGet=$nullChecks direct=$direct"
    $runnerSubnetsVar = [string]$netCompiled.variables['runnerSubnets']
    Assert-True 'a present runner subnet is the same subnet: name and addressPrefix from subnets.runner' ($runnerSubnetsVar -ceq "[if(equals(tryGet(parameters('subnets'), 'runner'), null()), createArray(), createArray(createObject('name', parameters('subnets').runner.name, 'properties', createObject('addressPrefix', parameters('subnets').runner.prefix))))]") $runnerSubnetsVar
    $runnerOut = [string]$netCompiled.outputs.runnerSubnetId.value
    Assert-True 'a present runner subnet gives the same output: its subnet resource id' ($runnerOut -ceq "[if(equals(tryGet(parameters('subnets'), 'runner'), null()), '', resourceId('Microsoft.Network/virtualNetworks/subnets', parameters('vnetName'), parameters('subnets').runner.name))]") $runnerOut
    # VNets created after 2026-03-31 default subnets to private (no egress): the APIM and Functions
    # integration subnets set defaultOutboundAccess explicitly, true unless the caller has NAT/firewall egress.
    Assert-True 'network.bicep defaultOutboundAccess parameter defaults to true' ($netCompiled.parameters['defaultOutboundAccess'].type -eq 'bool' -and $netCompiled.parameters['defaultOutboundAccess'].defaultValue -eq $true)
    $vnetRes = @($netCompiled.resources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' })[0]
    $subnetText = [string]$vnetRes.properties.subnets
    $setCount = [regex]::Matches($subnetText, [regex]::Escape("'defaultOutboundAccess', parameters('defaultOutboundAccess')")).Count
    Assert-True 'the APIM and Functions subnets set defaultOutboundAccess explicitly' ($setCount -eq 2) $subnetText
}
$null = az bicep build --file (Join-Path $root 'infra' 'prereqs' 'all.bicep') --stdout 2>&1
Assert-True 'infra/prereqs/all.bicep (the staged path''s caller of network.bicep) still compiles' ($LASTEXITCODE -eq 0)

# --- Parameters file: compiles against the template ---
$param = Join-Path $qs 'main.bicepparam'
Assert-True 'infra/quickstart/main.bicepparam exists' (Test-Path $param)
if (Test-Path $param) {
    $stderrFile = Join-Path $PSScriptRoot ".env.qs-param-$(Get-Random).txt"
    $null = az bicep build-params --file $param --stdout 2> $stderrFile
    $exit = $LASTEXITCODE
    $diag = (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue) + ''
    Remove-Item $stderrFile -ErrorAction SilentlyContinue
    Assert-True 'main.bicepparam builds (az bicep build-params exit 0)' ($exit -eq 0) "exit=$exit $diag"
}

# --- Runner off by default in both parameters files, and every runner shape still builds ---
function Invoke-BuildParams {
    # az bicep build-params of a .bicepparam text, written next to main.bicep (its `using` path) under a
    # git-ignored .env.* name; returns the parameter values, or the error text.
    param([Parameter(Mandatory)] [string]$Text, [Parameter(Mandatory)] [string]$Label)
    $file = Join-Path $qs ".env.test-$([guid]::NewGuid().ToString('N').Substring(0, 8))-$Label.bicepparam"
    Set-Content -LiteralPath $file -Value $Text -Encoding utf8NoBOM
    try {
        $all = az bicep build-params --file $file --stdout 2>&1
        $errors = @($all | Where-Object { $_ -isnot [string] }) -join ' '
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Ok = $false; Values = $null; Errors = $errors } }
        $p = ((@($all | Where-Object { $_ -is [string] }) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100).parametersJson | ConvertFrom-Json -AsHashtable -Depth 100
        $v = @{}; foreach ($k in $p.parameters.Keys) { $v[$k] = $p.parameters[$k].value }
        return [pscustomobject]@{ Ok = $true; Values = $v; Errors = $errors }
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}
$form = Join-Path $qs 'customer-form.bicepparam'
Assert-True 'infra/quickstart/customer-form.bicepparam exists (ccof-bicep efcfe7f)' (Test-Path $form)
$mainText = Get-Content -LiteralPath $param -Raw
$built = Invoke-BuildParams -Text $mainText -Label 'main'
Assert-True 'main.bicepparam: runner = { enabled: false } and no runner subnet' ($built.Ok -and $built.Values.runner.enabled -eq $false -and @($built.Values.runner.Keys).Count -eq 1 -and -not $built.Values.network.create.subnets.Contains('runner')) "$($built.Errors) runner=$($built.Values.runner | ConvertTo-Json -Compress)"
function Assert-FamilyForm($Values,$Label) {
    Assert-True "$Label uses one developer/gateway app with v2 and distinct resolver" ($Values.registrations.gatewayApi.appId -ceq $Values.registrations.developerSignIn.appId -and $Values.registrations.gatewayApi.accessTokenVersion -eq 2 -and $Values.registrations.resolverApi.appId -cne $Values.registrations.gatewayApi.appId)
    $person=@(500000,2000000,500000);$group=@(2000000,5000000,2000000)
    for($i=0;$i -lt $Values.groups.Count;$i++) {
        $g=$Values.groups[$i];$limits=$g.familyPolicy.aggregateLimits
        Assert-True "$Label group $i retains aggregate ceilings verbatim" ($limits.person.tokensPerMinute -eq 1000000 -and $limits.person.tokenQuota -eq $person[$i] -and $limits.person.tokenQuotaPeriod -ceq 'Daily' -and $null -eq $limits.group.tokensPerMinute -and $limits.group.tokenQuota -eq $group[$i] -and $limits.group.tokenQuotaPeriod -ceq 'Daily')
        Assert-True "$Label group $i replaces legacy fields and supplies no restricted deployment placeholders" (-not $g.Contains('modelAllowList') -and -not $g.Contains('tokenLimits') -and $g.familyPolicy.families.Count -ge 1 -and -not $g.familyPolicy.families.Contains('fable') -and -not $g.familyPolicy.families.Contains('mythos'))
    }
    $selected=@($Values.groups|Where-Object {$_.projectId -ceq $Values.client.projectId -and $_.classification -ceq $Values.client.classification})
    $models=@($selected[0].familyPolicy.families.Values|ForEach-Object {$_.models})
    Assert-True "$Label client selection and aliases are explicit admitted models" ($selected.Count -eq 1 -and $Values.client.models.Count -eq 4 -and @($Values.client.models.Values|Where-Object {$models -cnotcontains $_}).Count -eq 0)
}
if($built.Ok) {Assert-FamilyForm $built.Values 'main.bicepparam'}
if (Test-Path $form) {
    $formText = Get-Content -LiteralPath $form -Raw
    $built = Invoke-BuildParams -Text $formText -Label 'form'
    Assert-True 'customer-form.bicepparam builds, with runner = { enabled: false } and no runner subnet' ($built.Ok -and $built.Values.runner.enabled -eq $false -and @($built.Values.runner.Keys).Count -eq 1 -and -not $built.Values.network.create.subnets.Contains('runner')) "$($built.Errors)"
    if($built.Ok) {Assert-FamilyForm $built.Values 'customer-form.bicepparam'}
    $replace = @(($formText -split "`n") | Where-Object { $_ -match 'REPLACE-' -and $_ -notmatch '^\s*//' })
    Assert-True 'the customer form marks every customer decision REPLACE, with no SSH key to fill' ($replace.Count -gt 0 -and $formText -notmatch 'sshPublicKey' -and $formText -notmatch 'snet-runner') "$($replace.Count) REPLACE lines"
    # The tenant, subscription and object ids of a filled form never enter the repository.
    $guids = @([regex]::Matches(($formText -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n", '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object Value)
    Assert-True 'the customer form holds no GUID except the workbook resource name' (@($guids | Where-Object { $_ -ne $built.Values.workbook.resourceName }).Count -eq 0) "$($guids -join ', ')"

    $runnerSubnet = "      functions: { name: 'snet-functions', prefix: 'REPLACE-functions-subnet-range' }`n      runner: { name: 'snet-runner', prefix: 'REPLACE-runner-subnet-range' }"
    $withSubnet = $formText.Replace("      functions: { name: 'snet-functions', prefix: 'REPLACE-functions-subnet-range' }", $runnerSubnet)
    $previous = $withSubnet.Replace('param runner = { enabled: false }', "param runner = { vmSize: 'Standard_D2as_v7', adminUsername: 'ccofadmin', sshPublicKey: 'REPLACE-ssh-public-key' }")
    $built = Invoke-BuildParams -Text $previous -Label 'previous-runner'
    Assert-True 'a form filled with the previous runner line and a runner subnet still builds; without enabled the runner stays off' ($previous -cne $formText -and $built.Ok -and -not $built.Values.runner.Contains('enabled') -and $built.Values.network.create.subnets.runner.name -eq 'snet-runner') "$($built.Errors)"
    $enabled = $withSubnet.Replace('param runner = { enabled: false }', "param runner = { enabled: true, vmSize: 'Standard_D2as_v7', adminUsername: 'ccofadmin', sshPublicKey: 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ example' }")
    $built = Invoke-BuildParams -Text $enabled -Label 'runner-enabled'
    Assert-True 'runner enabled true with a runner subnet builds' ($enabled -cne $withSubnet -and $built.Ok -and $built.Values.runner.enabled -eq $true -and $built.Values.network.create.subnets.runner.name -eq 'snet-runner') "$($built.Errors)"
    # Option B (existing subnets), uncommented, without runnerSubnetId.
    $optionA = [regex]::Match($formText, '(?ms)^param network = \{\r?\n  mode: ''create''.*?^\}\r?\n')
    $optionB = [regex]::Match($formText, '(?ms)^// param network = \{\r?\n//   mode: ''existing''.*?^// \}\r?\n')
    $existing = if ($optionA.Success -and $optionB.Success) {
        $b = (($optionB.Value -split "`n") | Where-Object { $_ -notmatch 'runnerSubnetId' } | ForEach-Object { $_ -replace '^// ?', '' }) -join "`n"
        $formText.Replace($optionA.Value, $b)
    } else { '' }
    $built = if ($existing) { Invoke-BuildParams -Text $existing -Label 'existing' } else { $null }
    Assert-True 'existing network mode without runnerSubnetId builds' ($built -and $built.Ok -and $built.Values.network.mode -eq 'existing' -and -not $built.Values.network.existing.Contains('runnerSubnetId')) "optionA=$($optionA.Success) optionB=$($optionB.Success) $($built.Errors)"
}

# --- The wrapper resumes from the first step not completed ---
$wrapper = Join-Path $qs 'Deploy-Quickstart.ps1'
Assert-True 'infra/quickstart/Deploy-Quickstart.ps1 exists' (Test-Path $wrapper)
if (Test-Path $wrapper) {
    . $wrapper -DotSourceOnly
    $work = Join-Path $PSScriptRoot ".env.qs-resume-$(Get-Random)"
    New-Item -ItemType Directory -Path $work | Out-Null
    $state = Join-Path $work 'state.json'
    $script:calls = [System.Collections.Generic.List[int]]::new()
    $script:failStep = 4
    $steps = @(1..8 | ForEach-Object {
            $n = $_
            [pscustomobject]@{ Number = $n; Name = "step$n"; Action = { param($Ctx) $script:calls.Add($Ctx.Step); if ($Ctx.Step -eq $script:failStep) { throw "fake failure in step $($Ctx.Step)" }; @{ ok = $true } } }
        })
    $first = Invoke-QuickstartSteps -Steps $steps -StatePath $state -Context @{}
    Assert-True 'a failed step 4 stops the run after steps 1-4' ((($script:calls) -join ',') -eq '1,2,3,4') "calls=$($script:calls -join ',')"
    Assert-True 'the run reports failure at step 4' ($first.Failed -eq 4) "failed=$($first.Failed)"
    $saved = Get-Content $state -Raw | ConvertFrom-Json -AsHashtable
    Assert-True 'the state file records steps 1-3 completed, not 4' ((@($saved.completed.Keys | Sort-Object) -join ',') -eq '1,2,3') "completed=$(@($saved.completed.Keys) -join ',')"
    $script:calls.Clear(); $script:failStep = 0
    $second = Invoke-QuickstartSteps -Steps $steps -StatePath $state -Context @{}
    Assert-True 'the rerun resumes at step 4 and runs 4-8' ((($script:calls) -join ',') -eq '4,5,6,7,8') "calls=$($script:calls -join ',')"
    Assert-True 'the rerun reports success' ($null -eq $second.Failed)
    $script:calls.Clear()
    $null = Invoke-QuickstartSteps -Steps $steps -StatePath $state -Context @{}
    Assert-True 'a run after all steps completed runs nothing' ($script:calls.Count -eq 0) "calls=$($script:calls -join ',')"
    $script:calls.Clear()
    $null = Invoke-QuickstartSteps -Steps $steps -StatePath $state -Context @{} -From 3
    Assert-True '-From 3 restarts at step 3 and runs 3-8' ((($script:calls) -join ',') -eq '3,4,5,6,7,8') "calls=$($script:calls -join ',')"
    $script:calls.Clear()
    $null = Invoke-QuickstartSteps -Steps $steps -StatePath $state -Context @{} -Only 7
    Assert-True '-Only 7 runs step 7 alone' ((($script:calls) -join ',') -eq '7') "calls=$($script:calls -join ',')"
    Remove-Item -Recurse -Force $work
}

Write-Host "`n$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
exit 0
