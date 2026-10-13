#Requires -Version 7.0
<#
.SYNOPSIS
    D2 code deployment and the pieces D2 composes (docs/DEPLOYMENT-STAGES.md): one TypeScript build;
    per app a package holding only the compiled files its entry point reaches, its host.json and
    extra files, production dependencies, a zip with "/" entry names, and OneDeploy through
    `az functionapp deployment source config-zip` (Flex Consumption deploys only this way, U-14).
    Default pieces call WP-GW's renderer and deploy script, WP-TEL's diagnostics Bicep, WP-RES's
    resolver authentication functions and WP-WB's deploy.ps1 and verify.ps1; tests replace them. az.cmd passes every argument through
    cmd.exe on Windows, so D2's own az calls run only after Assert-OnboardingAzArguments accepts their
    arguments, and Stage D2 checks those arguments before any Azure call.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.D2Steps.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Azure.psm1')

# Entry points and package files: WP-RES (dist/resolver only), WP-SYNC (infra/sync/host.json),
# WP-REC (infra/reconciler/host.json, rate card, contract schedule, ledger query).
$script:Packages = [ordered]@{
    resolver   = @{ main = 'dist/resolver/function-app.js'; hostJson = 'host.json'; files = @() }
    sync       = @{ main = 'dist/sync/function-app.js'; hostJson = 'infra/sync/host.json'; files = @() }
    reconciler = @{ main = 'dist/reconciler/function-app.js'; hostJson = 'infra/reconciler/host.json'; files = @(
            @{ answer = 'rateCard.path'; to = 'config/rate-card.json' }
            @{ answer = 'rateCard.contractSchedulePath'; to = 'config/contract-schedule.json' }
            @{ repo = 'analytics/ledger.kql'; to = 'analytics/ledger.kql' }) }
}

function Get-CorePackageDefinition { param([string]$App) $script:Packages[$App] }

function Get-CoreReachableFiles {
    <#
    .SYNOPSIS
        The compiled files an entry point reaches through relative imports and re-exports
        (static `from "./x.js"` and dynamic `import("./x.js")`), as paths relative to the repository.
    #>
    param([Parameter(Mandatory)] [string]$RepositoryRoot, [Parameter(Mandatory)] [string]$Entry)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue([System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Entry)))
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    while ($queue.Count) {
        $file = $queue.Dequeue()
        if (-not $seen.Add($file) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $text = Get-Content -LiteralPath $file -Raw
        foreach ($m in [regex]::Matches($text, '(?:from\s*|import\s*\(\s*)["''](\.{1,2}/[^"'']+)["'']')) {
            $target = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $file -Parent) $m.Groups[1].Value))
            if ($target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $queue.Enqueue($target) }
        }
    }
    return @($seen | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object { $_.Substring($root.Length + 1).Replace('\', '/') } | Sort-Object)
}

function Get-CoreDirectoryDigest {
    param([string]$Directory)
    $root = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    $lines = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' } | ForEach-Object {
        "$($_.FullName.Substring($root.Length + 1).Replace('\', '/'))=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    } | Sort-Object
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    return ([System.Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function New-CoreAppPackage {
    <#
    .SYNOPSIS
        Stages one app's package (without node_modules) and returns Directory, Digest and Missing
        (files the app needs that are not in this checkout: a package not merged yet).
    #>
    param([string]$RepositoryRoot, [string]$App, [System.Collections.IDictionary]$Answers, [string]$AnswersDirectory, [string]$StageRoot)
    $def = $script:Packages[$App]
    $dir = Join-Path $StageRoot $App
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $missing = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $def.main))) { $missing.Add($def.main) }
    $copies = @(Get-CoreReachableFiles -RepositoryRoot $RepositoryRoot -Entry $def.main | ForEach-Object { @{ from = (Join-Path $RepositoryRoot $_); to = $_ } })
    $copies += @{ from = (Join-Path $RepositoryRoot $def.hostJson); to = 'host.json' }
    $copies += @{ from = (Join-Path $RepositoryRoot 'package-lock.json'); to = 'package-lock.json' }
    foreach ($extra in $def.files) {
        $from = if ($extra.answer) { $value = $Answers; foreach ($part in $extra.answer.Split('.')) { $value = $value[$part] }; [System.IO.Path]::GetFullPath((Join-Path $AnswersDirectory $value)) } else { Join-Path $RepositoryRoot $extra.repo }
        $copies += @{ from = $from; to = $extra.to }
    }
    foreach ($c in $copies) {
        if (-not (Test-Path -LiteralPath $c.from -PathType Leaf)) { $missing.Add($c.to); continue }
        $target = Join-Path $dir $c.to
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $c.from -Destination $target -Force
    }
    $package = ConvertFrom-CoreJson (Get-Content -LiteralPath (Join-Path $RepositoryRoot 'package.json') -Raw)
    $package.main = $def.main
    $package | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $dir 'package.json') -Encoding utf8NoBOM
    [pscustomobject]@{ Directory = $dir; Digest = (Get-CoreDirectoryDigest $dir); Missing = $missing.ToArray() }
}

function New-CoreZip {
    param([string]$Directory, [string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
    $root = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, 'Create')
    try {
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
            $name = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $name)
        }
    }
    finally { $zip.Dispose() }
}

