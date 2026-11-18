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
    # Reviewed-main attestation: refused before any check of the host or any change (no systemctl call).
    $reg = @('register', '--role', 'apply', '--client-id', '11111111-1111-4111-8111-111111111111', '--subscription-id', '22222222-2222-4222-8222-222222222222',
        '--tenant-id', '33333333-3333-4333-8333-333333333333', '--repository', 'octo/ccof-lab', '--runner-name', 'lab-apply', '--allowed-workflows', '.github/workflows/deploy.yml', '--runner-dir', $ours, '--tools-dir', $tools)
    foreach ($v in @($null, 'no', 'YES')) {
        $r = Invoke-Sh ($reg + @(if ($null -ne $v) { '--reviewed-main-enforced', $v }))
        Check "sh register: reviewed-main attestation '$v' is refused before any change" ($r.code -eq 2 -and $r.out -match 'needs --reviewed-main-enforced yes' -and $r.out -match 'nobody bypass' -and $r.calls.Count -eq 0)
    }
    $r = Invoke-Sh ($reg + @('--reviewed-main-enforced', 'yes'))
    Check 'sh register: with the attestation it goes on to the host checks (here: not root)' ($r.code -eq 2 -and $r.out -notmatch 'reviewed-main-enforced' -and $r.out -match 'run as root')

    # Runner directory lock. Jobs run as the runner user; a directory owner can unlink and replace any child whatever
    # the child's owner, so only _work and _diag may belong to that user. chown/chmod are logging fakes; find is real.
    $lk = Join-Path $root 'lockdir'; $lbin = Join-Path $root 'lockbin'; $llog = Join-Path $root 'lock.log'
    New-Item -ItemType Directory $lbin, (Join-Path $lk 'bin'), (Join-Path $lk 'externals/node22/bin'), (Join-Path $lk '_work/repo'), (Join-Path $lk '_diag') | Out-Null
    $lockFiles = '.env', '.runner', '.credentials', '.credentials_rsaparams'
    foreach ($f in @('bin/Runner.Listener', 'externals/node22/bin/node', '.path', 'config.sh', 'runsvc.sh', '_work/repo/x', '_diag/Runner_1.log') + $lockFiles) { [IO.File]::WriteAllText((Join-Path $lk $f), '') }
    foreach ($c in 'chown', 'chmod') {
        [IO.File]::WriteAllText((Join-Path $lbin $c), "#!/bin/bash`nh=''; s=''`nfor a in `"`$@`"; do case `"`$a`" in -h) h=' -h' ;; -*) echo `"$c REFUSED-OPTION `$a`" >>`"`$LOCK_LOG`"; exit 1 ;; *) if [ -z `"`$s`" ]; then s=`"`$a`"; else echo `"$c`$h `$s `$a`" >>`"`$LOCK_LOG`"; fi ;; esac; done`n")
    }
    function Invoke-Lock([string]$Dir) {
        if (Test-Path $llog) { Remove-Item $llog }
        $cmd = "export PATH=`"$(& $toBash $lbin)`":`$PATH LOCK_LOG='$(& $toBash $llog)'; fail() { echo `"failed: `$*`"; exit 3; }; RUNNER_DIR='$(& $toBash $Dir)'; RUNNER_USER=ghrunner; " +
            "eval `"`$(sed -n '/^lock_runner_dir() {/,/^}/p' '$sh')`"; type lock_runner_dir >/dev/null 2>&1 || { echo 'no lock_runner_dir'; exit 9; }; lock_runner_dir && echo locked"
        $out = & $bash -c $cmd 2>&1
        @{ code = $LASTEXITCODE; out = "$out"; calls = @(if (Test-Path $llog) { Get-Content $llog }) }
    }
    $lb = & $toBash $lk
    $r = Invoke-Lock $lk; $c = $r.calls
    Check 'sh lock: lock_runner_dir runs' ($r.code -eq 0 -and $r.out -match 'locked')
    Check 'sh lock: runner binaries, runsvc.sh and scripts become root:root without following links' (
        @("$lb/bin", "$lb/bin/Runner.Listener", "$lb/externals/node22/bin/node", "$lb/runsvc.sh", "$lb/config.sh" | Where-Object { $c -cnotcontains "chown -h root:root $_" }).Count -eq 0)
    Check 'sh lock: .env, .runner and the credentials are root:<runner user> 640' (
        @($lockFiles | Where-Object { $c -cnotcontains "chown root:ghrunner $lb/$_" -or $c -cnotcontains "chmod 640 $lb/$_" }).Count -eq 0)
    Check 'sh lock: the runner directory itself is root:<runner user> 750' ($c -ccontains "chown root:ghrunner $lb" -and $c -ccontains "chmod 750 $lb")
    Check 'sh lock: group and other write is removed from the rest' ($c -ccontains "chmod go-w $lb/bin/Runner.Listener" -and $c -ccontains "chmod go-w $lb/runsvc.sh")
    $toUser = @($c | Where-Object { $_ -match 'ghrunner:ghrunner' } | ForEach-Object { $_ -replace '^chown -h ghrunner:ghrunner ', '' } | Sort-Object)
    Check 'sh lock: only _work, _work/_tmp and _diag are given to the runner user' (($toUser -join '|') -ceq (@("$lb/_diag", "$lb/_work", "$lb/_work/_tmp") -join '|'))
    Check 'sh lock: nothing inside _work or _diag is changed (job content, links)' (@($c | Where-Object { $_ -match [regex]::Escape("$lb/") + '(_work|_diag)/' -and $_ -notmatch '_work/_tmp$' }).Count -eq 0)
    Check 'sh lock: no recursive chown or chmod' (-not ($c -match 'REFUSED-OPTION'))
    $lk2 = Join-Path $root 'lockdir2'; New-Item -ItemType Directory $lk2 | Out-Null
    $lnk2 = & $bash -c "MSYS=winsymlinks:nativestrict ln -s '$(& $toBash $target)' '$(& $toBash $lk2)/_work' && [ -L '$(& $toBash $lk2)/_work' ] && echo ok" 2>$null
    if ("$lnk2" -eq 'ok') {
        $r = Invoke-Lock $lk2
        Check 'sh lock: a _work that is a symbolic link fails before any change' ($r.code -eq 3 -and $r.out -match 'symbolic link' -and $r.calls.Count -eq 0)
    } else { Write-Host 'SKIP lock symlink case: native symlinks are not available' }

    $text = Get-Content -Raw (Join-Path $repo 'scripts/cicd/Install-CcofRunner.sh')
    $regBody = [regex]::Match($text, '(?s)\ndo_register\(\) \{.*?\n\}').Value; $instBody = [regex]::Match($text, '(?s)\ndo_install\(\) \{.*?\n\}').Value
    Check 'sh static: register runs config.sh as root for that command only, with --disableupdate' ($regBody -match 'RUNNER_ALLOW_RUNASROOT=1 \./config\.sh --unattended' -and $regBody -match '--replace --disableupdate')
    Check 'sh static: config.sh never runs as the runner user (it would need a writable runner directory)' ($text -notmatch 'runuser[^\n]*config\.sh')
    Check 'sh static: register locks the directory after svc.sh install and before svc.sh start' ($regBody -match '(?s)svc\.sh install.*\n\s*lock_runner_dir\n.*svc\.sh start')
    Check 'sh static: install locks the directory and never gives it to the runner user' ($instBody -match '\n\s*lock_runner_dir\n' -and $instBody -notmatch 'chown[^\n]*"\$RUNNER_USER:\$RUNNER_USER" "\$RUNNER_DIR"')
    Check 'sh static: a runner installed by an earlier bootstrap gets fresh bin and externals' ($instBody -match '\.ccof-layout' -and $instBody -match 'rm -rf -- "\$RUNNER_DIR/bin" "\$RUNNER_DIR/externals"' -and $regBody -match '\.ccof-layout')
    foreach ($p in 'list-unit-files', 'git config --system', 'ln -sf[^\n]*/usr/local/bin', 'update-ca-trust', 'update-ca-certificates', 'restorecon[^\n]*/usr/local/bin', 'chown -R "') {
        Check "sh static: no '$p'" ($text -notmatch $p)
    }
    Check 'sh static: .env is written root:runner 640' ($text -match 'chown root:"\$RUNNER_USER" "\$RUNNER_DIR/\.env\.new" && chmod 640')

    # Registration lifecycle (ADR 0042), run from the real do_register/do_remove bodies with fake config.sh and svc.sh that
    # log whether they see RUNNER_ALLOW_RUNASROOT. Host-changing helpers are stubs; the fake token is not a real one.
    $rd = Join-Path $root 'regdir'; $rlog = Join-Path $root 'reg.log'; New-Item -ItemType Directory $rd | Out-Null
    [IO.File]::WriteAllText((Join-Path $rd '.ccof-layout'), "root-locked-1`n")
    [IO.File]::WriteAllText((Join-Path $rd 'config.sh'), "#!/bin/bash`nf=''; for a in `"`$@`"; do case `"`$a`" in --replace|--disableupdate) f=`"`$f`$a`" ;; esac; done`necho `"config.sh `$1 `$f root=`${RUNNER_ALLOW_RUNASROOT-unset}`" >>`"`$REG_LOG`"`n")
    [IO.File]::WriteAllText((Join-Path $rd 'svc.sh'), "#!/bin/bash`necho `"svc.sh `$1 root=`${RUNNER_ALLOW_RUNASROOT-unset}`" >>`"`$REG_LOG`"`n")
    function Invoke-Lifecycle([string]$Fn, [string]$Lock = 'echo "lock root=${RUNNER_ALLOW_RUNASROOT-unset}" >>"$REG_LOG"', [string]$Svc = '') {
        if (Test-Path $rlog) { Remove-Item $rlog }
        $rb = & $toBash $rd
        $cmd = "set -euo pipefail; export REG_LOG='$(& $toBash $rlog)'; chmod +x '$rb/config.sh' '$rb/svc.sh'; fail() { echo `"failed: `$*`"; exit 3; }; refuse() { echo `"refused: `$*`"; exit 2; }; note() { :; }; " +
            "mkdir() { :; }; chown() { :; }; chmod() { :; }; print_hook() { :; }; write_env() { :; }; selinux_fix() { :; }; own_service() { SVC='$Svc'; }; lock_runner_dir() { $Lock; }; " +
            "RUNNER_DIR='$rb'; RUNNER_USER=ghrunner; LOG=/dev/null; POLICY='$rb.policy'; HOOK='$rb.hook'; ROLE=apply; REPOSITORY=octo/ccof-lab; RUNNER_NAME=lab-apply; LABELS=ccof-vnet,ccof-apply; " +
            "ALLOWED_REFS=refs/heads/main; ALLOWED_WORKFLOWS=.github/workflows/deploy.yml; RUNNER_TOKEN=FAKEFAKEFAKEFAKEFAKEFAKE; unset RUNNER_ALLOW_RUNASROOT; " +
            "eval `"`$(sed -n '/^$Fn() {/,/^}/p' '$sh')`"; type $Fn >/dev/null 2>&1 || { echo 'no $Fn'; exit 9; }; $Fn; echo `"after root=`${RUNNER_ALLOW_RUNASROOT-unset}`" >>`"`$REG_LOG`""
        $out = & $bash -c $cmd 2>&1
        @{ code = $LASTEXITCODE; out = "$out"; log = @(if (Test-Path $rlog) { Get-Content $rlog }) }
    }
    $r = Invoke-Lifecycle do_register
    Check 'sh register: only config.sh sees RUNNER_ALLOW_RUNASROOT=1 (--replace --disableupdate); svc.sh, the lock and the caller do not' (
        $r.code -eq 0 -and @($r.log | Where-Object { $_ -match 'root=1' }).Count -eq 1 -and $r.log -ccontains 'config.sh --unattended --replace--disableupdate root=1' -and $r.log[-1] -ceq 'after root=unset')
    Check 'sh register: config.sh, then svc.sh install, then lock_runner_dir, then svc.sh start' (
        ($r.log -join '|') -ceq 'config.sh --unattended --replace--disableupdate root=1|svc.sh install root=unset|lock root=unset|svc.sh start root=unset|after root=unset')
    $r = Invoke-Lifecycle do_register 'echo "lock failed" >>"$REG_LOG"; return 1'
    Check 'sh register: a failed lock stops registration before svc.sh start' ($r.code -ne 0 -and $r.log -ccontains 'lock failed' -and -not ($r.log -match 'svc\.sh start'))
    $r = Invoke-Lifecycle do_remove -Svc 'actions.runner.octo-ccof-lab.lab-apply.service'
    Check 'sh remove: only config.sh remove sees RUNNER_ALLOW_RUNASROOT=1; svc.sh stop and uninstall and the caller do not' (
        $r.code -eq 0 -and ($r.log -join '|') -ceq 'svc.sh stop root=unset|svc.sh uninstall root=unset|config.sh remove  root=1|after root=unset')
} else { Write-Host 'SKIP bash checks: Git for Windows bash not found' }

