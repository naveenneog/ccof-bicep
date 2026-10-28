#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'ClientGateway.Common.ps1')
. (Join-Path $PSScriptRoot 'ClientProjectHeaders.ps1')

function New-CcofCodeEnvironment {
    param($Config, [string]$ConfigPath)
    $envs = @{
        ANTHROPIC_BASE_URL = $Config.gatewayUrl
        ANTHROPIC_MODEL = $Config.models.default
        CLAUDE_CODE_API_KEY_HELPER_TTL_MS = [string]($Config.helperTtlSeconds * 1000)
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = $(if ($Config.disableNonessentialTraffic) { '1' } else { '0' })
        CCOF_CONFIG_FILE = $ConfigPath
        CLAUDE_CODE_USE_FOUNDRY = '0'; CLAUDE_CODE_USE_BEDROCK = '0'; CLAUDE_CODE_USE_VERTEX = '0'
        CLAUDE_CODE_USE_ANTHROPIC_AWS = '0'; CLAUDE_CODE_USE_MANTLE = '0'
        ANTHROPIC_API_KEY = ''; ANTHROPIC_AUTH_TOKEN = ''; CLAUDE_CODE_OAUTH_TOKEN = ''
    }
    foreach ($alias in @('opus', 'sonnet', 'haiku')) {
        $prefix = "ANTHROPIC_DEFAULT_$($alias.ToUpperInvariant())_MODEL"
        $envs[$prefix] = $Config.models[$alias]
        $envs["$($prefix)_SUPPORTED_CAPABILITIES"] = if ($Config.models.capabilities) { [string]$Config.models.capabilities[$alias] } else { '' }
    }
    return $envs
}

function Set-CcofClaudeCode {
    param([string]$ConfigPath, [string]$ClaudeHome, [string]$VSCodeSettingsPath, [string]$BackupRoot,
        $Inventory, [string]$NodePath, [string]$TokenEntryPath, [ValidateSet('Helper', 'AzureCli')][string]$TokenSource = 'Helper', [switch]$Confirmed)
    Assert-ClientConfirmation -Confirmed:$Confirmed
    if (-not $Inventory.CliVersion -and -not $Inventory.VSCodeVersion) {
        return (@{ event = 'not_installed'; component = 'claude-code' } | ConvertTo-Json -Compress)
    }
    $config = if ($TokenSource -eq 'AzureCli') { Read-ClientConfigurationBasic $ConfigPath } else { Read-ClientConfiguration $ConfigPath }
    $path = Join-Path $ClaudeHome 'settings.json'
    $helper = Join-Path $ClaudeHome $(if ($TokenSource -eq 'AzureCli') { 'az-gateway-token.cmd' } else { 'ccof-token.cmd' })
    $settings = Read-ClientJson $path
    if ($settings.Contains('env') -and $settings.env -isnot [Collections.IDictionary]) { throw 'Claude Code env must be an object; nothing was changed.' }
    if (-not $settings.env) { $settings.env = @{} }
    $entries = @()
    if ($Inventory.VSCodeVersion) {
        $vscode = Read-ClientJson $VSCodeSettingsPath
        $entries = @($vscode['claudeCode.environmentVariables'])
        if ($entries.Count -eq 1 -and $null -eq $entries[0]) { $entries = @() }
        foreach ($entry in $entries) {
            if ($entry -isnot [Collections.IDictionary] -or -not $entry.name -or $entry.value -isnot [string]) {
                throw 'VS Code claudeCode.environmentVariables must be name/value objects; nothing was changed.'
            }
        }
    }
    $envs = New-CcofCodeEnvironment $config $ConfigPath
    if ($config.project) {
        $sources = @($settings.env.ANTHROPIC_CUSTOM_HEADERS) + @($entries |
            Where-Object { $_.name -eq 'ANTHROPIC_CUSTOM_HEADERS' } | ForEach-Object { $_.value })
        $headers = Merge-CcofProjectHeaders -Sources $sources -Project $config.project
        $envs.ANTHROPIC_CUSTOM_HEADERS = (@($headers.Keys | ForEach-Object { "${_}: $($headers[$_])" }) -join "`n")
    }
    foreach ($key in $envs.Keys) { $settings.env[$key] = $envs[$key] }
    foreach ($key in @('ANTHROPIC_FOUNDRY_RESOURCE', 'ANTHROPIC_FOUNDRY_BASE_URL',
        'ANTHROPIC_FOUNDRY_API_KEY', 'ANTHROPIC_FOUNDRY_AUTH_TOKEN')) { $settings.env.Remove($key) | Out-Null }
    $settings.apiKeyHelper = if ($TokenSource -eq 'AzureCli') { "`"$helper`"" } else { "`"$helper`" token" }
    $settings.model = $config.models.default
    $settings.availableModels = @($config.models.available)
    $settings.enforceAvailableModels = $true
    $shim = if ($TokenSource -eq 'AzureCli') { New-ClientAzureCliShim $config } else { New-ClientTokenShim $ConfigPath $NodePath $TokenEntryPath }
    $paths = @($path, $helper)
    if ($Inventory.VSCodeVersion) {
        $merged = @($entries | Where-Object {
            -not $envs.ContainsKey([string]$_.name) -and $_.name -notlike 'ANTHROPIC_FOUNDRY_*'
        })
        foreach ($key in ($envs.Keys | Sort-Object)) { $merged += @{ name = $key; value = $envs[$key] } }
        $vscode['claudeCode.environmentVariables'] = $merged
        $vscode['claudeCode.disableLoginPrompt'] = $true
        $paths += $VSCodeSettingsPath
    }
    $snapshot = New-ClientSnapshot 'claude-code' $paths $BackupRoot
    Write-ClientText $helper $shim
    Write-ClientJson $path $settings
    if ($Inventory.VSCodeVersion) { Write-ClientJson $VSCodeSettingsPath $vscode }
    Complete-ClientSnapshot $snapshot
    return (@{ event = 'configured'; component = 'claude-code'; changeId = $snapshot.Manifest.changeId; tokenSource = $TokenSource } | ConvertTo-Json -Compress)
}
