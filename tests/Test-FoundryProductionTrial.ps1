#Requires -Version 7.0
param()

$ErrorActionPreference = 'Stop'
if ($env:CCOF_LIVE_TESTS -cne '0' -or -not $env:AZURE_CONFIG_DIR) {
    throw 'This offline trial requires CCOF_LIVE_TESTS=0 and an isolated AZURE_CONFIG_DIR.'
}

$root = Split-Path $PSScriptRoot -Parent
$driverPath = Join-Path $root 'infra\staged\Invoke-StagedDeployment.ps1'
$parserTest = Join-Path $root 'tests\Test-StagedStages.ps1'
$script:passed = 0
$script:failed = 0
function Check([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:passed++; Write-Host "PASS $Name" }
    else { $script:failed++; Write-Host "FAIL $Name" }
}

$parts = @('Staged.Common.ps1', 'Staged.WhatIf.ps1', 'Staged.Resources.ps1', 'Staged.Entra.ps1', 'Staged.SettingsGuard.ps1', 'Staged.Application.ps1')
foreach ($file in @($driverPath, $parserTest)) {
    $text = Get-Content -LiteralPath $file -Raw
    $positions = @($parts | ForEach-Object { $text.IndexOf("'$_'", [StringComparison]::Ordinal) })
    $ordered = -not @($positions | Where-Object { $_ -lt 0 }).Count
    if ($ordered) {
        for ($i = 1; $i -lt $positions.Count; $i++) {
            if ($positions[$i] -le $positions[$i - 1]) { $ordered = $false }
        }
    }
    Check "$(Split-Path $file -Leaf) includes both helpers in order" $ordered
}
foreach ($part in $parts) {
    $path = Join-Path $root "infra\staged\$part"
    $valid = Test-Path -LiteralPath $path
    if ($valid) {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $valid = -not $errors.Count
    }
    Check "$part exists and parses" $valid
}

function Is-Ignored([string]$Path) {
    & git --no-optional-locks -C $root check-ignore -q -- $Path
    if ($LASTEXITCODE -gt 1) { throw "git check-ignore failed for $Path" }
    return ($LASTEXITCODE -eq 0)
}
$ignored = [ordered]@{
    'root evidence' = 'evidence\stage5.what-if.json'
    'staged state' = 'deploy\fixture\.staged-state\state.json'
    'DR state' = 'deploy\fixture\.dr-state\state.json'
    'DR evidence' = 'deploy\fixture\.dr-evidence\what-if.json'
    'health alerts A' = 'deploy\fixture\.health-alerts-a\state.json'
    'health alerts B' = 'deploy\fixture\.health-alerts-b\state.json'
    'restored CI/CD state' = 'deploy\fixture\.cicd-state-restored'
}
foreach ($entry in $ignored.GetEnumerator()) { Check "$($entry.Key) is ignored" (Is-Ignored $entry.Value) }
foreach ($path in @('deploy\fixture\staged.config.json', 'deploy\fixture\dr.config.json', 'other\evidence\keep.json')) {
    Check "$path remains visible" (-not (Is-Ignored $path))
}

. $driverPath -DotSourceOnly
Check 'driver loads the WhatIf classifier and writer' (
    [bool](Get-Command Get-StgModifyVerdicts -ErrorAction SilentlyContinue) -and
    [bool](Get-Command Write-StgWhatIfResult -ErrorAction SilentlyContinue)
)
Check 'driver loads the Stage 5 settings guard' ([bool](Get-Command Assert-StgStage5SettingsKept -ErrorAction SilentlyContinue))

$script:StateDir = Join-Path $root ".env.trial-scratch\seam-$([guid]::NewGuid().ToString('N'))"
$generated = Join-Path $script:StateDir 'generated'
$gateway = Join-Path $generated 'gateway'
New-Item -ItemType Directory -Force -Path $gateway | Out-Null
'<policies />' | Set-Content -LiteralPath (Join-Path $gateway 'fixture.policy.xml')
$workbookPath = Join-Path $generated 'workbook.parameters.json'
'{"parameters":{"workbookContent":{"value":{}},"contentTags":{"value":{}}}}' |
    Set-Content -LiteralPath $workbookPath
