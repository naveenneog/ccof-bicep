<#
.SYNOPSIS
  Publishes the admin console package from a VM inside the VNet, after Front Door Lockdown has turned
  off public access to the admin app (ADR 0037, docs/runbooks/ADMIN-UPDATE-FROM-VM.md).

.DESCRIPTION
  Runs in Cloud Shell. Sends infra/admin/vm/admin-update.sh to the VM with Azure Run Command; the VM
  signs in with its system-assigned identity, builds admin/ at a pushed commit and publishes it with
  OneDeploy through the admin app's private endpoint.

  -Phase Setup   Install git, curl, Azure CLI, Node.js 22 and PowerShell 7 on the VM, then Check. Needs -Apply.
  -Phase Check   Read-only: tools, identity sign-in, admin app read, private DNS of <app>.scm, outbound HTTPS.
  -Phase Update  Check, then build the admin package at -Commit (default: this checkout's HEAD, which must
                 be pushed) and publish it. Needs -Apply; without it, prints the plan.

  Exit codes: 0 succeeded, 1 failed on the VM (step and detail printed), 2 input or precondition refused,
  3 Run Command failed or returned no run line. Evidence: -EvidenceDirectory/admin-<phase>-<UTC>.json.

.EXAMPLE
  pwsh -NoProfile -File infra/admin/Update-AdminFromVm.ps1 -Phase Check -Subscription <id> -VmResourceGroup <rg> -VmName <vm> -AdminApp <app>
  pwsh -NoProfile -File infra/admin/Update-AdminFromVm.ps1 -Phase Update -Subscription <id> -VmResourceGroup <rg> -VmName <vm> -AdminApp <app> -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Setup', 'Check', 'Update')] [string]$Phase,
    [Parameter(Mandatory)] [string]$Subscription,
    [Parameter(Mandatory)] [string]$VmResourceGroup,
    [Parameter(Mandatory)] [string]$VmName,
    [Parameter(Mandatory)] [string]$AdminApp,
    [string]$AdminResourceGroup,
    [string]$Commit,
    [string]$RepoUrl,
    [string]$EvidenceDirectory = (Join-Path $HOME 'ccof-admin-updates'),
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Stop-Upd([string]$Message, [int]$Code) { [Console]::Error.WriteLine($Message); exit $Code }
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'AdminVmUpdate.psm1') -Force
Import-Module (Join-Path $repoRoot 'infra/dr/DrPrerequisites.psm1') -Force

if (-not $AdminResourceGroup) { $AdminResourceGroup = $VmResourceGroup }
if (-not $RepoUrl) { $RepoUrl = "$(git -C $repoRoot remote get-url origin 2>$null)".Trim() -replace '\.git$', '' }
if ($Phase -eq 'Update' -and -not $Commit) { $Commit = "$(git -C $repoRoot rev-parse HEAD 2>$null)".Trim() }
$values = [ordered]@{ Subscription = $Subscription; ResourceGroup = $AdminResourceGroup; VmName = $VmName; App = $AdminApp; Commit = $Commit; RepoUrl = $RepoUrl }
$problems = @(Get-AdminVmInputProblems $values -RequireCommit:($Phase -eq 'Update'))
if (-not ($VmResourceGroup -cmatch '^[A-Za-z0-9._-]{1,90}$')) { $problems += "VmResourceGroup: '$VmResourceGroup' does not match ^[A-Za-z0-9._-]{1,90}$" }
if ($problems.Count) { Stop-Upd "input_refused: $($problems -join '; ')" 2 }
if ($Phase -eq 'Update') {
    # The VM clones the repository, so the commit must be on the remote.
    $remote = @(git -C $repoRoot branch -r --contains $Commit 2>$null | Where-Object { "$_".Trim() })
    if (-not $remote.Count) { Stop-Upd "commit_not_pushed: $Commit is not on any remote branch of this checkout. Push it (git push), run git fetch, and rerun." 2 }
}
$azProfile = Resolve-DrAzureProfile -ConfigDir $env:AZURE_CONFIG_DIR -CloudShell $env:ACC_CLOUD -HomePath $HOME
if (-not $azProfile.Ok) { Stop-Upd $azProfile.Message 2 }
$env:AZURE_CONFIG_DIR = $azProfile.ConfigDir

