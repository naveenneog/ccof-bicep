#Requires -Version 7.2
<#
.SYNOPSIS
  Runs the bundle-safe workbook modules as one command each. Without -Apply nothing in Azure changes.

.DESCRIPTION
  Discovery  = 01.1, 01.3-01.6 (read-only; writes customer-values.json privately)
  Roles      = 02.1-02.6 + 03.1-03.15 (6 Azure roles, 3 Cosmos role definitions, 11 Cosmos assignments)
  Settings   = 05.1-05.13 (backup, generate, merge, verify, remove old key-based AzureWebJobsStorage, timers check)
  Publish    = 07.1-07.9 (build app-specific ZIPs, publish, verify handlers)
  Artifacts  = 08.4-08.5 (offline registry validation, local policy/seed/workbook)

  Run in order: Discovery -> Roles -> Settings -> (06 by hand) -> Publish -> (08.1-08.3 by hand) -> Artifacts.
  Modules 04, 06, 09, 11, 13 stay one-step-at-a-time in the workbook.
  Each bundle without -Apply prints the plan. Rerun the same command with -Apply after review.
  All helpers reuse existing equivalent assignments/settings, so a rerun is safe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Discovery','Roles','Settings','Publish','Artifacts')][string]$Bundle,
    [switch]$Apply,
    [string]$Repo = (Join-Path $HOME 'ccof-bicep'),
    [string]$BundleDir = $PSScriptRoot,
    [string]$Out = (Join-Path $HOME 'ccof-private'),
    [string]$HelpersPath
)
$ErrorActionPreference = 'Stop'
if (-not $HelpersPath) { $HelpersPath = Join-Path $BundleDir 'Session-Helpers.ps1' }
. $HelpersPath

$inputFile  = Join-Path $Out 'customer-inputs.json'
$valuesFile = Join-Path $Out 'customer-values.json'
$apps = 'resolver','sync','reconciler'
$mode = if ($Apply) { 'APPLY' } else { 'PLAN (no Azure writes)' }

function Write-Step([string]$Id, [string]$Text) { Write-Host "[$Id] $Text" -ForegroundColor Cyan }

function Get-Values {
    if (-not (Test-Path $valuesFile)) { throw 'customer-values.json missing. Run -Bundle Discovery first.' }
    $c = Get-Content $valuesFile -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-CcofSession $c
    return $c
}

Write-Host "Bundle: $Bundle   Mode: $mode   Private folder: $Out" -ForegroundColor Yellow

switch ($Bundle) {

'Discovery' {
    if (-not (Test-Path $inputFile)) { throw "Fill $inputFile first (workbook 00.8 / 01.2)." }
    if ((Get-Content $inputFile -Raw) -match 'REPLACE-') { throw 'customer-inputs.json still contains REPLACE- placeholders.' }
    $in = Get-Content $inputFile -Raw | ConvertFrom-Json -AsHashtable -Depth 100

    Write-Step '01.1' "Resources in $($in.resourceGroup)"
    az resource list --subscription $in.subscriptionId -g $in.resourceGroup --query '[].{name:name,type:type}' -o table
    if ($LASTEXITCODE -ne 0) { throw 'Resource inventory failed.' }

    Write-Step '01.3' 'Read and verify live values (read-only)'
    Read-CcofCustomerValues -InputPath $inputFile -OutputPath $valuesFile
    $C = Get-Values

    Write-Step '01.4' 'Identity summary'
    $C.apps.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{App=$_.Key;Name=$_.Value.name;PrincipalId=$_.Value.principalId;ClientId=$_.Value.clientId;Storage=$_.Value.storageAccount;Container=$_.Value.deploymentContainer}
    } | Format-Table -AutoSize | Out-Host
    "Database: $($C.database)   APIM object ID: $($C.apimPrincipalId)   APIM client ID: $($C.apimClientId)"

    Write-Step '01.5' 'Cosmos containers and partition keys'
    $required = [ordered]@{ entitlement='/personId'; projects='/projectId'; subscriptionIndex='/subscriptionId'; budgetState='/personId'
        aggregateBudgetState='/scopeId'; syncLease='/id'; reconcilerLease='/id'; backends='/backendId' }
    $live = @(Invoke-CcofAzJson @('cosmosdb','sql','container','list','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-a',$C.cosmosAccount,'-d',$C.database))
    $rows = foreach ($k in $required.Keys) {
        $hit = $live | Where-Object { $_.resource.id -eq $k }
        $pk = if ($hit) { $hit.resource.partitionKey.paths[0] } else { '<missing>' }
        [pscustomobject]@{Container=$k;Required=$required[$k];Live=$pk;OK=($pk -eq $required[$k])}
    }
    $rows | Format-Table -AutoSize | Out-Host
    $bad = @($rows | Where-Object { -not $_.OK } | ForEach-Object Container)
    if ($bad) { Write-Warning "Fix these containers one at a time (workbook 01.5): $($bad -join ', ')" }

    Write-Step '01.6' 'Networking record (no change)'
    az cosmosdb show --subscription $C.subscriptionId -g $C.resourceGroup -n $C.cosmosAccount `
        --query '{public:publicNetworkAccess,localAuthDisabled:disableLocalAuth,vnetFilter:isVirtualNetworkFilterEnabled}' -o json
    if ($LASTEXITCODE -ne 0) { throw 'Cosmos networking read failed.' }
    foreach ($a in $apps) {
        az functionapp show --subscription $C.subscriptionId -g $C.resourceGroup -n $C.apps[$a].name `
            --query "{app:name,public:publicNetworkAccess,state:state}" -o json
        if ($LASTEXITCODE -ne 0) { throw "Function App read failed: $a" }
    }
    if ($bad) { throw 'Discovery found container problems; resolve before Roles.' }
    'Discovery PASS. Next: -Bundle Roles (plan), then -Bundle Roles -Apply.'
}

