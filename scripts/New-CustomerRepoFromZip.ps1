<#
.SYNOPSIS
  Builds the customer ZIP from a commit, and publishes a ZIP to a private GitHub repository.
  See docs/runbooks/CICD-SETUP.md, section 9.

.DESCRIPTION
  -Mode Build   : `git archive` of -Ref into -OutFile, the ZIP entry check and the secret scan. A refused entry
                  or a finding deletes the ZIP. Writes <OutFile>.manifest.json (commit, SHA-256, scanner).
  -Mode Publish : checks the ZIP entries before any git or gh command (no .git metadata, links, absolute or ..
                  paths, duplicates), extracts to a new directory, scans again, commits the files with an
                  isolated git configuration (no hooks, no global or system config, no filters), checks that
                  the commit holds exactly the extracted files and bytes, and pushes main to
                  https://github.com/<owner>/<name>.git after `gh repo view` confirms that repository and that
                  it is private. Preview by default; -Apply creates a missing repository with
                  `gh repo create --private` and pushes.
                  An empty repository gets main with a lease that main does not exist. A repository with
                  commits is refused unless -ReplaceMainAt <sha> names its current main commit; the push then
                  replaces main with --force-with-lease=main:<sha>, so a main that moved is not overwritten.
  The secret scan is scripts/SecretScan.psm1 (always), plus gitleaks when it is on PATH. Unscanned files
  fail the scan. Exceptions come only from -AllowList, an operator file outside the ZIP with exact entries.
  Exit codes: 0 ok, 2 refused (input or repository state), 3 secret found, unscanned file, or a command failed.
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
    [string]$ReplaceMainAt,
    [string]$AllowList,
    [string]$CommitMessage,
    [switch]$NoGitleaks,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SecretScan.psm1') -Force
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
[Environment]::CurrentDirectory = (Get-Location).Path
$script:work = $null

function Stop-With([int]$Code, [string]$Message) {
    if ($script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host $Message -ForegroundColor $(if ($Code -eq 0) { 'Green' } else { 'Red' }); exit $Code
}

function Invoke-Native([string]$Exe, [string[]]$ArgList) {
    $out = & $Exe @ArgList 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Stop-With 3 "$Exe $($ArgList -join ' ') failed ($LASTEXITCODE): $out" }
    return $out.Trim()
}

