# Builds the exact driver command for one workflow step of .github/workflows/deploy-environment.yml.
# Pure functions (no Azure call) so the tests can check every step, guard and approval switch.
Set-StrictMode -Version Latest

$script:Approvals = [ordered]@{
    ExistingVnetUpdate        = @{ steps = @('drprereq-Bootstrap'); switch = '-ApproveExistingVnetUpdate' }
    CosmosThroughputReduction = @{ steps = @('standby-Data'); switch = '-ApproveCosmosThroughputReduction' }
    PublicApimBootstrap       = @{ steps = @('standby-Shells'); switch = '-ApprovePublicApimBootstrap' }
    PublicFunctionAccess      = @{ steps = @('standby-Shells'); switch = '-ApprovePublicFunctionAccess' }
    PrivateNetworkChanges     = @{ steps = @('standby-Network'); switch = '-ApprovePrivateNetworkChanges' }
    StandbyReady              = @{ steps = @('frontdoor-Deploy', 'frontdoor-Approve'); switch = '-ConfirmStandbyReady' }
}

function Get-CicdStepNames {
    @(0..7 | ForEach-Object { "staged-$_" }) + @('drprereq-Discover', 'drprereq-Bootstrap', 'drprereq-Verify') +
    @('Data', 'Shells', 'Grants', 'Config', 'Network', 'Code', 'Verify' | ForEach-Object { "standby-$_" }) +
    @('frontdoor-Deploy', 'frontdoor-Approve', 'frontdoor-Verify', 'health-a', 'health-b', 'failover-Status')
}

function Get-CicdApprovalNames { @($script:Approvals.Keys) }

<#
Returns @{ Script; Arguments; Mode; Log } for one step, or throws "<code>: <reason>".
  -Apply              change Azure (apply runner, environment <env>-apply or a gate)
  -Approve            named approvals; each is allowed only on its step and only with -Apply
  -PrimaryOnly        Front Door primary-only mode
  -ReviewedConnectionIds   Front Door Approve -Apply: the independently reviewed connection IDs
  -TestNotification   health step: send the test e-mail instead of deploying