function Get-CoreD2ZipPath { param([string]$OutDir, [string]$App) Join-Path (Join-Path $OutDir 'packages') "$App.zip" }

function New-CoreD2ParametersPath { Join-Path ([System.IO.Path]::GetTempPath()) "ccof-d2-diagnostics-$([guid]::NewGuid()).json" }

function Get-CoreD2AzArguments {
    <#
    .SYNOPSIS
        The arguments of D2's own az calls: 'publish', OneDeploy of one app's zip (-App, -Path), and
        'diagnostics', WP-TEL's Bicep with its parameters file (-Path). The pieces run az with them.
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('publish', 'diagnostics')] [string]$Call,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Answers,
        [System.Collections.IDictionary]$D1, [string]$RepositoryRoot, [string]$App, [string]$Path
    )
    $target = @('--subscription', [string]$Answers.target.subscriptionId, '--resource-group', [string]$Answers.target.resourceGroup.name)
    if ($Call -eq 'publish') { return @('functionapp', 'deployment', 'source', 'config-zip') + $target + @('--name', ([string]$D1.apps[$App].functionAppId).Split('/')[-1], '--src', $Path) }
    return @('deployment', 'group', 'create') + $target + @('--name', "$($Answers.names.deploymentPrefix)-d2-diagnostics", '--template-file', (Join-Path $RepositoryRoot 'infra/poc/phase4-telemetry.bicep'), '--parameters', "@$Path")
}

function Get-CoreD2UnsafeAzArguments {
    <#
    .SYNOPSIS
        For a check before any Azure call: the arguments that Assert-OnboardingAzArguments refuses
        among those of the az calls the given steps make (code: each app's zip under -OutDir;
        diagnostics: the Bicep under -RepositoryRoot and a parameters file in the temporary
        directory). Empty when the guard accepts them all.
    #>
    param([System.Collections.IDictionary]$Answers, [System.Collections.IDictionary]$D1, [string]$RepositoryRoot, [string]$OutDir, [string[]]$Steps)
    $calls = [System.Collections.Generic.List[object]]::new()
    if ($Steps -ccontains 'code') { foreach ($app in $script:Packages.Keys) { $calls.Add((Get-CoreD2AzArguments -Call publish -Answers $Answers -D1 $D1 -App $app -Path (Get-CoreD2ZipPath $OutDir $app))) } }
    if ($Steps -ccontains 'diagnostics') { $calls.Add((Get-CoreD2AzArguments -Call diagnostics -Answers $Answers -RepositoryRoot $RepositoryRoot -Path (New-CoreD2ParametersPath))) }
    $sub = [string]$Answers.target.subscriptionId
    $unsafe = foreach ($arguments in $calls) { foreach ($argument in $arguments) { try { Assert-OnboardingAzArguments @('--subscription', $sub, $argument) } catch { $argument } } }
    return @($unsafe | Select-Object -Unique)
}

function Invoke-CoreAz {
    <#
    .SYNOPSIS
        Runs az only after Assert-OnboardingAzArguments accepts the arguments (it throws otherwise).
        Returns whether az exited 0.
    #>
    param([Parameter(Mandatory)] [string[]]$Arguments)
    Assert-OnboardingAzArguments $Arguments
    & az @Arguments --only-show-errors -o none | Out-Null
    return $LASTEXITCODE -eq 0
}

