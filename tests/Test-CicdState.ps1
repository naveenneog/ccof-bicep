#Requires -Version 7.0
# Offline tests of scripts/cicd/Sync-CicdState.ps1 (CicdState.psm1) against a local bare repository.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts\cicd\CicdState.psm1') -Force
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
function Throws([scriptblock]$Block, [string]$Pattern) { try { $null = & $Block; return $false } catch { return $_.Exception.Message -match $Pattern } }

# Short names: the runner's per-suite TEMP can be deep, and Git for Windows refuses a GIT_DIR near 260 characters ('$GIT_DIR' too big).
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('cs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$bare = Join-Path $scratch 'r.git'
# Setup commands of this test run with core.longpaths per command (the runner's per-suite TEMP can be deep). It is not set
# process-wide (GIT_CONFIG_PARAMETERS) so CicdState.psm1 itself must cope with long paths.
function tgit { git -c core.longpaths=true @args }
function New-Clone([string]$Name) {
    $dir = Join-Path $scratch $Name
    tgit init -q $dir; git -C $dir config user.email t@example.com; git -C $dir config user.name t; git -C $dir config core.autocrlf false
    git -C $dir remote add origin $bare
    New-Item -ItemType Directory -Force (Join-Path $dir 'deploy/prod') | Out-Null
    '{"subscriptionId":"x"}' | Set-Content (Join-Path $dir 'deploy/prod/staged.config.json')
    return $dir
}
function Write-State([string]$Repo, [string]$Rel, [string]$Text) {
    $p = Join-Path $Repo "deploy/prod/$Rel"; New-Item -ItemType Directory -Force (Split-Path $p -Parent) | Out-Null
    [IO.File]::WriteAllText($p, $Text)
}
function Get-RemoteHead { $r = git --git-dir $bare rev-parse --verify -q refs/heads/cicd-state/prod; if ($LASTEXITCODE) { $null } else { $r } }

try {
    New-Item -ItemType Directory -Force $scratch | Out-Null
    tgit init -q --bare $bare
    # The local bare remote is a test fixture: git runs its receive-pack without the caller's -c options (local transport
    # clears GIT_CONFIG_PARAMETERS), so the fixture's own config allows long paths. Production remotes are GitHub (HTTPS).
    git --git-dir $bare config core.longpaths true
    $a = New-Clone 'a'; $b = New-Clone 'b'

    $r = Restore-CicdState $a 'prod'
    Check 'first restore: no branch, nothing restored, marker none' ($null -eq $r.Commit -and $r.Files -eq 0 -and (Get-Content (Join-Path $a 'deploy/prod/.cicd-state-restored') -Raw) -eq 'none')

    Write-State $a '.staged-state/state.json' "{`"stages`":{`"1`":{`"ok`":true}}}`r`n"
    Write-State $a '.dr-state/frontdoor-state.json' '{"profileName":"p"}'
    Write-State $a '.health-alerts-a/state.json' '{"x":1}'
    Write-State $a '.dr-state/generated/packages/resolver.zip' 'PK'
    Write-State $a 'other/notes.json' '{}'
    $s = Save-CicdState $a 'prod' 'first'
    $tree = @(git --git-dir $bare ls-tree -r --name-only refs/heads/cicd-state/prod)
    Check 'save: pushed the allowed state files only' ($s.Pushed -and $tree.Count -eq 3 -and $tree -contains 'deploy/prod/.staged-state/state.json' -and $tree -notcontains 'deploy/prod/.dr-state/generated/packages/resolver.zip')
    Check 'save: config and other folders not saved' (@($tree | Where-Object { $_ -match 'staged.config.json|other/' }).Count -eq 0)
    Check 'save: orphan commit (no parent)' (@(git --git-dir $bare rev-list --parents -n 1 refs/heads/cicd-state/prod)[0].Split(' ').Count -eq 1)

    $r = Restore-CicdState $b 'prod'
    Check 'restore: files restored byte-exact (CRLF kept)' ($r.Files -eq 3 -and [IO.File]::ReadAllText((Join-Path $b 'deploy/prod/.staged-state/state.json')) -ceq "{`"stages`":{`"1`":{`"ok`":true}}}`r`n")
    $s2 = Save-CicdState $b 'prod' 'unchanged'
    Check 'save without change: nothing pushed' (-not $s2.Pushed -and (Get-RemoteHead) -eq $s.Commit)

    # Concurrency: a and b both based on the same commit; b saves first, a must be rejected.
    $null = Restore-CicdState $a 'prod'
    Write-State $b '.dr-state/standby-state.json' '{"phase":"Data"}'
    $sb = Save-CicdState $b 'prod' 'b'
    Write-State $a '.dr-state/standby-state.json' '{"phase":"Shells"}'
    Check 'neg: concurrent save rejected, remote keeps the other run' ((Throws { Save-CicdState $a 'prod' 'a' } 'state_push_rejected') -and (Get-RemoteHead) -eq $sb.Commit)
    Check 'second save has the restored commit as parent' (@(git --git-dir $bare rev-list --parents -n 1 refs/heads/cicd-state/prod)[0] -match " $($s.Commit)$")

    # Secret scan: nothing pushed.
    $null = Restore-CicdState $b 'prod'
    Write-State $b '.dr-state/leak.json' ('{"primaryMasterKey":"' + ('A' * 86) + '=="}')
    $head = Get-RemoteHead
    Check 'neg: account key in state refused, nothing pushed' ((Throws { Save-CicdState $b 'prod' 'leak' } 'state_secret_detected: deploy/prod/.dr-state/leak.json: storage or Cosmos account key') -and (Get-RemoteHead) -eq $head)
    Remove-Item (Join-Path $b 'deploy/prod/.dr-state/leak.json')
    Write-State $b '.staged-state/tok.json' '{"t":"eyJhbGciOiJSUzI1NiJ9.eyJvaWQiOiJ4eHh4eHh4In0.c2lnbmF0dXJlc2lnbmF0dXJl"}'
    Check 'neg: JWT in state refused' (Throws { Save-CicdState $b 'prod' 'jwt' } 'bearer or access token')
    Remove-Item (Join-Path $b 'deploy/prod/.staged-state/tok.json')
    Check 'secret message names the file and kind, not the value' (-not (Throws { Save-CicdState $b 'prod' 'clean' } '.'))

    # New secret shapes (not JWT): each refused by kind, nothing pushed.
    $head = Get-RemoteHead
    $samples = [ordered]@{
        'GitHub token'              = '{"token":"ghp_' + ('a1B2' * 9) + '"}'
        'GitHub token '             = '{"t":"ghs_' + ('Z9y8' * 9) + '"}'
        'GitHub token  '            = '{"t":"github_pat_11ABCDEFG0' + ('x_Y1' * 20) + '"}'
        'Entra client secret value' = '{"value":"Abc8Q~' + ('k-9_Lm.~Qz' * 3) + 'abcd"}'
        'connection string key'     = '{"cs":"Endpoint=sb://ns.servicebus.windows.net/;SharedAccessKeyName=root;SharedAccessKey=' + ('Q' * 43) + '="}'
        'HTTP authorization header' = '{"header":"AUTHORIZATION: basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('x-access-token:abc123def456')) + '"}'
        'credentials in a URL'      = '{"remote":"https://x-access-token:s3cr3tvalue1@github.com/o/r.git"}'
        'API key'                   = '{"key1":"' + ('0123456789abcdef' * 2) + '"}'
    }
    foreach ($k in $samples.Keys) {
        Write-State $b '.dr-state/leak.json' $samples[$k]
        Check "neg: $($k.Trim()) in state refused, nothing pushed ($($samples[$k].Substring(0, 12))...)" ((Throws { Save-CicdState $b 'prod' 'leak' } "leak.json: $([regex]::Escape($k.Trim()))") -and (Get-RemoteHead) -eq $head)
    }
    Remove-Item (Join-Path $b 'deploy/prod/.dr-state/leak.json')
    Write-State $b '.dr-state/ids.json' ('{"appId":"' + [guid]::NewGuid() + '","digest":"sha256:' + ('ab' * 32) + '","id":"/subscriptions/' + [guid]::NewGuid() + '/resourceGroups/r/providers/Microsoft.Web/sites/a","etag":"\"0a00d1b2-0000-0200-0000-6553a1b20000\""}')
    Check 'identifiers, digests and etags are not secrets' (@(Find-CicdStateSecrets $b @('deploy/prod/.dr-state/ids.json')).Count -eq 0)
    Remove-Item (Join-Path $b 'deploy/prod/.dr-state/ids.json')

    function NewDr([string]$N) { $r = New-Clone $N; New-Item -ItemType Directory -Force (Join-Path $r 'deploy/dr') | Out-Null; '{}' | Set-Content (Join-Path $r 'deploy/dr/staged.config.json'); $r }
    function WriteDr([string]$Repo, [string]$Rel, [string]$Text) { $q = Join-Path $Repo "deploy/dr/$Rel"; New-Item -ItemType Directory -Force (Split-Path $q -Parent) | Out-Null; [IO.File]::WriteAllText($q, $Text) }
    function DrHead { $r = git --git-dir $bare rev-parse --verify -q refs/heads/cicd-state/dr; if ($LASTEXITCODE) { $null } else { $r } }
    # DR state fixture (layout of a real primary + standby + Front Door + health run): every state file saved and
    # restored byte-exact; only the documented regenerable files left out; unknown or oversized files fail Save.
    $d = NewDr 'drfix'; $null = Restore-CicdState $d 'dr'
    $fixture = [ordered]@{
        '.staged-state/state.json' = '{"target":{"subscriptionId":"s"},"stages":{"1":{"ok":true},"4":{"verification":"manual"}}}'
        '.staged-state/evidence/stage1-services.what-if.json' = '[{"change":"NoChange","id":"/subscriptions/s/resourceGroups/r/providers/Microsoft.Web/sites/a"}]'
        '.staged-state/stage5-config.parameters.json' = '{"parameters":{"x":{"value":1}}}'
        '.staged-state/generated/gateway-config.json' = '{"apiId":"claude-messages"}'
        '.staged-state/generated/gateway/claude-messages.policy.xml' = '<policies><inbound /></policies>'
        '.dr-state/state.json' = '{"stages":{"1":{"ok":true}}}'
        '.dr-state/standby.state.json' = '{"phases":{"Data":{"ok":true},"Code":{"packages":{"resolver":"sha256:' + ('cd' * 32) + '"}}}}'
        '.dr-state/frontdoor-state.json' = '{"profileName":"p","mode":"primary-only"}'
        '.dr-state/frontdoor.parameters.json' = '{"parameters":{}}'
        '.dr-state/dr-standby-stage5-config.parameters.json' = ('{"parameters":{"big":{"value":"' + ('x' * 100000) + '"}}}')
        '.dr-state/standby.staged.config.json' = '{"resourceGroup":"rb"}'
        '.dr-state/cosmos-throughput-preview.json' = '{"steps":[]}'
        '.dr-state/evidence/failover-status-20261117T000000Z.json' = '{"schema":"ccof.dr.failover.v1"}'
        '.dr-evidence/discover-20261117.json' = '{"checks":{}}'
        '.health-alerts-a/health-alerts.parameters.json' = '{"parameters":{"prefix":{"value":"x-health"}}}'
        '.health-alerts-a/test-notification.json' = '{"sent":true}'
        '.health-alerts-b/health-alerts.parameters.json' = '{"parameters":{"prefix":{"value":"x-b-health"}}}'
    }
    foreach ($k in $fixture.Keys) { WriteDr $d $k $fixture[$k] }
    WriteDr $d '.dr-state/frontdoor-state.lock' ''
    WriteDr $d '.staged-state/generated/admin.zip' 'PK'
    WriteDr $d '.dr-state/generated/packages/resolver/node_modules/x/index.js' 'module.exports=1'
    $sel = Get-CicdStateFiles $d 'dr'
    Check 'fixture: exactly the state files selected' ((@($sel.Files) -join ',') -ceq (@($fixture.Keys | ForEach-Object { "deploy/dr/$_" } | Sort-Object) -join ',') -and $sel.Refused.Count -eq 0)
    Check 'fixture: lock, package zip and build staging excluded with a reason' ($sel.Excluded.Count -eq 3 -and @($sel.Excluded | Where-Object { $_ -match 'lock file|deployment package|build staging' }).Count -eq 3)
    $sd = Save-CicdState $d 'dr' 'fixture'
    $e = NewDr 'drfix2'; $re = Restore-CicdState $e 'dr'
    $same = @($fixture.Keys | Where-Object { [IO.File]::ReadAllText((Join-Path $e "deploy/dr/$_")) -ceq $fixture[$_] })
    Check 'fixture: save then restore returns every state file byte-exact' ($sd.Pushed -and $re.Files -eq $fixture.Count -and $same.Count -eq $fixture.Count)
    Check 'fixture: excluded files are not on the branch' (-not (Test-Path (Join-Path $e 'deploy/dr/.dr-state/frontdoor-state.lock')) -and -not (Test-Path (Join-Path $e 'deploy/dr/.staged-state/generated/admin.zip')))
    $head = DrHead
    WriteDr $e '.dr-state/frontdoor.bicepparam' 'using x'
    Check 'neg: unknown file type fails Save, nothing pushed' ((Throws { Save-CicdState $e 'dr' 'x' } "state_file_not_saved: deploy/dr/.dr-state/frontdoor.bicepparam \(type") -and (DrHead) -eq $head)
    Remove-Item (Join-Path $e 'deploy/dr/.dr-state/frontdoor.bicepparam')
    $big = Join-Path $e 'deploy/dr/.dr-state/huge.json'; $fs = [IO.File]::Create($big); $fs.SetLength(5MB + 1); $fs.Dispose()
    Check 'neg: file over 5 MB fails Save, nothing pushed' ((Throws { Save-CicdState $e 'dr' 'x' } 'state_file_not_saved: deploy/dr/.dr-state/huge.json \(size') -and (DrHead) -eq $head)
    Remove-Item $big
    Remove-Item (Join-Path $e 'deploy/dr/.staged-state/state.json')
    Check 'neg: restored essential state missing fails Save, nothing pushed' ((Throws { Save-CicdState $e 'dr' 'x' } 'state_essential_missing: deploy/dr/.staged-state/state.json') -and (DrHead) -eq $head)
    WriteDr $e '.staged-state/state.json' $fixture['.staged-state/state.json']; Remove-Item (Join-Path $e 'deploy/dr/.dr-state/state.json')
    Check 'neg: standby staged state.json missing fails Save, nothing pushed' ((Throws { Save-CicdState $e 'dr' 'x' } 'state_essential_missing: deploy/dr/.dr-state/state.json') -and (DrHead) -eq $head)

    # Restore: only "no such ref" (ls-remote exit 2) is a first run.
    $u = New-Clone 'unreach'; git -C $u remote set-url origin (Join-Path $scratch 'missing.git')
    Check 'neg real git: missing remote repository refused, no marker' ((Throws { Restore-CicdState $u 'prod' } 'state_remote_unreachable: git ls-remote origin exited 128') -and -not (Test-Path (Join-Path $u 'deploy/prod/.cicd-state-restored')))
    $fake = Join-Path $scratch 'fake-git.ps1'
    Set-Content $fake -Value @(
        '$plan = $env:FAKE_GIT_PLAN | ConvertFrom-Json'
        '$i = 0; while ($args[$i] -in ''-C'', ''-c'') { $i += 2 }; $sub = $args[$i]'
        'if ($plan.PSObject.Properties[$sub]) { foreach ($l in @($plan.$sub.out)) { Write-Output $l }; exit [int]$plan.$sub.code }'
        '& git @args; exit $LASTEXITCODE'
    )
    $mod = Get-Module CicdState
    function With-FakeGit([hashtable]$Plan, [scriptblock]$Block) {
        $env:FAKE_GIT_PLAN = $Plan | ConvertTo-Json -Depth 4
        & $mod { param($p) $script:GitCommand = $p } $fake
        try { & $Block } finally { & $mod { $script:GitCommand = 'git' }; Remove-Item env:FAKE_GIT_PLAN -ErrorAction SilentlyContinue }
    }
    $m = New-Clone 'mock'
    $notFound = @('remote: Repository not found.', "fatal: repository 'https://github.com/o/r.git/' not found")
    Check 'neg mock: repository not found (exit 128) is not a first run' (With-FakeGit @{ 'ls-remote' = @{ code = 128; out = $notFound } } { (Throws { Restore-CicdState $m 'prod' } 'state_remote_unreachable: .*exited 128.*Repository not found') -and -not (Test-Path (Join-Path $m 'deploy/prod/.cicd-state-restored')) })
    Check 'neg mock: authentication failure is not a first run' (With-FakeGit @{ 'ls-remote' = @{ code = 128; out = @("fatal: Authentication failed for 'https://github.com/o/r.git/'") } } { Throws { Restore-CicdState $m 'prod' } 'state_remote_unreachable' })
    Check 'neg mock: network failure (exit 1) is not a first run' (With-FakeGit @{ 'ls-remote' = @{ code = 1; out = @('fatal: unable to access: Could not resolve host: github.com') } } { Throws { Restore-CicdState $m 'prod' } 'state_remote_unreachable: .*exited 1' })
    Check 'mock: no matching ref (exit 2) is a first run' (With-FakeGit @{ 'ls-remote' = @{ code = 2; out = @() } } { $x = Restore-CicdState $m 'prod'; $null -eq $x.Commit -and (Get-Content (Join-Path $m 'deploy/prod/.cicd-state-restored') -Raw) -eq 'none' })
    Remove-Item (Join-Path $m 'deploy/prod/.cicd-state-restored')
    $sha = 'a' * 40
    Check 'neg mock: ref advertised but fetch fails ("not found") is refused' (With-FakeGit @{ 'ls-remote' = @{ code = 0; out = @("$sha`trefs/heads/cicd-state/prod") }; fetch = @{ code = 128; out = @("fatal: couldn't find remote ref refs/heads/cicd-state/prod") } } { (Throws { Restore-CicdState $m 'prod' } 'state_fetch_failed: .*exited 128') -and -not (Test-Path (Join-Path $m 'deploy/prod/.cicd-state-restored')) })
    Check 'neg mock: unexpected ls-remote output refused' (With-FakeGit @{ 'ls-remote' = @{ code = 0; out = @("$sha`trefs/heads/cicd-state/prod-old") } } { Throws { Restore-CicdState $m 'prod' } 'state_ls_remote_unexpected' })
    Check 'neg mock: branch moved between ls-remote and fetch refused' (With-FakeGit @{ 'ls-remote' = @{ code = 0; out = @("$sha`trefs/heads/cicd-state/prod") } } { Throws { Restore-CicdState $m 'prod' } 'state_branch_moved' })

    # Long workspace path: a state file beyond Windows MAX_PATH (260). Git for Windows refuses it without core.longpaths
    # even when the OS long-path setting is on (repro: files\cicd-t2-lab\state-integ\Repro-LongPath.ps1).
    $lpName = 'lp'; while ((Join-Path $scratch $lpName).Length -lt 225) { $lpName = Join-Path $lpName ('w' * 30) }
    $seed = New-Clone 'lpseed'; New-Item -ItemType Directory -Force (Join-Path $seed 'deploy/lp/.dr-state') | Out-Null; [IO.File]::WriteAllText((Join-Path $seed 'deploy/lp/.dr-state/standby.state.json'), '{}')
    $null = Restore-CicdState $seed 'lp'; $null = Save-CicdState $seed 'lp' 'seed'
    $lp = New-Clone $lpName; New-Item -ItemType Directory -Force (Join-Path $lp 'deploy/lp') | Out-Null
    function WriteLp([string]$Rel, [string]$Text) { $q = Join-Path $lp "deploy/lp/$Rel"; [IO.Directory]::CreateDirectory((Split-Path $q -Parent)) | Out-Null; [IO.File]::WriteAllText($q, $Text) }
    $lpRel = '.dr-state/evidence/standby-network-preview-20261118T004000Z-long-workspace.json'
    $lpR0 = $null; try { $lpR0 = Restore-CicdState $lp 'lp' } catch { Write-Host "long path restore (existing branch): $($_.Exception.Message)" }
    Check 'long path: Restore fetches the existing state branch' ($lpR0.Commit -and [IO.File]::Exists((Join-Path $lp 'deploy/lp/.dr-state/standby.state.json')))
    WriteLp $lpRel '{"phase":"Network","ok":true}'
    WriteLp '.dr-state/standby.state.json' '{"phase":"Network"}'
    $lpSave = $null; try { $lpSave = Save-CicdState $lp 'lp' 'long path' } catch { Write-Host "long path save: $($_.Exception.Message)" }
    Check "long path: Save pushes a state file of $((Join-Path $lp "deploy/lp/$lpRel").Length) characters" ((Join-Path $lp "deploy/lp/$lpRel").Length -gt 260 -and $lpSave.Pushed -and (@(git --git-dir $bare ls-tree -r --name-only refs/heads/cicd-state/lp) -contains "deploy/lp/$lpRel"))
    $lp2 = New-Clone (Join-Path (Split-Path $lpName) 'clone2'); New-Item -ItemType Directory -Force (Join-Path $lp2 'deploy/lp') | Out-Null
    $lpR = $null; try { $lpR = Restore-CicdState $lp2 'lp' } catch { Write-Host "long path restore: $($_.Exception.Message)" }
    Check 'long path: fresh restore is byte-exact' ($lpR.Commit -and [IO.File]::Exists((Join-Path $lp2 "deploy/lp/$lpRel")) -and [IO.File]::ReadAllText((Join-Path $lp2 "deploy/lp/$lpRel")) -eq '{"phase":"Network","ok":true}')
    Check 'long path: no git configuration was written (per-command setting only)' (-not (git -C $lp config --local --get core.longpaths) -and -not (git -C $lp2 config --local --get core.longpaths))

    # Guards.
    $c = New-Clone 'c'
    Check 'neg: save without restore refused' (Throws { Save-CicdState $c 'prod' 'x' } 'state_not_restored')
    Check 'neg: invalid environment name refused' (Throws { Restore-CicdState $c '../prod' } 'invalid_environment')
    Check 'neg: missing environment folder refused' (Throws { Restore-CicdState $c 'stg' } 'environment_folder_missing')
    $x = New-Clone 'x'; Write-State $x 'staged.config.json' '{}'
    git -C $x add -f deploy/prod/staged.config.json; git -C $x commit -q -m bad; git -C $x push -q origin HEAD:refs/heads/cicd-state/bad 2>$null
    New-Item -ItemType Directory -Force (Join-Path $c 'deploy/bad') | Out-Null
    Check 'neg: branch with a path outside the state folders refused' (Throws { Restore-CicdState $c 'bad' } 'state_branch_unexpected_path')

    # Script wrapper.
    $out = & pwsh -NoProfile -File (Join-Path $root 'scripts\cicd\Sync-CicdState.ps1') -Action Restore -Environment prod -RepositoryRoot $c 2>&1
    Check 'script: Restore through the wrapper' ($LASTEXITCODE -eq 0 -and ($out -join ' ') -match 'restored 4 file')
    $null = & pwsh -NoProfile -File (Join-Path $root 'scripts\cicd\Sync-CicdState.ps1') -Action Save -Environment prod -RepositoryRoot (New-Clone 'd') 2>&1
    Check 'neg script: Save without Restore exits non-zero' ($LASTEXITCODE -ne 0)

    # stderr is never parsed as output: GIT_TRACE makes every git command write trace lines to stderr (any OS).
    $tr = New-Clone 'trace'; $env:GIT_TRACE = '1'
    try { $trR = $null; try { $trR = Restore-CicdState $tr 'prod' } catch { Write-Host "trace restore: $($_.Exception.Message)" }
        Check 'stderr noise: Restore records the real commit, not a git stderr line' ($trR.Commit -eq (Get-RemoteHead) -and (Get-Content (Join-Path $tr 'deploy/prod/.cicd-state-restored') -Raw) -eq (Get-RemoteHead))
        Write-State $tr '.dr-state/evidence/trace.json' '{"t":1}'
        $trS = $null; try { $trS = Save-CicdState $tr 'prod' 'trace' } catch { Write-Host "trace save: $($_.Exception.Message)" }
        Check 'stderr noise: Save pushes a commit hash' ($trS.Pushed -and $trS.Commit -match '^[0-9a-f]{40}$' -and $trS.Commit -eq (Get-RemoteHead)) }
    finally { Remove-Item env:GIT_TRACE -ErrorAction SilentlyContinue }

    # A driver that crashed mid-write leaves a truncated essential state file: it must never replace the good snapshot.
    $tj = New-Clone 'tj'; $null = Restore-CicdState $tj 'prod'; $h0 = Get-RemoteHead
    Write-State $tj '.staged-state/state.json' '{"stages":{"1":{"ok":tr'
    Write-State $tj '.dr-state/evidence/crash.json' '{"partial":'
    Check 'neg: truncated essential JSON refused, remote unchanged' ((Throws { Save-CicdState $tj 'prod' 'crash' } 'state_invalid_json: deploy/prod/\.staged-state/state\.json') -and (Get-RemoteHead) -eq $h0)
    Write-State $tj '.staged-state/state.json' ''
    Check 'neg: empty essential state file refused' ((Throws { Save-CicdState $tj 'prod' 'crash' } 'state_invalid_json') -and (Get-RemoteHead) -eq $h0)
    Write-State $tj '.staged-state/state.json' '{"stages":{"1":{"ok":true}}}'
    $tjS = Save-CicdState $tj 'prod' 'crash evidence'
    Check 'partial evidence JSON is still saved byte-exact (recovery evidence, not essential)' ($tjS.Pushed -and ((git --git-dir $bare show "refs/heads/cicd-state/prod:deploy/prod/.dr-state/evidence/crash.json") -join '') -eq '{"partial":')
    $fj = New-Clone 'fj'; New-Item -ItemType Directory -Force (Join-Path $fj 'deploy/fj') | Out-Null; $null = Restore-CicdState $fj 'fj'
    [IO.Directory]::CreateDirectory((Join-Path $fj 'deploy/fj/.dr-state')) | Out-Null; [IO.File]::WriteAllText((Join-Path $fj 'deploy/fj/.dr-state/standby.state.json'), '{"phases":')
    Check 'neg: first save with an invalid essential file refused' ((Throws { Save-CicdState $fj 'fj' 'first' } 'state_invalid_json') -and -not (git --git-dir $bare rev-parse --verify -q refs/heads/cicd-state/fj))} finally {
    Get-ChildItem $scratch -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

$auth = Get-CicdStateFetchAuth -Token 'tok123' -ServerUrl 'https://github.com/'
$expected = 'AUTHORIZATION: basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('x-access-token:tok123'))
Check 'fetch auth: token passed through GIT_CONFIG_* for the server' ($auth['GIT_CONFIG_COUNT'] -eq '1' -and $auth['GIT_CONFIG_KEY_0'] -eq 'http.https://github.com/.extraheader' -and $auth['GIT_CONFIG_VALUE_0'] -eq $expected)
Check 'neg: fetch auth without a token adds nothing' ((Get-CicdStateFetchAuth -Token '' -ServerUrl 'https://github.com').Count -eq 0)

Write-Host "Test-CicdState: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 54) { exit 1 }
