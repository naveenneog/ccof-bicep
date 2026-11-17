# Assembles the prerequisite checks for one environment folder (used by Test-CicdPrerequisites.ps1).
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CicdChecks.psm1')
Import-Module (Join-Path $PSScriptRoot 'CicdNetworkChecks.psm1')

$script:ConfigSource = 'docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md#3-environment-folder'
$script:Providers = @('Microsoft.Web', 'Microsoft.DocumentDB', 'Microsoft.Storage', 'Microsoft.Network', 'Microsoft.OperationalInsights',
    'Microsoft.Insights', 'Microsoft.ManagedIdentity', 'Microsoft.ApiManagement', 'Microsoft.AlertsManagement', 'Microsoft.App', 'Microsoft.Cdn', 'Microsoft.CognitiveServices')

function Read-CicdJson { param([string]$Path) if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { $null } }

# Offline checks of the environment folder: files present, no REPLACE- placeholders, the DR config points at
# the staged config and state folders the workflow restores, and Stage 4 runs in manual (no Graph write) mode.
function Get-CicdConfigChecks {
    param([string]$Dir, [string[]]$Scope, $Staged, $Dr, $HealthA, $HealthB)
    $out = [Collections.Generic.List[object]]::new()
    $out.Add((New-CicdCheck 'config.staged' 'config' 'staged.config.json present' $(if ($Staged) { 'pass' } else { 'fail' }) $(if ($Staged) { "$Dir/staged.config.json read" } else { "$Dir/staged.config.json missing (copy deploy/example/staged.config.json)" }) $script:ConfigSource))
    $needDr = $Scope -contains 'standby' -or $Scope -contains 'frontdoor'
    if ($needDr) { $out.Add((New-CicdCheck 'config.dr' 'config' 'dr-standby.config.json present' $(if ($Dr) { 'pass' } else { 'fail' }) $(if ($Dr) { "$Dir/dr-standby.config.json read" } else { "$Dir/dr-standby.config.json missing; Front Door and the DR standby need it" }) $script:ConfigSource)) }
    foreach ($h in @(@{ n = 'a'; c = $HealthA }, @{ n = 'b'; c = $HealthB })) {
        if ($Scope -notcontains 'health') { break }
        if (-not $h.c -and $h.n -eq 'b') {
            # Invoke-HealthAlerts needs <stem>-cosmos in the target group; the DR standby shares the primary Cosmos account.
            $out.Add((New-CicdCheck 'config.health-b' 'config' 'health-b.json (region B alerts)' 'manual' "$Dir/health-b.json absent: no region B alert rules; the health driver needs <stem>-cosmos in region B, which a DR standby does not have (HEALTH-ALERTS.md section 6); watch region B with failover Status" 'docs/runbooks/HEALTH-ALERTS.md')); continue
        }        if (-not $h.c) { $out.Add((New-CicdCheck "config.health-$($h.n)" 'config' "health-$($h.n).json present" 'fail' "$Dir/health-$($h.n).json missing" 'docs/runbooks/HEALTH-ALERTS.md')); continue }
        $ph = @(Find-CicdPlaceholders $h.c)
        $fdOnly = $ph.Count -gt 0 -and @($ph | Where-Object { $_ -notlike 'frontDoor.*' }).Count -eq 0
        $status = if (-not $ph.Count) { 'pass' } elseif ($fdOnly) { 'manual' } else { 'fail' }
        $out.Add((New-CicdCheck "config.health-$($h.n)" 'config' "health-$($h.n).json complete" $status $(if (-not $ph.Count) { 'no placeholders' } elseif ($fdOnly) { "fill $($ph -join ', ') from the Front Door Deploy output before the health job" } else { "placeholders left: $($ph -join ', ')" }) 'docs/runbooks/HEALTH-ALERTS.md'))
    }
    foreach ($pair in @(@{ n = 'staged'; c = $Staged }, @{ n = 'dr'; c = $Dr })) {
        if (-not $pair.c) { continue }
        $ph = @(Find-CicdPlaceholders $pair.c)
        # Staged.Common.ps1 reads stage1.foundry only when create is true; an unused block may keep the example values.
        $fdUnused = $pair.n -eq 'staged' -and -not (Get-CicdValue $pair.c 'stage1.foundry.create')
        if ($fdUnused) { $ph = @($ph | Where-Object { $_ -notlike 'stage1.foundry.*' }) }
        # Invoke-DrFailover refuses a REPLACE- value in every phase (Status too); empty is valid until Promote.
        $hint = if ($ph -contains 'failover.ledgerCoverageStartAt') { ' (set failover.ledgerCoverageStartAt to empty until coverage is verified, DR-STANDBY-CLOUD-SHELL.md 5.2)' } else { '' }
        $out.Add((New-CicdCheck "config.$($pair.n).placeholders" 'config' "$($pair.n) config has no REPLACE- value" $(if ($ph.Count) { 'fail' } else { 'pass' }) $(if ($ph.Count) { "placeholders left: $($ph -join ', ')$hint" } else { 'no placeholders' }) $script:ConfigSource))
    }
    if ($Dr) {
        $want = [ordered]@{ stagedConfigPath = 'staged.config.json'; stagedStateDirectory = '.staged-state'; stateDirectory = '.dr-state' }
        $bad = @($want.Keys | Where-Object { [string](Get-CicdValue $Dr "standby.$_") -cne $want[$_] } | ForEach-Object { "standby.$_ must be '$($want[$_])'" })
        $out.Add((New-CicdCheck 'config.dr.paths' 'config' 'DR config uses the environment folder layout' $(if ($bad.Count) { 'fail' } else { 'pass' }) $(if ($bad.Count) { $bad -join '; ' } else { 'standby paths match the state folders the workflow restores and saves' }) $script:ConfigSource))
        # With an entra section, DR Discover reads the applications through Graph and blocks on read_denied.
        $hasEntra = [bool](Get-CicdValue $Dr 'entra')
        $out.Add((New-CicdCheck 'config.dr.entra' 'config' 'DR config leaves Entra manual (no entra section)' $(if ($hasEntra) { 'manual' } else { 'pass' }) $(if ($hasEntra) { 'entra section present: DR Discover reads the apps through Graph and stops on entra.<role>:read_denied unless the identity may read applications; omit it for manual Entra' } else { 'no entra section: DR Discover and Config make no Graph call' }) 'infra/dr/Invoke-DrPrerequisites.ps1; docs/runbooks/DR-STANDBY-CLOUD-SHELL.md section 7.3'))
        $same = $Staged -and $Dr.subscriptionId -ceq $Staged.subscriptionId -and $Dr.tenantId -ceq $Staged.tenantId
        $out.Add((New-CicdCheck 'config.dr.subscription' 'config' 'DR and staged configs target one tenant and subscription' $(if ($same) { 'pass' } else { 'fail' }) "staged $($Staged.subscriptionId) / dr $($Dr.subscriptionId)" $script:ConfigSource))
    }
    return $out.ToArray()
}

