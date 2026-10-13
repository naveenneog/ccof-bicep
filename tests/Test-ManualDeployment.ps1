#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manual = Join-Path $root 'infra\manual'
$failures = 0
function Assert-Manual([string]$Name, [bool]$Condition) {
    if ($Condition) { Write-Host "PASS: $Name" }
    else { Write-Host "FAIL: $Name"; $script:failures++ }
}
function Assert-Refused([string]$Name, [scriptblock]$Action, [string]$ExpectedReason = '') {
    $refused = $false
    try { & $Action | Out-Null } catch { $refused = -not $ExpectedReason -or $_.Exception.Message -like "*$ExpectedReason*" }
    Assert-Manual $Name $refused
}

Assert-Manual 'manual resource input module exists' (Test-Path (Join-Path $manual 'Inputs.psm1'))
if (-not (Test-Path (Join-Path $manual 'Inputs.psm1'))) { exit 1 }
Import-Module (Join-Path $manual 'Inputs.psm1') -Force
. (Join-Path $root 'infra\quickstart\Deploy-Quickstart.ps1') -DotSourceOnly
$p = Read-QsParameters (Join-Path $root 'infra\quickstart\main.bicepparam')
$inputs = @(Get-ManualResourceInputs -P $p -RepositoryRoot $root)
Assert-Manual 'workspace and identities are independent resource shells' (
    ($inputs | Where-Object Stage -eq 'resource-shells').Count -eq 2)
Assert-Manual 'network precedes private-dependent resources' (
    [array]::IndexOf($inputs.Id, 'network') -lt [array]::IndexOf($inputs.Id, 'cosmos'))
Assert-Manual 'three function apps are ordered rather than parallel' (
    (($inputs | Where-Object Id -like 'app-*').Id -join ',') -ceq 'app-resolver,app-sync,app-reconciler')
Assert-Manual 'existing APIM is not redeployed' (-not ($inputs | Where-Object Id -eq 'apim'))
Assert-Manual 'resource inputs never deploy the quickstart monolith or workbook shell' (
    -not ($inputs | Where-Object { $_.Template -match 'quickstart[\\/]main|workbook' }))
Assert-Manual 'Cosmos PE and DNS prerequisites are explicit' (
    ($inputs | Where-Object Id -eq 'cosmos').Parameters.privateEndpointSubnetId.value -match '/subnets/' -and
    ($inputs | Where-Object Id -eq 'cosmos').Parameters.cosmosPrivateDnsZoneId.value -match 'privatelink.documents.azure.com$')

# Compile locally and compare every generated input name to the module's real contract.
foreach ($entry in $inputs) {
    $text = az bicep build --file $entry.Template --stdout --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "compile failed: $($entry.Id)" }
    $template = ($text -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100
    $unknown = @($entry.Parameters.Keys | Where-Object { -not $template.parameters.ContainsKey($_) })
    $missing = @($template.parameters.Keys | Where-Object {
        -not $template.parameters[$_].ContainsKey('defaultValue') -and -not $entry.Parameters.Contains($_)
    })
    Assert-Manual "$($entry.Id) inputs exactly satisfy real Bicep parameters" (-not $unknown.Count -and -not $missing.Count)
    if ($entry.Id -eq 'cosmos') {
        $account = @($template.resources | Where-Object type -eq 'Microsoft.DocumentDB/databaseAccounts')[0]
        Assert-Manual 'Cosmos public access stays disabled and local auth stays off' (
            $account.properties.publicNetworkAccess -ceq 'Disabled' -and $account.properties.disableLocalAuth)
    }
}
$copy = $p | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$copy.network = @{ mode = 'existing'; existing = @{
    privateEndpointSubnetId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.Network/virtualNetworks/v/subnets/pe'
    functionsSubnetId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.Network/virtualNetworks/v/subnets/functions'
    privateDnsZoneIds = @{ cosmos = '/dns/cosmos'; blob = '/dns/blob' }
} }
$existing = @(Get-ManualResourceInputs -P $copy -RepositoryRoot $root)
Assert-Manual 'existing network mode never rewrites a VNet or DNS links' (-not ($existing | Where-Object Id -eq 'network'))
$copy.network.existing.functionsSubnetId = ''
Assert-Refused 'missing integration subnet is rejected before generating inputs' {
    Get-ManualResourceInputs -P $copy -RepositoryRoot $root
}
$copy.network.mode = 'bogus'
Assert-Refused 'unknown network mode is rejected' { Get-ManualResourceInputs -P $copy -RepositoryRoot $root }