'Roles' {
    $C = Get-Values
    $azureRoles = @(
        @{Id='02.1'; P=$C.apps.resolver.principalId;   R='Storage Blob Data Owner';      S=$C.apps.resolver.storageId}
        @{Id='02.2'; P=$C.apps.sync.principalId;       R='Storage Blob Data Owner';      S=$C.apps.sync.storageId}
        @{Id='02.3'; P=$C.apps.reconciler.principalId; R='Storage Blob Data Owner';      S=$C.apps.reconciler.storageId}
        @{Id='02.4'; P=$C.apps.resolver.principalId;   R='Monitoring Metrics Publisher'; S=$C.apps.resolver.appInsightsResourceId}
        @{Id='02.5'; P=$C.apps.sync.principalId;       R='Monitoring Metrics Publisher'; S=$C.apps.sync.appInsightsResourceId}
        @{Id='02.6'; P=$C.apps.reconciler.principalId; R='Log Analytics Reader';         S=$C.workspaceResourceId}
    )
    foreach ($r in $azureRoles) {
        Write-Step $r.Id "$($r.R)"
        Grant-CcofAzureRole -C $C -PrincipalId $r.P -Role $r.R -Scope $r.S -Apply:$Apply
    }

    $kinds = [ordered]@{ '03.1'='sync'; '03.2'='reconciler'; '03.3'='seed' }
    foreach ($id in $kinds.Keys) {
        Write-Step $id "Cosmos role definition: $($kinds[$id])"
        Set-CcofCosmosRole -C $C -Kind $kinds[$id] -Directory $Out -Apply:$Apply
    }
    if (-not $Apply) {
        Write-Step '03.4-03.14' 'Cosmos assignments are planned after the role definitions exist (they need the definition IDs). Rerun with -Apply.'
        'Roles PLAN complete. Review, then rerun with -Apply.'
        return
    }
    $cosmos = @(
        @('03.4','resolver','reader',$null), @('03.5','sync','sync','entitlement'), @('03.6','sync','sync','syncLease'),
        @('03.7','sync','reader','projects'), @('03.8','sync','seed','projects'), @('03.9','sync','seed','backends'),
        @('03.10','reconciler','reader','projects'), @('03.11','reconciler','reader','entitlement'),
        @('03.12','reconciler','reconciler','budgetState'), @('03.13','reconciler','reconciler','aggregateBudgetState'),
        @('03.14','reconciler','reconciler','reconcilerLease')
    )
    foreach ($x in $cosmos) {
        Write-Step $x[0] "Cosmos $($x[2]) for $($x[1])$(if ($x[3]) { " on $($x[3])" })"
        $p = @{ C=$C; App=$x[1]; Kind=$x[2]; Apply=$true }
        if ($x[3]) { $p.Container = $x[3] }
        Grant-CcofCosmosRole @p
    }
    Write-Step '03.15' 'Native Cosmos assignments'
    az cosmosdb sql role assignment list --subscription $C.subscriptionId -g $C.resourceGroup -a $C.cosmosAccount `
        --query '[].{principal:principalId,scope:scope}' -o table
    if ($LASTEXITCODE -ne 0) { throw 'Cosmos assignment listing failed.' }
    'Roles APPLY complete (6 Azure + 3 definitions + 11 Cosmos). Next: module 04 Graph by the admin, then -Bundle Settings.'
}

'Settings' {
    $C = Get-Values
    $n = 1
    foreach ($a in $apps) {
        $name = $C.apps[$a].name
        Write-Step "05.$n" "Back up $a settings"; $n++
        $live = Invoke-CcofAzJson @('functionapp','config','appsettings','list','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-n',$name)
        $backup = Join-Path $Out "$a-before.json"
        if (Test-Path $backup) { Write-Host "  Keeping first backup $backup" } else { Save-CcofJson @($live) $backup }

        Write-Step "05.$n" "Generate $a settings locally"; $n++
        New-CcofAppSettings -C $C -App $a -Directory $Out
        $obj = Get-Content (Join-Path $Out "$a-settings.object.json") -Raw | ConvertFrom-Json -AsHashtable
        $liveNames = @($live | ForEach-Object { $_.name })
        $changed = @($obj.Keys | Where-Object { $liveNames -notcontains $_ -or (($live | Where-Object name -eq $_).value -ne [string]$obj[$_]) })
        "  Keys to add or change ($($changed.Count)): $($changed -join ', ')"
        $hasOldHost = $liveNames -contains 'AzureWebJobsStorage'
        "  Old key-based AzureWebJobsStorage present: $hasOldHost"

        if (-not $Apply) { $n += 2; continue }

        Write-Step "05.$n" "Merge $a settings"; $n++
        $file = Join-Path $Out "$a-settings.object.json"
        Invoke-CcofAzWrite @('functionapp','config','appsettings','set','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-n',$name,'--settings',"@$file")
        Test-CcofAppSettings -C $C -App $a -Directory $Out

        Write-Step "05.$n" "Remove old AzureWebJobsStorage on $a (only if present)"; $n++
        if ($hasOldHost) {
            Invoke-CcofAzWrite @('functionapp','config','appsettings','delete','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-n',$name,'--setting-names','AzureWebJobsStorage')
            Test-CcofAppSettings -C $C -App $a -Directory $Out
        } else { '  Already absent; skipped.' }
    }
    Write-Step '05.13' 'Timers must all be disabled'
    foreach ($a in 'sync','reconciler') {
        $t = @(Invoke-CcofAzJson @('functionapp','config','appsettings','list','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-n',$C.apps[$a].name)) |
            Where-Object { $_.name -like 'AzureWebJobs.*.Disabled' }
        $t | ForEach-Object { "  $a $($_.name)=$($_.value)" }
        if ($Apply -and ($t | Where-Object { $_.value -ne 'true' })) { throw "A timer on $a is not disabled. Stop." }
    }
    if ($Apply) { 'Settings APPLY complete. Next: module 06 resolver auth by hand, then -Bundle Publish.' }
    else { 'Settings PLAN complete. Review the *-settings.portal.json files, then rerun with -Apply.' }
}

'Publish' {
    $C = Get-Values
    $expected = @{ resolver=@('resolve','health'); sync=@('syncEntitlement'); reconciler=@('reconcileBudgets') }
    $i = 1
    foreach ($a in $apps) {
        Write-Step "07.$i" "Build $a ZIP (local)"; $i++
        pwsh -NoProfile -File (Join-Path $Repo 'scripts/portal/Build-PortalPackage.ps1') -App $a -OutputDirectory $Out
        if ($LASTEXITCODE -ne 0) { throw "$a package build failed." }
        $zip = Join-Path $Out "$a.zip"
        "  $zip SHA-256 $((Get-FileHash $zip -Algorithm SHA256).Hash)"

        if (-not $Apply) { $i += 2; continue }

        Write-Step "07.$i" "Publish $a"; $i++
        Invoke-CcofAzWrite @('functionapp','deployment','source','config-zip','--subscription',$C.subscriptionId,'-g',$C.resourceGroup,'-n',$C.apps[$a].name,'--src',$zip)

        Write-Step "07.$i" "Verify $a handlers"; $i++
        $found = @()
        foreach ($try in 1..12) {
            $found = @(az functionapp function list --subscription $C.subscriptionId -g $C.resourceGroup -n $C.apps[$a].name --query '[].name' -o tsv) |
                ForEach-Object { ($_ -split '/')[-1] }
            if ($LASTEXITCODE -eq 0 -and -not ($expected[$a] | Where-Object { $found -notcontains $_ })) { break }
            Start-Sleep -Seconds 15
        }
        "  Functions: $($found -join ', ')"
        $missing = @($expected[$a] | Where-Object { $found -notcontains $_ })
        if ($missing) { throw "$a is missing handlers: $($missing -join ', '). Check Log stream / App Insights before continuing." }
    }
    if ($Apply) { 'Publish APPLY complete. Next: fill registry/routing (08.1-08.3), then -Bundle Artifacts.' }
    else { 'Publish PLAN complete: ZIPs built locally. Rerun with -Apply to publish.' }
}

'Artifacts' {
    $C = Get-Values
    $registry = Join-Path $Out 'registry.json'; $routing = Join-Path $Out 'routing.json'
    foreach ($f in $registry, $routing) {
        if (-not (Test-Path $f)) { throw "Missing $f (workbook 08.1-08.3)." }
        if ((Get-Content $f -Raw) -match 'REPLACE-') { throw "$f still contains placeholders." }
    }
    Write-Step '08.4' 'Offline registry validation'
    node (Join-Path $BundleDir 'Validate-Registry.mjs') $Repo $registry (Join-Path $Out 'sync-settings.object.json')
    if ($LASTEXITCODE -ne 0) { throw 'Offline registry validation failed.' }
    Write-Step '08.5' 'Build policy, seed and chargeback workbook (local)'
    pwsh -NoProfile -File (Join-Path $BundleDir 'Build-LocalArtifacts.ps1') -Repository $Repo -ValuesPath $valuesFile `
        -RegistryPath $registry -RoutingPath $routing -OutputDirectory $Out
    if ($LASTEXITCODE -ne 0) { throw 'Artifact build failed. Do not apply partial output.' }
    'Artifacts complete (local only). Next: module 09 APIM one step at a time.'
}
}
