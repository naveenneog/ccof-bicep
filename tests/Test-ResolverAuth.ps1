#Requires -Version 7.0
<#
.SYNOPSIS
    Tests infra/poc/resolver-auth.ps1 (ADR-0009): the App Service Authentication settings that admit
    only APIM's managed identity to the resolver, and the apply-and-verify step.

.DESCRIPTION
    RED first. The settings body is security-critical: an empty allow-list would admit every
    application or principal in the tenant, so the builder refuses one. Azure calls are injected.
#>

$ErrorActionPreference = 'Continue'
$script:Pass = 0
$script:Fail = 0
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'infra/poc/resolver-auth.ps1'

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "PASS: $Name" -ForegroundColor Green
        $script:Pass++
    }
    else {
        Write-Host "FAIL: $Name $Detail" -ForegroundColor Red
        $script:Fail++
    }
}

function Assert-Throws {
    param([string]$Name, [scriptblock]$Action, [string]$MessagePattern)
    try {
        & $Action | Out-Null
        Assert-True $Name $false 'did not throw'
    }
    catch {
        Assert-True $Name ($_.Exception.Message -match $MessagePattern) "message: $($_.Exception.Message)"
    }
}

Assert-True 'resolver-auth.ps1 exists' (Test-Path $scriptPath)
if (-not (Test-Path $scriptPath)) {
    Write-Host "`n$script:Pass passed, $script:Fail failed"
    exit 1
}
. $scriptPath -DotSourceOnly

$tenant = '00000000-0000-4000-8000-000000000111'
$resolverApp = '00000000-0000-4000-8000-000001111000'
$apimApp = '00000000-0000-4000-8000-000001111001'
$apimObject = '00000000-0000-4000-8000-000001101111'

