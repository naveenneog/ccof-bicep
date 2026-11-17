# Offline tests for scripts/New-CustomerRepoFromZip.ps1 and scripts/SecretScan.psm1 (docs/runbooks/CICD-SETUP.md,
# section 9). Uses a scratch git repository, a local bare repository as the push target and a stub `gh`.
# Fake secrets are assembled at run time so this file itself passes the scan.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'scripts/SecretScan.psm1') -Force
$script = Join-Path $repo 'scripts/New-CustomerRepoFromZip.ps1'
$dir = Join-Path $repo '.env.public-test-scratch/customer-zip'
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# Each rule: a value it must flag and a look-alike it must not.
$b64 = 'Q' * 86
$cases = @(
    @{ rule = 'private-key'; bad = '-----BEGIN ' + 'RSA PRIVATE KEY-----'; ok = '-----BEGIN PUBLIC KEY-----' },
    @{ rule = 'github-token'; bad = 'gh' + 'p_' + ('a1' * 18); ok = 'ghp_short' },
    @{ rule = 'entra-client-secret'; bad = 'abc8' + 'Q~' + ('x' * 32); ok = 'abc8Q~short' },
    @{ rule = 'storage-account-key'; bad = 'Account' + 'Key=' + ('A' * 86) + '=='; ok = 'AccountKey=<from-key-vault>' },
    @{ rule = 'cosmos-or-service-key'; bad = "key: $b64=="; ok = "integrity: sha512-$b64==" },
    @{ rule = 'sas-signature'; bad = 'https://x.blob.core.windows.net/c?sv=1&s' + 'ig=' + ('A' * 43) + '%3D'; ok = 'sig=short' },
    @{ rule = 'connection-string-key'; bad = 'Endpoint=sb://x/;SharedAccess' + 'Key=' + ('k' * 30); ok = 'Password=$env:DB_PASSWORD_VALUE_X' },
    @{ rule = 'aws-access-key'; bad = 'AK' + 'IA' + ('B' * 16); ok = 'AKIA_NOT_A_KEY' },
    @{ rule = 'slack-token'; bad = 'xo' + 'xb-' + ('1' * 12); ok = 'xoxb-' },
    @{ rule = 'jwt'; bad = 'ey' + 'J' + ('a' * 12) + '.eyJ' + ('b' * 12) + '.' + ('c' * 24); ok = 'eyJhbGciOi' },
    @{ rule = 'runner-token'; bad = 'RUNNER_' + 'TOKEN=' + ('A' * 29); ok = 'RUNNER_TOKEN="$RUNNER_TOKEN"' }
)
Check 'every scan rule has a test case' (((@((Get-CcofSecretRules).Keys) | Sort-Object) -join ',') -eq ((@($cases.rule) | Sort-Object) -join ','))
foreach ($c in $cases) {
    $t = Join-Path $dir "rule-$($c.rule)"; New-Item -ItemType Directory -Force $t | Out-Null
    Set-Content -LiteralPath (Join-Path $t 'bad.txt') -Value "line one`n$($c.bad)"
    Set-Content -LiteralPath (Join-Path $t 'ok.txt') -Value $c.ok
    $r = Find-CcofSecrets -Path $t
    $f = @($r.findings)
    Check "rule $($c.rule): flags the secret on its line only, and not the look-alike" (@($f | Where-Object { $_.rule -eq $c.rule -and $_.path -eq 'bad.txt' -and $_.line -eq 2 }).Count -ge 1 -and @($f | Where-Object { $_.path -eq 'ok.txt' }).Count -eq 0)
    Check "rule $($c.rule): the finding never prints the whole value" (@($f | Where-Object { $_.excerpt.Contains($c.bad.Substring([Math]::Max(0, $c.bad.Length - 12))) }).Count -eq 0)
}

