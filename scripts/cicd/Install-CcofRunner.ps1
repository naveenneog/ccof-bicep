#Requires -Version 5.1
<#
.SYNOPSIS
Bootstraps a CCOF self-hosted GitHub Actions runner on Windows Server 2022 (docs/runbooks/CICD-SETUP.md).
.DESCRIPTION
Windows counterpart of Install-CcofRunner.sh. The VM admin runs it in an elevated PowerShell on their own image;
no VM extension or custom data is used. Commands:
  install     Azure CLI (MSI), Node.js, PowerShell 7, Bicep and the runner (zip files pinned by SHA-256, downloaded
              or taken from -Stage). Git for Windows must already be installed (customer software baseline).
  register    job policy and job-started hook under ProgramData (admin-only write), runner .env, configure the
              runner as a Windows service. Needs $env:RUNNER_TOKEN (registration token); it is never written.
  status      service state, then Test-RunnerHost.ps1 next to this script.
  remove      unregister; $env:RUNNER_TOKEN is a remove token.
  print-hook  print the job-started hook (offline tests).
Exit codes: 0 ok, 2 input refused, 3 failed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('install', 'register', 'status', 'remove', 'print-hook')][string]$Command,
    [ValidateSet('preview', 'apply')][string]$Role,
    [string]$ClientId, [string]$SubscriptionId, [string]$TenantId, [string]$Repository,
    [string]$RunnerName = "$($env:COMPUTERNAME.ToLowerInvariant())", [string]$Labels,
    [string]$AllowedRefs = 'refs/heads/main', [string]$AllowedWorkflows = '',
    [string]$RunnerVersion = '2.338.2', [string]$RunnerSha256 = 'a1f17aa987fc8158bc7521d284912267a0d01b7c2c4684b33c86783b5e8221cc',
    [string]$NodeVersion = '22.23.5', [string]$NodeSha256 = '4a191082e9706866830379d577d2cc8a50c776fcd9436a8d061b063ed0d9a0e3',
    [string]$PwshVersion = '7.7.0', [string]$PwshSha256 = '7c74e03b20a75b59715847439d046a6214b1863ee79b187872980f139bb4a05f',
    [string]$BicepVersion = 'v0.46.1', [string]$BicepSha256 = '441d3d6094513acaa8a9be0b96b754d174bc0c19064c7be04e35b87e67b66250',
    [string]$AzMsi, [string]$AzSha256, [string]$Stage, [string]$Proxy, [string]$NoProxy, [string]$CaCert,
    [string]$RunnerDir = 'C:\actions-runner', [string]$ToolsDir = 'C:\ccof-tools'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$policyDir = Join-Path $env:ProgramData 'ccof-runner'
$imds = '169.254.169.254'
$defaultNoProxy = "localhost,127.0.0.1,$imds,168.63.129.16,.documents.azure.com,.azurewebsites.net,.azure-api.net,.vaultcore.azure.net,.cognitiveservices.azure.com,.services.ai.azure.com,.openai.azure.com"

