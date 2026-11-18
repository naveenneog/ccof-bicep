#Requires -Version 7.2
<#
.SYNOPSIS
Preflight for a CCOF runner host (docs/runbooks/CICD-SETUP.md); PowerShell counterpart of Test-RunnerHost.sh.
.DESCRIPTION
Run it as the first step of every job on a Windows ccof-* runner, or after Install-CcofRunner.ps1. It changes
nothing on the host. Prints one PASS, FAIL, WARN or INFO line per check with its evidence; exits 1 when any
check fails. Defaults come from the runner environment (CCOF_RUNNER_IDENTITY_CLIENT_ID,
CCOF_RUNNER_SUBSCRIPTION_ID, CCOF_PRIVATE_FQDNS).
#>
[CmdletBinding()]
param(
    [string]$ClientId = $env:CCOF_RUNNER_IDENTITY_CLIENT_ID,
    [string]$SubscriptionId = $env:CCOF_RUNNER_SUBSCRIPTION_ID,
    [string[]]$PrivateFqdns = @("$env:CCOF_PRIVATE_FQDNS".Split(' ', [StringSplitOptions]::RemoveEmptyEntries)),
    [string]$BicepVersion,
    [int]$MinDiskGb = 10,
    [switch]$NoLogin,
    [string]$ImdsUri = 'http://169.254.169.254/metadata/instance?api-version=2021-02-01',
    [int]$TimeoutSec = 5
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:fails = 0
function Pass($n, $e) { "PASS ${n}: $e" }
function Bad($n, $e) { $script:fails++; "FAIL ${n}: $e" }
function Info($n, $e) { "INFO ${n}: $e" }
function Test-PrivateIp([string]$Ip) {
    $o = $Ip.Split('.'); if ($o.Count -ne 4) { return $false }
    $a = [int]$o[0]; $b = [int]$o[1]
    return ($a -eq 10) -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 192 -and $b -eq 168) -or ($a -eq 100 -and $b -ge 64 -and $b -le 127)
}
$guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

# 1. IMDS first, never through a proxy.
try { $r = Invoke-WebRequest -NoProxy -TimeoutSec $TimeoutSec -Headers @{ Metadata = 'true' } -Uri $ImdsUri; Pass 'imds' "HTTP $($r.StatusCode)" }
catch { Bad 'imds' "$ImdsUri not reachable ($($_.Exception.Message)): allow it in the host firewall and exclude it from the proxy" }
$proxy = "$env:HTTPS_PROXY$env:https_proxy"; $noProxy = ",$env:NO_PROXY,$env:no_proxy,"
# Only the proxy host:port is ever printed; a proxy with user:password@ is refused (credentials would reach job logs).
$proxyShown = (($proxy -replace '^[a-zA-Z]+://', '') -replace '^.*@', '') -replace '/.*$', ''
if ($proxy -match '@') { Bad 'proxy' 'HTTPS_PROXY contains credentials (user:password@, not shown): use an IP-allow-listed proxy' }
elseif ($proxy) { if ($noProxy -like '*,169.254.169.254,*') { Pass 'proxy' 'HTTPS_PROXY set; NO_PROXY includes 169.254.169.254' } else { Bad 'proxy' 'HTTPS_PROXY is set but NO_PROXY does not include 169.254.169.254' } }
else { Info 'proxy' 'no HTTPS_PROXY' }

# 2. Tools.
foreach ($t in 'git', 'az') { $c = Get-Command $t -ErrorAction SilentlyContinue; if ($c) { Pass "tool $t" $c.Source } else { Bad "tool $t" 'not on PATH' } }
$nv = try { (& node -v) 2>$null } catch { '' }
if ("$nv" -match '^v(\d+)' -and [int]$Matches[1] -ge 22) { Pass 'tool node' $nv } else { Bad 'tool node' "need Node.js 22 or later, found '$nv'" }
Pass 'tool pwsh' $PSVersionTable.PSVersion.ToString()
$bv = try { "$(& bicep --version 2>$null)" } catch { '' }
$bm = [regex]::Match($bv, '\d+\.\d+\.\d+').Value
if (-not $bm) { Bad 'tool bicep' 'not on PATH' } elseif ($BicepVersion -and $bm -ne $BicepVersion.TrimStart('v')) { Bad 'tool bicep' "found $bm, need $($BicepVersion.TrimStart('v'))" } else { Pass 'tool bicep' $bm }