$script:stage1 = @{
    cosmosEndpoint = 'https://fixture.invalid'; clientIds = @{ sync = 'sync'; reconciler = 'reconciler' }
    names = @{ apps = [ordered]@{ admin = @{ functionApp = 'fixture-admin' } } }
}
$script:stage4 = @{
    admin = @{ appId = '11111111-1111-1111-1111-111111111111' }
    registrations = @{ developerSignIn = @{ appId = 'developer' }; resolverApi = @{ appId = 'resolver' } }
    groups = @{}
}
$script:context = @{
    P = @{ names = $script:stage1.names; groups = @() }; GeneratedDir = $generated
    State = @{ completed = @{ '1' = @{ outputs = @{} } } }
    Apim = @{ id = 'fixture-apim'; principalId = 'fixture-principal' }; GatewayUrl = 'https://fixture.invalid'
}
$cfg = @{
    subscriptionId = 'fixture-subscription'; tenantId = 'fixture-tenant'; resourceGroup = 'fixture-group'
    location = 'fixture'; stage1 = @{ includeAdmin = $true }; admin = @{}
    apim = @{ apiId = 'fixture' }; gateway = @{ projectHeaderName = 'x-ccof-project' }
    resolver = @{}; sync = @{}; reconciler = @{}; budgetState = @{}; workbook = @{}
    backends = @(); syncTimerEnabled = $false
}
$script:liveSettings = @{ ADMIN_V3_ENABLED = 'true'; EXTRA_TEST_SETTING = 'synthetic-private-value-654' }
$script:requests = [Collections.Generic.List[string]]::new()
$script:whatIfFails = $false
function az { throw 'Unexpected Azure CLI invocation in offline test.' }
function npx { $global:LASTEXITCODE = 0 }
function node { $global:LASTEXITCODE = 0 }
function Get-StgStage { param($Cfg, $Number) switch ($Number) { 1 { return $script:stage1 } 4 { return $script:stage4 } 3 { return @{} } default { throw "Unexpected stage $Number" } } }
function Read-StgState { param($Cfg) return @{ stages = @{ '5' = @{ outputs = @{ verify = @{ settings = @{ admin = @('ADMIN_V3_ENABLED') } } } } } } }
function New-StgQsContext { param($Cfg) return $script:context }
function Get-StgManagedIdentityClientId { param($ResourceId, $PrincipalId) return 'fixture-client' }
function New-QsGatewayConfig { param($P, $Checks) return @{ entra = @{} } }
function New-QsWorkbookAnswers { param($P, $ApimId, $Directory) return 'fixture-answers' }
function Get-StgWorkbookGroups { param($P, $Stage4) return @() }
function Invoke-QsWorkbookBuild { param($AnswersPath, $GroupsPath, $Directory) return @{ parametersPath = $workbookPath } }
function Get-StgApim { param($Cfg) return @{} }
function Invoke-StgExistingApimDiagnostics { param($Cfg, $Stage1, $Apply) }
function Invoke-StgAzJson {
    param([string[]]$Arguments)
    if (($Arguments[0..3] -join ' ') -cne 'functionapp config appsettings list' -or $Arguments[-1] -cne 'fixture-admin') {
        throw 'Unexpected settings read in offline test.'
    }
    return $script:liveSettings.Clone()
}
function Invoke-StgReadBack {
    param([string]$Kind, [string]$Target)
    if ($Kind -cne 'appsettings' -or $Target -cnotmatch '/config/appsettings$') { throw 'Unexpected WhatIf read-back.' }
    return $script:liveSettings.Clone()
}
function Invoke-QsAz {
    param([string[]]$Arguments)
    $request = $Arguments[0..2] -join ' '
    $script:requests.Add($request)
    if ($request -cne 'deployment group what-if') { throw "Unexpected Azure operation in offline test: $request" }
    if ($script:whatIfFails) { throw 'synthetic_whatif_failed' }
    return @{ changes = @(@{
        resourceId = '/subscriptions/s/resourceGroups/g/providers/Microsoft.Web/sites/fixture-admin/config/appsettings'
        changeType = 'Modify'
        delta = @(@{ path = 'properties'; propertyChangeType = 'Create'; before = $null; after = @{ ADMIN_V3_ENABLED = 'true' } })
    }) }
}
function Set-ResultPath([string]$Name) {
    $env:CCOF_WHATIF_RESULTS = Join-Path $script:StateDir "$Name.jsonl"
}
function Read-Result {
    if (-not (Test-Path -LiteralPath $env:CCOF_WHATIF_RESULTS)) { return $null }
    $lines = @(Get-Content -LiteralPath $env:CCOF_WHATIF_RESULTS | Where-Object { $_ })
    if ($lines.Count -ne 1) { return $null }
    return ($lines[0] | ConvertFrom-Json -AsHashtable)
}
function Has-Verdict($Record, [string]$Verdict) {
    if (-not $Record -or $Record.source -cne 'stage5-config' -or @($Record.changes).Count -ne 1) { return $false }
    return [bool]@($Record.changes[0].properties | Where-Object { $_.path -ceq 'properties' -and $_.rule -ceq 'appsettings-read-back' -and $_.verdict -ceq $Verdict }).Count
}