function Invoke-UpdAz([string[]]$Arguments) {
    $out = & az @Arguments --output json --only-show-errors 2>&1
    $code = $LASTEXITCODE
    $text = (@($out | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n").Trim()
    $err = (@($out | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) -join ' ').Trim()
    if ($code -ne 0) { throw "az $($Arguments[0..2] -join ' ') failed: $($err.Substring(0, [Math]::Min(400, $err.Length)))" }
    if (-not $text) { return $null }
    return $text | ConvertFrom-Json -Depth 50
}

Write-Host "== admin update $Phase$(if ($Phase -ne 'Check' -and -not $Apply) { ' (preview)' }): VM $VmName ($VmResourceGroup), app $AdminApp ($AdminResourceGroup)$(if ($Phase -eq 'Update') { ", commit $Commit" })"
try { $view = Invoke-UpdAz @('vm', 'get-instance-view', '--subscription', $Subscription, '--resource-group', $VmResourceGroup, '--name', $VmName) }
catch { Stop-Upd "vm_unreadable: $_" 2 }
$power = @($view.instanceView.statuses | Where-Object { "$($_.code)".StartsWith('PowerState/') } | ForEach-Object { $_.code }) | Select-Object -First 1
if ($power -cne 'PowerState/running') { Stop-Upd "vm_not_running: $VmName is '$power'. Start it: az vm start --subscription $Subscription --resource-group $VmResourceGroup --name $VmName" 2 }
if ($Phase -ne 'Check' -and -not $Apply) {
    if ($Phase -eq 'Setup') { Write-Host 'preview: install the missing tools on the VM (apt, Azure CLI, Node.js 22, PowerShell 7), then run Check. Rerun with -Apply.' }
    else { Write-Host "preview: Check, then on the VM clone $RepoUrl at $Commit, build admin/ (admin/Build-AdminPackage.ps1, with unit tests) and publish it to $AdminApp with OneDeploy. Rerun with -Apply." }
    exit 0
}

$script = New-AdminVmScript -Phase $Phase.ToLowerInvariant() -Values $values
$file = Join-Path ([IO.Path]::GetTempPath()) "ccof-admin-update-$([guid]::NewGuid().ToString('N')).sh"
$started = [DateTime]::UtcNow.ToString('o')
try {
    [IO.File]::WriteAllText($file, $script, [Text.UTF8Encoding]::new($false))
    $result = Invoke-UpdAz @('vm', 'run-command', 'invoke', '--subscription', $Subscription, '--resource-group', $VmResourceGroup, '--name', $VmName, '--command-id', 'RunShellScript', '--scripts', "@$file")
} catch { Stop-Upd "run_command_failed: $_" 3 }
finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }

$message = (@($result.value) | ForEach-Object { "$($_.message)" }) -join "`n"
$run = Read-AdminVmRunLine $message
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$evidenceFile = Join-Path $EvidenceDirectory "admin-$($Phase.ToLowerInvariant())-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).json"
[ordered]@{ schema = 'ccof.admin.vmupdate.evidence.v1'; phase = $Phase; vm = $VmName; vmResourceGroup = $VmResourceGroup; app = $AdminApp; appResourceGroup = $AdminResourceGroup
    commit = $Commit; repoUrl = $RepoUrl; startedAt = $started; completedAt = [DateTime]::UtcNow.ToString('o'); run = $run; message = $message } |
    ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidenceFile -Encoding utf8NoBOM
if (-not $run) { Write-Host $message; Stop-Upd "no_run_line: the VM returned no result line (evidence: $evidenceFile). Run Command needs outbound HTTPS from the VM to Azure (service tag AzureCloud)." 3 }
foreach ($n in @("$($run.notes)" -split '; ' | Where-Object { $_ })) { Write-Host "  $n" }
Write-Host "evidence: $evidenceFile"
if ($run.outcome -cne 'succeeded') {
    $tail = @(($message -split "`n") | Where-Object { $_ -and -not $_.StartsWith('{"schema"') } | Select-Object -Last 14)
    $tail | ForEach-Object { Write-Host "  | $_" }
    Stop-Upd "failed at $($run.step): $($run.detail) (VM log: $($run.log))" 1
}
Write-Host "result: $Phase succeeded$(if ($run.sha256) { "; package sha256 $($run.sha256)" })" -ForegroundColor Green