$hookText = @'
# CCOF job-started hook (installed by scripts/cicd/Install-CcofRunner.ps1). A non-zero exit fails the job before any
# step runs. Policy: %ProgramData%\ccof-runner\policy (argument 1 overrides it for the offline tests).
param([string]$PolicyPath = (Join-Path $env:ProgramData 'ccof-runner\policy'))
function Deny([string]$Why) { [Console]::Error.WriteLine("ccof-runner: job refused: $Why"); exit 1 }
if (-not (Test-Path -LiteralPath $PolicyPath)) { Deny "policy file $PolicyPath is missing" }
$p = @{}; foreach ($l in Get-Content -LiteralPath $PolicyPath) { if ($l -match '^([A-Z_]+)=(.*)$') { $p[$Matches[1]] = $Matches[2].Trim('"') } }
$repo = "$($p['REPOSITORY'])"; $role = "$($p['RUNNER_ROLE'])"; $event = "$env:GITHUB_EVENT_NAME"; $ref = "$env:GITHUB_REF"; $wref = "$env:GITHUB_WORKFLOW_REF"
"ccof-runner: context role=$role repository=$env:GITHUB_REPOSITORY event=$event ref=$ref ref_type=$env:GITHUB_REF_TYPE head_ref=$env:GITHUB_HEAD_REF workflow_ref=$wref sha=$env:GITHUB_SHA workflow_sha=$env:GITHUB_WORKFLOW_SHA"
# Both runners reach IMDS and the VNet, so both are fail-closed (see Install-CcofRunner.sh).
if ($role -cnotin 'preview', 'apply') { Deny "policy RUNNER_ROLE '$role' is not preview or apply" }
$refs = @("$($p['ALLOWED_REFS'])".Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
$wfs = @("$($p['ALLOWED_WORKFLOWS'])".Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
if (-not $repo) { Deny 'policy has no REPOSITORY' }
if (-not $refs.Count) { Deny 'policy has no ALLOWED_REFS' }
if (-not $wfs.Count) { Deny 'policy has no ALLOWED_WORKFLOWS (the allow-list is required)' }
if ("$env:GITHUB_REPOSITORY" -cne $repo) { Deny "repository '$env:GITHUB_REPOSITORY' is not $repo" }
if ($event -cnotin 'push', 'workflow_dispatch', 'schedule') { Deny "event '$event' cannot run on a CCOF runner (pull_request jobs use GitHub-hosted runners)" }
if ("$env:GITHUB_HEAD_REF") { Deny 'a pull request head ref is set' }
if ("$env:GITHUB_REF_TYPE" -cne 'branch') { Deny "ref type '$env:GITHUB_REF_TYPE' is not branch" }
if ($refs -cnotcontains $ref) { Deny "ref '$ref' is not one of: $($refs -join ' ')" }
if (-not "$env:GITHUB_SHA" -or "$env:GITHUB_SHA" -cne "$env:GITHUB_WORKFLOW_SHA") { Deny "workflow commit '$env:GITHUB_WORKFLOW_SHA' is not the job commit '$env:GITHUB_SHA'" }
if (@($wfs | Where-Object { $wref -ceq "$repo/$_@$ref" }).Count -ne 1) { Deny "workflow '$wref' is not one of: $($wfs -join ' ') (at $ref)" }
"ccof-runner: $role runner, $event on $ref accepted."
exit 0
'@

function Refuse([string]$Why) { [Console]::Error.WriteLine("input refused: $Why"); exit 2 }
function Fail([string]$Why) { [Console]::Error.WriteLine("failed: $Why"); exit 3 }
function Want([string]$Name, [string]$Value, [string]$Pattern) { if ($Value -cnotmatch $Pattern) { Refuse "$Name '$Value' does not match $Pattern" } }

if ($Command -eq 'print-hook') { $hookText; exit 0 }
if (-not $Role) { Refuse '-Role preview or apply is required' }
foreach ($s in $RunnerSha256, $NodeSha256, $PwshSha256, $BicepSha256) { Want 'sha256' $s '^[0-9a-f]{64}$' }
Want 'RunnerVersion' $RunnerVersion '^\d+\.\d+\.\d+$'; Want 'NodeVersion' $NodeVersion '^22\.\d+\.\d+$'; Want 'PwshVersion' $PwshVersion '^7\.\d+\.\d+$'; Want 'BicepVersion' $BicepVersion '^v\d+\.\d+\.\d+$'
if ($Proxy) { Want 'Proxy' $Proxy '^https?://[A-Za-z0-9.:@_%-]+/?$' }
$noProxyAll = if ($NoProxy) { "$defaultNoProxy,$NoProxy" } else { $defaultNoProxy }
if (-not $Labels) { $Labels = "ccof-vnet,ccof-$Role" }
if ($Command -eq 'register') {
    Want 'ClientId' $ClientId $guid; Want 'SubscriptionId' $SubscriptionId $guid; Want 'TenantId' $TenantId $guid
    Want 'Repository' $Repository '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'; Want 'RunnerName' $RunnerName '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    Want 'Labels' $Labels '^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$'
    $other = if ($Role -eq 'preview') { 'apply' } else { 'preview' }
    if (",$Labels," -notlike "*,ccof-$Role,*" -or ",$Labels," -like "*,ccof-$other,*") { Refuse "labels must include ccof-$Role and not ccof-$other" }
    Want 'AllowedRefs' $AllowedRefs '^refs/heads/[A-Za-z0-9._/-]+( refs/heads/[A-Za-z0-9._/-]+)*$'
    Want 'AllowedWorkflows' $AllowedWorkflows '^\.github/workflows/[A-Za-z0-9._-]+( \.github/workflows/[A-Za-z0-9._-]+)*$'
}
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Refuse 'run in an elevated PowerShell (Administrator)' }
if ($Proxy) { $env:HTTPS_PROXY = $Proxy; $env:HTTP_PROXY = $Proxy; $env:NO_PROXY = $noProxyAll; [Net.WebRequest]::DefaultWebProxy = [Net.WebProxy]::new($Proxy, $true, $noProxyAll.Split(',')) }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-Pinned([string]$Name, [string]$Url, [string]$Sha) {
    $dl = Join-Path $ToolsDir 'dl'; New-Item -ItemType Directory -Force $dl | Out-Null
    $out = Join-Path $dl $Name
    if ($Stage -and (Test-Path -LiteralPath $Stage -PathType Container)) { Copy-Item -LiteralPath (Join-Path $Stage $Name) $out -Force }
    else {
        if ($Stage) { $Url = "$($Stage.TrimEnd('/'))/$Name" }
        try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $out } catch { Fail "download of $Url failed: $($_.Exception.Message) (egress allow-list, -Proxy, -CaCert)" }
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLowerInvariant() -cne $Sha) { Remove-Item $out -Force; Fail "$Name SHA-256 does not match the pinned value" }
    return $out
}
function Add-MachinePath([string]$Dir) {
    $p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($p -split ';') -notcontains $Dir) { [Environment]::SetEnvironmentVariable('Path', "$p;$Dir", 'Machine') }
    if (($env:Path -split ';') -notcontains $Dir) { $env:Path = "$env:Path;$Dir" }
}
function Test-Imds {
    try { $r = Invoke-WebRequest -UseBasicParsing -NoProxy -TimeoutSec 5 -Headers @{ Metadata = 'true' } -Uri "http://$imds/metadata/instance?api-version=2021-02-01" } catch { $r = $null }
    if (-not $r -or $r.StatusCode -ne 200) { Fail "IMDS $imds is not reachable: managed identity needs it; allow it in the host firewall and exclude it from the proxy" }
    'IMDS reachable'
}

