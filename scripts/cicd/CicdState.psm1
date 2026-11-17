# Driver state persistence for the CI/CD workflows (docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md, "State").
# The drivers keep state files next to the configuration (deploy/<env>/.staged-state, .dr-state, ...). Those
# folders are gitignored, so the workflow keeps them on an orphan branch cicd-state/<env> in the deployment
# repository: Restore copies the branch into the checkout, Save commits a snapshot with the restored commit as
# parent and pushes it fast-forward only (a concurrent run makes the push fail rather than lose state).
Set-StrictMode -Version Latest

$script:StateFolders = @('.staged-state', '.dr-state', '.dr-evidence', '.health-alerts-a', '.health-alerts-b')
$script:Extensions = @('.json', '.jsonl', '.txt', '.md', '.log', '.csv', '.xml')
$script:MaxBytes = 5MB
$script:Marker = '.cicd-state-restored'
$script:GitCommand = 'git'
# Safe, regenerable exclusions (docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md, "State"). Anything else in a state
# folder is saved, or Save fails: a file is never dropped silently.
$script:Exclusions = [ordered]@{
    'build staging (generated/packages: npm trees and per-app zips; digests are in standby.state.json)' = '^[^/]+/generated/packages/'
    'deployment package (generated/*.zip, rebuilt from source by Stage 7 and standby Code)'              = '^[^/]+/generated/[^/]+\.zip$'
    'lock file (frontdoor-state.lock, held only while a phase runs)'                                   = '\.lock$'
    'node_modules or .git folder'                                                                       = '(^|/)(node_modules|\.git)/'
}
# State the drivers read back on the next run: losing one would make a rerun start over or lose evidence.
# .dr-state/state.json is the standby's staged state (Invoke-DrStandby, Invoke-DrFrontDoor and Invoke-DrFailover read it).
$script:Essential = @('.staged-state/state.json', '.dr-state/state.json', '.dr-state/standby.state.json', '.dr-state/frontdoor-state.json')
$script:SecretPatterns = [ordered]@{
    'storage or Cosmos account key'  = '(?i)(AccountKey|primaryMasterKey|secondaryMasterKey|primaryKey|secondaryKey)["'']?\s*[:=]\s*["'']?[A-Za-z0-9+/]{40,}={0,2}'
    'SAS signature'                  = '(?i)[?&]sig=[A-Za-z0-9%+/]{20,}'
    'private key'                    = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'bearer or access token (JWT)'   = 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    'client secret'                  = '(?i)"?(client_?secret|clientSecret|password)"?\s*[:=]\s*"[^"]{8,}"'
    'APIM subscription key'          = '(?i)(Ocp-Apim-Subscription-Key|subscriptionKey)"?\s*[:=]\s*"?[0-9a-f]{32}'
    'GitHub token'                   = '\b(gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{60,255})\b'
    'Entra client secret value'      = '(?<![A-Za-z0-9_~.-])[A-Za-z0-9_~.-]{3}[0-9]Q~[A-Za-z0-9_~.-]{31,34}(?![A-Za-z0-9_~.-])'
    'connection string key'          = '(?i)(SharedAccessKey|AccountKey|AccessKey)=[A-Za-z0-9+/]{20,}={0,2}'
    'HTTP authorization header'      = '(?i)authorization["'']?\s*[:=]\s*["'']?(basic|bearer)\s+[A-Za-z0-9+/=._~-]{16,}'
    'credentials in a URL'           = '(?i)\bhttps?://[^/\s:@"'']+:[^/\s@"'']{8,}@'
    'API key'                        = '(?i)"(api[-_]?key|key1|key2)"\s*:\s*"[A-Za-z0-9]{32,}"'
}