function Get-ZipPayload([string]$Zip) {
    # Returns the file paths in the ZIP, or the reasons it is refused. Reads the central directory only.
    $files = [Collections.Generic.List[string]]::new(); $bad = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try { $za = [IO.Compression.ZipFile]::OpenRead($Zip) } catch { return @{ files = @(); bad = @("not a readable ZIP: $($_.Exception.Message)") } }
    try {
        foreach ($e in $za.Entries) {
            $n = $e.FullName
            if ($n -match '[\\:\x00-\x1f]' -or $n.StartsWith('/')) { $bad.Add("$n : absolute path, backslash, colon or control character"); continue }
            $parts = $n.TrimEnd('/').Split('/')
            if (@($parts | Where-Object { $_ -in @('', '.', '..') }).Count) { $bad.Add("$n : empty, . or .. path component"); continue }
            if (@($parts | Where-Object { $_.TrimEnd('.', ' ') -ieq '.git' -or $_ -imatch '^git~\d+$' }).Count) { $bad.Add("$n : git metadata (.git) is not allowed"); continue }
            if ((($e.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { $bad.Add("$n : symbolic link"); continue }
            if (-not $seen.Add($n.TrimEnd('/'))) { $bad.Add("$n : duplicate entry"); continue }
            if (-not $n.EndsWith('/')) { $files.Add($n) }
        }
    } finally { $za.Dispose() }
    return @{ files = @($files | Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture)); bad = $bad.ToArray() }
}

function Expand-Payload([string]$Zip, [string[]]$Expected) {
    # Extracts into a new directory that only this run owns ($script:work); nothing else is deleted.
    $script:work = Join-Path (Split-Path $Zip) ('.ccof-zip-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:work -ErrorAction Stop | Out-Null
    $payload = Join-Path $script:work 'payload'
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $payload)
    $items = @(Get-ChildItem -LiteralPath $payload -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { Stop-With 2 'Refused: the extracted payload contains a link or junction.' }
    $got = @($items | Where-Object { -not $_.PSIsContainer } | ForEach-Object { [IO.Path]::GetRelativePath($payload, $_.FullName).Replace('\', '/') })
    if ((@($got | Sort-Object) -join "`n") -ne (@($Expected | Sort-Object) -join "`n")) { Stop-With 2 'Refused: the extracted files differ from the ZIP entries.' }
    return $payload
}

function Invoke-Scan([string]$Tree) {
    $allow = @(); if ($AllowList) { $allow = @(Read-CcofSecretAllowList -Path $AllowList -ScannedRoot $Tree) }
    $r = Find-CcofSecrets -Path $Tree -Allow $allow
    foreach ($f in $r.findings) { Write-Host "SECRET $($f.path):$($f.line) [$($f.rule)] $($f.excerpt) sha256 $($f.sha256)" -ForegroundColor Red }
    foreach ($u in $r.unscanned) { Write-Host "UNSCANNED $($u.path): $($u.reason)$(if ($u.sha256) { " sha256 $($u.sha256)" })" -ForegroundColor Red }
    Write-Host "Secret scan (regex): $($r.scanned) file(s) scanned, $(@($r.unscanned).Count) unscanned, $(@($r.findings).Count) finding(s), $($r.allowed) allow-listed."
    $ok = (@($r.findings).Count -eq 0 -and @($r.unscanned).Count -eq 0); $scanner = 'regex'
    if (-not $NoGitleaks -and (Get-Command gitleaks -CommandType Application -ErrorAction SilentlyContinue)) {
        $out = & gitleaks dir $Tree --redact --no-banner --exit-code 3 2>&1 | Out-String
        Write-Host $out; $scanner = 'regex+gitleaks'
        if ($LASTEXITCODE -ne 0) { $ok = $false }
    }
    return [pscustomobject]@{ scanner = $scanner; ok = $ok }
}

if ($Mode -eq 'Build') {
    if (-not $OutFile) { Stop-With 2 '-OutFile is required for -Mode Build.' }
    $OutFile = [IO.Path]::GetFullPath($OutFile)
    $commit = Invoke-Native git @('-C', $RepoPath, 'rev-parse', '--verify', "$Ref^{commit}")
    New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
    Invoke-Native git @('-C', $RepoPath, 'archive', '--format=zip', "--output=$OutFile", $commit) | Out-Null
    $p = Get-ZipPayload $OutFile
    if ($p.bad.Count) { Remove-Item -LiteralPath $OutFile -Force; Stop-With 2 ("ZIP deleted; refused entries:`n  " + ($p.bad -join "`n  ")) }
    $payload = Expand-Payload $OutFile $p.files
    $scan = Invoke-Scan $payload
    if (-not $scan.ok) {
        Remove-Item -LiteralPath $OutFile -Force
        Stop-With 3 'Secret scan failed; ZIP deleted. Remove the secret from the commit (and rotate it), or allow-list a vetted exception with -AllowList, then rebuild.'
    }
    $manifest = [ordered]@{
        schema = 'ccof.customer-zip.v1'; commit = $commit; ref = $Ref; zip = (Split-Path $OutFile -Leaf)
        sha256 = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLowerInvariant()
        files = $p.files.Count; scanner = $scan.scanner; builtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath "$OutFile.manifest.json" -Encoding utf8NoBOM
    Stop-With 0 "Built $OutFile from $commit (sha256 $($manifest.sha256), $($p.files.Count) files); secret scan clean ($($scan.scanner))."
}

# Publish: every check that needs no git or gh comes first.
if (-not $ZipPath -or -not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { Stop-With 2 '-ZipPath must point to an existing ZIP for -Mode Publish.' }
if ($Repository -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { Stop-With 2 '-Repository must be owner/name.' }
if ($ReplaceMainAt -and $ReplaceMainAt -notmatch '^[0-9a-f]{40}$') { Stop-With 2 '-ReplaceMainAt must be the full 40-character SHA of the current main commit.' }
$canonical = "https://github.com/$Repository.git"
if ($RemoteUrl -and $RemoteUrl.TrimEnd('/') -ine $canonical -and $RemoteUrl.TrimEnd('/') -ine "https://github.com/$Repository") {
    Stop-With 2 "Refused: -RemoteUrl $RemoteUrl is not $canonical. The push goes only to the verified repository -Repository."
}
$ZipPath = [IO.Path]::GetFullPath($ZipPath)
if (-not $CommitMessage) { $CommitMessage = "Import $(Split-Path $ZipPath -Leaf)" }
$manifestPath = "$ZipPath.manifest.json"
if (Test-Path -LiteralPath $manifestPath) {
    $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($m.sha256 -ne $hash) { Stop-With 2 "ZIP SHA-256 $hash does not match the manifest ($($m.sha256))." }
    $CommitMessage += " (source commit $($m.commit))"
}
$p = Get-ZipPayload $ZipPath
if ($p.bad.Count) { Stop-With 2 ("Refused before any git or gh command; ZIP entries:`n  " + ($p.bad -join "`n  ")) }
if (-not $p.files.Count) { Stop-With 2 'Refused: the ZIP has no files.' }
$payload = Expand-Payload $ZipPath $p.files
$scan = Invoke-Scan $payload
if (-not $scan.ok) { Stop-With 3 'Secret scan failed; nothing was pushed.' }

function Get-RepoInfo {
    $view = & gh repo view $Repository --json nameWithOwner,url,visibility,isEmpty 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { return ($view | ConvertFrom-Json) }
    if ($view -match 'Could not resolve|not found|404') { return $null }
    Stop-With 3 "gh repo view $Repository failed: $view"
}
function Assert-RepoInfo($Info) {
    if ($Info.nameWithOwner -ine $Repository -or $Info.url.TrimEnd('/') -ine "https://github.com/$Repository") {
        Stop-With 2 "Refused: gh reports $($Info.nameWithOwner) at $($Info.url), not $Repository (renamed or redirected repository?)."
    }
    if ($Info.visibility -ne 'PRIVATE') { Stop-With 2 "$Repository is $($Info.visibility); only a private repository is allowed." }
}
$gitAuth = @('-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential')
$info = Get-RepoInfo
$expect = ''
if ($info) {
    Assert-RepoInfo $info
    if (-not $info.isEmpty) {
        $remoteMain = ((Invoke-Native git ($gitAuth + @('ls-remote', $canonical, 'refs/heads/main'))) -split '\s+')[0]
        if (-not $ReplaceMainAt) { Stop-With 2 "$Repository already has commits (main at $(if ($remoteMain) { $remoteMain } else { 'none' })). Nothing was pushed. To replace main with this ZIP, confirm that this is the right repository and re-run with -ReplaceMainAt $remoteMain." }
        if ($remoteMain -ne $ReplaceMainAt) { Stop-With 2 "Refused: main is at $(if ($remoteMain) { $remoteMain } else { 'none' }), not -ReplaceMainAt $ReplaceMainAt." }
        $expect = $ReplaceMainAt
    }
}
if ($ReplaceMainAt -and -not $expect) { Stop-With 2 "Refused: -ReplaceMainAt was given but $Repository has no main commit." }
$plan = @(
    $(if ($info) { "use existing private repository $Repository" } else { "gh repo create $Repository --private" }),
    "commit the $($p.files.Count) ZIP files as one commit on main ($CommitMessage)",
    "git push $canonical main --force-with-lease=refs/heads/main:$expect ($(if ($expect) { "replaces main at $expect" } else { 'main must not exist' }))"
)
if (-not $Apply) {
    Write-Host 'Preview only. Re-run with -Apply to:'; $plan | ForEach-Object { Write-Host "  - $_" }
    Stop-With 0 'Preview complete.'
}
if (-not $info) {
    Invoke-Native gh @('repo', 'create', $Repository, '--private', '--disable-wiki') | Out-Null
    $info = Get-RepoInfo
    if (-not $info) { Stop-With 3 "gh repo create $Repository did not give a repository." }
    Assert-RepoInfo $info
}

# Local git commands run with no system or global configuration, no hooks and no filters; the git directory
# is outside the payload.
$gitDir = Join-Path $script:work 'git'; $hooks = Join-Path $script:work 'hooks'; $cfg = Join-Path $script:work 'gitconfig'
New-Item -ItemType Directory -Path $hooks | Out-Null; Set-Content -LiteralPath $cfg -Value '' -NoNewline
$saved = @{}; foreach ($k in 'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_TEMPLATE_DIR') { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
$env:GIT_CONFIG_NOSYSTEM = '1'; $env:GIT_CONFIG_GLOBAL = $cfg; $env:GIT_TEMPLATE_DIR = $hooks; Remove-Item env:GIT_DIR, env:GIT_WORK_TREE -ErrorAction SilentlyContinue
$g = @("--git-dir=$gitDir", "--work-tree=$payload", '-c', "core.hooksPath=$hooks", '-c', 'core.autocrlf=false', '-c', 'core.fsmonitor=false',
    '-c', 'core.symlinks=false', '-c', 'commit.gpgsign=false', '-c', 'user.name=ccof-release', '-c', 'user.email=ccof-release@users.noreply.github.com')
Invoke-Native git @('init', '-q', '-b', 'main', '--bare', $gitDir) | Out-Null
Invoke-Native git ($g + @('config', 'core.bare', 'false')) | Out-Null
Invoke-Native git ($g + @('add', '-A', '-f')) | Out-Null
$tracked = @((Invoke-Native git ($g + @('-c', 'core.quotepath=false', 'ls-files', '-s'))) -split '\r?\n' | Where-Object { $_ })
$byPath = @{}; foreach ($t in $tracked) { $meta, $path = $t -split "`t", 2; $byPath[$path] = ($meta -split ' ')[1] }
if ((@($byPath.Keys | Sort-Object) -join "`n") -ne (@($p.files | Sort-Object) -join "`n")) { Stop-With 3 'Refused: the staged file set differs from the ZIP files; nothing was pushed.' }
$hashes = @((@($p.files | ForEach-Object { Join-Path $payload $_ }) -join "`n") | & git @g hash-object --no-filters --stdin-paths 2>&1)
if ($LASTEXITCODE -ne 0 -or $hashes.Count -ne $p.files.Count) { Stop-With 3 "git hash-object failed: $hashes" }
for ($i = 0; $i -lt $p.files.Count; $i++) {
    if ($byPath[$p.files[$i]] -ne "$($hashes[$i])".Trim()) { Stop-With 3 "Refused: the staged content of $($p.files[$i]) differs from the ZIP; nothing was pushed." }
}
Invoke-Native git ($g + @('commit', '-q', '--no-verify', '-m', $CommitMessage)) | Out-Null
$head = Invoke-Native git ($g + @('rev-parse', 'HEAD'))
foreach ($k in $saved.Keys) { if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $saved[$k] } }

Invoke-Native git (@("--git-dir=$gitDir", '-c', "core.hooksPath=$hooks") + $gitAuth + @('push', '-q', $canonical, 'HEAD:refs/heads/main', "--force-with-lease=refs/heads/main:$expect")) | Out-Null
Stop-With 0 "Pushed $head ($($p.files.Count) files) to $Repository main (scanner $($scan.scanner))."
