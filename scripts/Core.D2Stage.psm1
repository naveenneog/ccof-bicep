#Requires -Version 7.0
<#
.SYNOPSIS
    Stage D2 orchestration (docs/DEPLOYMENT-STAGES.md, D2 steps): runs the steps in their order, each
    only when the steps it needs succeeded in this run or, when they are not selected (-Steps), were
    recorded earlier; records stage-D2:<step> for each step that succeeds, and stage-D2 when all
    have. A step that waits (for D3's runtime grants or a piece another package has not delivered)
    or fails blocks only the steps that need it.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.D2Steps.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.D2Apim.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.D2Code.psm1')

# `reads`: the answers sections a step reads, so that a run of only that step (Stage-D2 -Steps) is not
# blocked by a decision still PENDING elsewhere. A step without `reads` is checked against every D2
# section.
$script:Steps = @(
    @{ id = 'schema'; needs = @(); reads = @('availability|availabilityFile', 'names') }
    @{ id = 'settings'; needs = @('schema') }
    @{ id = 'resolver-auth'; needs = @('settings') }
    @{ id = 'apim'; needs = @() }
    @{ id = 'diagnostics'; needs = @('apim') }
    @{ id = 'code'; needs = @('settings') }
    @{ id = 'policy'; needs = @('code', 'resolver-auth', 'apim') }
    @{ id = 'workbook'; needs = @('diagnostics') }
    @{ id = 'smoke'; needs = @('policy') }
)

function Get-CoreD2Steps { return $script:Steps }

function Get-CoreD2StepSections {
    <#
    .SYNOPSIS
        The answers sections the selected steps read, or $null when one of them reads every D2 section.
    #>
    param([Parameter(Mandatory)] [string[]]$Steps)
    $selected = @($script:Steps | Where-Object { $Steps -ccontains $_.id })
    if (-not $selected.Count -or @($selected | Where-Object { -not $_.reads }).Count) { return $null }
    return @($selected | ForEach-Object { $_.reads } | Select-Object -Unique)
}

function Get-CoreDigest { param($Value) ([System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-CoreCanonicalJson $Value))) | ForEach-Object { $_.ToString('x2') }) -join '' }

function Invoke-CoreD2ResolverAuth {
    param($Ctx)
    $d1 = $Ctx.D1
    if (-not $d1.apim.appId) { return New-CoreStepResult 'failed' -ReasonCode 'apim_app_id_missing' -Lines @("stage-D1 has no APIM identity application id; run Record-Prerequisites.ps1 -Action Record again.") }
    $inputs = [ordered]@{ tenant = $Ctx.Answers.target.tenantId; resolverAppId = $d1.registrations.resolverApi.appId; apimAppId = $d1.apim.appId; apimPrincipalId = $d1.apim.principalId; site = $d1.apps.resolver.functionAppId }
    $digest = Get-CoreDigest $inputs
    if ($Ctx.Previous['resolver-auth'] -and $Ctx.Previous['resolver-auth'].digest -eq $digest) { return New-CoreStepResult 'unchanged' -Outputs $Ctx.Previous['resolver-auth'] }
    try { $ok = & $Ctx.Pieces.ResolverAuth $inputs.tenant $inputs.resolverAppId $inputs.apimAppId $inputs.apimPrincipalId $inputs.site }
    catch { return New-CoreStepResult 'failed' -ReasonCode 'piece_failed:WP-RES' -Lines @('WP-RES infra/poc/resolver-auth.ps1 failed or is not in this checkout.') }
    if (-not $ok) { return New-CoreStepResult 'failed' -ReasonCode 'resolver_auth_not_verified' }
    New-CoreStepResult 'applied' -Outputs @{ digest = $digest; allowedCaller = $d1.apim.principalId } -Writes 1
}

