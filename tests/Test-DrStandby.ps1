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

# Stage 6 network for region B in the same resource group: the Cosmos endpoint is named after the
# shared account, so region B needs a suffix; without one the names are those of region A.
$n = Build 'infra/staged/stage6-network.bicep'
Check 'network template has endpointNameSuffix defaulting to empty' ($n.parameters.endpointNameSuffix.defaultValue -ceq '')
$nAll = if ($n.resources -is [array]) { @($n.resources) } else { @($n.resources.PSObject.Properties.Value) }
$pes = @($nAll | Where-Object { $_.type -ceq 'Microsoft.Network/privateEndpoints' })
Check 'every private endpoint name ends with the suffix' ($pes.Count -eq 3 -and @($pes | Where-Object { $_.name -notmatch "parameters\('endpointNameSuffix'\)\)\]$" }).Count -eq 0)
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

# The standby region runs the primary's stage functions with a `standby` section in its derived
# configuration; without it the parameters and deployment names are unchanged.
$primaryCfg = @{ resourceGroup = 'rg' }
$standbyCfg = @{ resourceGroup = 'rg'; standby = @{ assignmentNameSalt = 'dr-b'; endpointNameSuffix = '-b'; stage1DeploymentName = 'dr-standby-shells' } }
$p3 = @{ names = @{} }
Check 'primary: Stage 3 parameters unchanged' (-not (Add-StgStandbyParameters $primaryCfg 3 $p3.Clone()).ContainsKey('assignmentNameSalt'))
Check 'standby: Stage 3 gets the salt' ((Add-StgStandbyParameters $standbyCfg 3 $p3.Clone()).assignmentNameSalt -ceq 'dr-b')
Check 'standby: Stage 6 gets the endpoint suffix' ((Add-StgStandbyParameters $standbyCfg 6 @{}).endpointNameSuffix -ceq '-b')
$p5 = Add-StgStandbyParameters $standbyCfg 5 @{ workbookContent = @{ x = 1 }; workbookContentTags = @{ y = 1 } }
Check 'standby: Stage 5 leaves the shared workbook alone' ($p5.workbookContent.Count -eq 0 -and $p5.workbookContentTags.Count -eq 0)
Check 'primary: Stage 5 keeps the workbook' ((Add-StgStandbyParameters $primaryCfg 5 @{ workbookContent = @{ x = 1 } }).workbookContent.x -eq 1)
Check 'Stage 1 deployment name: primary default, standby own' ((Get-StgStage1DeploymentName $primaryCfg) -ceq 'stage1-services' -and (Get-StgStage1DeploymentName $standbyCfg) -ceq 'dr-standby-shells')
Check 'stage deployment names: primary unchanged, standby prefixed' ((Get-StgDeploymentName $primaryCfg 'stage5-config') -ceq 'stage5-config' -and (Get-StgDeploymentName $standbyCfg 'stage5-config') -ceq 'dr-standby-stage5-config')

# ---- infra/dr/DrStandby.psm1
Import-Module (Join-Path $repo 'infra/dr/DrStandby.psm1') -Force
function New-DrCfg { $c = Get-Content (Join-Path $repo 'infra/dr/dr.config.example.json') -Raw | ConvertFrom-Json
    $c.standby.stagedConfigPath = 'staged.config.json'; $c.standby.stagedStateDirectory = '.staged-state'; $c.standby.stateDirectory = '.dr-standby-state'
    $c.standby.apim.publisherEmail = 'platform@contoso.example'; $c.standby.apim.publisherName = 'Contoso'; $c }
Check 'complete standby section has no problems' (@(Get-DrStandbyProblems (New-DrCfg)).Count -eq 0)
$x = Get-DrStandbyProblems (Get-Content (Join-Path $repo 'infra/dr/dr.config.example.json') -Raw | ConvertFrom-Json)
Check 'example placeholders are refused by name' ($x -contains 'standby.stagedConfigPath:placeholder' -and $x -contains 'standby.apim.publisherEmail:placeholder')
$c = New-DrCfg; $c.standby.nameSuffix = 'B-1'; Check 'name suffix must be 1-2 lowercase characters' (@(Get-DrStandbyProblems $c) -contains 'standby.nameSuffix:one_or_two_lowercase_letters_or_digits')
$c = New-DrCfg; $c.secondary.location = $c.primary.location; Check 'standby in the primary location refused' (@(Get-DrStandbyProblems $c) -contains 'secondary.location:same_as_primary')
$c = New-DrCfg; $c.standby.apim.sku = 'BasicV2'; Check 'BasicV2 refused (no private outbound)' (@(Get-DrStandbyProblems $c) -contains 'standby.apim.sku:StandardV2_or_PremiumV2')
$c = New-DrCfg; $c.cosmos.autoscaleMaxThroughput = 1500; Check 'autoscale max must be a multiple of 1000' (@(Get-DrStandbyProblems $c) -contains 'cosmos.autoscaleMaxThroughput:multiple_of_1000_from_1000')
$c = New-DrCfg; $c.cosmos.convertServerless = 'yes'; Check 'convertServerless must be a boolean' (@(Get-DrStandbyProblems $c) -contains 'cosmos.convertServerless:true_or_false')
$c = New-DrCfg; $c.standby.functionsPublicNetworkAccess = 'Open'; Check 'public access must be Enabled or Disabled' (@(Get-DrStandbyProblems $c) -contains 'standby.functionsPublicNetworkAccess:Enabled_or_Disabled')

$pn = @{ deploymentPrefix = 'lab1'; cosmosAccount = 'lab1-abc-cosmos'; logAnalyticsWorkspace = 'lab1-abc-law'
    apps = @{ resolver = @{ functionApp = 'lab1-abc-resolver'; storageAccount = 'lab1abcres' } } }
