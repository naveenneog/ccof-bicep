#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeDesktopGateway.ps1')
$appId = '33333333-3333-4333-8333-333333333333'
$config = @{
    tenantId = '11111111-1111-4111-8111-111111111111'
    clientId = $appId
    scope = "api://$appId/access_as_user"
    gatewayUrl = 'https://gateway.example.test/anthropic'
    models = @{ default = 'test-sonnet'; available = @('test-sonnet') }
}
$schema = @{
    credentialKinds = @('external-idp')
    keys = @('inferenceProvider', 'inferenceGatewayBaseUrl', 'inferenceGatewayAuthScheme',
        'inferenceModels', 'inferenceCredentialKind', 'inferenceIdpAuthFlow', 'inferenceIdpOidc')
}
$profile = New-CcofDesktopProfile $config $schema 'unused-helper'
if ($profile.inferenceIdpOidc.scopes -cne "$appId/access_as_user") { throw 'FAIL: Desktop token-to-self must use GUID resource (AADSTS90009)' }
Write-Host 'PASS: combined Desktop native sign-in uses GUID resource'
if ($config.scope -cne "api://$appId/access_as_user") { throw 'FAIL: original profile config was mutated' }
Write-Host 'PASS: configured scope remains intact'
$config.clientId = '44444444-4444-4444-8444-444444444444'
$profile = New-CcofDesktopProfile $config $schema 'unused-helper'
if ($profile.inferenceIdpOidc.scopes -cne $config.scope) { throw 'FAIL: separate Desktop client/API scope changed' }
Write-Host 'PASS: legacy Desktop sign-in keeps the identifier URI resource'
