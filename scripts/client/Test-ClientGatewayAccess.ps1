#Requires -Version 7.0
[CmdletBinding()]
param([string]$ConfigPath, [switch]$Confirmed)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClientGateway.Common.ps1')
. (Join-Path $PSScriptRoot 'ClientInventory.ps1')
. (Join-Path $PSScriptRoot 'ClientProcess.ps1')
Assert-ClientConfirmation -Confirmed:$Confirmed
if (-not $ConfigPath) { $ConfigPath = Get-ClientDefaultConfigPath }
$config = Read-ClientConfiguration $ConfigPath
$inventory = Get-CcofClientInventory
$node = (Get-Command node -ErrorAction Stop).Source
$entry = Join-Path $script:ClientRepoRoot 'client\bin\ccof-token.mjs'
$work = Join-Path $script:ClientRepoRoot ('client\.test-work\live-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$token = $null
try {
    $silent = Invoke-CcofChild -FilePath $node -Arguments @($entry, 'token') -WorkingDirectory $work `
        -TimeoutSeconds ([Math]::Min(600, $config.tokenTimeoutSeconds * 3)) `
        -Environment @{ CCOF_CONFIG_FILE = $ConfigPath }
    if ($silent.ExitCode -ne 0 -or $silent.Stdout.Trim() -notmatch '^\S+$' -or $silent.Stderr) {
        @{ event = 'verification_failed'; stage = 'silent-token'; reason = 'run_ccof_token_login' } | ConvertTo-Json -Compress
        exit 1
    }
    $token = $silent.Stdout.Trim()
    $silent.Stdout = ''
    @{ event = 'verified'; stage = 'silent-child-token' } | ConvertTo-Json -Compress
    $body = @{ model = $config.models.haiku; max_tokens = 8
        messages = @(@{ role = 'user'; content = 'Reply with OK' }) } | ConvertTo-Json -Depth 5 -Compress
    try {
        $response = Invoke-WebRequest -Method Post -Uri "$($config.gatewayUrl)/v1/messages" `
            -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01' } `
            -ContentType 'application/json' -Body $body -TimeoutSec $config.tokenTimeoutSeconds `
            -MaximumRedirection 0 -SkipHttpErrorCheck
        $status = [int]$response.StatusCode
        $response = $null
    } catch { throw 'Gateway transport failed. No headers or response body were logged.' }
    $token = $null
    @{ event = 'gateway_result'; stage = 'messages'; httpStatus = $status } | ConvertTo-Json -Compress
    $cliOk = $true
    if ($inventory.CliVersion) {
        $cli = Invoke-CcofChild -FilePath $inventory.CliPath -Arguments @('-p', 'Reply with OK',
            '--model', $config.models.haiku, '--tools', '', '--disable-slash-commands',
            '--strict-mcp-config', '--no-session-persistence', '--setting-sources', 'user') `
            -WorkingDirectory $work -TimeoutSeconds ([Math]::Min(600, $config.loginTimeoutSeconds)) `
            -Environment @{ CCOF_CONFIG_FILE = $ConfigPath }
        $cliOk = $cli.ExitCode -eq 0 -and $cli.Stdout.Trim() -ceq 'OK'
        @{ event = 'claude_code_result'; ok = $cliOk; exitCode = $cli.ExitCode; timedOut = $cli.TimedOut } | ConvertTo-Json -Compress
    } else { @{ event = 'not_installed'; component = 'claude-code' } | ConvertTo-Json -Compress }
    if ($status -ne 200 -or -not $cliOk) { exit 1 }
} finally {
    $token = $null
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