function Invoke-CoreD2Code {
    param($Ctx)
    $runtime = $Ctx.D3Runtime
    $waiting = @('resolver', 'sync', 'reconciler' | Where-Object { -not ($runtime -and $runtime[$_]) })
    if ($waiting.Count) { return New-CoreStepResult 'waiting' -ReasonCode 'runtime_grants_missing' -Lines @("Code waits for D3's runtime grants (Storage Blob Data Owner) of: $($waiting -join ', '). Run D3, then this stage again.") }
    # Build before the digest: a dist/ left by an earlier build must never stand for changed sources.
    if (-not (& $Ctx.Pieces.Build)) { return New-CoreStepResult 'failed' -ReasonCode 'build_failed' -Lines @('npx tsc -p tsconfig.json failed; run npm ci, fix the build, and run this stage again.') }
    $stageRoot = Join-Path $Ctx.OutDir 'packages'
    $packages = [ordered]@{}
    $missing = @()
    foreach ($app in $script:Packages.Keys) {
        $packages[$app] = New-CoreAppPackage -RepositoryRoot $Ctx.RepositoryRoot -App $app -Answers $Ctx.Answers -AnswersDirectory $Ctx.AnswersDirectory -StageRoot $stageRoot
        $missing += @($packages[$app].Missing | ForEach-Object { "${app}: $_" })
    }
    if ($missing.Count) { return New-CoreStepResult 'failed' -ReasonCode 'package_files_missing' -Lines (@('These package files are not in this checkout (a package that has not merged yet):') + @($missing | ForEach-Object { "  - $_" })) }
    $previous = $Ctx.Previous['code']
    $changed = @($packages.Keys | Where-Object { -not $previous -or $previous.digests[$_] -ne $packages[$_].Digest })
    if (-not $changed.Count) { return New-CoreStepResult 'unchanged' -Outputs $previous }
    $digests = [ordered]@{}
    foreach ($app in $packages.Keys) {
        $digests[$app] = $packages[$app].Digest
        if ($previous -and $previous.digests[$app] -eq $packages[$app].Digest) { continue }
        if (-not (& $Ctx.Pieces.InstallProduction $packages[$app].Directory)) { return New-CoreStepResult 'failed' -ReasonCode "npm_ci_failed_$app" }
        $zip = Get-CoreD2ZipPath $Ctx.OutDir $app
        New-CoreZip -Directory $packages[$app].Directory -ZipPath $zip
        try { $published = & $Ctx.Pieces.Publish $app $zip }
        catch { return New-CoreStepResult 'failed' -ReasonCode $(if ($_.Exception.Data['OnboardingRefusal']) { 'az_arguments_refused' } else { "publish_failed_$app" }) -Lines @("${app}: $($_.Exception.Message)") -Outputs @{ digests = $digests } }
        if (-not $published) { return New-CoreStepResult 'failed' -ReasonCode "publish_failed_$app" -Outputs @{ digests = $digests } }
    }
    New-CoreStepResult 'applied' -Outputs @{ digests = $digests } -Writes $changed.Count
}

