#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'scripts/client/ClientGateway.Common.ps1')
. (Join-Path $repo 'scripts/client/ClaudeCodeGateway.ps1')
. (Join-Path $repo 'scripts/client/ClaudeDesktopGateway.ps1')
. (Join-Path $repo 'scripts/client/DeveloperSignInRedirects.ps1')

$work = Join-Path $repo ('client/.test-work/scripts-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$script:passed = 0
$script:failed = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Test) {
    try { & $Test; $script:passed++; Write-Host "PASS: $Name" }
    catch { $script:failed++; Write-Host "FAIL: $Name - $($_.Exception.Message)" }
}
function Refuses([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Assert ($_.Exception.Message -match $Pattern) 'Refusal did not name the expected remedy'
        return
    }
    throw 'Expected refusal'
}

try {
    $configPath = Join-Path $work 'config.json'
    $config = @{
        schemaVersion = 1
        tenantId = '11111111-1111-4111-8111-111111111111'
        clientId = '22222222-2222-4222-8222-222222222222'
        scope = 'api://33333333-3333-4333-8333-333333333333/access_as_user'
        gatewayUrl = 'https://gateway.example.test/anthropic'
        helperTtlSeconds = 300; minimumTokenLifetimeSeconds = 360
        loginTimeoutSeconds = 120; tokenTimeoutSeconds = 30
        disableNonessentialTraffic = $true
        models = @{ default = 'sonnet-deployment'; opus = 'opus-deployment'
            sonnet = 'sonnet-deployment'; haiku = 'haiku-deployment'
            available = @('sonnet-deployment', 'opus-deployment', 'haiku-deployment')
            capabilities = @{ opus = 'thinking,adaptive_thinking'; sonnet = 'thinking,adaptive_thinking' } }
        desktop = @{ profileId = '44444444-4444-4444-8444-444444444444'; profileName = 'Test gateway' }
    }
    Write-ClientJson $configPath $config
    $backupRoot = Join-Path $work 'backups'
    $claudeHome = Join-Path $work '.claude'
    $vscodePath = Join-Path $work 'code/settings.json'
    $desktopRoot = Join-Path $work 'Claude-3p/configLibrary'
    $inventory = @{ CliVersion = '2.1.272'; VSCodeVersion = '2.1.289'; DesktopVersion = '2.2553.1.0' }
    $node = (Get-Command node -ErrorAction Stop).Source
    $entry = Join-Path $repo 'client/bin/ccof-token.mjs'
    $codeArgs = @{ ConfigPath = $configPath; ClaudeHome = $claudeHome; VSCodeSettingsPath = $vscodePath
        BackupRoot = $backupRoot; Inventory = $inventory; NodePath = $node; TokenEntryPath = $entry }
    $settingsPath = Join-Path $claudeHome 'settings.json'
    $old = '{"theme":"dark","model":"old","env":{"KEEP_ME":"yes","CLAUDE_CODE_USE_FOUNDRY":"1"}}'
    [void][IO.Directory]::CreateDirectory($claudeHome)
    [IO.File]::WriteAllText($settingsPath, $old)
    Write-ClientJson $vscodePath @{ 'editor.fontSize' = 17; 'claudeCode.environmentVariables' = @(
        @{ name = 'KEEP_VSCODE'; value = 'yes' }, @{ name = 'CLAUDE_CODE_USE_FOUNDRY'; value = '1' }) }

    Test-Case 'configuration is validated by the same Node schema used by the helper' {
        $loaded = Read-ClientConfiguration $configPath
        Assert ([string]::Equals($loaded.gatewayUrl, $config.gatewayUrl, 'Ordinal')) 'Gateway changed'
        $bad = Join-Path $work 'bad.json'
        [IO.File]::WriteAllText($bad, '{"tenantId":"hidden-private-value"}')
        Refuses { Read-ClientConfiguration $bad } 'configuration'
    }
    Test-Case 'setup refuses without confirmation before writing any file' {
        Refuses { Set-CcofClaudeCode @codeArgs } 'Confirmed'
        Assert ([IO.File]::ReadAllText($settingsPath) -ceq $old) 'Original changed on refusal'
        Assert (-not (Test-Path $backupRoot)) 'Refusal created a backup'
    }
    Test-Case 'Claude Code merges settings, pins every model, clears conflicting auth and backs up first' {
        $script:codeResult = Set-CcofClaudeCode @codeArgs -Confirmed | ConvertFrom-Json -AsHashtable
        $settings = Read-ClientJson $settingsPath
        Assert ($settings.theme -ceq 'dark') 'Unrelated setting lost'
        Assert ($settings.env.KEEP_ME -ceq 'yes') 'Unrelated environment lost'
        Assert ($settings.env.ANTHROPIC_BASE_URL -ceq $config.gatewayUrl) 'Incorrect API base'
        Assert ($settings.env.CLAUDE_CODE_USE_FOUNDRY -ceq '0') 'Conflicting provider retained'
        Assert ($settings.env.ANTHROPIC_MODEL -ceq 'sonnet-deployment') 'Default model not pinned'
        Assert ($settings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL -ceq 'haiku-deployment') 'Haiku not pinned'
        Assert ($settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL -ceq 'opus-deployment') 'Opus not pinned'
        Assert ($settings.env.ANTHROPIC_DEFAULT_SONNET_MODEL -ceq 'sonnet-deployment') 'Sonnet not pinned'
        Assert ($settings.env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS -ceq '300000') 'Helper TTL incorrect'
        Assert ($settings.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC -ceq '1') 'Traffic decision missing'
        Assert ($settings.apiKeyHelper -match '^".+ccof-token\.cmd" token$') 'Silent token command missing'
        $snapshot = Join-Path $backupRoot $codeResult.changeId
        $manifest = Read-ClientJson (Join-Path $snapshot 'snapshot.json')
        $record = $manifest.files | Where-Object { [string]::Equals($_.path, $settingsPath, 'Ordinal') }
        Assert ([IO.File]::ReadAllText((Join-Path $snapshot $record.backupFile)) -ceq $old) 'Backup not exact'
    }
    Test-Case 'VS Code receives the common environment and disables only its hosted login prompt' {
        $vscode = Read-ClientJson $vscodePath
        Assert ($vscode['editor.fontSize'] -eq 17) 'Unrelated VS Code setting lost'
        Assert ($vscode['claudeCode.disableLoginPrompt'] -eq $true) 'External auth prelaunch check not configured'
        $envs = @{}; foreach ($row in $vscode['claudeCode.environmentVariables']) { $envs[$row.name] = $row.value }
        Assert ($envs.KEEP_VSCODE -ceq 'yes') 'Unrelated VS Code env lost'
        Assert ($envs.ANTHROPIC_BASE_URL -ceq $config.gatewayUrl) 'VS Code does not point at gateway'
        Assert ($envs.CLAUDE_CODE_USE_FOUNDRY -ceq '0') 'VS Code old provider still active'
    }
    Test-Case 'generated Windows shim quotes paths, pins config, and never invokes Azure CLI' {
        $shim = [IO.File]::ReadAllText((Join-Path $claudeHome 'ccof-token.cmd'))
        Assert ($shim -match '@echo off') 'Echo could leak credentials'
        Assert ($shim -match 'DisableDelayedExpansion') 'Exclamation marks would be re-expanded'
        Assert ($shim.Contains('set "CCOF_CONFIG_FILE=')) 'Config not pinned'
        Assert (-not ($shim -match '\baz\b|get-access-token')) 'Developer shim invokes Azure CLI'
        Assert ($shim -match 'exit /b %errorlevel%') 'Helper exit status not propagated'
    }
    Test-Case 'restore detects later edits rather than overwriting them silently' {
        [IO.File]::AppendAllText($settingsPath, "`n")
        Refuses { Restore-ClientSnapshot -BackupPath (Join-Path $backupRoot $codeResult.changeId) -Kind 'claude-code' -Confirmed } 'changed'
        $script:edited = $true
    }
    Test-Case 'explicit restore recovers byte-exact originals and removes only newly created files' {
        Restore-ClientSnapshot -BackupPath (Join-Path $backupRoot $codeResult.changeId) -Kind 'claude-code' -Confirmed -AllowChangedFiles | Out-Null
        Assert ([IO.File]::ReadAllText($settingsPath) -ceq $old) 'Restore did not recover original bytes'
        Assert (-not (Test-Path (Join-Path $claudeHome 'ccof-token.cmd'))) 'New shim not removed'
        $vscode = Read-ClientJson $vscodePath
        Assert (-not $vscode.Contains('claudeCode.disableLoginPrompt')) 'Restore retained added key'
    }
    Test-Case 'corrupted backup bytes fail integrity before any restored file is overwritten' {
        $path = Join-Path $work 'integrity.json'
        Write-ClientText $path 'original'
        $snapshot = New-ClientSnapshot 'claude-code' @($path) $backupRoot
        Write-ClientText $path 'configured'
        Complete-ClientSnapshot $snapshot
        Write-ClientText (Join-Path $snapshot.Directory '0.bin') 'corrupted'
        Refuses { Restore-ClientSnapshot -BackupPath $snapshot.Directory -Kind 'claude-code' -Confirmed } 'integrity'
        Assert ([IO.File]::ReadAllText($path) -ceq 'configured') 'Restore wrote before integrity validation'
    }
    Test-Case 'missing clients are reported and never installed or configured' {
        $options = $codeArgs.Clone(); $options.Inventory = @{ CliVersion = $null; VSCodeVersion = $null }
        $result = Set-CcofClaudeCode @options -Confirmed | ConvertFrom-Json -AsHashtable
        Assert ($result.event -ceq 'not_installed') 'Missing app not reported'
        Assert ([IO.File]::ReadAllText($settingsPath) -ceq $old) 'Missing app configured'
    }
    $keys = @('inferenceProvider', 'inferenceGatewayBaseUrl', 'inferenceGatewayAuthScheme',
        'inferenceCredentialKind', 'inferenceCredentialHelper', 'inferenceCredentialHelperArgs',
        'inferenceCredentialHelperTimeoutSec', 'inferenceCredentialHelperTtlSec',
        'inferenceCredentialHelperSilentRefreshEnabled', 'inferenceModels')
    $schema = @{ keys = $keys; credentialKinds = @('static', 'helper-script', 'interactive') }
    $desktopArgs = @{ ConfigPath = $configPath; LibraryPath = $desktopRoot; BackupRoot = $backupRoot
        Inventory = $inventory; Schema = $schema; NodePath = $node; TokenEntryPath = $entry }
    $previousId = '55555555-5555-4555-8555-555555555555'
    Write-ClientJson (Join-Path $desktopRoot '_meta.json') @{
        appliedId = $previousId; entries = @(@{ id = $previousId; name = 'Previous' }); unrelated = 'keep'
    }
    Test-Case 'Desktop older bundle uses MSAL helper and preserves existing profile selection metadata' {
        $script:desktopResult = Set-CcofClaudeDesktop @desktopArgs -Confirmed | ConvertFrom-Json -AsHashtable
        $profile = Read-ClientJson (Join-Path $desktopRoot "$($config.desktop.profileId).json")
        Assert ($profile.inferenceCredentialKind -ceq 'helper-script') 'Unsupported external-idp was selected'
        Assert ($profile.inferenceGatewayBaseUrl -ceq $config.gatewayUrl) 'Desktop URL is wrong'
        Assert ($profile.inferenceGatewayAuthScheme -ceq 'bearer') 'Desktop must send bearer tokens'
        Assert ($profile.inferenceCredentialHelperArgs[0] -ceq 'token') 'Desktop helper is not silent'
        Assert ($profile.inferenceCredentialHelperTtlSec -lt $config.minimumTokenLifetimeSeconds) 'Desktop TTL too long'
        $meta = Read-ClientJson (Join-Path $desktopRoot '_meta.json')
        Assert ($meta.appliedId -ceq $config.desktop.profileId) 'New profile not selected'
        Assert ($meta.entries.Count -eq 2) 'Existing profile entry lost'
        Assert ($meta.unrelated -ceq 'keep') 'Unrelated metadata lost'
    }
    Test-Case 'Desktop restore returns to previous appliedId and removes new profile and helper' {
        Restore-ClientSnapshot -BackupPath (Join-Path $backupRoot $desktopResult.changeId) -Kind 'claude-desktop' -Confirmed | Out-Null
        $meta = Read-ClientJson (Join-Path $desktopRoot '_meta.json')
        Assert ($meta.appliedId -ceq $previousId) 'Previous selection was not restored'
        Assert (-not (Test-Path (Join-Path $desktopRoot "$($config.desktop.profileId).json"))) 'New profile retained'
    }
    Test-Case 'Desktop modern schema uses broker access-token OIDC for the configured API, never id_token' {
        $modern = @{ keys = $keys + @('inferenceIdpOidc', 'inferenceIdpAuthFlow'); credentialKinds = @('external-idp', 'helper-script') }
        $profile = New-CcofDesktopProfile -Config $config -Schema $modern -HelperPath 'unused'
        Assert ($profile.inferenceCredentialKind -ceq 'external-idp') 'New build did not use external-idp'
        Assert ($profile.inferenceIdpAuthFlow -ceq 'broker') 'Desktop broker not enabled'
        Assert ($profile.inferenceIdpOidc.bearerTokenType -ceq 'access_token') 'Wrong gateway audience type'
        Assert ($profile.inferenceIdpOidc.scopes -ceq $config.scope) 'Wrong gateway scope'
        Assert (-not $profile.Contains('inferenceCredentialHelper')) 'OIDC mixed with helper credentials'
    }
    Test-Case 'Desktop puts the configured default deployment first regardless of available-list order' {
        $orderedConfig = $config.Clone(); $orderedConfig.models = $config.models.Clone()
        $orderedConfig.models.available = @('opus-deployment', 'haiku-deployment', 'sonnet-deployment')
        $profile = New-CcofDesktopProfile -Config $orderedConfig -Schema $schema -HelperPath 'helper'
        Assert ($profile.inferenceModels[0].name -ceq 'sonnet-deployment') 'Desktop silently chose another default'
        Assert ($profile.inferenceModels.Count -eq 3) 'Model ordering lost or duplicated a deployment'
    }
    Test-Case 'Desktop reconfiguration preserves unrelated profile keys and clears obsolete credentials' {
        $custom = @{ organizationInstructions = 'Preserve these organization instructions'
            disableNonessentialTelemetry = $true; inferenceGatewayApiKey = 'synthetic-old-key' }
        $profilePath = Join-Path $desktopRoot "$($config.desktop.profileId).json"
        Write-ClientJson $profilePath $custom
        $originalBytes = [IO.File]::ReadAllText($profilePath)
        $options = $desktopArgs.Clone()
        $options.Schema = @{ keys = $keys + @('organizationInstructions', 'disableNonessentialTelemetry', 'inferenceGatewayApiKey')
            credentialKinds = @('helper-script') }
        $result = Set-CcofClaudeDesktop @options -Confirmed | ConvertFrom-Json -AsHashtable
        $profile = Read-ClientJson $profilePath
        Assert ($profile.organizationInstructions -ceq $custom.organizationInstructions) 'Unrelated instructions were deleted'
        Assert ($profile.disableNonessentialTelemetry -eq $true) 'Telemetry policy was deleted'
        Assert (-not $profile.Contains('inferenceGatewayApiKey')) 'Old static credential remained'
        Restore-ClientSnapshot -BackupPath (Join-Path $backupRoot $result.changeId) -Kind 'claude-desktop' -Confirmed | Out-Null
        Assert ([IO.File]::ReadAllText($profilePath) -ceq $originalBytes) 'Reconfiguration backup was not byte-exact'
        Remove-Item -LiteralPath $profilePath
    }
    Test-Case 'missing Desktop keys refuse before writing configuration or backup' {
        $badSchema = @{ keys = @('inferenceProvider'); credentialKinds = @('helper-script') }
        $options = $desktopArgs.Clone(); $options.Schema = $badSchema
        Refuses { Set-CcofClaudeDesktop @options -Confirmed } 'support|schema'
        Assert (-not (Test-Path (Join-Path $desktopRoot "$($config.desktop.profileId).json"))) 'Unsupported profile written'
    }
    Test-Case 'Desktop refuses a hybrid bootstrap pointer that would override the selected local profile' {
        $metaPath = Join-Path $desktopRoot '_meta.json'
        $original = [IO.File]::ReadAllText($metaPath)
        $meta = Read-ClientJson $metaPath
        $meta.hybridPointer = @{ source = 'another-configuration' }
        Write-ClientJson $metaPath $meta
        try {
            Refuses { Set-CcofClaudeDesktop @desktopArgs -Confirmed } 'hybrid|bootstrap'
        } finally {
            [IO.File]::WriteAllText($metaPath, $original)
            $profilePath = Join-Path $desktopRoot "$($config.desktop.profileId).json"
            if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath }
        }
    }
    $script:remote = @{ id = '66666666-6666-4666-8666-666666666666'
        appId = $config.clientId; publicClient = @{ redirectUris = @('http://localhost', 'https://login.microsoftonline.com/common/oauth2/nativeclient') } }
    $script:patches = 0
    $graph = {
        param($Method, $Uri, $Body)
        if ($Method -ceq 'PATCH') {
            if ($script:patches -eq 0) {
                Assert (@(Get-ChildItem $backupRoot -Recurse -File -Filter 'redirects.json').Count -gt 0) 'Redirect backup must exist before PATCH'
            }
            $script:patches++; $script:remote.publicClient = ($Body | ConvertFrom-Json -AsHashtable).publicClient; return
        }
        return $script:remote
    }
    $redirectArgs = @{ ConfigPath = $configPath; SubscriptionId = '77777777-7777-4777-8777-777777777777'
        BackupRoot = $backupRoot; InvokeGraph = $graph }
    Test-Case 'redirect setup refuses unconfirmed writes before making Graph calls' {
        Refuses { Set-CcofDeveloperRedirects @redirectArgs } 'Confirmed'
        Assert ($patches -eq 0) 'Unconfirmed Graph PATCH'
    }
    Test-Case 'redirect setup backs up before PATCH and adds broker URI while preserving existing redirects' {
        $script:redirectResult = Set-CcofDeveloperRedirects @redirectArgs -Confirmed | ConvertFrom-Json -AsHashtable
        Assert ($patches -eq 1) 'Expected one Graph PATCH'
        Assert ($remote.publicClient.redirectUris -ccontains "ms-appx-web://Microsoft.AAD.BrokerPlugin/$($config.clientId)") 'Broker URI missing'
        Assert ($remote.publicClient.redirectUris -ccontains 'http://localhost') 'Existing redirect lost'
        Assert (Test-Path (Join-Path $backupRoot "$($redirectResult.changeId)/redirects.json")) 'Redirect backup missing'
    }
    Test-Case 'redirect setup is idempotent' {
        Set-CcofDeveloperRedirects @redirectArgs -Confirmed | Out-Null
        Assert ($patches -eq 1) 'Idempotent rerun wrote to Graph'
    }
    Test-Case 'redirect restore recovers original values only for the matching application' {
        Restore-CcofDeveloperRedirects -ConfigPath $configPath -SubscriptionId $redirectArgs.SubscriptionId `
            -BackupPath (Join-Path $backupRoot $redirectResult.changeId) -InvokeGraph $graph -Confirmed | Out-Null
        Assert ($remote.publicClient.redirectUris.Count -eq 2) 'Redirects not restored'
        Assert (-not ($remote.publicClient.redirectUris -cmatch '^ms-appx-web:')) 'Broker URI retained'
    }
    Test-Case 'a foreign Graph application is rejected before any PATCH' {
        $foreign = { param($Method, $Uri, $Body) return @{ id = $script:remote.id; appId = '88888888-8888-4888-8888-888888888888'; publicClient = $script:remote.publicClient } }
        $options = $redirectArgs.Clone(); $options.InvokeGraph = $foreign
        $count = $patches
        Refuses { Set-CcofDeveloperRedirects @options -Confirmed } 'application'
        Assert ($patches -eq $count) 'Foreign application modified'
    }
    Test-Case 'Graph failures are not treated as an empty redirect list' {
        $options = $redirectArgs.Clone(); $options.InvokeGraph = { throw 'Graph unavailable' }
        $count = $patches
        Refuses { Set-CcofDeveloperRedirects @options -Confirmed } 'Graph'
        Assert ($patches -eq $count) 'Graph error caused PATCH'
    }
    Test-Case 'malformed Graph application data refuses before any PATCH' {
        foreach ($badRead in @(
            @{ id = 'not-guid'; appId = $config.clientId; publicClient = @{ redirectUris = @() } },
            @{ id = $remote.id; appId = $config.clientId; publicClient = $null },
            @{ id = $remote.id; appId = $config.clientId; publicClient = @{} })) {
            $counter = @{ writes = 0 }
            $reader = { param($Method, $Uri, $Body)
                if ($Method -ceq 'PATCH') { $counter.writes++; throw 'Unexpected write reached' }
                return $badRead
            }.GetNewClosure()
            $options = $redirectArgs.Clone(); $options.InvokeGraph = $reader
            Refuses { Set-CcofDeveloperRedirects @options -Confirmed } 'GUID|redirect list'
            Assert ($counter.writes -eq 0) 'Malformed response caused a write'
        }
    }
    Test-Case 'redirect PATCH is not success until readback matches the recorded target' {
        $unchanged = @{ id = $remote.id; appId = $config.clientId; publicClient = @{ redirectUris = @('http://localhost') } }
        $counter = @{ writes = 0 }
        $reader = { param($Method, $Uri, $Body)
            if ($Method -ceq 'PATCH') { $counter.writes++; return }
            return $unchanged
        }.GetNewClosure()
        $options = $redirectArgs.Clone(); $options.InvokeGraph = $reader
        Refuses { Set-CcofDeveloperRedirects @options -Confirmed } 'verification failed'
        Assert ($counter.writes -eq 1) 'Readback regression did not exercise PATCH'
    }
    Test-Case 'redirect restore refuses another administrator change before PATCH' {
        $parallel = @{ id = $remote.id; appId = $config.clientId; publicClient = @{
            redirectUris = @('http://localhost', 'https://login.microsoftonline.com/common/oauth2/nativeclient',
                'https://approved.example.test/callback') } }
        $counter = @{ writes = 0 }
        $reader = { param($Method, $Uri, $Body)
            if ($Method -ceq 'PATCH') { $counter.writes++; return }
            return $parallel
        }.GetNewClosure()
        Refuses { Restore-CcofDeveloperRedirects -ConfigPath $configPath -SubscriptionId $redirectArgs.SubscriptionId `
            -BackupPath (Join-Path $backupRoot $redirectResult.changeId) -InvokeGraph $reader -Confirmed } 'changed'
        Assert ($counter.writes -eq 0) 'Concurrent administrator change was overwritten'
    }
    Test-Case 'public redirect entrypoint uses its real default invoker without script-scope resolution failure' {
        $child = Join-Path $PSScriptRoot 'Test-RedirectEntrypointChild.ps1'
        $childOutput = & pwsh -NoProfile -File $child -ConfigPath $configPath -BackupRoot $backupRoot `
            -SubscriptionId $redirectArgs.SubscriptionId 2>$null
        Assert ($LASTEXITCODE -eq 0) 'Public redirect entrypoint failed in a fresh process'
        Assert (($childOutput | ConvertFrom-Json -AsHashtable).ok -eq $true) 'Fresh process did not verify the adapter'
        $global:CcofMockGraph = @{ app = @{ id = '66666666-6666-4666-8666-666666666666'
                appId = $config.clientId; publicClient = @{ redirectUris = @('http://localhost') } }
            azCalls = 0; restCalls = 0; tenant = $config.tenantId; subscription = $redirectArgs.SubscriptionId
            credential = 'synthetic-admin-value' }
        function global:az {
            $global:CcofMockGraph.azCalls++
            if ($args -ccontains '--tenant' -or $args -cnotcontains '--subscription' -or $args -cnotcontains 'ms-graph') {
                $global:LASTEXITCODE = 1
                return ''
            }
            $global:LASTEXITCODE = 0
            return (@{ accessToken = $global:CcofMockGraph.credential; tenant = $global:CcofMockGraph.tenant
                subscription = $global:CcofMockGraph.subscription } | ConvertTo-Json -Compress)
        }
        function global:Invoke-RestMethod {
            param($Method, $Uri, $Headers, $Body, $ContentType, $MaximumRedirection, $ErrorAction)
            $global:CcofMockGraph.restCalls++
            if ($Headers.Authorization -cne 'Bearer synthetic-admin-value') { throw 'Expected mocked Graph credential only' }
            if ($Method -ceq 'PATCH') { $global:CcofMockGraph.app.publicClient = ($Body | ConvertFrom-Json -AsHashtable).publicClient; return }
            return $global:CcofMockGraph.app
        }
        try {
            & (Join-Path $repo 'scripts/client/Set-DeveloperSignInRedirects.ps1') -ConfigPath $configPath `
                -SubscriptionId $redirectArgs.SubscriptionId -BackupRoot $backupRoot -Confirmed | Out-Null
            Assert ($global:CcofMockGraph.azCalls -eq 3) 'Default invoker did not obtain mocked Graph tokens'
            Assert ($global:CcofMockGraph.restCalls -eq 3) 'Default invoker did not execute GET/PATCH/readback'
            foreach ($field in @('tenant', 'subscription', 'credential')) {
                $before = $global:CcofMockGraph[$field]
                $global:CcofMockGraph[$field] = 'invalid metadata'
                Refuses { Invoke-CcofGraph 'GET' 'https://graph.microsoft.com/v1.0/applications' $null $config.tenantId $redirectArgs.SubscriptionId } 'token|tenant|subscription'
                Assert ($global:CcofMockGraph.restCalls -eq 3) 'Mismatched administrator token reached Graph'
                $global:CcofMockGraph[$field] = $before
            }
        } finally {
            Remove-Item Function:\az, Function:\Invoke-RestMethod
            Remove-Variable CcofMockGraph -Scope Global
        }
    }
    Test-Case 'model capability declarations are optional and nonessential traffic is an explicit choice' {
        $withoutCapabilities = $config.Clone()
        $withoutCapabilities.models = $config.models.Clone()
        $withoutCapabilities.models.Remove('capabilities')
        $withoutCapabilities.disableNonessentialTraffic = $false
        $envs = New-CcofCodeEnvironment $withoutCapabilities $configPath
        Assert ($envs.ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES -ceq '') 'Optional capabilities were fabricated'
        Assert ($envs.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC -ceq '0') 'Explicit traffic choice ignored'
    }
    Test-Case 'public setup, restore and verification entrypoints exist and parse' {
        foreach ($name in @('Set-ClaudeCodeGateway.ps1', 'Restore-ClaudeCodeGateway.ps1',
            'Set-ClaudeDesktopGateway.ps1', 'Restore-ClaudeDesktopGateway.ps1',
            'Set-DeveloperSignInRedirects.ps1', 'Restore-DeveloperSignInRedirects.ps1',
            'Test-InstalledClients.ps1', 'Test-ClientGatewayAccess.ps1')) {
            $file = Join-Path $repo "scripts/client/$name"
            Assert (Test-Path $file) "Missing public entrypoint $name"
            $tokens = $null; $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
            Assert ($errors.Count -eq 0) "Invalid PowerShell in $name"
        }
    }
    Test-Case 'child-process verification closes stdin and captures credentials without printing them' {
        $file = Join-Path $repo 'scripts/client/ClientProcess.ps1'
        Assert (Test-Path $file) 'Missing bounded process adapter'
        . $file
        $result = Invoke-CcofChild -FilePath $node -Arguments @('-e', 'process.stdin.on("end",()=>process.stdout.write("synthetic-child-value")).resume()') `
            -WorkingDirectory $work -TimeoutSeconds 5 -Environment @{ CCOF_CONFIG_FILE = $configPath }
        Assert ($result.ExitCode -eq 0) 'Non-interactive child failed'
        Assert ($result.Stdout -ceq 'synthetic-child-value') 'Child output was not captured exactly'
        Assert ($result.Stderr -ceq '') 'Child wrote unexpected diagnostic output'
    }
    Test-Case 'child-process verification times out and terminates only its own process tree' {
        $file = Join-Path $repo 'scripts/client/ClientProcess.ps1'
        Assert (Test-Path $file) 'Missing bounded process adapter'
        . $file
        $result = Invoke-CcofChild -FilePath $node -Arguments @('-e', 'setTimeout(()=>{},30000)') `
            -WorkingDirectory $work -TimeoutSeconds 1
        Assert ($result.TimedOut -eq $true) 'Child timeout ignored'
        Assert ($result.ExitCode -ne 0) 'Timed-out child reported success'
    }
    Test-Case 'CMD child launch uses native shell quoting and preserves spaces and empty arguments' {
        . (Join-Path $repo 'scripts/client/ClientProcess.ps1')
        $cmdPath = Join-Path $work 'cmd fixture/echo.cmd'
        [void][IO.Directory]::CreateDirectory((Split-Path $cmdPath -Parent))
        [IO.File]::WriteAllText($cmdPath, "@echo off`r`n`"$node`" -e `"process.stdout.write(JSON.stringify(process.argv.slice(1)))`" %*`r`nexit /b %errorlevel%`r`n")
        $start = New-CcofChildStartInfo -FilePath $cmdPath -Arguments @('one two', '', 'tail') -WorkingDirectory $work
        Assert ($start.ArgumentList.Count -eq 0) 'CMD command was escaped as a CRT argument'
        Assert ($start.Arguments.StartsWith('/d /s /c ""')) 'CMD raw command quoting is missing'
        if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
            $result = Invoke-CcofChild -FilePath $cmdPath -Arguments @('one two', '', 'tail') -WorkingDirectory $work -TimeoutSeconds 5
            Assert ($result.ExitCode -eq 0) 'Actual CMD execution failed'
            Assert ($result.Stdout -ceq '["one two","","tail"]') 'CMD arguments were changed'
        }
    }
    Test-Case 'project profiles share SSO and send only the configured selector while preserving unrelated headers' {
        $selected = $config.Clone()
        $selected.project = @{ id = 'CCOFPILOT01'; selectorHeader = 'X-Test-Project' }
        $selectedPath = Join-Path $work 'project-config.json'
        Write-ClientJson $selectedPath $selected
        $options = $codeArgs.Clone()
        $options.ConfigPath = $selectedPath
        $options.ClaudeHome = Join-Path $work 'project/.claude'
        $options.VSCodeSettingsPath = Join-Path $work 'project/code/settings.json'
        Write-ClientJson (Join-Path $options.ClaudeHome 'settings.json') @{ env = @{ ANTHROPIC_CUSTOM_HEADERS = 'X-Keep: one' } }
        Write-ClientJson $options.VSCodeSettingsPath @{ 'claudeCode.environmentVariables' = @(@{ name = 'ANTHROPIC_CUSTOM_HEADERS'; value = 'X-Editor: two' }) }
        Set-CcofClaudeCode @options -Confirmed | Out-Null
        $value = Read-ClientJson (Join-Path $options.ClaudeHome 'settings.json')
        Assert ($value.env.ANTHROPIC_CUSTOM_HEADERS -match '(?m)^X-Test-Project: CCOFPILOT01$') 'Project selector missing'
        Assert ($value.env.ANTHROPIC_CUSTOM_HEADERS -match 'X-Keep: one') 'Existing CLI header lost'
        Assert ($value.env.ANTHROPIC_CUSTOM_HEADERS -match 'X-Editor: two') 'Existing editor header lost'
        $desktopOptions = $desktopArgs.Clone()
        $desktopOptions.ConfigPath = $selectedPath
        $desktopOptions.LibraryPath = Join-Path $work 'project/desktop/configLibrary'
        $desktopOptions.Schema = @{ keys = $keys + @('inferenceCustomHeaders'); credentialKinds = @('helper-script') }
        Set-CcofClaudeDesktop @desktopOptions -Confirmed | Out-Null
        $firstPath = Join-Path $desktopOptions.LibraryPath "$($selected.desktop.profileId).json"
        $first = Read-ClientJson $firstPath
        Assert ($first.inferenceCustomHeaders['X-Test-Project'] -ceq 'CCOFPILOT01') 'Desktop selector missing'
        $first.inferenceCustomHeaders['X-Desktop'] = 'preserve'
        Write-ClientJson $firstPath $first
        Set-CcofClaudeDesktop @desktopOptions -Confirmed | Out-Null
        Assert ((Read-ClientJson $firstPath).inferenceCustomHeaders['X-Desktop'] -ceq 'preserve') 'Unrelated Desktop header lost'
        $selected.project.id = 'CCOFPILOT02'
        $selected.desktop = @{ profileId = '99999999-9999-4999-8999-999999999999'; profileName = 'Project two' }
        Write-ClientJson $selectedPath $selected
        Set-CcofClaudeDesktop @desktopOptions -Confirmed | Out-Null
        $second = Read-ClientJson (Join-Path $desktopOptions.LibraryPath "$($selected.desktop.profileId).json")
        Assert ($second.inferenceCredentialHelper -ceq $first.inferenceCredentialHelper) 'Project profiles do not share the helper'
        Assert ((Read-ClientJson $firstPath).inferenceCustomHeaders['X-Test-Project'] -ceq 'CCOFPILOT01') 'First project profile changed'
        Assert ($second.inferenceCustomHeaders['X-Test-Project'] -ceq 'CCOFPILOT02') 'Second project selector missing'
        $selected.project.id = $null
        Write-ClientJson $selectedPath $selected
        Set-CcofClaudeCode @options -Confirmed | Out-Null
        $cleared = Read-ClientJson (Join-Path $options.ClaudeHome 'settings.json')
        Assert ($cleared.env.ANTHROPIC_CUSTOM_HEADERS -notmatch 'X-Test-Project') 'Explicit no-selector profile retained a selector'
        Assert ($cleared.env.ANTHROPIC_CUSTOM_HEADERS -match 'X-Keep: one') 'Clearing selector removed unrelated headers'
    }
    Test-Case 'project header merging rejects malformed values, credential headers and unrelated conflicts' {
        $project = @{ id = 'CCOFPILOT01'; selectorHeader = 'X-Test-Project' }
        foreach ($source in @(42, 'not-a-header', @{ 'X-Other' = @('not', 'string') },
            "X-Other: one`rtwo", 'Authorization: synthetic', 'x-api-key: synthetic')) {
            Refuses { Merge-CcofProjectHeaders -Sources @($source) -Project $project } 'headers|credential'
        }
        Refuses { Merge-CcofProjectHeaders -Sources @('X-Other: one', 'X-Other: two') -Project $project } 'conflict'
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
