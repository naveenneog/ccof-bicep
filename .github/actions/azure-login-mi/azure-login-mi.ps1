# Windows body of .github/actions/azure-login-mi; same contract as azure-login-mi.sh.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
function Fail([string]$Why) { "::error title=azure-login-mi::$Why"; exit 1 }
if (-not $env:RUNNER_TEMP -or -not $env:GITHUB_ENV) { Fail 'RUNNER_TEMP or GITHUB_ENV is not set: run this inside a GitHub Actions job' }
$mode = if ($env:IN_MODE) { $env:IN_MODE } else { 'login' }
if ($mode -eq 'logout') {
    $dir = "$env:AZURE_CONFIG_DIR"
    if (-not $dir) { 'No per-job Azure CLI profile to remove.'; exit 0 }
    if (-not $dir.StartsWith((Join-Path $env:RUNNER_TEMP 'azcfg.'), [StringComparison]::OrdinalIgnoreCase)) { Fail "AZURE_CONFIG_DIR '$dir' was not created by this action; not removed." }
    & az logout 2>$null | Out-Null; & az account clear 2>$null | Out-Null
    Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue
    Add-Content $env:GITHUB_ENV 'AZURE_CONFIG_DIR='
    'Signed out; removed the per-job Azure CLI profile.'; exit 0
}
if ($mode -ne 'login') { Fail "mode must be login or logout, not '$mode'" }
$role = "$env:CCOF_RUNNER_ROLE"
if ($role -notin 'preview', 'apply') { Fail 'this runner has no CCOF_RUNNER_ROLE (preview or apply): it was not set up by scripts/cicd/Install-CcofRunner.ps1' }
if ($env:IN_ROLE -and $env:IN_ROLE -ne $role) { Fail "the job expects the $env:IN_ROLE identity but runs on a $role runner; check runs-on (ccof-$env:IN_ROLE label)" }
$clientId = if ($env:IN_CLIENT_ID) { $env:IN_CLIENT_ID } else { "$env:CCOF_RUNNER_IDENTITY_CLIENT_ID" }
$sub = if ($env:IN_SUBSCRIPTION_ID) { $env:IN_SUBSCRIPTION_ID } else { "$env:CCOF_RUNNER_SUBSCRIPTION_ID" }
if ($clientId -notmatch $guid) { Fail "identity client ID '$clientId' is not a GUID" }
if ($sub -notmatch $guid) { Fail "subscription ID '$sub' is not a GUID" }
$dir = Join-Path $env:RUNNER_TEMP ('azcfg.' + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory $dir | Out-Null
$env:AZURE_CONFIG_DIR = $dir
Add-Content $env:GITHUB_ENV "AZURE_CONFIG_DIR=$dir", 'AZURE_CORE_COLLECT_TELEMETRY=false'
& az login --identity --client-id $clientId --output none
if ($LASTEXITCODE -ne 0) { Fail "az login --identity failed for client ID ${clientId}: is this identity attached to the runner VM?" }
& az account set --subscription $sub
if ($LASTEXITCODE -ne 0) { Fail "subscription $sub is not visible to identity ${clientId}: it needs a role in that subscription" }
$tenant = & az account show --query tenantId --output tsv
if ($env:GITHUB_OUTPUT) { Add-Content $env:GITHUB_OUTPUT "client-id=$clientId", "subscription-id=$sub", "tenant-id=$tenant", "role=$role" }
"Signed in with the $role runner identity $clientId (tenant $tenant, subscription $sub) in a per-job profile."