function New-CoreDefaultPieces {
    <#
    .SYNOPSIS
        The real pieces: local commands and other packages' scripts, each with an explicit
        --subscription. Every one returns a value the step checks; none prints a secret. -Send is
        D2's ARM client (Invoke-CoreRest for the answers' subscription when it is not given).
    #>
    param([string]$RepositoryRoot, [System.Collections.IDictionary]$Answers, [System.Collections.IDictionary]$D1, [scriptblock]$Send)
    $sub = $Answers.target.subscriptionId
    if (-not $Send) { $Send = { param($Method, $Url, $Body) Invoke-CoreRest -SubscriptionId $sub -Method $Method -Url $Url -Body $Body }.GetNewClosure() }
    @{
        Build = { Push-Location $RepositoryRoot; try { npx tsc -p tsconfig.json | Out-Null; return $LASTEXITCODE -eq 0 } finally { Pop-Location } }.GetNewClosure()
        InstallProduction = { param($Dir) Push-Location $Dir; try { npm ci --omit=dev --no-audit --no-fund --quiet | Out-Null; return $LASTEXITCODE -eq 0 } finally { Pop-Location } }
        Publish = { param($App, $Zip) Invoke-CoreAz (Get-CoreD2AzArguments -Call publish -Answers $Answers -D1 $D1 -App $App -Path $Zip) }.GetNewClosure()
        Http = { param($Method, $Url) try { [int](Invoke-WebRequest -Uri $Url -Method $Method -Body '{}' -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 30).StatusCode } catch { 0 } }
        GatewayRender = { param($Config, $Out) $line = node (Join-Path $RepositoryRoot 'infra/gateway/render.ts') --config $Config --out $Out 2>$null | Select-Object -Last 1; if ($LASTEXITCODE -ne 0) { return $null }; ConvertFrom-CoreJson ([string]$line) }.GetNewClosure()
        GatewayDeploy = {
            param($Config, $AnswersFile, $Out, $MakeCurrent, $Revision)
            $script = Join-Path $RepositoryRoot 'infra/gateway/Deploy-GatewayRevision.ps1'
            $arguments = @('-NoProfile', '-File', $script, '-ConfigPath', $Config, '-AnswersPath', $AnswersFile, '-NonInteractive', '-OutDir', $Out)
            if ($MakeCurrent) { $arguments += @('-MakeCurrent', '-Revision', $Revision) }
            # Each action writes its own record: deployment.json for a new revision, make-current.json
            # for make-current (WP-SEC F-6). One left by an earlier run is removed first, so a run that
            # writes none is not taken as done.
            $record = Join-Path $Out $(if ($MakeCurrent) { 'make-current.json' } else { 'deployment.json' })
            Remove-Item -LiteralPath $record -Force -ErrorAction SilentlyContinue
            pwsh @arguments | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $record -PathType Leaf)) { return $null }
            ConvertFrom-CoreJson (Get-Content -LiteralPath $record -Raw)
        }.GetNewClosure()
        Diagnostics = {
            param($Parameters)
            $file = New-CoreD2ParametersPath
            try {
                @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $Parameters } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
                Invoke-CoreAz (Get-CoreD2AzArguments -Call diagnostics -Answers $Answers -RepositoryRoot $RepositoryRoot -Path $file)
            }
            finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        }.GetNewClosure()
        ResolverAuth = {
            # Not named like resolver-auth.ps1's parameters: dot-sourcing it sets those to empty here.
            param($Tenant, $ResolverApp, $ApimApp, $ApimPrincipal, $Site)
            . (Join-Path $RepositoryRoot 'infra/poc/resolver-auth.ps1') -DotSourceOnly
            $body = New-ResolverAuthSettingsBody -TenantId $Tenant -ResolverAppId $ResolverApp -AllowedCallerAppIds @($ApimApp) -AllowedCallerObjectIds @($ApimPrincipal)
            # Through D2's ARM client, not WP-RES's default az rest: that names no --subscription, and
            # az.cmd would pass its body file path (in the current directory) through cmd.exe. A nested
            # closure captures only this scope's variables, hence $arm.
            $arm = $Send
            $put = { param($Url, $Json) $w = & $arm 'PUT' $Url (ConvertFrom-CoreJson $Json); if ($w.Status -notin @(200, 201)) { throw "authsettingsV2 write answered HTTP $($w.Status)." } }.GetNewClosure()
            $get = { param($Url) $g = & $arm 'GET' $Url $null; if ($g.Status -ne 200) { throw "authsettingsV2 read-back answered HTTP $($g.Status)." }; $g.Content }.GetNewClosure()
            $r = Invoke-ResolverAuthApply -SiteResourceId $Site -Body $body -PutAuthSettings $put -GetAuthSettings $get
            return [bool]$r.Verified
        }.GetNewClosure()
        # WP-RES's comparison alone (GET only), for a resolver-auth step whose digest is unchanged (WP-SEC
        # C7): $true only when the live authsettingsV2 matches the body the apply piece would write.
        ResolverAuthVerify = {
            # Not named like resolver-auth.ps1's parameters, as in ResolverAuth.
            param($Tenant, $ResolverApp, $ApimApp, $ApimPrincipal, $Site)
            . (Join-Path $RepositoryRoot 'infra/poc/resolver-auth.ps1') -DotSourceOnly
            $body = New-ResolverAuthSettingsBody -TenantId $Tenant -ResolverAppId $ResolverApp -AllowedCallerAppIds @($ApimApp) -AllowedCallerObjectIds @($ApimPrincipal)
            $read = & $Send 'GET' "https://management.azure.com$Site/config/authsettingsV2?api-version=$script:AuthSettingsApiVersion" $null
            if ($read.Status -ne 200 -or $null -eq $read.Content) { return $false }
            return @(Compare-ResolverAuthSettings -Intended ($body | ConvertTo-Json -Depth 20 | ConvertFrom-Json) -Returned $read.Content).Count -eq 0
        }.GetNewClosure()
        Workbook = {
            param($Ctx)
            $deploy = Join-Path $RepositoryRoot 'infra/workbook/deploy.ps1'
            if (-not (Test-Path -LiteralPath $deploy)) { return $null }
            $file = New-CoreD2WorkbookAnswers $Ctx
            Push-Location $RepositoryRoot
            try {
                $out = @(pwsh -NoProfile -File $deploy -AnswersPath $file 2>$null)
                $deployed = $LASTEXITCODE -eq 0 -and @($out | Where-Object { $_ -match '"ccof\.workbook\.deploy\.v1"' -and $_ -match '"outcome"\s*:\s*"deployed"' }).Count -gt 0
                if (-not $deployed) { return $false }
                return Test-CoreD2WorkbookVerified -RepositoryRoot $RepositoryRoot -AnswersFile $file
            }
            finally { Pop-Location }
        }.GetNewClosure()
        # WP-WB's verify.ps1 alone (read-only), for a workbook step whose digest is unchanged.
        WorkbookVerify = {
            param($Ctx)
            if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot 'infra/workbook/verify.ps1'))) { return $null }
            $file = New-CoreD2WorkbookAnswers $Ctx
            Push-Location $RepositoryRoot
            try { return Test-CoreD2WorkbookVerified -RepositoryRoot $RepositoryRoot -AnswersFile $file }
            finally { Pop-Location }
        }.GetNewClosure()
    }
}

