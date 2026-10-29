#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'infra\staged\Invoke-StagedDeployment.ps1') -DotSourceOnly
$scratch = Join-Path $root ".env.stage5-admin-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
$script:Repo = $root
$script:captured = $null
$script:diagnosticsCalls = 0
$script:fakeContext = @{
    P = @{ names = @{} }; GeneratedDir = $scratch
    State = @{ completed = @{ '1' = @{ outputs = @{} } } }
    Apim = @{ id = '/fixture'; principalId = 'fixture' }; GatewayUrl = 'https://example.invalid/anthropic'
}
$script:fakeEntra = @{
    admin = @{ appId = '00000000-0000-4000-8000-000000000001' }
    registrations = @{ developerSignIn = @{ appId = '00000000-0000-4000-8000-000000000002' }; resolverApi = @{ appId = '00000000-0000-4000-8000-000000000003' } }
}
function Get-StgStage { param($Cfg, $Stage) if ($Stage -eq 4) { return $script:fakeEntra }; return @{ clientIds = @{} } }
function New-StgQsContext { param($Cfg) return $script:fakeContext }
function Get-StgManagedIdentityClientId { return '00000000-0000-4000-8000-000000000004' }
function npx { $global:LASTEXITCODE = 0 }
function node { $global:LASTEXITCODE = 0 }
function New-QsGatewayConfig { return @{ entra = @{} } }
function New-QsWorkbookAnswers { return 'fixture-answers' }
function Get-QsWorkbookGroups { return @() }
function Invoke-QsWorkbookBuild { return @{ parametersPath = (Join-Path $script:fakeContext.GeneratedDir 'workbook.parameters.json') } }
function Get-StgApim { return @{} }
function Invoke-StgExistingApimDiagnostics { $script:diagnosticsCalls++; return $null }
function Invoke-StgBicep { param($Cfg, $Template, $Name, $Apply, $Parameters) $script:captured = $Parameters; return $null }
$gateway = '/subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/fixture/providers/Microsoft.ApiManagement/service/fixture-apim'
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'gateway') | Out-Null
    '<policies />' | Set-Content (Join-Path $scratch 'gateway\fixture.policy.xml')
    '{"parameters":{"workbookContent":{"value":{}},"contentTags":{"value":{}}}}' | Set-Content (Join-Path $scratch 'workbook.parameters.json')
    $cfg = @{ stage1 = @{ includeAdmin = $true }; admin = @{ extraAllowedClientIds = @() }; apim = @{ apiId = 'fixture' }; gateway = @{} }
    $null = Invoke-Stage5 -Cfg $cfg
    $admin = ($script:captured | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100).admin
    if ($admin.ContainsKey('gatewayResourceIds')) { throw 'stage5_admin_null: omitted gatewayResourceIds must not generate an ARM array containing null.' }
    if ($admin.uiClientId -cne $script:fakeEntra.admin.appId -or $admin.readerIds.Count -ne 0 -or $admin.editorIds.Count -ne 0 -or $admin.extraAllowedClientIds.Count -ne 0) {
        throw 'Other admin ID parameters changed.'
    }
    foreach ($empty in @(@{ value = @() }, @{ value = $null }, @{ value = @($null) }, @{ value = @('', '  ', $null) })) {
        $cfg.admin.gatewayResourceIds = $empty.value
        $null = Invoke-Stage5 -Cfg $cfg
        if ($script:captured.admin.ContainsKey('gatewayResourceIds')) { throw 'Empty/null optional list must remain omitted.' }
    }
    $cfg.admin.gatewayResourceIds = @($gateway, "$gateway-dr")
    $null = Invoke-Stage5 -Cfg $cfg
    if (($script:captured.admin.gatewayResourceIds -join ',') -cne "$gateway,$gateway-dr") { throw 'Valid gateway IDs changed.' }
    $cfg.admin.gatewayResourceIds = @($null, $gateway, ' ', "$gateway-dr")
    $null = Invoke-Stage5 -Cfg $cfg
    if (($script:captured.admin.gatewayResourceIds -join ',') -cne "$gateway,$gateway-dr") { throw 'Sanitizing optional entries must preserve valid IDs and their order.' }
    foreach ($bad in @(@{ value = @('not-an-id') }, @{ value = @($gateway, 'invalid') }, @{ value = @($gateway.Replace('00000000-0000-4000-8000-000000000010', ('a' * 36))) })) {
        $cfg.admin.gatewayResourceIds = $bad.value
        $script:captured = $null; $script:diagnosticsCalls = 0
        $errorText = $null
        try { $null = Invoke-Stage5 -Cfg $cfg } catch { $errorText = "$_" }
        if ($errorText -notmatch 'admin\.gatewayResourceIds' -or $null -ne $script:captured -or $script:diagnosticsCalls -ne 0) {
            throw "Malformed gateway IDs must fail before diagnostics/deployment: $errorText"
        }
    }
    $cfg.admin.gatewayResourceIds = @()
    $script:fakeEntra.admin.appId = $null
    $script:diagnosticsCalls = 0; $script:captured = $null
    $errorText = $null
    try { $null = Invoke-Stage5 -Cfg $cfg } catch { $errorText = "$_" }
    if ($errorText -notmatch 'admin.*appId' -or $null -ne $script:captured -or $script:diagnosticsCalls -ne 0) {
        throw 'A missing required admin client ID must not be sanitized away.'
    }
    $cfg.stage1.includeAdmin = $false
    $null = Invoke-Stage5 -Cfg $cfg
    if ($script:captured.admin.enabled -or $script:captured.admin.ContainsKey('uiClientId')) { throw 'Disabled admin must not require or generate admin IDs.' }
    Write-Host 'PASS: actual Stage 5 parameters omit missing/empty gateway lists, preserve valid IDs, and reject malformed IDs before any write.'
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