$body = New-ResolverAuthSettingsBody -TenantId $tenant -ResolverAppId $resolverApp `
    -AllowedCallerAppIds @($apimApp) -AllowedCallerObjectIds @($apimObject)
$p = $body.properties
$aad = $p.identityProviders.azureActiveDirectory

# A1: authentication is on and required, and an API answers 401, not a sign-in page.
Assert-True 'platform enabled' ($p.platform.enabled -eq $true)
Assert-True 'authentication required' ($p.globalValidation.requireAuthentication -eq $true)
Assert-True 'unauthenticated requests get 401' ($p.globalValidation.unauthenticatedClientAction -eq 'Return401')
Assert-True 'HTTPS required' ($p.httpSettings.requireHttps -eq $true)
Assert-True 'no token store' ($p.login.tokenStore.enabled -eq $false)
Assert-True 'no path is excluded from authentication' ($null -eq $p.globalValidation.excludedPaths)

# A2: the tenant's v2 issuer and the resolver app.
Assert-True 'Microsoft Entra provider enabled' ($aad.enabled -eq $true)
Assert-True 'issuer is the tenant v2 endpoint' ($aad.registration.openIdIssuer -eq "https://login.microsoftonline.com/$tenant/v2.0")
Assert-True 'client id is the resolver app' ($aad.registration.clientId -eq $resolverApp)
Assert-True 'no client secret setting' ($null -eq $aad.registration.clientSecretSettingName)

# A3: only the resolver's audience.
Assert-True 'audiences are exactly the resolver URI and id' ((@($aad.validation.allowedAudiences) -join ',') -eq "api://$resolverApp,$resolverApp")

# A4: only the given callers.
$policy = $aad.validation.defaultAuthorizationPolicy
Assert-True 'allowed applications are exactly the callers' ((@($policy.allowedApplications) -join ',') -eq $apimApp)
Assert-True 'allowed identities are exactly the callers' ((@($policy.allowedPrincipals.identities) -join ',') -eq $apimObject)

# A5: an empty allow-list would admit everyone, so it is refused.
Assert-Throws 'refuses an empty application allow-list' {
    New-ResolverAuthSettingsBody -TenantId $tenant -ResolverAppId $resolverApp -AllowedCallerAppIds @() -AllowedCallerObjectIds @($apimObject)
} 'AllowedCallerAppIds'
Assert-Throws 'refuses an empty identity allow-list' {
    New-ResolverAuthSettingsBody -TenantId $tenant -ResolverAppId $resolverApp -AllowedCallerAppIds @($apimApp) -AllowedCallerObjectIds @()
} 'AllowedCallerObjectIds'

# A6: every id must be a GUID.
Assert-Throws 'refuses a tenant that is not a GUID' {
    New-ResolverAuthSettingsBody -TenantId 'contoso' -ResolverAppId $resolverApp -AllowedCallerAppIds @($apimApp) -AllowedCallerObjectIds @($apimObject)
} 'TenantId'
Assert-Throws 'refuses a caller id that is not a GUID' {
    New-ResolverAuthSettingsBody -TenantId $tenant -ResolverAppId $resolverApp -AllowedCallerAppIds @('apim') -AllowedCallerObjectIds @($apimObject)
} 'AllowedCallerAppIds'

# A7: MS Learn limits the identities list to 500 characters in total.
$many = 1..14 | ForEach-Object { [guid]::NewGuid().ToString() }
Assert-Throws 'refuses identities longer than 500 characters in total' {
    New-ResolverAuthSettingsBody -TenantId $tenant -ResolverAppId $resolverApp -AllowedCallerAppIds @($apimApp) -AllowedCallerObjectIds $many
} '500'

# A8: apply PUTs exactly the body and verifies what Azure returns.
$script:putBody = $null
$fakePut = { param($Url, $BodyJson) $script:putBody = $BodyJson }
$fakeGetSame = { param($Url) $script:putBody | ConvertFrom-Json }
$siteId = '/subscriptions/00000000-0000-4000-8000-000000000110/resourceGroups/sample-pilot-rg/providers/Microsoft.Web/sites/sample-pilot-resolver-func'
$applied = Invoke-ResolverAuthApply -SiteResourceId $siteId -Body $body -PutAuthSettings $fakePut -GetAuthSettings $fakeGetSame
Assert-True 'apply reports success when Azure returns the same settings' $applied.Verified
Assert-True 'apply sends the body as JSON' (($script:putBody | ConvertFrom-Json).properties.identityProviders.azureActiveDirectory.registration.clientId -eq $resolverApp)

$fakeGetDrift = {
    param($Url)
    $returned = $script:putBody | ConvertFrom-Json
    $returned.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities = @()
    $returned
}
$drifted = Invoke-ResolverAuthApply -SiteResourceId $siteId -Body $body -PutAuthSettings $fakePut -GetAuthSettings $fakeGetDrift
Assert-True 'apply reports a mismatch when Azure returns different allowed identities' (-not $drifted.Verified)
Assert-True 'the mismatch names the field' ($drifted.Mismatches -contains 'allowedPrincipals.identities')

$fakeGetOff = {
    param($Url)
    $returned = $script:putBody | ConvertFrom-Json
    $returned.properties.globalValidation.requireAuthentication = $false
    $returned
}
$off = Invoke-ResolverAuthApply -SiteResourceId $siteId -Body $body -PutAuthSettings $fakePut -GetAuthSettings $fakeGetOff
Assert-True 'apply reports a mismatch when authentication is not required' (-not $off.Verified -and $off.Mismatches -contains 'requireAuthentication')

# A9: an id followed by a newline is not a GUID (PowerShell's $ also matches before a final newline).
Assert-Throws 'refuses a tenant id with a trailing newline' {
    New-ResolverAuthSettingsBody -TenantId "$tenant`n" -ResolverAppId $resolverApp -AllowedCallerAppIds @($apimApp) -AllowedCallerObjectIds @($apimObject)
} 'TenantId'
Assert-Throws 'refuses a caller id with a trailing newline' {
    New-ResolverAuthSettingsBody -TenantId $tenant -ResolverAppId $resolverApp -AllowedCallerAppIds @("$apimApp`n") -AllowedCallerObjectIds @($apimObject)
} 'AllowedCallerAppIds'