function Invoke-CoreD2Diagnostics {
    param($Ctx)
    $d1 = $Ctx.D1
    $parameters = [ordered]@{
        workspaceResourceId = @{ value = $d1.workspace.id }; apimResourceId = @{ value = $d1.apim.id }; apiName = @{ value = $Ctx.Answers.apim.apiId }
        location = @{ value = $Ctx.Answers.target.location }
        functionAppResourceIds = @{ value = @('resolver', 'sync', 'reconciler' | ForEach-Object { $d1.apps[$_].functionAppId }) }
        enableAlerts = @{ value = $false }
    }
    $alerts = $Ctx.Answers.telemetry.alertConfigurationFile
    if ($null -ne $alerts) {
        $text = Get-Content -LiteralPath ([System.IO.Path]::GetFullPath((Join-Path $Ctx.AnswersDirectory $alerts))) -Raw
        $parameters.enableAlerts = @{ value = $true }
        $parameters.alertConfiguration = @{ value = (ConvertFrom-CoreJson $text) }
        $parameters.alertConfigurationDigest = @{ value = (([System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    }
    $digest = Get-CoreDigest $parameters
    if ($Ctx.Previous['diagnostics'] -and $Ctx.Previous['diagnostics'].digest -eq $digest) { return New-CoreStepResult 'unchanged' -Outputs $Ctx.Previous['diagnostics'] }
    try { $deployed = & $Ctx.Pieces.Diagnostics $parameters }
    catch { return New-CoreStepResult 'failed' -ReasonCode $(if ($_.Exception.Data['OnboardingRefusal']) { 'az_arguments_refused' } else { 'piece_failed:WP-TEL' }) -Lines @("diagnostics: $($_.Exception.Message)") }
    if (-not $deployed) { return New-CoreStepResult 'failed' -ReasonCode 'piece_failed:WP-TEL' -Lines @('WP-TEL infra/poc/phase4-telemetry.bicep failed or is not in this checkout.') }
    New-CoreStepResult 'applied' -Outputs @{ digest = $digest; alertsEnabled = [bool]$parameters.enableAlerts.value } -Writes 1
}

function Invoke-CoreD2Workbook {
    param($Ctx)
    $card = [System.IO.Path]::GetFullPath((Join-Path $Ctx.AnswersDirectory $Ctx.Answers.rateCard.path))
    $ledger = Join-Path $Ctx.RepositoryRoot 'analytics/ledger.kql'
    $inputs = [ordered]@{
        workbook = $Ctx.Answers.workbook; workspace = $Ctx.D1.workspace.id; gateway = $Ctx.D1.apim.id; reconciler = $Ctx.D1.apps.reconciler.functionAppId
        retentionDays = $Ctx.Answers.availability.telemetry.retentionDays
        rateCard = $(if (Test-Path -LiteralPath $card) { (Get-FileHash -LiteralPath $card -Algorithm SHA256).Hash } else { $null })
        ledger = $(if (Test-Path -LiteralPath $ledger) { (Get-FileHash -LiteralPath $ledger -Algorithm SHA256).Hash } else { $null })
    }
    $digest = Get-CoreDigest $inputs
    $redeploy = @()
    if ($Ctx.Previous['workbook'] -and $Ctx.Previous['workbook'].digest -eq $digest) {
        # Same inputs, but the live content can change after D2 (re-running D1 resets the shell), and
        # only WP-WB's verify.ps1 sees it: only a workbook it verifies is unchanged. Fail closed on any
        # other answer, a thrown or non-boolean one included.
        $verifyError = $null
        $verified = try { & $Ctx.Pieces.WorkbookVerify $Ctx } catch { $verifyError = $_.Exception.Message; $false }
        if ($null -eq $verified) { return New-CoreStepResult 'waiting' -ReasonCode 'piece_missing:WP-WB' -Lines @("WP-WB's infra/workbook/verify.ps1 is not in this checkout yet.") }
        if ($verified -is [bool] -and $verified) { return New-CoreStepResult 'unchanged' -Outputs $Ctx.Previous['workbook'] }
        $redeploy = @("The recorded workbook did not pass WP-WB's verify.ps1 (its content or tags differ, or it could not be checked), so D2 ran deploy.ps1 again.") +
            @($verifyError | Where-Object { $_ } | ForEach-Object { "The verify piece failed: $_" })
    }
    try { $r = & $Ctx.Pieces.Workbook $Ctx }
    catch { return New-CoreStepResult 'failed' -ReasonCode 'piece_failed:WP-WB' -Lines ($redeploy + @("The deploy piece failed: $($_.Exception.Message)")) }
    if ($null -eq $r) { return New-CoreStepResult 'waiting' -ReasonCode 'piece_missing:WP-WB' -Lines @("WP-WB's infra/workbook/deploy.ps1 is not in this checkout yet.") }
    if ($r -eq $false) { return New-CoreStepResult 'failed' -ReasonCode 'piece_failed:WP-WB' -Lines ($redeploy + @('WP-WB deploy.ps1 or verify.ps1 did not report deployed and verified; run them by hand for their message.')) }
    New-CoreStepResult 'applied' -ReasonCode $(if ($redeploy.Count) { 'workbook_not_verified_redeployed' }) -Lines $redeploy -Outputs @{ digest = $digest; workbookId = $Ctx.D1.workbook.id } -Writes 1
}

function Invoke-CoreD2Step {
    param([string]$Id, $Ctx)
    switch ($Id) {
        'schema' { Invoke-CoreD2Schema $Ctx }
        'settings' { Invoke-CoreD2Settings $Ctx }
        'resolver-auth' { Invoke-CoreD2ResolverAuth $Ctx }
        'apim' { Invoke-CoreD2Apim $Ctx }
        'diagnostics' { Invoke-CoreD2Diagnostics $Ctx }
        'code' { Invoke-CoreD2Code $Ctx }
        'policy' { Invoke-CoreD2Policy $Ctx }
        'workbook' { Invoke-CoreD2Workbook $Ctx }
        'smoke' { Invoke-CoreD2Smoke $Ctx }
    }
}

function Invoke-CoreD2Steps {
    <#
    .SYNOPSIS
        Runs every step whose needs succeeded in this run; returns one row per step: Id, State
        (applied, unchanged, waiting, failed, blocked, skipped), ReasonCode, Lines, Outputs. With -Only,
        the other steps are skipped (not run, not recorded); a need that is skipped counts as met only
        when an earlier run recorded it.
    #>
    param($Ctx, [scriptblock]$OnStep, [string[]]$Only)
    $states = @{}
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($step in $script:Steps) {
        if ($Only -and $Only -cnotcontains $step.id) {
            $states[$step.id] = if ($Ctx.Previous.Contains($step.id)) { 'unchanged' } else { 'skipped' }
            $rows.Add([pscustomobject]@{ Id = $step.id; State = 'skipped'; ReasonCode = 'not_selected'; Lines = @(); Outputs = $null })
            continue
        }
        $blockedBy = @($step.needs | Where-Object { $states[$_] -notin @('applied', 'unchanged') })
        if ($blockedBy.Count) {
            $states[$step.id] = 'blocked'
            $rows.Add([pscustomobject]@{ Id = $step.id; State = 'blocked'; ReasonCode = "waits_for:$($blockedBy -join ',')"; Lines = @(); Outputs = $null })
            continue
        }
        $result = Invoke-CoreD2Step -Id $step.id -Ctx $Ctx
        $states[$step.id] = $result.State
        if ($result.State -in @('applied', 'unchanged')) { $Ctx.Previous[$step.id] = $result.Outputs }
        $row = [pscustomobject]@{ Id = $step.id; State = $result.State; ReasonCode = $result.ReasonCode; Lines = @($result.Lines); Outputs = $result.Outputs }
        $rows.Add($row)
        if ($OnStep) { & $OnStep $row }
    }
    return $rows.ToArray()
}

Export-ModuleMember -Function Get-CoreD2Steps, Get-CoreD2StepSections, Invoke-CoreD2Steps, Invoke-CoreD2Step, Get-CoreDigest