switch ($Command) {
    'install' {
        if ($PSVersionTable.PSVersion.Major -ge 7) { Test-Imds } else { try { $null = Invoke-RestMethod -TimeoutSec 5 -Headers @{ Metadata = 'true' } -Uri "http://$imds/metadata/instance?api-version=2021-02-01" -Proxy $null; 'IMDS reachable' } catch { Fail "IMDS $imds is not reachable" } }
        if ($CaCert) { Import-Certificate -FilePath $CaCert -CertStoreLocation Cert:\LocalMachine\Root | Out-Null; 'corporate CA added to LocalMachine\Root' }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'Git for Windows is not installed: install it from the customer software baseline first' }
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            $msi = if ($AzMsi) { if (-not $AzSha256) { Refuse '-AzMsi needs -AzSha256' }; if ((Get-FileHash $AzMsi).Hash.ToLowerInvariant() -cne $AzSha256) { Fail '-AzMsi SHA-256 does not match' }; $AzMsi }
            else { $o = Join-Path $ToolsDir 'azure-cli.msi'; New-Item -ItemType Directory -Force $ToolsDir | Out-Null; Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/installazurecliwindowsx64' -OutFile $o; $o }
            $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
            if ($p.ExitCode -ne 0) { Fail "Azure CLI MSI exit code $($p.ExitCode)" }
            Add-MachinePath 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin'; 'Azure CLI installed'
        }
        $node = Join-Path $ToolsDir 'node'
        if (-not (Test-Path "$node\node.exe") -or (& "$node\node.exe" -v) -ne "v$NodeVersion") {
            $z = Get-Pinned "node-v$NodeVersion-win-x64.zip" "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip" $NodeSha256
            Remove-Item -Recurse -Force $node -ErrorAction SilentlyContinue; Expand-Archive $z (Join-Path $ToolsDir 'node-x') -Force
            Move-Item (Join-Path $ToolsDir "node-x\node-v$NodeVersion-win-x64") $node; Remove-Item -Recurse -Force (Join-Path $ToolsDir 'node-x'); "node v$NodeVersion installed"
        }
        $pwshDir = Join-Path $ToolsDir 'pwsh'
        if (-not (Test-Path "$pwshDir\pwsh.exe") -or (& "$pwshDir\pwsh.exe" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()') -ne $PwshVersion) {
            $z = Get-Pinned "PowerShell-$PwshVersion-win-x64.zip" "https://github.com/PowerShell/PowerShell/releases/download/v$PwshVersion/PowerShell-$PwshVersion-win-x64.zip" $PwshSha256
            Remove-Item -Recurse -Force $pwshDir -ErrorAction SilentlyContinue; Expand-Archive $z $pwshDir -Force; "pwsh $PwshVersion installed"
        }
        $bin = Join-Path $ToolsDir 'bin'; New-Item -ItemType Directory -Force $bin | Out-Null
        if (-not (Test-Path "$bin\bicep.exe") -or "$(& "$bin\bicep.exe" --version)" -notmatch [regex]::Escape($BicepVersion.TrimStart('v'))) {
            Copy-Item (Get-Pinned 'bicep-win-x64.exe' "https://github.com/Azure/bicep/releases/download/$BicepVersion/bicep-win-x64.exe" $BicepSha256) "$bin\bicep.exe" -Force; "bicep $BicepVersion installed"
        }
        foreach ($d in $node, $pwshDir, $bin) { Add-MachinePath $d }
        if (-not (Test-Path "$RunnerDir\.ccof-version") -or (Get-Content "$RunnerDir\.ccof-version") -ne $RunnerVersion) {
            $z = Get-Pinned "actions-runner-win-x64-$RunnerVersion.zip" "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip" $RunnerSha256
            New-Item -ItemType Directory -Force $RunnerDir | Out-Null; Expand-Archive $z $RunnerDir -Force; Set-Content "$RunnerDir\.ccof-version" $RunnerVersion; "runner $RunnerVersion installed in $RunnerDir"
        }
        New-Item -ItemType Directory -Force "$RunnerDir\_work\_tmp" | Out-Null
        Remove-Item -Recurse -Force (Join-Path $ToolsDir 'dl') -ErrorAction SilentlyContinue
    }
    'register' {
        if (-not (Test-Path "$RunnerDir\config.cmd")) { Fail 'runner is not installed: run install first' }
        if ("$env:RUNNER_TOKEN" -cnotmatch '^[A-Za-z0-9_-]{20,200}$') { Refuse 'RUNNER_TOKEN (registration token) is not set or malformed' }
        New-Item -ItemType Directory -Force $policyDir | Out-Null
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @(@('BUILTIN\Administrators', 'FullControl'), @('NT AUTHORITY\SYSTEM', 'FullControl'), @('BUILTIN\Users', 'ReadAndExecute'))) {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($r[0], $r[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        Set-Acl $policyDir $acl
        Set-Content (Join-Path $policyDir 'policy') "RUNNER_ROLE=$Role`nREPOSITORY=$Repository`nALLOWED_REFS=$AllowedRefs`nALLOWED_WORKFLOWS=$AllowedWorkflows" -Encoding ascii
        Set-Content (Join-Path $policyDir 'job-started.ps1') $hookText -Encoding utf8
        Push-Location $RunnerDir
        try {
            if (Test-Path .runner) { Remove-Item .runner, .credentials, .credentials_rsaparams -Force -ErrorAction SilentlyContinue; Get-Service 'actions.runner.*' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Service $_ -Force; & sc.exe delete $_.Name | Out-Null } }
            & .\config.cmd --unattended --url "https://github.com/$Repository" --token $env:RUNNER_TOKEN --name $RunnerName --labels $Labels --work _work --replace --runasservice | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail 'config.cmd failed: the registration token may be expired (1 hour) or for another repository' }
            $envLines = @("CCOF_RUNNER_ROLE=$Role", "CCOF_RUNNER_IDENTITY_CLIENT_ID=$ClientId", "CCOF_RUNNER_SUBSCRIPTION_ID=$SubscriptionId", "CCOF_RUNNER_TENANT_ID=$TenantId",
                "ACTIONS_RUNNER_HOOK_JOB_STARTED=$(Join-Path $policyDir 'job-started.ps1')", "TMP=$RunnerDir\_work\_tmp", "TEMP=$RunnerDir\_work\_tmp",
                'AZURE_BICEP_USE_BINARY_FROM_PATH=true', 'AZURE_BICEP_CHECK_VERSION=false', 'AZURE_CORE_COLLECT_TELEMETRY=false')
            if ($Proxy) { $envLines += "HTTPS_PROXY=$Proxy", "HTTP_PROXY=$Proxy", "NO_PROXY=$noProxyAll" }
            if ($CaCert) { $envLines += "NODE_EXTRA_CA_CERTS=$CaCert" }
            Set-Content .env $envLines -Encoding ascii
            Get-Service 'actions.runner.*' | Restart-Service -Force
            "registered $RunnerName ($Labels) to $Repository"
        } finally { Pop-Location }
    }
    'status' {
        $svc = Get-Service 'actions.runner.*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $svc) { Fail 'no runner service: run register' }
        "$($svc.Name) $($svc.Status)"; if ($svc.Status -ne 'Running') { Fail "runner service is $($svc.Status)" }
        $pre = Join-Path $PSScriptRoot 'Test-RunnerHost.ps1'
        if (Test-Path $pre) {
            foreach ($l in Get-Content "$RunnerDir\.env") { if ($l -match '^([^=]+)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2] } }
            & pwsh -NoProfile -File $pre; if ($LASTEXITCODE -ne 0) { Fail 'Test-RunnerHost.ps1 failed' }
        }
    }
    'remove' {
        if (-not $env:RUNNER_TOKEN) { Refuse 'RUNNER_TOKEN (a remove token) is not set' }
        Push-Location $RunnerDir; try { & .\config.cmd remove --token $env:RUNNER_TOKEN; if ($LASTEXITCODE -ne 0) { Fail 'config.cmd remove failed' } } finally { Pop-Location }
        'removed the runner registration'
    }
}
exit 0
