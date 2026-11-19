# Developer onboarding from a Windows VDI

This route configures Claude Code and its VS Code extension to use an Azure CLI
gateway token. It uses Windows PowerShell 5.1 and does not require Git, Node.js or
PowerShell 7. Claude Code, the VS Code extension and Azure CLI are installed through
the organization's approved software channels.

## 1. Before setup

The platform team supplies:

| Value | Meaning |
| --- | --- |
| Tenant ID | Microsoft Entra tenant GUID |
| Gateway scope | The delegated gateway API scope, for example `api://REPLACE-GATEWAY-APP-ID/access_as_user` |
| Gateway base URL | The approved user-facing HTTPS URL ending in `/anthropic`, without `/v1/messages` |
| Project ID | The project selector value |
| Project header name | The configured selector header, normally `x-ccof-project` |
| Default, Opus, Sonnet and Haiku model names | Actual deployments allowed for this project; an alias can point to another allowed deployment |

The account needs the approved project membership, a successful entitlement sync and
access to an allowed model. The Azure CLI client also needs to be preauthorized by
the gateway configuration. The project header selects a project; it does not grant
membership. The VDI needs the approved network path to the user-facing gateway.
References: [user onboarding](USER-ONBOARDING.md) and
[client configuration](../CLIENTS.md).

In Windows PowerShell, check that the Azure CLI is available:

```powershell
Get-Command az.cmd
```

If it is missing, the desktop administrator installs it. No token is printed by this
check. The sign-in follows the organization's Conditional Access policy.

## 2. Create the Azure CLI token helper

The following block opens the per-user helper in Notepad. An existing helper is copied
to a timestamped backup before it is opened.

```powershell
$dir = Join-Path $env:USERPROFILE '.claude'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$helper = Join-Path $dir 'az-gateway-token.cmd'
if (Test-Path -LiteralPath $helper -PathType Leaf) {
    $backup = "$helper.before-vdi-$(Get-Date -Format 'yyyyMMdd-HHmmssfff').bak"
    Copy-Item -LiteralPath $helper -Destination $backup -ErrorAction Stop
    Write-Host "Previous helper: $backup"
}
notepad.exe $helper
```

Replace the Notepad contents with the block below. Replace the tenant GUID and the
entire scope with the approved values. Save as `az-gateway-token.cmd`, using
**All files** and **ANSI** encoding. The extension is `.cmd`, not `.cmd.txt`.
This is the repository's [Azure CLI helper template](../examples/az-gateway-token-auto-login.cmd).

```cmd
@echo off
setlocal DisableDelayedExpansion
set "TENANT=REPLACE-tenant-guid"
set "SCOPE=api://REPLACE-gateway-app-client-guid/access_as_user"
set "AZURE_CORE_LOGIN_EXPERIENCE_V2=off"
if "%TENANT:~0,8%"=="REPLACE-" (
  >&2 echo Configure the customer TENANT and SCOPE in this file first.
  exit /b 1
)
if "%SCOPE:~0,14%"=="api://REPLACE-" (
  >&2 echo Configure the gateway SCOPE in this file first.
  exit /b 1
)
where az.cmd >nul 2>nul
if errorlevel 1 (
  >&2 echo Azure CLI az.cmd is not on PATH. Contact your desktop administrator.
  exit /b 1
)
call az.cmd account get-access-token --tenant "%TENANT%" --scope "%SCOPE%" --query accessToken --output tsv --only-show-errors 2>nul
if not errorlevel 1 exit /b 0
>&2 echo Gateway token unavailable. Starting Microsoft interactive sign-in.
call az.cmd login --tenant "%TENANT%" --scope "%SCOPE%" --allow-no-subscriptions --output none --only-show-errors <nul 1>&2
if errorlevel 1 exit /b 1
call az.cmd account get-access-token --tenant "%TENANT%" --scope "%SCOPE%" --query accessToken --output tsv --only-show-errors
exit /b %errorlevel%
```

The helper emits an access token to the invoking client. It is not a command to run
in a terminal without redirecting its output.

## 3. Configure Claude Code

