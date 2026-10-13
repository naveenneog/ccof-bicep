#Requires -Version 7.0
<#
.SYNOPSIS
    Owner smoke through the gateway: without a token the gateway must answer 401; with the owner's
    token from the client helper (ccof-token) it must answer 200 with the reply "OK".

.DESCRIPTION
    The gateway configuration (-GatewayConfigPath, infra/gateway/config/<name>.json, checked against
    infra/gateway/gateway-config.schema.json) gives the URL (apim.gatewayBaseUrl/apim.apiPath), the
    project header (resolver.projectHeaderName) and anthropic-version (forwarding.defaultAnthropicVersion;
    null sends none). The client configuration (-ClientConfigPath; by default CCOF_CONFIG_FILE, else
    %LOCALAPPDATA%\ClaudeGateway\config.json; docs/CLIENTS.md) must name the same gateway in gatewayUrl.
    It gives the default model (models.haiku), the project selection (project.id, sent when set) and
    the time limits (tokenTimeoutSeconds, used as scripts/client/Test-ClientGatewayAccess.ps1 uses it).
    -Revision, -ProjectId and -Model override.

    The token comes from client/bin/ccof-token.mjs token (docs/CLIENTS.md, section 3) and stays a
    SecureString; requests send it with -Authentication Bearer and follow no redirect. Response text is
    scrubbed of the token and of any JWT-shaped string before it is printed. The output is one JSON
    report: status codes, the gateway's request ids and error types, the model and the reply.
    Exit codes: 0 both checks passed; 1 a check failed; 2 refused before any request.

.EXAMPLE
    pwsh -NoProfile -File scripts/Test-OwnerSmoke.ps1 -GatewayConfigPath infra/gateway/config/sample-pilot.json
.EXAMPLE
    pwsh -NoProfile -File scripts/Test-OwnerSmoke.ps1 -GatewayConfigPath infra/gateway/config/sample-pilot.json -Revision 8 -ProjectId CCOFPILOT02
#>
[CmdletBinding()]
param([string]$GatewayConfigPath, [string]$ClientConfigPath, [string]$Revision, [string]$ProjectId, [string]$Model, [switch]$DotSourceOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'client' 'ClientGateway.Common.ps1')
. (Join-Path $PSScriptRoot 'client' 'ClientProcess.ps1')

$script:OwnerSmokeGatewaySchema = Join-Path (Split-Path $PSScriptRoot -Parent) 'infra' 'gateway' 'gateway-config.schema.json'
$script:OwnerSmokeJwt = 'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*'

function Stop-OwnerSmoke {
    param([Parameter(Mandatory)] [string]$Code, [Parameter(Mandatory)] [string]$Message)
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['OwnerSmokeCode'] = $Code
    throw $exception
}

function Protect-OwnerSmokeText {
    param([AllowNull()] [AllowEmptyString()] [string]$Text, [AllowNull()] [AllowEmptyString()] [string]$Secret, [int]$Max = 240)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $clean = ($Text -replace '\s+', ' ').Trim()
    if ($Secret) { $clean = $clean.Replace($Secret, '[redacted]') }
    $clean = [regex]::Replace($clean, $script:OwnerSmokeJwt, '[redacted]')
    if ($clean.Length -gt $Max) { $clean = $clean.Substring(0, $Max) + '...' }
    $clean
}

