# Cosmos throughput inventory and changes for the DR Data phase.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DrStandby.psm1') -DisableNameChecking

function Test-DrCosmosMissingOffer {
    param([string]$Message)
    return $Message -match '\Aaz cosmosdb sql failed:\s*ERROR:\s*\(NotFound\)\s*Entity with the specified id does not exist in the system\.?(?:\s+More info:\s*https://aka\.ms/cosmosdb-tsg-not-found\.?)?\s*\z'
}

function Get-DrCosmosResourceArguments {
    param($Context, [string]$Kind, [string]$Name)
    $args = @('cosmosdb', 'sql', $Kind, 'show', '--subscription', $Context.subscription,
        '--resource-group', $Context.resourceGroup, '--account-name', $Context.account)
    if ($Kind -ceq 'container') { $args += @('--database-name', $Context.database) }
    return , ($args + @('--name', $Name))
}

function Get-DrCosmosOfferArguments {
    param($Context, [string]$Kind, [string]$Name, [string]$Operation)
    $args = @('cosmosdb', 'sql', $Kind, 'throughput', $Operation, '--subscription', $Context.subscription,
        '--resource-group', $Context.resourceGroup, '--account-name', $Context.account)
    if ($Kind -ceq 'container') { $args += @('--database-name', $Context.database) }
    return , ($args + @('--name', $Name))
}

function Assert-DrCosmosResource {
    param($Context, [string]$Kind, [string]$Name, [scriptblock]$InvokeAz)
    $expectedId = "$($Context.accountId)/sqlDatabases/$($Context.database)"
    if ($Kind -ceq 'container') { $expectedId += "/containers/$Name" }
    try { $resource = & $InvokeAz (Get-DrCosmosResourceArguments $Context $Kind $Name) }
    catch { throw "cosmos_resource_unverified: cannot read $Kind '$Name'; check its name, access and account before retrying. $($_.Exception.Message)" }
    $resourceName = [string](Get-DrValue $resource 'name')
    $resourceId = [string](Get-DrValue $resource 'id')
    $cosmosId = [string](Get-DrValue $resource 'resource.id')
    if ($resourceName -cne $Name -or $resourceId -ine $expectedId -or ($cosmosId -and $cosmosId -cne $Name)) {
        throw "cosmos_resource_unverified: $Kind '$Name' did not return the expected name and resource ID; inspect the configured account and database."
    }
    return $resource
}

function ConvertTo-DrCosmosRu {
    param($Value, [string]$Label)
    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number) -or $number -le 0) {
        throw "cosmos_throughput_invalid: $Label is missing or is not a positive RU/s value; inspect the throughput response."
    }
    return $number
}

function Get-DrCosmosOffer {
    param($Context, [string]$Kind, [string]$Name, [scriptblock]$InvokeAz)
    $args = Get-DrCosmosOfferArguments $Context $Kind $Name 'show'
    $response = $null
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try { $response = & $InvokeAz $args; break }
        catch {
            $message = $_.Exception.Message
            if (-not (Test-DrCosmosMissingOffer $message)) {
                throw "cosmos_throughput_read_failed: cannot read $Kind '$Name' throughput; check permissions and connectivity. $message"
            }
            if ($attempt -eq 1) { $global:LASTEXITCODE = 0; return $null }
            Start-Sleep -Seconds 1
        }
    }
    $expectedId = "$($Context.accountId)/sqlDatabases/$($Context.database)"
    if ($Kind -ceq 'container') { $expectedId += "/containers/$Name" }
    $expectedId += '/throughputSettings/default'
    $validIds = @($expectedId)
    if ($Kind -ceq 'container') {
        # The ARM throughput response example uses sqlContainers, although its GET path uses containers.
        $validIds += "$($Context.accountId)/sqlDatabases/$($Context.database)/sqlContainers/$Name/throughputSettings/default"
    }
    if ($validIds -inotcontains [string](Get-DrValue $response 'id') -or [string](Get-DrValue $response 'name') -cne 'default') {
        throw "cosmos_throughput_invalid: $Kind '$Name' returned an unexpected throughput resource ID or name."
    }
    $pending = [string](Get-DrValue $response 'resource.offerReplacePending')
    if ($pending -in @('true', '1')) { throw "cosmos_throughput_pending: $Kind '$Name' has a throughput change in progress; wait, then preview again." }
    if ($pending -and $pending -notin @('false', '0')) { throw "cosmos_throughput_invalid: $Kind '$Name' returned an unrecognized pending status." }
    $settings = Get-DrValue $response 'resource.autoscaleSettings'
    if ($null -ne $settings) {
        $mode = 'autoscale'
        $value = ConvertTo-DrCosmosRu (Get-DrValue $settings 'maxThroughput') "$Kind '$Name' autoscale maximum"
    } else {
        $mode = 'manual'
        $value = ConvertTo-DrCosmosRu (Get-DrValue $response 'resource.throughput') "$Kind '$Name' manual throughput"
    }
    $minimum = Get-DrValue $response 'resource.minimumThroughput'
    if ($null -ne $minimum -and "$minimum" -ne '') { $minimum = ConvertTo-DrCosmosRu $minimum "$Kind '$Name' minimum" }
    else { $minimum = 0 }
    return [ordered]@{ name = $Name; mode = $mode; value = $value; minimum = $minimum }
}

