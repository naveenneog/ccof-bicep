#Requires -Version 7.0
<#
.SYNOPSIS
Plans or grants one existing Function App's runtime access. No resource creation or Graph consent.
.DESCRIPTION
Uses the same permission definitions and verified apply engine as staged D3. Default is read-only.
Apply requires the operator's existing assignment rights, verifies the live app identity, refuses
custom-role rewrites and records a receipt. Reruns find existing grants. This does not elevate the app.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ParametersPath,
    [Parameter(Mandatory)] [string]$EvidencePath,
    [Parameter(Mandatory)] [ValidateSet('resolver', 'sync', 'reconciler')] [string]$App,
    [string]$OutputDirectory = '.env.portal-artifacts',
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'infra/quickstart/Deploy-Quickstart.ps1') -ParametersPath $ParametersPath -DotSourceOnly
Import-Module (Join-Path $PSScriptRoot 'Portal.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'scripts/Core.PermissionsApply.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'scripts/Core.Rest.psm1') -DisableNameChecking
$p = Read-QsParameters (Resolve-QsParametersPath $ParametersPath)
$evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$plan = New-PortalAccessPlan -P $p -Evidence $evidence -App $App
$sub = $p.names.subscriptionId
$account = Invoke-QsAz @('account', 'show', '--subscription', $sub)
if ($account.tenantId -ine $p.tenantId) { throw 'portal_tenant_mismatch: sign in to the approved tenant.' }
$send = {
    param($Method, $Url, $Body)
    $response = Invoke-CoreRest -SubscriptionId $sub -Method $Method -Url $Url -Body $Body
    if ($Method -eq 'GET' -and $response.Status -notin @(200, 404)) {
        throw "portal_read_failed: HTTP $($response.Status), code $($response.ErrorCode). An unreadable resource is not absent."
    }
    return $response
}.GetNewClosure()
$live = & $send 'GET' "https://management.azure.com$($evidence.apps[$App].functionAppId)?api-version=2024-04-01" $null
if ($live.Status -ne 200) { throw "portal_app_unreadable: HTTP $($live.Status)" }
$identity = $live.Content.identity
if ($App -eq 'resolver') {
    if ($identity.principalId -ine $evidence.apps[$App].principalId -or $identity.type -notmatch 'SystemAssigned') { throw 'portal_live_identity_mismatch: resolver system identity differs from the UI record.' }
} else {
    $matches = @($identity.userAssignedIdentities.Values | Where-Object {
        $_.principalId -ieq $evidence.apps[$App].principalId -and $_.clientId -ieq $evidence.apps[$App].clientId
    })
    if ($matches.Count -ne 1) { throw "portal_live_identity_mismatch: $App user-assigned identity is not attached." }
}
$plan.Items | Select-Object id, plane, role, principalId, scope | Format-Table -AutoSize | Out-Host
$definitions = Get-CoreCosmosDefinitionWrites -Plan $plan -D1 $evidence -Send $send
if ($definitions.Refusals.Count) { throw ($definitions.Refusals -join "`n") }
$definitions.Writes | Select-Object roleName, op, heldBy | Format-Table -AutoSize | Out-Host
if (@($definitions.Writes | Where-Object op -eq 'update').Count) { throw 'portal_role_rewrite_refused: an existing role differs; request a reviewed change or choose a fresh custom role name.' }
if (-not $Apply) { Write-Host 'READ-ONLY plan. Review the scopes, then repeat this command with -Apply.'; return }
$refusals = @(Get-CoreD3Refusals -Plan $plan -D1 $evidence -Send $send)
if ($refusals.Count) { throw ($refusals -join "`n") }
$out = Resolve-QsParametersPath $OutputDirectory
New-Item -ItemType Directory -Path $out -Force | Out-Null
$audit = [System.Collections.Generic.List[object]]::new()
$auditPath = Join-Path $out "$App-access-audit.json"
$onWrite = {
    param($Operation, $Key, $Id)
    $audit.Add(@{ at = [DateTime]::UtcNow.ToString('o'); operation = $Operation; key = $Key; id = $Id })
    ConvertTo-Json -InputObject @($audit.ToArray()) -Depth 10 | Set-Content -LiteralPath $auditPath -Encoding utf8NoBOM
}.GetNewClosure()
$results = @(Invoke-CoreD3Apply -Plan $plan -D1 $evidence -Send $send -DefinitionWrites $definitions.Writes -OnWrite $onWrite)
$results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $out "$App-access-receipt.json") -Encoding utf8NoBOM
$results | Select-Object id, state, reasonCode, assignmentId | Format-Table -AutoSize | Out-Host
if (@($results | Where-Object state -notin @('created', 'existing', 'inherited')).Count) { throw "portal_access_not_verified: review $App-access-receipt.json; rerun only this app after fixing the cause." }
Write-Host "$App access verified. No timer, resource, code, Graph permission or admin privilege was changed."