# Encodings, containers and unscanned files: the same fake token is found in every supported form, and
# anything the scanner cannot read is reported as unscanned (which fails the scan), never as clean.
$tok = 'gh' + 'p_' + ('a1' * 18)
function Find-In([hashtable]$Files, [long]$Max = 20MB, [string[]]$Allow = @()) {
    $t = Join-Path $dir ('enc-' + [guid]::NewGuid().ToString('n').Substring(0, 8)); New-Item -ItemType Directory -Force $t | Out-Null
    foreach ($k in $Files.Keys) { [IO.File]::WriteAllBytes((Join-Path $t $k), [byte[]]$Files[$k]) }
    $r = Find-CcofSecrets -Path $t -MaxBytes $Max -Allow $Allow; $r | Add-Member -NotePropertyName dir -NotePropertyValue $t; $r
}
function Zlib([byte[]]$b) { $ms = [IO.MemoryStream]::new(); $z = [IO.Compression.ZLibStream]::new($ms, [IO.Compression.CompressionLevel]::Optimal); $z.Write($b, 0, $b.Length); $z.Dispose(); $ms.ToArray() }
function Chunk([string]$Type, [byte[]]$Data) { $l = [byte[]]::new(4); [Buffers.Binary.BinaryPrimitives]::WriteInt32BigEndian($l, $Data.Length); $l + [Text.Encoding]::ASCII.GetBytes($Type) + $Data + [byte[]]::new(4) }
function ZipBytes([hashtable]$Entries) {
    $ms = [IO.MemoryStream]::new(); $za = [IO.Compression.ZipArchive]::new($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($k in $Entries.Keys) { $s = $za.CreateEntry($k).Open(); $s.Write([byte[]]$Entries[$k], 0, $Entries[$k].Length); $s.Dispose() }
    $za.Dispose(); $ms.ToArray()
}
$line = "x = $tok`n"
$forms = [ordered]@{
    'UTF-16LE with BOM' = [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($line)
    'UTF-16BE with BOM' = [byte[]](0xFE, 0xFF) + [Text.Encoding]::BigEndianUnicode.GetBytes($line)
    'UTF-16LE without BOM' = [Text.Encoding]::Unicode.GetBytes($line)
    'UTF-16BE without BOM' = [Text.Encoding]::BigEndianUnicode.GetBytes($line)
    'UTF-32LE with BOM' = [byte[]](0xFF, 0xFE, 0, 0) + [Text.Encoding]::UTF32.GetBytes($line)
    'UTF-8 with BOM' = [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes($line)
    'a ZIP container (e.g. .docx) entry' = ZipBytes @{ 'word/document.xml' = [Text.Encoding]::UTF8.GetBytes($line) }
    'a ZIP inside a ZIP' = ZipBytes @{ 'inner.zip' = (ZipBytes @{ 'a.txt' = [Text.Encoding]::Unicode.GetBytes("`u{FEFF}$line") }) }
    'a PNG zTXt chunk' = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + (Chunk 'zTXt' ([byte[]]([Text.Encoding]::ASCII.GetBytes('Comment') + 0, 0) + (Zlib ([Text.Encoding]::ASCII.GetBytes($line))))) + (Chunk 'IEND' @())
}
foreach ($k in $forms.Keys) {
    $r = Find-In @{ 'f.bin' = $forms[$k] }
    Check "scan: the fake token in $k is found and nothing is unscanned" (@($r.findings | Where-Object rule -eq 'github-token').Count -eq 1 -and @($r.unscanned).Count -eq 0)
}
$r = Find-In @{ 'blob.dat' = [byte[]](0, 1, 2, 3, 0xFF, 0, 7, 9, 0, 0x80, 0x81, 0) }
Check 'scan: an unknown binary file is reported as unscanned with its SHA-256, not skipped' (@($r.unscanned).Count -eq 1 -and $r.unscanned[0].reason -match 'binary' -and $r.unscanned[0].sha256 -match '^[0-9a-f]{64}$')
$r = Find-In @{ 'big.txt' = [Text.Encoding]::UTF8.GetBytes('a' * 200) } -Max 100
Check 'scan: a file over the size limit is reported as unscanned' (@($r.unscanned).Count -eq 1 -and $r.unscanned[0].reason -match 'larger than')
$r = Find-In @{ 'bad.png' = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 1, 0, 0x7A, 0x54, 0x58, 0x74) }
Check 'scan: a truncated PNG is unscanned, not clean' (@($r.unscanned).Count -eq 1)
$r = Find-In @{ '.secretscan-allow' = [Text.Encoding]::UTF8.GetBytes(".*`n^.*$"); 'a.txt' = [Text.Encoding]::UTF8.GetBytes($line) }
Check 'scan: a .secretscan-allow file with .* inside the tree has no effect (the token is still found)' (@($r.findings | Where-Object { $_.rule -eq 'github-token' -and $_.path -eq 'a.txt' }).Count -eq 1)

# Operator allow-list: exact entries only, outside the scanned tree.
$r = Find-In @{ 'a.txt' = [Text.Encoding]::UTF8.GetBytes($line); 'b.txt' = [Text.Encoding]::UTF8.GetBytes("`n$line") }
$fa = @($r.findings | Where-Object path -eq 'a.txt')[0]
$al = Join-Path $dir 'allow.txt'; Set-Content $al "# vetted`nfinding:a.txt:1:github-token:$($fa.sha256)"
$r2 = Find-CcofSecrets -Path $r.dir -Allow (Read-CcofSecretAllowList -Path $al -ScannedRoot $r.dir)
Check 'allow-list: an exact entry suppresses only that path, line, rule and value' (@($r2.findings).Count -eq 1 -and $r2.findings[0].path -eq 'b.txt' -and $r2.allowed -eq 1)
Set-Content (Join-Path $r.dir 'a.txt') ($tok.Replace('a1a1', 'b2b2'))
Check 'allow-list: a changed value on the allowed line is found again' (@((Find-CcofSecrets -Path $r.dir -Allow (Read-CcofSecretAllowList -Path $al -ScannedRoot $r.dir)).findings | Where-Object path -eq 'a.txt').Count -eq 1)
foreach ($bad in @('.*', 'finding:.*', "finding:a.txt:1:github-token:.*", 'finding:a.txt:1:no-such-rule:' + ('0' * 64), 'file:*:' + ('0' * 64))) {
    Set-Content $al $bad; $threw = $false; try { Read-CcofSecretAllowList -Path $al | Out-Null } catch { $threw = $true }
    Check "allow-list: the pattern-like entry '$bad' is rejected" $threw
}
Set-Content (Join-Path $r.dir 'allow.txt') "finding:a.txt:1:github-token:$($fa.sha256)"; $threw = $false
try { Read-CcofSecretAllowList -Path (Join-Path $r.dir 'allow.txt') -ScannedRoot $r.dir | Out-Null } catch { $threw = $_.Exception.Message -match 'inside the scanned tree' }
Check 'allow-list: a file inside the scanned tree (archive-controlled) is rejected' $threw
$r = Find-In @{ 'blob.dat' = [byte[]](0, 1, 2, 3, 0xFF, 0, 7, 9, 0, 0x80, 0x81, 0) }
Set-Content $al "file:blob.dat:$($r.unscanned[0].sha256)"
Check 'allow-list: a file entry with the exact SHA-256 accepts a vetted binary' (@((Find-CcofSecrets -Path $r.dir -Allow (Read-CcofSecretAllowList -Path $al)).unscanned).Count -eq 0)

# Scratch source repository with a clean commit and a commit that adds a secret. The clean commit has an
# ignored-but-tracked file and a .gitattributes filter: the published commit must still hold every file, as is.
$src = Join-Path $dir 'src'; New-Item -ItemType Directory -Force $src | Out-Null
$git = @('-C', $src, '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'core.autocrlf=false')
git -C $src init -q -b main
Set-Content -LiteralPath (Join-Path $src 'README.md') -Value 'Customer: Contoso STG, subscription 00000000-0000-4000-8000-000000000002'
New-Item -ItemType Directory -Force (Join-Path $src 'infra') | Out-Null
Set-Content -LiteralPath (Join-Path $src 'infra/main.bicep') -Value "param location string = 'eastus2'"
Set-Content -LiteralPath (Join-Path $src '.gitignore') -Value '*.log'
Set-Content -LiteralPath (Join-Path $src '.gitattributes') -Value '* filter=evil'
Set-Content -LiteralPath (Join-Path $src 'kept.log') -Value 'tracked although ignored'
git @git add -A; git @git add -f kept.log; git @git commit -q -m clean
$clean = (git -C $src rev-parse HEAD).Trim()
$expected = 'README.md,.gitattributes,.gitignore,infra/main.bicep,kept.log'.Split(',') | Sort-Object
Set-Content -LiteralPath (Join-Path $src 'infra/local.settings.json') -Value ('{"conn":"AccountEndpoint=https://x/;Account' + 'Key=' + ('Z' * 86) + '=="}')
git @git add -A; git @git commit -q -m leak

# The canonical remote https://github.com/octo/ccof-lab.git is mapped to a local bare repository by a test-only
# global git config (the script itself has no override). The same config defines the `evil` filter: it must
# not run during publish. Stubs log every gh and git command.
$bare = Join-Path $dir 'remote.git'; git init -q --bare -b main $bare
$marker = Join-Path $dir 'filter-ran'
$gcfg = Join-Path $dir 'test.gitconfig'
@"
[url "$($bare.Replace('\', '/'))"]
	insteadOf = https://github.com/octo/ccof-lab.git
[filter "evil"]
	clean = sh -c 'echo ran >> \"$($marker.Replace('\', '/'))\" && cat'
"@ | Set-Content $gcfg
function Run-Zip([string[]]$ScriptArgs, [hashtable]$Env = @{}) {
    $stub = Join-Path $dir 'stubs.ps1'
    @'
function global:gh {
    $l = $args -join ' '; Add-Content -LiteralPath $env:FAKE_GH_LOG -Value $l; $global:LASTEXITCODE = 0
    if ($l -match '^repo view ') {
        if ($env:FAKE_REPO -eq 'missing' -and -not (Test-Path "$env:FAKE_GH_LOG.created")) { $global:LASTEXITCODE = 1; return "GraphQL: Could not resolve to a Repository with the name 'x'." }
        $n = if ($env:FAKE_NWO) { $env:FAKE_NWO } else { 'octo/ccof-lab' }; $v = if ($env:FAKE_REPO -eq 'missing') { 'PRIVATE' } else { $env:FAKE_REPO }
        return '{"nameWithOwner":"' + $n + '","url":"https://github.com/' + $n + '","visibility":"' + $v + '","isEmpty":' + $env:FAKE_EMPTY + '}'
    }
    if ($l -match '^repo create \S+ --private') { Set-Content "$env:FAKE_GH_LOG.created" 1; return 'https://github.com/octo/x' }
    $global:LASTEXITCODE = 1; return "stub gh: unexpected $l"
}
function global:git {
    Add-Content -LiteralPath $env:FAKE_GIT_LOG -Value ($args -join ' ')
    $exe = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    if ($MyInvocation.ExpectingInput) { $input | & $exe @args } else { & $exe @args }
}
'@ | Set-Content -LiteralPath $stub -Encoding utf8NoBOM
    $env:FAKE_GH_LOG = Join-Path $dir 'gh.log'; Set-Content $env:FAKE_GH_LOG ''; Remove-Item "$env:FAKE_GH_LOG.created" -ErrorAction SilentlyContinue
    $env:FAKE_GIT_LOG = Join-Path $dir 'git.log'; Set-Content $env:FAKE_GIT_LOG ''
    $Env = @{ GIT_CONFIG_GLOBAL = $gcfg } + $Env
    $sets = ($Env.Keys | ForEach-Object { "`$env:$_ = '$($Env[$_])'; " }) -join ''
    $cmd = ". '$stub'; $sets& '$script' $($ScriptArgs -join ' '); exit `$LASTEXITCODE"
    $out = pwsh -NoProfile -Command $cmd 2>&1 | Out-String
    @{ code = $LASTEXITCODE; out = $out; gh = @(Get-Content $env:FAKE_GH_LOG | Where-Object { $_ }); git = @(Get-Content $env:FAKE_GIT_LOG | Where-Object { $_ }) }
}
function Main { (git --git-dir=$bare rev-parse --verify -q main) }
function NoLeftovers { @(Get-ChildItem -Force (Join-Path $dir 'out') -Filter '.ccof-zip-*').Count -eq 0 }

$zip = Join-Path $dir 'out/ccof.zip'
New-Item -ItemType Directory -Force "$zip.staging" | Out-Null; Set-Content "$zip.staging/user-notes.txt" 'keep me'
$r = Run-Zip @('-Mode', 'Build', '-RepoPath', "'$src'", '-Ref', 'HEAD', '-OutFile', "'$zip'", '-NoGitleaks')
Check 'build: a commit with a planted key fails (exit 3), names file and rule, deletes the ZIP, never prints the key' ($r.code -eq 3 -and
    $r.out -match 'infra/local\.settings\.json:1 \[(storage-account-key|connection-string-key)\]' -and -not (Test-Path $zip) -and $r.out -notmatch ('Z' * 20))
$r = Run-Zip @('-Mode', 'Build', '-RepoPath', "'$src'", '-Ref', $clean, '-OutFile', "'$zip'", '-NoGitleaks')
$m = if (Test-Path "$zip.manifest.json") { Get-Content "$zip.manifest.json" -Raw | ConvertFrom-Json } else { $null }
Check 'build: a clean commit gives the ZIP and a manifest with the commit, SHA-256 and file count' ($r.code -eq 0 -and (Test-Path $zip) -and $m -and $m.commit -eq $clean -and
    $m.sha256 -eq (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -and $m.scanner -eq 'regex' -and $m.files -eq 5)
Check 'build: customer names and subscription IDs are allowed in the ZIP' ($r.out -match '0 finding')
Check 'build: a pre-existing <zip>.staging directory (user data) is left alone, and the run leaves no work directory' ((Get-Content "$zip.staging/user-notes.txt") -eq 'keep me' -and (NoLeftovers))

$common = @('-Mode', 'Publish', '-ZipPath', "'$zip'", '-Repository', 'octo/ccof-lab', '-NoGitleaks')
$r = Run-Zip $common @{ FAKE_REPO = 'missing'; FAKE_EMPTY = 'true' }
Check 'publish preview: prints the plan, creates and pushes nothing' ($r.code -eq 0 -and $r.out -match 'Preview only' -and $r.out -match 'gh repo create octo/ccof-lab --private' -and
    @($r.gh | Where-Object { $_ -match '^repo create' }).Count -eq 0 -and -not (Main))
$r = Run-Zip ($common + @('-RemoteUrl', 'https://github.com/someone-else/public-repo.git', '-Apply')) @{ FAKE_REPO = 'missing'; FAKE_EMPTY = 'true' }
Check 'publish: a -RemoteUrl other than the -Repository URL is refused (exit 2) before any gh or git' ($r.code -eq 2 -and $r.out -match 'is not https://github.com/octo/ccof-lab.git' -and $r.gh.Count -eq 0 -and $r.git.Count -eq 0)
$r = Run-Zip ($common + '-Apply') @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'true'; FAKE_NWO = 'evil/ccof-lab' }
Check 'publish: gh reporting a different repository (rename/redirect) is refused (exit 2), nothing pushed' ($r.code -eq 2 -and $r.out -match 'evil/ccof-lab' -and -not (Main))
$r = Run-Zip ($common + '-Apply') @{ FAKE_REPO = 'missing'; FAKE_EMPTY = 'true' }
$files = @(git --git-dir=$bare ls-tree -r --name-only main | Sort-Object)
$same = @($expected | Where-Object { (git --git-dir=$bare show "main:$_" | Out-String) -eq (git -C $src show "${clean}:$_" | Out-String) }).Count -eq $expected.Count
Check 'publish -Apply: creates the private repository and pushes one commit with exactly the ZIP files (ignored file kept)' ($r.code -eq 0 -and
    @($r.gh | Where-Object { $_ -match '^repo create octo/ccof-lab --private' }).Count -eq 1 -and ($files -join ',') -eq ($expected -join ',') -and
    (git --git-dir=$bare log --format=%s main) -match "source commit $clean" -and @(git --git-dir=$bare rev-list main).Count -eq 1)
Check 'publish: file contents are byte-identical; no global filter, hook or config ran' ($same -and -not (Test-Path $marker))
Check 'publish: <zip>.staging user data is untouched and the work directory is removed' ((Get-Content "$zip.staging/user-notes.txt") -eq 'keep me' -and (NoLeftovers))
$r = Run-Zip ($common + '-Apply') @{ FAKE_REPO = 'PUBLIC'; FAKE_EMPTY = 'true' }
Check 'publish: a public repository is refused (exit 2)' ($r.code -eq 2 -and $r.out -match 'only a private repository')
$before = (Main)
$r = Run-Zip ($common + '-Apply') @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'false' }
Check 'publish: a repository with commits is refused without -ReplaceMainAt, prints main, pushes nothing (exit 2)' ($r.code -eq 2 -and $r.out -match "-ReplaceMainAt $before" -and (Main) -eq $before)
$r = Run-Zip ($common + @('-Apply', '-ReplaceMainAt', ('0' * 40))) @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'false' }
Check 'publish: -ReplaceMainAt that is not the current main is refused, main unchanged' ($r.code -eq 2 -and $r.out -match 'not -ReplaceMainAt' -and (Main) -eq $before)
$r = Run-Zip ($common + '-Apply') @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'true' }
Check 'publish: the lease refuses to overwrite a main that exists although gh reported an empty repository (exit 3)' ($r.code -eq 3 -and (Main) -eq $before)
$r = Run-Zip ($common + @('-Apply', '-ReplaceMainAt', $before)) @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'false' }
Check 'publish -ReplaceMainAt <current main>: replaces main from the ZIP with a lease (re-runnable)' ($r.code -eq 0 -and (Main) -ne $before -and @(git --git-dir=$bare rev-list main).Count -eq 1 -and
    @($r.git | Where-Object { $_ -match "--force-with-lease=refs/heads/main:$before" }).Count -eq 1 -and @($r.git | Where-Object { $_ -match '(^| )--force( |$)' }).Count -eq 0)