$n = Get-DrStandbyNames $pn 'b'
Check 'standby names derive from the primary stem' ($n.stem -ceq 'lab1-abc-b' -and $n.storageStem -ceq 'lab1abcb' -and $n.deploymentPrefix -ceq 'lab1b')
$threw = $false; try { $null = Get-DrStandbyNames @{ deploymentPrefix = 'x'; apps = @{ resolver = @{ functionApp = 'x-resolver'; storageAccount = 'lab1abcdefghijklmnopqrres' } } } 'bb' } catch { $threw = "$_" -match 'standby_storage_name_too_long' }
Check 'storage names over 24 characters refused' $threw

$primary = [ordered]@{ location = 'eastus2'; syncTimerEnabled = $true; reconciler = @{ timerEnabled = $true }; stage1 = @{ apimSku = 'StandardV2' }
    backends = @(@{ id = 'foundry-a'; privateEndpoint = $true }); network = @{ mode = 'create' }; __path = 'x' }
$zones = @{ cosmos = '/z/documents'; blob = '/z/blob' }
$b = New-DrStandbyStagedConfig -Primary $primary -Dr (New-DrCfg) -VnetId '/v/standby' -ZoneIds $zones
Check 'standby config: standby location' ($b.location -ceq 'centralus')
Check 'standby config: both writers off' ($b.syncTimerEnabled -eq $false -and $b.reconciler.timerEnabled -eq $false)
Check 'standby config: existing standby subnets and shared zones' ($b.network.mode -ceq 'existing' -and $b.network.existing.functionsSubnetId -ceq '/v/standby/subnets/snet-functions' -and $b.network.existing.privateDnsZoneIds.cosmos -ceq '/z/documents')
Check 'standby config: no second Foundry private endpoint' ($b.backends[0].privateEndpoint -eq $false)
Check 'standby config: standby section set' ($b.standby.stage1DeploymentName -ceq 'dr-standby-shells' -and $b.standby.endpointNameSuffix -ceq '-b')
Check 'primary configuration not modified' ($primary.syncTimerEnabled -eq $true -and $primary.backends[0].privateEndpoint -eq $true -and $primary.location -ceq 'eastus2')

$ps1 = [ordered]@{ names = $pn; cosmosAccountId = '/c'; cosmosEndpoint = 'https://c'; workspaceId = '/w'; workspaceCustomerId = 'ws' }
$shells = [ordered]@{ apps = @{ resolver = @{ functionApp = 'lab1-abc-b-resolver' } }; apimId = '/apim-b'; apimName = 'apim-b'; apimPrincipalId = 'p-apim'; apimGatewayUrl = 'https://b'
    functionApps = @(@{ key = 'resolver'; service = @{ principalId = 'p-res'; clientId = '' } }, @{ key = 'sync'; service = @{ principalId = 'p-sync'; clientId = 'c-sync' } }, @{ key = 'reconciler'; service = @{ principalId = 'p-rec'; clientId = 'c-rec' } }) }
$ids = @{ sync = @{ name = 'sync-b'; principalId = 'P-SYNC' }; reconciler = @{ name = 'rec-b'; principalId = 'p-rec' } }
$s1b = New-DrStandbyStage1Outputs -Primary $ps1 -Shells $shells -Identities $ids -StandbyNames $n
Check 'standby Stage 1: own apps and APIM, shared Cosmos and workspace' ($s1b.names.apps.resolver.functionApp -ceq 'lab1-abc-b-resolver' -and $s1b.apimName -ceq 'apim-b' -and $s1b.names.cosmosAccount -ceq 'lab1-abc-cosmos' -and $s1b.cosmosEndpoint -ceq 'https://c' -and $s1b.names.deploymentPrefix -ceq 'lab1b')
Check 'standby Stage 1: principals and client ids from the standby apps' ($s1b.principals.sync -ceq 'p-sync' -and $s1b.clientIds.reconciler -ceq 'c-rec')
$ids.sync.principalId = 'someone-else'; $threw = $false; try { $null = New-DrStandbyStage1Outputs -Primary $ps1 -Shells $shells -Identities $ids -StandbyNames $n } catch { $threw = "$_" -match 'standby_identity_mismatch' }
Check 'an app not running as its P1 identity is refused' $threw

function Acct($caps, $mode, $locs, $auto, $transition) { [pscustomobject]@{ properties = [pscustomobject]@{ capabilities = @($caps | ForEach-Object { [pscustomobject]@{ name = $_ } }); capacityMode = $mode
    capacityModeChangeTransitionState = $(if ($transition) { [pscustomobject]@{ capacityModeTransitionStatus = $transition } } else { $null })
    locations = @($locs | ForEach-Object { [pscustomobject]@{ locationName = $_ } }); enableAutomaticFailover = $auto } } }
Check 'serverless single region: convert, add region, enable failover' ((@(Get-DrCosmosSteps (Acct @('EnableServerless') 'Serverless' @('East US 2') $false $null) 'centralus') -join ',') -ceq 'convert_to_provisioned,add_secondary_region,enable_service_managed_failover')
Check 'conversion in progress: wait only' ((@(Get-DrCosmosSteps (Acct @('EnableServerless') 'Serverless' @('East US 2') $false 'InProgress') 'centralus') -join ',') -ceq 'wait_capacity_change')
Check 'converted (capability still listed): no conversion step' (@(Get-DrCosmosSteps (Acct @('EnableServerless') 'Provisioned' @('East US 2') $false 'Completed') 'centralus') -notcontains 'convert_to_provisioned')
Check 'done: no steps' (@(Get-DrCosmosSteps (Acct @() 'Provisioned' @('East US 2', 'Central US') $true $null) 'centralus').Count -eq 0)

Write-Host "Test-DrStandby: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 39) { exit 1 }