function Get-DrCosmosThroughputPlan {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [int]$Target,
        [Parameter(Mandatory)] [scriptblock]$InvokeAz
    )
    $null = Assert-DrCosmosResource $Context 'database' $Context.database $InvokeAz
    $database = Get-DrCosmosOffer $Context 'database' $Context.database $InvokeAz
    $listArgs = @('cosmosdb', 'sql', 'container', 'list', '--subscription', $Context.subscription,
        '--resource-group', $Context.resourceGroup, '--account-name', $Context.account, '--database-name', $Context.database)
    try { $listed = @(& $InvokeAz $listArgs) }
    catch { throw "cosmos_container_list_failed: cannot list containers in '$($Context.database)'. $($_.Exception.Message)" }
    if (-not $listed.Count) { throw "cosmos_container_list_empty: no containers returned for '$($Context.database)'; verify the account and database before proceeding." }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $listed) {
        $name = [string](Get-DrValue $row 'name')
        if ([string]::IsNullOrWhiteSpace($name) -or -not $names.Add($name)) {
            throw 'cosmos_container_list_invalid: a container name is empty or duplicated; inspect the inventory before proceeding.'
        }
    }
    $containers = [Collections.Generic.List[object]]::new()
    foreach ($name in @($names | Sort-Object -CaseSensitive)) {
        $containerResource = Assert-DrCosmosResource $Context 'container' $name $InvokeAz
        $offer = Get-DrCosmosOffer $Context 'container' $name $InvokeAz
        if ($null -eq $offer) {
            if ($null -ne (Get-DrValue $containerResource 'options.throughput') -or
                $null -ne (Get-DrValue $containerResource 'options.autoscaleSettings')) {
                throw "cosmos_throughput_scope_unknown: container '$name' reports dedicated throughput options but its offer is unreadable; inspect the container before retrying."
            }
            if ($null -eq $database) {
                throw "cosmos_throughput_scope_unknown: container '$name' has no readable dedicated offer and its database has no readable throughput; inspect both before retrying."
            }
            $offer = [ordered]@{ name = $name; mode = 'shared'; value = 0; minimum = 0 }
        }
        $containers.Add($offer)
    }
    # A missing or changed database offer during discovery makes the shared classification unsafe.
    $null = Assert-DrCosmosResource $Context 'database' $Context.database $InvokeAz
    $again = Get-DrCosmosOffer $Context 'database' $Context.database $InvokeAz
    if (($null -eq $database) -ne ($null -eq $again) -or
        ($null -ne $database -and ($database.mode -cne $again.mode -or $database.value -ne $again.value -or $database.minimum -ne $again.minimum))) {
        throw 'cosmos_inventory_changed: database throughput changed during inspection; preview again after it settles.'
    }
    if ($null -eq $database) { $database = [ordered]@{ name = $Context.database; mode = 'none'; value = 0; minimum = 0 } }
    foreach ($entry in @($database) + @($containers.ToArray())) {
        if ($entry.mode -ceq 'autoscale' -and $entry.minimum -gt 0 -and $Target -lt $entry.minimum) {
            throw "cosmos_target_below_minimum: '$($entry.name)' needs at least $($entry.minimum) RU/s; review the target and preview again."
        }
    }
    return [ordered]@{ database = $database; containers = $containers.ToArray(); target = $Target }
}

function Test-DrCosmosReduction {
    param($Entry, [int]$Target)
    return ($Entry.mode -ceq 'autoscale' -and $Entry.value -gt $Target) -or
        ($Entry.mode -ceq 'manual')
}

function Show-DrCosmosThroughputPlan {
    param($Plan)
    $entries = @(@{ kind = 'database'; offer = $Plan.database }) +
        @($Plan.containers | ForEach-Object { @{ kind = 'container'; offer = $_ } })
    foreach ($item in $entries) {
        $e = $item.offer; $label = "$($item.kind) $($e.name)"
        if ($e.mode -ceq 'none') { Write-Host "$label`: no database throughput offer."; continue }
        if ($e.mode -ceq 'shared') { Write-Host "$label`: shared database throughput; no dedicated offer or container change."; continue }
        if ($e.mode -ceq 'manual') {
            $action = "manual $($e.value) RU/s -> autoscale maximum $($Plan.target) RU/s (minimum $([int]($Plan.target / 10)) RU/s); Azure chooses an initial maximum and a temporary throughput reduction is possible"
        } elseif ($e.value -eq $Plan.target) {
            $action = "autoscale maximum $($e.value) RU/s; unchanged"
        } else {
            $action = "autoscale maximum $($e.value) -> $($Plan.target) RU/s"
        }
        if (Test-DrCosmosReduction $e $Plan.target) { $action += '; throughput reduction requires -ApproveCosmosThroughputReduction' }
        Write-Host "$label`: $action."
    }
}

