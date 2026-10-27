<#
.SYNOPSIS
  Turns on Log Analytics workspace replication to the standby region (ADR 0038 option 1).

.DESCRIPTION
  Replication copies only logs ingested after it is enabled
  (https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication), so it is enabled when
  region A is first deployed, before model traffic starts. The reconciler's ledger then has whole
  billing months in the replica from the next UTC month start (ADR 0038).

  The Azure CLI has no replication-location argument, and the REST call is a full-object PUT: the
  script reads the workspace, adds properties.replication and writes the whole object back, so SKU,
  retention and other settings stay unchanged. Without -Apply it only reads and prints the plan.
  Already enabled to the same region: nothing is changed. Enabled to another region: refused (exit 3).
  -Disable turns replication off with the same full-object PUT (no -Location needed); a replicated
  workspace cannot be deleted, and the replica region cannot be changed, until replication is off.

  Exit codes: 0 done or nothing to do, 2 input refused, 3 refused or failed, 5 still in progress.

.EXAMPLE
  pwsh -NoProfile -File infra/dr/Enable-WorkspaceReplication.ps1 -Subscription <id> -ResourceGroup <rg> -Location centralus
  pwsh -NoProfile -File infra/dr/Enable-WorkspaceReplication.ps1 -Subscription <id> -ResourceGroup <rg> -Location centralus -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Subscription,
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [string]$Workspace,
    [string]$Location,
    [switch]$Disable,
    [switch]$Apply,
    [int]$PollSeconds = 30,
    [int]$PollAttempts = 20
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Stop-Ws([string]$Message, [int]$Code) { [Console]::Error.WriteLine($Message); exit $Code }
if ($Subscription -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { Stop-Ws "input_refused: -Subscription '$Subscription' is not a subscription ID (GUID)." 2 }
if (-not $Disable -and -not $Location) { Stop-Ws 'input_refused: -Location (the standby region, for example centralus) is required unless -Disable.' 2 }
if ($Location -and $Location -notmatch '^[A-Za-z0-9 ]{3,40}$') { Stop-Ws "input_refused: -Location '$Location' is not a region name, for example centralus." 2 }
foreach ($v in @($ResourceGroup, $Workspace)) { if ($v -and $v -notmatch '^[A-Za-z0-9._-]{1,90}$') { Stop-Ws "input_refused: '$v' holds characters this script does not pass to az (letters, digits, . _ - only)." 2 } }
Import-Module (Join-Path $PSScriptRoot 'DrPrerequisites.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DrFailover.psm1') -Force
$azProfile = Resolve-DrAzureProfile -ConfigDir $env:AZURE_CONFIG_DIR -CloudShell $env:ACC_CLOUD -HomePath $HOME
if (-not $azProfile.Ok) { Stop-Ws $azProfile.Message 2 }
$env:AZURE_CONFIG_DIR = $azProfile.ConfigDir
$Location = ($Location -replace '\s', '').ToLowerInvariant()

try {
    if (-not $Workspace) {
        $names = @(Invoke-DrAzCli @('monitor', 'log-analytics', 'workspace', 'list', '--subscription', $Subscription, '--resource-group', $ResourceGroup) | ForEach-Object { $_.name })
        if ($names.Count -ne 1) { Stop-Ws "workspace_ambiguous: resource group $ResourceGroup has $($names.Count) workspaces ($($names -join ', ')); name one with -Workspace." 2 }
        $Workspace = $names[0]
    }
    $url = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/${Workspace}?api-version=2025-02-01"
    $ws = Invoke-DrAzCli @('rest', '--method', 'get', '--url', $url)
    $sku = if ($ws.properties.Contains('sku')) { $ws.properties.sku.name } else { '' }
    $retention = $ws.properties['retentionInDays']
    Write-Host "workspace $Workspace ($($ws.location)): sku $sku, retention $retention days"
    if ($Disable) {
        $cur = if ($ws.properties.Contains('replication')) { $ws.properties.replication } else { $null }
        if (-not ($cur -is [Collections.IDictionary]) -or $cur['enabled'] -ne $true) { Write-Host 'replication already off'; exit 0 }
        if (-not $Apply) { Write-Host "preview: disable replication to $($cur['location']) (full-object PUT; SKU, retention and other settings kept). Rerun with -Apply."; exit 0 }
        $bodyFile = Join-Path ([IO.Path]::GetTempPath()) "ccof-ws-replication-$([guid]::NewGuid().ToString('N')).json"
        try {
            New-DrReplicationBody -Workspace $ws -Disable | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
            $null = Invoke-DrAzCli @('rest', '--method', 'put', '--url', $url, '--headers', 'Content-Type=application/json', '--body', "@$bodyFile")
        } finally { Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue }
        for ($i = 0; $i -le $PollAttempts; $i++) {
            $ws = Invoke-DrAzCli @('rest', '--method', 'get', '--url', $url)
            $r = if ($ws.properties.Contains('replication')) { $ws.properties.replication } else { $null }
            if (-not ($r -is [Collections.IDictionary]) -or $r['enabled'] -ne $true) { break }
            if ($PollSeconds) { Start-Sleep -Seconds $PollSeconds }
        }
        $sku2 = if ($ws.properties.Contains('sku')) { $ws.properties.sku.name } else { '' }
        if ($sku2 -cne $sku -or $ws.properties['retentionInDays'] -ne $retention) { Stop-Ws "workspace_changed: SKU/retention read back '$sku2'/$($ws.properties['retentionInDays']) (were '$sku'/$retention)." 3 }
        if ($r -is [Collections.IDictionary] -and $r['enabled'] -eq $true) { Stop-Ws "replication_in_progress: replication still reads enabled ($($r['provisioningState'])); run the same command again in a few minutes." 5 }
        Write-Host 'replication: disabled (read back)'
        exit 0
    }
    $plan = Get-DrReplicationPlan -Workspace $ws -Location $Location
    if ($plan -ceq 'enable') {
        if (-not $Apply) { Write-Host "preview: enable replication to $Location (full-object PUT; SKU, retention and other settings kept). Rerun with -Apply."; exit 0 }
        $bodyFile = Join-Path ([IO.Path]::GetTempPath()) "ccof-ws-replication-$([guid]::NewGuid().ToString('N')).json"
        try {
            New-DrReplicationBody -Workspace $ws -Location $Location | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
            $null = Invoke-DrAzCli @('rest', '--method', 'put', '--url', $url, '--headers', 'Content-Type=application/json', '--body', "@$bodyFile")
        } finally { Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue }
        Write-Host "replication requested to $Location"
    } elseif ($plan -ceq 'none') { Write-Host "replication already enabled to $Location" }
    $state = $null
    for ($i = 0; $i -le $PollAttempts; $i++) {
        $ws = Invoke-DrAzCli @('rest', '--method', 'get', '--url', $url)
        $r = if ($ws.properties.Contains('replication')) { $ws.properties.replication } else { $null }
        $state = if ($r -is [Collections.IDictionary]) { [string]$r['provisioningState'] } else { '' }
        if ($state -ceq 'Succeeded' -or $state -ceq 'Failed' -or -not $Apply) { break }
        if ($PollSeconds) { Start-Sleep -Seconds $PollSeconds }
    }
    $sku2 = if ($ws.properties.Contains('sku')) { $ws.properties.sku.name } else { '' }
    if ($sku2 -cne $sku -or $ws.properties['retentionInDays'] -ne $retention) { Stop-Ws "workspace_changed: SKU/retention read back '$sku2'/$($ws.properties['retentionInDays']) (were '$sku'/$retention)." 3 }
    $c = Get-DrReplicationCoverage -Replication $r
    Write-Host "replication: $(if ($c.enabled) { 'enabled' } else { 'not enabled' }), $($c.location), $state"
    if ($c.enabled -and $c.fullMonthFrom) {
        Write-Host "workspace switchover allowed after $($c.switchoverAllowedAfter); full billing months in the replica from $($c.fullMonthFrom)"
    }
    if ($state -ceq 'Failed') { Stop-Ws 'replication_failed: provisioningState Failed; see the workspace Activity log.' 3 }
    if ($state -cne 'Succeeded') { Stop-Ws "replication_in_progress: provisioningState '$state'; run the same command again in a few minutes." 5 }
} catch {
    Stop-Ws "refused or failed: $_" 3
}
