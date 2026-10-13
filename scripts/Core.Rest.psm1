#Requires -Version 7.0
<#
.SYNOPSIS
    REST calls for the WP-CORE stages: Azure Resource Manager and Microsoft Graph with a token from
    the Azure CLI for an explicit subscription (never az login or az account set). Returns Status,
    Content and the provider's error code, without throwing on an HTTP error, so a stage can decide.
    Tokens and bodies are never written to output or logs.
#>

$script:Hosts = @('management.azure.com', 'graph.microsoft.com')
$script:Tokens = @{}

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Azure.psm1')

function Get-CoreAccessToken {
    param([Parameter(Mandatory)] [string]$SubscriptionId, [Parameter(Mandatory)] [string]$Resource)
    $arguments = @('account', 'get-access-token', '--subscription', $SubscriptionId, '--resource', $Resource)
    # az.cmd passes every argument through cmd.exe on Windows; the guard also requires a GUID subscription.
    Assert-OnboardingAzArguments $arguments
    $key = "$SubscriptionId|$Resource"
    $cached = $script:Tokens[$key]
    if ($cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { return $cached.Token }
    $raw = az @arguments --only-show-errors -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'The Azure CLI returned no access token for the subscription. Sign in with an AZURE_CONFIG_DIR for the target tenant.' }
    $token = $raw | ConvertFrom-Json
    $expires = if ($token.expires_on) { [DateTimeOffset]::FromUnixTimeSeconds([long]$token.expires_on) } else { [DateTimeOffset]::UtcNow.AddMinutes(30) }
    $script:Tokens[$key] = @{ Token = $token.accessToken; ExpiresOn = $expires }
    return $token.accessToken
}

function Invoke-CoreRest {
    <#
    .SYNOPSIS
        One HTTPS call to ARM or Graph. Returns Status (int), Content (parsed JSON or $null) and
        ErrorCode (the provider's error.code, when there is one).
    #>
    param(
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [ValidateSet('GET', 'PUT', 'POST', 'PATCH')] [string]$Method,
        [Parameter(Mandatory)] [string]$Url,
        $Body
    )
    $uri = [uri]$Url
    if ($uri.Scheme -ne 'https' -or $script:Hosts -notcontains $uri.Host -or $uri.UserInfo -or $uri.Fragment) { throw 'Only HTTPS calls to management.azure.com and graph.microsoft.com are allowed.' }
    $resource = if ($uri.Host -eq 'graph.microsoft.com') { 'https://graph.microsoft.com/' } else { 'https://management.azure.com/' }
    $token = Get-CoreAccessToken -SubscriptionId $SubscriptionId -Resource $resource
    $request = @{ Uri = $Url; Method = $Method; Headers = @{ Authorization = "Bearer $token" }; SkipHttpErrorCheck = $true; MaximumRedirection = 0; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $request.Body = ($Body | ConvertTo-Json -Depth 30 -Compress); $request.ContentType = 'application/json' }
    try { $response = Invoke-WebRequest @request }
    catch { return [pscustomobject]@{ Status = 0; Content = $null; ErrorCode = 'transport_failed' } }
    $content = $null
    if ($response.Content) { try { $content = ConvertFrom-CoreJson ([string]$response.Content) } catch { $content = $null } }
    $errorCode = if ($content -is [System.Collections.IDictionary] -and $content.Contains('error')) { [string]$content.error.code } else { $null }
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Content = $content; ErrorCode = $errorCode }
}

Export-ModuleMember -Function Invoke-CoreRest, Get-CoreAccessToken
