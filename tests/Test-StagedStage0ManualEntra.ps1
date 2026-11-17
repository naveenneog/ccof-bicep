#Requires -Version 7.0
# Offline: Stage 0 with entra.manualVerification makes no Microsoft Graph call (a pipeline managed identity
# has no Graph token), and without it still reads the operator and the groups through Graph. No Azure call.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'infra\staged\Invoke-StagedDeployment.ps1') -DotSourceOnly
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }

$sub = '00000000-0000-4000-8000-000000000002'
$tenant = '00000000-0000-4000-8000-000000000001'
$script:graph = [Collections.Generic.List[string]]::new()
$script:evidence = @{}
function Invoke-StgAzJson { param([string[]]$Arguments)
    switch ($Arguments[0]) {
        'account' { return @{ id = $sub; name = 'fixture'; tenantId = $tenant; user = @{ name = '11111111-1111-4111-8111-111111111111'; type = 'servicePrincipal' } } }
        'provider' { return @{ registrationState = 'Registered' } }
        'functionapp' { return @(@{ name = 'East US 2' }) }
        default { return @() }
    }
}
function Invoke-QsAz { param([string[]]$Arguments) if ($Arguments[0] -eq 'group') { return 'false' }; return $null }
function Get-StgArm { param([string]$Path) if ($Path -match '/deployments$') { return @{ value = @(@{ name = 'claude-haiku-4-5' }) } }; return @{ id = $Path; name = 'acct'; properties = @{ publicNetworkAccess = 'Disabled' } } }
function Get-StgGraph { param([string]$Path) $script:graph.Add($Path); if ($Path -like 'me*') { return @{ id = 'me-id'; userPrincipalName = 'op@example.com' } }; return @{ securityEnabled = $true } }
function Write-StgEvidence { param([string]$Name, $Value) $script:evidence[$Name] = $Value }
function Read-StgState { param($Cfg) return @{ stages = @{} } }

function New-Cfg([switch]$Manual) {
    $c = @{
        tenantId = $tenant; subscriptionId = $sub; resourceGroup = 'rg-fixture'; location = 'eastus2'
        stage1 = @{ foundry = @{ create = $false } }
        backends = @(@{ id = 'be1'; subscriptionId = $sub; resourceGroup = 'rg-f'; accountName = 'acct'; deploymentInferenceGeo = @{ 'claude-haiku-4-5' = 'global' } })
        groups = @(@{ projectId = 'P1'; classification = 'STD'; groupId = '22222222-2222-4222-8222-222222222222' })
        entra = @{}
    }
    if ($Manual) { $c.entra.manualVerification = @{ confirmedBy = 'Entra team'; confirmedOn = '2026-11-17' } }
    return $c
}

$out = Invoke-Stage0 (New-Cfg -Manual) 6>$null
Check 'manual: no Graph call at all' ($script:graph.Count -eq 0)
Check 'manual: operator recorded as not read through Graph' ($out.operator.graph -match 'not read' -and $out.operator.signedIn -eq '11111111-1111-4111-8111-111111111111')
Check 'manual: every group listed for manual verification' (@($out.groups).Count -eq 1 -and $out.groups[0].verification -eq 'manual' -and $out.groups[0].groupId -eq '22222222-2222-4222-8222-222222222222')
Check 'manual: ARM checks still run (backend deployments)' (@($out.backends).Count -eq 1 -and $script:evidence.ContainsKey('stage0.json'))

$script:graph.Clear()
$out = Invoke-Stage0 (New-Cfg) 6>$null
Check 'graph mode unchanged: reads me and the group' ($script:graph.Count -eq 2 -and $script:graph[0] -like 'me*' -and $script:graph[1] -like 'groups/22222222*')
Check 'graph mode unchanged: operator from Graph' ($out.operator.upn -eq 'op@example.com')

# Negative: a tenant mismatch still refuses in manual mode.
$bad = New-Cfg -Manual; $bad.tenantId = '00000000-0000-4000-8000-000000000009'
$refused = $false
try { $null = Invoke-Stage0 $bad 6>$null } catch { $refused = $_.Exception.Message -match 'verify_failed: subscription' }
Check 'manual: tenant mismatch still refused' $refused

Write-Host "Test-StagedStage0ManualEntra: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 7) { exit 1 }