# Actions the identity needs at each scope. Preview needs reads only; apply needs the deployment actions.
function Get-CicdRequiredActions {
    param([string]$Mode, $Staged)
    $rg = "/subscriptions/$($Staged.subscriptionId)/resourceGroups/$($Staged.resourceGroup)"
    $list = [Collections.Generic.List[object]]::new()
    if ($Mode -eq 'preview') {
        $list.Add(@{ id = 'access.rg.read'; scope = $rg; actions = @('Microsoft.Resources/subscriptions/resourceGroups/read', 'Microsoft.Web/sites/read', 'Microsoft.DocumentDB/databaseAccounts/read') })
    } else {
        $list.Add(@{ id = 'access.rg.deploy'; scope = $rg; actions = @('Microsoft.Resources/deployments/write', 'Microsoft.Resources/deployments/whatIf/action', 'Microsoft.Web/sites/write', 'Microsoft.Web/serverfarms/write',
            'Microsoft.DocumentDB/databaseAccounts/write', 'Microsoft.ApiManagement/service/write', 'Microsoft.Storage/storageAccounts/write', 'Microsoft.ManagedIdentity/userAssignedIdentities/write',
            'Microsoft.Network/privateEndpoints/write', 'Microsoft.Cdn/profiles/write', 'Microsoft.Insights/components/write', 'Microsoft.Authorization/roleAssignments/write') })
        $e = Get-CicdValue $Staged 'network.existing'
        foreach ($k in 'functionsSubnetId', 'privateEndpointSubnetId', 'apimSubnetId') {
            $sn = [string](Get-CicdValue $e $k)
            if ($sn) { $list.Add(@{ id = "access.subnet.$k"; scope = $sn; actions = @('Microsoft.Network/virtualNetworks/subnets/join/action', 'Microsoft.Network/virtualNetworks/subnets/read') }) }
        }
        $dz = Get-CicdValue $Staged 'network.existing.privateDnsZoneIds'
        if ($dz -is [Collections.IDictionary]) { foreach ($k in $dz.Keys) { $list.Add(@{ id = "access.dns.$k"; scope = [string]$dz[$k]; actions = @('Microsoft.Network/privateDnsZones/join/action') }) } }
        foreach ($b in @($Staged.backends | Where-Object { $_.assignCognitiveServicesUser })) {
            $list.Add(@{ id = "access.foundry.$($b.id)"; scope = "/subscriptions/$($b.subscriptionId)/resourceGroups/$($b.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($b.accountName)"; actions = @('Microsoft.Authorization/roleAssignments/write') })
        }
    }
    return $list.ToArray()
}