Copy-Item $zip "$zip.bak"; Add-Content -LiteralPath $zip -Value 'tamper'
$r = Run-Zip ($common + '-Apply') @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'true' }
Check 'publish: a ZIP that does not match its manifest SHA-256 is refused' ($r.code -eq 2 -and $r.out -match 'does not match the manifest')
Move-Item "$zip.bak" $zip -Force

# ZIPs that must be refused before any git or gh command runs (nothing is extracted into a git repository).
$ok = [Text.Encoding]::UTF8.GetBytes('ok')
$bad = [ordered]@{
    '.git/hooks/pre-commit' = @{ '.git/hooks/pre-commit' = $ok; 'README.md' = $ok }
    'nested sub/.git file' = @{ 'sub/.git' = [Text.Encoding]::UTF8.GetBytes('gitdir: ../../evil'); 'README.md' = $ok }
    '.GIT/config (case)' = @{ 'x/.GIT/config' = $ok }
    '.git. (trailing dot)' = @{ '.git./config' = $ok }
    'GIT~1 short name' = @{ 'GIT~1/config' = $ok }
    '../ path' = @{ '../escape.txt' = $ok }
    'backslash path' = @{ 'a\..\..\b.txt' = $ok }
}
foreach ($k in $bad.Keys) {
    $bz = Join-Path $dir "out/bad-$([array]::IndexOf(@($bad.Keys), $k)).zip"; [IO.File]::WriteAllBytes($bz, (ZipBytes $bad[$k]))
    $r = Run-Zip @('-Mode', 'Publish', '-ZipPath', "'$bz'", '-Repository', 'octo/ccof-lab', '-NoGitleaks', '-Apply') @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'true' }
    Check "publish: a ZIP with $k is refused (exit 2) and no git or gh command runs" ($r.code -eq 2 -and $r.out -match 'Refused before any git or gh' -and $r.git.Count -eq 0 -and $r.gh.Count -eq 0 -and (NoLeftovers))
}
$bz = Join-Path $dir 'out/link.zip'; $ms = [IO.MemoryStream]::new(); $za = [IO.Compression.ZipArchive]::new($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
$e = $za.CreateEntry('link'); $e.ExternalAttributes = 0xA1FF -shl 16; $s = $e.Open(); $s.Write($ok, 0, 2); $s.Dispose(); $za.Dispose(); [IO.File]::WriteAllBytes($bz, $ms.ToArray())
$r = Run-Zip @('-Mode', 'Publish', '-ZipPath', "'$bz'", '-Repository', 'octo/ccof-lab', '-NoGitleaks', '-Apply') @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'true' }
Check 'publish: a ZIP with a symbolic link entry is refused and no git or gh command runs' ($r.code -eq 2 -and $r.out -match 'symbolic link' -and $r.git.Count -eq 0 -and $r.gh.Count -eq 0)

