#Requires -Version 7.0
<#
.SYNOPSIS
    Offline contract tests for the staged deployment entry points (infra/staged/stage*.bicep and
    Invoke-StagedDeployment.ps1). No Azure call: Bicep compiles locally and the driver is dot-sourced.
#>
[CmdletBinding()]
param([string]$BicepPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $BicepPath) {
    $command = Get-Command bicep -ErrorAction SilentlyContinue
    if ($command) { $BicepPath = $command.Source }
    elseif (Test-Path (Join-Path $HOME '.azure\bin\bicep.exe')) { $BicepPath = Join-Path $HOME '.azure\bin\bicep.exe' }
    else { throw 'Offline Bicep CLI required. Supply -BicepPath; this test does not install tools or call Azure.' }
}
$passed = 0
function Assert-Contract([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
function Build-Arm([string]$Relative) {
    $out = & $BicepPath build (Join-Path $root $Relative) --stdout 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Bicep compilation failed: $Relative" }
    return ($out -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100
}
function Get-Resources($Template) {
    foreach ($resource in $Template.resources) {
        $resource
        if ($resource.properties.template) { Get-Resources $resource.properties.template }
    }
}
function Test-StageBoundary($Arm, [string[]]$Allowed, [string]$Stage) {
    foreach ($r in @(Get-Resources $Arm)) {
        if ($r.type -notin $Allowed) { throw "$Stage declares a resource outside its boundary: $($r.type)" }
    }
}

# Stage boundaries: each entry point declares only its own kind of resource.
$boundaries = [ordered]@{
    'infra\staged\stage6-network.bicep' = @('Microsoft.Resources/deployments', 'Microsoft.Network/networkSecurityGroups', 'Microsoft.Network/virtualNetworks',
        'Microsoft.Network/privateDnsZones', 'Microsoft.Network/privateDnsZones/virtualNetworkLinks', 'Microsoft.Network/privateEndpoints',
        'Microsoft.Network/privateEndpoints/privateDnsZoneGroups')
    'infra\staged\stage2-schema.bicep' = @('Microsoft.DocumentDB/databaseAccounts/sqlDatabases', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers')
    'infra\staged\stage3-grants.bicep' = @('Microsoft.Resources/deployments', 'Microsoft.Authorization/roleAssignments',
        'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions', 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments')
    'infra\staged\stage5-config.bicep' = @('Microsoft.Resources/deployments', 'Microsoft.Web/sites/config', 'Microsoft.ApiManagement/service/apis',
        'Microsoft.ApiManagement/service/backends', 'Microsoft.ApiManagement/service/apis/policies', 'Microsoft.ApiManagement/service/policyFragments', 'Microsoft.ApiManagement/service/apis/operations', 'Microsoft.ApiManagement/service/loggers',
        'Microsoft.ApiManagement/service/apis/diagnostics', 'Microsoft.Insights/workbooks')
}
$arms = @{}
foreach ($path in $boundaries.Keys) {
    $arms[$path] = Build-Arm $path
    Test-StageBoundary $arms[$path] $boundaries[$path] $path
    $passed++
}

# Negative control: the same check rejects a role assignment injected into the network stage.
$mutated = $arms['infra\staged\stage6-network.bicep'] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
$mutated.resources += @{ type = 'Microsoft.Authorization/roleAssignments'; apiVersion = '2022-04-01'; name = 'injected' }
$caught = $false
try { Test-StageBoundary $mutated $boundaries['infra\staged\stage6-network.bicep'] 'mutated stage 6' } catch { $caught = $_.Exception.Message -match 'roleAssignments' }
Assert-Contract $caught 'Negative control: an injected role assignment was not rejected by the boundary check.'

# Stage 5 (configuration) must never grant: no Authorization resource anywhere, including the reused modules.
Assert-Contract (-not (@(Get-Resources $arms['infra\staged\stage5-config.bicep']) | Where-Object type -Match 'Authorization|sqlRole')) 'Stage 5 contains a grant.'
# Stage 5 must not repeat Stage 1's resource-log diagnostic settings (Azure Monitor refuses duplicates).
Assert-Contract (-not (@(Get-Resources $arms['infra\staged\stage5-config.bicep']) | Where-Object type -EQ 'Microsoft.Insights/diagnosticSettings')) 'Stage 5 repeats a diagnostic setting.'

# Stage 3 and Stage 4 keep the quickstart's Cosmos data contract.
$quick = Build-Arm 'infra\quickstart\modules\cosmos-data.bicep'
$schema = $arms['infra\staged\stage2-schema.bicep']; $grants = $arms['infra\staged\stage3-grants.bicep']
$quickContainers = $quick.variables.cosmosContainers | ConvertTo-Json -Compress
$stagedContainers = $schema.variables.cosmosContainers | ConvertTo-Json -Compress
Assert-Contract ($quickContainers -ceq $stagedContainers) 'Stage 3 containers differ from the quickstart.'
foreach ($d in $quick.variables.cosmosRoleDefinitions) {
    $m = @($grants.variables.cosmosRoleDefinitions | Where-Object { $_.key -ceq $d.key })
    Assert-Contract ($m.Count -eq 1 -and (($m[0].dataActions | ConvertTo-Json -Compress) -ceq ($d.dataActions | ConvertTo-Json -Compress))) "Stage 4 role definition $($d.key) differs from the quickstart."
}
$admin = @($grants.variables.cosmosRoleDefinitions | Where-Object key -CEQ 'adminProjectEditor')[0]
Assert-Contract (-not ($admin.dataActions -match '/delete$|/upsert$')) 'Admin editor role must not delete or upsert.'
foreach ($a in $quick.variables.cosmosAssignments | Where-Object principal -NE 'runner') {
    $m = @($grants.variables.cosmosAssignments | Where-Object { $_.id -ceq $a.id })
    Assert-Contract ($m.Count -eq 1 -and $m[0].role -ceq $a.role -and $m[0].container -ceq $a.container -and $m[0].principal -ceq $a.principal) "Stage 4 assignment $($a.id) differs from the quickstart."
}
# Every client the admin API accepts (ADMIN_ALLOWED_CLIENT_IDS) is preauthorized by Stage 4 and read back.
$entraText = Get-Content -Raw (Join-Path $root 'infra\staged\Staged.Entra.ps1')
Assert-Contract ($entraText -match '\$adminClients = @\(\$adm\.appId\) \+ @\(\$Cfg\.admin\.extraAllowedClientIds' -and $entraText -match 'Merge-StgPreauthorized \$adm \$adminClients' -and $entraText -match 'foreach \(\$cid in \$adminClients\)') 'Stage 4 must preauthorize and verify admin.extraAllowedClientIds.'
$adminScopes = @($grants.variables.cosmosAssignments | Where-Object principal -EQ 'admin' | ForEach-Object { $_.container })
Assert-Contract ((($adminScopes | Sort-Object) -join ',') -ceq 'adminConfig,projects') 'Admin Cosmos access must be limited to projects and adminConfig.'
# The sync reads the admin console's removal-limit override: read-only, adminConfig only, and only with the admin app.
$syncConfig = @($grants.variables.cosmosAssignments | Where-Object { $_.principal -ceq 'sync' -and $_.container -ceq 'adminConfig' })
Assert-Contract ($syncConfig.Count -eq 1 -and $syncConfig[0].role -ceq '00000000-0000-0000-0000-000000000001') 'Sync access to adminConfig must be the built-in Data Reader only.'
Assert-Contract ($grants.variables.activeAssignments -match "not\(equals\(lambdaVariables\('a'\)\.container, 'adminConfig'\)\), not\(empty\(coalesce\(tryGet\(parameters\('principals'\), 'admin'\)") 'adminConfig assignments must require the admin principal.'
$settingsArm = Build-Arm 'infra\quickstart\modules\app-settings.bicep'
Assert-Contract (($settingsArm.parameters.syncLimitsContainer.defaultValue -ceq '') -and ((Get-Content -Raw 'infra\staged\stage5-config.bicep') -match "syncLimitsContainer: \(admin\.\?enabled \?\? false\) \? 'adminConfig' : ''")) 'Stage 5 must set SYNC_LIMITS_CONTAINER=adminConfig only with the admin app.'

# Stage 1 publishes the names later stages read.
$s1 = Build-Arm 'infra\staged\main.bicep'
Assert-Contract ($s1.outputs.ContainsKey('names') -and $s1.outputs.ContainsKey('apimName')) 'Stage 1 must output names and apimName.'
Assert-Contract (($s1.parameters.apimSku.allowedValues -join ',') -ceq 'BasicV2,StandardV2' -and $s1.parameters.apimSku.defaultValue -ceq 'StandardV2') 'APIM SKU choice changed.'
# APIM zone redundancy (UNKNOWNS APIM-ZR-01): off by default; when on, only the preview API resource carries properties.zoneRedundant.
Assert-Contract ($s1.parameters.ContainsKey('apimZoneRedundant') -and $s1.parameters.apimZoneRedundant.type -ceq 'bool' -and $s1.parameters.apimZoneRedundant.defaultValue -eq $false) 'main.bicep must declare apimZoneRedundant bool defaulting to false.'
$apimModule = @(Get-Resources $s1 | Where-Object { $_.type -ceq 'Microsoft.Resources/deployments' -and $_.name -ceq 'stage1-apim' })[0]
Assert-Contract ($apimModule -and $apimModule.properties.parameters.zoneRedundant.value -ceq "[parameters('apimZoneRedundant')]") 'main.bicep must pass apimZoneRedundant to apim-service.bicep.'
$apimArm = Build-Arm 'infra\staged\apim-service.bicep'
Assert-Contract ($apimArm.parameters.zoneRedundant.defaultValue -eq $false) 'apim-service.bicep zoneRedundant must default to false.'
$apimResources = if ($apimArm.resources -is [Collections.IDictionary]) { $apimArm.resources.Values } else { $apimArm.resources }
$apimServices = @($apimResources | Where-Object { $_.type -ceq 'Microsoft.ApiManagement/service' -and -not $_.existing })
$apimGa = @($apimServices | Where-Object { $_.apiVersion -ceq '2024-05-01' })
$apimZr = @($apimServices | Where-Object { $_.apiVersion -ceq '2025-03-01-preview' })
Assert-Contract ($apimServices.Count -eq 2 -and $apimGa.Count -eq 1 -and $apimGa[0].condition -ceq "[not(parameters('zoneRedundant'))]" -and -not $apimGa[0].properties.ContainsKey('zoneRedundant')) 'Default (zone redundancy off) APIM must use the GA API with no zoneRedundant property.'
Assert-Contract ($apimZr.Count -eq 1 -and $apimZr[0].condition -ceq "[parameters('zoneRedundant')]" -and $apimZr[0].properties.zoneRedundant -eq $true) 'Zone-redundant APIM must set properties.zoneRedundant true on the preview API resource.'

# Driver: parses, every stage has an entry function, no az argument holds a cmd.exe metacharacter,
# preview is the default, and later stages read earlier stage state.
$driverPath = Join-Path $root 'infra\staged\Invoke-StagedDeployment.ps1'
$driverFiles = @($driverPath) + @('Staged.Common.ps1', 'Staged.Resources.ps1', 'Staged.Entra.ps1', 'Staged.Application.ps1' | ForEach-Object { Join-Path $root "infra\staged\$_" })
$functionAsts = @()
foreach ($file in $driverFiles) {
    $tokens = $null; $errors = $null
    $fileAst = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    Assert-Contract (-not $errors.Count) "Driver file $file does not parse: $($errors.Message -join '; ')"
    $functionAsts += @($fileAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
}
$functions = @($functionAsts | ForEach-Object Name)
foreach ($n in 0..8) { Assert-Contract ($functions -contains "Invoke-Stage$n") "Driver lacks Invoke-Stage$n." }
$driver = ($driverFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
Assert-Contract (-not $driver.Contains('}`n} finally')) 'Driver must not contain a literal escaped newline after its Stage 7 lock try block.'
foreach ($line in ($driver -split "`n" | Where-Object { $_ -match "Invoke-Qs(Az|AzJson)|Invoke-StgAzJson|Get-StgGraph|Get-StgArm" })) {
    foreach ($literal in [regex]::Matches($line, "'[^']*'")) {
        Assert-Contract ($literal.Value -notmatch '[&|<>^]') "Driver passes a cmd.exe metacharacter to az: $($literal.Value)"
    }
}
Assert-Contract ($driver -match '\[switch\]\$Apply' -and $driver -match "what-if") 'Driver must preview by default.'
# az apim update sets the identity to None unless --enable-managed-identity true (azure-cli apim custom.py
# apim_update); APIM changes go through ARM PATCH. Comments may name the command; code may not.
foreach ($file in $driverFiles) {
    $tokens = $null; $null = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$null)
    $code = (@($tokens | Where-Object Kind -NE 'Comment' | ForEach-Object Text) -join ' ')
    Assert-Contract ($code -notmatch "(?i)'apim'\s*,?\s*'update'|\bapim\s+update\b") "$(Split-Path $file -Leaf) calls az apim update, which strips the APIM managed identity."
}
$stageBody = @{}; foreach ($n in 1, 5, 6) { $stageBody[$n] = @($functionAsts | Where-Object Name -EQ "Invoke-Stage$n")[0].Body.Extent.Text }
Assert-Contract ($stageBody[1] -match 'Write-StgExistingApimNote') 'Stage 1 preview must print the existing-APIM manual-step note.'
Assert-Contract ($stageBody[5] -match 'Invoke-StgExistingApimDiagnostics') 'Stage 5 must configure the existing APIM gateway diagnostics when opted in.'
Assert-Contract ($stageBody[6] -match 'Invoke-StgExistingApimOutbound' -and $stageBody[6] -match 'Invoke-StgApimOutboundIntegration') 'Stage 6 must integrate a created or an opted-in existing APIM through one ARM PATCH path.'
foreach ($n in 2..8) {
    $body = @($functionAsts | Where-Object Name -EQ "Invoke-Stage$n")[0].Body.Extent.Text
    Assert-Contract ($body -match 'Get-StgStage \$Cfg 1') "Invoke-Stage$n does not require Stage 1 state."
}

# Configuration: the committed example is refused until its placeholders are replaced; a filled copy passes.
. $driverPath -DotSourceOnly
$action = Get-StgNetworkAction -Mode 'create' -VnetExists $false -StageStateExists $false
Assert-Contract ($action -ceq 'deploy') 'First Stage 6 create-mode deployment must deploy the network.'
$action = Get-StgNetworkAction -Mode 'create' -VnetExists $true -StageStateExists $true
Assert-Contract ($action -ceq 'reuse') 'A saved Stage 6 create-mode retry must skip the authoritative network deployment.'
$action = Get-StgNetworkAction -Mode 'existing' -VnetExists $true -StageStateExists $false
Assert-Contract ($action -ceq 'deploy') 'Existing-network mode must not be blocked by a pre-existing VNet.'
$unsafeCreateRetry = $false
try { $null = Get-StgNetworkAction -Mode 'create' -VnetExists $true -StageStateExists $false } catch { $unsafeCreateRetry = $_.Exception.Message -match 'network_create_existing_vnet' }
Assert-Contract $unsafeCreateRetry 'Create mode without Stage 2 state must refuse to rewrite an existing VNet subnet list.'
$dnsConfig = @{ subscriptionId = '00000000-0000-4000-8000-000000000001'; resourceGroup = 'rg'; network = @{ mode = 'create' } }
$dnsOutputs = @{ functionsSubnetId = '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/functions'; privateDnsZoneIds = @{ cosmos = 'cosmos-zone'; blob = 'blob-zone' } }
$dnsTargets = Get-StgNetworkDnsTargets -Cfg $dnsConfig -Outputs $dnsOutputs -HasFoundry $true
Assert-Contract ($dnsTargets.vnetId -ceq '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet' -and $dnsTargets.zoneIds.Count -eq 5) 'Stage 6 must derive DNS targets when earlier deployment outputs lack VNet and Foundry zone IDs.'
# Flex Consumption apps without VNet integration return virtualNetworkSubnetId null (seen live 2026-10-25);
# the read-back compares it with '' for Stage 1, so Get-StgSite returns a string.
function Invoke-StgAzJson { param([string[]]$Arguments) if ($Arguments[1] -eq 'config') { @{ ftpsState = 'Disabled' } } else { @{ name = 'app'; properties = @{ publicNetworkAccess = 'Enabled'; virtualNetworkSubnetId = $null; httpsOnly = $true } } } }
$nullSubnetSite = Get-StgSite -Cfg @{ subscriptionId = 's'; resourceGroup = 'g' } -Name 'app'
Assert-Contract ($nullSubnetSite.virtualNetworkSubnetId -ieq '') 'Get-StgSite must return an empty string, not null, for an app without VNet integration (Stage 1 read-back).'
# Stage 1 verify reads zone redundancy back with the preview API only when the configuration asks for it (UNKNOWNS APIM-ZR-02).
$script:zrArmCalls = @()
function Get-StgArm { param([string]$Path, [string]$ApiVersion) $script:zrArmCalls += "$ApiVersion"; @{ properties = @{ zoneRedundant = $script:zrArmValue } } }
$script:zrArmValue = $true
$zrRead = Assert-StgApimZoneRedundancy -Cfg @{ stage1 = @{ apimZoneRedundant = $true } } -ApimId '/apim'
Assert-Contract ($zrRead -eq $true -and ($script:zrArmCalls -join ',') -ceq '2025-03-01-preview') 'Stage 1 verify must read zoneRedundant back with API 2025-03-01-preview when configured.'
$script:zrArmValue = $false
$bad = $false; try { $null = Assert-StgApimZoneRedundancy -Cfg @{ stage1 = @{ apimZoneRedundant = $true } } -ApimId '/apim' } catch { $bad = $_.Exception.Message -match 'verify_failed: APIM zoneRedundant' }
Assert-Contract $bad 'Stage 1 verify must fail when a configured zone-redundant APIM reads back as not zone redundant.'
$script:zrArmCalls = @(); $script:zrArmValue = $true
$zrRead = Assert-StgApimZoneRedundancy -Cfg @{ stage1 = @{ apimZoneRedundant = $false } } -ApimId '/apim'
Assert-Contract ($null -eq $zrRead -and $script:zrArmCalls.Count -eq 0) 'Stage 1 verify must not read zone redundancy when the setting is off.'
# Admin publishing after Front Door Lockdown (ADR 0037): public access Disabled -> skip, no build, no deploy.
$script:pubCalls = @(); $script:pubBuilds = 0; $script:pubAccess = 'Disabled'
function Get-StgArm { param([string]$Path, [string]$ApiVersion) $script:pubCalls += "GET $Path"; @{ properties = @{ publicNetworkAccess = $script:pubAccess } } }
function Invoke-QsAz { param([string[]]$Arguments) $script:pubCalls += ($Arguments -join ' '); $null }
$pubZip = Join-Path ([IO.Path]::GetTempPath()) "ccof-admin-test-$([guid]::NewGuid().ToString('N')).zip"
$pubBuild = { param($zip) $script:pubBuilds++; [IO.File]::WriteAllText($zip, 'zip') }
$pub = Publish-StgAdminPackage -Subscription 's' -ResourceGroup 'g' -App 'adm' -ZipPath $pubZip -Build $pubBuild 3>$null
Assert-Contract ($pub.skipped -ceq 'public_access_disabled' -and $script:pubBuilds -eq 0 -and @($script:pubCalls | Where-Object { $_ -match 'config-zip' }).Count -eq 0 -and $pub.runbook -match 'ADMIN-UPDATE-FROM-VM') 'Admin publishing must be skipped, without build or deploy, when the admin app has public access Disabled (Front Door Lockdown).'
$script:pubCalls = @(); $script:pubAccess = 'Enabled'
try { $pub = Publish-StgAdminPackage -Subscription 's' -ResourceGroup 'g' -App 'adm' -ZipPath $pubZip -Build $pubBuild } finally { Remove-Item -LiteralPath $pubZip -ErrorAction SilentlyContinue }
Assert-Contract ($script:pubBuilds -eq 1 -and @($script:pubCalls | Where-Object { $_ -match "^functionapp deployment source config-zip --subscription s --resource-group g --name adm --src " }).Count -eq 1 -and $pub.sha256 -match '^[0-9A-F]{64}$') 'Admin publishing with public access Enabled must build once and deploy once with config-zip.'
$stage7Text = Get-Content -Raw (Join-Path $root 'infra\staged\Staged.Application.ps1'); $drText = Get-Content -Raw (Join-Path $root 'infra\dr\Invoke-DrStandby.ps1')
Assert-Contract (([regex]::Matches($stage7Text + $drText, "'config-zip'")).Count -eq 1 -and ([regex]::Matches($stage7Text + $drText, 'Publish-StgAdminPackage ')).Count -ge 2) 'Stage 7 and the DR Code phase must publish the admin package only through Publish-StgAdminPackage.'
# Stage 4 with existing registrations already configured by an Entra administrator (for example by hand
# in the Portal): an operator who is not an owner can read but not write, so Stage 4 sends nothing.
$cli = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
function New-S4World {
    $gwScope = '11111111-0000-4000-8000-000000000001'; $admScope = '11111111-0000-4000-8000-000000000002'
    $w = @{
        sends = [Collections.Generic.List[string]]::new()
        apps = @{
            gw = @{ id = 'o-gw'; appId = 'a-gw'; displayName = 'gw'; identifierUris = @('api://a-gw'); isFallbackPublicClient = $true
                api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(@{ id = $gwScope; value = 'access_as_user'; type = 'Admin'; isEnabled = $true; adminConsentDisplayName = 'Portal text' })
                    preAuthorizedApplications = @(@{ appId = 'a-gw'; delegatedPermissionIds = @($gwScope) }, @{ appId = $cli; delegatedPermissionIds = @($gwScope) }) }
                publicClient = @{ redirectUris = @('ms-appx-web://microsoft.aad.brokerplugin/a-gw', 'http://localhost') } }
            res = @{ id = 'o-res'; appId = 'a-res'; displayName = 'res'; identifierUris = @('api://a-res'); api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(); preAuthorizedApplications = @() } }
            adm = @{ id = 'o-adm'; appId = 'a-adm'; displayName = 'adm'; identifierUris = @('api://a-adm')
                appRoles = @(@{ id = 'r-read'; value = 'CCOF.Projects.Read'; isEnabled = $true; allowedMemberTypes = @('User') }, @{ id = 'r-write'; value = 'CCOF.Projects.Write'; isEnabled = $true; allowedMemberTypes = @('User') })
                api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(@{ id = $admScope; value = 'Projects.Manage'; type = 'Admin'; isEnabled = $true })
                    preAuthorizedApplications = @(@{ appId = 'a-adm'; delegatedPermissionIds = @($admScope) }, @{ appId = $cli; delegatedPermissionIds = @($admScope) }) }
                spa = @{ redirectUris = @('https://lab-admin.azurewebsites.net/api/console', 'https://lab-admin.azurewebsites.net/api/console-v3') } }
        }
        sp = @{ 'a-gw' = @{ id = 'sp-gw'; appId = 'a-gw' }; 'a-res' = @{ id = 'sp-res'; appId = 'a-res' }; 'a-adm' = @{ id = 'sp-adm'; appId = 'a-adm'; appRoleAssignmentRequired = $true } }
        assigned = @(@{ principalId = 'u-me'; appRoleId = 'r-write' })
    }
    return $w
}
$cfg4 = @{ entra = @{ existing = @{ gatewayAppId = 'a-gw'; resolverAppId = 'a-res'; adminAppId = 'a-adm' }; allowAzureCliClient = $true; adminEditors = @('@me'); adminReaders = @() }
    stage1 = @{ includeAdmin = $true }; admin = @{ extraAllowedClientIds = @($cli) }
    groups = @(@{ projectId = 'P1'; classification = 'STD'; groupId = 'g-1'; members = @() }) }
function Get-StgStage { param($Cfg, $N) @{ names = @{ apps = @{ admin = @{ functionApp = 'lab-admin' } } } } }
function Write-StgEvidence { param($Name, $Value) $null }
function Get-StgGraph { param([string]$Path)
    if ($Path -like 'me*') { return @{ id = 'u-me' } }
    if ($Path -match "^applications\?\`$filter=appId eq '([^']+)'") { $a = @($script:s4.apps.Values | Where-Object { $_.appId -eq $Matches[1] }); return @{ value = $a } }
    if ($Path -match "^servicePrincipals\?\`$filter=appId eq '([^']+)'") { return @{ value = @($script:s4.sp[$Matches[1]]) } }
    if ($Path -match '/appRoleAssignedTo$') { return @{ value = $script:s4.assigned } }
    if ($Path -match '^groups/g-1/members') { return @{ value = @() } }
    if ($Path -match '^groups/g-1') { return @{ id = 'g-1'; displayName = 'G1'; securityEnabled = $true } }
    throw "unexpected graph read $Path" }
function Send-StgGraph { param([string]$Method, [string]$Path, $Body) $script:s4.sends.Add("$Method $Path"); throw 'Authorization_RequestDenied (fake 403)' }
$script:s4 = New-S4World
$s4err = $null; try { $null = Invoke-Stage4 -Cfg $cfg4 -Apply 6>$null } catch { $s4err = "$_" }
Assert-Contract ($null -eq $s4err -and $script:s4.sends.Count -eq 0) "Stage 4 must send no Graph change when the existing registrations are already configured (a non-owner operator gets 403 on any write). sends: $($script:s4.sends -join '; ') error: $s4err"
$script:s4 = New-S4World; $script:s4.apps.adm.spa.redirectUris = @('https://lab-admin.azurewebsites.net/api/console')
$s4err = $null; try { $null = Invoke-Stage4 -Cfg $cfg4 -Apply 6>$null } catch { $s4err = "$_" }
Assert-Contract ($s4err -match 'fake 403' -and @($script:s4.sends) -contains 'patch applications/o-adm') 'Stage 4 must still update an existing registration that lacks a required setting (missing admin SPA redirect).'
$script:s4 = New-S4World; $script:s4.apps.gw.api.preAuthorizedApplications = @(@{ appId = 'a-gw'; delegatedPermissionIds = @('11111111-0000-4000-8000-000000000001') })
$s4err = $null; try { $null = Invoke-Stage4 -Cfg $cfg4 -Apply 6>$null } catch { $s4err = "$_" }
Assert-Contract (@($script:s4.sends) -contains 'patch applications/o-gw') 'Stage 4 must preauthorize the Azure CLI on the gateway app when it is missing.'
$script:s4 = New-S4World; $script:s4.sp['a-adm'].appRoleAssignmentRequired = $false
$s4err = $null; try { $null = Invoke-Stage4 -Cfg $cfg4 -Apply 6>$null } catch { $s4err = "$_" }
Assert-Contract (@($script:s4.sends) -contains 'patch servicePrincipals/sp-adm') 'Stage 4 must require assignment on the admin enterprise application when it is off.'
# entra.browserSignIn false: the organization does not allow http://localhost on the gateway app.
$script:s4 = New-S4World; $script:s4.apps.gw.publicClient.redirectUris = @('ms-appx-web://microsoft.aad.brokerplugin/a-gw', 'https://localhost')
$cfgNoLoopback = $cfg4.Clone(); $cfgNoLoopback.entra = $cfg4.entra.Clone(); $cfgNoLoopback.entra.browserSignIn = $false
$s4err = $null; try { $null = Invoke-Stage4 -Cfg $cfgNoLoopback -Apply 6>$null } catch { $s4err = "$_" }
Assert-Contract ($null -eq $s4err -and $script:s4.sends.Count -eq 0) "Stage 4 with entra.browserSignIn false must not require http://localhost on the gateway app. sends: $($script:s4.sends -join '; ') error: $s4err"
$script:s4 = New-S4World; $script:s4.apps.gw.publicClient.redirectUris = @('ms-appx-web://microsoft.aad.brokerplugin/a-gw', 'https://localhost')
$s4err = $null; try { $null = Invoke-Stage4 -Cfg $cfg4 -Apply 6>$null } catch { $s4err = "$_" }
Assert-Contract (@($script:s4.sends) -contains 'patch applications/o-gw') 'Stage 4 by default must still require http://localhost on the gateway app (https://localhost does not match the client loopback).'
$script:s4 = New-S4World; $script:s4.apps.gw.publicClient.redirectUris = @('https://localhost')
$s4err = $null; try { $null = Invoke-Stage4 -Cfg $cfgNoLoopback -Apply 6>$null } catch { $s4err = "$_" }
Assert-Contract (@($script:s4.sends) -contains 'patch applications/o-gw') 'Stage 4 with entra.browserSignIn false must still require the Windows broker redirect.'
# entra.manualVerification: the operator cannot get a Microsoft Graph token (Conditional Access, AADSTS53003)
# and an Entra administrator confirmed the settings in the Portal. Stage 4 records the configured IDs, no Graph.
$script:s4graph = [Collections.Generic.List[string]]::new()
function Get-StgGraph { param([string]$Path) $script:s4graph.Add($Path); throw 'AADSTS53003: access blocked by Conditional Access (fake)' }
$cfgManual = $cfg4.Clone(); $cfgManual.entra = $cfg4.entra.Clone()
$cfgManual.entra.manualVerification = @{ confirmedBy = 'Entra admin, change 123'; confirmedOn = '2026-10-29' }
$cfgManual.groups = @(@{ projectId = 'P1'; classification = 'STD'; groupId = 'g-1'; groupDisplayName = 'CCOF P1 STD'; members = @() })
$script:s4 = New-S4World
$m = $null; $s4err = $null; try { $m = Invoke-Stage4 -Cfg $cfgManual -Apply 6>$null } catch { $s4err = "$_" }
Assert-Contract ($null -eq $s4err -and $script:s4graph.Count -eq 0 -and $script:s4.sends.Count -eq 0) "Stage 4 with entra.manualVerification must make no Microsoft Graph call. reads: $($script:s4graph -join '; ') error: $s4err"
Assert-Contract ($m.registrations.gatewayApi.appId -ceq 'a-gw' -and $m.registrations.developerSignIn.appId -ceq 'a-gw' -and $m.registrations.resolverApi.appId -ceq 'a-res' -and
    $m.gatewayIdentifierUri -ceq 'api://a-gw' -and $m.admin.appId -ceq 'a-adm' -and $m.groups['P1/STD'].id -ceq 'g-1' -and $m.groups['P1/STD'].displayName -ceq 'CCOF P1 STD' -and
    $m.azureCliClientAllowed -eq $true -and $m.verification -ceq 'manual' -and $m.manualVerification.confirmedBy -ceq 'Entra admin, change 123') 'Stage 4 with entra.manualVerification must record the configured application and group IDs that Stages 5, 7 and 8 read.'
$previewText = (Invoke-Stage4 -Cfg $cfgManual 6>&1 | Out-String)
Assert-Contract ($script:s4graph.Count -eq 0 -and $previewText -match 'Expose an API' -and $previewText -match $cli -and $previewText -match 'https://lab-admin\.azurewebsites\.net/api/console-v3' -and $previewText -match 'g-1') 'Stage 4 preview with entra.manualVerification must print the Portal checklist, without Graph.'
Assert-Contract ($previewText -match 'Enterprise applications' -and $previewText -match 'a-res' -and $previewText -match 'a-gw' -and $previewText -match 'service principal') 'Stage 4 manual checklist must ask the Entra admin to confirm the gateway and resolver enterprise applications (service principals); APIM cannot get a resolver token without one.'
$cfgManualMembers = $cfgManual.Clone(); $cfgManualMembers.groups = @(@{ projectId = 'P1'; classification = 'STD'; groupId = 'g-1'; members = @('u-1') })
$s4err = $null; try { $null = Invoke-Stage4 -Cfg $cfgManualMembers -Apply 6>$null } catch { $s4err = "$_" }
Assert-Contract ($s4err -match 'manual_verification' -and $s4err -match 'members' -and $script:s4graph.Count -eq 0) 'Stage 4 with entra.manualVerification must refuse group members it cannot add without Graph.'
$cfgManualNoIds = $cfgManual.Clone(); $cfgManualNoIds.entra = $cfgManual.entra.Clone(); $cfgManualNoIds.entra.existing = @{ gatewayAppId = 'a-gw'; adminAppId = 'a-adm' }
$s4err = $null; try { $null = Invoke-Stage4 -Cfg $cfgManualNoIds -Apply 6>$null } catch { $s4err = "$_" }
Assert-Contract ($s4err -match 'manual_verification' -and $s4err -match 'resolverAppId') 'Stage 4 with entra.manualVerification must refuse a missing existing application ID.'
# Stage 7 takes the delegated group snapshot with the operator's own Graph token. With
# entra.manualVerification that token is unavailable, so Stage 7 leaves membership to the sync timer
# (sync.mode application-permission) and refuses a mode in which nothing could read the groups.
Assert-Contract ((Get-StgStage7SnapshotPlan @{ entra = @{}; sync = @{ mode = 'delegated-snapshot' } }) -ceq 'delegated') 'Stage 7 must keep the delegated snapshot by default.'
Assert-Contract ((Get-StgStage7SnapshotPlan @{ entra = @{}; sync = @{ mode = 'application-permission' } }) -ceq 'delegated') 'Stage 7 must keep the delegated snapshot for application-permission when the operator can read Graph.'
Assert-Contract ((Get-StgStage7SnapshotPlan @{ entra = @{ manualVerification = @{ confirmedBy = 'x'; confirmedOn = '2026-10-29' } }; sync = @{ mode = 'application-permission' } }) -ceq 'sync-timer') 'Stage 7 with entra.manualVerification must leave group membership to the sync timer.'
$planErr = $null; try { $null = Get-StgStage7SnapshotPlan @{ entra = @{ manualVerification = @{ confirmedBy = 'x'; confirmedOn = '2026-10-29' } }; sync = @{ mode = 'delegated-snapshot' } } } catch { $planErr = "$_" }
Assert-Contract ($planErr -match 'manual_verification_sync_mode' -and $planErr -match 'application-permission') 'Stage 7 with entra.manualVerification must refuse sync.mode delegated-snapshot, which needs the operator''s Graph token.'
$stage7Src = (Get-Command Invoke-Stage7).Definition
$planAt = $stage7Src.IndexOf('Get-StgStage7SnapshotPlan'); $codeAt = $stage7Src.IndexOf('Invoke-QsCode'); $snapAt = $stage7Src.IndexOf('snapshot --credential azure-cli')
$gatedSnapshot = [regex]::IsMatch($stage7Src, "if \(\`$snapshotPlan -ceq 'delegated'\) \{\s*\r?\n(?:(?!\} else \{).)*?snapshot --credential azure-cli", 'Singleline')
Assert-Contract ($planAt -ge 0 -and $planAt -lt $codeAt -and $gatedSnapshot -and $snapAt -gt $planAt) 'Stage 7 must decide the snapshot plan before publishing code and run the delegated snapshot only for the delegated plan.'
# Stage 8 calls acceptance.gatewayUrl when set (the address users are given), else Stage 5's APIM URL.
Assert-Contract ((Get-StgStage8GatewayUrl -Cfg @{ acceptance = @{ allowed = @() } } -Stage5 @{ gatewayUrl = 'https://apim.example.net/claude' }) -ceq 'https://apim.example.net/claude') 'Stage 8 must default to the Stage 5 APIM gateway URL.'
Assert-Contract ((Get-StgStage8GatewayUrl -Cfg @{ acceptance = @{ gatewayUrl = 'https://fd.example.net/claude' } } -Stage5 @{ gatewayUrl = 'https://apim.example.net/claude' }) -ceq 'https://fd.example.net/claude') 'Stage 8 must call acceptance.gatewayUrl when it is set.'
$stage8Src = (Get-Command Invoke-Stage8).Definition
Assert-Contract ($stage8Src -match 'Get-StgStage8GatewayUrl' -and $stage8Src -notmatch '-Url \$config\.gatewayUrl') 'Every Stage 8 gateway request must use Get-StgStage8GatewayUrl, not the Stage 5 URL directly.'
# Stage 5 reads the APIM identity's client ID from Azure Resource Manager, not Microsoft Graph.
$script:miArm = @(); $script:miReply = @{ properties = @{ principalId = 'p-apim'; clientId = '00000000-0000-4000-8000-0000000000aa' } }
function Get-StgArm { param([string]$Path, [string]$ApiVersion) $script:miArm += "$Path|$ApiVersion"; $script:miReply }
$miClient = Get-StgManagedIdentityClientId -ResourceId '/subscriptions/s/resourceGroups/g/providers/Microsoft.ApiManagement/service/apim' -PrincipalId 'p-apim'
Assert-Contract ($miClient -ceq '00000000-0000-4000-8000-0000000000aa' -and $script:miArm[0] -ceq '/subscriptions/s/resourceGroups/g/providers/Microsoft.ApiManagement/service/apim/providers/Microsoft.ManagedIdentity/identities/default|2023-01-31') 'The APIM identity client ID must come from the ARM identities/default resource.'
$miErr = $null; try { $null = Get-StgManagedIdentityClientId -ResourceId '/x' -PrincipalId 'p-other' } catch { $miErr = "$_" }
Assert-Contract ($miErr -match 'managed_identity_mismatch') 'The ARM identity lookup must refuse a principal that is not the expected one.'
$stage5Body = [regex]::Match((Get-Content -Raw (Join-Path $root 'infra\staged\Staged.Application.ps1')), '(?s)function Invoke-Stage5 \{.*?\n\}').Value
Assert-Contract ($stage5Body.Length -gt 0 -and $stage5Body -notmatch 'Get-StgGraph' -and $stage5Body -match 'Get-StgManagedIdentityClientId') 'Stage 5 must not call Microsoft Graph (operators blocked by Conditional Access run it).'
Remove-Item Function:\Get-StgArm
Remove-Item Function:\Invoke-StgAzJson
. $driverPath -DotSourceOnly
$headers = New-StgGatewayHeaders -Token 'token-placeholder' -Project 'PROJECT01' -ProjectHeader 'x-customer-project'
Assert-Contract ($headers['x-customer-project'] -ceq 'PROJECT01' -and -not $headers.ContainsKey('x-ccof-project')) 'Stage 8 must use the configured project selector header.'
$priorResourceId = '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/shared/providers/Microsoft.Storage/storageAccounts/prefix-owned/blobServices/default'
$changes = @(
    @{ changeType = 'Create'; resourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/prefix-new' }
    @{ changeType = 'Modify'; resourceId = $priorResourceId }
    @{ changeType = 'Modify'; resourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.ApiManagement/service/prefix-unrelated' }
)
$unsafe = @(Get-StgUnsafeSharedChanges -Changes $changes -PriorStage1TargetIds @($priorResourceId))
Assert-Contract ($unsafe.Count -eq 1 -and $unsafe[0].resourceId -like '*prefix-unrelated') 'Shared Stage 1 must use exact prior operation IDs, not a colliding prefix.'
Assert-Contract ((Test-StgExactResourceScope $priorResourceId @($priorResourceId)) -and -not (Test-StgExactResourceScope '/subscriptions/s/resourceGroups/rg/providers/Microsoft.ApiManagement/service/prefix-unrelated' @($priorResourceId))) 'Stage 1 and Stage 4 grant inventory must use exact resource IDs, not matching names.'
$delete = @(Get-StgUnsafeSharedChanges -Changes @(@{ changeType = 'Delete'; resourceId = $priorResourceId }) -PriorStage1TargetIds @($priorResourceId))
Assert-Contract ($delete.Count -eq 1) 'Shared Stage 1 must always refuse Delete, even for a prior target.'
$example = Join-Path $root 'infra\staged\staged.config.example.json'
$refused = $false
try { $null = Read-StgConfig $example } catch { $refused = $_.Exception.Message -match 'tenantId must be a GUID' }
Assert-Contract $refused 'Example configuration with placeholders must be refused.'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "staged-config-$([guid]::NewGuid().ToString('N')).json"
try {
    $c = Get-Content -LiteralPath $example -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $c.tenantId = '00000000-0000-4000-8000-000000000001'; $c.subscriptionId = '00000000-0000-4000-8000-000000000002'; $c.resourceGroup = 'rg-new'
    $vnetPath = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets'
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $placeholderRefused = $false
    try { $null = Read-StgConfig $tmp } catch { $placeholderRefused = $_.Exception.Message -match 'network.mode verify requires' }
    Assert-Contract $placeholderRefused 'The example''s placeholder subnet IDs must be refused in verify mode.'
    $c.network.existing = @{ functionsSubnetId = "$vnetPath/functions"; privateEndpointSubnetId = "$vnetPath/private"; apimSubnetId = "$vnetPath/apim" }
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $read = Read-StgConfig $tmp
    Assert-Contract ($read.network.mode -ceq 'verify') 'The example network mode must be verify: the customer builds the network.'
    Assert-Contract ($read.stage1.prefix -ceq 'ccofstg' -and $read.stage1.functionsPublicNetworkAccess -ceq 'Disabled' -and $read.stage1.approveNewPublicApimBootstrap -eq $false) 'Example defaults must stay private and defer APIM.'
    Assert-Contract ($read.stage1.Contains('apimZoneRedundant') -and $read.stage1.apimZoneRedundant -is [bool] -and $read.stage1.apimZoneRedundant -eq $false -and (Get-Stage1Parameters $read).apimZoneRedundant -eq $false) 'Example stage1.apimZoneRedundant must be false and reach the Stage 1 parameters.'
    $c.stage1.apimZoneRedundant = 'yes'
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'stage1\.apimZoneRedundant must be true or false' }
    Assert-Contract $bad 'A non-boolean stage1.apimZoneRedundant must be refused.'
    $c.stage1.apimZoneRedundant = $true; $c.stage1.apimSku = 'BasicV2'
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'stage1\.apimZoneRedundant requires stage1\.apimSku StandardV2 or PremiumV2' }
    Assert-Contract $bad 'Zone redundancy with BasicV2 must be refused.'
    $c.stage1.apimSku = 'StandardV2'; $c.stage1.apimUnits = 1
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $zrWarnings = $null; $read = Read-StgConfig $tmp -WarningVariable zrWarnings -WarningAction SilentlyContinue
    Assert-Contract ($read.stage1.apimZoneRedundant -eq $true -and @($zrWarnings | Where-Object { "$_" -match 'stage1\.apimZoneRedundant with stage1\.apimUnits 1.*at least two units' }).Count -eq 1) 'Zone redundancy with one unit must be accepted with a warning (Learn: at least two units recommended).'
    $c.stage1.apimUnits = 2
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $zrWarnings = $null; $read = Read-StgConfig $tmp -WarningVariable zrWarnings -WarningAction SilentlyContinue
    Assert-Contract ($read.stage1.apimZoneRedundant -eq $true -and -not @($zrWarnings | Where-Object { "$_" -match 'apimZoneRedundant' }).Count) 'Zone redundancy with two units must be accepted without a warning.'
    $c.stage1.apimZoneRedundant = $false; $c.stage1.apimUnits = 1
    $c.entra.browserSignIn = 'no'
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'entra\.browserSignIn must be true or false' }
    Assert-Contract $bad 'A non-boolean entra.browserSignIn must be refused.'
    $c.entra.browserSignIn = $false
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $read = Read-StgConfig $tmp
    Assert-Contract ($read.entra.browserSignIn -eq $false -and (Get-Command Get-StgQuickstartParameters) ) 'entra.browserSignIn false must be accepted.'
    $c.entra.Remove('browserSignIn')
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $read = Read-StgConfig $tmp
    # acceptance.gatewayUrl: Stage 8 tests the address users are given (for example a Front Door host).
    foreach ($badUrl in @('http://fd.example.net/claude', 'https://fd.example.net/claude/v1', 'https://fd.example.net/claude/', 'not a url', 5,
        "https://fd.example.net$($c.apim.apiPath.Trim('/'))", 'https://fd.example.net', 'https://fd.example.net/other-path')) {
        $c.acceptance.gatewayUrl = $badUrl
        $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
        $bad = ''; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message }
        Assert-Contract ($bad -match 'acceptance\.gatewayUrl') "acceptance.gatewayUrl '$badUrl' must be refused (https, no trailing slash, no /v1)."
    }
    $validUrl = "https://ccof-fd.z01.azurefd.net/$($c.apim.apiPath.Trim('/'))"
    $c.acceptance.gatewayUrl = $validUrl
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $read = Read-StgConfig $tmp
    Assert-Contract ($read.acceptance.gatewayUrl -ceq $validUrl) 'A valid acceptance.gatewayUrl (Front Door host plus apim.apiPath) must be accepted.'
    $c.acceptance.Remove('gatewayUrl')
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $c.entra.manualVerification = @{ confirmedBy = ''; confirmedOn = '2026-10-29' }
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = ''; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message }
    Assert-Contract ($bad -match 'entra\.manualVerification\.confirmedBy' -and $bad -match 'entra\.existing\.gatewayAppId' -and $bad -match 'members') 'entra.manualVerification must be refused without a confirmer, existing application IDs and member-free groups.'
    $c.entra.manualVerification = @{ confirmedBy = 'Entra admin'; confirmedOn = '2026-10-29' }
    $c.entra.existing = @{ gatewayAppId = '00000000-0000-4000-8000-000000000011'; resolverAppId = '00000000-0000-4000-8000-000000000012'; adminAppId = '00000000-0000-4000-8000-000000000013' }
    $savedGroups = $c.groups
    $c.groups = @($c.groups | ForEach-Object { $g = $_.Clone(); $g.groupId = '00000000-0000-4000-8000-0000000000' + (20 + [array]::IndexOf($c.groups, $_)); $g.members = @(); $g })
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $read = Read-StgConfig $tmp
    Assert-Contract ($read.entra.manualVerification.confirmedBy -ceq 'Entra admin') 'A complete entra.manualVerification must be accepted.'
    $c.entra.Remove('manualVerification'); $c.entra.Remove('existing'); $c.groups = $savedGroups
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $c.reconciler.continuityGate = 'on'
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'ledgerCoverageStartAt is required' }
    Assert-Contract $bad 'An enabled staged continuity gate must have a coverage start.'
    $c.reconciler.ledgerCoverageStartAt = '2026-10-20T15:41:34.000Z'
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $read = Read-StgConfig $tmp
    Assert-Contract ($read.reconciler.continuityGate -ceq 'on' -and $read.reconciler.ledgerCoverageStartAt -ceq '2026-10-20T15:41:34.000Z') 'Staged config accepts and retains valid continuity settings.'
    $c.reconciler.continuityGate = $null
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'continuityGate must be on or off' }
    Assert-Contract $bad 'Staged config refuses an explicitly null continuity gate.'
    $c.reconciler.continuityGate = 'on'
    $c.reconciler.ledgerCoverageStartAt = '2026-10-20T15:41:34+00:00'
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'valid UTC timestamp' }
    Assert-Contract $bad 'Staged config refuses non-canonical UTC coverage starts.'
    $c.reconciler.ledgerCoverageStartAt = '2026-10-20T15:41:34.000Z'
    $stage1Parameters = Get-Stage1Parameters $read
    $recordedParameters = @{ properties = @{ parameters = @{} } }
    foreach ($key in $stage1Parameters.Keys) { $recordedParameters.properties.parameters[$key] = @{ value = $stage1Parameters[$key] } }
    Assert-StgStage1Parameters $recordedParameters $read
    $recordedParameters.properties.parameters.storagePublicNetworkAccess.value = 'Enabled'
    $mismatch = $false
    try { Assert-StgStage1Parameters $recordedParameters $read } catch { $mismatch = $_.Exception.Message -match 'stage1_parameters_changed' }
    Assert-Contract $mismatch 'A completed Stage 1 deployment with different parameters must not be adopted.'
    $c.stage1.prefix = 'BAD_PREFIX'; $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'prefix' }
    Assert-Contract $bad 'An invalid prefix must be refused.'
    $c.stage1.prefix = 'ccofstg'
    $c.stage1.foundry.create = $true
    $c.stage1.foundry.modelProviderData = @{ organizationName = 'Example Corp'; countryCode = 'US'; industry = 'Technology' }
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'industry' }
    Assert-Contract $bad 'Anthropic model-provider industry must use a supported lowercase value.'
    $c.stage1.foundry.modelProviderData.industry = 'technology'
    $c.stage1.foundry.deployments[1].name = $c.stage1.foundry.deployments[0].name
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'unique' }
    Assert-Contract $bad 'Duplicate Foundry deployment names must be refused.'
    $c.stage1.foundry.deployments[1].name = 'claude-sonnet-5'
    if (-not $c.entra.existing) { $c.entra.existing = @{} }
    $c.entra.existing.Remove('adminAppId')
    $c.entra.adminEditors = @()
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'adminEditors' }
    Assert-Contract $bad 'A new assignment-required admin app must have at least one editor.'
    $c.entra.existing.adminAppId = '00000000-0000-4000-8000-000000000003'
    $c.entra.adminEditors = @()
    $c.stage1.foundry.create = $false
    $c.network.mode = 'existing'
    $c.network.existing = @{
        privateEndpointSubnetId = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/private'
        functionsSubnetId = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/functions'
        apimSubnetId = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/apim'
        privateDnsZoneIds = @{ cosmos = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com'; blob = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net' }
    }
    $c.backends[0].privateEndpoint = $true
    $c.backends[0].subscriptionId = $c.subscriptionId
    $c.backends[0].resourceGroup = $c.resourceGroup
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'private Foundry.*requires' }
    Assert-Contract $bad 'Existing-network private Foundry configuration must require all three zone IDs.'
    # Customer deployment 2026-10-26: privateDnsZoneIds placed under network, not network.existing.
    $c.backends[0].privateEndpoint = $false
    $zones = $c.network.existing.privateDnsZoneIds
    $c.network.existing.Remove('privateDnsZoneIds'); $c.network.privateDnsZoneIds = $zones
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $message = ''; try { $null = Read-StgConfig $tmp } catch { $message = $_.Exception.Message }
    Assert-Contract ($message -match 'network\.existing\.privateDnsZoneIds' -and $message -match 'not under network' -and $message -notmatch 'null array') "Misplaced privateDnsZoneIds must be named, not crash: $message"
    $c.network.Remove('privateDnsZoneIds'); $c.network.existing.privateDnsZoneIds = $zones
    # A trailing comma: strict JSON parse error must name the file as the cause.
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    (Get-Content -LiteralPath $tmp -Raw) -replace '(\S)(\s*\}\s*)$', '$1,$2' | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM -NoNewline
    $message = ''; try { $null = Read-StgConfig $tmp } catch { $message = $_.Exception.Message }
    Assert-Contract ($message -match 'staged configuration is not strict JSON' -and $message -match 'trailing comma') "A trailing comma must be reported as a configuration JSON error: $message"
    # Client aliases are checked at Stage 0, not first at Stage 7 (Invoke-QsClient).
    $models = $c.client.models
    $c.client.models = [ordered]@{ default = 'claude-sonnet-5'; sonnet = 'claude-sonnet-5'; haiku = 'claude-haiku-4-5' }
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $message = ''; try { $null = Read-StgConfig $tmp } catch { $message = $_.Exception.Message }
    Assert-Contract ($message -match 'client\.models must name exactly default, opus, sonnet and haiku') "Three client aliases must be refused at config read: $message"
    $c.client.models = [ordered]@{ default = 'claude-sonnet-5'; opus = 'claude-sonnet-5'; sonnet = 'claude-sonnet-5'; haiku = 'claude-haiku-5-5' }
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $message = ''; try { $null = Read-StgConfig $tmp } catch { $message = $_.Exception.Message }
    Assert-Contract ($message -match 'client\.models\.haiku' -and $message -match 'claude-haiku-5-5') "An alias outside the selected group's admitted models must be refused: $message"
    $c.client.models = $models
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $read = Read-StgConfig $tmp
    Assert-Contract ($read.client.models.haiku -ceq 'claude-haiku-4-5') 'Admitted client aliases must be accepted.'
} finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
# State is bound to its tenant/subscription/RG: another target's outputs are refused, not reused.
$stateDir = Join-Path ([IO.Path]::GetTempPath()) "staged-state-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $stateDir | Out-Null
try {
    $script:StateDir = $stateDir
    $cfgA = @{
        tenantId = '00000000-0000-4000-8000-00000000000a'
        subscriptionId = '00000000-0000-4000-8000-00000000000b'
        resourceGroup = 'rg-a'
        location = 'eastus2'
        tags = @{}
        sharedResourceGroup = $false
        stage1 = @{ prefix = 'abc123'; includeAdmin = $true }
        cosmos = @{ databaseName = 'ccof'; capacityMode = 'serverless' }
        sync = @{ mode = 'delegated-snapshot' }
        backends = @()
    }
    Save-StgStage $cfgA 1 @{ marker = 'a'; durationSeconds = 1 }
    Assert-Contract ((Get-StgStage $cfgA 1).marker -ceq 'a') 'State must return its own target outputs.'
    $cfgB = $cfgA.Clone()
    $cfgB.subscriptionId = '00000000-0000-4000-8000-00000000000c'
    $mismatch = $false
    try { $null = Get-StgStage $cfgB 1 } catch { $mismatch = $_.Exception.Message -match 'state_target_mismatch' }
    Assert-Contract $mismatch 'State of another subscription must be refused.'
    $cfgA.stage1.prefix = 'xyz789'
    $changed = $false
    try { $null = Get-StgStage $cfgA 1 } catch { $changed = $_.Exception.Message -match 'stage_config_changed' }
    Assert-Contract $changed 'Stage outputs must not be reused after that stage config changes.'
    $cfgA.stage1.prefix = 'abc123'
    # Network-last order: 2 schema, 3 grants (needs 2), 4 Entra, 5 configuration, 6 network, 7 code (needs 6).
    Assert-Contract ((@(Get-StgStageDependencies 3) -join ',') -ceq '1,2') 'Grants (Stage 3) must depend on Stage 1 and the schema (Stage 2).'
    Assert-Contract ((@(Get-StgStageDependencies 6) -join ',') -ceq '1') 'The network (Stage 6) must need only Stage 1 resources.'
    Assert-Contract ((@(Get-StgStageDependencies 7) -join ',') -ceq '1,4,5,6') 'Publishing (Stage 7) must require Entra, configuration and the verified network.'
    foreach ($n in 2..5) { Assert-Contract (@(Get-StgStageDependencies $n) -notcontains 6) "Stage $n must not need the network: it runs before Stage 6." }
    Save-StgStage $cfgA 2 @{ marker = 'schema-a' }
    Save-StgStage $cfgA 3 @{ marker = 'grants-a' }
    Save-StgStage $cfgA 1 @{ marker = 'a'; durationSeconds = 999 }
    Assert-Contract ((Get-StgStage $cfgA 3).marker -ceq 'grants-a') 'A duration-only change must not invalidate dependent stages.'
    Save-StgStage $cfgA 2 @{ marker = 'schema-a'; verify = @{ containers = 9; readAt = 'later' } }
    Assert-Contract ((Get-StgStage $cfgA 3).marker -ceq 'grants-a') 'A changed read-back snapshot (verify) must not invalidate dependent stages.'
    $state = Read-StgState $cfgA
    $legacyOutput = ConvertTo-StgCanonical $state.stages['1'].outputs | ConvertTo-Json -Depth 100 -Compress
    $state.stages['3'].dependencyHashes['1'] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($legacyOutput))).ToLowerInvariant()
    $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Get-StgStatePath $cfgA) -Encoding utf8NoBOM
    $null = Get-StgStage $cfgA 3
    $state = Read-StgState $cfgA
    Assert-Contract ($state.stages['3'].dependencyHashes['1'] -ceq (Get-StgDependencyHashes $state 3)['1']) 'Legacy duration-inclusive dependency hashes must migrate only when the saved output matches exactly.'
    Save-StgStage $cfgA 2 @{ marker = 'schema-b' }
    $dependencyChanged = $false
    try { $null = Get-StgStage $cfgA 3 } catch { $dependencyChanged = $_.Exception.Message -match 'stage_dependency_changed' }
    Assert-Contract $dependencyChanged 'Downstream outputs must not be reused after a prerequisite stage is reapplied.'

    # Layout 1 state (network was Stage 2) moves to the network-last keys, hashes untouched, with a backup.
    $legacyDir = Join-Path $stateDir 'layout1'; New-Item -ItemType Directory -Path $legacyDir | Out-Null
    $script:StateDir = $legacyDir
    $layout1 = @{ schemaVersion = 1; target = (Get-StgTarget $cfgA); stages = @{
        '1' = @{ configHash = 'h1'; outputs = @{ marker = 'resources' } }
        '2' = @{ configHash = 'h2'; dependencyHashes = @{ '1' = 'd1' }; outputs = @{ marker = 'network' } }
        '3' = @{ configHash = 'h3'; dependencyHashes = @{ '1' = 'd1' }; outputs = @{ marker = 'schema' } }
        '4' = @{ configHash = 'h4'; dependencyHashes = @{ '1' = 'd1'; '3' = 'd3' }; outputs = @{ marker = 'grants' } }
        '6' = @{ configHash = 'h6'; dependencyHashes = @{ '1' = 'd1'; '4' = 'd4'; '5' = 'd5' }; outputs = @{ marker = 'config' } }
        '7' = @{ configHash = 'h7'; dependencyHashes = @{ '1' = 'd1'; '2' = 'd2'; '5' = 'd5'; '6' = 'd6' }; outputs = @{ marker = 'code' } } } }
    $layout1 | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $legacyDir 'state.json') -Encoding utf8NoBOM
    $moved = Read-StgState $cfgA
    Assert-Contract ($moved.stageLayout -eq 2 -and $moved.stages['6'].outputs.marker -ceq 'network' -and $moved.stages['2'].outputs.marker -ceq 'schema' -and
        $moved.stages['3'].outputs.marker -ceq 'grants' -and $moved.stages['5'].outputs.marker -ceq 'config' -and -not $moved.stages['4']) 'Layout 1 stage keys must move to the network-last numbers.'
    Assert-Contract ((($moved.stages['3'].dependencyHashes.Keys | Sort-Object) -join ',') -ceq '1,2' -and $moved.stages['3'].dependencyHashes['2'] -ceq 'd3') 'Moved dependency hashes must keep their values under the new keys.'
    Assert-Contract ((($moved.stages['7'].dependencyHashes.Keys | Sort-Object) -join ',') -ceq '1,4,5,6' -and $moved.stages['7'].dependencyHashes['6'] -ceq 'd2') 'Stage 7 must keep its network dependency under Stage 6.'
    Assert-Contract (Test-Path -LiteralPath (Join-Path $legacyDir 'state.layout1.json')) 'Layout migration must keep a backup of the original state.'
    Assert-Contract ((Read-StgState $cfgA).stages['6'].outputs.marker -ceq 'network') 'A migrated state must not be migrated twice.'

    # Stage 6 verify mode: the customer network check decides; a FAIL row stops the stage and nothing is created.
    $fakeRepo = Join-Path $stateDir 'repo'; New-Item -ItemType Directory -Path (Join-Path $fakeRepo 'scripts/manual') -Force | Out-Null
    $fakeCheck = Join-Path $fakeRepo 'scripts/manual/Test-NetworkConfiguration.ps1'
    $savedRepo = $script:Repo; $script:Repo = $fakeRepo; $script:StateDir = $stateDir
    try {
        $netCfg = @{ subscriptionId = '00000000-0000-4000-8000-00000000000b'; resourceGroup = 'rg-a'; stage1 = @{ apimSku = 'StandardV2' }
            network = @{ mode = 'verify'; existing = @{ functionsSubnetId = "$vnetPath/functions"; privateEndpointSubnetId = "$vnetPath/private"; apimSubnetId = "$vnetPath/apim" } }
            backends = @(@{ subscriptionId = 's2'; resourceGroup = 'rg-f'; accountName = 'fd1'; privateEndpoint = $true }, @{ subscriptionId = 's2'; resourceGroup = 'rg-f'; accountName = 'fd2'; privateEndpoint = $false }) }
        $stage1Out = @{ cosmosAccountId = '/x/cosmos'; apimName = 'apim1'; apimId = '/x/apim1'
            names = @{ apps = @{ sync = @{ functionApp = 'app-sync'; storageAccount = 'stsync' }; resolver = @{ functionApp = 'app-res'; storageAccount = 'stres' } } } }
        $verifyArgs = Get-StgNetworkVerifyArguments $netCfg $stage1Out
        Assert-Contract ($verifyArgs.VnetResourceId -ceq ($vnetPath -replace '/subnets$', '') -and $verifyArgs.FlexSubnet -ceq 'functions' -and $verifyArgs.PeSubnet -ceq 'private' -and $verifyArgs.ApimSubnet -ceq 'apim') 'Verify mode must check the configured VNet and subnets.'
        Assert-Contract (@($verifyArgs.FunctionAppIds).Count -eq 2 -and @($verifyArgs.StorageAccountIds).Count -eq 2 -and @($verifyArgs.FoundryResourceId).Count -eq 1 -and $verifyArgs.FoundryResourceId[0] -like '*/accounts/fd1') 'Verify mode must check every app, its storage and each private Foundry backend only.'
        $stage1Out.apimName = ''
        Assert-Contract (-not (Get-StgNetworkVerifyArguments $netCfg $stage1Out).Contains('ApimSubnet')) 'Without a Stage 1 Standard v2 APIM, the APIM subnet is not checked.'
        $stage1Out.apimName = 'apim1'
        $fakeBody = @(
            'param([string]$SubscriptionId, [string]$VnetResourceId, [string]$ApimSubnet, [string]$FlexSubnet, [string]$PeSubnet, [string]$CosmosResourceId, [string[]]$StorageAccountIds, [string[]]$FunctionAppIds, [string]$ApimResourceId, [string[]]$FoundryResourceId, [string]$ResultPath)'
            "ConvertTo-Json -InputObject @(@{ Area = 'Subnet'; Item = `$FlexSubnet; State = 'PASS'; Detail = '' }, @{ Area = 'PrivateEndpoint'; Item = 'cosmos [Sql]'; State = 'FAIL'; Detail = 'no private endpoint' }) | Set-Content -LiteralPath `$ResultPath"
            'exit 1')
        Set-Content -LiteralPath $fakeCheck -Encoding utf8NoBOM -Value $fakeBody
        $refused = $false
        try { $null = Invoke-StgNetworkVerify -Cfg $netCfg -Stage1 $stage1Out -Apply } catch { $refused = $_.Exception.Message -match 'verify_failed: the customer network check reported 1 FAIL rows: PrivateEndpoint cosmos' }
        Assert-Contract $refused 'Stage 6 verify must stop on a FAIL row from the network check.'
        Set-Content -LiteralPath $fakeCheck -Encoding utf8NoBOM -Value ($fakeBody -replace "State = 'FAIL'", "State = 'PASS'" -replace '^exit 1$', 'exit 0')
        $ok = Invoke-StgNetworkVerify -Cfg $netCfg -Stage1 $stage1Out -Apply
        Assert-Contract ($ok.mode -ceq 'verify' -and $ok.functionsSubnetId -ceq "$vnetPath/functions" -and $ok.verify.fail -eq 0 -and $ok.verify.pass -eq 2) 'Stage 6 verify must record the subnets and the check result when every row passes.'
    } finally { $script:Repo = $savedRepo }
    # The network check wraps the CLI in a function named Az; a bare `& az` resolves to that function
    # (names are case-insensitive) and recursed forever. Every CLI call must use the resolved executable.
    $checkAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\manual\Test-NetworkConfiguration.ps1'), [ref]$null, [ref]$null)
    $bareAz = @($checkAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Ampersand' -and $n.CommandElements[0].Extent.Text -ieq 'az' }, $true))
    Assert-Contract ($bareAz.Count -eq 0) "Test-NetworkConfiguration.ps1 calls the bare az name, which resolves to its own Az function: $($bareAz.Extent.Text -join '; ')"
    $badVnet = (Get-Content -LiteralPath $example -Raw | ConvertFrom-Json -AsHashtable -Depth 100)
    $badVnet.tenantId = '00000000-0000-4000-8000-000000000001'; $badVnet.subscriptionId = '00000000-0000-4000-8000-000000000002'
    $badVnet.network.existing = @{ functionsSubnetId = "$vnetPath/functions"; privateEndpointSubnetId = ($vnetPath -replace 'vnet/subnets', 'other/subnets') + '/private' }
    $badPath = Join-Path $stateDir 'bad-vnet.json'; $badVnet | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $badPath -Encoding utf8NoBOM
    $refused = $false; try { $null = Read-StgConfig $badPath } catch { $refused = $_.Exception.Message -match 'same VNet' }
    Assert-Contract $refused 'Verify mode must refuse subnets from different VNets.'

    # Existing APIM (apim.existing): gateway diagnostics and outbound VNet integration are opt-in flags.
    $apimCfgPath = Join-Path $stateDir 'apim-existing.json'
    $apimDoc = (Get-Content -LiteralPath $example -Raw | ConvertFrom-Json -AsHashtable -Depth 100)
    $apimDoc.tenantId = '00000000-0000-4000-8000-000000000001'; $apimDoc.subscriptionId = '00000000-0000-4000-8000-000000000002'
    $apimDoc.network.existing = @{ functionsSubnetId = "$vnetPath/functions"; privateEndpointSubnetId = "$vnetPath/private"; apimSubnetId = "$vnetPath/apim" }
    $apimDoc.apim.existing = @{ subscriptionId = '00000000-0000-4000-8000-000000000002'; resourceGroup = 'rg-apim'; name = 'apim-shared'; configureGatewayDiagnostics = $true; integrateOutboundVnet = $true }
    $writeApimDoc = { $apimDoc | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $apimCfgPath -Encoding utf8NoBOM }
    & $writeApimDoc
    $read = Read-StgConfig $apimCfgPath
    Assert-Contract ($read.apim.existing.configureGatewayDiagnostics -eq $true -and $read.apim.existing.integrateOutboundVnet -eq $true) 'Existing-APIM flags set to true must be accepted with a full APIM subnet ID.'
    $apimDoc.apim.existing.configureGatewayDiagnostics = 'true'; & $writeApimDoc
    $refused = $false; try { $null = Read-StgConfig $apimCfgPath } catch { $refused = $_.Exception.Message -match 'apim\.existing\.configureGatewayDiagnostics must be true or false' }
    Assert-Contract $refused 'apim.existing.configureGatewayDiagnostics must refuse a non-boolean value.'
    $apimDoc.apim.existing.configureGatewayDiagnostics = $true; $apimDoc.apim.existing.integrateOutboundVnet = 1; & $writeApimDoc
    $refused = $false; try { $null = Read-StgConfig $apimCfgPath } catch { $refused = $_.Exception.Message -match 'apim\.existing\.integrateOutboundVnet must be true or false' }
    Assert-Contract $refused 'apim.existing.integrateOutboundVnet must refuse a non-boolean value.'
    $apimDoc.apim.existing.integrateOutboundVnet = $true; $apimDoc.network.existing.Remove('apimSubnetId'); & $writeApimDoc
    $refused = $false; try { $null = Read-StgConfig $apimCfgPath } catch { $refused = $_.Exception.Message -match 'integrateOutboundVnet requires network\.existing\.apimSubnetId' }
    Assert-Contract $refused 'apim.existing.integrateOutboundVnet must refuse a missing network.existing.apimSubnetId.'
    $apimDoc.network.existing.apimSubnetId = "$vnetPath/apim" -replace '00000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000009'
    $apimDoc.network.existing.functionsSubnetId = $apimDoc.network.existing.apimSubnetId -replace '/apim$', '/functions'
    $apimDoc.network.existing.privateEndpointSubnetId = $apimDoc.network.existing.apimSubnetId -replace '/apim$', '/private'; & $writeApimDoc
    $refused = $false; try { $null = Read-StgConfig $apimCfgPath } catch { $refused = $_.Exception.Message -match "same subscription as the existing APIM" }
    Assert-Contract $refused 'apim.existing.integrateOutboundVnet must refuse an APIM subnet in another subscription than the APIM.'
    $apimDoc.network.existing = @{ functionsSubnetId = "$vnetPath/functions"; privateEndpointSubnetId = "$vnetPath/private"; apimSubnetId = "$vnetPath/apim" }
    $apimDoc.stage1.approveNewPublicApimBootstrap = $true; & $writeApimDoc
    $refused = $false; try { $null = Read-StgConfig $apimCfgPath } catch { $refused = $_.Exception.Message -match 'apply only to an existing APIM' }
    Assert-Contract $refused 'Existing-APIM flags must be refused when Stage 1 creates the APIM.'
    $apimDoc.stage1.approveNewPublicApimBootstrap = $false; $apimDoc.apim.existing.Remove('configureGatewayDiagnostics'); $apimDoc.apim.existing.Remove('integrateOutboundVnet'); & $writeApimDoc
    $read = Read-StgConfig $apimCfgPath
    Assert-Contract (-not $read.apim.existing.Contains('configureGatewayDiagnostics') -and -not $read.apim.existing.Contains('integrateOutboundVnet')) 'Existing-APIM flags must be optional.'
    $hashAbsent = Get-StgStageInput $read 6
    $read.apim.existing.integrateOutboundVnet = $false; $read.apim.existing.configureGatewayDiagnostics = $false
    Assert-Contract ((Get-StgStageInput $read 6) -ceq $hashAbsent) 'Existing-APIM flags set to false must not change the Stage 6 input hash of a completed deployment.'
    $read.apim.existing.integrateOutboundVnet = $true
    Assert-Contract ((Get-StgStageInput $read 6) -cne $hashAbsent) 'Turning on apim.existing.integrateOutboundVnet must change the Stage 6 input hash.'

    # Fake ARM for the existing APIM; every az call is recorded.
    $script:azCalls = @(); $script:fakeDiag = @(); $script:putBody = $null; $script:patchBody = $null; $script:stripIdentity = $false; $script:dropCategory = $false
    $apimPath = '/subscriptions/00000000-0000-4000-8000-000000000002/resourceGroups/rg-apim/providers/Microsoft.ApiManagement/service/apim-shared'
    $workspace = '/subscriptions/00000000-0000-4000-8000-00000000000b/resourceGroups/rg-a/providers/Microsoft.OperationalInsights/workspaces/law-a'
    $script:fakeApim = @{ id = $apimPath; name = 'apim-shared'; sku = @{ name = 'StandardV2' }; identity = @{ type = 'SystemAssigned'; principalId = '11111111-1111-4111-8111-111111111111' }
        properties = @{ provisioningState = 'Succeeded'; virtualNetworkType = 'None'; publicNetworkAccess = 'Enabled' } }
    function Invoke-QsAz {
        param([string[]]$Arguments)
        $script:azCalls += , ($Arguments -join ' ')
        $method = $Arguments[2]; $url = $Arguments[4]
        if ($Arguments[0] -cne 'rest') { throw "unexpected az call: $($Arguments -join ' ')" }
        if ($url -like '*/diagnosticSettings/ccof-gateway-logs`?*') {
            if ($method -eq 'put') {
                $script:putBody = Get-Content -LiteralPath ($Arguments[$Arguments.IndexOf('--body') + 1].Substring(1)) -Raw | ConvertFrom-Json -AsHashtable
                $stored = $script:putBody | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
                if ($script:dropCategory) { $stored.properties.logs = @($stored.properties.logs[0]) }
                $script:fakeDiag = @(@{ name = 'ccof-gateway-logs'; properties = $stored.properties })
            }
            return $script:fakeDiag[0]
        }
        if ($url -like '*/diagnosticSettings`?*') { return @{ value = $script:fakeDiag } }
        if ($url -like "https://management.azure.com$apimPath`?*") {
            if ($method -eq 'patch') {
                $script:patchBody = Get-Content -LiteralPath ($Arguments[$Arguments.IndexOf('--body') + 1].Substring(1)) -Raw | ConvertFrom-Json -AsHashtable
                $script:fakeApim.properties.virtualNetworkType = $script:patchBody.properties.virtualNetworkType
                $script:fakeApim.properties.virtualNetworkConfiguration = @{ subnetResourceId = $script:patchBody.properties.virtualNetworkConfiguration.subnetResourceId }
                if ($script:stripIdentity) { $script:fakeApim.identity = @{ type = 'None' } }
                return $null
            }
            return $script:fakeApim
        }
        throw "unexpected az call: $($Arguments -join ' ')"
    }
    $script:StgApimPollSeconds = 0
    $existingCfg = @{ subscriptionId = '00000000-0000-4000-8000-00000000000b'; resourceGroup = 'rg-a'; stage1 = @{ approveNewPublicApimBootstrap = $false }
        apim = @{ existing = @{ subscriptionId = '00000000-0000-4000-8000-000000000002'; resourceGroup = 'rg-apim'; name = 'apim-shared' } }
        network = @{ mode = 'verify'; existing = @{ functionsSubnetId = "$vnetPath/functions"; privateEndpointSubnetId = "$vnetPath/private"; apimSubnetId = "$vnetPath/apim" } } }
    $existingS1 = @{ apimName = ''; workspaceId = $workspace }
    $writes = { @($script:azCalls | Where-Object { $_ -match '^rest --method (put|patch|post|delete)' -or $_ -notmatch '^rest --method get' }) }

    # Flags absent and false: no Azure call at all, and preview prints the manual-step note.
    foreach ($value in @($null, $false)) {
        $script:azCalls = @()
        if ($null -ne $value) { $existingCfg.apim.existing.configureGatewayDiagnostics = $value; $existingCfg.apim.existing.integrateOutboundVnet = $value }
        $note = (Invoke-StgExistingApimDiagnostics -Cfg $existingCfg -Stage1 $existingS1 6>&1 | Out-String)
        $applied = Invoke-StgExistingApimDiagnostics -Cfg $existingCfg -Stage1 $existingS1 -Apply 6>$null
        $outbound = Invoke-StgExistingApimOutbound -Cfg $existingCfg -Stage1 $existingS1 -Apply 6>$null
        Assert-Contract ($script:azCalls.Count -eq 0 -and $null -eq $applied -and $null -eq $outbound) "Existing-APIM flags $(if ($null -eq $value) { 'absent' } else { 'false' }) must make no Azure call (made: $($script:azCalls -join '; '))."
        Assert-Contract ($note -match 'apim\.existing\.configureGatewayDiagnostics' -and $note -match 'apim\.existing\.integrateOutboundVnet' -and $note -match 'ccof-gateway-logs') 'Preview for an existing APIM with the flags off must name the manual steps and both flags.'
    }
    $stage1Note = (Write-StgExistingApimNote -Cfg $existingCfg 6>&1 | Out-String)
    Assert-Contract ($stage1Note -match 'integrateOutboundVnet' -and @($stage1Note.Trim() -split "`n").Count -eq 1) 'The existing-APIM note must be one line.'
    $existingCfg.apim.existing.configureGatewayDiagnostics = $true; $existingCfg.apim.existing.integrateOutboundVnet = $true
    Assert-Contract (-not (Write-StgExistingApimNote -Cfg $existingCfg 6>&1 | Out-String).Trim()) 'With both flags on, no manual-step note is printed.'

    # Diagnostics on: preview reads only; apply PUTs exactly ccof-gateway-logs and reads it back.
    $script:azCalls = @()
    $preview = (Invoke-StgExistingApimDiagnostics -Cfg $existingCfg -Stage1 $existingS1 6>&1 | Out-String)
    Assert-Contract ((& $writes).Count -eq 0 -and $preview -match 'preview: .*ccof-gateway-logs.*GatewayLogs, GatewayLlmLogs') "Diagnostics preview must only read (calls: $($script:azCalls -join '; '))."
    $script:azCalls = @()
    $diagResult = Invoke-StgExistingApimDiagnostics -Cfg $existingCfg -Stage1 $existingS1 -Apply 6>$null
    $puts = @($script:azCalls | Where-Object { $_ -match '^rest --method put' })
    Assert-Contract ($puts.Count -eq 1 -and $puts[0] -match [regex]::Escape("https://management.azure.com$apimPath/providers/Microsoft.Insights/diagnosticSettings/ccof-gateway-logs?api-version=2021-05-01-preview")) "Diagnostics apply must PUT one ccof-gateway-logs setting on the existing APIM (calls: $($script:azCalls -join '; '))."
    Assert-Contract ($script:putBody.properties.workspaceId -ceq $workspace -and $script:putBody.properties.logAnalyticsDestinationType -ceq 'Dedicated' -and
        ((@($script:putBody.properties.logs | ForEach-Object { "$($_.category)=$($_.enabled)" }) -join ',') -ceq 'GatewayLogs=True,GatewayLlmLogs=True') -and $script:putBody.Keys.Count -eq 1 -and -not $script:putBody.properties.Contains('metrics')) 'Diagnostics body must match apim-service.bicep: Stage 1 workspace, Dedicated, GatewayLogs and GatewayLlmLogs.'
    Assert-Contract ($diagResult.workspaceId -ceq $workspace -and (($diagResult.categories) -join ',') -ceq 'GatewayLlmLogs,GatewayLogs' -and $diagResult.apimId -ceq $apimPath) 'Diagnostics apply must return the read-back workspace and categories.'
    $script:dropCategory = $true; $script:fakeDiag = @()
    $refused = $false; try { $null = Invoke-StgExistingApimDiagnostics -Cfg $existingCfg -Stage1 $existingS1 -Apply 6>$null } catch { $refused = $_.Exception.Message -match 'verify_failed: .*GatewayLlmLogs' }
    Assert-Contract $refused 'Diagnostics read-back must fail when a category is missing.'
    $script:dropCategory = $false
    # A setting of that name sending to another workspace is never overwritten.
    $script:fakeDiag = @(@{ name = 'ccof-gateway-logs'; properties = @{ workspaceId = ($workspace -replace 'law-a$', 'law-other'); logs = @() } })
    $script:azCalls = @()
    $refused = $false; try { $null = Invoke-StgExistingApimDiagnostics -Cfg $existingCfg -Stage1 $existingS1 -Apply 6>$null } catch { $refused = $_.Exception.Message -match 'apim_diagnostics_conflict: .*law-other' }
    Assert-Contract ($refused -and (& $writes).Count -eq 0) 'A ccof-gateway-logs setting pointing to another workspace must be refused without a write.'
    $script:fakeDiag = @()

    # Outbound integration on: sku read at run time; ARM PATCH of the two network properties only; identity kept.
    $script:fakeApim.sku.name = 'BasicV2'; $script:azCalls = @()
    $refused = $false; try { $null = Invoke-StgExistingApimOutbound -Cfg $existingCfg -Stage1 $existingS1 -Apply 6>$null } catch { $refused = $_.Exception.Message -match 'apim_sku_unsupported: .*BasicV2' }
    Assert-Contract ($refused -and (& $writes).Count -eq 0) 'Outbound integration must refuse an existing APIM whose SKU is not StandardV2/PremiumV2, without a write.'
    $script:fakeApim.sku.name = 'StandardV2'; $script:azCalls = @()
    $null = Invoke-StgExistingApimOutbound -Cfg $existingCfg -Stage1 $existingS1 6>$null
    Assert-Contract ((& $writes).Count -eq 0) 'Outbound integration preview must only read.'
    $outbound = Invoke-StgExistingApimOutbound -Cfg $existingCfg -Stage1 $existingS1 -Apply 6>$null
    $patches = @($script:azCalls | Where-Object { $_ -match '^rest --method patch' })
    Assert-Contract ($patches.Count -eq 1 -and $patches[0] -match [regex]::Escape("--url https://management.azure.com$apimPath`?api-version=2024-05-01")) "Outbound integration must PATCH the existing APIM in its own subscription and resource group (calls: $($script:azCalls -join '; '))."
    Assert-Contract (($script:patchBody | ConvertTo-Json -Depth 5 -Compress) -ceq (@{ properties = @{ virtualNetworkType = 'External'; virtualNetworkConfiguration = @{ subnetResourceId = "$vnetPath/apim" } } } | ConvertTo-Json -Depth 5 -Compress)) 'The PATCH body must hold only virtualNetworkType External and the APIM subnet.'
    Assert-Contract ($outbound.virtualNetworkType -ceq 'External' -and $outbound.identityType -ceq 'SystemAssigned' -and $outbound.name -ceq 'apim-shared') 'Outbound integration must read back External and a SystemAssigned identity.'
    $script:azCalls = @()
    $null = Invoke-StgExistingApimOutbound -Cfg $existingCfg -Stage1 $existingS1 -Apply 6>$null
    Assert-Contract ((& $writes).Count -eq 0) 'An already integrated existing APIM must not be patched again.'
    $script:fakeApim.properties.virtualNetworkType = 'None'; $script:stripIdentity = $true
    $refused = $false; try { $null = Invoke-StgExistingApimOutbound -Cfg $existingCfg -Stage1 $existingS1 -Apply 6>$null } catch { $refused = $_.Exception.Message -match 'verify_failed: .*identity' }
    Assert-Contract $refused 'Outbound integration must fail when the APIM identity is no longer SystemAssigned afterwards.'
    $verifyArgs = Get-StgNetworkVerifyArguments $existingCfg @{ cosmosAccountId = '/x/cosmos'; apimName = ''; names = @{ apps = @{ sync = @{ functionApp = 'app-sync'; storageAccount = 'stsync' } } } }
    Assert-Contract ($verifyArgs.ApimSubnet -ceq 'apim' -and $verifyArgs.ApimResourceId -ceq $apimPath) 'Verify mode must check the existing APIM integration when integrateOutboundVnet is on.'
    Remove-Item Function:\Invoke-QsAz
    . $driverPath -DotSourceOnly
    $script:StateDir = $stateDir

    $lockPath = Join-Path $stateDir 'stage7.lock'
    $lock = Enter-StgStage7Lock $lockPath
    $busy = $false
    try { $second = Enter-StgStage7Lock $lockPath; $second.Dispose() } catch { $busy = $_.Exception.Message -match 'stage7_busy' }
    Assert-Contract $busy 'Concurrent Stage 7 package builds must fail fast.'
    $lock.Dispose()
    $reacquired = Enter-StgStage7Lock $lockPath
    Assert-Contract ($null -ne $reacquired) 'Stage 7 lock must be released for a later retry.'
    $reacquired.Dispose()
} finally { Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue }
$s1Params = @($s1.parameters.Keys)
foreach ($k in $c.stage1.Keys) { Assert-Contract ($s1Params -contains $k) "Example stage1.$k is not a Stage 1 template parameter." }

"Staged stages: $passed checks passed (4 stage boundaries, negative control, Cosmos contract, network-last order and layout migration, network verify mode, driver and configuration). No Azure calls."
