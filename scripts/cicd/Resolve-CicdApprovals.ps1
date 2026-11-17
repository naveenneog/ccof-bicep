<#
.SYNOPSIS
    Validates the deploy-environment "approvals" input and derives the driver approval flags.

.DESCRIPTION
    The input is a comma-separated list of exact, case-sensitive names: ExistingVnetUpdate, CosmosThroughputReduction,
    PublicFunctionAccess. Whitespace around an item is ignored; an empty input approves nothing extra. Any other text
    (a prefix or suffix such as DO_NOT_APPROVE_PublicFunctionAccess, a different case, an unknown name, an empty item,
    a duplicate or another separator) fails with approvals_invalid and writes no output, so no flag is derived from it.
    Output (and GITHUB_OUTPUT when set): approve_vnet, approve_cosmos, approve_shells. Standby Shells always gets
    PublicApimBootstrap; PublicFunctionAccess is added only when listed. Each apply still waits for its own
    environment approval (gate-network, apply, gate-security).

.EXAMPLE
    pwsh scripts/cicd/Resolve-CicdApprovals.ps1 -Approvals 'ExistingVnetUpdate,PublicFunctionAccess'
#>
[CmdletBinding()]
param([AllowEmptyString()][string]$Approvals = '')
$ErrorActionPreference = 'Stop'
$allowed = 'ExistingVnetUpdate', 'CosmosThroughputReduction', 'PublicFunctionAccess'
$names = [Collections.Generic.List[string]]::new()
if ($Approvals.Trim()) {
    foreach ($part in $Approvals.Split(',')) {
        $n = $part.Trim()
        if (-not $n) { throw "approvals_invalid: empty item in '$Approvals' (use a comma-separated list of $($allowed -join ', '))" }
        if ($n -cnotin $allowed) { throw "approvals_invalid: '$n' is not one of $($allowed -join ', ') (exact, case-sensitive)" }
        if ($names.Contains($n)) { throw "approvals_invalid: '$n' is listed twice" }
        $names.Add($n)
    }
}
$flags = [ordered]@{
    approve_vnet   = $(if ($names.Contains('ExistingVnetUpdate')) { 'ExistingVnetUpdate' } else { '' })
    approve_cosmos = $(if ($names.Contains('CosmosThroughputReduction')) { 'CosmosThroughputReduction' } else { '' })
    approve_shells = $(if ($names.Contains('PublicFunctionAccess')) { 'PublicApimBootstrap,PublicFunctionAccess' } else { 'PublicApimBootstrap' })
}
if ($env:GITHUB_OUTPUT) { $flags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Add-Content -LiteralPath $env:GITHUB_OUTPUT }
if ($env:GITHUB_STEP_SUMMARY) { "Extra approvals: $(if ($names.Count) { $names -join ', ' } else { 'none' })" | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }
[pscustomobject]$flags
