#Requires -Version 7.0
<#
.SYNOPSIS
    Applies a group snapshot inside the VNet through a jump box's Run Command (docs/SYNC.md,
    "Without the Graph application permission").

.DESCRIPTION
    The workstation cannot reach Cosmos (public network access is disabled), so the snapshot, the
    settings file and the built sync code travel inside the Run Command script itself, each as a
    base64 block, and run there:
        node dist/sync/cli.js apply-snapshot --credential managed-identity ...
    with the jump box's managed identity for Cosmos (D3 gives private runners the sync's Cosmos
    access in delegated-snapshot mode). No credential travels.

    Size: Microsoft Learn documents no maximum for an action Run Command script or its parameters
    (checked 2026-10-11: "Run scripts in a Linux VM in Azure using action Run Commands", the
    az vm run-command reference and the RunCommandInput REST schema); it documents only that
    "Output is limited to the last 4,096 bytes". So -MaxScriptBytes is required and the script is
    refused above it; the run line is printed last so it survives the 4,096-byte tail.

    The runner must already have Node.js 22 or later from an approved image or package source: this
    script never downloads and runs an installer as root. Dependencies come from the committed lock
    file (integrity hashes) with install scripts disabled. The snapshot must match the SHA-256 the
    snapshot command printed, and src/sync must be committed; the audit line records the commit and
    the bundle's SHA-256. Exit code: 0 succeeded, 1 failed or no run line, 3 partial, 4 skipped.

.EXAMPLE
    pwsh -NoProfile -File infra/sync/Invoke-SnapshotApply.ps1 -AnswersFile infra/sync/sync.answers.pilot.json `
      -VmName ccof-jumpbox-sync -SnapshotPath .env.sync-snapshot.json -ExpectedSnapshotSha256 <sha256> `
      -SettingsPath .env.sync-apply-settings.json -MaxScriptBytes 262144 -AuditPath .env.sync-audit.jsonl
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AnswersFile,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')] [string] $VmName,
    [Parameter(Mandatory)] [string] $SnapshotPath,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{64}$')] [string] $ExpectedSnapshotSha256,
    [Parameter(Mandatory)] [string] $SettingsPath,
    [Parameter(Mandatory)] [ValidateRange(1024, 16777216)] [int] $MaxScriptBytes,
    [Parameter(Mandatory)] [string] $AuditPath,
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')] [string] $ClientId
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'SyncDeploy.psm1') -Force

function Get-Base64Block([byte[]] $Bytes) { [Convert]::ToBase64String($Bytes, [Base64FormattingOptions]::InsertLineBreaks) }
function Get-Sha256([byte[]] $Bytes) { (([Security.Cryptography.SHA256]::HashData($Bytes)) | ForEach-Object { $_.ToString('x2') }) -join '' }
function Stop-Apply([string] $Reason, [string] $Message, [System.Collections.IDictionary] $Extra = @{}) {
    $record = [ordered]@{ action = 'apply-snapshot'; outcome = 'refused'; reason = $Reason }
    foreach ($k in $Extra.Keys) { $record[$k] = $Extra[$k] }
    Write-SyncAudit -Path $AuditPath -Record $record
    throw $Message
}

$answers = Read-SyncAnswers -Path $AnswersFile
$problems = Test-SyncAnswers $answers
if ($problems.Count -gt 0) { Stop-Apply 'answers_invalid' "The answers file is incomplete or invalid: $($problems -join ', ')" }
foreach ($path in @($SnapshotPath, $SettingsPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-Apply 'file_missing' "Not found: $path" } }

# The file sent must be the file the snapshot command wrote.
$snapshotBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $SnapshotPath))
$snapshotSha = Get-Sha256 $snapshotBytes
if (-not [string]::Equals($snapshotSha, $ExpectedSnapshotSha256, 'OrdinalIgnoreCase')) {
    Stop-Apply 'snapshot_hash_mismatch' "The snapshot's SHA-256 is $snapshotSha, not the expected $ExpectedSnapshotSha256."
}
$settingsBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $SettingsPath))