# 3. Managed identity sign-in in a throwaway profile.
if ($NoLogin) { Info 'identity' 'skipped (-NoLogin)' }
elseif ("$ClientId" -notmatch $guid) { Bad 'identity' 'no identity client ID (CCOF_RUNNER_IDENTITY_CLIENT_ID or -ClientId)' }
elseif (Get-Command az -ErrorAction SilentlyContinue) {
    $cfg = Join-Path ($env:RUNNER_TEMP ?? [IO.Path]::GetTempPath()) ("preflight-az." + [guid]::NewGuid().ToString('n').Substring(0, 8))
    $old = $env:AZURE_CONFIG_DIR; $env:AZURE_CONFIG_DIR = $cfg
    try {
        $out = & az login --identity --client-id $ClientId --allow-no-subscriptions --output none 2>&1
        if ($LASTEXITCODE -ne 0) { Bad 'identity' "az login --identity --client-id $ClientId failed: $("$out".Trim() | Select-Object -Last 1)" }
        elseif ("$SubscriptionId" -match $guid) {
            & az account set --subscription $SubscriptionId 2>$null
            if ($LASTEXITCODE -eq 0) { Pass 'identity' "az login --identity $ClientId; subscription $SubscriptionId visible" } else { Bad 'identity' "signed in as $ClientId but subscription $SubscriptionId is not visible" }
        } else { Pass 'identity' "az login --identity $ClientId" }
        & az logout 2>$null | Out-Null
    } finally { $env:AZURE_CONFIG_DIR = $old; Remove-Item -Recurse -Force $cfg -ErrorAction SilentlyContinue }
}

# 4. Private DNS.
foreach ($f in $PrivateFqdns) {
    $ip = try { @([Net.Dns]::GetHostAddresses($f) | Where-Object AddressFamily -eq 'InterNetwork')[0].ToString() } catch { '' }
    if (-not $ip) { Bad "dns $f" 'does not resolve' } elseif (Test-PrivateIp $ip) { Pass "dns $f" "$ip (private)" } else { Bad "dns $f" "$ip is public: the privatelink zone is not linked to this VNet or the record is missing" }
}
if (-not $PrivateFqdns) { Info 'dns' 'no CCOF_PRIVATE_FQDNS given' }

# 5. GitHub (through the proxy, if any) and the clock against the GitHub Date header.
try {
    $g = Invoke-WebRequest -Method Head -TimeoutSec 15 -Uri 'https://api.github.com/'
    Pass 'github' "https://api.github.com HTTP $($g.StatusCode)$(if ($proxy) { " via proxy $proxyShown" })"
    $skew = [math]::Abs(([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse("$($g.Headers['Date'])")).TotalSeconds)
    if ($skew -le 300) { Pass 'clock' "skew $([int]$skew)s against api.github.com" } else { Bad 'clock' "skew $([int]$skew)s against api.github.com: check time sync" }
} catch { Bad 'github' "https://api.github.com: $($_.Exception.Message)" }

# 6. Disk space and executable temp directory.
$dir = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
$free = try { [IO.DriveInfo]::new([IO.Path]::GetPathRoot((Resolve-Path $dir).Path)).AvailableFreeSpace } catch { 0 }
if ($IsLinux) { $kb = (& df -Pk $dir 2>$null | Select-Object -Last 1) -split '\s+'; if ($kb.Count -ge 4) { $free = [long]$kb[3] * 1024 } }
if ($free -ge $MinDiskGb * 1GB) { Pass 'disk' "$([int]($free / 1GB)) GB free in $dir" } else { Bad 'disk' "$([int]($free / 1GB)) GB free in $dir, need $MinDiskGb" }
$tmp = [IO.Path]::GetTempPath()
if ($IsLinux) {
    $probe = Join-Path $tmp ("ccof-exec." + [guid]::NewGuid().ToString('n').Substring(0, 8))
    Set-Content $probe "#!/bin/sh`necho ok" -NoNewline; & chmod 700 $probe
    $ok = try { (& $probe) -eq 'ok' } catch { $false }
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    if ($ok) { Pass 'tmpdir' "$tmp allows executables" } else { Bad 'tmpdir' "$tmp does not allow executables (noexec): set TMPDIR inside the runner _work directory" }
} else { Info 'tmpdir' $tmp }

# 7. Host facts.
Info 'os' ([Runtime.InteropServices.RuntimeInformation]::OSDescription)
Info 'role' "CCOF_RUNNER_ROLE=$(if ($env:CCOF_RUNNER_ROLE) { $env:CCOF_RUNNER_ROLE } else { 'unset' })"
"Test-RunnerHost: $script:fails failed"
exit ([int]($script:fails -gt 0))