try {
    Set-ResultPath 'drift'
    $preview = @(Invoke-Stage5 $cfg 3>&1 6>&1)
    $previewText = $preview | Out-String
    $result = Read-Result
    Check 'preview warns about a dropped setting' ($previewText -match 'would remove EXTRA_TEST_SETTING')
    Check 'preview classifies the same extra setting as drift' (Has-Verdict $result 'drift')
    $guardEvidence = Get-Content -LiteralPath (Join-Path $script:StateDir 'evidence\stage5.settings-guard.json') -Raw
    $resultText = if (Test-Path -LiteralPath $env:CCOF_WHATIF_RESULTS) { Get-Content -LiteralPath $env:CCOF_WHATIF_RESULTS -Raw } else { '' }
    Check 'warning and structured evidence do not disclose the setting value' (($previewText + $guardEvidence + $resultText) -cnotmatch 'synthetic-private-value-654')

    Set-ResultPath 'blocked-apply'
    $before = $script:requests.Count
    $errorText = ''
    try { $null = @(Invoke-Stage5 $cfg -Apply 3>&1 6>&1) } catch { $errorText = $_.Exception.Message }
    Check 'unsafe apply is refused by the settings guard' ($errorText -match '^stage5_settings_would_drop:')
    Check 'refused apply makes no deployment request or WhatIf record' ($script:requests.Count -eq $before -and -not (Test-Path -LiteralPath $env:CCOF_WHATIF_RESULTS))

    $script:liveSettings.EXTRA_TEST_SETTING = ''
    Set-ResultPath 'unmeasured'
    $null = @(Invoke-Stage5 $cfg 3>&1 6>&1)
    Check 'omitted empty live setting is unmeasured, not clean' (Has-Verdict (Read-Result) 'unmeasured')

    $script:liveSettings.Remove('EXTRA_TEST_SETTING')
    Set-ResultPath 'matched'
    $cleanPreview = @(Invoke-Stage5 $cfg 3>&1 6>&1) | Out-String
    Check 'matching settings preview has no drop warning' ($cleanPreview -notmatch 'would remove')
    Check 'matching settings have a matched WhatIf verdict' (Has-Verdict (Read-Result) 'matched')

    $script:whatIfFails = $true
    Set-ResultPath 'failed-whatif'
    $errorText = ''
    try { $null = @(Invoke-Stage5 $cfg 3>&1 6>&1) } catch { $errorText = $_.Exception.Message }
    Check 'WhatIf failure propagates without a success record' ($errorText -match '^synthetic_whatif_failed' -and -not (Test-Path -LiteralPath $env:CCOF_WHATIF_RESULTS))
}
finally {
    Remove-Item -LiteralPath $script:StateDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Test-FoundryProductionTrial: $script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
