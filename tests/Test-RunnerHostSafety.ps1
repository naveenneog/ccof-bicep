# Offline host-safety tests for scripts/cicd/Install-CcofRunner.sh and .ps1 on an existing (customer) host:
# the bootstrap touches only its own runner service and dedicated directories, and refuses unsafe paths,
# runner users and credential-bearing proxies. Services are mocked (fake systemctl, mocked Windows cmdlets);
# nothing on this machine is stopped, deleted or installed.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("ccof-hostsafety-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory $scratch | Out-Null

# ---- Linux bootstrap (Git for Windows bash; skipped when absent)
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", '/bin/bash') | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ($bash) {
    $toBash = { param($p) ($p -replace '\\', '/') -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLowerInvariant() } }
    $sh = & $toBash (Join-Path $repo 'scripts/cicd/Install-CcofRunner.sh')
    $root = Join-Path $scratch 'lin'; $bin = Join-Path $root 'fakebin'; $units = Join-Path $root 'units'
    New-Item -ItemType Directory $bin, $units | Out-Null
    $log = Join-Path $root 'systemctl.log'
    # Fake systemctl: logs every call; `cat -- <unit>` prints units/<unit> when it exists.
    [IO.File]::WriteAllText((Join-Path $bin 'systemctl'), "#!/bin/bash`necho `"`$*`" >>`"`$FAKE_LOG`"`nif [ `"`$1`" = cat ]; then f=`"`$FAKE_UNITS/`${3:-`$2}`"; [ -f `"`$f`" ] && cat `"`$f`" && exit 0; exit 1; fi`nexit 0`n")
    function Unit([string]$Name, [string]$Dir) { [IO.File]::WriteAllText((Join-Path $units $Name), "[Service]`nExecStart=$Dir/runsvc.sh`nWorkingDirectory=$Dir`n") }
    function New-RunnerDir([string]$Name, [string]$ServiceName) {
        $d = Join-Path $root $Name; New-Item -ItemType Directory $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d '.ccof-owned'), '')
        if ($ServiceName) { [IO.File]::WriteAllText((Join-Path $d '.service'), "$ServiceName`n") }
        & $toBash $d
    }
    function Invoke-Sh([string[]]$Arguments) {
        if (Test-Path $log) { Remove-Item $log }
        $env:FAKE_LOG = & $toBash $log; $env:FAKE_UNITS = & $toBash $units
        try {
            $q = ($Arguments | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
            $out = & $bash -c "export PATH=`"$(& $toBash $bin)`":`$PATH; bash '$sh' $q" 2>&1
            return @{ code = $LASTEXITCODE; out = "$out"; calls = @(if (Test-Path $log) { Get-Content $log }) }
        } finally { Remove-Item env:FAKE_LOG, env:FAKE_UNITS -ErrorAction SilentlyContinue }
    }
    $tools = & $toBash (Join-Path $root 'tools')
    function Chk([string]$Dir, [string[]]$More = @()) { Invoke-Sh (@('check', '--role', 'apply', '--runner-dir', $Dir, '--tools-dir', $tools) + $More) }

    # Two unrelated runner services on the same host, plus ours.
    $ours = New-RunnerDir 'ours' 'actions.runner.contoso-app.ccof-apply.service'
    Unit 'actions.runner.contoso-app.ccof-apply.service' $ours
    Unit 'actions.runner.other-org-repo.build1.service' '/srv/other-runner-1'
    Unit 'actions.runner.other-org-repo.build2.service' '/opt/other-runner-2'
    $r = Chk $ours
    Check 'sh check: resolves exactly the unit named in RUNNER_DIR/.service' ($r.code -eq 0 -and $r.out -match 'service: actions\.runner\.contoso-app\.ccof-apply\.service')
    Check 'sh check: only reads its own unit (no stop/disable/list of other runner services)' ($r.calls.Count -eq 1 -and $r.calls[0] -eq 'cat -- actions.runner.contoso-app.ccof-apply.service')
    $foreign = New-RunnerDir 'foreign' 'actions.runner.other-org-repo.build1.service'
    $r = Chk $foreign
    Check 'sh check: a .service naming another runner''s unit is refused, not touched' ($r.code -ne 0 -and $r.out -match 'not touched' -and -not ($r.calls -match 'stop|disable'))
    $r = Chk (New-RunnerDir 'gone' 'actions.runner.contoso-app.missing.service')
    Check 'sh check: a .service naming a unit that is not installed fails' ($r.code -ne 0 -and $r.out -match 'not installed')
    $r = Chk (New-RunnerDir 'evil' 'actions.runner.x.service; systemctl stop sshd')
    Check 'sh check: a malformed .service is refused before systemctl runs' ($r.code -ne 0 -and $r.calls.Count -eq 0)
    $r = Chk (New-RunnerDir 'fresh' '')
    Check 'sh check: no .service means no service (nothing else is picked)' ($r.code -eq 0 -and $r.out -match 'service: none' -and $r.calls.Count -eq 0)

    foreach ($bad in '/', '/etc', '/usr/local', '/opt', '/var/lib', '/home/ghrunner', '/tmp/runner', 'opt/runner', '/opt/../etc/x', '/opt/./x', '/root/runner') {
        $r = Chk $bad
        Check "sh check: runner-dir '$bad' is refused" ($r.code -eq 2)
    }
    $adj = Join-Path $root 'adjacent'; New-Item -ItemType Directory $adj | Out-Null; [IO.File]::WriteAllText((Join-Path $adj 'data.txt'), 'user data')
    $r = Chk (& $toBash $adj)
    Check 'sh check: an existing non-empty directory without the CCOF marker is refused' ($r.code -eq 2 -and $r.out -match 'not empty')
    Check 'sh check: the refused directory is left as it was' ((Get-Content (Join-Path $adj 'data.txt')) -eq 'user data')
    $r = Chk ((& $toBash $adj) + '-new')
    Check 'sh check: a new sibling of an existing directory is accepted' ($r.code -eq 0)
    $target = Join-Path $root 'linktarget'; New-Item -ItemType Directory $target | Out-Null
    $lnk = & $bash -c "MSYS=winsymlinks:nativestrict ln -s '$(& $toBash $target)' '$(& $toBash $root)/link' && [ -L '$(& $toBash $root)/link' ] && echo ok" 2>$null
    if ("$lnk" -eq 'ok') {
        $r = Chk ((& $toBash $root) + '/link/runner')
        Check 'sh check: a runner-dir through a symbolic link is refused' ($r.code -eq 2 -and $r.out -match 'symbolic link')
    } else { Write-Host 'SKIP symlink case: native symlinks are not available' }
    $r = Chk $ours @('--runner-user', 'root')
    Check 'sh check: runner-user root is refused' ($r.code -eq 2 -and $r.out -match 'must not be root')
    $fakeTools = Join-Path $root 'usedtools'; New-Item -ItemType Directory $fakeTools | Out-Null; [IO.File]::WriteAllText((Join-Path $fakeTools 'x'), '')
    $r = Invoke-Sh @('check', '--role', 'apply', '--runner-dir', $ours, '--tools-dir', (& $toBash $fakeTools))
    Check 'sh check: a tools-dir with foreign content is refused' ($r.code -eq 2)
    $legacy = Join-Path $root 'legacytools'; New-Item -ItemType Directory (Join-Path $legacy 'node'), (Join-Path $legacy 'pwsh') | Out-Null
    $r = Invoke-Sh @('check', '--role', 'apply', '--runner-dir', $ours, '--tools-dir', (& $toBash $legacy))
    Check 'sh check: an earlier CCOF tools-dir (node, pwsh only) is accepted' ($r.code -eq 0)
    $r = Chk $ours @('--proxy', 'http://fakeuser:FAKEPASS123@proxy.example:8080')
    Check 'sh: a credential-bearing proxy is refused and not echoed' ($r.code -eq 2 -and $r.out -notmatch 'FAKEPASS123|fakeuser')

    $text = Get-Content -Raw (Join-Path $repo 'scripts/cicd/Install-CcofRunner.sh')
    foreach ($p in 'list-unit-files', 'git config --system', 'ln -sf[^\n]*/usr/local/bin', 'update-ca-trust', 'update-ca-certificates', 'restorecon[^\n]*/usr/local/bin', 'chown -R "') {
        Check "sh static: no '$p'" ($text -notmatch $p)
    }
    Check 'sh static: .env is written root:runner 640' ($text -match 'chown root:"\$RUNNER_USER" "\$RUNNER_DIR/\.env\.new" && chmod 640')
} else { Write-Host 'SKIP bash checks: Git for Windows bash not found' }

Remove-Item -Recurse -Force $scratch
Write-Host "Test-RunnerHostSafety: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
