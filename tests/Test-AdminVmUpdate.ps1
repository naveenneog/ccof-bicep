# Offline tests for the VM-based admin update (ADR 0037, docs/runbooks/ADMIN-UPDATE-FROM-VM.md):
# infra/admin/AdminVmUpdate.psm1, infra/admin/vm/admin-update.sh run under bash with stub commands, and
# infra/admin/Update-AdminFromVm.ps1 with a stub `az` and `git` in a child pwsh. No Azure call is made.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'infra/admin/AdminVmUpdate.psm1') -Force
$sub = '00000000-0000-4000-8000-000000000002'
$commit = 'a' * 40
$values = [ordered]@{ Subscription = $sub; ResourceGroup = 'rg-lab'; VmName = 'vm-admin'; App = 'lab-admin'; Commit = $commit; RepoUrl = 'https://github.com/example/ccof-bicep' }

# ---- inputs and the generated script
Check 'valid values have no problem' (@(Get-AdminVmInputProblems $values -RequireCommit).Count -eq 0)
$bad = [ordered]@{} + $values; $bad.Commit = 'abc'
Check 'a short commit is refused' ((@(Get-AdminVmInputProblems $bad -RequireCommit) -match '^Commit').Count -eq 1)
$bad = [ordered]@{} + $values; $bad.ResourceGroup = "rg'; rm -rf /; '"
Check 'a quote or shell syntax in a value is refused' ((@(Get-AdminVmInputProblems $bad) -match '^ResourceGroup').Count -eq 1)
$bad = [ordered]@{} + $values; $bad.RepoUrl = 'http://github.com/example/ccof-bicep'
Check 'a non-HTTPS repository URL is refused' ((@(Get-AdminVmInputProblems $bad) -match '^RepoUrl').Count -eq 1)
$bad = [ordered]@{} + $values; $bad.Commit = ''
Check 'Update needs a commit; Check does not' ((@(Get-AdminVmInputProblems $bad -RequireCommit) -match '^Commit').Count -eq 1 -and @(Get-AdminVmInputProblems $bad).Count -eq 0)
$text = New-AdminVmScript -Phase update -Values $values
Check 'script: values line written once, marker gone, LF only' ($text.Contains("PHASE='update'; SUB='$sub'; RG='rg-lab'; APP='lab-admin'; COMMIT='$commit'; REPO_URL='https://github.com/example/ccof-bicep'") -and -not $text.Contains('# @@VALUES@@') -and -not $text.Contains("`r"))
Check 'template is checked out with LF line endings (.gitattributes *.sh eol=lf)' (-not [IO.File]::ReadAllText((Join-Path $repo 'infra/admin/vm/admin-update.sh')).Contains("`r"))
Check 'script: well under the Run Command script size limit (256 KiB)' ([Text.Encoding]::UTF8.GetByteCount($text) -lt 32768)
$threw = $false; try { $null = New-AdminVmScript -Phase update -Values $bad } catch { $threw = "$_" -match 'input_refused' }
Check 'script: not built from refused values' $threw
$msg = "[stdout]`nnoise`n{`"schema`":`"ccof.admin.vmupdate.v1`",`"phase`":`"check`",`"outcome`":`"succeeded`",`"step`":`"check`",`"detail`":`"ok`"}`n[stderr]`n"
Check 'run line parsed from a Run Command message' ((Read-AdminVmRunLine $msg).outcome -ceq 'succeeded' -and $null -eq (Read-AdminVmRunLine "[stdout]`nnothing"))

# ---- the bash script under stub commands. CI runs Git Bash; a Windows workstation may run WSL bash.
$scratch = Join-Path $repo '.env.public-test-scratch/admin-vm'
Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$kind = try { "$(& bash -c 'uname -s' 2>$null | Select-Object -First 1)" } catch { '' }
Check "bash is available to run the VM script (uname: '$kind')" ([bool]$kind)
function ConvertTo-BashPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $IsWindows) { return $full }
    if ($kind -match '^Linux') { return "/mnt/$($full.Substring(0, 1).ToLowerInvariant())$($full.Substring(2).Replace('\', '/'))" }
    return $full.Replace('\', '/')
}
$stubs = @'
rec() { echo "$*" >> "$CALLS"; }
az() { rec "az $*"
  case "$*" in
    "login --identity"*) return 0 ;;
    "account set"*) return 0 ;;
    "functionapp show"*) echo Disabled ;;
    "functionapp deployment source config-zip"*) [ -z "${STUB_DEPLOY_FAIL:-}" ] || { echo "deploy error" >&2; return 1; } ;;
    "functionapp function list"*) printf '%s\n' ${STUB_FUNCS-lab-admin/projects lab-admin/adminUi lab-admin/adminHealth} ;;
    *) return 0 ;;
  esac; }
