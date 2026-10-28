#Requires -Version 7.0
$script:ClientRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Read-ClientJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{} }
    try { $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'Invalid JSON configuration. Repair the original file before retrying; nothing was overwritten.' }
    if ($value -isnot [Collections.IDictionary]) { throw 'Configuration must be a JSON object.' }
    return $value
}

function Write-ClientText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $pending = "$Path.pending-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($pending, $Text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($pending, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force }
    }
}

function Write-ClientJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-ClientText $Path (($Value | ConvertTo-Json -Depth 100) + "`n")
}

function Get-ClientDefaultConfigPath {
    if ($env:CCOF_CONFIG_FILE) { return $env:CCOF_CONFIG_FILE }
    if (-not $env:LOCALAPPDATA) { throw 'Set CCOF_CONFIG_FILE to an absolute client configuration file path.' }
    return Join-Path $env:LOCALAPPDATA 'ClaudeGateway\config.json'
}

function Read-ClientConfiguration {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Client configuration path must be absolute.' }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { throw 'Node.js is missing. Ask the coordinator before installing it.' }
    $value = & $node.Source (Join-Path $script:ClientRepoRoot 'client\bin\validate-config.mjs') $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        throw 'Client configuration is missing or invalid. Review docs/CLIENTS.md and the administrator answers.'
    }
    return ($value | ConvertFrom-Json -AsHashtable)
}

function Assert-ClientConfirmation {
    param([switch]$Confirmed)
    if (-not $Confirmed) { throw 'No changes made. Review the target and rerun with -Confirmed to explicitly approve the change.' }
}

function Get-ClientFileHash {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return $null
}

function New-ClientSnapshot {
    param([string]$Kind, [string[]]$Paths, [string]$BackupRoot)
    $id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
    $directory = Join-Path $BackupRoot $id
    [void][IO.Directory]::CreateDirectory($directory)
    $records = @(); $index = 0
    foreach ($path in $Paths) {
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $backupFile = "$index.bin"
        if ($exists) { Copy-Item -LiteralPath $path -Destination (Join-Path $directory $backupFile) -ErrorAction Stop }
        $records += @{ path = [IO.Path]::GetFullPath($path); existed = $exists; backupFile = $backupFile
            beforeSha256 = Get-ClientFileHash $path; afterSha256 = $null }
        $index++
    }
    $snapshot = @{ schemaVersion = 1; kind = $Kind; changeId = $id; complete = $false; files = $records }
    Write-ClientJson (Join-Path $directory 'snapshot.json') $snapshot
    return @{ Directory = $directory; Manifest = $snapshot }
}

function Complete-ClientSnapshot {
    param($Snapshot)
    foreach ($record in $Snapshot.Manifest.files) { $record.afterSha256 = Get-ClientFileHash $record.path }
    $Snapshot.Manifest.complete = $true
    Write-ClientJson (Join-Path $Snapshot.Directory 'snapshot.json') $Snapshot.Manifest
}

function Restore-ClientSnapshot {
    param([Parameter(Mandatory)][string]$BackupPath, [Parameter(Mandatory)][string]$Kind,
        [switch]$Confirmed, [switch]$AllowChangedFiles)
    Assert-ClientConfirmation -Confirmed:$Confirmed
    $manifest = Read-ClientJson (Join-Path $BackupPath 'snapshot.json')
    if ($manifest.schemaVersion -ne 1 -or -not [string]::Equals($manifest.kind, $Kind, 'Ordinal') -or -not $manifest.files) {
        throw 'This backup does not match the requested client. Select its original snapshot directory.'
    }
    foreach ($record in $manifest.files) {
        if ($record.backupFile -notmatch '^\d+\.bin$' -or -not [IO.Path]::IsPathFullyQualified($record.path)) {
            throw 'Invalid backup manifest. No files restored.'
        }
        if ($record.existed -and -not [string]::Equals(
            (Get-ClientFileHash (Join-Path $BackupPath $record.backupFile)), $record.beforeSha256, 'Ordinal')) {
            throw 'Backup integrity check failed. No files restored.'
        }
        if (-not $AllowChangedFiles -and (-not $manifest.complete -or -not [string]::Equals(
            (Get-ClientFileHash $record.path), $record.afterSha256, 'Ordinal'))) {
            throw 'A configured file changed after setup, or setup was interrupted. Review it; use -AllowChangedFiles only to explicitly restore the original.'
        }
    }
    foreach ($record in $manifest.files) {
        if ($record.existed) { Copy-Item -LiteralPath (Join-Path $BackupPath $record.backupFile) -Destination $record.path -Force -ErrorAction Stop }
        elseif (Test-Path -LiteralPath $record.path) { Remove-Item -LiteralPath $record.path -Force -ErrorAction Stop }
    }
    return (@{ event = 'restored'; component = $Kind; changeId = $manifest.changeId } | ConvertTo-Json -Compress)
}