#>
function Get-CicdDriverCommand {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Apply,
        [string[]]$Approve = @(),
        [switch]$PrimaryOnly,
        [string]$ReviewedConnectionIds = '',
        [switch]$TestNotification,
        [ValidateSet('A', 'B')][string]$Region = 'A'
    )
    if ($Environment -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') { throw "invalid_environment: '$Environment'" }
    if ((Get-CicdStepNames) -cnotcontains $Step) { throw "unknown_step: '$Step' (supported: $((Get-CicdStepNames) -join ', '); Lockdown, DrainPrimary, RestorePrimary, Fence, Promote, Failback and Stage 8 stay manual)" }
    $folder = "deploy/$Environment"
    $staged = "$folder/staged.config.json"; $dr = "$folder/dr-standby.config.json"
    $Approve = @($Approve | Where-Object { $_ } | ForEach-Object { $_.Trim() })
    foreach ($a in $Approve) {
        if (-not $script:Approvals.Contains($a)) { throw "unknown_approval: '$a'" }
        if ($script:Approvals[$a].steps -cnotcontains $Step) { throw "approval_not_for_step: $a applies to $($script:Approvals[$a].steps -join ', '), not $Step" }
        if (-not $Apply) { throw "approval_without_apply: $a is an apply-time approval; previews take none" }
    }
    if ($PrimaryOnly -and $Step -notlike 'frontdoor-*') { throw "primary_only_not_for_step: $Step" }
    if ($ReviewedConnectionIds -and $Step -ne 'frontdoor-Approve') { throw "reviewed_ids_not_for_step: $Step" }
    if ($TestNotification -and $Step -notlike 'health-*') { throw "test_notification_not_for_step: $Step" }
    $kind, $name = $Step -split '-', 2
    $argv = [Collections.Generic.List[string]]::new()
    $mode = if ($TestNotification) { 'test' } elseif ($Apply) { 'apply' } else { 'preview' }
    switch ($kind) {
        'staged' {
            $driver = 'infra/staged/Invoke-StagedDeployment.ps1'
            if ($name -eq '4') { Assert-CicdManualEntra (Join-Path $RepoRoot $staged) }
            $argv.AddRange([string[]]@('-Stage', $name, '-ConfigPath', $staged))
        }
        'drprereq' { $driver = 'infra/dr/Invoke-DrPrerequisites.ps1'; $argv.AddRange([string[]]@('-Phase', $name, '-ConfigPath', $dr, '-EvidenceDirectory', "$folder/.dr-evidence")) }
        'standby' {
            $driver = 'infra/dr/Invoke-DrStandby.ps1'
            $argv.AddRange([string[]]@('-Phase', $name, '-ConfigPath', $dr))
            if ($name -eq 'Code' -and $Apply) { $argv.Add('-PrivatePublisher') }
        }
        'frontdoor' {
            $driver = 'infra/dr/Invoke-DrFrontDoor.ps1'
            $argv.AddRange([string[]]@('-Phase', $name, '-ConfigPath', $dr))
            if ($PrimaryOnly) { $argv.Add('-PrimaryOnly') }
            if ($PrimaryOnly -and $Approve -contains 'StandbyReady') { throw 'standby_ready_not_primary_only: primary-only Front Door needs no standby readiness' }
            if (-not $PrimaryOnly -and $Apply -and $name -in 'Deploy', 'Approve' -and $Approve -notcontains 'StandbyReady') { throw "standby_ready_required: full Front Door $name -Apply needs the StandbyReady approval (gate frontdoor)" }
            if ($name -eq 'Approve' -and $Apply) {
                $ids = @($ReviewedConnectionIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if (-not $ids.Count) { throw 'reviewed_ids_required: Approve -Apply needs the connection IDs reviewed by the resource owners (workflow input)' }
                $bad = @($ids | Where-Object { $_ -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/.+/privateEndpointConnections/[^/]+$' })
                if ($bad.Count) { throw "reviewed_ids_invalid: not a private endpoint connection ID: $($bad -join ', ')" }
                $argv.AddRange([string[]]@('-ReviewedConnectionIds', ($ids -join ',')))
            }
        }
        'health' {
            $driver = 'infra/monitoring/Invoke-HealthAlerts.ps1'
            if ($TestNotification -and -not $Apply) { throw 'test_notification_requires_apply_runner: the test e-mail is a write (createNotifications); run it in the apply job' }
            $argv.AddRange([string[]]@('-ConfigPath', "$folder/health-$name.json", '-StateDirectory', "$folder/.health-alerts-$name"))
            if ($TestNotification) { $argv.Add('-TestNotification') }
        }
        'failover' {
            $driver = 'infra/dr/Invoke-DrFailover.ps1'
            if ($Apply) { throw 'failover_apply_refused: only Status runs in the pipeline; Fence, Promote and Failback follow docs/DR-ACTIVE-PASSIVE.md by hand' }
            $argv.AddRange([string[]]@('-Phase', 'Status', '-ConfigPath', $dr, '-Region', $Region))
        }
    }
    if ($Apply -and -not $TestNotification) { $argv.Add('-Apply') }
    foreach ($a in $Approve) { $argv.Add($script:Approvals[$a].switch) }
    return [pscustomobject]@{ Script = $driver; Arguments = $argv.ToArray(); Mode = $mode; Log = "evidence/$Environment/$Step-$mode.log" }
}

# Stage 4 in the pipeline only verifies: without entra.manualVerification it would write through Graph.
function Assert-CicdManualEntra {
    param([string]$StagedConfigPath)
    if (-not (Test-Path -LiteralPath $StagedConfigPath)) { throw "config_missing: $StagedConfigPath" }
    $cfg = Get-Content -LiteralPath $StagedConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $mv = if ($cfg.Contains('entra') -and $cfg.entra -is [Collections.IDictionary] -and $cfg.entra.Contains('manualVerification')) { $cfg.entra.manualVerification } else { $null }
    if ($mv -isnot [Collections.IDictionary] -or -not "$($mv['confirmedBy'])".Trim() -or "$($mv['confirmedOn'])" -notmatch '^\d{4}-\d{2}-\d{2}$') {
        throw 'stage4_graph_write_refused: entra.manualVerification (confirmedBy, confirmedOn) is required; the pipeline never creates or changes Entra objects. See docs/runbooks/CICD-NETWORK-ENTRA-CHECKLIST.md.'
    }
}

function Format-CicdCommand { param($Command) "pwsh -NoProfile -File $($Command.Script) $($Command.Arguments -join ' ')" }

# Drift = a what-if line the drivers print as "  <Create|Delete|Modify> <resource id>" (DR prerequisites: "what-if: <change> <id>").
# NoChange and Ignore are not drift; Deploy and Unsupported cannot be evaluated by what-if and are listed for review.
function Get-CicdDrift {
    param([Parameter(Mandatory)][string[]]$LogPath)
    $rows = foreach ($p in $LogPath) {
        if (-not (Test-Path -LiteralPath $p)) { [pscustomobject]@{ Log = (Split-Path $p -Leaf); Change = 'MissingLog'; Id = $p }; continue }
        foreach ($l in Get-Content -LiteralPath $p) {
            if ($l -cmatch '^(?:\s{2}|what-if: )(Create|Delete|Modify|Deploy|Unsupported)\s+(\S+/\S+)\s*$') {
                [pscustomobject]@{ Log = (Split-Path $p -Leaf); Change = $Matches[1]; Id = $Matches[2] }
            }
        }
    }
    $rows = @($rows)
    [pscustomobject]@{
        Drift  = @($rows | Where-Object { $_.Change -in 'Create', 'Delete', 'Modify', 'MissingLog' })
        Review = @($rows | Where-Object { $_.Change -in 'Deploy', 'Unsupported' })
    }
}

Export-ModuleMember -Function Get-CicdStepNames, Get-CicdApprovalNames, Get-CicdDriverCommand, Assert-CicdManualEntra, Format-CicdCommand, Get-CicdDrift
