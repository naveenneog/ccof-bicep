#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'ClientGateway.Common.ps1')

function Assert-ClientGuid {
    param([string]$Value, [string]$Field)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Value, 'D', [ref]$parsed)) { throw "$Field must be an explicit GUID. No Graph write performed." }
}

function Invoke-CcofGraph {
    param([string]$Method, [string]$Uri, [string]$Body, [string]$TenantId, [string]$SubscriptionId)
    $raw = & az account get-access-token --resource-type ms-graph --subscription $SubscriptionId -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Administrator Graph token unavailable. Use the owner Azure CLI profile; developer sign-in does not need Azure CLI.' }
    try { $credential = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'Administrator Graph token response was invalid. No Graph request performed.' }
    if (-not [string]::Equals($credential.tenant, $TenantId, 'Ordinal') -or
        -not [string]::Equals($credential.subscription, $SubscriptionId, 'Ordinal') -or
        -not $credential.accessToken -or $credential.accessToken -match '\s') {
        throw 'Administrator token tenant or subscription does not match the explicit configuration. No Graph request performed.'
    }
    $token = $credential.accessToken
    try {
        $args = @{ Method = $Method; Uri = $Uri; Headers = @{ Authorization = "Bearer $token" }
            ContentType = 'application/json'; MaximumRedirection = 0; ErrorAction = 'Stop' }
        if ($Body) { $args.Body = $Body }
        $result = Invoke-RestMethod @args
        if ($null -ne $result) { return ($result | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable) }
    } catch { throw 'Graph request failed. No credentials or response body were logged. Check app ownership, tenant and administrator permissions.' }
    finally { $token = $null; $credential = $null; $raw = $null }
}

function New-CcofGraphInvoker {
    param([string]$TenantId, [string]$SubscriptionId)
    $invoke = ${function:Invoke-CcofGraph}
    return { param($Method, $Uri, $Body)
        & $invoke $Method $Uri $Body $TenantId $SubscriptionId
    }.GetNewClosure()
}

function Get-CcofPublicClient {
    param($Config, [scriptblock]$InvokeGraph)
    $uri = "https://graph.microsoft.com/v1.0/applications(appId='$($Config.clientId)')"
    $app = & $InvokeGraph 'GET' $uri $null
    if (-not $app -or -not [string]::Equals($app.appId, $Config.clientId, 'Ordinal')) { throw 'Graph returned a different application. No write performed.' }
    Assert-ClientGuid $app.id 'Application object id'
    if ($app.publicClient -isnot [Collections.IDictionary] -or $app.publicClient.redirectUris -isnot [array]) {
        throw 'Graph did not return the public-client redirect list. A failed or incomplete read is not an empty list.'
    }
    return $app
}

function Test-CcofRedirectsEqual {
    param([string[]]$Left, [string[]]$Right)
    if ($Left.Count -ne $Right.Count) { return $false }
    foreach ($item in $Left) { if ($Right -cnotcontains $item) { return $false } }
    return $true
}

