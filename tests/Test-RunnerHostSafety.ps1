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
    $wtext = Get-Content -Raw $ps1
    foreach ($p in "'actions\.runner\.\*'", 'SetEnvironmentVariable', 'Import-Certificate', 'Cert:\\', 'git config --system', 'Select-Object -First 1') {
        Check "ps static: no $p" ($wtext -notmatch $p)
    }
    Check 'ps static: services are only addressed by the verified own name' (@([regex]::Matches($wtext, '(Stop|Restart|Start)-Service[^\n]*') | Where-Object { $_.Value -notmatch '-Name \$own' }).Count -eq 0)
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
