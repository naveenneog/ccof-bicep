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
$t = Join-Path $dir 'rule-github-token'
Set-Content -LiteralPath (Join-Path $t '.secretscan-allow') -Value "# test fixture`n^bad\.txt:2:github-token$"
Check 'allow list: an entry for path:line:rule suppresses only that finding' (@((Find-CcofSecrets -Path $t -AllowPatterns (Read-CcofSecretAllowList -Path $t)).findings).Count -eq 0)
[IO.File]::WriteAllBytes((Join-Path $t 'bin.dat'), [byte[]](@(0, 1) + [Text.Encoding]::ASCII.GetBytes($cases[1].bad)))
Check 'binary files are skipped and counted' ((Find-CcofSecrets -Path $t -AllowPatterns (Read-CcofSecretAllowList -Path $t)).skipped -eq 1)

# Scratch source repository with a clean commit and a commit that adds a secret.
$src = Join-Path $dir 'src'; New-Item -ItemType Directory -Force $src | Out-Null
$git = @('-C', $src, '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'core.autocrlf=false')
git -C $src init -q -b main
Set-Content -LiteralPath (Join-Path $src 'README.md') -Value 'Customer: Contoso STG, subscription 00000000-0000-4000-8000-000000000002'
New-Item -ItemType Directory -Force (Join-Path $src 'infra') | Out-Null
Set-Content -LiteralPath (Join-Path $src 'infra/main.bicep') -Value "param location string = 'eastus2'"
git @git add -A; git @git commit -q -m clean
$clean = (git -C $src rev-parse HEAD).Trim()
Set-Content -LiteralPath (Join-Path $src 'infra/local.settings.json') -Value ('{"conn":"AccountEndpoint=https://x/;Account' + 'Key=' + ('Z' * 86) + '=="}')
git @git add -A; git @git commit -q -m leak

function Run-Zip([string[]]$ScriptArgs, [hashtable]$Env = @{}) {
    $stub = Join-Path $dir 'gh-stub.ps1'
    @'
function global:gh {
    $l = $args -join ' '; Add-Content -LiteralPath $env:FAKE_GH_LOG -Value $l; $global:LASTEXITCODE = 0
    if ($l -match '^repo view ') {
        if ($env:FAKE_REPO -eq 'missing') { $global:LASTEXITCODE = 1; return "GraphQL: Could not resolve to a Repository with the name 'x'." }
        return '{"visibility":"' + $env:FAKE_REPO + '","isEmpty":' + $env:FAKE_EMPTY + '}'
    }
    if ($l -match '^repo create \S+ --private') { return 'https://github.com/octo/x' }
    if ($l -match '^auth git-credential') { return '' }
    $global:LASTEXITCODE = 1; return "stub gh: unexpected $l"
}
'@ | Set-Content -LiteralPath $stub -Encoding utf8NoBOM
    $env:FAKE_GH_LOG = Join-Path $dir 'gh.log'; Set-Content $env:FAKE_GH_LOG ''
    $sets = ($Env.Keys | ForEach-Object { "`$env:$_ = '$($Env[$_])'; " }) -join ''
    $cmd = ". '$stub'; $sets& '$script' $($ScriptArgs -join ' '); exit `$LASTEXITCODE"
    $out = pwsh -NoProfile -Command $cmd 2>&1 | Out-String
    @{ code = $LASTEXITCODE; out = $out; gh = @(Get-Content $env:FAKE_GH_LOG | Where-Object { $_ }) }
}

$zip = Join-Path $dir 'out/ccof.zip'
$r = Run-Zip @('-Mode', 'Build', '-RepoPath', "'$src'", '-Ref', 'HEAD', '-OutFile', "'$zip'", '-NoGitleaks')
Check 'build: a commit with a planted key fails (exit 3), names file and rule, deletes the ZIP, never prints the key' ($r.code -eq 3 -and
    $r.out -match 'infra/local\.settings\.json:1 \[(storage-account-key|connection-string-key)\]' -and -not (Test-Path $zip) -and $r.out -notmatch ('Z' * 20))
$r = Run-Zip @('-Mode', 'Build', '-RepoPath', "'$src'", '-Ref', $clean, '-OutFile', "'$zip'", '-NoGitleaks')
$m = if (Test-Path "$zip.manifest.json") { Get-Content "$zip.manifest.json" -Raw | ConvertFrom-Json } else { $null }
Check 'build: a clean commit gives the ZIP and a manifest with the commit and SHA-256' ($r.code -eq 0 -and (Test-Path $zip) -and $m -and $m.commit -eq $clean -and
    $m.sha256 -eq (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -and $m.scanner -eq 'regex')
Check 'build: customer names and subscription IDs are allowed in the ZIP' ($r.out -match '0 finding')

$bare = Join-Path $dir 'remote.git'; git init -q --bare -b main $bare
$common = @('-Mode', 'Publish', '-ZipPath', "'$zip'", '-Repository', 'octo/ccof-lab', '-RemoteUrl', "'$bare'", '-NoGitleaks')
$r = Run-Zip $common @{ FAKE_REPO = 'missing'; FAKE_EMPTY = 'true' }
Check 'publish preview: prints the plan, creates and pushes nothing' ($r.code -eq 0 -and $r.out -match 'Preview only' -and $r.out -match 'gh repo create octo/ccof-lab --private' -and
    @($r.gh | Where-Object { $_ -match '^repo create' }).Count -eq 0 -and -not (git --git-dir=$bare rev-parse --verify -q main))
$r = Run-Zip ($common + '-Apply') @{ FAKE_REPO = 'missing'; FAKE_EMPTY = 'true' }
$files = @(git --git-dir=$bare ls-tree -r --name-only main)
Check 'publish -Apply: creates the private repository and pushes one commit with the ZIP contents' ($r.code -eq 0 -and @($r.gh | Where-Object { $_ -match '^repo create octo/ccof-lab --private' }).Count -eq 1 -and
    ($files -join ',') -eq 'README.md,infra/main.bicep' -and (git --git-dir=$bare log --format=%s main) -match "source commit $clean")
$r = Run-Zip ($common + '-Apply') @{ FAKE_REPO = 'PUBLIC'; FAKE_EMPTY = 'true' }
Check 'publish: a public repository is refused (exit 2)' ($r.code -eq 2 -and $r.out -match 'only a private repository')
$r = Run-Zip ($common + '-Apply') @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'false' }
Check 'publish: a repository with commits is refused without -Force (exit 2)' ($r.code -eq 2 -and $r.out -match '-Force')
$before = (git --git-dir=$bare rev-parse main).Trim()
$r = Run-Zip ($common + @('-Apply', '-Force')) @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'false' }
Check 'publish -Force: re-creates main from the ZIP (re-runnable)' ($r.code -eq 0 -and (git --git-dir=$bare rev-parse main).Trim() -ne $before -and @(git --git-dir=$bare rev-list main).Count -eq 1)
Copy-Item $zip "$zip.bak"; Add-Content -LiteralPath $zip -Value 'tamper'
$r = Run-Zip ($common + '-Apply') @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'true' }
Check 'publish: a ZIP that does not match its manifest SHA-256 is refused' ($r.code -eq 2 -and $r.out -match 'does not match the manifest')
Move-Item "$zip.bak" $zip -Force

# A ZIP that contains a secret (built without this script) is refused at publish time.
$leakZip = Join-Path $dir 'out/leak.zip'; git -C $src archive --format=zip "--output=$leakZip" HEAD
$r = Run-Zip @('-Mode', 'Publish', '-ZipPath', "'$leakZip'", '-Repository', 'octo/ccof-lab', '-RemoteUrl', "'$bare'", '-NoGitleaks', '-Apply') @{ FAKE_REPO = 'PRIVATE'; FAKE_EMPTY = 'true' }
Check 'publish: a ZIP with a secret is refused (exit 3) before any gh or git push' ($r.code -eq 3 -and $r.gh.Count -eq 0)

Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Test-CustomerRepoZip: $($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