function New-ClientTokenShim {
    param([string]$ConfigPath, [string]$NodePath, [string]$TokenEntryPath)
    foreach ($value in @($ConfigPath, $NodePath, $TokenEntryPath)) {
        if (-not [IO.Path]::IsPathFullyQualified($value) -or $value -match '["\r\n]') { throw 'Helper paths must be absolute and contain no quotes or line breaks.' }
    }
    $config = $ConfigPath.Replace('%', '%%')
    $node = $NodePath.Replace('%', '%%')
    $entry = $TokenEntryPath.Replace('%', '%%')
    return "@echo off`r`nsetlocal DisableDelayedExpansion`r`nset `"CCOF_CONFIG_FILE=$config`"`r`n`"$node`" `"$entry`" %*`r`nexit /b %errorlevel%`r`n"
}

# Azure CLI token route (docs/runbooks/PUBLIC-ACCESS-WORKBOOK.md Step 13 A-refresh and 17.8d): the helper
# is docs/examples/az-gateway-token-auto-login.cmd with the tenant and gateway scope filled in. It needs
# the Azure CLI on PATH, not Node.js. The gateway app must preauthorize the Azure CLI client and APIM must
# list it as a delegated client (staged entra.allowAzureCliClient: true).
$script:ClientGuid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# The client file fields the Claude Code and Desktop settings use, checked without Node.js.
function Read-ClientConfigurationBasic {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Client configuration path must be absolute.' }
    $bad = 'Client configuration is missing or invalid. Review docs/CLIENTS.md and the administrator answers.'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $bad }
    try { $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw $bad }
    $ok = $c -is [Collections.IDictionary] -and $c.schemaVersion -eq 1 -and
        "$($c.tenantId)" -match $script:ClientGuid -and "$($c.clientId)" -match $script:ClientGuid -and
        $c.scope -is [string] -and $c.gatewayUrl -is [string] -and $c.gatewayUrl -cmatch '^https://[^\s"]+$'
    if (-not $ok) { throw $bad }
    foreach ($k in 'helperTtlSeconds', 'tokenTimeoutSeconds') { if (-not ($c[$k] -is [int] -or $c[$k] -is [long]) -or $c[$k] -le 0) { throw $bad } }
    $m = $c.models
    if ($m -isnot [Collections.IDictionary] -or @($m.available).Count -eq 0) { throw $bad }
    foreach ($alias in 'default', 'opus', 'sonnet', 'haiku') { if (@($m.available) -cnotcontains $m[$alias]) { throw $bad } }
    if ($c.desktop -isnot [Collections.IDictionary] -or "$($c.desktop.profileId)" -notmatch $script:ClientGuid -or -not "$($c.desktop.profileName)".Trim()) { throw $bad }
    if ($c.Contains('project') -and ($c.project -isnot [Collections.IDictionary] -or $c.project.selectorHeader -isnot [string])) { throw $bad }
    $null = Get-ClientAzureCliScope $c
    return $c
}

# The scope the Azure CLI requests: an identifier URI (az account get-access-token --scope).
function Get-ClientAzureCliScope {
    param($Config)
    $scope = [string]$Config.scope
    if ($scope -match '^[0-9a-fA-F-]{36}/[A-Za-z0-9][A-Za-z0-9_.-]*$') { $scope = "api://$scope" }
    # Written into a CMD file: no quotes, percent signs, carets or other cmd.exe syntax.
    if ($scope -cnotmatch '^(api|https)://[A-Za-z0-9._/-]+$') { throw 'Client configuration scope cannot be used with the Azure CLI helper.' }
    return $scope
}

function New-ClientAzureCliShim {
    param($Config)
    $template = [IO.File]::ReadAllText((Join-Path $script:ClientRepoRoot 'docs\examples\az-gateway-token-auto-login.cmd')).Replace("`r`n", "`n")
    $scopeLine = 'set "SCOPE=api://REPLACE-gateway-app-client-guid/access_as_user"'
    if (-not $template.Contains('set "TENANT=REPLACE-tenant-guid"') -or -not $template.Contains($scopeLine)) { throw 'Azure CLI helper template changed; no helper written.' }
    $text = $template.Replace('set "TENANT=REPLACE-tenant-guid"', "set `"TENANT=$($Config.tenantId)`"").Replace($scopeLine, "set `"SCOPE=$(Get-ClientAzureCliScope $Config)`"")
    return $text.Replace("`n", "`r`n")
}