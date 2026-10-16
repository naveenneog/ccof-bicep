#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path $PSScriptRoot -Parent
$source = Get-Content (Join-Path $root 'docs/examples/az-gateway-token-auto-login.cmd') -Raw
$guide = Get-Content (Join-Path $root 'docs/runbooks/PUBLIC-ACCESS-WORKBOOK.md') -Raw
$normalized = $source.Replace("`r`n", "`n").Trim()
$printed = '```bat' + "`n$normalized`n" + '```'
if (-not $guide.Replace("`r`n", "`n").Contains($printed)) {
    throw 'The printed CMD helper must match the tested complete example.'
}
if (-not $IsWindows) {
    'Auto-login helper source matches workbook; native CMD scenarios require Windows (not run on this host).'
    exit 0
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ccof-auto-login-' + [guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH
New-Item -ItemType Directory -Path $scratch | Out-Null
$helper = Join-Path $scratch 'gateway-helper.cmd'
$log = Join-Path $scratch 'calls.log'
$session = Join-Path $scratch 'session'
$loginFail = Join-Path $scratch 'login-fail'
$tokenFail = Join-Path $scratch 'token-fail'
$stdout = Join-Path $scratch 'stdout.txt'
$stderr = Join-Path $scratch 'stderr.txt'
$mock = @'
@echo off
if "%1"=="login" goto login
if "%1"=="account" goto token
exit /b 99
:token
>>"%~dp0calls.log" echo token
if exist "%~dp0token-fail" (
  >&2 echo Final token failure.
  exit /b 9
)
if exist "%~dp0session" (
  echo eyJ.mock.token
  exit /b 0
)
>&2 echo Interaction required.
exit /b 1
:login
>>"%~dp0calls.log" echo login
echo LOGIN-OUTPUT-NOT-A-TOKEN
if exist "%~dp0login-fail" (
  >&2 echo Sign-in cancelled.
  exit /b 5
)
>"%~dp0session" echo signed-in
exit /b 0
'@

function Invoke-TestHelper {
    & $env:ComSpec /d /c "`"$helper`"" 1> $stdout 2> $stderr
    $exitCode = $LASTEXITCODE
    $outText = Get-Content $stdout -Raw
    $errorText = Get-Content $stderr -Raw
    @{
        exitCode = $exitCode
        stdout = if ($null -eq $outText) { '' } else { $outText.Trim() }
        stderr = if ($null -eq $errorText) { '' } else { $errorText.Trim() }
    }
}

try {
    $mock | Set-Content (Join-Path $scratch 'az.cmd') -Encoding ascii
    $env:PATH = "$scratch;$originalPath"
    $source | Set-Content $helper -Encoding ascii
    $result = Invoke-TestHelper
    if ($result.exitCode -eq 0 -or $result.stdout -or (Test-Path $log)) { throw 'Unconfigured helper must refuse before contacting az.' }

    $configured = $source.Replace('REPLACE-tenant-guid', '00000000-0000-4000-8000-000000000001').
        Replace('REPLACE-gateway-app-client-guid', '00000000-0000-4000-8000-000000000002')
    $configured | Set-Content $helper -Encoding ascii
    $result = Invoke-TestHelper
    if ($result.exitCode -ne 0 -or $result.stdout -cne 'eyJ.mock.token') { throw 'First-run sign-in did not return only a token.' }
    if ($result.stderr -notmatch 'LOGIN-OUTPUT-NOT-A-TOKEN') { throw 'Login stdout was not routed away from credential stdout.' }
    if ((Get-Content $log) -join ',' -cne 'token,login,token') { throw 'Expected a silent attempt, one login, then one retry.' }

    Remove-Item $log
    $result = Invoke-TestHelper
    if ($result.exitCode -ne 0 -or $result.stdout -cne 'eyJ.mock.token' -or (Get-Content $log) -join ',' -cne 'token') {
        throw 'Cached-token flow should not log in.'
    }

    Remove-Item $session, $log
    Set-Content $loginFail 'fail'
    $result = Invoke-TestHelper
    if ($result.exitCode -eq 0 -or $result.stdout -or (Get-Content $log) -join ',' -cne 'token,login') {
        throw 'Cancelled login must fail with no token and no additional token retry.'
    }

    Remove-Item $loginFail, $log
    Set-Content $tokenFail 'fail'
    $result = Invoke-TestHelper
    if ($result.exitCode -ne 9 -or $result.stdout -or (Get-Content $log) -join ',' -cne 'token,login,token') {
        throw 'A failed final token acquisition must propagate failure, not loop or return login output.'
    }
    'Auto-login CMD: placeholder refusal, first-run login, silent reuse, cancelled login, final failure and stdout isolation: PASS (mock az only).'
} finally {
    $env:PATH = $originalPath
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