# ---- Windows bootstrap: check/status with mocked service cmdlets in a child pwsh (no real service is queried or changed)
if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    $ps1 = Join-Path $repo 'scripts/cicd/Install-CcofRunner.ps1'
    $wroot = Join-Path $scratch 'win'; New-Item -ItemType Directory $wroot | Out-Null
    $calls = Join-Path $wroot 'calls.log'
    function Invoke-Win([string[]]$Arguments, [hashtable[]]$Services = @()) {
        if (Test-Path $calls) { Remove-Item $calls }
        $svcJson = ConvertTo-Json -Compress -Depth 3 @($Services)
        $driver = @"
`$ErrorActionPreference = 'Stop'
`$env:PUBLIC = 'C:\ccof-test-no-profiles\Public'   # the scratch dir is under the real profiles root
`$global:svc = '$($svcJson -replace "'", "''")' | ConvertFrom-Json
function global:Log([string]`$s) { Add-Content -LiteralPath '$calls' `$s }
function global:Get-CimInstance { param(`$ClassName, `$Filter, `$ErrorAction) Log "cim `$Filter"; if (`$Filter -match "Name='([^']+)'") { `$global:svc | Where-Object Name -eq `$Matches[1] } }
function global:Get-Service { param(`$Name) Log "get `$Name"; `$global:svc | Where-Object Name -like `$Name | ForEach-Object { [pscustomobject]@{ Name = `$_.Name; Status = `$_.Status } } }
function global:Stop-Service { Log "STOP `$args" }
function global:Start-Service { Log "START `$args" }
function global:Restart-Service { Log "RESTART `$args" }
function global:sc.exe { Log "SC `$args" }
& '$ps1' @args
exit `$LASTEXITCODE
"@
        $dfile = Join-Path $wroot 'driver.ps1'; Set-Content $dfile $driver
        $out = & pwsh -NoProfile -File $dfile @Arguments 2>&1
        @{ code = $LASTEXITCODE; out = "$out"; calls = @(if (Test-Path $calls) { Get-Content $calls }) }
    }
    $tools = Join-Path $wroot 'tools'
    $ours = Join-Path $wroot 'runner'; New-Item -ItemType Directory $ours | Out-Null; Set-Content (Join-Path $ours '.ccof-owned') ''
    Set-Content (Join-Path $ours '.service') 'actions.runner.contoso-app.ccof-apply'
    $svcs = @(
        @{ Name = 'actions.runner.other-org-repo.build1'; Status = 'Running'; PathName = '"D:\other-runner-1\bin\RunnerService.exe"' },
        @{ Name = 'actions.runner.other-org-repo.build2'; Status = 'Running'; PathName = '"E:\agents\r2\bin\RunnerService.exe"' },
        @{ Name = 'actions.runner.contoso-app.ccof-apply'; Status = 'Stopped'; PathName = "`"$ours\bin\RunnerService.exe`"" })
    $r = Invoke-Win @('check', '-Role', 'apply', '-RunnerDir', $ours, '-ToolsDir', $tools) $svcs
    Check 'ps check: resolves exactly the service named in RunnerDir\.service' ($r.code -eq 0 -and $r.out -match 'service: actions\.runner\.contoso-app\.ccof-apply')
    Check 'ps check: queries only its own service, never a wildcard' ($r.calls.Count -eq 1 -and $r.calls[0] -eq "cim Name='actions.runner.contoso-app.ccof-apply'")
    $r = Invoke-Win @('status', '-Role', 'apply', '-RunnerDir', $ours, '-ToolsDir', $tools) $svcs
    Check 'ps status: reports its own (stopped) service, not the first running unrelated one' ($r.code -eq 3 -and $r.out -match 'contoso-app\.ccof-apply Stopped' -and $r.out -notmatch 'build1|build2')
    Check 'ps status: unrelated services are not stopped, deleted or restarted' (-not ($r.calls -match 'STOP|START|RESTART|SC|build'))
    Set-Content (Join-Path $ours '.service') 'actions.runner.other-org-repo.build1'
    $r = Invoke-Win @('check', '-Role', 'apply', '-RunnerDir', $ours, '-ToolsDir', $tools) $svcs
    Check 'ps check: a .service naming a service with another binary path is refused, not touched' ($r.code -eq 3 -and $r.out -match 'no service is touched' -and -not ($r.calls -match 'STOP|SC|RESTART'))
    Set-Content (Join-Path $ours '.service') "actions.runner.x' OR Name LIKE '%"
    $r = Invoke-Win @('check', '-Role', 'apply', '-RunnerDir', $ours, '-ToolsDir', $tools) $svcs
    Check 'ps check: a malformed .service is refused before any service query' ($r.code -eq 3 -and $r.calls.Count -eq 0)
    Remove-Item (Join-Path $ours '.service')
    $r = Invoke-Win @('check', '-Role', 'apply', '-RunnerDir', $ours, '-ToolsDir', $tools) $svcs
    Check 'ps check: no .service means no service (nothing else is picked)' ($r.code -eq 0 -and $r.out -match 'service: none' -and $r.calls.Count -eq 0)

    $adj = Join-Path $wroot 'adjacent'; New-Item -ItemType Directory $adj | Out-Null; Set-Content (Join-Path $adj 'data.txt') 'user data'
    $junction = Join-Path $wroot 'junction'; New-Item -ItemType Junction -Path $junction -Target $adj | Out-Null
    foreach ($bad in 'C:\', 'C:\Windows', "$env:SystemRoot\Temp\r", $env:ProgramFiles, $env:ProgramData, 'C:\ccof-test-no-profiles\navg\r', 'runner', 'C:\a\..\Windows', 'C:\x\', $adj, "$junction\r") {
        $r = Invoke-Win @('check', '-Role', 'apply', '-RunnerDir', $bad, '-ToolsDir', $tools)
        Check "ps check: RunnerDir '$bad' is refused" ($r.code -eq 2)
    }
    Check 'ps check: the refused directory is left as it was' ((Get-Content (Join-Path $adj 'data.txt')) -eq 'user data')
    $r = Invoke-Win @('check', '-Role', 'apply', '-RunnerDir', $ours, '-ToolsDir', $adj)
    Check 'ps check: a ToolsDir with foreign content is refused' ($r.code -eq 2)
    $legacy = Join-Path $wroot 'legacytools'; New-Item -ItemType Directory (Join-Path $legacy 'node'), (Join-Path $legacy 'bin') | Out-Null
    $r = Invoke-Win @('check', '-Role', 'apply', '-RunnerDir', $ours, '-ToolsDir', $legacy)
    Check 'ps check: an earlier CCOF ToolsDir (node, bin only) is accepted' ($r.code -eq 0)
    $r = Invoke-Win @('check', '-Role', 'apply', '-RunnerDir', $ours, '-ToolsDir', $tools, '-Proxy', 'http://fakeuser:FAKEPASS123@proxy.example:8080')
    Check 'ps: a credential-bearing proxy is refused and not echoed' ($r.code -eq 2 -and $r.out -notmatch 'FAKEPASS123|fakeuser')
    $wreg = @('register', '-Role', 'apply', '-ClientId', '11111111-1111-4111-8111-111111111111', '-SubscriptionId', '22222222-2222-4222-8222-222222222222',
        '-TenantId', '33333333-3333-4333-8333-333333333333', '-Repository', 'octo/ccof-lab', '-AllowedWorkflows', '.github/workflows/deploy.yml', '-ToolsDir', $tools)
    $r = Invoke-Win ($wreg + @('-RunnerDir', $ours)) $svcs
    Check 'ps register: without -ReviewedMainEnforced it is refused before any service query or change' ($r.code -eq 2 -and $r.out -match 'needs -ReviewedMainEnforced' -and $r.out -match 'nobody bypass' -and $r.calls.Count -eq 0)
    $r = Invoke-Win ($wreg + @('-RunnerDir', 'C:\', '-ReviewedMainEnforced')) $svcs
    Check 'ps register: with -ReviewedMainEnforced it goes on to the next check (here: a refused RunnerDir)' ($r.code -eq 2 -and $r.out -notmatch 'ReviewedMainEnforced' -and $r.calls.Count -eq 0)
    $wtext = Get-Content -Raw $ps1
    foreach ($p in "'actions\.runner\.\*'", 'SetEnvironmentVariable', 'Import-Certificate', 'Cert:\\', 'git config --system', 'Select-Object -First 1') {
        Check "ps static: no $p" ($wtext -notmatch $p)
    }
    Check 'ps static: services are only addressed by the verified own name' (@([regex]::Matches($wtext, '(Stop|Restart|Start)-Service[^\n]*') | Where-Object { $_.Value -notmatch '-Name \$own' }).Count -eq 0)
    $wreg2 = [regex]::Match($wtext, "(?s)\n    'register' \{.*?\n    'remove'").Value
    Check 'ps static: config.cmd pins the service account to NETWORK SERVICE and disables self-update' ($wreg2 -match "config\.cmd [^\n]*--runasservice --windowslogonaccount 'NT AUTHORITY\\NETWORK SERVICE' --disableupdate")
    Check 'ps static: .env (with the hook) is written before config.cmd starts the service' ($wreg2 -match '(?s)Write-RunnerEnv[^\n]*\n.*config\.cmd')
    Check 'ps static: after config.cmd the account is verified, then Protect-RunnerDir, owner reset, then restart' ($wreg2 -match '(?s)config\.cmd.*S-1-5-20.*Protect-RunnerDir \$RunnerDir.*/setowner \*S-1-5-32-544.*Restart-Service')

    # Runner directory ACL on NTFS (real ACLs in the scratch directory; this process stands in for the service account).
    if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'SKIP NTFS runner ACL checks: elevated shell (the Administrators entry would grant every right)'
    } else {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        function New-Tree([string]$Name) {
            $d = Join-Path $wroot $Name
            foreach ($s in 'bin', '_work\r', '_diag') { New-Item -ItemType Directory -Force (Join-Path $d $s) | Out-Null }
            foreach ($f in 'bin\Runner.Listener.exe', '.env', '.runner', '.credentials', 'config.cmd', '_work\r\x', '_diag\l.log') { Set-Content (Join-Path $d $f) 'x' }
            $d
        }
        function Set-Protected([string]$Path, [object[]]$Rules) {
            $a = if (Test-Path -LiteralPath $Path -PathType Container) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
            $a.SetAccessRuleProtection($true, $false)
            foreach ($x in $Rules) { $a.AddAccessRule($x) }
            Set-Acl -LiteralPath $Path $a
        }
        function Invoke-Probe([scriptblock]$Do) { try { & $Do; $true } catch { $false } }
        function Undo-Tree([string]$Dir) { & icacls.exe $Dir /grant "${me}:(OI)(CI)F" /T /C /Q | Out-Null; & icacls.exe $Dir /reset /T /C /Q | Out-Null }
        # Negative control, the shape config.cmd leaves: the account's group has Full control of the root, .env is Read only.
        $neg = New-Tree 'acl-config'
        Set-Protected $neg @((New-Object Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Protected (Join-Path $neg '.env') @((New-Object Security.AccessControl.FileSystemAccessRule($me, 'Read', 'Allow')))
        Check 'NTFS negative control: a Read-only .env cannot be written by the account' (-not (Invoke-Probe { [IO.File]::WriteAllText((Join-Path $neg '.env'), 'ACTIONS_RUNNER_HOOK_JOB_STARTED=') }))
        Check 'NTFS negative control: but Full control of the runner root lets the account delete and replace it' (
            (Invoke-Probe { Remove-Item -LiteralPath (Join-Path $neg '.env') -ErrorAction Stop; [IO.File]::WriteAllText((Join-Path $neg '.env'), 'ACTIONS_RUNNER_HOOK_JOB_STARTED=') }) -and
            (Get-Content -Raw (Join-Path $neg '.env')) -eq 'ACTIONS_RUNNER_HOOK_JOB_STARTED=')
        Undo-Tree $neg

        $ast = [Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Protect-RunnerDir' }, $true)
        Check 'ps: Install-CcofRunner.ps1 defines Protect-RunnerDir' ($null -ne $fn)
        if ($fn) {
            function Fail([string]$m) { throw "Fail: $m" }
            . ([scriptblock]::Create($fn.Extent.Text))
            $setAcl = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-CcofAcl' }, $true)
            if ($setAcl) { . ([scriptblock]::Create($setAcl.Extent.Text)) }
            $pos = New-Tree 'acl-ccof'
            # config.cmd's group entry, then the CCOF ACL on top of it.
            Set-Protected $pos @((New-Object Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            Set-Protected (Join-Path $pos '.env') @((New-Object Security.AccessControl.FileSystemAccessRule($me, 'Read', 'Allow')))
            Protect-RunnerDir $pos $me
            Check 'ps lock: the account can still read .env, .runner and the runner binaries' (
                (Invoke-Probe { $null = [IO.File]::ReadAllText((Join-Path $pos '.env')); $null = [IO.File]::ReadAllText((Join-Path $pos '.runner')); $null = [IO.File]::ReadAllBytes((Join-Path $pos 'bin\Runner.Listener.exe')) }))
            Check 'ps lock: the account cannot delete, rename or overwrite .env' (
                -not (Invoke-Probe { Remove-Item -LiteralPath (Join-Path $pos '.env') -ErrorAction Stop }) -and -not (Invoke-Probe { Rename-Item -LiteralPath (Join-Path $pos '.env') '.env.x' -ErrorAction Stop }) -and
                -not (Invoke-Probe { [IO.File]::WriteAllText((Join-Path $pos '.env'), 'x') }) -and (Get-Content -Raw (Join-Path $pos '.env')).Trim() -eq 'x' -and (Test-Path (Join-Path $pos '.env')))
            Check 'ps lock: the account cannot create files in the runner root' (-not (Invoke-Probe { [IO.File]::WriteAllText((Join-Path $pos '.env2'), 'x') }) -and -not (Test-Path (Join-Path $pos '.env2')))
            Check 'ps lock: the account cannot change, delete or add runner binaries or registration files' (
                -not (Invoke-Probe { [IO.File]::WriteAllText((Join-Path $pos 'bin\Runner.Listener.exe'), 'x') }) -and -not (Invoke-Probe { Remove-Item -LiteralPath (Join-Path $pos 'bin\Runner.Listener.exe') -ErrorAction Stop }) -and
                -not (Invoke-Probe { [IO.File]::WriteAllText((Join-Path $pos 'bin\evil.dll'), 'x') }) -and -not (Invoke-Probe { [IO.File]::WriteAllText((Join-Path $pos '.runner'), 'x') }) -and
                -not (Invoke-Probe { Remove-Item -LiteralPath (Join-Path $pos '.credentials') -ErrorAction Stop }))
            Check 'ps lock: the account can still create, change and delete files in _work and _diag' (
                Invoke-Probe { foreach ($w in '_work', '_diag') { $f = Join-Path $pos "$w\new.txt"; [IO.File]::WriteAllText($f, 'x'); [IO.File]::AppendAllText($f, 'y'); Remove-Item -LiteralPath $f -ErrorAction Stop }; Remove-Item -LiteralPath (Join-Path $pos '_work\r') -Recurse -Force -ErrorAction Stop })
            $rootRules = @((Get-Acl -LiteralPath $pos).Access)
            Check 'ps lock: the root ACL is protected and the account has ReadAndExecute only' (
                (Get-Acl -LiteralPath $pos).AreAccessRulesProtected -and @($rootRules | Where-Object { $_.IdentityReference.Value -eq $me -and $_.FileSystemRights -ne 'ReadAndExecute, Synchronize' }).Count -eq 0)
            Undo-Tree $pos
            $jn = New-Tree 'acl-junction'; Remove-Item -Recurse -Force (Join-Path $jn '_diag'); New-Item -ItemType Junction -Path (Join-Path $jn '_diag') -Target $adj | Out-Null
            Check 'ps lock: a _work or _diag that is a link fails' (-not (Invoke-Probe { Protect-RunnerDir $jn $me }))
            Undo-Tree $jn
        }
    }
} else { Write-Host 'SKIP Windows bootstrap checks: not Windows' }

# ---- preflight: a credential-bearing proxy fails and its userinfo never reaches the output (fake values only)
$fakeProxy = 'http://fakeuser:FAKEPASS123@127.0.0.1:9'
$saved = @{ HTTPS_PROXY = $env:HTTPS_PROXY; NO_PROXY = $env:NO_PROXY }
try {
    $env:HTTPS_PROXY = $fakeProxy; $env:NO_PROXY = 'localhost,169.254.169.254'
    $pf = "$(& pwsh -NoProfile -File (Join-Path $repo 'scripts/cicd/Test-RunnerHost.ps1') -NoLogin -ImdsUri 'http://127.0.0.1:9/' -TimeoutSec 2 -MinDiskGb 0 2>&1)"
    Check 'ps preflight: a proxy with credentials fails the proxy check' ($pf -match 'FAIL proxy: HTTPS_PROXY contains credentials')
    Check 'ps preflight: proxy userinfo is never printed' ($pf -notmatch 'FAKEPASS123|fakeuser')
    if ($bash) {
        $pfs = "$(& $bash -c "HTTPS_PROXY='$fakeProxy' NO_PROXY='localhost,169.254.169.254' bash '$(& $toBash (Join-Path $repo 'scripts/cicd/Test-RunnerHost.sh'))' --no-login --min-disk-gb 0" 2>&1)"
        Check 'sh preflight: a proxy with credentials fails the proxy check' ($pfs -match 'FAIL proxy: HTTPS_PROXY contains credentials')
        Check 'sh preflight: proxy userinfo is never printed' ($pfs -notmatch 'FAKEPASS123|fakeuser')
    }
} finally { foreach ($k in $saved.Keys) { if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $saved[$k] } } }

Remove-Item -Recurse -Force $scratch
Write-Host "Test-RunnerHostSafety: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
