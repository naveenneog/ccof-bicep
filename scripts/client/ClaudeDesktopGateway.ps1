#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'ClientGateway.Common.ps1')
. (Join-Path $PSScriptRoot 'ClientProjectHeaders.ps1')

function New-CcofDesktopProfile {
    param($Config, $Schema, [string]$HelperPath)
    $models = @($Config.models.default) + @($Config.models.available | Where-Object {
        -not [string]::Equals($_, $Config.models.default, 'Ordinal')
    })
    $profile = @{
        inferenceProvider = 'gateway'; inferenceGatewayBaseUrl = $Config.gatewayUrl
        inferenceGatewayAuthScheme = 'bearer'
        inferenceModels = @($models | ForEach-Object { @{ name = $_ } })
    }
    if ($Schema.credentialKinds -ccontains 'external-idp' -and
        $Schema.keys -ccontains 'inferenceIdpOidc' -and $Schema.keys -ccontains 'inferenceIdpAuthFlow') {
        $scope = [string]$Config.scope
        $selfPrefix = "api://$($Config.clientId)/"
        if ($scope.StartsWith($selfPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $scope = "$($Config.clientId)/$($scope.Substring($selfPrefix.Length))"
        }
        $profile.inferenceCredentialKind = 'external-idp'
        $profile.inferenceIdpAuthFlow = 'broker'
        $profile.inferenceIdpOidc = @{
            issuer = "https://login.microsoftonline.com/$($Config.tenantId)/v2.0"
            clientId = $Config.clientId; scopes = $scope; bearerTokenType = 'access_token'
        }
    } else {
        if ($Schema.credentialKinds -cnotcontains 'helper-script') { throw 'The installed Desktop schema does not support a compatible credential helper. No profile written.' }
        $profile.inferenceCredentialKind = 'helper-script'
        $profile.inferenceCredentialHelper = $HelperPath
        $profile.inferenceCredentialHelperArgs = @('token')
        $profile.inferenceCredentialHelperTtlSec = $Config.helperTtlSeconds
        $profile.inferenceCredentialHelperTimeoutSec = $Config.tokenTimeoutSeconds * 3
        $profile.inferenceCredentialHelperSilentRefreshEnabled = $true
        if ($profile.inferenceCredentialHelperTimeoutSec -gt 600) { throw 'Configuration tokenTimeoutSeconds exceeds the Desktop helper timeout support.' }
    }
    if ($Config.project) {
        $profile.inferenceCustomHeaders = Merge-CcofProjectHeaders -Sources @() -Project $Config.project
    }
    foreach ($key in $profile.Keys) {
        if ($Schema.keys -cnotcontains $key) { throw "The installed Desktop schema does not support required key $key. No profile written." }
    }
    return $profile
}

function Set-CcofClaudeDesktop {
    param([string]$ConfigPath, [string]$LibraryPath, [string]$BackupRoot, $Inventory, $Schema,
        [string]$NodePath, [string]$TokenEntryPath, [switch]$Confirmed)
    Assert-ClientConfirmation -Confirmed:$Confirmed
    if (-not $Inventory.DesktopVersion) { return (@{ event = 'not_installed'; component = 'claude-desktop' } | ConvertTo-Json -Compress) }
    $config = Read-ClientConfiguration $ConfigPath
    $id = $config.desktop.profileId
    $metaPath = Join-Path $LibraryPath '_meta.json'
    $profilePath = Join-Path $LibraryPath "$id.json"
    $helperPath = Join-Path (Split-Path $LibraryPath -Parent) 'ccof-token.cmd'
    $profile = New-CcofDesktopProfile $config $Schema $helperPath
    $existing = Read-ClientJson $profilePath
    if ($config.project) {
        $profile.inferenceCustomHeaders = Merge-CcofProjectHeaders -Sources @($existing.inferenceCustomHeaders) -Project $config.project
    }
    $owned = @($profile.Keys) + @('inferenceGatewayApiKey', 'inferenceGatewayOidc',
        'inferenceGatewayOidcAuthFlow', 'inferenceIdpOidc', 'inferenceIdpAuthFlow')
    foreach ($key in $existing.Keys) {
        if ($owned -ccontains $key -or $key -cmatch '^inference(CredentialHelper|Foundry|Bedrock|Vertex|Anthropic|Mantle)') { continue }
        if ($Schema.keys -cnotcontains $key) { throw 'The installed Desktop schema does not support an existing profile key. Review it in the application; nothing was overwritten.' }
        $profile[$key] = $existing[$key]
    }
    $shim = New-ClientTokenShim $ConfigPath $NodePath $TokenEntryPath
    $meta = Read-ClientJson $metaPath
    if ($meta.hybridPointer) { throw 'Desktop uses a hybrid bootstrap selection. Switch to a local configuration in Desktop before rerunning; nothing was changed.' }
    if ($meta.Contains('entries') -and $meta.entries -isnot [array]) { throw 'Desktop metadata entries must be an array; nothing was changed.' }
    $entries = @($meta.entries | Where-Object { $_ -and -not [string]::Equals($_.id, $id, 'Ordinal') })
    $meta.entries = $entries + @(@{ id = $id; name = $config.desktop.profileName })
    $meta.appliedId = $id
    $paths = @($metaPath, $profilePath)
    if ($profile.inferenceCredentialKind -ceq 'helper-script') { $paths += $helperPath }
    $snapshot = New-ClientSnapshot 'claude-desktop' $paths $BackupRoot
    if ($profile.inferenceCredentialKind -ceq 'helper-script') { Write-ClientText $helperPath $shim }
    Write-ClientJson $profilePath $profile
    Write-ClientJson $metaPath $meta
    Complete-ClientSnapshot $snapshot
    return (@{ event = 'configured'; component = 'claude-desktop'; changeId = $snapshot.Manifest.changeId
        credentialKind = $profile.inferenceCredentialKind } | ConvertTo-Json -Compress)
}
