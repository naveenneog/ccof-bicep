#Requires -Version 7.0
# Pure checks shared by the staged and quick-start prerequisites. No Graph writes or consent.
function New-CoreAuthProblem {
    param([string]$Name, [string]$Code, [string]$Detail)
    [pscustomobject]@{ name = $Name; path = "identity.$Name"; code = $Code; detail = $Detail }
}

function Test-CoreAuthSeparation {
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Registrations)
    $resolver = [string]$Registrations.resolverApi.appId
    foreach ($name in @('gatewayApi', 'developerSignIn')) {
        $other = [string]$Registrations[$name].appId
        if ($resolver -and $other -and [string]::Equals($resolver, $other, [StringComparison]::OrdinalIgnoreCase)) {
            New-CoreAuthProblem 'resolverApi' 'resolver_app_shared' "resolverApi must be a separate audience from $name (ADR-0009 and ADR-0026)"
            return
        }
    }
}

function Get-CoreDeveloperScope {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Registrations,
        [Parameter(Mandatory)] [string]$GatewayIdentifierUri
    )
    $apiId = [string]$Registrations.gatewayApi.appId
    $clientId = [string]$Registrations.developerSignIn.appId
    $resource = $GatewayIdentifierUri
    if ([string]::Equals($apiId, $clientId, [StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::Equals($GatewayIdentifierUri, "api://$apiId", [StringComparison]::OrdinalIgnoreCase)) {
        $resource = $apiId
    }
    return "$resource/$($Registrations.gatewayApi.scope)"
}

function Test-CoreAuthRegistrations {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Registrations,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Applications
    )
    Test-CoreAuthSeparation -Registrations $Registrations
    $gateway = $Applications.gatewayApi
    if ($gateway) {
        $scope = @($gateway.api.oauth2PermissionScopes | Where-Object { $_.value -ceq $Registrations.gatewayApi.scope -and $_.isEnabled })
        if (-not $scope.Count) { New-CoreAuthProblem 'gatewayApi' 'scope_missing' 'Expose an API must publish the enabled answered delegated scope' }
        if (-not @($gateway.identifierUris | Where-Object { $_ }).Count) { New-CoreAuthProblem 'gatewayApi' 'identifier_uri_missing' 'an Application ID URI is required' }
        $version = if ($null -eq $gateway.api.requestedAccessTokenVersion) { 1 } else { [int]$gateway.api.requestedAccessTokenVersion }
        if ($version -ne [int]$Registrations.gatewayApi.accessTokenVersion) { New-CoreAuthProblem 'gatewayApi' 'token_version_mismatch' 'requestedAccessTokenVersion must match gatewayApi.accessTokenVersion' }
    }
    $developer = $Applications.developerSignIn
    if ($developer) {
        $missing = @($Registrations.developerSignIn.redirectUris | Where-Object { @($developer.publicClient.redirectUris) -cnotcontains $_ })
        if ($missing.Count) { New-CoreAuthProblem 'developerSignIn' 'redirect_uri_missing' 'public-client redirects must include every answered URI' }
    }
    $resolver = $Applications.resolverApi
    if ($resolver) {
        if (@($resolver.identifierUris) -cnotcontains "api://$($Registrations.resolverApi.appId)") { New-CoreAuthProblem 'resolverApi' 'identifier_uri_missing' 'Application ID URI must be api://<resolverAppId> (ADR-0009)' }
        if ($resolver.api.requestedAccessTokenVersion -ne 2) { New-CoreAuthProblem 'resolverApi' 'token_version_mismatch' 'requestedAccessTokenVersion must be 2 (ADR-0009)' }
        if (@($resolver.publicClient.redirectUris | Where-Object { $_ }).Count) { New-CoreAuthProblem 'resolverApi' 'resolver_public_client' 'resolver must have no public-client redirect URIs (ADR-0009)' }
        if (@($resolver.api.oauth2PermissionScopes | Where-Object { $_ }).Count) { New-CoreAuthProblem 'resolverApi' 'resolver_delegated_scope' 'resolver must expose no delegated scope (ADR-0009)' }
    }
}

Export-ModuleMember -Function Test-CoreAuthSeparation, Test-CoreAuthRegistrations, Get-CoreDeveloperScope
