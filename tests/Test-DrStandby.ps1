# Offline tests for the DR standby region tooling (infra/dr/Invoke-DrStandby.ps1, ADR 0033).
# `az bicep build` compiles locally; no Azure call is made.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'infra/dr/DrStandby.psm1') -Force
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

# Both regions' admin apps read usage from both gateways (ADMIN_GATEWAY_RESOURCE_IDS, DR-05); the
# setting is written only when a list is configured, so a single-region deployment is unchanged.
$s5 = Build 'infra/staged/stage5-config.bicep'
$s5All = if ($s5.resources -is [array]) { @($s5.resources) } else { @($s5.resources.PSObject.Properties.Value) }
$adminSettings = @($s5All | Where-Object { $_.type -ceq 'Microsoft.Web/sites/config' })[0]
$props = "$($adminSettings.properties)"
Check 'admin settings add ADMIN_GATEWAY_RESOURCE_IDS only for a non-empty list' ($props -match "union\(" -and $props -match "if\(empty\(variables\('adminGatewayList'\)\), createObject\(\)" -and $props -match "ADMIN_GATEWAY_RESOURCE_IDS")
$appSettings = Build 'infra/quickstart/modules/app-settings.bicep'
$recSettings = "$($appSettings.variables.reconcilerSettings)"
Check 'reconciler receives its workspace App Insights connection string' ($recSettings -match 'APPLICATIONINSIGHTS_CONNECTION_STRING' -and $recSettings -match "parameters\('reconcilerAppInsightsConnection'\)")
Check 'reconciler logs authenticate to workspace-based App Insights' ($recSettings -match 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING' -and $recSettings -match 'Authorization=AAD')
$stage5Source = Get-Content (Join-Path $repo 'infra/staged/stage5-config.bicep') -Raw
Check 'Stage 5 passes the reconciler component connection string to app-settings' ($stage5Source -match 'reconcilerAppInsightsConnection\s*:\s*reconcilerInsights\.properties\.ConnectionString')
$reader = @($byType['Microsoft.Authorization/roleAssignments'] | Where-Object { $_.name -match 'logReader' })[0]
Check 'workspace reader name: unsalted form kept, salted form added' ($reader.name -match "if\(empty\(parameters\('assignmentNameSalt'\)\), guid\(resourceId\('Microsoft.OperationalInsights/workspaces'.*variables\('logReader'\)\), guid\(.*parameters\('assignmentNameSalt'\)\)\)")
$cosmos = @($byType['Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments'])[0]
Check 'Cosmos assignment name: unsalted form kept, salted form added' ($cosmos.name -match "if\(empty\(parameters\('assignmentNameSalt'\)\), guid\(.*'ccof-staged', variables\('activeAssignments'\)\[copyIndex\(\)\].id\), guid\(.*parameters\('assignmentNameSalt'\)\)\)")
$defs = @($byType['Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions'])[0]
Check 'Cosmos role definitions are not salted (shared by both regions)' ($defs.name -notmatch 'assignmentNameSalt')

# ---- infra/dr/frontdoor.bicep: Front Door Premium in front of both APIM gateways over Private Link
$fd = Build 'infra/dr/frontdoor.bicep'
$fdAll = if ($fd.resources -is [array]) { @($fd.resources) } else { @($fd.resources.PSObject.Properties.Value) }
$fdType = { param($t) @($fdAll | Where-Object { $_.type -ceq $t }) }
Check 'Front Door profile is Premium (Private Link origins need it)' ("$((& $fdType 'Microsoft.Cdn/profiles')[0].sku.name)" -ceq 'Premium_AzureFrontDoor')
$origins = & $fdType 'Microsoft.Cdn/profiles/originGroups/origins'
$originText = $origins | ConvertTo-Json -Depth 20
Check 'origins reach APIM through Private Link, sub-resource Gateway' ($originText -match '"groupId":\s*"Gateway"' -and $originText -match 'sharedPrivateLinkResource')
Check 'APIM origin priority comes from apimOrigins (active/passive)' ($originText -match "\[parameters\('apimOrigins'\)\[copyIndex\(\)\].priority\]")
$og = "$((& $fdType 'Microsoft.Cdn/profiles/originGroups') | ConvertTo-Json -Depth 20)"
Check 'health probe: GET on the APIM status endpoint (HEAD answers 404)' ($og -match 'status-0123456789abcdef' -and $og -match '"probeRequestType":\s*"GET"')
$adminOg = "$((& $fdType 'Microsoft.Cdn/profiles/originGroups' | Where-Object { $_.name -match "'admin'" }) | ConvertTo-Json -Depth 20)"
Check 'admin health probe: GET anonymous console path' ($adminOg -match 'probePath.*api/console' -and $adminOg -match '"probeRequestType":\s*"GET"')
$adminOrigin = "$((& $fdType 'Microsoft.Cdn/profiles/originGroups/origins' | Where-Object { $_.name -match 'admin' }) | ConvertTo-Json -Depth 20)"
Check 'admin origins use App Service private links (group sites)' ($adminOrigin -match '"groupId":\s*"sites"' -and $adminOrigin -match 'sharedPrivateLinkResource')
Check 'admin origin priority comes from adminOrigins' ($adminOrigin -match "\[parameters\('adminOrigins'\)\[copyIndex\(\)\].priority\]")
$routes = & $fdType 'Microsoft.Cdn/profiles/afdEndpoints/routes'
$route = "$($routes | ConvertTo-Json -Depth 20)"
Check 'gateway route: HTTPS only, no caching' ($route -match '"forwardingProtocol":\s*"HttpsOnly"' -and $route -match '"httpsRedirect":\s*"Enabled"' -and $route -notmatch 'cacheConfiguration"\s*:\s*\{')
Check 'admin route sends /api to its own origin group' ($route -match '"patternsToMatch":\s*\[\s*"/api/\*"' -and $route -match "originGroups'.*'admin")
Check 'WAF policy attached through a security policy' (@(& $fdType 'Microsoft.Cdn/profiles/securityPolicies').Count -eq 1 -and @(& $fdType 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies').Count -eq 1)
Check 'WAF mode is a parameter defaulting to Detection' ($fd.parameters.wafMode.defaultValue -ceq 'Detection' -and (@($fd.parameters.wafMode.allowedValues) -join ',') -ceq 'Detection,Prevention')
$wafPolicy = "$((& $fdType 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies') | ConvertTo-Json -Depth 20)"
Check 'WAF preserves the managed JavaScript challenge expiration' ($wafPolicy -match 'javascriptChallengeExpirationInMinutes.*30')
Check 'primary gateway drain control defaults off' ($fd.parameters.disablePrimaryOrigins.defaultValue -eq $false)
Check 'primary admin drain control defaults off' ($fd.parameters.disablePrimaryAdminOrigins.defaultValue -eq $false)
Check 'primary failure injection defaults off' ($fd.parameters.simulatePrimaryFailure.defaultValue -eq $false)
$fdOriginEnabled = $origins | ConvertTo-Json -Depth 20
Check 'primary gateway can be drained independently by priority' ($fdOriginEnabled -match "if\(and\(equals\(parameters\('apimOrigins'\)\[copyIndex\(\)\]\.priority, 1\), parameters\('disablePrimaryOrigins'\)\), 'Disabled', 'Enabled'\)")
$fdOriginHost = "$($origins | ConvertTo-Json -Depth 20)"
Check 'primary gateway fault is an origin-host-header 404' ($fdOriginHost -match "if\(and\(equals\(parameters\('apimOrigins'\)\[copyIndex\(\)\]\.priority, 1\), parameters\('simulatePrimaryFailure'\)\), 'dr-drill.invalid', parameters\('apimOrigins'\)\[copyIndex\(\)\].hostName\)")
$allFdOrigins = & $fdType 'Microsoft.Cdn/profiles/originGroups/origins'
$fdAdminOriginEnabled = $allFdOrigins | Where-Object { $_.name -match 'adminOrigins' } | ConvertTo-Json -Depth 20
Check 'primary admin can be drained independently by priority' ($fdAdminOriginEnabled -match "if\(and\(equals\(parameters\('adminOrigins'\)\[copyIndex\(\)\]\.priority, 1\), parameters\('disablePrimaryAdminOrigins'\)\), 'Disabled', 'Enabled'\)")
Check 'primary admin origin gets the same reversible health fault' ($fdAdminOriginEnabled -match "if\(and\(equals\(parameters\('adminOrigins'\)\[copyIndex\(\)\]\.priority, 1\), parameters\('simulatePrimaryFailure'\)\), 'dr-drill.invalid', parameters\('adminOrigins'\)\[copyIndex\(\)\].hostName\)")
$front = New-DrFrontDoorParameters -Stem 'contoso-dr' `
    -PrimaryApimId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-a' `
    -PrimaryApimHost 'apim-a.azure-api.net' -PrimaryApimLocation 'eastus2' `
    -StandbyApimId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-b' `
    -StandbyApimHost 'apim-b.azure-api.net' -StandbyApimLocation 'centralus' `
    -PrimaryAdminSiteId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Web/sites/admin-a' `
    -PrimaryAdminHost 'admin-a.azurewebsites.net' -PrimaryAdminLocation 'eastus2' `
    -StandbyAdminSiteId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Web/sites/admin-b' `
    -StandbyAdminHost 'admin-b.azurewebsites.net' -StandbyAdminLocation 'centralus'
Check 'Front Door parameters preserve gateway and admin origins, primary first' ($front.apimOrigins.Count -eq 2 -and $front.apimOrigins[0].priority -eq 1 -and $front.apimOrigins[1].priority -eq 2 -and $front.adminOrigins.Count -eq 2 -and $front.adminOrigins[0].siteId -match '/Microsoft.Web/sites/admin-a')
Check 'normal Front Door deployment leaves both primary origins enabled' (-not $front.disablePrimaryOrigins -and -not $front.disablePrimaryAdminOrigins)
$drained = New-DrFrontDoorParameters -Stem 'contoso-dr' `
    -PrimaryApimId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-a' `
    -PrimaryApimHost 'apim-a.azure-api.net' -PrimaryApimLocation 'eastus2' `
    -StandbyApimId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-b' `
    -StandbyApimHost 'apim-b.azure-api.net' -StandbyApimLocation 'centralus' `
    -PrimaryAdminSiteId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Web/sites/admin-a' `
    -PrimaryAdminHost 'admin-a.azurewebsites.net' -PrimaryAdminLocation 'eastus2' `
    -StandbyAdminSiteId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Web/sites/admin-b' `
    -StandbyAdminHost 'admin-b.azurewebsites.net' -StandbyAdminLocation 'centralus' -SimulatePrimaryFailure
Check 'drain settings fault both primary origins but preserve standby priority' ($drained.simulatePrimaryFailure -and -not $drained.disablePrimaryOrigins -and -not $drained.disablePrimaryAdminOrigins -and $drained.apimOrigins[0].priority -eq 1 -and $drained.apimOrigins[1].priority -eq 2)
$threw = $false; try { $null = New-DrFrontDoorParameters -Stem 'Bad_Name' -PrimaryApimId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-a' -PrimaryApimHost 'apim-a.azure-api.net' -PrimaryApimLocation 'eastus2' -StandbyApimId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-b' -StandbyApimHost 'apim-b.azure-api.net' -StandbyApimLocation 'centralus' -PrimaryAdminSiteId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Web/sites/admin-a' -PrimaryAdminHost 'admin-a.azurewebsites.net' -PrimaryAdminLocation 'eastus2' -StandbyAdminSiteId '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Web/sites/admin-b' -StandbyAdminHost 'admin-b.azurewebsites.net' -StandbyAdminLocation 'centralus' } catch { $threw = "$_" -match 'frontdoor_stem_invalid' }
Check 'Front Door stem rejects uppercase and underscores before az' $threw
Check 'Front Door parameters default to WAF detection' ($front.wafMode -ceq 'Detection' -and $front.probeIntervalSeconds -eq 30)

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
$armHash = @(@{ properties = @{ principalId = 'aaaaaaaa-0000-4000-8000-000000000002' } }, @{ properties = @{ principalId = 'bbbbbbbb-0000-4000-8000-000000000009' } }, @{ principalId = 'AAAAAAAA-0000-4000-8000-000000000001' })
Check 'hashtables (az JSON as parsed by Invoke-QsAz) filtered the same way' (@(Select-StgOwnAssignments -Assignments $armHash -Principals $own).Count -eq 2)
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
    $c.standby.apim.publisherEmail = 'platform@contoso.example'; $c.standby.apim.publisherName = 'Contoso'
    $c.frontDoor.stem = 'contoso-dr'; $c }
Check 'complete standby section has no problems' (@(Get-DrStandbyProblems (New-DrCfg)).Count -eq 0)
$x = Get-DrStandbyProblems (Get-Content (Join-Path $repo 'infra/dr/dr.config.example.json') -Raw | ConvertFrom-Json)
Check 'example placeholders are refused by name' ($x -contains 'standby.stagedConfigPath:placeholder' -and $x -contains 'standby.apim.publisherEmail:placeholder')
$c = New-DrCfg; $c.standby.nameSuffix = 'B-1'; Check 'name suffix must be 1-2 lowercase characters' (@(Get-DrStandbyProblems $c) -contains 'standby.nameSuffix:one_or_two_lowercase_letters_or_digits')
$c = New-DrCfg; $c.secondary.location = $c.primary.location; Check 'standby in the primary location refused' (@(Get-DrStandbyProblems $c) -contains 'secondary.location:same_as_primary')
$c = New-DrCfg; $c.standby.apim.sku = 'BasicV2'; Check 'BasicV2 refused (no private outbound)' (@(Get-DrStandbyProblems $c) -contains 'standby.apim.sku:StandardV2_or_PremiumV2')
$c = New-DrCfg; Check 'example standby.apim.zoneRedundant is false' ($c.standby.apim.PSObject.Properties['zoneRedundant'] -and $c.standby.apim.zoneRedundant -is [bool] -and $c.standby.apim.zoneRedundant -eq $false)
$c = New-DrCfg; $c.standby.apim | Add-Member -Force zoneRedundant 'yes'; Check 'zoneRedundant must be a boolean' (@(Get-DrStandbyProblems $c) -contains 'standby.apim.zoneRedundant:true_or_false')
$c = New-DrCfg; $c.standby.apim | Add-Member -Force zoneRedundant $true; $c.standby.apim.units = 1; $zrw = $null
$zrp = @(Get-DrStandbyProblems $c -WarningVariable zrw -WarningAction SilentlyContinue)
Check 'zoneRedundant with one unit: accepted with a two-unit warning' ($zrp.Count -eq 0 -and @($zrw | Where-Object { "$_" -match 'standby\.apim\.zoneRedundant with standby\.apim\.units 1.*at least two units' }).Count -eq 1)
$c = New-DrCfg; $c.standby.apim | Add-Member -Force zoneRedundant $true; $c.standby.apim.units = 2; $zrw = $null
$zrp = @(Get-DrStandbyProblems $c -WarningVariable zrw -WarningAction SilentlyContinue)
Check 'zoneRedundant with two units: no problem, no warning' ($zrp.Count -eq 0 -and -not @($zrw).Count)
$sb = Build 'infra/dr/standby.bicep'
$sbAll = if ($sb.resources -is [array]) { @($sb.resources) } else { @($sb.resources.PSObject.Properties.Value) }
$sbApim = @($sbAll | Where-Object { $_.type -ceq 'Microsoft.Resources/deployments' -and $_.name -ceq 'dr-standby-apim' })[0]
$sbZr = if ($sbApim) { $sbApim.properties.parameters.PSObject.Properties['zoneRedundant'] } else { $null }
$sbZrValue = if ($sbZr) { "$($sbZr.Value.value)" } else { '' }
Check 'standby.bicep passes apim.zoneRedundant (default false) to apim-service.bicep' ($sbZrValue -match "tryGet\(parameters\('apim'\), 'zoneRedundant'\)" -and $sbZrValue -match 'false\(\)\)\]$')
$c = New-DrCfg; $c.cosmos.autoscaleMaxThroughput = 1500; Check 'autoscale max must be a multiple of 1000' (@(Get-DrStandbyProblems $c) -contains 'cosmos.autoscaleMaxThroughput:multiple_of_1000_from_1000')
$c = New-DrCfg; $c.cosmos.convertServerless = 'yes'; Check 'convertServerless must be a boolean' (@(Get-DrStandbyProblems $c) -contains 'cosmos.convertServerless:true_or_false')
$c = New-DrCfg; $c.standby.functionsPublicNetworkAccess = 'Open'; Check 'public access must be Enabled or Disabled' (@(Get-DrStandbyProblems $c) -contains 'standby.functionsPublicNetworkAccess:Enabled_or_Disabled')
$c = New-DrCfg; $c.frontDoor.stem = 'Invalid_Stem'; Check 'Front Door name is validated before Azure API calls' (@(Get-DrStandbyProblems $c) -contains 'frontDoor.stem:lowercase_letters_digits_hyphens_3_to_40')
$c = New-DrCfg; $c.frontDoor.wafMode = 'BlockEverything'; Check 'Front Door WAF mode must be Detection or Prevention' (@(Get-DrStandbyProblems $c) -contains 'frontDoor.wafMode:Detection_or_Prevention')

$pn = @{ deploymentPrefix = 'lab1'; cosmosAccount = 'lab1-abc-cosmos'; logAnalyticsWorkspace = 'lab1-abc-law'
    apps = @{ resolver = @{ functionApp = 'lab1-abc-resolver'; storageAccount = 'lab1abcres' } } }
$n = Get-DrStandbyNames $pn 'b'
Check 'standby names derive from the primary stem' ($n.stem -ceq 'lab1-abc-b' -and $n.storageStem -ceq 'lab1abcb' -and $n.deploymentPrefix -ceq 'lab1b')
$threw = $false; try { $null = Get-DrStandbyNames @{ deploymentPrefix = 'x'; apps = @{ resolver = @{ functionApp = 'x-resolver'; storageAccount = 'lab1abcdefghijklmnopqrres' } } } 'bb' } catch { $threw = "$_" -match 'standby_storage_name_too_long' }
Check 'storage names over 24 characters refused' $threw

$primary = [ordered]@{ location = 'eastus2'; syncTimerEnabled = $true; reconciler = @{ timerEnabled = $true; continuityGate = 'on'; ledgerCoverageStartAt = '2026-10-20T15:41:34.000Z' }; stage1 = @{ apimSku = 'StandardV2' }
    backends = @(@{ id = 'foundry-a'; privateEndpoint = $true }); network = @{ mode = 'create' }; __path = 'x' }
$zones = @{ cosmos = '/z/documents'; blob = '/z/blob' }
$b = New-DrStandbyStagedConfig -Primary $primary -Dr (New-DrCfg) -VnetId '/v/standby' -ZoneIds $zones
Check 'standby config: standby location' ($b.location -ceq 'centralus')
Check 'standby config: both writers off' ($b.syncTimerEnabled -eq $false -and $b.reconciler.timerEnabled -eq $false)
Check 'standby config: UTC coverage start remains a canonical string' ($b.reconciler.continuityGate -ceq 'on' -and $b.reconciler.ledgerCoverageStartAt -is [string] -and $b.reconciler.ledgerCoverageStartAt -ceq '2026-10-20T15:41:34.000Z')
$coverageStartAt = $primary.reconciler.ledgerCoverageStartAt
$primary.reconciler.Remove('continuityGate'); $primary.reconciler.Remove('ledgerCoverageStartAt')
$withoutCoverage = $null; $failed = $false
try { $withoutCoverage = New-DrStandbyStagedConfig -Primary $primary -Dr (New-DrCfg) -VnetId '/v/standby' -ZoneIds $zones } catch { $failed = $true }
Check 'standby config: optional continuity settings remain absent for a single-region config' (-not $failed -and -not $withoutCoverage.reconciler.Contains('continuityGate') -and -not $withoutCoverage.reconciler.Contains('ledgerCoverageStartAt'))
$primary.reconciler.continuityGate = 'on'; $primary.reconciler.ledgerCoverageStartAt = $coverageStartAt
Check 'standby config: existing standby subnets and shared zones' ($b.network.mode -ceq 'existing' -and $b.network.existing.functionsSubnetId -ceq '/v/standby/subnets/snet-functions' -and $b.network.existing.privateDnsZoneIds.cosmos -ceq '/z/documents')
Check 'standby config: no second Foundry private endpoint' ($b.backends[0].privateEndpoint -eq $false)
Check 'standby config: standby section set' ($b.standby.stage1DeploymentName -ceq 'dr-standby-shells' -and $b.standby.endpointNameSuffix -ceq '-b')
Check 'standby config: APIM zone redundancy from standby.apim, not the primary' ($b.stage1['apimZoneRedundant'] -is [bool] -and $b.stage1['apimZoneRedundant'] -eq $false)
$zrDr = New-DrCfg; $zrDr.standby.apim | Add-Member -Force zoneRedundant $true
Check 'standby config: standby.apim.zoneRedundant true reaches stage1.apimZoneRedundant' ((New-DrStandbyStagedConfig -Primary $primary -Dr $zrDr -VnetId '/v/standby' -ZoneIds $zones).stage1['apimZoneRedundant'] -eq $true)
Check 'primary configuration not modified' ($primary.syncTimerEnabled -eq $true -and $primary.backends[0].privateEndpoint -eq $true -and $primary.location -ceq 'eastus2')
$gw = @('/subscriptions/x/resourceGroups/r/providers/Microsoft.ApiManagement/service/a', '/subscriptions/x/resourceGroups/r/providers/Microsoft.ApiManagement/service/b')
$b2 = New-DrStandbyStagedConfig -Primary $primary -Dr (New-DrCfg) -VnetId '/v/standby' -ZoneIds $zones -GatewayResourceIds $gw
Check 'standby config: reconciler and admin read both gateways' ((@($b2.reconciler.ledgerGatewayResourceIds) -join ',') -ceq ($gw -join ',') -and (@($b2.admin.gatewayResourceIds) -join ',') -ceq ($gw -join ','))
Check 'standby config without the list: no list keys' (-not $b.reconciler.Contains('ledgerGatewayResourceIds'))
$primaryApim = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-a'
$standbyApim = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-b'
$gwids = @(Get-DrGatewayResourceIds -PrimaryApimId $primaryApim -StandbyApimId $standbyApim)
Check 'both APIM IDs are preserved in the gateway list' ($gwids.Count -eq 2 -and $gwids[0] -ceq $primaryApim -and $gwids[1] -ceq $standbyApim)
$threw = $false; try { $null = Get-DrGatewayResourceIds -PrimaryApimId $primaryApim } catch { $threw = "$_" -match 'standby_gateway_id_missing' }
Check 'missing standby APIM ID is refused, not serialized as an empty list item' $threw
$threw = $false; try { $null = Get-DrGatewayResourceIds -PrimaryApimId $primaryApim -StandbyApimId "$standbyApim,garbage" } catch { $threw = "$_" -match 'standby_gateway_id_invalid' }
Check 'invalid standby APIM ID is refused' $threw

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
if ($script:fail -gt 0 -or $script:pass -lt 75) { exit 1 }
