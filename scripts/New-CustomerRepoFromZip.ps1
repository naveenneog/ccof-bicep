<#
.SYNOPSIS
  Builds the customer ZIP from a commit, and publishes a ZIP to a private GitHub repository.
  See docs/runbooks/CICD-SETUP.md, section 9.

.DESCRIPTION
  -Mode Build   : `git archive` of -Ref into -OutFile, then a secret scan of the extracted tree. Any finding
                  deletes the ZIP and exits 3. Writes <OutFile>.manifest.json (commit, SHA-256, scanner).
  -Mode Publish : extracts -ZipPath, scans again, `git init -b main`, one commit, and pushes to the private
                  repository -Repository (owner/name). Preview by default; -Apply creates the repository
                  when it is missing (`gh repo create --private`) and pushes. A public or internal repository
                  is refused. A repository that already has commits is refused unless -Force, which
                  force-pushes main (use it to re-create the lab repository from a newer ZIP).
  The scanner is gitleaks when it is on PATH (`gitleaks dir`), otherwise scripts/SecretScan.psm1.
  Customer names and resource IDs may be in the ZIP; credentials may not.
  Exit codes: 0 ok, 2 refused (input or repository state), 3 secret found or a command failed.
#>
[CmdletBinding()]
param(
    [ValidateSet('Build', 'Publish')][string]$Mode = 'Build',
    [string]$RepoPath = (Split-Path $PSScriptRoot -Parent),
    [string]$Ref = 'HEAD',
    [string]$OutFile,
    [string]$ZipPath,
    [string]$Repository,
    [string]$RemoteUrl,
    [string]$CommitMessage,
    [switch]$NoGitleaks,
    [switch]$Force,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SecretScan.psm1') -Force
[Environment]::CurrentDirectory = (Get-Location).Path

function Stop-With([int]$Code, [string]$Message) { Write-Host $Message -ForegroundColor $(if ($Code -eq 0) { 'Green' } else { 'Red' }); exit $Code }

function Invoke-Scan([string]$Tree) {
    if (-not $NoGitleaks -and (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
        $out = & gitleaks dir $Tree --redact --no-banner --exit-code 3 2>&1 | Out-String
        $code = $LASTEXITCODE
        Write-Host $out
        return [pscustomobject]@{ scanner = 'gitleaks'; count = $(if ($code -eq 0) { 0 } else { 1 }); ok = ($code -eq 0) }
    }
    $r = Find-CcofSecrets -Path $Tree -AllowPatterns (Read-CcofSecretAllowList -Path $Tree)
    foreach ($f in $r.findings) { Write-Host "SECRET $($f.path):$($f.line) [$($f.rule)] $($f.excerpt)" -ForegroundColor Red }
    Write-Host "Secret scan (regex): $($r.scanned) text files scanned, $($r.skipped) binary or large files skipped, $(@($r.findings).Count) finding(s)."
    return [pscustomobject]@{ scanner = 'regex'; count = @($r.findings).Count; ok = (@($r.findings).Count -eq 0) }
}

function Expand-ToStaging([string]$Zip) {
    $staging = "$Zip.staging"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $Zip -DestinationPath $staging
    return $staging
}

function Invoke-Native([string]$Exe, [string[]]$ArgList) {
    $out = & $Exe @ArgList 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Stop-With 3 "$Exe $($ArgList -join ' ') failed ($LASTEXITCODE): $out" }
    return $out.Trim()
}

if ($Mode -eq 'Build') {
    if (-not $OutFile) { Stop-With 2 '-OutFile is required for -Mode Build.' }
    $OutFile = [IO.Path]::GetFullPath($OutFile)
    $commit = Invoke-Native git @('-C', $RepoPath, 'rev-parse', '--verify', "$Ref^{commit}")
    New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
    Invoke-Native git @('-C', $RepoPath, 'archive', '--format=zip', "--output=$OutFile", $commit) | Out-Null
    $staging = Expand-ToStaging $OutFile
    try { $scan = Invoke-Scan $staging } finally { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not $scan.ok) {
        Remove-Item -LiteralPath $OutFile -Force
        Stop-With 3 "Secret scan failed; ZIP deleted. Remove the secret from the commit (and rotate it), then rebuild."
    }
    $manifest = [ordered]@{
        schema = 'ccof.customer-zip.v1'; commit = $commit; ref = $Ref; zip = (Split-Path $OutFile -Leaf)
        sha256 = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLowerInvariant()
        scanner = $scan.scanner; builtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath "$OutFile.manifest.json" -Encoding utf8NoBOM
    Stop-With 0 "Built $OutFile from $commit (sha256 $($manifest.sha256)); secret scan clean ($($scan.scanner))."
}

# Publish
if (-not $ZipPath -or -not (Test-Path -LiteralPath $ZipPath)) { Stop-With 2 '-ZipPath must point to an existing ZIP for -Mode Publish.' }
if ($Repository -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { Stop-With 2 '-Repository must be owner/name.' }
$ZipPath = [IO.Path]::GetFullPath($ZipPath)
if (-not $RemoteUrl) { $RemoteUrl = "https://github.com/$Repository.git" }
if (-not $CommitMessage) { $CommitMessage = "Import $(Split-Path $ZipPath -Leaf)" }
$manifestPath = "$ZipPath.manifest.json"
if (Test-Path -LiteralPath $manifestPath) {
    $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($m.sha256 -ne $hash) { Stop-With 2 "ZIP SHA-256 $hash does not match the manifest ($($m.sha256))." }
    $CommitMessage += " (source commit $($m.commit))"
}

$staging = Expand-ToStaging $ZipPath
try {
    $scan = Invoke-Scan $staging
    if (-not $scan.ok) { Stop-With 3 'Secret scan failed; nothing was pushed.' }

    $view = & gh repo view $Repository --json visibility,isEmpty 2>&1 | Out-String
    $exists = ($LASTEXITCODE -eq 0)
    if ($exists) {
        $info = $view | ConvertFrom-Json
        if ($info.visibility -ne 'PRIVATE') { Stop-With 2 "$Repository is $($info.visibility); only a private repository is allowed." }
        if (-not $info.isEmpty -and -not $Force) { Stop-With 2 "$Repository already has commits. Re-run with -Force to replace main with this ZIP." }
    } elseif ($view -notmatch 'Could not resolve|not found|404') {
        Stop-With 3 "gh repo view $Repository failed: $view"
    }
    $plan = @(
        $(if ($exists) { "use existing private repository $Repository" } else { "gh repo create $Repository --private" }),
        "git init -b main and commit the ZIP contents ($CommitMessage)",
        "git push $(if ($Force) { '--force ' })$RemoteUrl main"
    )
    if (-not $Apply) {
        Write-Host 'Preview only. Re-run with -Apply to:'; $plan | ForEach-Object { Write-Host "  - $_" }
        Stop-With 0 'Preview complete.'
    }
    if (-not $exists) { Invoke-Native gh @('repo', 'create', $Repository, '--private', '--disable-wiki') | Out-Null }
    $g = @('-C', $staging, '-c', 'user.name=ccof-release', '-c', 'user.email=ccof-release@users.noreply.github.com', '-c', 'core.autocrlf=false')
    Invoke-Native git @('-C', $staging, 'init', '-q', '-b', 'main') | Out-Null
    Invoke-Native git ($g + @('add', '-A')) | Out-Null
    Invoke-Native git ($g + @('commit', '-q', '-m', $CommitMessage)) | Out-Null
    $push = @('-C', $staging, '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential', 'push', '-q', $RemoteUrl, 'main')
    if ($Force) { $push += '--force' }
    Invoke-Native git $push | Out-Null
    $head = Invoke-Native git @('-C', $staging, 'rev-parse', 'HEAD')
    Stop-With 0 "Pushed $head to $Repository main (scanner $($scan.scanner))."
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
