#Requires -Version 7.0
# Offline tests for scripts/cicd/Resolve-CicdApprovals.ps1: the workflow input "approvals" is a comma-separated list of
# exact, case-sensitive approval names. Anything else (substring, prefix, negation, unknown, empty item, duplicate,
# other separator) fails closed before any flag is derived.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'scripts\cicd\Resolve-CicdApprovals.ps1'
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
function Resolve([string]$Value) {
    try { return @{ Ok = $true; R = (& $script -Approvals $Value) } } catch { return @{ Ok = $false; Error = $_.Exception.Message } }
}
$none = @{ approve_vnet = ''; approve_cosmos = ''; approve_shells = 'PublicApimBootstrap' }
function Same($r, $want) { $r.Ok -and @($want.Keys | Where-Object { $r.R.$_ -cne $want[$_] }).Count -eq 0 }

Check 'script exists' (Test-Path $script)

# Valid input.
Check 'empty input approves nothing extra' (Same (Resolve '') $none)
Check 'whitespace-only input approves nothing extra' (Same (Resolve "  `t ") $none)
Check 'PublicFunctionAccess alone' (Same (Resolve 'PublicFunctionAccess') @{ approve_vnet = ''; approve_cosmos = ''; approve_shells = 'PublicApimBootstrap,PublicFunctionAccess' })
Check 'ExistingVnetUpdate alone' (Same (Resolve 'ExistingVnetUpdate') @{ approve_vnet = 'ExistingVnetUpdate'; approve_cosmos = ''; approve_shells = 'PublicApimBootstrap' })
Check 'CosmosThroughputReduction alone' (Same (Resolve 'CosmosThroughputReduction') @{ approve_vnet = ''; approve_cosmos = 'CosmosThroughputReduction'; approve_shells = 'PublicApimBootstrap' })
$all = @{ approve_vnet = 'ExistingVnetUpdate'; approve_cosmos = 'CosmosThroughputReduction'; approve_shells = 'PublicApimBootstrap,PublicFunctionAccess' }
Check 'all three, spaces around items' (Same (Resolve ' ExistingVnetUpdate , CosmosThroughputReduction,PublicFunctionAccess ') $all)
Check 'all three, other order' (Same (Resolve 'PublicFunctionAccess,ExistingVnetUpdate,CosmosThroughputReduction') $all)
Check 'two of three' (Same (Resolve 'CosmosThroughputReduction, ExistingVnetUpdate') @{ approve_vnet = 'ExistingVnetUpdate'; approve_cosmos = 'CosmosThroughputReduction'; approve_shells = 'PublicApimBootstrap' })

# Fail closed: substring, prefix, suffix, negation, case, unknown, malformed.
$bad = @(
    'DO_NOT_APPROVE_PublicFunctionAccess', 'PublicFunctionAccess_NO', 'NotPublicFunctionAccess', 'PublicFunctionAccessX',
    '!PublicFunctionAccess', '-PublicFunctionAccess', 'no PublicFunctionAccess', 'PublicFunctionAccess=false', '"PublicFunctionAccess"',
    'publicfunctionaccess', 'PUBLICFUNCTIONACCESS', 'xExistingVnetUpdate', 'ExistingVnetUpdates', 'CosmosThroughputReduction?',
    'PublicApimBootstrap', 'PrivateNetworkChanges', 'StandbyReady', 'Unknown',
    'PublicFunctionAccess,', ',PublicFunctionAccess', 'ExistingVnetUpdate,,PublicFunctionAccess', ' , ',
    'PublicFunctionAccess;CosmosThroughputReduction', 'PublicFunctionAccess CosmosThroughputReduction',
    "PublicFunctionAccess`nCosmosThroughputReduction", 'PublicFunctionAccess,PublicFunctionAccess',
    'ExistingVnetUpdate,DO_NOT_APPROVE_PublicFunctionAccess'
)
foreach ($b in $bad) {
    $r = Resolve $b
    Check "neg: '$($b -replace "`n", '\n')' fails closed" (-not $r.Ok -and $r.Error -match '^approvals_invalid:')
}

# GitHub step output: exactly the three keys, one line each.
$out = Join-Path ([IO.Path]::GetTempPath()) ('ccof-approvals-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    $env:GITHUB_OUTPUT = $out
    $null = & $script -Approvals 'PublicFunctionAccess'
    $lines = @(Get-Content $out)
    Check 'GITHUB_OUTPUT has exactly the three flags' (($lines -join '|') -ceq 'approve_vnet=|approve_cosmos=|approve_shells=PublicApimBootstrap,PublicFunctionAccess')
    Remove-Item $out -Force
    $failed = $false; try { $null = & $script -Approvals 'DO_NOT_APPROVE_PublicFunctionAccess' } catch { $failed = $true }
    Check 'neg: invalid input writes no output' ($failed -and -not (Test-Path $out))
} finally { Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue; Remove-Item $out -Force -ErrorAction SilentlyContinue }

# The CLI (as the workflow runs it) exits non-zero on invalid input.
$o = & pwsh -NoProfile -Command "& '$script' -Approvals 'DO_NOT_APPROVE_PublicFunctionAccess'" 2>&1
Check 'neg: CLI exits non-zero on invalid input' ($LASTEXITCODE -ne 0 -and (@($o) -join ' ') -match 'approvals_invalid')

Write-Host "Test-CicdApprovals: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 39) { exit 1 }