function Invoke-CicdGit {
    param([string]$Repo, [string[]]$Arguments, [switch]$AllowFailure, [hashtable]$Environment = @{})
    $saved = @{}
    foreach ($k in $Environment.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
    try { $global:LASTEXITCODE = 0; $out = & $script:GitCommand -C $Repo @Arguments 2>&1; $code = $LASTEXITCODE }
    finally { foreach ($k in $saved.Keys) { if ($null -eq $saved[$k]) { Remove-Item -LiteralPath "env:$k" -ErrorAction SilentlyContinue } else { Set-Item -LiteralPath "env:$k" -Value $saved[$k] } } }
    if ($code -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed ($code): $(@($out) -join ' ')" }
    return [pscustomobject]@{ Code = $code; Output = @($out | ForEach-Object { "$_" }) }
}

function Get-CicdStateBranch { param([string]$Environment)
    if ($Environment -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') { throw "invalid_environment: '$Environment' (lowercase letters, digits and -)" }
    return "cicd-state/$Environment"
}

# Files the state branch holds: every file under deploy/<env>/<state folder>/ except the documented regenerable
# exclusions. Returns @{ Files = repo-relative paths; Excluded = "path (reason)"; Refused = "path (reason)" }.
# Refused files (unknown type, over 5 MB) make Save fail; they are never dropped silently.
function Get-CicdStateFiles {
    param([string]$Repo, [string]$Environment)
    $base = Join-Path $Repo "deploy/$Environment"
    $files = [Collections.Generic.List[string]]::new(); $excluded = [Collections.Generic.List[string]]::new(); $refused = [Collections.Generic.List[string]]::new()
    foreach ($folder in $script:StateFolders) {
        $dir = Join-Path $base $folder
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Force) {
            $rel = [IO.Path]::GetRelativePath($Repo, $f.FullName).Replace('\', '/')
            $inFolder = [IO.Path]::GetRelativePath($base, $f.FullName).Replace('\', '/')
            $why = @($script:Exclusions.Keys | Where-Object { $inFolder -match $script:Exclusions[$_] }) | Select-Object -First 1
            if ($why) { $excluded.Add("$rel ($why)"); continue }
            if ($script:Extensions -notcontains $f.Extension.ToLowerInvariant()) { $refused.Add("$rel (type '$($f.Extension)' is not a known state type)"); continue }
            if ($f.Length -gt $script:MaxBytes) { $refused.Add("$rel (size $($f.Length) bytes, limit $($script:MaxBytes))"); continue }
            $files.Add($rel)
        }
    }
    return @{ Files = @($files | Sort-Object); Excluded = $excluded.ToArray(); Refused = $refused.ToArray() }
}

# Secret findings as "path: kind" (never the matched value).
function Find-CicdStateSecrets {
    param([string]$Repo, [string[]]$Files)
    $found = [Collections.Generic.List[string]]::new()
    foreach ($rel in $Files) {
        $text = [IO.File]::ReadAllText((Join-Path $Repo $rel))
        foreach ($kind in $script:SecretPatterns.Keys) { if ($text -match $script:SecretPatterns[$kind]) { $found.Add("${rel}: $kind") } }
    }
    return $found.ToArray()
}

function Get-CicdStateFetchAuth {
    # Jobs checked out with persist-credentials: false (resolve, drift check) pass the read-only job token
    # in CCOF_STATE_TOKEN. It goes to git through GIT_CONFIG_* variables, so it never appears on a command line.
    param([string]$Token = $env:CCOF_STATE_TOKEN, [string]$ServerUrl = $env:GITHUB_SERVER_URL)
    if (-not $Token) { return @{} }
    if (-not $ServerUrl) { $ServerUrl = 'https://github.com' }
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$Token"))
    return @{ GIT_CONFIG_COUNT = '1'; GIT_CONFIG_KEY_0 = "http.$($ServerUrl.TrimEnd('/'))/.extraheader"; GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $basic" }
}

function Restore-CicdState {
    param([string]$Repo, [string]$Environment, [string]$Remote = 'origin')
    $branch = Get-CicdStateBranch $Environment
    $base = Join-Path $Repo "deploy/$Environment"
    if (-not (Test-Path -LiteralPath $base)) { throw "environment_folder_missing: deploy/$Environment" }
    $auth = Get-CicdStateFetchAuth
    # Only "the remote answered and has no such branch" (ls-remote --exit-code: 2) is a first run. Any other
    # failure (repository not found, lost authorization, network) stops: never apply without prior state.
    $ls = Invoke-CicdGit $Repo @('ls-remote', '--exit-code', '--heads', $Remote, "refs/heads/$branch") -AllowFailure -Environment $auth
    if ($ls.Code -eq 2) {
        Set-Content -LiteralPath (Join-Path $base $script:Marker) -Value 'none' -NoNewline
        return [pscustomobject]@{ Commit = $null; Files = 0; Message = "no $branch branch yet (remote answered, no such ref): first run, nothing restored" }
    }
    if ($ls.Code -ne 0) { throw "state_remote_unreachable: git ls-remote $Remote exited $($ls.Code): $(@($ls.Output) -join ' '). The state branch cannot be read; nothing was restored and this is not treated as a first run." }
    $heads = @($ls.Output | Where-Object { $_ -match "^[0-9a-f]{40}\trefs/heads/$([regex]::Escape($branch))$" })
    if ($heads.Count -ne 1) { throw "state_ls_remote_unexpected: expected one ref refs/heads/$branch, got: $(@($ls.Output) -join ' ')" }
    $advertised = ($heads[0] -split "`t")[0]
    $fetch = Invoke-CicdGit $Repo @('fetch', '--no-tags', '--depth', '1', $Remote, "+refs/heads/${branch}:refs/remotes/$Remote/$branch") -AllowFailure -Environment $auth
    if ($fetch.Code -ne 0) { throw "state_fetch_failed: $branch exists on $Remote but git fetch exited $($fetch.Code): $(@($fetch.Output) -join ' ')" }
    $commit = (Invoke-CicdGit $Repo @('rev-parse', "refs/remotes/$Remote/$branch")).Output[0].Trim()
    if ($commit -cne $advertised) { throw "state_branch_moved: $branch moved from $advertised to $commit during Restore (another run saved state); rerun." }
    $paths = @((Invoke-CicdGit $Repo @('ls-tree', '-r', '--name-only', $commit)).Output | Where-Object { $_ })
    $prefix = "deploy/$Environment/"
    $n = 0
    foreach ($p in $paths) {
        if (-not $p.StartsWith($prefix) -or @($script:StateFolders | Where-Object { $p.StartsWith("$prefix$_/") }).Count -eq 0) { throw "state_branch_unexpected_path: $p" }
        $target = Join-Path $Repo $p
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        $blob = (Invoke-CicdGit $Repo @('rev-parse', "${commit}:$p")).Output[0].Trim()
        $psi = [Diagnostics.ProcessStartInfo]::new('git', @('-C', $Repo, 'cat-file', 'blob', $blob)); $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
        $proc = [Diagnostics.Process]::Start($psi); $fs = [IO.File]::Create($target)
        try { $proc.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Dispose(); $proc.WaitForExit() }
        if ($proc.ExitCode -ne 0) { throw "state_restore_failed: $p" }
        $n++
    }
    Set-Content -LiteralPath (Join-Path $base $script:Marker) -Value $commit -NoNewline
    return [pscustomobject]@{ Commit = $commit; Files = $n; Message = "restored $n file(s) from $branch at $($commit.Substring(0, 12))" }
}

function Save-CicdState {
    param([string]$Repo, [string]$Environment, [string]$Message = 'ccof cicd state', [string]$Remote = 'origin')
    $branch = Get-CicdStateBranch $Environment
    $marker = Join-Path $Repo "deploy/$Environment/$script:Marker"
    if (-not (Test-Path -LiteralPath $marker)) { throw 'state_not_restored: run Sync-CicdState.ps1 -Action Restore in this job before Save' }
    $parent = (Get-Content -LiteralPath $marker -Raw).Trim()
    $sel = Get-CicdStateFiles $Repo $Environment
    if ($sel.Refused.Count) { throw "state_file_not_saved: $($sel.Refused -join '; '). Nothing was pushed; state is never dropped silently (see the documented exclusions)." }
    foreach ($s in $sel.Excluded) { Write-Host "not saved (regenerable): $s" }
    if ($parent -ne 'none') {
        # An essential file the restored snapshot had must still be there: a lost state.json would otherwise be
        # pushed as an empty state and the next run would start over.
        $before = @((Invoke-CicdGit $Repo @('ls-tree', '-r', '--name-only', $parent)).Output | Where-Object { $_ })
        $lost = @($script:Essential | ForEach-Object { "deploy/$Environment/$_" } | Where-Object { $before -contains $_ -and $sel.Files -notcontains $_ })
        if ($lost.Count) { throw "state_essential_missing: $($lost -join ', ') was restored but is missing now. Nothing was pushed." }
    }
    $secrets = @(Find-CicdStateSecrets $Repo $sel.Files)
    if ($secrets.Count) { throw "state_secret_detected: $($secrets -join '; '). Nothing was pushed; remove the value from the state file." }
    $index = Join-Path ([IO.Path]::GetTempPath()) ('ccof-state-index-' + [guid]::NewGuid().ToString('N'))
    $genv = @{ GIT_INDEX_FILE = $index; GIT_AUTHOR_NAME = 'ccof-cicd'; GIT_AUTHOR_EMAIL = 'ccof-cicd@users.noreply.github.com'; GIT_COMMITTER_NAME = 'ccof-cicd'; GIT_COMMITTER_EMAIL = 'ccof-cicd@users.noreply.github.com' }
    try {
        $null = Invoke-CicdGit $Repo @('read-tree', '--empty') -Environment $genv
        foreach ($rel in $sel.Files) {
            $blob = (Invoke-CicdGit $Repo @('hash-object', '-w', '--no-filters', '--', $rel)).Output[0].Trim()
            $null = Invoke-CicdGit $Repo @('update-index', '--add', '--cacheinfo', "100644,$blob,$rel") -Environment $genv
        }
        $tree = (Invoke-CicdGit $Repo @('write-tree') -Environment $genv).Output[0].Trim()
    } finally { Remove-Item -LiteralPath $index -ErrorAction SilentlyContinue }
    if ($parent -ne 'none' -and (Invoke-CicdGit $Repo @('rev-parse', "$parent^{tree}")).Output[0].Trim() -eq $tree) {
        return [pscustomobject]@{ Commit = $parent; Files = $sel.Files.Count; Pushed = $false; Message = "no state change; $branch stays at $($parent.Substring(0, 12))" }
    }
    $ctArgs = @('commit-tree', $tree, '-m', $Message) + $(if ($parent -ne 'none') { @('-p', $parent) } else { @() })
    $commit = (Invoke-CicdGit $Repo $ctArgs -Environment $genv).Output[0].Trim()
    # Fast-forward only: a first save requires the branch to be absent; later saves require it unchanged.
    $lease = if ($parent -eq 'none') { "--force-with-lease=refs/heads/${branch}:" } else { "--force-with-lease=refs/heads/${branch}:$parent" }
    $push = Invoke-CicdGit $Repo @('push', $lease, $Remote, "${commit}:refs/heads/$branch") -AllowFailure
    if ($push.Code -ne 0) { throw "state_push_rejected: $branch moved since Restore (another run saved state) or push denied: $(@($push.Output) -join ' ')" }
    Set-Content -LiteralPath $marker -Value $commit -NoNewline
    return [pscustomobject]@{ Commit = $commit; Files = $sel.Files.Count; Pushed = $true; Message = "saved $($sel.Files.Count) file(s) to $branch at $($commit.Substring(0, 12))" }
}

Export-ModuleMember -Function Get-CicdStateBranch, Get-CicdStateFetchAuth, Get-CicdStateFiles, Find-CicdStateSecrets, Restore-CicdState, Save-CicdState