git() { rec "git $*"
  case "$1" in
    clone) mkdir -p "${@: -1}" ;;
    -C) [ "$3" = rev-parse ] && echo "${STUB_HEAD:-$COMMIT}"; [ "$3" = checkout ] && [ -n "${STUB_CHECKOUT_FAIL:-}" ] && return 1; return 0 ;;
  esac; }
pwsh() { rec "pwsh $*"
  if [ "$2" = -Command ]; then echo 7.5.0; return 0; fi
  local out=''; while [ $# -gt 0 ]; do [ "$1" = -OutFile ] && out="$2"; shift; done; echo package > "$out"
  [ -z "${STUB_BUILD_FAIL:-}" ] || { echo "npm ERR build"; return 1; }; }
node() { echo "${STUB_NODE:-v22.11.0}"; }
curl() { rec "curl $*"; case "$*" in *http_code*) echo "${STUB_HTTP:-200}" ;; *) echo 'echo installed' ;; esac; }
getent() { echo "${STUB_IP:-10.1.2.3} $2"; }
apt-get() { rec "apt-get $*"; }
npm() { rec "npm $* (in $(basename "$PWD"))"; [ -z "${STUB_NPM_FAIL:-}" ] || return 1; }
dpkg() { rec "dpkg $*"; }
wget() { rec "wget $*"; }
'@
[IO.File]::WriteAllText((Join-Path $scratch 'stubs.sh'), $stubs.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $scratch 'os-release'), "VERSION_ID=`"24.04`"`n", [Text.UTF8Encoding]::new($false))
$script:runId = 0
function Invoke-VmScript([string]$Phase, [hashtable]$Env = @{}, [string[]]$Without = @()) {
    $script:runId++
    $d = Join-Path $scratch "run$script:runId"; New-Item -ItemType Directory -Force -Path (Join-Path $d 'work') | Out-Null
    [IO.File]::WriteAllText((Join-Path $d 'script.sh'), (New-AdminVmScript -Phase $Phase -Values $values), [Text.UTF8Encoding]::new($false))
    $fns = @('az', 'git', 'pwsh', 'node', 'curl', 'getent', 'apt-get', 'dpkg', 'wget', 'npm', 'rec') | Where-Object { $Without -notcontains $_ }
    $exports = ($Env.GetEnumerator() | ForEach-Object { "export $($_.Key)='$($_.Value)'" }) -join "`n"
    $runner = @"
if [ "`$(uname -s)" = Linux ]; then
  BIN=`$(mktemp -d)
  for t in mkdir date tr cut tail sed awk grep sha256sum seq sleep rm cat head bash basename; do ln -s "`$(command -v `$t)" "`$BIN/`$t"; done
  export PATH="`$BIN"
else
  export PATH=/usr/bin:/bin
fi
. '$(ConvertTo-BashPath (Join-Path $scratch 'stubs.sh'))'
$(($Without | ForEach-Object { "unset -f $_" }) -join "`n")
export -f $($fns -join ' ')
export CALLS='$(ConvertTo-BashPath (Join-Path $d 'calls.txt'))' CCOF_ADMIN_WORK='$(ConvertTo-BashPath (Join-Path $d 'work'))' CCOF_POLL_SECONDS=0 CCOF_OS_RELEASE='$(ConvertTo-BashPath (Join-Path $scratch 'os-release'))'
$exports
: > "`$CALLS"
bash '$(ConvertTo-BashPath (Join-Path $d 'script.sh'))' > '$(ConvertTo-BashPath (Join-Path $d 'out.txt'))' 2> '$(ConvertTo-BashPath (Join-Path $d 'err.txt'))'
echo `$? > '$(ConvertTo-BashPath (Join-Path $d 'code.txt'))'
"@
    [IO.File]::WriteAllText((Join-Path $d 'runner.sh'), $runner.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    & bash (ConvertTo-BashPath (Join-Path $d 'runner.sh')) | Out-Null
    $read = { param($f) $p = Join-Path $d $f; if (Test-Path $p) { [IO.File]::ReadAllText($p) } else { '' } }
    $out = & $read 'out.txt'
    @{ code = "$(& $read 'code.txt')".Trim(); out = $out; err = (& $read 'err.txt'); calls = @((& $read 'calls.txt') -split "`n" | Where-Object { $_ }); run = (Read-AdminVmRunLine $out); work = (Join-Path $d 'work') }
}
function Has($r, [string]$Pattern) { @($r.calls | Where-Object { $_ -match $Pattern }).Count -gt 0 }

$r = Invoke-VmScript 'check'
Check 'check: private DNS, identity and outbound HTTPS -> succeeded' ($r.run -and $r.run.outcome -ceq 'succeeded' -and $r.code -eq '0' -and "$($r.run.notes)" -match 'lab-admin\.scm\.azurewebsites\.net -> 10\.1\.2\.3' -and (Has $r '^az login --identity'))
Check 'check: changes nothing (no build, no deploy, no install)' (-not (Has $r 'config-zip|^pwsh -NoProfile -File|^apt-get|^git clone'))
$r = Invoke-VmScript 'check' @{ STUB_IP = '20.50.1.2' }
Check 'check: scm name resolving to a public address fails with the DNS reason' ($r.run -and $r.run.outcome -ceq 'failed' -and $r.run.step -ceq 'check' -and $r.run.detail -match 'not a private address' -and $r.code -eq '1')
$r = Invoke-VmScript 'check' @{ STUB_HTTP = '000' }
Check 'check: no outbound HTTPS fails naming the URL' ($r.run -and $r.run.outcome -ceq 'failed' -and $r.run.detail -match 'outbound HTTPS to https://github.com/example/ccof-bicep')
$r = Invoke-VmScript 'check' @{ STUB_NODE = 'v20.11.0' }
Check 'check: Node.js older than 22 fails' ($r.run -and $r.run.outcome -ceq 'failed' -and $r.run.detail -match 'older than 22')

$r = Invoke-VmScript 'update'
$order = @('^az login --identity', '^git clone --quiet --no-checkout https://github.com/example/ccof-bicep ', "^git -C \S+ checkout --quiet $commit", "^npm ci --ignore-scripts --no-audit --no-fund \(in src-$commit\)", '^pwsh -NoProfile -File \S+/admin/Build-AdminPackage\.ps1 -OutFile ', "^az functionapp deployment source config-zip --subscription $sub --resource-group rg-lab --name lab-admin --src \S+admin-$commit\.zip", '^az functionapp function list ') |
    ForEach-Object { $p = $_; [array]::FindIndex([string[]]$r.calls, [Predicate[string]] { param($c) $c -match $p }) }
Check 'update: sign-in, clone, checkout, build, publish, verify in that order' ($r.run -and $r.run.outcome -ceq 'succeeded' -and -not ($order -contains -1) -and (($order | Sort-Object) -join ',') -ceq ($order -join ','))
Check 'update: run line carries the commit and the package sha256' ($r.run -and $r.run.commit -ceq $commit -and $r.run.sha256 -match '^[0-9a-f]{64}$')
Check 'update: history line written on the VM' ((Test-Path (Join-Path $r.work 'history.log')) -and (Get-Content (Join-Path $r.work 'history.log') -Raw) -match "lab-admin $commit [0-9a-f]{64}")
$r = Invoke-VmScript 'update' @{ STUB_IP = '20.50.1.2' }
Check 'update: public DNS stops before clone, build or publish' ($r.run.step -ceq 'check' -and -not (Has $r '^git clone|^pwsh -NoProfile -File|config-zip'))
$r = Invoke-VmScript 'update' @{ STUB_CHECKOUT_FAIL = '1' }
Check 'update: a commit not on the remote stops before build' ($r.run.step -ceq 'clone' -and $r.run.detail -match 'push it first' -and -not (Has $r '^pwsh -NoProfile -File|config-zip'))
$r = Invoke-VmScript 'update' @{ STUB_HEAD = ('b' * 40) }
Check 'update: a different checked-out commit stops before build' ($r.run.step -ceq 'clone' -and -not (Has $r '^pwsh -NoProfile -File|config-zip'))
$r = Invoke-VmScript 'update' @{ STUB_NPM_FAIL = '1' }
Check 'update: a failed npm ci at the repository root stops before the admin build' ($r.run.step -ceq 'build' -and $r.run.detail -match 'npm ci' -and -not (Has $r '^pwsh -NoProfile -File|config-zip'))
$r = Invoke-VmScript 'update' @{ STUB_BUILD_FAIL = '1' }
Check 'update: a failed build or unit test is not published' ($r.run.step -ceq 'build' -and -not (Has $r 'config-zip') -and $r.err -match 'npm ERR build')
$r = Invoke-VmScript 'update' @{ STUB_DEPLOY_FAIL = '1' }
Check 'update: a failed OneDeploy is reported at deploy, no history line' ($r.run.step -ceq 'deploy' -and $r.run.outcome -ceq 'failed' -and -not (Test-Path (Join-Path $r.work 'history.log')))
$r = Invoke-VmScript 'update' @{ STUB_FUNCS = 'lab-admin/projects' }
Check 'update: functions missing after publish fail at verify' ($r.run.step -ceq 'verify' -and $r.run.detail -match 'adminUi' -and $r.run.detail -match 'adminHealth')

$r = Invoke-VmScript 'setup'
Check 'setup: all tools present -> nothing installed, then check passes' ($r.run.outcome -ceq 'succeeded' -and "$($r.run.notes)" -match 'tools present' -and -not (Has $r '^apt-get'))
$r = Invoke-VmScript 'setup' @{} @('pwsh')
Check 'setup: missing PowerShell -> Microsoft package repository for the Ubuntu version, then apt install' ((Has $r '^wget -q https://packages\.microsoft\.com/config/ubuntu/24\.04/packages-microsoft-prod\.deb') -and (Has $r '^apt-get install -y powershell') -and -not (Has $r 'InstallAzureCLIDeb'))

# ---- the driver with stub az and git
$drv = Join-Path $scratch 'driver'; New-Item -ItemType Directory -Force -Path $drv | Out-Null
$stubPs = @'
function global:az {
    $l = $args -join ' '; Add-Content -LiteralPath $env:FAKE_AZ_LOG -Value $l; $global:LASTEXITCODE = 0
    if ($l -match '^vm get-instance-view') { return "{`"instanceView`":{`"statuses`":[{`"code`":`"ProvisioningState/succeeded`"},{`"code`":`"PowerState/$env:FAKE_POWER`"}]}}" }
    if ($l -match '^vm run-command invoke .*--scripts @(\S+)') { Copy-Item -LiteralPath $Matches[1] -Destination (Join-Path $env:FAKE_DIR 'sent.sh') -Force
        return (@{ value = @(@{ code = 'ProvisioningState/succeeded'; message = "Enable succeeded: `n[stdout]`nnote`n$env:FAKE_RUNLINE`n[stderr]`n" }) } | ConvertTo-Json -Depth 5) }
    $global:LASTEXITCODE = 1; Write-Error "stub: unexpected $l"
}
function global:git { $l = $args -join ' '; $global:LASTEXITCODE = 0
    if ($l -match 'remote get-url origin') { return 'https://github.com/example/ccof-bicep.git' }
    if ($l -match 'rev-parse HEAD') { return ('c' * 40) }
    if ($l -match 'branch -r --contains') { if ($env:FAKE_PUSHED) { return '  origin/main' } else { return } }
}
'@
$runDrv = { param([string[]]$DriverArgs, [hashtable]$Env)
    $env:FAKE_AZ_LOG = Join-Path $drv 'az.log'; Set-Content $env:FAKE_AZ_LOG ''; $env:FAKE_DIR = $drv; Remove-Item (Join-Path $drv 'sent.sh') -ErrorAction SilentlyContinue
    $env:FAKE_POWER = 'running'; $env:FAKE_PUSHED = '1'; $env:FAKE_RUNLINE = '{"schema":"ccof.admin.vmupdate.v1","phase":"update","outcome":"succeeded","step":"update","detail":"ok","sha256":"' + ('d' * 64) + '","notes":"published; ","log":"/x"}'
    foreach ($k in $Env.Keys) { Set-Item "env:$k" $Env[$k] }
    $cmd = "$stubPs; `$env:AZURE_CONFIG_DIR = '$drv'; & '$(Join-Path $repo 'infra/admin/Update-AdminFromVm.ps1')' $($DriverArgs -join ' ') -Subscription $sub -VmResourceGroup rg-lab -VmName vm-admin -AdminApp lab-admin -EvidenceDirectory '$drv'; exit `$LASTEXITCODE"
    $out = pwsh -NoProfile -Command $cmd 2>&1 | Out-String
    @{ code = $LASTEXITCODE; out = $out; log = @(Get-Content $env:FAKE_AZ_LOG | Where-Object { $_ }); sent = $(if (Test-Path (Join-Path $drv 'sent.sh')) { [IO.File]::ReadAllText((Join-Path $drv 'sent.sh')) } else { '' }) } }
$d = & $runDrv @('-Phase', 'Update') @{}
Check 'driver Update without -Apply: no Run Command, exit 0' ($d.code -eq 0 -and $d.out -match 'preview:' -and @($d.log | Where-Object { $_ -match 'run-command' }).Count -eq 0)
$d = & $runDrv @('-Phase', 'Update', '-Apply') @{}
Check 'driver Update -Apply: sends the update script for HEAD and the origin URL, exit 0' ($d.code -eq 0 -and $d.sent -match "PHASE='update'" -and $d.sent -match "COMMIT='$('c' * 40)'" -and $d.sent -match "REPO_URL='https://github.com/example/ccof-bicep'" -and $d.out -match "package sha256 $('d' * 64)")
$ev = @(Get-ChildItem $drv -Filter 'admin-update-*.json')
Check 'driver writes evidence with the run line' ($ev.Count -ge 1 -and ((Get-Content $ev[-1].FullName -Raw | ConvertFrom-Json).run.outcome -ceq 'succeeded'))
$d = & $runDrv @('-Phase', 'Update', '-Apply') @{ FAKE_PUSHED = '' }
Check 'driver: an unpushed commit stops before any az call (exit 2)' ($d.code -eq 2 -and $d.out -match 'commit_not_pushed' -and $d.log.Count -eq 0)
$d = & $runDrv @('-Phase', 'Check') @{ FAKE_POWER = 'deallocated' }
Check 'driver: a stopped VM stops before Run Command and prints az vm start (exit 2)' ($d.code -eq 2 -and $d.out -match 'az vm start' -and @($d.log | Where-Object { $_ -match 'run-command' }).Count -eq 0)
$d = & $runDrv @('-Phase', 'Check') @{ FAKE_RUNLINE = '{"schema":"ccof.admin.vmupdate.v1","phase":"check","outcome":"failed","step":"check","detail":"resolves to 20.1.1.1, not a private address","notes":"","log":"/x"}' }
Check 'driver: a failed VM step exits 1 with step and detail' ($d.code -eq 1 -and $d.out -match 'failed at check: resolves to 20\.1\.1\.1')
$d = & $runDrv @('-Phase', 'Check') @{ FAKE_RUNLINE = 'no json here' }
Check 'driver: no run line exits 3' ($d.code -eq 3 -and $d.out -match 'no_run_line')
$d = & $runDrv @('-Phase', 'Update', '-Apply', '-Commit', 'HEAD') @{}
Check 'driver: a commit that is not a 40-character SHA is refused (exit 2)' ($d.code -eq 2 -and $d.out -match 'input_refused' -and $d.log.Count -eq 0)

Write-Host "Test-AdminVmUpdate: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 36) { exit 1 }
