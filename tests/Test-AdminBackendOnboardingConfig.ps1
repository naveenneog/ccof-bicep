# Offline tests for the opt-in admin backend onboarding plumbing (ADR 0040): the Stage 3 Cosmos grant on
# `backends`, the Stage 5 admin settings, and the Stage 3 input hash. Off by default, so a deployment that
# does not set admin.backendOnboarding keeps its templates, parameters and stage hashes.
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$root = Split-Path $PSScriptRoot -Parent
function Build([string]$Relative) { (& az bicep build --file (Join-Path $root $Relative) --stdout --only-show-errors 2>$null) -join "`n" | ConvertFrom-Json -Depth 100 -AsHashtable }

# Stage 3: one admin row on `backends`, create-only role, only behind the flag.
$g = Build 'infra/staged/stage3-grants.bicep'
Check 'stage 3 has adminBackendOnboarding defaulting to false' ($g.parameters.Contains('adminBackendOnboarding') -and $g.parameters.adminBackendOnboarding.defaultValue -eq $false)
$rows = @($g.variables.cosmosAssignments | Where-Object { $_.principal -ceq 'admin' -and $_.container -ceq 'backends' })
Check 'admin backends grant is one onbProjectWriter row gated on onboarding' ($rows.Count -eq 1 -and $rows[0].role -ceq 'custom:onbProjectWriter' -and $rows[0].when -ceq 'onboarding')
$writer = @($g.variables.cosmosRoleDefinitions | Where-Object { $_.key -ceq 'onbProjectWriter' })[0]
Check 'onbProjectWriter cannot delete, replace or upsert' (-not ($writer.dataActions -match '/delete$|/replace$|/upsert$|/\*$'))
Check 'activeAssignments admits onboarding rows only with the flag' ("$($g.variables.activeAssignments)" -match "equals\(lambdaVariables\('a'\)\.when, 'onboarding'\), parameters\('adminBackendOnboarding'\)")

# Stage 5: the three optional settings are written only when configured.
$s5 = Build 'infra/staged/stage5-config.bicep'
$all = if ($s5.resources -is [Collections.IList]) { @($s5.resources) } else { @($s5.resources.Values) }
$props = "$((@($all | Where-Object { $_.type -ceq 'Microsoft.Web/sites/config' -and "$($_.name)" -match 'appsettings' -and "$($_.condition)" -match 'adminEnabled' })[0]).properties)"
$vars = ($s5.variables | ConvertTo-Json -Depth 50 -Compress)
foreach ($setting in 'ADMIN_BACKEND_ONBOARDING', 'ADMIN_RESOURCE_IDS', 'ADMIN_DISCOVERY_SCOPES') {
    Check "stage 5 writes $setting conditionally" (($props + $vars) -match $setting)
}
Check 'stage 5 onboarding flag is opt-in' (($props + $vars) -match "if\(coalesce\(tryGet\(parameters\('admin'\), 'backendOnboarding'\), false\(\)\), createObject\('ADMIN_BACKEND_ONBOARDING', 'true'\), createObject\(\)\)")
Check 'stage 5 resource IDs omitted when empty' (($props + $vars) -match "if\(empty\(variables\('adminResourceIdList'\)\), createObject\(\)")
Check 'stage 5 discovery scopes omitted when empty' (($props + $vars) -match "if\(empty\(variables\('adminDiscoveryScopeList'\)\), createObject\(\)")

# Stage 3 input hash and parameters: unchanged unless the flag is true.
. (Join-Path $root 'infra\staged\Invoke-StagedDeployment.ps1') -DotSourceOnly
$cfg = @{ tenantId = 't'; subscriptionId = 's'; resourceGroup = 'rg'; stage1 = @{}; cosmos = @{ databaseName = 'db'; roleNames = @{} }; sync = @{ mode = 'delegated-snapshot' }; backends = @(); admin = @{} }
$base = Get-StgStageInput $cfg 3
$cfg.admin.backendOnboarding = $false
Check 'stage 3 hash unchanged with the flag false' ((Get-StgStageInput $cfg 3) -ceq $base)
$cfg.admin.backendOnboarding = 'true'
Check 'stage 3 hash unchanged with a non-boolean flag' ((Get-StgStageInput $cfg 3) -ceq $base)
$cfg.admin.backendOnboarding = $true
Check 'stage 3 hash changes with the flag true' ((Get-StgStageInput $cfg 3) -cne $base)

function Get-StgStage { param($Cfg, $Number) return @{ names = @{}; principals = @{} } }
function Get-StgApimIdentity { return @{ principalId = 'p'; id = '/apim' } }
function Invoke-StgBicep { param($Cfg, $Template, $Name, $Apply, $Parameters) $script:captured = $Parameters; return $null }
function Get-StgStandbyOption { return $null }
foreach ($case in @(@{ v = $null; want = $false }, @{ v = 'true'; want = $false }, @{ v = $true; want = $true })) {
    $cfg.admin.backendOnboarding = $case.v; $script:captured = $null
    $null = Invoke-Stage3 -Cfg $cfg
    $got = $script:captured.Contains('adminBackendOnboarding') -and $script:captured.adminBackendOnboarding -eq $true
    Check "stage 3 passes adminBackendOnboarding=$($case.want) for '$($case.v)'" ($got -eq $case.want -and ($case.want -or -not $script:captured.Contains('adminBackendOnboarding')))
}

Write-Host "Admin backend onboarding config: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
