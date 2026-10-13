#Requires -Version 7.0
<#
.SYNOPSIS
    ADR-0009: App Service Authentication on the resolver Function App, admitting only the given
    callers (APIM's managed identity) with tokens for the resolver's own app registration.

.DESCRIPTION
    New-ResolverAuthSettingsBody builds the Microsoft.Web/sites/config 'authsettingsV2' body
    (https://learn.microsoft.com/azure/templates/microsoft.web/sites/config-authsettingsv2):
    authentication required, 401 for unauthenticated requests, the tenant's v2 issuer, the resolver's
    audiences, and allow-lists of caller application ids (checked against appid/azp) and object ids
    (checked against oid). MS Learn, "Configure Microsoft Entra authentication": requests that fail
    these checks get 403. An empty allow-list means no restriction, so the builder refuses one.

    Invoke-ResolverAuthApply PUTs the body through a JSON file (az.cmd passes arguments through
    cmd.exe, which mangles inline JSON) and reads the settings back to verify them.

    The tail creates the resolver's app registration when -CreateRegistration is given (single
    tenant, api://<appId>, v2 access tokens, no secret, tag ccof-wp=res) and applies the settings.
    Previous settings and the rollback command are recorded in docs/status/WP-RES.md before a live run.

.PARAMETER DotSourceOnly
    Internal: set by tests/Test-ResolverAuth.ps1 to dot-source the functions without running the tail.

.EXAMPLE
    $apimOid = az apim show --name sample-pilot-apim --resource-group sample-pilot-rg --subscription <sub> --query identity.principalId -o tsv
    $apimAppId = az ad sp show --id $apimOid --query appId -o tsv
    ./infra/poc/resolver-auth.ps1 -TenantId <tenant> -SubscriptionId <sub> -ResourceGroup sample-pilot-rg `
        -FunctionAppName sample-pilot-resolver-func -ResolverAppId <appId> `
        -AllowedCallerAppIds $apimAppId -AllowedCallerObjectIds $apimOid
#>
param(
    [switch]$DotSourceOnly,
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$FunctionAppName,
    [string]$ResolverAppId,
    [string]$RegistrationDisplayName = 'ccof-resolver-api',
    [switch]$CreateRegistration,
    [string[]]$AllowedCallerAppIds,
    [string[]]$AllowedCallerObjectIds,
    [switch]$PlanOnly
)

# \z, not $: PowerShell's $ also matches before a final newline.
$script:GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z'
$script:AuthSettingsApiVersion = '2024-04-01'

function Assert-GuidList {
    param([string]$Name, [string[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) {
        throw "$Name is empty. An empty allow-list admits every caller in the tenant, so it is refused."
    }
    foreach ($value in $Values) {
        if ($value -notmatch $script:GuidPattern) { throw "$Name holds '$value', which is not a GUID." }
    }
}

function New-ResolverAuthSettingsBody {
    param(
        [Parameter(Mandatory)] [string]$TenantId,
        [Parameter(Mandatory)] [string]$ResolverAppId,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$AllowedCallerAppIds,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$AllowedCallerObjectIds
    )
    if ($TenantId -notmatch $script:GuidPattern) { throw "TenantId '$TenantId' is not a GUID." }
    if ($ResolverAppId -notmatch $script:GuidPattern) { throw "ResolverAppId '$ResolverAppId' is not a GUID." }
    Assert-GuidList -Name 'AllowedCallerAppIds' -Values $AllowedCallerAppIds
    Assert-GuidList -Name 'AllowedCallerObjectIds' -Values $AllowedCallerObjectIds
    # MS Learn: "There's a limit of 500 characters (total) across the list of identities."
    if (($AllowedCallerObjectIds -join '').Length -gt 500) {
        throw 'AllowedCallerObjectIds exceed the 500-character total that App Service allows.'
    }

    return [ordered]@{
        properties = [ordered]@{
            platform          = [ordered]@{ enabled = $true }
            globalValidation  = [ordered]@{
                requireAuthentication       = $true
                unauthenticatedClientAction = 'Return401'
            }
            httpSettings      = [ordered]@{ requireHttps = $true }
            identityProviders = [ordered]@{
                azureActiveDirectory = [ordered]@{
                    enabled      = $true
                    registration = [ordered]@{
                        openIdIssuer = "https://login.microsoftonline.com/$TenantId/v2.0"
                        clientId     = $ResolverAppId
                    }
                    validation   = [ordered]@{
                        allowedAudiences           = @("api://$ResolverAppId", $ResolverAppId)
                        defaultAuthorizationPolicy = [ordered]@{
                            allowedApplications = @($AllowedCallerAppIds)
                            allowedPrincipals   = [ordered]@{ identities = @($AllowedCallerObjectIds) }
                        }
                    }
                }
            }
            login             = [ordered]@{ tokenStore = [ordered]@{ enabled = $false } }
        }
    }
}

function Compare-ResolverAuthSettings {
    <# Returns the names of the security-relevant fields that differ between the intended and the returned settings. #>
    param([Parameter(Mandatory)] $Intended, [Parameter(Mandatory)] $Returned)
    # Ordinal throughout: PowerShell's -eq ignores case, and a value Azure changed only in case is
    # still a change to verify, not to wave through.
    $same = { param($a, $b) [string]::Equals([string]$a, [string]$b, [System.StringComparison]::Ordinal) }
    $sameSet = { param($a, $b) & $same ((@($a) | Sort-Object -CaseSensitive) -join ',') ((@($b) | Sort-Object -CaseSensitive) -join ',') }
    $i = $Intended.properties; $r = $Returned.properties
    $iAad = $i.identityProviders.azureActiveDirectory; $rAad = $r.identityProviders.azureActiveDirectory
    $checks = [ordered]@{
        'platform.enabled'             = & $same $i.platform.enabled $r.platform.enabled
        'requireAuthentication'        = & $same $i.globalValidation.requireAuthentication $r.globalValidation.requireAuthentication
        'unauthenticatedClientAction'  = & $same $i.globalValidation.unauthenticatedClientAction $r.globalValidation.unauthenticatedClientAction
        'excludedPaths'                = @($r.globalValidation.excludedPaths | Where-Object { $_ }).Count -eq 0
        'openIdIssuer'                 = & $same $iAad.registration.openIdIssuer $rAad.registration.openIdIssuer
        'clientId'                     = & $same $iAad.registration.clientId $rAad.registration.clientId
        'allowedAudiences'             = & $sameSet $iAad.validation.allowedAudiences $rAad.validation.allowedAudiences
        'allowedApplications'          = & $sameSet $iAad.validation.defaultAuthorizationPolicy.allowedApplications $rAad.validation.defaultAuthorizationPolicy.allowedApplications
        'allowedPrincipals.identities' = & $sameSet $iAad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities $rAad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities
        'tokenStore.enabled'           = & $same $i.login.tokenStore.enabled $r.login.tokenStore.enabled
    }
    return @($checks.Keys | Where-Object { -not $checks[$_] })
}

function Invoke-ResolverAuthApply {
    param(
        [Parameter(Mandatory)] [string]$SiteResourceId,
        [Parameter(Mandatory)] $Body,
        [scriptblock]$PutAuthSettings = {
            param($Url, $BodyJson)
            $bodyFile = Join-Path (Get-Location) "resolver-auth-body-$([guid]::NewGuid().ToString('N')).json"
            try {
                Set-Content -Path $bodyFile -Value $BodyJson -NoNewline -Encoding utf8NoBOM
                az rest --method put --url $Url --body "@$bodyFile" -o none
                if ($LASTEXITCODE -ne 0) { throw "az rest PUT authsettingsV2 failed ($LASTEXITCODE)" }
            }
            finally { Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue }
        },
        [scriptblock]$GetAuthSettings = {
            param($Url)
            az rest --method get --url $Url -o json | ConvertFrom-Json
        }
    )
    $url = "https://management.azure.com$SiteResourceId/config/authsettingsV2?api-version=$($script:AuthSettingsApiVersion)"
    & $PutAuthSettings $url ($Body | ConvertTo-Json -Depth 20)
    $returned = & $GetAuthSettings $url
    $mismatches = @(Compare-ResolverAuthSettings -Intended ($Body | ConvertTo-Json -Depth 20 | ConvertFrom-Json) -Returned $returned)
    return [PSCustomObject]@{ Verified = ($mismatches.Count -eq 0); Mismatches = $mismatches }
}

function Initialize-ResolverApiRegistration {
    <#
    .SYNOPSIS
        Creates the resolver's app registration and service principal once (Entra refuses tokens for
        an application without a service principal). Returns the app id. Needs Application
        Administrator, Cloud Application Administrator, or a tenant that lets users register apps.
        Deployment stage D1 (docs/PILOT.md C-9); the Entra operations are injectable for tests.
    #>
    param(
        [Parameter(Mandatory)] [string]$DisplayName,
        [scriptblock]$ListApps = {
            param($DisplayName)
            # az's --display-name filter matches by prefix; the exact match is made below.
            $apps = az ad app list --display-name $DisplayName -o json | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) { throw "Listing app registrations failed ($LASTEXITCODE)." }
            @($apps | ForEach-Object { [pscustomobject]@{ appId = $_.appId; displayName = $_.displayName } })
        },
        [scriptblock]$CreateApp = {
            param($DisplayName)
            $created = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId -o tsv
            if ($LASTEXITCODE -ne 0) { throw "Creating '$DisplayName' failed ($LASTEXITCODE)." }
            $created
        },
        [scriptblock]$GetAppObjectId = {
            param($AppId)
            $id = az ad app show --id $AppId --query id -o tsv
            if ($LASTEXITCODE -ne 0) { throw "Reading app $AppId failed ($LASTEXITCODE)." }
            $id
        },
        [scriptblock]$PatchApp = {
            param($ObjectId, $PatchJson)
            $patchFile = Join-Path (Get-Location) "resolver-app-patch-$([guid]::NewGuid().ToString('N')).json"
            try {
                Set-Content -Path $patchFile -Value $PatchJson -NoNewline -Encoding utf8NoBOM
                az rest --method patch --url "https://graph.microsoft.com/v1.0/applications/$ObjectId" --body "@$patchFile" -o none
                if ($LASTEXITCODE -ne 0) { throw "Updating app $ObjectId failed ($LASTEXITCODE)." }
            }
            finally { Remove-Item -Path $patchFile -ErrorAction SilentlyContinue }
        },
        [scriptblock]$GetServicePrincipalId = {
            param($AppId)
            # Absent is a normal answer here, so the exit code is not checked.
            az ad sp show --id $AppId --query id -o tsv 2>$null
        },
        [scriptblock]$CreateServicePrincipal = {
            param($AppId)
            az ad sp create --id $AppId -o none
            if ($LASTEXITCODE -ne 0) { throw "Creating the service principal for $AppId failed ($LASTEXITCODE)." }
        }
    )
    $existing = @(& $ListApps $DisplayName | Where-Object { [string]::Equals([string]$_.displayName, $DisplayName, [System.StringComparison]::Ordinal) })
    if ($existing.Count -gt 1) { throw "More than one app registration is named '$DisplayName'; pass -ResolverAppId." }
    $appId = if ($existing.Count -eq 1) { [string]$existing[0].appId } else { [string](& $CreateApp $DisplayName) }
    if ($appId -notmatch $script:GuidPattern) { throw "Creating '$DisplayName' did not return an app id." }
    $objectId = & $GetAppObjectId $appId
    $patch = [ordered]@{
        identifierUris = @("api://$appId")
        api            = [ordered]@{ requestedAccessTokenVersion = 2 }
        tags           = @('ccof-wp=res')
    } | ConvertTo-Json -Depth 5
    & $PatchApp $objectId $patch
    if (-not (& $GetServicePrincipalId $appId)) {
        & $CreateServicePrincipal $appId
        # Verified by reading it back, not by the create call's exit code alone.
        if (-not (& $GetServicePrincipalId $appId)) { throw "The service principal for $appId was not found after creating it." }
    }
    return $appId
}

if (-not $DotSourceOnly) {
    $ErrorActionPreference = 'Stop'
    if ($PlanOnly -and $CreateRegistration) {
        # Creating the registration is a write; a plan must not make one.
        Write-Error '-PlanOnly writes nothing, so it cannot create the registration: pass -ResolverAppId instead of -CreateRegistration.' -ErrorAction Continue
        exit 1
    }
    if ($CreateRegistration) { $ResolverAppId = Initialize-ResolverApiRegistration -DisplayName $RegistrationDisplayName }
    $body = New-ResolverAuthSettingsBody -TenantId $TenantId -ResolverAppId $ResolverAppId `
        -AllowedCallerAppIds $AllowedCallerAppIds -AllowedCallerObjectIds $AllowedCallerObjectIds
    if ($PlanOnly) {
        $body | ConvertTo-Json -Depth 20
        exit 0
    }
    $siteId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$FunctionAppName"
    $result = Invoke-ResolverAuthApply -SiteResourceId $siteId -Body $body
    if (-not $result.Verified) {
        Write-Error "authsettingsV2 read back differs in: $($result.Mismatches -join ', ')"
        exit 1
    }
    Write-Output "App Service Authentication on '$FunctionAppName' admits only: apps [$($AllowedCallerAppIds -join ', ')], principals [$($AllowedCallerObjectIds -join ', ')]; audience api://$ResolverAppId."
    exit 0
}
