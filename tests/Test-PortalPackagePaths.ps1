#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/Core.D2Code.psm1') -Force -DisableNameChecking
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$scratch = Join-Path $root ".env.package-path-$([guid]::NewGuid().ToString('N'))"
$repo = Join-Path $scratch 'source with spaces'
$stage = Join-Path $scratch 'stage'
try {
    foreach ($folder in 'config','dist/reconciler','infra/reconciler','analytics') {
        New-Item -ItemType Directory -Path (Join-Path $repo $folder) -Force | Out-Null
    }
    foreach ($file in 'config/rate-card.json','config/contract-schedule.json','infra/reconciler/host.json','package-lock.json') {
        '{}' | Set-Content -LiteralPath (Join-Path $repo $file)
    }
    '{"name":"synthetic","version":"1.0.0","main":"dist/**/*.js"}' | Set-Content -LiteralPath (Join-Path $repo 'package.json')
    'export const fixture = true;' | Set-Content -LiteralPath (Join-Path $repo 'dist/reconciler/function-app.js')
    '// synthetic ledger' | Set-Content -LiteralPath (Join-Path $repo 'analytics/ledger.kql')
    foreach ($absolute in $false, $true) {
        $answers=@{rateCard=@{
            path=if($absolute){Join-Path $repo 'config/rate-card.json'}else{'config/rate-card.json'}
            contractSchedulePath=if($absolute){Join-Path $repo 'config/contract-schedule.json'}else{'config/contract-schedule.json'}
        }}
        Push-Location $scratch
        try { $package=New-CoreAppPackage -RepositoryRoot $repo -App reconciler -Answers $answers -AnswersDirectory $repo -StageRoot $stage }
        finally { Pop-Location }
        Assert ($package.Missing.Count -eq 0) "Reconciler source paths failed (absolute=$absolute): $($package.Missing -join ',')"
        foreach ($path in 'host.json','package.json','config/rate-card.json','config/contract-schedule.json','analytics/ledger.kql','dist/reconciler/function-app.js') {
            Assert (Test-Path -LiteralPath (Join-Path $package.Directory $path)) "Missing staged $path"
        }
        $dot=Join-Path $package.Directory 'node_modules/.package-lock.json'
        New-Item -ItemType Directory -Path (Split-Path $dot) -Force | Out-Null
        '{}' | Set-Content -LiteralPath $dot
        if ($IsWindows) { (Get-Item -LiteralPath $dot).Attributes += 'Hidden' }
        else {
            $hostJson=Join-Path $package.Directory 'host.json'
            & chmod 600 $hostJson
            Assert ($LASTEXITCODE -eq 0 -and [IO.File]::GetUnixFileMode($hostJson) -eq [IO.UnixFileMode]'UserRead,UserWrite') 'Fixture host.json is not 0600; the umask regression is not exercised.'
        }
        $zip=Join-Path $scratch 'reconciler.zip'
        New-CoreZip -Directory $package.Directory -ZipPath $zip
        $archive=[IO.Compression.ZipFile]::OpenRead($zip)
        try {
            Assert ($null -ne $archive.GetEntry('config/rate-card.json')) 'ZIP lost relative config path.'
            Assert ($null -ne $archive.GetEntry('node_modules/.package-lock.json')) 'ZIP skipped a hidden or dot file.'
            # The Flex host must read every file whatever the build machine's umask (SS-08).
            $modes=@($archive.Entries | ForEach-Object { '{0:x}' -f (($_.ExternalAttributes -shr 16) -band 0xFFFF) } | Sort-Object -Unique)
            Assert (($modes -join ',') -eq '81a4') "ZIP entry modes not all 0100644: $($modes -join ',')"
        }
        finally { $archive.Dispose() }
    }
    $bad=@{rateCard=@{path='';contractSchedulePath='config/contract-schedule.json'}}
    $message=$null
    try { New-CoreAppPackage -RepositoryRoot $repo -App reconciler -Answers $bad -AnswersDirectory $repo -StageRoot $stage | Out-Null }
    catch { $message=$_.Exception.Message }
    Assert ($message -like 'package_source_path_missing*') 'An empty source path did not fail explicitly.'
    'Reconciler packaging: relative/absolute paths, alternate working directory, spaces, ZIP roots and missing-path refusal: PASS'
} finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
