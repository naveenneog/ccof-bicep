#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts\Core.Auth.psm1') -Force
$script:Passed = 0
function Assert([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:Passed++; Write-Host "PASS: $Name"
}
$gw = '33333333-3333-4333-8333-333333333333'
$dev = '44444444-4444-4444-8444-444444444444'
$res = '55555555-5555-4555-8555-555555555555'
$registrations = @{
    gatewayApi = @{ appId = $gw; scope = 'access_as_user'; accessTokenVersion = 2 }
    developerSignIn = @{ appId = $gw; redirectUris = @('http://localhost') }
    resolverApi = @{ appId = $res }
}
$combined = @{
    identifierUris = @("api://$gw")
    api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(@{ value = 'access_as_user'; isEnabled = $true }) }
    publicClient = @{ redirectUris = @('http://localhost') }
}
$resolver = @{ identifierUris = @("api://$res"); api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @() }; publicClient = @{ redirectUris = @() } }
function Check($Apps) { @(Test-CoreAuthRegistrations -Registrations $registrations -Applications $Apps) }
$apps = @{ gatewayApi = $combined; developerSignIn = $combined; resolverApi = $resolver }
Assert 'combined API/public client has no configuration problem' ((Check $apps).Count -eq 0)
Assert 'combined profile retains the default api:// identifier' ((Get-CoreDeveloperScope -Registrations $registrations -GatewayIdentifierUri "api://$gw") -ceq "api://$gw/access_as_user")
Assert 'combined custom identifier URI still requests the GUID self-resource' ((Get-CoreDeveloperScope -Registrations $registrations -GatewayIdentifierUri 'https://gateway.example.test/api') -ceq "$gw/access_as_user")
$combined.api.oauth2PermissionScopes[0].isEnabled = $false
Assert 'combined app must retain its enabled delegated scope' ((Check $apps).code -contains 'scope_missing')
$combined.api.oauth2PermissionScopes[0].isEnabled = $true
$combined.publicClient.redirectUris = @()
Assert 'combined app must retain public client redirects' ((Check $apps).code -contains 'redirect_uri_missing')
$combined.publicClient.redirectUris = @('http://localhost')
$combined.api.requestedAccessTokenVersion = 1
Assert 'gateway token version must match its answer' ((Check $apps).code -contains 'token_version_mismatch')
$combined.api.requestedAccessTokenVersion = 2
$combined.identifierUris = @()
Assert 'combined app must retain its API identifier URI' ((Check $apps).code -contains 'identifier_uri_missing')
$combined.identifierUris = @("api://$gw")
foreach ($id in @($gw, $dev.ToUpperInvariant())) {
    $registrations.developerSignIn.appId = $dev
    $registrations.resolverApi.appId = $id
    Assert 'resolver cannot share either gateway or developer application ID' (@(Test-CoreAuthSeparation -Registrations $registrations).code -contains 'resolver_app_shared')
}
$registrations.resolverApi.appId = $res
Assert 'legacy separate client/API registrations remain supported' ((Check $apps).Count -eq 0)
Assert 'legacy separate-client custom identifier URI is unchanged' ((Get-CoreDeveloperScope -Registrations $registrations -GatewayIdentifierUri 'https://gateway.example.test/api') -ceq 'https://gateway.example.test/api/access_as_user')
$resolver.publicClient.redirectUris = @('http://localhost')
Assert 'resolver cannot become a public client' ((Check $apps).code -contains 'resolver_public_client')
$resolver.publicClient.redirectUris = @()
$resolver.api.oauth2PermissionScopes = @(@{ value = 'access_as_user'; isEnabled = $true })
Assert 'resolver cannot expose a developer delegated scope' ((Check $apps).code -contains 'resolver_delegated_scope')
Import-Module (Join-Path $root 'scripts\Core.Schema.psm1') -Force
Import-Module (Join-Path $root 'scripts\Core.Answers.psm1') -Force
Import-Module (Join-Path $root 'scripts\Core.Prereqs.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Test-CoreFakes.psm1') -Force
$answers = ConvertFrom-CoreJson (Get-Content (Join-Path $root 'config\core.answers.example.json') -Raw)
Assert 'new example defaults to a combined developer/gateway app' ($answers.identity.gatewayApi.appId -eq $answers.identity.developerSignIn.appId)
foreach ($combinedMode in @($true, $false)) {
    if (-not $combinedMode) { $answers.identity.developerSignIn.appId = $dev }
    $ids = Get-CoreD1ExpectedIds -Answers $answers
    $envFake = New-CoreFakeEnvironment -Answers $answers -Ids $ids
    $calls = [System.Collections.Generic.List[string]]::new()
    $record = Get-CoreD1Record -Answers $answers -Get (New-CoreFakeGet -Environment $envFake -Calls $calls)
    Assert "D1 records both role settings (combined=$combinedMode)" ($record.Problems.Count -eq 0)
    $reg = $record.Outputs.registrations
    Assert "resolver audience remains separate (combined=$combinedMode)" ($reg.resolverApi.appId -ne $reg.gatewayApi.appId -and $reg.resolverApi.appId -ne $reg.developerSignIn.appId)
    if ($combinedMode) {
        Assert 'combined D1 role records refer to the same object and service principal' ($reg.gatewayApi.objectId -eq $reg.developerSignIn.objectId -and $reg.gatewayApi.servicePrincipalId -eq $reg.developerSignIn.servicePrincipalId)
        Assert 'combined registration is read only once for consistent settings' (@($calls | Where-Object { $_ -like "*applications(appId='$($reg.gatewayApi.appId)')*" }).Count -eq 1)
    }
}
$answers.identity.resolverApi.appId = $answers.identity.developerSignIn.appId
Assert 'answers refuse shared resolver before any cloud operation' (@(Test-CoreAnswerRules -Answers $answers).code -contains 'resolver_app_shared')
$authTemplate = Get-Content (Join-Path $root 'infra\quickstart\modules\app-settings.bicep') -Raw
Assert 'resolver authentication remains required with unauthenticated 401' ($authTemplate -match 'requireAuthentication:\s*true' -and $authTemplate -match "unauthenticatedClientAction:\s*'Return401'")
Assert 'resolver audiences are only the separate resolver identifier and app ID' ($authTemplate.Contains("allowedAudiences: ['api://`${resolverApiAppId}', resolverApiAppId]"))
Assert 'resolver application allowlist is only APIM managed identity' ($authTemplate -match 'allowedApplications:\s*\[apimIdentityAppId\]')
Assert 'resolver principal allowlist is only APIM managed identity object' ($authTemplate -match 'allowedPrincipals:\s*\{\s*identities:\s*\[apimPrincipalId\]')
Write-Host "$script:Passed passed"
