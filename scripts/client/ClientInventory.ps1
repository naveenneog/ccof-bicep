#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'ClientGateway.Common.ps1')

function Get-CcofClientInventory {
    $result = @{ CliVersion = $null; CliPath = $null; VSCodeVersion = $null
        DesktopVersion = $null; DesktopBundles = @() }
    $claude = @(Get-Command claude -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -match '\.(exe|cmd|ps1)$' }) | Select-Object -First 1
    if ($claude) {
        $banner = & $claude.Source --version 2>$null
        if ($LASTEXITCODE -eq 0 -and "$banner" -match '(\d+\.\d+\.\d+)') {
            $result.CliVersion = $Matches[1]; $result.CliPath = $claude.Source
        }
    }
    $code = Get-Command code -ErrorAction SilentlyContinue
    if ($code) {
        $extensions = & $code.Source --list-extensions --show-versions 2>$null
        $match = @($extensions | Where-Object { $_ -match '^anthropic\.claude-code@' }) | Select-Object -First 1
        if ($LASTEXITCODE -eq 0 -and $match -match '@(\d+\.\d+\.\d+)') { $result.VSCodeVersion = $Matches[1] }
    }
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return $result }
    $candidates = @()
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        foreach ($package in @(Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue)) {
            foreach ($relative in @('app\resources\app.asar', 'resources\app.asar')) {
                $bundle = Join-Path $package.InstallLocation $relative
                if (Test-Path -LiteralPath $bundle) { $candidates += @{ Bundle = $bundle; Version = "$($package.Version)" } }
            }
        }
    }
    $perUser = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (Test-Path $perUser) {
        $latest = Get-ChildItem $perUser -Directory -Filter 'app-*' |
            Where-Object { $_.Name -match '^app-\d+\.\d+\.\d+' } |
            Sort-Object { [version]($_.Name -replace '^app-', '') } -Descending | Select-Object -First 1
        if ($latest) { $candidates += @{ Bundle = Join-Path $latest.FullName 'resources\app.asar'; Version = $latest.Name -replace '^app-', '' } }
    }
    $exePaths = @((Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'))
    $exePaths += @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath } | Select-Object -ExpandProperty ExecutablePath)
    foreach ($exe in $exePaths) {
        $bundle = Join-Path (Split-Path $exe -Parent) 'resources\app.asar'
        if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $bundle)) {
            $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion
            if ($version -match '(\d+\.\d+\.\d+(?:\.\d+)?)') {
                $candidates += @{ Bundle = $bundle; Version = $Matches[1] }
            }
        }
    }
    $candidates = @($candidates | Where-Object { Test-Path -LiteralPath $_.Bundle } | Sort-Object { [version]$_.Version })
    if ($candidates.Count) {
        $result.DesktopVersion = $candidates[0].Version
        $result.DesktopBundles = @($candidates.Bundle | Select-Object -Unique)
    }
    return $result
}

function Get-CcofInstalledDesktopSchema {
    param($Inventory)
    if (-not $Inventory.DesktopBundles.Count) { throw 'No installed Desktop bundle could be verified. No profile written.' }
    $schemas = @()
    foreach ($bundle in $Inventory.DesktopBundles) {
        $json = & node (Join-Path $script:ClientRepoRoot 'client\bin\inspect-desktop.mjs') $bundle 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'The installed Desktop schema is unrecognized. No profile written.' }
        $schemas += ($json | ConvertFrom-Json -AsHashtable)
    }
    $keys = @($schemas[0].keys); $kinds = @($schemas[0].credentialKinds)
    foreach ($schema in $schemas) {
        $keys = @($keys | Where-Object { $schema.keys -ccontains $_ })
        $kinds = @($kinds | Where-Object { $schema.credentialKinds -ccontains $_ })
    }
    return @{ keys = $keys; credentialKinds = $kinds }
}

# The helper-script profile keys documented for Desktop's third-party inference profiles; used only
# when Node.js is unavailable to inspect the installed bundle (Set-ClaudeDesktopGateway.ps1 -TokenSource AzureCli).
function Get-CcofKnownDesktopHelperSchema {
    return @{ credentialKinds = @('helper-script')
        keys = @('inferenceProvider', 'inferenceGatewayBaseUrl', 'inferenceGatewayAuthScheme', 'inferenceModels',
            'inferenceCredentialKind', 'inferenceCredentialHelper', 'inferenceCredentialHelperArgs',
            'inferenceCredentialHelperTtlSec', 'inferenceCredentialHelperTimeoutSec',
            'inferenceCredentialHelperSilentRefreshEnabled', 'inferenceCustomHeaders') }
}

function Assert-NoCcofManagedDesktopPolicy {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return }
    foreach ($key in @('HKLM:\SOFTWARE\Policies\Claude', 'HKCU:\SOFTWARE\Policies\Claude')) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $names = (Get-Item -LiteralPath $key -ErrorAction Stop).GetValueNames()
        if (@($names | Where-Object { $_ -match '^(inference|bootstrap)' }).Count) {
            throw 'Managed Desktop inference policy overrides local profiles. Ask its administrator to change it; no registry values were modified.'
        }
    }
}