function Read-OwnerSmokeSettings {
    param([string]$GatewayConfigPath, [string]$ClientConfigPath, [string]$Revision, [string]$ProjectId, [string]$Model)
    if ($Revision -and $Revision -cnotmatch '^[1-9][0-9]{0,5}$') { Stop-OwnerSmoke 'parameter_invalid' "-Revision must be an API revision number, not '$Revision'." }
    if ($ProjectId -and $ProjectId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { Stop-OwnerSmoke 'parameter_invalid' "-ProjectId must be a project id (a letter or digit, then up to 79 letters, digits, '_' or '-'), not '$ProjectId'." }
    if ($Model -and $Model -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { Stop-OwnerSmoke 'parameter_invalid' "-Model must be a deployment name, not '$Model'." }
    if (-not $GatewayConfigPath -or -not (Test-Path -LiteralPath $GatewayConfigPath -PathType Leaf)) {
        Stop-OwnerSmoke 'gateway_config_missing' "Pass -GatewayConfigPath: the deployed gateway's configuration, infra/gateway/config/<name>.json; '$GatewayConfigPath' was not found."
    }
    $json = Get-Content -LiteralPath $GatewayConfigPath -Raw
    $problems = $null
    if (-not ($json -and (Test-Json -Json $json -SchemaFile $script:OwnerSmokeGatewaySchema -ErrorAction SilentlyContinue -ErrorVariable problems))) {
        $why = @($problems | ForEach-Object { $_.Exception.Message -replace '^The JSON is not valid with the schema: ', '' } | Where-Object { $_ }) -join '; '
        Stop-OwnerSmoke 'gateway_config_invalid' "$GatewayConfigPath does not match infra/gateway/gateway-config.schema.json: $(if ($why) { $why } else { 'empty' })."
    }
    $gateway = $json | ConvertFrom-Json -AsHashtable
    $base = "$($gateway.apim.gatewayBaseUrl)/$($gateway.apim.apiPath)"
    $header = $gateway.resolver.projectHeaderName
    try {
        if (-not $ClientConfigPath) { $ClientConfigPath = Get-ClientDefaultConfigPath }
        $ClientConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ClientConfigPath)
        $client = Read-ClientConfiguration $ClientConfigPath
    }
    catch { Stop-OwnerSmoke 'client_config_invalid' "Client configuration ${ClientConfigPath}: $($_.Exception.Message)" }
    if (-not [string]::Equals($client.gatewayUrl, $base, 'Ordinal')) {
        Stop-OwnerSmoke 'gateway_url_mismatch' ("The client configuration's gatewayUrl $($client.gatewayUrl) is not the gateway configuration's $base (apim.gatewayBaseUrl/apim.apiPath). " +
            'Pass the gateway configuration this client uses, or correct the client configuration (docs/CLIENTS.md).')
    }
    $clientProject = $client['project']
    if ($clientProject -and -not [string]::Equals($clientProject.selectorHeader, $header, 'OrdinalIgnoreCase')) {
        Stop-OwnerSmoke 'project_header_mismatch' "The client configuration's project.selectorHeader $($clientProject.selectorHeader) is not the gateway's resolver.projectHeaderName $header."
    }
    $project = if ($ProjectId) { [ordered]@{ id = $ProjectId; header = $header; source = 'parameter' } }
    elseif ($clientProject -and $null -ne $clientProject.id) { [ordered]@{ id = $clientProject.id; header = $header; source = 'client configuration' } }
    [pscustomobject]@{
        Url                 = "$base$(if ($Revision) { ";rev=$Revision" })/v1/messages"
        Revision            = $(if ($Revision) { $Revision } else { $null })
        Model               = $(if ($Model) { $Model } else { $client.models.haiku })
        ModelSource         = $(if ($Model) { 'parameter' } else { 'client configuration models.haiku' })
        AnthropicVersion    = $gateway.forwarding.defaultAnthropicVersion
        Project             = $project
        TimeoutSeconds      = [int]$client.tokenTimeoutSeconds
        TokenTimeoutSeconds = [Math]::Min(600, [int]$client.tokenTimeoutSeconds * 3)
        ClientConfigPath    = $ClientConfigPath
    }
}

function Get-OwnerSmokeHeader {
    param($Headers, [string]$Name)
    if (-not $Headers) { return $null }
    foreach ($key in @($Headers.Keys)) { if ([string]::Equals("$key", $Name, 'OrdinalIgnoreCase')) { return "$(@($Headers[$key])[0])" } }
    $null
}

function Get-OwnerSmokeBody {
    param([string]$Content)
    try { $Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $null }
}

function Get-OwnerSmokeError {
    param([string]$Content, [string]$Secret)
    $body = Get-OwnerSmokeBody $Content
    $type = $null
    $message = $Content
    if ($body -is [Collections.IDictionary] -and $body['error'] -is [Collections.IDictionary]) { $type = "$($body['error']['type'])"; $message = "$($body['error']['message'])" }
    elseif ($body -is [Collections.IDictionary] -and $body['message']) { $message = "$($body['message'])" }
    [ordered]@{ type = (Protect-OwnerSmokeText $type $Secret 64); message = (Protect-OwnerSmokeText $message $Secret) }
}

function Get-OwnerSmokeRemedy {
    param([int]$Expected, [int]$Status, [string]$Message)
    if ($Expected -eq 401) {
        if ($Status -ge 200 -and $Status -lt 300) { return 'The gateway answered without a token: sign-in is not enforced on this API or revision. Treat it as an incident and check its validate-jwt policy (docs/GATEWAY.md).' }
        return 'Expected 401 without a token; check the URL, -Revision and the API policy.'
    }
    switch ($Status) {
        401 { 'The token was refused: run ccof-token login; check the tenant, public client and gateway API scope (docs/CLIENTS.md, Troubleshooting).' }
        403 { 'Not entitled, model not allowed, or a token quota used up: check pilot-group membership and the model with the administrator (docs/CLIENTS.md, Troubleshooting).' }
        400 { if ($Message -match 'more than one project') { 'More than one active project: pass -ProjectId, or set project in the client configuration (docs/CLIENTS.md).' } else { 'The gateway refused the request as invalid; see the error.' } }
        404 { 'Wrong API base, revision or deployment name: check apim.apiPath, -Revision and -Model (docs/CLIENTS.md, Troubleshooting).' }
        429 { 'Rate limited: honour Retry-After; do not retry in a tight loop.' }
        default { 'See the error and docs/CLIENTS.md, Troubleshooting.' }
    }
}

function Invoke-OwnerSmokeCheck {
    param($Probes, $Settings, [hashtable]$Headers, [string]$Body, [int]$Expected, [securestring]$Token)
    $secret = if ($Token) { [Net.NetworkCredential]::new('', $Token).Password } else { $null }
    $check = [ordered]@{ status = $null; expected = $Expected; pass = $false }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        try { $response = & $Probes.Http $Settings.Url $Headers $Body $Token $Settings.TimeoutSeconds }
        catch {
            $check.error = [ordered]@{ type = 'transport'; message = (Protect-OwnerSmokeText "transport failed: $($_.Exception.Message)" $secret) }
            $check.remedy = 'The gateway could not be reached; check the URL and the network path.'
            return $check
        }
        $check.status = [int]$response.StatusCode
        $check.ms = $timer.ElapsedMilliseconds
        $check.requestId = Protect-OwnerSmokeText (Get-OwnerSmokeHeader $response.Headers 'x-ccof-request-id') $secret 80
        if ($Expected -eq 200 -and $check.status -eq 200) {
            $message = Get-OwnerSmokeBody "$($response.Content)"
            $first = if ($message -is [Collections.IDictionary]) { @($message['content'] | Where-Object { $_ -is [Collections.IDictionary] -and $_['type'] -eq 'text' })[0] }
            $text = if ($first) { "$($first['text'])" }
            $check.reply = Protect-OwnerSmokeText $text $secret 80
            if ($message -is [Collections.IDictionary] -and $message['usage'] -is [Collections.IDictionary]) {
                $check.usage = "in=$($message['usage']['input_tokens']) out=$($message['usage']['output_tokens'])"
            }
            $check.pass = $check.reply -is [string] -and $check.reply.TrimEnd('.') -ieq 'OK'
            if (-not $check.pass) { $check.remedy = 'The gateway answered 200, but the reply was not OK; check the model deployment.' }
            return $check
        }
        $check.pass = $check.status -eq $Expected
        if (-not $check.pass) {
            $check.error = Get-OwnerSmokeError "$($response.Content)" $secret
            $check.remedy = Get-OwnerSmokeRemedy $Expected $check.status $check.error.message
        }
        $check
    }
    finally { $secret = $null }
}