function Test-DrCosmosPlanChanges {
    param($Plan)
    foreach ($entry in @($Plan.database) + @($Plan.containers)) {
        if ($entry.mode -ceq 'manual' -or ($entry.mode -ceq 'autoscale' -and $entry.value -ne $Plan.target)) { return $true }
    }
    return $false
}

function Test-DrCosmosPlanReduction {
    param($Plan)
    foreach ($entry in @($Plan.database) + @($Plan.containers)) {
        if (Test-DrCosmosReduction $entry $Plan.target) { return $true }
    }
    return $false
}

function Invoke-DrCosmosThroughputChanges {
    param($Context, $Plan, [scriptblock]$InvokeAz)
    $entries = @(@{ kind = 'database'; offer = $Plan.database }) +
        @($Plan.containers | ForEach-Object { @{ kind = 'container'; offer = $_ } })
    foreach ($item in $entries) {
        $kind = $item.kind; $planned = $item.offer
        if ($planned.mode -in @('none', 'shared') -or ($planned.mode -ceq 'autoscale' -and $planned.value -eq $Plan.target)) { continue }
        $current = Get-DrCosmosOffer $Context $kind $planned.name $InvokeAz
        if ($null -eq $current -or $current.mode -cne $planned.mode -or $current.value -ne $planned.value -or $current.minimum -ne $planned.minimum) {
            throw "cosmos_preview_stale: $kind '$($planned.name)' changed since preview; inspect it and preview again before applying."
        }
        if ($current.mode -ceq 'manual') {
            Write-Host "Migrating $kind $($planned.name) from manual to autoscale; Azure determines the initial maximum."
            $args = (Get-DrCosmosOfferArguments $Context $kind $planned.name 'migrate') + @('--throughput-type', 'autoscale')
            try { $null = & $InvokeAz $args }
            catch { throw "cosmos_throughput_write_failed: migration of $kind '$($planned.name)' may be partial; inspect and preview again. $($_.Exception.Message)" }
            try { $current = Get-DrCosmosOffer $Context $kind $planned.name $InvokeAz }
            catch { throw "cosmos_throughput_readback_failed: migration of $kind '$($planned.name)' may be partial; inspect and preview again. $($_.Exception.Message)" }
            if ($null -eq $current -or $current.mode -cne 'autoscale') {
                throw "cosmos_throughput_readback_failed: $kind '$($planned.name)' has not confirmed autoscale; wait and preview again."
            }
            if ($current.value -gt $Plan.target) {
                throw "cosmos_migration_repreview_required: $kind '$($planned.name)' migrated to $($current.value) RU/s, above the requested $($Plan.target). No reduction of this offer or region change was attempted; earlier throughput changes may be partial. Inspect, preview again and obtain approval."
            }
        }
        if ($current.minimum -gt 0 -and $Plan.target -lt $current.minimum) {
            throw "cosmos_target_below_minimum: $kind '$($planned.name)' now needs at least $($current.minimum) RU/s; preview again."
        }
        if ($current.value -ne $Plan.target) {
            $args = (Get-DrCosmosOfferArguments $Context $kind $planned.name 'update') + @('--max-throughput', "$($Plan.target)")
            try { $null = & $InvokeAz $args }
            catch { throw "cosmos_throughput_write_failed: update of $kind '$($planned.name)' may be partial; inspect and preview again. $($_.Exception.Message)" }
            try { $current = Get-DrCosmosOffer $Context $kind $planned.name $InvokeAz }
            catch { throw "cosmos_throughput_readback_failed: update of $kind '$($planned.name)' may be partial; inspect and preview again. $($_.Exception.Message)" }
        }
        if ($null -eq $current -or $current.mode -cne 'autoscale' -or $current.value -ne $Plan.target) {
            throw "cosmos_throughput_readback_failed: $kind '$($planned.name)' did not confirm autoscale maximum $($Plan.target); no region change was attempted."
        }
        Write-Host "  $kind $($planned.name) autoscale maximum $($Plan.target) RU/s verified."
    }
}

function Assert-DrCosmosThroughputApplied {
    param($Expected, $Actual)
    $before = @($Expected.database) + @($Expected.containers)
    $after = @($Actual.database) + @($Actual.containers)
    if ($before.Count -ne $after.Count) { throw 'cosmos_throughput_readback_failed: the database or container inventory changed; preview again.' }
    for ($i = 0; $i -lt $before.Count; $i++) {
        $want = $before[$i]; $got = $after[$i]
        $expectedMode = if ($want.mode -in @('none', 'shared')) { $want.mode } else { 'autoscale' }
        $expectedValue = if ($expectedMode -ceq 'autoscale') { $Expected.target } else { 0 }
        if ($want.name -cne $got.name -or $got.mode -cne $expectedMode -or $got.value -ne $expectedValue) {
            throw "cosmos_throughput_readback_failed: '$($want.name)' differs from the reviewed plan; no region change was attempted."
        }
    }
}

Export-ModuleMember -Function Get-DrCosmosThroughputPlan, Show-DrCosmosThroughputPlan, Test-DrCosmosPlanChanges, Test-DrCosmosPlanReduction, Invoke-DrCosmosThroughputChanges, Assert-DrCosmosThroughputApplied