In the block below, replace all seven values with those supplied by the platform team.
The block preserves other settings and custom headers, backs up an existing settings
file, and writes the gateway values to `%USERPROFILE%\.claude\settings.json`. A
conflicting existing API key, token or credential header causes it to stop rather
than overwrite it.
Backups can contain private settings and remain on the device.

```powershell
$gatewayBase = 'REPLACE-GATEWAY-BASE-URL'
$projectId = 'REPLACE-PROJECT-ID'
$projectHeader = 'REPLACE-PROJECT-HEADER'
$defaultModel = 'REPLACE-DEFAULT-MODEL'
$opusModel = 'REPLACE-OPUS-MODEL'
$sonnetModel = 'REPLACE-SONNET-MODEL'
$haikuModel = 'REPLACE-HAIKU-MODEL'

$valuesToCheck = @($gatewayBase, $projectId, $projectHeader, $defaultModel, $opusModel, $sonnetModel, $haikuModel)
foreach ($value in $valuesToCheck) {
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match 'REPLACE-' -or $value -match '[\r\n]') {
        throw 'Replace each placeholder with a single-line value from the platform team.'
    }
}
$gatewayUri = $null
if (-not [Uri]::TryCreate($gatewayBase, [UriKind]::Absolute, [ref]$gatewayUri) -or
    $gatewayUri.Scheme -cne 'https' -or $gatewayUri.UserInfo -or $gatewayUri.Query -or
    $gatewayUri.Fragment -or $gatewayUri.AbsolutePath.TrimEnd('/') -cne '/anthropic') {
    throw 'The gateway URL must be an HTTPS host followed by /anthropic.'
}
if ($projectId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') {
    throw 'The project ID has an invalid format.'
}
$credentialHeaders = @('authorization', 'proxy-authorization', 'x-api-key', 'api-key', 'cookie', 'set-cookie')
$reservedHeaders = $credentialHeaders + @('host', 'content-type', 'content-length', 'connection',
    'transfer-encoding', 'anthropic-version', 'anthropic-beta')
if ($projectHeader -notmatch '^[A-Za-z][A-Za-z0-9-]{0,63}$' -or $projectHeader.ToLowerInvariant() -in $reservedHeaders) {
    throw 'The project header name is invalid or reserved.'
}

$dir = Join-Path $env:USERPROFILE '.claude'
$helper = Join-Path $dir 'az-gateway-token.cmd'
$settingsPath = Join-Path $dir 'settings.json'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    throw 'The token helper is missing. Complete section 2 first.'
}
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($settings -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'Claude Code settings must be a JSON object; nothing was changed.'
    }
} else {
    $settings = New-Object PSObject
}
$envProperty = $settings.PSObject.Properties['env']
if ($envProperty -and $null -ne $envProperty.Value) {
    $clientEnv = $envProperty.Value
    if ($clientEnv -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'Claude Code settings.env must be a JSON object; nothing was changed.'
    }
} else {
    $clientEnv = New-Object PSObject
}
foreach ($name in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN')) {
    $existing = $clientEnv.PSObject.Properties[$name]
    if ([Environment]::GetEnvironmentVariable($name, 'Process') -or ($existing -and $existing.Value)) {
        throw "Existing $name needs review by the administrator; nothing was changed."
    }
}
$headerProperty = $clientEnv.PSObject.Properties['ANTHROPIC_CUSTOM_HEADERS']
$headers = @()
if ($headerProperty -and $null -ne $headerProperty.Value) {
    if ($headerProperty.Value -isnot [string]) {
        throw 'ANTHROPIC_CUSTOM_HEADERS must be a string; nothing was changed.'
    }
    foreach ($line in ($headerProperty.Value -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split ':', 2
        if ($parts.Count -ne 2 -or $parts[0].Trim() -notmatch '^[A-Za-z][A-Za-z0-9-]{0,63}$' -or
            $parts[1] -match '[\r\n\0]') {
            throw 'An existing custom header is malformed; nothing was changed.'
        }
        $name = $parts[0].Trim()
        if ($name.ToLowerInvariant() -in $credentialHeaders) {
            throw 'An existing custom credential header needs review; nothing was changed.'
        }
        if (-not [string]::Equals($name, $projectHeader, [StringComparison]::OrdinalIgnoreCase)) {
            $headers += $line
        }
    }
}
$headers += "${projectHeader}: $projectId"
$clientValues = [ordered]@{
    ANTHROPIC_BASE_URL = $gatewayBase.TrimEnd('/')
    ANTHROPIC_CUSTOM_HEADERS = ($headers -join "`n")
    ANTHROPIC_MODEL = $defaultModel
    ANTHROPIC_DEFAULT_OPUS_MODEL = $opusModel
    ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnetModel
    ANTHROPIC_DEFAULT_HAIKU_MODEL = $haikuModel
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    CLAUDE_CODE_API_KEY_HELPER_TTL_MS = '300000'
}
foreach ($name in $clientValues.Keys) {
    $clientEnv | Add-Member -NotePropertyName $name -NotePropertyValue $clientValues[$name] -Force
}
$settings | Add-Member -NotePropertyName env -NotePropertyValue $clientEnv -Force
$settings | Add-Member -NotePropertyName apiKeyHelper -NotePropertyValue ('"' + $helper + '"') -Force
$settings | Add-Member -NotePropertyName model -NotePropertyValue $defaultModel -Force
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $backup = "$settingsPath.before-vdi-$(Get-Date -Format 'yyyyMMdd-HHmmssfff').bak"
    Copy-Item -LiteralPath $settingsPath -Destination $backup -ErrorAction Stop
    Write-Host "Previous settings: $backup"
}
$json = $settings | ConvertTo-Json -Depth 40
[IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host 'Claude Code gateway settings saved.'
```

Existing process or VS Code extension environment settings can override the file.
If another provider, credential or gateway is already configured, review it with the
platform team rather than removing it blindly. The repository's PowerShell 7 setup
script is an alternative when an approved repository copy and client configuration
file are available: [client setup](../CLIENTS.md).

## 4. Configure VS Code

In VS Code, open **Preferences: Open User Settings (JSON)** from the command palette.
Add the following property to the existing outer JSON object, preserving the other
entries and commas:

```json
"claudeCode.disableLoginPrompt": true
```

Reload the window using **Developer: Reload Window**. Existing
`claudeCode.environmentVariables` entries can override the gateway settings; review
any conflicts with the platform team. The extension and CLI use the same per-user
Claude Code settings. See [VS Code configuration](../CLIENTS.md#4-configure-claude-code-and-vs-code).

## 5. Sign in and test

The following command discards the helper's token output. If Azure CLI needs an
interactive sign-in, it opens the organization's approved sign-in flow. The final
line reports success or failure, not the token.

```powershell
& (Join-Path $env:USERPROFILE '.claude\az-gateway-token.cmd') > $null
if ($LASTEXITCODE -ne 0) { throw 'Gateway sign-in failed; check the sign-in error with the identity team.' }
Write-Host 'Gateway token helper succeeded.'
```

In a new terminal, an authorized user can make a small billable test request:

```powershell
claude -p "Reply with exactly: gateway OK"
```

An actual reply is the acceptance check; helper success alone proves only that a
token was obtained. In VS Code, select the approved model in the Claude Code
extension and send the same test. Record the UTC time, client version, model,
HTTP status and a redacted correlation or tracking ID when a test fails.

| Result | Next check |
| --- | --- |
| Sign-in error | Identity team checks account, scope, preauthorization and Conditional Access. |
| 401 | Platform team checks token audience, scope and accepted client. |
| 403 | Platform team correlates the tracking ID with WAF and gateway logs and checks project/model admission. |
| 400 `project_selection_required` | Check the project header and authorized membership. |
| 429 | Check the response and applicable rate or budget limits. |
| 503 `entitlement_unavailable` | Platform team traces the APIM-to-resolver request, resolver health, authentication and private connectivity. The error alone does not identify the cause. |

Do not share the token, prompt text or raw request body in the diagnostic record.
For rollback, review and restore the timestamped helper and settings backups; any
changes made after the backup need separate review.