function Invoke-OwnerSmoke {
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [hashtable]$Probes)
    $body = [ordered]@{ model = $Settings.Model; max_tokens = 16; messages = @(@{ role = 'user'; content = 'Reply with the single word OK' }) } | ConvertTo-Json -Depth 5 -Compress
    $headers = @{}
    if ($Settings.AnthropicVersion) { $headers['anthropic-version'] = $Settings.AnthropicVersion }
    $report = [ordered]@{ result = $null; at = [DateTimeOffset]::UtcNow.ToString('o'); url = $Settings.Url; revision = $Settings.Revision; model = $Settings.Model
        modelSource = $Settings.ModelSource; anthropicVersion = $Settings.AnthropicVersion; project = $Settings.Project; noToken = $null; owner = $null
    }
    $report.noToken = Invoke-OwnerSmokeCheck $Probes $Settings $headers $body 401 $null
    $token = $null
    $tokenError = 'The client helper returned no token. Run ccof-token login once (docs/CLIENTS.md, section 3).'
    try { $token = & $Probes.GetToken $Settings } catch { $tokenError = $_.Exception.Message }
    if ($token -isnot [securestring]) {
        $report.owner = [ordered]@{ status = $null; expected = 200; pass = $false; token = 'unavailable'; remedy = (Protect-OwnerSmokeText $tokenError $null) }
    }
    else {
        $ownerHeaders = $headers.Clone()
        if ($Settings.Project) { $ownerHeaders[$Settings.Project.header] = $Settings.Project.id }
        try { $report.owner = Invoke-OwnerSmokeCheck $Probes $Settings $ownerHeaders $body 200 $token }
        finally { $token.Dispose() }
    }
    $passed = $report.noToken.pass -and $report.owner.pass
    $report.result = if ($passed) { 'PASS' } else { 'FAIL' }
    [pscustomobject]@{ ExitCode = $(if ($passed) { 0 } else { 1 }); Report = $report }
}