function Set-CcofDeveloperRedirects {
    param([string]$ConfigPath, [string]$SubscriptionId, [string]$BackupRoot,
        [scriptblock]$InvokeGraph, [switch]$IncludeDesktopBrokerRedirect,
        [switch]$IncludeDesktopBrowserRedirect, [switch]$Confirmed)
    Assert-ClientConfirmation -Confirmed:$Confirmed
    Assert-ClientGuid $SubscriptionId 'SubscriptionId'
    $config = Read-ClientConfiguration $ConfigPath
    if (-not $InvokeGraph) { $InvokeGraph = New-CcofGraphInvoker $config.tenantId $SubscriptionId }
    $app = Get-CcofPublicClient $config $InvokeGraph
    $desired = @($app.publicClient.redirectUris)
    $additions = @("ms-appx-web://Microsoft.AAD.BrokerPlugin/$($config.clientId)")
    if ($IncludeDesktopBrokerRedirect) { $additions += 'msauth.com.anthropic.claudefordesktop://auth' }
    if ($IncludeDesktopBrowserRedirect) { $additions += 'http://127.0.0.1/callback' }
    foreach ($uri in $additions) { if ($desired -cnotcontains $uri) { $desired += $uri } }
    if (Test-CcofRedirectsEqual $app.publicClient.redirectUris $desired) {
        return (@{ event = 'unchanged'; component = 'developer-redirects'; clientId = $config.clientId } | ConvertTo-Json -Compress)
    }
    $id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
    $directory = Join-Path $BackupRoot $id
    $backup = @{ schemaVersion = 1; kind = 'developer-redirects'; changeId = $id
        tenantId = $config.tenantId; clientId = $config.clientId; objectId = $app.id; subscriptionId = $SubscriptionId
        before = @($app.publicClient.redirectUris); after = $desired }
    Write-ClientJson (Join-Path $directory 'redirects.json') $backup
    $body = @{ publicClient = @{ redirectUris = $desired } } | ConvertTo-Json -Depth 5 -Compress
    & $InvokeGraph 'PATCH' "https://graph.microsoft.com/v1.0/applications/$($app.id)" $body | Out-Null
    $verified = Get-CcofPublicClient $config $InvokeGraph
    if (-not (Test-CcofRedirectsEqual $verified.publicClient.redirectUris $desired)) { throw 'Graph redirect verification failed. Use the recorded backup to restore.' }
    return (@{ event = 'configured'; component = 'developer-redirects'; changeId = $id; clientId = $config.clientId } | ConvertTo-Json -Compress)
}

function Restore-CcofDeveloperRedirects {
    param([string]$ConfigPath, [string]$SubscriptionId, [string]$BackupPath,
        [scriptblock]$InvokeGraph, [switch]$Confirmed)
    Assert-ClientConfirmation -Confirmed:$Confirmed
    Assert-ClientGuid $SubscriptionId 'SubscriptionId'
    $config = Read-ClientConfiguration $ConfigPath
    $backup = Read-ClientJson (Join-Path $BackupPath 'redirects.json')
    if ($backup.schemaVersion -ne 1 -or $backup.kind -cne 'developer-redirects' -or
        -not [string]::Equals($backup.tenantId, $config.tenantId, 'Ordinal') -or
        -not [string]::Equals($backup.clientId, $config.clientId, 'Ordinal')) { throw 'Redirect backup belongs to a different tenant or application.' }
    if (-not $InvokeGraph) { $InvokeGraph = New-CcofGraphInvoker $config.tenantId $SubscriptionId }
    $app = Get-CcofPublicClient $config $InvokeGraph
    if (-not [string]::Equals($backup.objectId, $app.id, 'Ordinal')) { throw 'Application object changed. No restore performed.' }
    if (Test-CcofRedirectsEqual $app.publicClient.redirectUris $backup.before) {
        return (@{ event = 'unchanged'; component = 'developer-redirects'; changeId = $backup.changeId } | ConvertTo-Json -Compress)
    }
    if (-not (Test-CcofRedirectsEqual $app.publicClient.redirectUris $backup.after)) { throw 'Application redirects changed after setup. Review the differences instead of overwriting another administrator.' }
    $body = @{ publicClient = @{ redirectUris = @($backup.before) } } | ConvertTo-Json -Depth 5 -Compress
    & $InvokeGraph 'PATCH' "https://graph.microsoft.com/v1.0/applications/$($app.id)" $body | Out-Null
    $verified = Get-CcofPublicClient $config $InvokeGraph
    if (-not (Test-CcofRedirectsEqual $verified.publicClient.redirectUris $backup.before)) { throw 'Graph restore verification failed.' }
    return (@{ event = 'restored'; component = 'developer-redirects'; changeId = $backup.changeId } | ConvertTo-Json -Compress)
}