# A10: the read-back comparison is exact (ordinal), so a value Azure changed only in case is reported.
$fakeGetCase = {
    param($Url)
    $returned = $script:putBody | ConvertFrom-Json
    $returned.properties.identityProviders.azureActiveDirectory.validation.allowedAudiences = @("API://$resolverApp", $resolverApp)
    $returned.properties.identityProviders.azureActiveDirectory.registration.openIdIssuer = "https://login.microsoftonline.com/$($tenant.ToUpper())/v2.0"
    $returned
}
$cased = Invoke-ResolverAuthApply -SiteResourceId $siteId -Body $body -PutAuthSettings $fakePut -GetAuthSettings $fakeGetCase
Assert-True 'a case-only change of the audience is a mismatch' ($cased.Mismatches -contains 'allowedAudiences') "got: $($cased.Mismatches -join ', ')"
Assert-True 'a case-only change of the issuer is a mismatch' ($cased.Mismatches -contains 'openIdIssuer') "got: $($cased.Mismatches -join ', ')"

# A11: the registration is found by its exact display name; az's --display-name filter matches prefixes.
$script:created = @()
$script:spCreated = @()
$script:spIds = @{}
$ops = @{
    ListApps               = { param($DisplayName) @([pscustomobject]@{ appId = '99999999-9999-9999-9999-999999999999'; displayName = 'ccof-resolver-api-old' }) }
    CreateApp              = { param($DisplayName) $script:created += $DisplayName; '00000000-0000-4000-8000-000001111010' }
    GetAppObjectId         = { param($AppId) '00000000-0000-4000-8000-000001111011' }
    PatchApp               = { param($ObjectId, $PatchJson) }
    GetServicePrincipalId  = { param($AppId) $script:spIds[$AppId] }
    CreateServicePrincipal = { param($AppId) $script:spCreated += $AppId; $script:spIds[$AppId] = '00000000-0000-4000-8000-000001111100' }
}
$appId = Initialize-ResolverApiRegistration -DisplayName 'ccof-resolver-api' @ops
Assert-True 'a prefix match is not taken for the registration' ($script:created -contains 'ccof-resolver-api' -and $appId -eq '00000000-0000-4000-8000-000001111010')
Assert-True 'the service principal is created when missing' ($script:spCreated -contains $appId)

$script:created = @(); $script:spCreated = @()
$exact = $ops.Clone()
$exact.ListApps = { param($DisplayName) @([pscustomobject]@{ appId = '00000000-0000-4000-8000-000001111010'; displayName = 'ccof-resolver-api' }, [pscustomobject]@{ appId = '99999999-9999-9999-9999-999999999999'; displayName = 'CCOF-RESOLVER-API' }) }
$appId = Initialize-ResolverApiRegistration -DisplayName 'ccof-resolver-api' @exact
Assert-True 'an exact match is reused, not created again; a case variant is another name' ($script:created.Count -eq 0 -and $appId -eq '00000000-0000-4000-8000-000001111010')
Assert-True 'an existing service principal is not created again' ($script:spCreated.Count -eq 0)

$twice = $ops.Clone()
$twice.ListApps = { param($DisplayName) @([pscustomobject]@{ appId = '00000000-0000-4000-8000-000001111010'; displayName = 'ccof-resolver-api' }, [pscustomobject]@{ appId = '99999999-9999-9999-9999-999999999999'; displayName = 'ccof-resolver-api' }) }
Assert-Throws 'two registrations with the exact name are refused' { Initialize-ResolverApiRegistration -DisplayName 'ccof-resolver-api' @twice } 'More than one'

$noSp = $ops.Clone()
$noSp.GetServicePrincipalId = { param($AppId) $null }
$noSp.CreateServicePrincipal = { param($AppId) }
Assert-Throws 'a service principal that cannot be read back after creation is an error' { Initialize-ResolverApiRegistration -DisplayName 'ccof-resolver-api' @noSp } 'service principal'

# A12: -PlanOnly writes nothing, so it refuses -CreateRegistration before any call.
$planOut = & pwsh -NoProfile -File $scriptPath -PlanOnly -CreateRegistration -TenantId $tenant `
    -AllowedCallerAppIds $apimApp -AllowedCallerObjectIds $apimObject 2>&1 | Out-String
Assert-True '-PlanOnly with -CreateRegistration exits non-zero' ($LASTEXITCODE -ne 0)
Assert-True '-PlanOnly with -CreateRegistration names the conflict' ($planOut -match 'PlanOnly writes nothing') "output: $planOut"

Write-Host "`n$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
exit 0
