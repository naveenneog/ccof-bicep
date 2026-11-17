# Assembles the prerequisite checks for one environment folder (used by Test-CicdPrerequisites.ps1).
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CicdChecks.psm1')
Import-Module (Join-Path $PSScriptRoot 'CicdNetworkChecks.psm1')

$script:ConfigSource = 'docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md#3-environment-folder'
$script:Providers = @('Microsoft.Web', 'Microsoft.DocumentDB', 'Microsoft.Storage', 'Microsoft.Network', 'Microsoft.OperationalInsights',
    'Microsoft.Insights', 'Microsoft.ManagedIdentity', 'Microsoft.ApiManagement', 'Microsoft.AlertsManagement', 'Microsoft.App', 'Microsoft.Cdn', 'Microsoft.CognitiveServices')

function Read-CicdJson { param([string]$Path) if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { $null } }

$script:HealthSource = 'docs/runbooks/HEALTH-ALERTS.md#6-region-b-dr-standby'
$script:SharedRules = @{ cosmos = @('cosmosThrottled', 'cosmosServerErrors', 'cosmosAvailability'); frontDoor = @('frontDoorOriginHealth', 'frontDoor5xx') }
$script:IdleStandbyRules = @('reconcilerStale', 'gatewayTelemetrySilent')

# A DR environment deploys region B alerts (health-b.json) or records an explicit, approved opt-out
# (health-b.optout.json); the opt-out is reported as manual so the run summary shows that region B is not monitored.
function Get-CicdHealthBPresence {
    param([string]$Dir, $Dr, $HealthB, $OptOut)
    $t = 'health-b.json (region B alerts) or explicit opt-out'
    if ($HealthB -and $OptOut) { return New-CicdCheck 'config.health-b' 'config' $t 'fail' "both $Dir/health-b.json and $Dir/health-b.optout.json exist; keep one" $script:HealthSource }
    if ($OptOut) {
        $bad = @(foreach ($k in 'reason', 'approvedBy', 'approvedOn') { if (-not ($OptOut -is [Collections.IDictionary] -and $OptOut[$k] -is [string] -and $OptOut[$k].Trim())) { $k } })
        if (-not $bad.Count -and $OptOut.approvedOn -cnotmatch '^\d{4}-\d{2}-\d{2}$') { $bad = @('approvedOn (yyyy-MM-dd)') }
        if ($bad.Count) { return New-CicdCheck 'config.health-b' 'config' $t 'fail' "$Dir/health-b.optout.json needs non-empty $($bad -join ', ')" $script:HealthSource }
        return New-CicdCheck 'config.health-b' 'config' $t 'manual' "EXPLICIT OPT-OUT: NO region B health monitoring; approved by $($OptOut.approvedBy) on $($OptOut.approvedOn): $($OptOut.reason)" $script:HealthSource
    }
    if (-not $Dr) { return New-CicdCheck 'config.health-b' 'config' $t 'pass' 'no dr-standby.config.json: region B not applicable' $script:HealthSource }
    return New-CicdCheck 'config.health-b' 'config' $t 'fail' "$Dir/health-b.json missing for a DR environment; copy deploy/example/health-b.json, or record an approved $Dir/health-b.optout.json {reason, approvedBy, approvedOn} to run without region B alerts" $script:HealthSource
}

# The workspace, APIM and Cosmos account a health config resolves to, as Invoke-HealthAlerts.ps1 does.
function Get-CicdHealthEffective {
    param($H)
    $base = "/subscriptions/$($H['subscriptionId'])/resourceGroups/$($H['resourceGroup'])/providers"
    @{ workspace = $(if ($H['workspaceId']) { [string]$H['workspaceId'] } else { "$base/Microsoft.OperationalInsights/workspaces/$($H['stem'])-law" })
        apim = $(if (Get-CicdValue $H 'apim.id') { [string](Get-CicdValue $H 'apim.id') } else { "$base/Microsoft.ApiManagement/service/$($H['stem'])-apim" })
        cosmos = $(if ($H['cosmosId']) { [string]$H['cosmosId'] } else { "$base/Microsoft.DocumentDB/databaseAccounts/$($H['stem'])-cosmos" }) }
}
function Test-CicdHealthRuleOn { param($H, [string]$Name) $r = Get-CicdValue $H "rules.$Name"; -not ($r -is [Collections.IDictionary] -and $r.Contains('enabled') -and $r.enabled -eq $false) }
function Test-CicdProbeOn { param($H, [string]$Key) [string](Get-CicdValue $H "probes.$Key") -cne 'off' }