# The built sync code: dist/sync/*.js with the lock file, so the runner installs the same versions.
Push-Location $repoRoot
try {
    npx tsc -p tsconfig.json | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Apply 'build_failed' 'The TypeScript build failed.' }
    $bundle = Join-Path $repoRoot '.env.sync-bundle.tgz'
    Remove-Item -Force -LiteralPath $bundle -ErrorAction SilentlyContinue
    $files = @('package.json', 'package-lock.json') + @(Get-ChildItem -Path dist/sync -Filter *.js | ForEach-Object { "dist/sync/$($_.Name)" })
    tar -czf $bundle @files
    if ($LASTEXITCODE -ne 0) { Stop-Apply 'bundle_failed' 'tar failed to bundle dist/sync.' }
    $bundleBytes = [IO.File]::ReadAllBytes($bundle)
    Remove-Item -Force -LiteralPath $bundle
}
finally { Pop-Location }
$bundleSha = Get-Sha256 $bundleBytes

$clientArg = if ($ClientId) { " --client-id $ClientId" } else { '' }
$script = @"
#!/bin/bash
set -euo pipefail
umask 077
WORK=/var/lib/ccof-sync-apply
rm -rf "`$WORK"; mkdir -p "`$WORK"; cd "`$WORK"
trap 'cd /; rm -rf "`$WORK"' EXIT
if ! command -v node >/dev/null 2>&1 || [ "`$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  echo "Node.js 22 or later is required on the runner; install it from an approved source first" >&2
  exit 5
fi
base64 -d > bundle.tgz <<'CCOF_B64'
$(Get-Base64Block $bundleBytes)
CCOF_B64
base64 -d > snapshot.json <<'CCOF_B64'
$(Get-Base64Block $snapshotBytes)
CCOF_B64
base64 -d > settings.json <<'CCOF_B64'
$(Get-Base64Block $settingsBytes)
CCOF_B64
tar -xzf bundle.tgz
if ! npm ci --omit=dev --ignore-scripts --no-audit --no-fund > npm.log 2>&1; then
  tail -n 20 npm.log >&2
  exit 6
fi
set +e
node dist/sync/cli.js apply-snapshot --snapshot snapshot.json --credential managed-identity --settings settings.json$clientArg
code=`$?
echo "apply-snapshot exit code `$code" >&2
exit `$code
"@
$script = $script.Replace("`r`n", "`n")
$scriptBytes = [Text.Encoding]::UTF8.GetByteCount($script)
if ($scriptBytes -gt $MaxScriptBytes) {
    Stop-Apply 'script_too_large' "The Run Command script is $scriptBytes bytes, above -MaxScriptBytes $MaxScriptBytes." ([ordered]@{ scriptBytes = $scriptBytes; maxScriptBytes = $MaxScriptBytes })
}
# The code sent must be a commit, so the apply can be traced.
$dirty = git -C $repoRoot status --porcelain -- src/sync
if ($dirty) { Stop-Apply 'source_not_committed' 'src/sync has uncommitted changes; commit them so the apply can be traced to a commit.' }
$commit = (git -C $repoRoot rev-parse HEAD).Trim()

$scriptFile = Join-Path $repoRoot '.env.sync-apply.sh'
try {
    [IO.File]::WriteAllText($scriptFile, $script, [Text.UTF8Encoding]::new($false))
    $raw = az vm run-command invoke --subscription $answers.subscriptionId --resource-group $answers.resourceGroup --name $VmName `
        --command-id RunShellScript --scripts "@$scriptFile" -o json 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-Apply 'run_command_failed' "az vm run-command invoke failed: $(($raw | Select-Object -Last 3) -join ' ')" }
}
finally { Remove-Item -Force -LiteralPath $scriptFile -ErrorAction SilentlyContinue }

$message = (($raw | Where-Object { $_ -is [string] }) -join "`n" | ConvertFrom-Json).value[0].message
$runLine = ($message -split "`n" | Where-Object { $_.StartsWith('{"schema":"ccof.sync.run.v1"') } | Select-Object -Last 1)
$run = if ($runLine) { $runLine | ConvertFrom-Json } else { $null }
Write-SyncAudit -Path $AuditPath -Record ([ordered]@{
        action = 'apply-snapshot'; outcome = if ($run) { $run.outcome } else { 'no_run_line' }; runId = $run.runId
        vmName = $VmName; snapshotSha256 = $snapshotSha; bundleSha256 = $bundleSha; commit = $commit; scriptBytes = $scriptBytes
    })
Write-Output $message
# az vm run-command invoke exits 0 whatever the script returned: the exit code follows the run line.
exit $(switch ($run.outcome) { 'succeeded' { 0 } 'partial' { 3 } 'skipped' { 4 } default { 1 } })
