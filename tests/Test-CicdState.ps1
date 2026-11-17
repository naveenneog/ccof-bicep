#Requires -Version 7.0
# Offline tests of scripts/cicd/Sync-CicdState.ps1 (CicdState.psm1) against a local bare repository.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts\cicd\CicdState.psm1') -Force
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
function Throws([scriptblock]$Block, [string]$Pattern) { try { $null = & $Block; return $false } catch { return $_.Exception.Message -match $Pattern } }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ccof-cicd-state-' + [guid]::NewGuid().ToString('N'))
$bare = Join-Path $scratch 'remote.git'
function New-Clone([string]$Name) {
    $dir = Join-Path $scratch $Name
    git init -q $dir; git -C $dir config user.email t@example.com; git -C $dir config user.name t; git -C $dir config core.autocrlf false
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
    git init -q --bare $bare
    $a = New-Clone 'a'; $b = New-Clone 'b'

    $r = Restore-CicdState $a 'prod'
    Check 'first restore: no branch, nothing restored, marker none' ($null -eq $r.Commit -and $r.Files -eq 0 -and (Get-Content (Join-Path $a 'deploy/prod/.cicd-state-restored') -Raw) -eq 'none')

    Write-State $a '.staged-state/state.json' "{`"stages`":{`"1`":{`"ok`":true}}}`r`n"
    Write-State $a '.dr-state/frontdoor-state.json' '{"profileName":"p"}'
    Write-State $a '.health-alerts-a/state.json' '{"x":1}'
    Write-State $a '.dr-state/package.zip' 'PK'
    Write-State $a 'other/notes.json' '{}'
    $s = Save-CicdState $a 'prod' 'first'
    $tree = @(git --git-dir $bare ls-tree -r --name-only refs/heads/cicd-state/prod)
    Check 'save: pushed the allowed state files only' ($s.Pushed -and $tree.Count -eq 3 -and $tree -contains 'deploy/prod/.staged-state/state.json' -and $tree -notcontains 'deploy/prod/.dr-state/package.zip')
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
} finally {
    Get-ChildItem $scratch -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

$auth = Get-CicdStateFetchAuth -Token 'tok123' -ServerUrl 'https://github.com/'
$expected = 'AUTHORIZATION: basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('x-access-token:tok123'))
Check 'fetch auth: token passed through GIT_CONFIG_* for the server' ($auth['GIT_CONFIG_COUNT'] -eq '1' -and $auth['GIT_CONFIG_KEY_0'] -eq 'http.https://github.com/.extraheader' -and $auth['GIT_CONFIG_VALUE_0'] -eq $expected)
Check 'neg: fetch auth without a token adds nothing' ((Get-CicdStateFetchAuth -Token '' -ServerUrl 'https://github.com').Count -eq 0)

Write-Host "Test-CicdState: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 17) { exit 1 }