# Region B of a DR environment: the standby group and stem, the primary workspace and Cosmos account, its own APIM;
# a shared target (Cosmos, Front Door, Foundry) alerts from one region only; idle-standby rules are off in region B.
function Get-CicdHealthPairChecks {
    param($Dr, $HealthA, $HealthB)
    if (-not ($Dr -and $HealthA -and $HealthB)) { return }
    $ids = { param($h) @{ s = $h['subscriptionId']; r = $h['resourceGroup']; t = $h['stem']; w = $h['workspaceId']; c = $h['cosmosId']; p = (Get-CicdValue $h 'apim.id') } }
    if (@(Find-CicdPlaceholders (& $ids $HealthA)).Count -or @(Find-CicdPlaceholders (& $ids $HealthB)).Count) { return }
    $a = Get-CicdHealthEffective $HealthA; $b = Get-CicdHealthEffective $HealthB
    $suffix = [string](Get-CicdValue $Dr 'standby.nameSuffix'); if (-not $suffix) { $suffix = 'b' }
    $wantStem = "$($HealthA['stem'])-$suffix"; $wantRg = [string](Get-CicdValue $Dr 'secondary.resourceGroup')
    $bad = @(
        if ([string]$HealthB['subscriptionId'] -ine [string]$HealthA['subscriptionId']) { "subscriptionId $($HealthB['subscriptionId']) is not region A's $($HealthA['subscriptionId'])" }
        if ($wantRg -and [string]$HealthB['resourceGroup'] -ine $wantRg) { "resourceGroup $($HealthB['resourceGroup']) is not the DR secondary.resourceGroup $wantRg" }
        if ([string]$HealthB['stem'] -cne $wantStem) { "stem $($HealthB['stem']) is not $wantStem (<A stem>-<standby.nameSuffix>)" }
        if ($b.workspace -ine $a.workspace) { "workspace $(($b.workspace -split '/')[-1]) is not the primary workspace $(($a.workspace -split '/')[-1]) (set workspaceId)" }
        if ($b.apim -ieq $a.apim) { "APIM $(($b.apim -split '/')[-1]) is region A's APIM; region B watches the standby APIM" }
        if ($b.cosmos -ine $a.cosmos) { "Cosmos $(($b.cosmos -split '/')[-1]) is not the shared primary account $(($a.cosmos -split '/')[-1]) (set cosmosId)" })
    New-CicdCheck 'health.b.scope' 'health' 'Health alerts region B scope (standby APIM and apps, shared workspace and Cosmos)' $(if ($bad.Count) { 'fail' } else { 'pass' }) $(if ($bad.Count) { $bad -join '; ' } else { "stem $wantStem in $($HealthB['resourceGroup']); workspace $(($a.workspace -split '/')[-1]) and Cosmos $(($a.cosmos -split '/')[-1]) shared with region A; APIM $(($b.apim -split '/')[-1])" }) $script:HealthSource

    $dup = [Collections.Generic.List[string]]::new()
    if ($b.cosmos -ieq $a.cosmos) { foreach ($n in $script:SharedRules.cosmos) { if ((Test-CicdHealthRuleOn $HealthA $n) -and (Test-CicdHealthRuleOn $HealthB $n)) { $dup.Add("$n (Cosmos $(($a.cosmos -split '/')[-1]))") } } }
    $pa = [string](Get-CicdValue $HealthA 'frontDoor.profileId'); $pb = [string](Get-CicdValue $HealthB 'frontDoor.profileId')
    if ($pa -and $pa -ieq $pb) { foreach ($n in $script:SharedRules.frontDoor) { if ((Test-CicdHealthRuleOn $HealthA $n) -and (Test-CicdHealthRuleOn $HealthB $n)) { $dup.Add("$n (profile $(($pa -split '/')[-1]))") } } }
    $ha = [string](Get-CicdValue $HealthA 'frontDoor.host'); $hb = [string](Get-CicdValue $HealthB 'frontDoor.host')
    if ($ha -and $ha -ieq $hb -and (Test-CicdHealthRuleOn $HealthA 'availability') -and (Test-CicdHealthRuleOn $HealthB 'availability')) {
        foreach ($k in 'frontDoorGateway', 'frontDoorAdmin') { if ((Test-CicdProbeOn $HealthA $k) -and (Test-CicdProbeOn $HealthB $k)) { $dup.Add("probes.$k (web test on $ha)") } }
    }
    $fa = @($HealthA['foundryAccountIds'] | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $both = @($HealthB['foundryAccountIds'] | Where-Object { $_ -and $fa -contains ([string]$_).ToLowerInvariant() })
    if ($both.Count -and (Test-CicdHealthRuleOn $HealthA 'foundryServerErrors') -and (Test-CicdHealthRuleOn $HealthB 'foundryServerErrors')) { $dup.Add("foundryServerErrors ($(@($both | ForEach-Object { ($_ -split '/')[-1] }) -join ', '))") }
    New-CicdCheck 'health.shared-duplicates' 'health' 'Shared targets alert from one region only' $(if ($dup.Count) { 'fail' } else { 'pass' }) $(if ($dup.Count) { "enabled in both health-a.json and health-b.json: $($dup -join '; '); set rules.<name>.enabled false (or probes.<key> off) in health-b.json" } else { 'no Cosmos account, Front Door profile or host, or Foundry account is alerted from both regions' }) $script:HealthSource

    $idle = @($script:IdleStandbyRules | Where-Object { Test-CicdHealthRuleOn $HealthB $_ })
    New-CicdCheck 'health.b.standby-rules' 'health' 'Idle-standby rules off in region B' $(if ($idle.Count) { 'fail' } else { 'pass' }) $(if ($idle.Count) { "$($idle -join ', ') on in health-b.json: they fire continuously on an idle standby; set rules.<name>.enabled false (swap after Promote)" } else { 'reconcilerStale and gatewayTelemetrySilent off for the standby' }) $script:HealthSource
}
# foundryServerErrors is one switch per config and alerts on every account that config lists. Each listed account
# needs the rule on in at least one config that can alert on it (same subscription, or allowCrossSubscriptionFoundry).
function Get-CicdFoundryAccounts {
    param($HealthA, $HealthB)
    $cfgs = @(@{ n = 'health-a.json'; h = $HealthA }, @{ n = 'health-b.json'; h = $HealthB } | Where-Object { $_.h })
    $accounts = [ordered]@{}; $covered = [ordered]@{}; $why = @{}; $ids = @{}
    foreach ($c in $cfgs) {
        $on = Test-CicdHealthRuleOn $c.h 'foundryServerErrors'
        foreach ($id in @($c.h['foundryAccountIds'] | Where-Object { $_ -is [string] -and $_ })) {
            $k = $id.ToLowerInvariant(); if (-not $accounts.Contains($k)) { $accounts[$k] = ($id -split '/')[-1]; $why[$k] = [Collections.Generic.List[string]]::new() }
            $crossOk = ($id -split '/')[2] -ieq [string]$c.h['subscriptionId'] -or $c.h['allowCrossSubscriptionFoundry'] -eq $true
            if ($on -and $crossOk) { $covered[$k] = $c.n; $ids[$k] = $id }
            elseif (-not $on) { $why[$k].Add("rules.foundryServerErrors off in $($c.n)") }
            else { $why[$k].Add("another subscription and allowCrossSubscriptionFoundry not true in $($c.n)") }
        }
    }
    @{ configs = $cfgs.Count; accounts = $accounts; covered = $covered; why = $why; ids = $ids }
}
function Get-CicdFoundryCoverage {
    param($HealthA, $HealthB)
    $f = Get-CicdFoundryAccounts $HealthA $HealthB
    if (-not $f.configs) { return }
    $accounts = $f.accounts; $covered = $f.covered; $why = $f.why
    $t = 'Every listed Foundry account has a foundryServerErrors alert'
    if (-not $accounts.Count) { return New-CicdCheck 'health.foundry-coverage' 'health' $t 'pass' 'no foundryAccountIds listed: no Foundry metric alert planned' $script:HealthSource }
    $miss = @($accounts.Keys | Where-Object { -not $covered.Contains($_) })
    if ($miss.Count) { return New-CicdCheck 'health.foundry-coverage' 'health' $t 'fail' "not monitored: $(@($miss | ForEach-Object { "$($accounts[$_]) ($($why[$_] -join '; '))" }) -join ', '); enable foundryServerErrors in the config that lists it, or remove the ID" $script:HealthSource }
    New-CicdCheck 'health.foundry-coverage' 'health' $t 'pass' "$(@($accounts.Keys | ForEach-Object { "$($accounts[$_]) by $($covered[$_])" }) -join ', ')" $script:HealthSource
}

# Offline checks of the environment folder: files present, no REPLACE- placeholders, the DR config points at
# the staged config and state folders the workflow restores, and Stage 4 runs in manual (no Graph write) mode.
function Get-CicdConfigChecks {
    param([string]$Dir, [string[]]$Scope, $Staged, $Dr, $HealthA, $HealthB, $OptOut)
    $out = [Collections.Generic.List[object]]::new()
    $out.Add((New-CicdCheck 'config.staged' 'config' 'staged.config.json present' $(if ($Staged) { 'pass' } else { 'fail' }) $(if ($Staged) { "$Dir/staged.config.json read" } else { "$Dir/staged.config.json missing (copy deploy/example/staged.config.json)" }) $script:ConfigSource))
    $needDr = $Scope -contains 'standby' -or $Scope -contains 'frontdoor'
    if ($needDr) { $out.Add((New-CicdCheck 'config.dr' 'config' 'dr-standby.config.json present' $(if ($Dr) { 'pass' } else { 'fail' }) $(if ($Dr) { "$Dir/dr-standby.config.json read" } else { "$Dir/dr-standby.config.json missing; Front Door and the DR standby need it" }) $script:ConfigSource)) }
    foreach ($h in @(@{ n = 'a'; c = $HealthA }, @{ n = 'b'; c = $HealthB })) {
        if ($Scope -notcontains 'health') { break }
        if ($h.n -eq 'b' -and ($OptOut -or -not $h.c)) { $out.Add((Get-CicdHealthBPresence $Dir $Dr $HealthB $OptOut)); continue }
        if (-not $h.c) { $out.Add((New-CicdCheck "config.health-$($h.n)" 'config' "health-$($h.n).json present" 'fail' "$Dir/health-$($h.n).json missing" 'docs/runbooks/HEALTH-ALERTS.md')); continue }
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
    if ($Scope -contains 'health') {
        foreach ($c in @(Get-CicdHealthPairChecks $Dr $HealthA $HealthB)) { $out.Add($c) }
        $cov = Get-CicdFoundryCoverage $HealthA $(if ($OptOut) { $null } else { $HealthB }); if ($cov) { $out.Add($cov) }
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

# The workspace, APIM and Cosmos account each health config resolves to, as Invoke-HealthAlerts.ps1 does (workspaceId or
# <stem>-law, apim.id or <stem>-apim, cosmosId or <stem>-cosmos). Missing is a fail when no later step creates it: Stage 1
# creates no <stem>-apim with apim.existing, and the DR standby (region B) shares the primary workspace and Cosmos account.
# Otherwise manual until Stage 1.
function Test-CicdHealthTargets {
    param($Staged, [hashtable]$Configs)
    $src = 'docs/runbooks/HEALTH-ALERTS.md'
    foreach ($n in @('a', 'b')) {
        $h = $Configs[$n]
        if (-not $h -or @(Find-CicdPlaceholders @{ s = $h['subscriptionId']; r = $h['resourceGroup']; t = $h['stem'] }).Count) { continue }
        $eff = Get-CicdHealthEffective $h
        $targets = @(
            @{ key = 'workspaceId'; id = $eff.workspace; api = '2023-09-01'
                fixed = [bool]$h['workspaceId']; never = ($n -eq 'b'); why = 'the DR standby logs to the primary workspace; set workspaceId to it' }
            @{ key = 'apim.id'; id = $eff.apim; api = '2024-05-01'
                fixed = [bool](Get-CicdValue $h 'apim.id'); never = ($n -eq 'a' -and [bool](Get-CicdValue $Staged 'apim.existing')); why = 'Stage 1 uses apim.existing and creates no <stem>-apim; set apim.id to the existing APIM' }
            @{ key = 'cosmos'; id = $eff.cosmos; api = '2024-11-15'
                fixed = [bool]$h['cosmosId']; never = ($n -eq 'b'); why = 'the DR standby shares the primary Cosmos account; set cosmosId to it' }
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
        New-CicdCheck "health.$n.targets" 'health' "Health alerts region $($n.ToUpper()) workspace, APIM and Cosmos" $status ($ev -join '; ') $src
    }
}

# Invoke-HealthAlerts.ps1 alerts on ModelRequests (5xx StatusCode) or ServerErrors and skips an account with neither,
# with a note only; read the metric definitions of every covered account so a skipped account is not counted as monitored.
function Test-CicdFoundryMetrics {
    param($HealthA, $HealthB)
    $f = Get-CicdFoundryAccounts $HealthA $HealthB
    if (-not $f.covered.Count) { return }
    $status = 'pass'; $ev = @()
    foreach ($k in $f.covered.Keys) {
        $id = $f.ids[$k]; $name = $f.accounts[$k]
        if (@(Find-CicdPlaceholders @{ id = $id }).Count) { if ($status -eq 'pass') { $status = 'manual' }; $ev += "$name placeholder"; continue }
        $r = Invoke-CicdArmGet "$id/providers/Microsoft.Insights/metricDefinitions" '2018-01-01'
        if (-not $r.Ok) {
            if (Test-CicdNotFound $r.Error) { $status = 'fail'; $ev += "$name not found ($($f.covered[$k]))" }
            else { if ($status -eq 'pass') { $status = 'manual' }; $ev += "${name}: metric definitions unreadable ($(Get-CicdAzReason $r.Error)); verify the health preview plans its foundry alert" }
            continue
        }
        $names = @($r.Data.value | ForEach-Object { [string]$_.name.value })
        $m = if ($names -contains 'ModelRequests') { 'ModelRequests' } elseif ($names -contains 'ServerErrors') { 'ServerErrors' } else { $null }
        if ($m) { $ev += "$name $m ($($f.covered[$k]))" } else { $status = 'fail'; $ev += "$name has no ModelRequests or ServerErrors metric: the driver skips it, not monitored" }
    }
    New-CicdCheck 'health.foundry-metrics' 'health' 'Foundry accounts expose the metric the alert uses' $status ($ev -join '; ') 'docs/runbooks/HEALTH-ALERTS.md#foundryservererrors'
}

function Invoke-CicdPrerequisites {
    param([string]$Dir, [string]$Mode, [string[]]$Scope, [switch]$Offline)
    $staged = Read-CicdJson (Join-Path $Dir 'staged.config.json')
    $dr = Read-CicdJson (Join-Path $Dir 'dr-standby.config.json')
    $ha = Read-CicdJson (Join-Path $Dir 'health-a.json'); $hb = Read-CicdJson (Join-Path $Dir 'health-b.json'); $optOut = Read-CicdJson (Join-Path $Dir 'health-b.optout.json')
    $checks = [Collections.Generic.List[object]]::new()
    foreach ($c in (Get-CicdConfigChecks $Dir $Scope $staged $dr $ha $hb $optOut)) { $checks.Add($c) }
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
    if ($Scope -contains 'health') { $fm = Test-CicdFoundryMetrics $ha $(if ($optOut) { $null } else { $hb }); if ($fm) { $checks.Add($fm) } }
    return $checks.ToArray()
}

Export-ModuleMember -Function Read-CicdJson, Get-CicdConfigChecks, Get-CicdRequiredActions, Invoke-CicdPrerequisites