# The workspace and APIM each health config resolves to, as Invoke-HealthAlerts.ps1 does (workspaceId or <stem>-law,
# apim.id or <stem>-apim). Missing is a fail when no later step creates it: Stage 1 does not create <stem>-apim when
# apim.existing is used, and the DR standby (region B) logs to the primary workspace. Otherwise manual until Stage 1.
function Test-CicdHealthTargets {
    param($Staged, [hashtable]$Configs)
    $src = 'docs/runbooks/HEALTH-ALERTS.md'
    foreach ($n in @('a', 'b')) {
        $h = $Configs[$n]
        if (-not $h -or @(Find-CicdPlaceholders @{ s = $h['subscriptionId']; r = $h['resourceGroup']; t = $h['stem'] }).Count) { continue }
        $base = "/subscriptions/$($h['subscriptionId'])/resourceGroups/$($h['resourceGroup'])/providers"
        $targets = @(
            @{ key = 'workspaceId'; id = $(if ($h['workspaceId']) { [string]$h['workspaceId'] } else { "$base/Microsoft.OperationalInsights/workspaces/$($h['stem'])-law" }); api = '2023-09-01'
                fixed = [bool]$h['workspaceId']; never = ($n -eq 'b'); why = 'the DR standby logs to the primary workspace; set workspaceId to it' }
            @{ key = 'apim.id'; id = $(if (Get-CicdValue $h 'apim.id') { [string](Get-CicdValue $h 'apim.id') } else { "$base/Microsoft.ApiManagement/service/$($h['stem'])-apim" }); api = '2024-05-01'
                fixed = [bool](Get-CicdValue $h 'apim.id'); never = ($n -eq 'a' -and [bool](Get-CicdValue $Staged 'apim.existing')); why = 'Stage 1 uses apim.existing and creates no <stem>-apim; set apim.id to the existing APIM' }
            @{ key = 'cosmos'; id = "$base/Microsoft.DocumentDB/databaseAccounts/$($h['stem'])-cosmos"; api = '2024-11-15'
                fixed = $false; never = ($n -eq 'b'); why = 'the DR standby shares the primary Cosmos account and the health driver has no Cosmos ID field; remove health-b.json' }
        )
        $status = 'pass'; $ev = @()
        foreach ($t in $targets) {
            $r = Invoke-CicdArmGet $t.id $t.api
            if ($r.Ok) { $ev += "$($t.key) $(($t.id -split '/')[-1]) found"; continue }
            $name = ($t.id -split '/')[-1]
            if (-not (Test-CicdNotFound $r.Error)) { if ($status -eq 'pass') { $status = 'manual' }; $ev += "$($t.key) ${name}: $(Get-CicdAzReason $r.Error)"; continue }
            if ($t.fixed -or $t.never) { $status = 'fail'; $ev += "$($t.key) $name not found ($(if ($t.fixed) { 'configured ID' } else { $t.why }))" }
            else { if ($status -eq 'pass') { $status = 'manual' }; $ev += "$($t.key) $name not found yet (Stage 1 creates it; the health job stops with *_missing otherwise)" }
        }
        New-CicdCheck "health.$n.targets" 'health' "Health alerts region $($n.ToUpper()) workspace and APIM" $status ($ev -join '; ') $src
    }
}