function Format-OwnerSmokeReport {
    param([Parameter(Mandatory)] $Report)
    # Every response field is scrubbed already; this is a second net for any JWT-shaped string.
    [regex]::Replace(($Report | ConvertTo-Json -Depth 6), $script:OwnerSmokeJwt, '[redacted]')
}

function Get-OwnerSmokeToken {
    param([Parameter(Mandatory)] [string]$ClientConfigPath, [Parameter(Mandatory)] [ValidateRange(1, 600)] [int]$TimeoutSeconds,
        [string]$EntryPath = (Join-Path $script:ClientRepoRoot 'client' 'bin' 'ccof-token.mjs'))
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { throw 'Node.js is missing; the client helper needs it (docs/CLIENTS.md).' }
    $child = Invoke-CcofChild -FilePath $node.Source -Arguments @($EntryPath, 'token') -WorkingDirectory $script:ClientRepoRoot `
        -TimeoutSeconds $TimeoutSeconds -Environment @{ CCOF_CONFIG_FILE = $ClientConfigPath }
    $text = "$($child.Stdout)".Trim()
    $child.Stdout = $null
    if ($child.ExitCode -ne 0 -or $child.Stderr -or $text -notmatch '^\S+$') {
        $text = $null
        throw 'The client helper returned no token. Run ccof-token login once (docs/CLIENTS.md, section 3).'
    }
    $secure = ConvertTo-SecureString -String $text -AsPlainText -Force
    $text = $null
    $secure
}

function Get-OwnerSmokeDefaultToken {
    param($Settings)
    if (-not (Test-Path -LiteralPath (Join-Path $script:ClientRepoRoot 'client' 'node_modules') -PathType Container)) {
        throw 'The client helper is not installed in this checkout: run npm ci --prefix client --no-audit --no-fund (docs/CLIENTS.md, section 2), then ccof-token login once.'
    }
    Get-OwnerSmokeToken -ClientConfigPath $Settings.ClientConfigPath -TimeoutSeconds $Settings.TokenTimeoutSeconds
}

function Invoke-OwnerSmokeHttp {
    param([string]$Uri, [hashtable]$Headers, [string]$Body, [securestring]$BearerToken, [int]$TimeoutSeconds)
    $request = @{ Method = 'Post'; Uri = $Uri; Headers = $Headers; Body = $Body; ContentType = 'application/json'; SkipHttpErrorCheck = $true
        MaximumRedirection = 0; TimeoutSec = $TimeoutSeconds; UserAgent = 'ccof-owner-smoke/1.0'; ErrorAction = 'Stop'
    }
    if ($BearerToken) { $request.Authentication = 'Bearer'; $request.Token = $BearerToken }
    $response = Invoke-WebRequest @request
    [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Content = "$($response.Content)"; Headers = $response.Headers }
}

function Invoke-OwnerSmokeMain {
    param([string]$GatewayConfigPath, [string]$ClientConfigPath, [string]$Revision, [string]$ProjectId, [string]$Model,
        [hashtable]$Probes = @{ Http = ${function:Invoke-OwnerSmokeHttp}; GetToken = ${function:Get-OwnerSmokeDefaultToken} })
    try { $settings = Read-OwnerSmokeSettings -GatewayConfigPath $GatewayConfigPath -ClientConfigPath $ClientConfigPath -Revision $Revision -ProjectId $ProjectId -Model $Model }
    catch {
        $code = $_.Exception.Data['OwnerSmokeCode']
        $refusal = [ordered]@{ result = 'REFUSED'; reasonCode = $(if ($code) { $code } else { 'unexpected_error' }); remedy = $_.Exception.Message }
        return [pscustomobject]@{ ExitCode = 2; Text = ($refusal | ConvertTo-Json) }
    }
    $run = Invoke-OwnerSmoke -Settings $settings -Probes $Probes
    [pscustomobject]@{ ExitCode = $run.ExitCode; Text = (Format-OwnerSmokeReport $run.Report) }
}

if (-not $DotSourceOnly) {
    $run = Invoke-OwnerSmokeMain -GatewayConfigPath $GatewayConfigPath -ClientConfigPath $ClientConfigPath -Revision $Revision -ProjectId $ProjectId -Model $Model
    Write-Output $run.Text
    exit $run.ExitCode
}
