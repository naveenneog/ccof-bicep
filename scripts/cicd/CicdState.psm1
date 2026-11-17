# Driver state persistence for the CI/CD workflows (docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md, "State").
# The drivers keep state files next to the configuration (deploy/<env>/.staged-state, .dr-state, ...). Those
# folders are gitignored, so the workflow keeps them on an orphan branch cicd-state/<env> in the deployment
# repository: Restore copies the branch into the checkout, Save commits a snapshot with the restored commit as
# parent and pushes it fast-forward only (a concurrent run makes the push fail rather than lose state).
Set-StrictMode -Version Latest

$script:StateFolders = @('.staged-state', '.dr-state', '.dr-evidence', '.health-alerts-a', '.health-alerts-b')
$script:Extensions = @('.json', '.jsonl', '.txt', '.md', '.log', '.csv')
$script:MaxBytes = 5MB
$script:Marker = '.cicd-state-restored'
$script:SecretPatterns = [ordered]@{
    'storage or Cosmos account key'  = '(?i)(AccountKey|primaryMasterKey|secondaryMasterKey|primaryKey|secondaryKey)["'']?\s*[:=]\s*["'']?[A-Za-z0-9+/]{40,}={0,2}'
    'SAS signature'                  = '(?i)[?&]sig=[A-Za-z0-9%+/]{20,}'
    'private key'                    = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'bearer or access token (JWT)'   = 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    'client secret'                  = '(?i)"?(client_?secret|clientSecret|password)"?\s*[:=]\s*"[^"]{8,}"'
    'APIM subscription key'          = '(?i)(Ocp-Apim-Subscription-Key|subscriptionKey)"?\s*[:=]\s*"?[0-9a-f]{32}'
}

function Invoke-CicdGit {
    param([string]$Repo, [string[]]$Arguments, [switch]$AllowFailure, [hashtable]$Environment = @{})
    $saved = @{}
    foreach ($k in $Environment.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
    try { $out = & git -C $Repo @Arguments 2>&1; $code = $LASTEXITCODE }
    finally { foreach ($k in $saved.Keys) { if ($null -eq $saved[$k]) { Remove-Item -LiteralPath "env:$k" -ErrorAction SilentlyContinue } else { Set-Item -LiteralPath "env:$k" -Value $saved[$k] } } }
    if ($code -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed ($code): $(@($out) -join ' ')" }
    return [pscustomobject]@{ Code = $code; Output = @($out | ForEach-Object { "$_" }) }
}

function Get-CicdStateBranch { param([string]$Environment)
    if ($Environment -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') { throw "invalid_environment: '$Environment' (lowercase letters, digits and -)" }
    return "cicd-state/$Environment"
}

# Files the state branch may hold: under deploy/<env>/<state folder>/, allowed extensions, at most 5 MB.
# Returns @{ Files = repo-relative paths; Skipped = reasons }.
function Get-CicdStateFiles {
    param([string]$Repo, [string]$Environment)
    $base = Join-Path $Repo "deploy/$Environment"
    $files = [Collections.Generic.List[string]]::new(); $skipped = [Collections.Generic.List[string]]::new()
    foreach ($folder in $script:StateFolders) {
        $dir = Join-Path $base $folder
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Force) {
            $rel = [IO.Path]::GetRelativePath($Repo, $f.FullName).Replace('\', '/')
            if ($script:Extensions -notcontains $f.Extension.ToLowerInvariant()) { $skipped.Add("$rel (type $($f.Extension))"); continue }
            if ($f.Length -gt $script:MaxBytes) { $skipped.Add("$rel (size $($f.Length))"); continue }
            if ($rel -match '/(node_modules|\.git)/') { $skipped.Add("$rel (excluded folder)"); continue }
            $files.Add($rel)
        }
    }
    return @{ Files = @($files | Sort-Object); Skipped = $skipped.ToArray() }
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
    # Jobs checked out with persist-credentials: false (pull requests, drift check) pass the read-only job token
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
    $fetch = Invoke-CicdGit $Repo @('fetch', '--no-tags', '--depth', '1', $Remote, "+refs/heads/${branch}:refs/remotes/$Remote/$branch") -AllowFailure -Environment (Get-CicdStateFetchAuth)
    if ($fetch.Code -ne 0) {
        if (@($fetch.Output) -join ' ' -notmatch "couldn't find remote ref|not found") { throw "state_fetch_failed: $(@($fetch.Output) -join ' ')" }
        Set-Content -LiteralPath (Join-Path $base $script:Marker) -Value 'none' -NoNewline
        return [pscustomobject]@{ Commit = $null; Files = 0; Message = "no $branch branch yet: first run, nothing restored" }
    }
    $commit = (Invoke-CicdGit $Repo @('rev-parse', "refs/remotes/$Remote/$branch")).Output[0].Trim()
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
    foreach ($s in $sel.Skipped) { Write-Warning "not saved: $s" }
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