function Invoke-CicdPrerequisites {
    param([string]$Dir, [string]$Mode, [string[]]$Scope, [switch]$Offline)
    $staged = Read-CicdJson (Join-Path $Dir 'staged.config.json')
    $dr = Read-CicdJson (Join-Path $Dir 'dr-standby.config.json')
    $ha = Read-CicdJson (Join-Path $Dir 'health-a.json'); $hb = Read-CicdJson (Join-Path $Dir 'health-b.json')
    $checks = [Collections.Generic.List[object]]::new()
    foreach ($c in (Get-CicdConfigChecks $Dir $Scope $staged $dr $ha $hb)) { $checks.Add($c) }
    if (-not $staged) { return $checks.ToArray() }
    foreach ($c in (Test-CicdEntra $staged -Offline:$Offline)) { $checks.Add($c) }
    if ($Offline) { return $checks.ToArray() }

    $me = Get-CicdSignedInIdentity
    if (-not $me.Ok) { $checks.Add((New-CicdCheck 'access.signed-in' 'access' 'Azure CLI signed in' 'fail' "az account show failed: $(Get-CicdAzReason $me.Error)" '.github/actions/azure-login-mi')); return $checks.ToArray() }
    $tenantOk = $me.TenantId -ceq $staged.tenantId
    $checks.Add((New-CicdCheck 'access.signed-in' 'access' 'Signed-in identity and tenant' $(if ($tenantOk) { 'pass' } else { 'fail' }) "$($me.Type) $($me.Name) object $($me.ObjectId) in tenant $($me.TenantId)$(if (-not $tenantOk) { "; config tenant is $($staged.tenantId)" })" '.github/actions/azure-login-mi'))
    $checks.Add((Test-CicdResourceGroup $staged.subscriptionId $staged.resourceGroup))
    foreach ($req in (Get-CicdRequiredActions $Mode $staged)) {
        $checks.Add((Test-CicdScopeActions $req.id "Identity ($Mode) actions at $(($req.scope -split '/')[-1])" $me.ObjectId $req.scope $req.actions 'docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md#4-identities-and-roles'))
    }
    foreach ($c in (Test-CicdProviders $staged.subscriptionId $script:Providers)) { $checks.Add($c) }
    $regionB = [string](Get-CicdValue $dr 'secondary.location')
    foreach ($c in (Test-CicdRegionOffers $staged.subscriptionId $staged.location 'A' -Cosmos -Flex -Apim)) { $checks.Add($c) }
    if ($regionB -and $Scope -contains 'standby') { foreach ($c in (Test-CicdRegionOffers $staged.subscriptionId $regionB 'B' -Cosmos -Flex -Apim)) { $checks.Add($c) } }
    foreach ($c in (Test-CicdFoundryBackends $staged)) { $checks.Add($c) }
    foreach ($c in (Test-CicdNetwork $staged $(if ($Scope -contains 'standby') { $dr } else { $null }))) { $checks.Add($c) }
    if ($dr -and $Scope -contains 'frontdoor') { foreach ($c in (Test-CicdFrontDoorInputs $dr (Join-Path $Dir '.dr-state'))) { $checks.Add($c) } }
    if ($Scope -contains 'health') { foreach ($c in @(Test-CicdHealthTargets $staged @{ a = $ha; b = $hb })) { $checks.Add($c) } }
    return $checks.ToArray()
}

Export-ModuleMember -Function Read-CicdJson, Get-CicdConfigChecks, Get-CicdRequiredActions, Invoke-CicdPrerequisites
