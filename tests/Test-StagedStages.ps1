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
    'infra\staged\stage2-network.bicep' = @('Microsoft.Resources/deployments', 'Microsoft.Network/networkSecurityGroups', 'Microsoft.Network/virtualNetworks',
        'Microsoft.Network/privateDnsZones', 'Microsoft.Network/privateDnsZones/virtualNetworkLinks', 'Microsoft.Network/privateEndpoints',
        'Microsoft.Network/privateEndpoints/privateDnsZoneGroups')
    'infra\staged\stage3-schema.bicep' = @('Microsoft.DocumentDB/databaseAccounts/sqlDatabases', 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers')
    'infra\staged\stage4-grants.bicep' = @('Microsoft.Resources/deployments', 'Microsoft.Authorization/roleAssignments',
        'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions', 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments')
    'infra\staged\stage6-config.bicep' = @('Microsoft.Resources/deployments', 'Microsoft.Web/sites/config', 'Microsoft.ApiManagement/service/apis',
        'Microsoft.ApiManagement/service/backends', 'Microsoft.ApiManagement/service/apis/policies', 'Microsoft.ApiManagement/service/apis/operations', 'Microsoft.ApiManagement/service/loggers',
        'Microsoft.ApiManagement/service/apis/diagnostics', 'Microsoft.Insights/workbooks')
}
$arms = @{}
foreach ($path in $boundaries.Keys) {
    $arms[$path] = Build-Arm $path
    Test-StageBoundary $arms[$path] $boundaries[$path] $path
    $passed++
}

# Negative control: the same check rejects a role assignment injected into the network stage.
$mutated = $arms['infra\staged\stage2-network.bicep'] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
$mutated.resources += @{ type = 'Microsoft.Authorization/roleAssignments'; apiVersion = '2022-04-01'; name = 'injected' }
$caught = $false
try { Test-StageBoundary $mutated $boundaries['infra\staged\stage2-network.bicep'] 'mutated stage 2' } catch { $caught = $_.Exception.Message -match 'roleAssignments' }
Assert-Contract $caught 'Negative control: an injected role assignment was not rejected by the boundary check.'

# Stage 6 must never grant: no Authorization resource anywhere, including the reused modules.
Assert-Contract (-not (@(Get-Resources $arms['infra\staged\stage6-config.bicep']) | Where-Object type -Match 'Authorization|sqlRole')) 'Stage 6 contains a grant.'
# Stage 6 must not repeat Stage 1's resource-log diagnostic settings (Azure Monitor refuses duplicates).
Assert-Contract (-not (@(Get-Resources $arms['infra\staged\stage6-config.bicep']) | Where-Object type -EQ 'Microsoft.Insights/diagnosticSettings')) 'Stage 6 repeats a diagnostic setting.'

# Stage 3 and Stage 4 keep the quickstart's Cosmos data contract.
$quick = Build-Arm 'infra\quickstart\modules\cosmos-data.bicep'
$schema = $arms['infra\staged\stage3-schema.bicep']; $grants = $arms['infra\staged\stage4-grants.bicep']
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
$adminScopes = @($grants.variables.cosmosAssignments | Where-Object principal -EQ 'admin' | ForEach-Object { $_.container })
Assert-Contract ((($adminScopes | Sort-Object) -join ',') -ceq 'adminConfig,projects') 'Admin Cosmos access must be limited to projects and adminConfig.'

# Stage 1 publishes the names later stages read.
$s1 = Build-Arm 'infra\staged\main.bicep'
Assert-Contract ($s1.outputs.ContainsKey('names') -and $s1.outputs.ContainsKey('apimName')) 'Stage 1 must output names and apimName.'
Assert-Contract (($s1.parameters.apimSku.allowedValues -join ',') -ceq 'BasicV2,StandardV2' -and $s1.parameters.apimSku.defaultValue -ceq 'StandardV2') 'APIM SKU choice changed.'

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
foreach ($line in ($driver -split "`n" | Where-Object { $_ -match "Invoke-Qs(Az|AzJson)|Invoke-StgAzJson|Get-StgGraph|Get-StgArm" })) {
    foreach ($literal in [regex]::Matches($line, "'[^']*'")) {
        Assert-Contract ($literal.Value -notmatch '[&|<>^]') "Driver passes a cmd.exe metacharacter to az: $($literal.Value)"
    }
}
Assert-Contract ($driver -match '\[switch\]\$Apply' -and $driver -match "what-if") 'Driver must preview by default.'
foreach ($n in 2..8) {
    $body = @($functionAsts | Where-Object Name -EQ "Invoke-Stage$n")[0].Body.Extent.Text
    Assert-Contract ($body -match 'Get-StgStage \$Cfg 1') "Invoke-Stage$n does not require Stage 1 state."
}

# Configuration: the committed example is refused until its placeholders are replaced; a filled copy passes.
. $driverPath -DotSourceOnly
$example = Join-Path $root 'infra\staged\staged.config.example.json'
$refused = $false
try { $null = Read-StgConfig $example } catch { $refused = $_.Exception.Message -match 'tenantId must be a GUID' }
Assert-Contract $refused 'Example configuration with placeholders must be refused.'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "staged-config-$([guid]::NewGuid().ToString('N')).json"
try {
    $c = Get-Content -LiteralPath $example -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $c.tenantId = '00000000-0000-4000-8000-000000000001'; $c.subscriptionId = '00000000-0000-4000-8000-000000000002'; $c.resourceGroup = 'rg-new'
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $read = Read-StgConfig $tmp
    Assert-Contract ($read.stage1.prefix -ceq 'ccofstg' -and $read.stage1.functionsPublicNetworkAccess -ceq 'Disabled' -and $read.stage1.approveNewPublicApimBootstrap -eq $false) 'Example defaults must stay private and defer APIM.'
    $c.stage1.prefix = 'BAD_PREFIX'; $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    $bad = $false; try { $null = Read-StgConfig $tmp } catch { $bad = $_.Exception.Message -match 'prefix' }
    Assert-Contract $bad 'An invalid prefix must be refused.'
} finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
$s1Params = @($s1.parameters.Keys)
foreach ($k in $c.stage1.Keys) { Assert-Contract ($s1Params -contains $k) "Example stage1.$k is not a Stage 1 template parameter." }

"Staged stages: $passed checks passed (4 stage boundaries, negative control, Cosmos contract, driver and configuration). No Azure calls."