# ZIPs with a secret are refused at publish time before any gh or git command, also in UTF-16.
$leakZip = Join-Path $dir 'out/leak.zip'; git -C $src archive --format=zip "--output=$leakZip" HEAD
$u16Zip = Join-Path $dir 'out/u16.zip'; [IO.File]::WriteAllBytes($u16Zip, (ZipBytes @{ 'notes.txt' = $forms['UTF-16LE with BOM'] }))
$binZip = Join-Path $dir 'out/bin.zip'; [IO.File]::WriteAllBytes($binZip, (ZipBytes @{ 'blob.dat' = [byte[]](0, 1, 2, 3, 0xFF, 0, 7, 9, 0, 0x80, 0x81, 0) }))
foreach ($z in $leakZip, $u16Zip, $binZip) {
    $r = Run-Zip @('-Mode', 'Publish', '-ZipPath', "'$z'", '-Repository', 'octo/ccof-lab', '-NoGitleaks', '-Apply') @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'true' }
    Check "publish: $(Split-Path $z -Leaf) with a secret or an unscanned file is refused (exit 3) before any gh or git command" ($r.code -eq 3 -and $r.gh.Count -eq 0 -and $r.git.Count -eq 0 -and (NoLeftovers))
}

Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Test-CustomerRepoZip: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
