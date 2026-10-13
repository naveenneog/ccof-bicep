#Requires -Version 7.0
param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$BackupRoot,
    [Parameter(Mandatory)][string]$SubscriptionId)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$global:CcofChildGraph = @{ azCalls = 0; restCalls = 0; tenant = $config.tenantId; subscription = $SubscriptionId
    app = @{ id = '66666666-6666-4666-8666-666666666666'; appId = $config.clientId
        publicClient = @{ redirectUris = @('http://localhost') } } }
function global:az {
    $global:CcofChildGraph.azCalls++
    if ($args -ccontains '--tenant' -or $args -cnotcontains '--subscription' -or $args -cnotcontains 'ms-graph') {
        $global:LASTEXITCODE = 1; return ''
    }
    $global:LASTEXITCODE = 0
    return (@{ accessToken = 'synthetic-child-admin'; tenant = $global:CcofChildGraph.tenant
        subscription = $global:CcofChildGraph.subscription } | ConvertTo-Json -Compress)
}
function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $Body, $ContentType, $MaximumRedirection, $ErrorAction)
    $global:CcofChildGraph.restCalls++
    if ($Headers.Authorization -cne 'Bearer synthetic-child-admin') { throw 'Unexpected fixture credential' }
    if ($Method -ceq 'PATCH') { $global:CcofChildGraph.app.publicClient = ($Body | ConvertFrom-Json -AsHashtable).publicClient; return }
    return $global:CcofChildGraph.app
}
try {
    $entry = Join-Path (Split-Path $PSScriptRoot -Parent) 'Set-DeveloperSignInRedirects.ps1'
    $result = & $entry -ConfigPath $ConfigPath -SubscriptionId $SubscriptionId -BackupRoot $BackupRoot -Confirmed
    if ($global:CcofChildGraph.azCalls -ne 3 -or $global:CcofChildGraph.restCalls -ne 3) { throw 'Default adapter was not exercised' }
    @{ ok = $true; calls = $global:CcofChildGraph.restCalls } | ConvertTo-Json -Compress
} catch {
    '{"ok":false,"reason":"default_entrypoint_failed"}'
    exit 1
}
