# DR standby -Phase Backends (infra/dr/Invoke-DrStandby.ps1; docs/runbooks/CICD-FOUNDRY-ONBOARDING.md).
# Adds Foundry backends to an existing region B with the primary's Stage 3 (APIM B identity on the
# account) and Stage 5 (APIM B backend entities and policy) only, after proving that the region B
# configuration differs from the verified one by those backends alone. The Grants, Config and Code
# evidence stays; Verify must run again.
Set-StrictMode -Version Latest

# The configuration without the named backends: the shape that region B was last verified with.
function Remove-DrStandbyBackends {
    param([Parameter(Mandatory)] [Collections.IDictionary]$Cfg, [Parameter(Mandatory)] [string[]]$BackendIds)
    $copy = $Cfg | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $copy['backends'] = @($copy['backends'] | Where-Object { $BackendIds -inotcontains [string]$_.id })
    return $copy
}

# Null when every listed stage record was verified either with the current inputs (an idempotent
# rerun) or with the current inputs minus the named backends; otherwise the refusal message.
function Get-DrStandbyBackendsScopeProblem {
    param(
        [Parameter(Mandatory)] [Collections.IDictionary]$Cfg,
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]]$BackendIds,
        [Parameter(Mandatory)] [Collections.IDictionary]$Records,
        [Parameter(Mandatory)] [scriptblock]$HashOf,
        [int[]]$Stages = @(3, 5)
    )
    $ids = @($BackendIds | Where-Object { $_ })
    if (-not $ids.Count) { return 'standby_backends_ids_required: name the added backends with -BackendIds.' }
    $known = @($Cfg['backends'] | Where-Object { $_ } | ForEach-Object { [string]$_.id })
    $unknown = @($ids | Where-Object { $known -inotcontains $_ })
    if ($unknown.Count) { return "standby_backends_unknown: $($unknown -join ', ') is not in the primary staged configuration backends; add it there first." }
    if ($ids.Count -eq $known.Count) { return 'standby_backends_scope: every backend is named; region B would have no verified backend. Use -Phase Grants and Config.' }
    $without = Remove-DrStandbyBackends -Cfg $Cfg -BackendIds $ids
    foreach ($n in $Stages) {
        $record = $Records["$n"]
        if (-not ($record -is [Collections.IDictionary]) -or -not $record['configHash']) { return "standby_backends_order: region B Stage $n has no verified record; run the full standby phases first." }
        $current = & $HashOf $Cfg $n
        if ($record['configHash'] -ceq $current) { continue }
        if ($record['configHash'] -cne (& $HashOf $without $n)) {
            return "standby_backends_scope: region B Stage $n inputs changed beyond the backends $($ids -join ', '); review the change and use -Phase Grants and Config (then Code and Verify)."
        }
    }
    return $null
}

# Null when both region B writers are off (the standby state that Stage 5 for region B writes).
# Region B serving as the active region (after failover) has them on: Stage 5 would turn them off.
function Get-DrStandbyWritersProblem {
    param([Parameter(Mandatory)] [hashtable]$Sync, [Parameter(Mandatory)] [hashtable]$Reconciler)
    $s = "$($Sync['AzureWebJobs.syncEntitlement.Disabled'])"; $r = "$($Reconciler['AzureWebJobs.reconcileBudgets.Disabled'])"
    if ($s -ieq 'true' -and $r -ieq 'true') { return $null }
    return "standby_backends_region_active: region B writers are not both off (sync disabled '$s', reconciler disabled '$r'). Region B may be serving after failover; Backends would turn its writers off. Add the backend with the primary procedure for the active region, or fail back first."
}

Export-ModuleMember -Function Remove-DrStandbyBackends, Get-DrStandbyBackendsScopeProblem, Get-DrStandbyWritersProblem