$configurationPath = Join-Path $manual 'configuration.bicep'
$text = az bicep build --file $configurationPath --stdout --only-show-errors
Assert-Manual 'configuration entrypoint compiles locally' ($LASTEXITCODE -eq 0)
if ($LASTEXITCODE -eq 0) {
    $configuration = ($text -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100
    $serialized = $configuration | ConvertTo-Json -Depth 100 -Compress
    Assert-Manual 'configuration does not create network, resource shells or workbook shells' (
        $serialized -notmatch '"type":"Microsoft.Network/(virtualNetworks|privateEndpoints)"' -and
        $serialized -notmatch '"type":"Microsoft.Storage/storageAccounts"' -and
        $serialized -notmatch 'workbook-shell|Workbook has not been configured')
    Assert-Manual 'workbook content deployment is conditional' (
        @($configuration.resources | Where-Object { $_.name -match 'manual-workbook' -and $_.condition }).Count -eq 1)
}
. (Join-Path $manual 'Invoke-ManualConfiguration.ps1') -DotSourceOnly
Assert-Manual 'configuration commands have no resource deployment stage' (
    ((Get-ManualConfigurationSteps).Number -join ',') -ceq '1,2,3,4,5,7,8')
Assert-Refused 'out of order seed is refused' {
    Assert-ManualStepPrerequisites -Step 5 -State @{ completed = @{} } -ParametersDigest 'x'
}
Assert-Refused 'changed parameters refuse stale preparation' {
    Assert-ManualStepPrerequisites -Step 3 -State @{ parametersDigest = 'old'; completed = @{ '1' = @{}; '2' = @{} } } -ParametersDigest 'new'
}
Assert-Refused 'wrong completed stage chain is refused' {
    Assert-ManualStepPrerequisites -Step 8 -State @{ parametersDigest = 'x'; completed = @{ '1' = @{}; '3' = @{} } } -ParametersDigest 'x'
}
$originalAz = ${function:Invoke-QsAz}
$originalChecks = ${function:Test-QsPrerequisites}
try {
    function Test-QsPrerequisites { return @{ apimIdentityAppId = 'app' } }
    $script:deploymentAttempted = $false
    function Invoke-QsAz {
        param([string[]]$Arguments)
        if ($Arguments[0] -eq 'deployment') { $script:deploymentAttempted = $true }
        return @{ tenantId = 'another-tenant' }
    }
    Assert-Refused 'cross-tenant backend refused before configuration deployment' {
        Invoke-ManualConfigDeploy @{ P = $p; State = @{ completed = @{} } }
    } 'manual_cross_tenant_backend'
    Assert-Manual 'unsupported backend authentication causes no configuration write' (-not $script:deploymentAttempted)
} finally {
    Set-Item Function:\Invoke-QsAz $originalAz
    Set-Item Function:\Test-QsPrerequisites $originalChecks
}
$scratch = Join-Path $PSScriptRoot ".manual-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $custom = (Get-Content (Join-Path $root 'infra\quickstart\main.bicepparam') -Raw).
        Replace("using 'main.bicep'", "using '../../infra/quickstart/main.bicep'").
        Replace("deploymentPrefix: 'sampleqs'", "deploymentPrefix: 'manualtest'")
    $customPath = Join-Path $scratch 'customer.bicepparam'
    Set-Content -LiteralPath $customPath -Value $custom -Encoding utf8NoBOM
    & (Join-Path $manual 'Export-ManualInputs.ps1') -ParametersPath $customPath -OutputDirectory (Join-Path $scratch 'inputs')
    $manifest = Get-Content (Join-Path $scratch 'inputs\manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-Manual 'export command preserves the caller parameter file when importing quickstart helpers' (
        @($manifest | Where-Object { $_.deploymentName -notlike 'manualtest-*' }).Count -eq 0)
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
Assert-Manual 'runbook names the five-hour load deadline and UI-only blockers' (
    (Get-Content (Join-Path $root 'docs\MANUAL-DEPLOYMENT.md') -Raw) -match 'five-hour' -and
    (Get-Content (Join-Path $root 'docs\MANUAL-DEPLOYMENT.md') -Raw) -match 'Cosmos SQL RBAC')
Write-Host "$failures failed"
if ($failures) { exit 1 }
