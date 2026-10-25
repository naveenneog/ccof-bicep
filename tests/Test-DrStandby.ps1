# Offline tests for the DR standby region tooling (infra/dr/Invoke-DrStandby.ps1, ADR 0033).
# `az bicep build` compiles locally; no Azure call is made.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$repo = Split-Path $PSScriptRoot -Parent
function Build([string]$Relative) { (& az bicep build --file (Join-Path $repo $Relative) --stdout --only-show-errors 2>$null) -join "`n" | ConvertFrom-Json -Depth 100 }

# Stage 3 grants on resources shared by both regions (workspace, Cosmos account). Their names hash
# the assignment key, not the principal, so region B with the same names would overwrite region A's
# grants. A salt gives region B its own names; without it the names are those of region A.
$g = Build 'infra/staged/stage3-grants.bicep'
Check 'grants template has assignmentNameSalt defaulting to empty' ($g.parameters.assignmentNameSalt.defaultValue -ceq '')
$all = if ($g.resources -is [array]) { @($g.resources) } else { @($g.resources.PSObject.Properties.Value) }
$byType = @{}; foreach ($r in $all) { $byType[$r.type] += @($r) }
$reader = @($byType['Microsoft.Authorization/roleAssignments'] | Where-Object { $_.name -match 'logReader' })[0]
Check 'workspace reader name: unsalted form kept, salted form added' ($reader.name -match "if\(empty\(parameters\('assignmentNameSalt'\)\), guid\(resourceId\('Microsoft.OperationalInsights/workspaces'.*variables\('logReader'\)\), guid\(.*parameters\('assignmentNameSalt'\)\)\)")
$cosmos = @($byType['Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments'])[0]
Check 'Cosmos assignment name: unsalted form kept, salted form added' ($cosmos.name -match "if\(empty\(parameters\('assignmentNameSalt'\)\), guid\(.*'ccof-staged', variables\('activeAssignments'\)\[copyIndex\(\)\].id\), guid\(.*parameters\('assignmentNameSalt'\)\)\)")
$defs = @($byType['Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions'])[0]
Check 'Cosmos role definitions are not salted (shared by both regions)' ($defs.name -notmatch 'assignmentNameSalt')

# Region A's Stage 3 read-back counts only its own principals, so region B's grants on the shared
# workspace and Cosmos account do not fail it.
. (Join-Path $repo 'infra/staged/Invoke-StagedDeployment.ps1') -DotSourceOnly
$ErrorActionPreference = 'Stop'
$own = @{ resolver = 'aaaaaaaa-0000-4000-8000-000000000001'; reconciler = 'aaaaaaaa-0000-4000-8000-000000000002' }
$cosmosList = @(
    [pscustomobject]@{ principalId = 'AAAAAAAA-0000-4000-8000-000000000001'; scope = 'x' },
    [pscustomobject]@{ principalId = 'bbbbbbbb-0000-4000-8000-000000000009'; scope = 'x' })
$kept = @(Select-StgOwnAssignments -Assignments $cosmosList -Principals $own)
Check 'own principals kept (case-insensitive), other region dropped' ($kept.Count -eq 1 -and $kept[0].principalId -like 'AAAAAAAA*')
$armList = @([pscustomobject]@{ properties = [pscustomobject]@{ principalId = 'aaaaaaaa-0000-4000-8000-000000000002' } },
    [pscustomobject]@{ properties = [pscustomobject]@{ principalId = 'bbbbbbbb-0000-4000-8000-000000000009' } })
Check 'ARM role assignments filtered on properties.principalId' (@(Select-StgOwnAssignments -Assignments $armList -Principals $own).Count -eq 1)
Check 'no assignments gives an empty list' (@(Select-StgOwnAssignments -Assignments @() -Principals $own).Count -eq 0)

Write-Host "Test-DrStandby: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 7) { exit 1 }