function New-CoreD2WorkbookAnswers {
    <#
    .SYNOPSIS
        Writes the answers file of WP-WB's deploy.ps1 and verify.ps1 under the D2 output directory and
        returns its path: WP-WB's keys, from the workbook answers, the D1 record and
        availability.telemetry.retentionDays.
    #>
    param([Parameter(Mandatory)] $Ctx)
    $a = $Ctx.Answers; $s = $a.workbook.settings
    $dir = Join-Path $Ctx.OutDir 'workbook'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir 'workbook.answers.json'
    [ordered]@{
        schemaVersion = 1; subscriptionId = $a.target.subscriptionId; tenantId = $a.target.tenantId; resourceGroupName = $a.target.resourceGroup.name; location = $a.target.location
        deploymentName = "$($a.names.deploymentPrefix)-d2-workbook"; workbookResourceName = $a.workbook.resourceName; workbookDisplayName = $a.workbook.displayName
        workspaceResourceId = $Ctx.D1.workspace.id; gatewayResourceId = $Ctx.D1.apim.id; reconcilerResourceId = $Ctx.D1.apps.reconciler.functionAppId
        rateCardPath = [System.IO.Path]::GetFullPath((Join-Path $Ctx.AnswersDirectory $a.rateCard.path)); ledgerPath = 'analytics/ledger.kql'
        outputDirectory = ".env.workbook-$($a.names.deploymentPrefix)"
        defaultProjectId = $s.defaultProjectId; maxRows = $s.maxRows; topUsers = $s.topUsers; maxQueryDays = $s.maxQueryDays; budgetLookbackDays = $s.budgetLookbackDays
        # Not a workbook setting: the workspace's retention. WP-WB checks it live (retention_mismatch), as D1 did.
        retentionDays = $a.availability.telemetry.retentionDays
    } | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding utf8NoBOM
    return $file
}

function Test-CoreD2WorkbookVerified {
    <#
    .SYNOPSIS
        Runs WP-WB's verify.ps1 (read-only) on the answers file; $true only when it exits 0 and reports
        verified.
    #>
    param([Parameter(Mandatory)] [string]$RepositoryRoot, [Parameter(Mandatory)] [string]$AnswersFile)
    # '*' stays a quoted literal: on Linux PowerShell expands a bare or splatted * for a native command.
    $out = @(pwsh -NoProfile -File (Join-Path $RepositoryRoot 'infra/workbook/verify.ps1') -AnswersPath $AnswersFile -Period month -Project '*' 2>$null)
    return $LASTEXITCODE -eq 0 -and @($out | Where-Object { $_ -match '"ccof\.workbook\.verify\.v1"' -and $_ -match '"outcome"\s*:\s*"verified"' }).Count -gt 0
}

Export-ModuleMember -Function Get-CorePackageDefinition, Get-CoreReachableFiles, New-CoreAppPackage, New-CoreZip, Invoke-CoreD2Code, New-CoreDefaultPieces, Get-CoreDirectoryDigest, Get-CoreD2ZipPath, New-CoreD2ParametersPath, Get-CoreD2AzArguments, Get-CoreD2UnsafeAzArguments, Invoke-CoreAz, New-CoreD2WorkbookAnswers, Test-CoreD2WorkbookVerified
