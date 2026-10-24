#Requires -Version 7.0
<#
.SYNOPSIS
    Loads and checks the one-time core installer's answers file (docs/PILOT.md C-9) before any Azure
    call: JSON Schema (config/core.answers.schema.json), the Stage 0 availability export (WP-HADEC),
    cross-field rules the other packages enforce at run time, and the local files the answers name.

.DESCRIPTION
    Every problem is returned together, so an administrator sees every missing decision at once.
    Problems carry paths and reason codes, never answer values.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')
Import-Module (Join-Path $PSScriptRoot 'Core.Auth.psm1')

function New-CoreRuleProblem {
    param([string]$Path, [string]$Code, [string]$Detail)
    [pscustomobject]@{ path = $Path; code = $Code; detail = $Detail }
}

function Get-CoreScheduleMinutes {
    param([string]$Schedule)
    if ($Schedule -match '^0 \*/([0-9]+) \* \* \* \*$') { return [int]$Matches[1] }
    return $null
}

function Test-CoreAnswerRules {
    <#
    .SYNOPSIS
        Cross-field rules that JSON Schema cannot express. Each one mirrors a rule another package
        enforces at run time, so the installer refuses before a write instead of after it. A rule
        runs only when the sections it reads are present and none of them is in -SkipSections (a
        section that still holds a PENDING decision).
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Answers, [string[]]$SkipSections = @())
    $p = [System.Collections.Generic.List[object]]::new()
    function Test-Ready([string[]]$Sections) { -not @($Sections | Where-Object { $SkipSections -contains $_ }).Count }
    $location = [string]$Answers.target.location
    if ($Answers.identity -is [System.Collections.IDictionary] -and (Test-Ready 'identity')) {
        foreach ($problem in @(Test-CoreAuthSeparation -Registrations $Answers.identity)) { $p.Add($problem) }
    }
    $availability = $Answers.availability
    if ($availability -is [System.Collections.IDictionary] -and (Test-Ready 'availability', 'target')) {
        if (-not [string]::Equals([string]$availability.region.primary, $location, 'Ordinal')) {
            $p.Add((New-CoreRuleProblem 'availability.region.primary' 'region_mismatch' 'must equal target.location'))
        }
        if (-not [string]::Equals([string]@($availability.registry.regions)[0], $location, 'Ordinal')) {
            $p.Add((New-CoreRuleProblem 'availability.registry.regions[0]' 'region_mismatch' 'the first registry region must equal target.location'))
        }
        # WP-RES src/resolver/config.ts: grace_exceeds_hard_limit.
        if ([long]$availability.budgetState.graceSeconds -gt [long]$availability.budgetState.hardLimitSeconds) {
            $p.Add((New-CoreRuleProblem 'availability.budgetState.graceSeconds' 'grace_exceeds_hard_limit' 'must not exceed hardLimitSeconds'))
        }
        # WP-GW gateway-config: refreshBackoffSeconds <= lastKnownGoodGraceSeconds when that is above 0.
        $cache = $availability.entitlementCache
        if ([long]$cache.lastKnownGoodGraceSeconds -gt 0 -and [long]$cache.refreshBackoffSeconds -gt [long]$cache.lastKnownGoodGraceSeconds) {
            $p.Add((New-CoreRuleProblem 'availability.entitlementCache.refreshBackoffSeconds' 'backoff_exceeds_grace' 'must not exceed lastKnownGoodGraceSeconds'))
        }
    }
    if ($Answers.Contains('backends') -and (Test-Ready 'backends', 'onboarding')) {
        $backendIds = @($Answers.backends | ForEach-Object { [string]$_.id })
        if (@($backendIds | Select-Object -Unique).Count -ne $backendIds.Count) {
            $p.Add((New-CoreRuleProblem 'backends' 'duplicate_backend_id' 'each backend id must be unique'))
        }
        $i = 0
        foreach ($project in @($Answers.onboarding.projects | Where-Object { $_ })) {
            if ($backendIds -cnotcontains [string]$project.backendId) {
                $p.Add((New-CoreRuleProblem "onboarding.projects[$i].backendId" 'unknown_backend' 'must name a backend in backends'))
            }
            $i++
        }
    }
    # WP-REC contract: validUntil must outlive one interval plus the ledger timeout; lease >= 2 x timeout.
    $rec = $Answers.reconciler
    if ($rec -is [System.Collections.IDictionary] -and (Test-Ready 'reconciler')) {
        $minutes = Get-CoreScheduleMinutes ([string]$rec.schedule)
        if ($null -ne $minutes -and [long]$rec.validitySeconds -le ($minutes * 60 + [long]$rec.ledgerTimeoutSeconds)) {
            $p.Add((New-CoreRuleProblem 'reconciler.validitySeconds' 'validity_too_short' 'must exceed the schedule interval plus ledgerTimeoutSeconds'))
        }
        if ($null -ne $minutes -and $null -ne $rec.pacingWindowMinutes -and [long]$rec.pacingWindowMinutes -lt $minutes) {
            $p.Add((New-CoreRuleProblem 'reconciler.pacingWindowMinutes' 'pacing_window_too_short' 'must be at least the schedule interval'))
        }
        if ([long]$rec.leaseSeconds -lt 2 * [long]$rec.ledgerTimeoutSeconds) {
            $p.Add((New-CoreRuleProblem 'reconciler.leaseSeconds' 'lease_too_short' 'must be at least twice ledgerTimeoutSeconds'))
        }
    }
    # WP-CLIENT client/src/config.mjs rules.
    $client = $Answers.client
    if ($client -is [System.Collections.IDictionary] -and (Test-Ready 'client')) {
        foreach ($alias in @('default', 'opus', 'sonnet', 'haiku')) {
            if (@($client.models.available) -cnotcontains [string]$client.models[$alias]) {
                $p.Add((New-CoreRuleProblem "client.models.$alias" 'model_not_available' 'must be one of client.models.available'))
            }
        }
        if ([long]$client.minimumTokenLifetimeSeconds -le [long]$client.helperTtlSeconds) {
            $p.Add((New-CoreRuleProblem 'client.minimumTokenLifetimeSeconds' 'token_lifetime_order' 'must exceed helperTtlSeconds'))
        }
    }
    $apps = $Answers.names.apps
    if ($Answers.workbook -is [System.Collections.IDictionary] -and $Answers.workbook.settings -is [System.Collections.IDictionary] -and (Test-Ready 'workbook')) {
        # WP-WB analytics/workbooks/config.ts: topUsers must not exceed maxRows.
        if ([long]$Answers.workbook.settings.topUsers -gt [long]$Answers.workbook.settings.maxRows) {
            $p.Add((New-CoreRuleProblem 'workbook.settings.topUsers' 'top_users_exceed_rows' 'must not exceed maxRows'))
        }
    }
    if ($apps -is [System.Collections.IDictionary] -and (Test-Ready 'names')) {
        foreach ($field in @('functionApp', 'plan', 'storageAccount', 'appInsights')) {
            $values = @('resolver', 'sync', 'reconciler' | ForEach-Object { $apps[$_][$field] } | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            if (@($values | Select-Object -Unique).Count -ne $values.Count) {
                $p.Add((New-CoreRuleProblem "names.apps.*.$field" 'duplicate_name' 'each app needs its own'))
            }
        }
    }
    return $p.ToArray()
}

function Get-CoreStageProblems {
    <#
    .SYNOPSIS
        The sections a stage needs (x-ccof-stages in the schema), or -Sections when a run reads fewer
        of them. A missing section is expanded into every required decision inside it. "a|b" means
        exactly one of a or b.
    #>
    param([System.Collections.IDictionary]$Answers, $Schema, [Parameter(Mandatory)] [string]$Stage, [string[]]$Sections)
    $p = [System.Collections.Generic.List[object]]::new()
    $stages = $Schema['x-ccof-stages']
    if (-not $stages.Contains($Stage)) { $p.Add((New-CoreRuleProblem 'stage' 'unknown_stage' "one of $(@($stages.Keys) -join ', ')")); return $p.ToArray() }
    $requirements = if ($PSBoundParameters.ContainsKey('Sections')) { @($Sections) } else { @($stages[$Stage]) }
    foreach ($requirement in $requirements) {
        $choices = @($requirement -split '\|')
        $present = @($choices | Where-Object { $Answers.Contains($_) })
        if ($choices.Count -gt 1) {
            if ($present.Count -eq 0) { $p.Add((New-CoreRuleProblem ($choices -join ' | ') 'missing' 'give exactly one of these')) }
            continue
        }
        if ($present.Count -eq 0) {
            foreach ($leaf in (Get-CoreRequiredLeaves -Schema $Schema['properties'][$requirement] -Root $Schema -Prefix $requirement)) {
                $p.Add((New-CoreRuleProblem $leaf 'missing' 'required decision'))
            }
        }
    }
    return $p.ToArray()
}

function Resolve-CoreAnswerPath {
    param([string]$BaseDirectory, [string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Test-CorePathInside {
    param([string]$Child, [string]$Parent)
    $c = [System.IO.Path]::GetFullPath($Child).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $r = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $c.StartsWith($r, $comparison)
}

function Test-CoreLocalFiles {
    param([System.Collections.IDictionary]$Answers, [string]$BaseDirectory, [string]$RepositoryRoot, [string[]]$Sections)
    $p = [System.Collections.Generic.List[object]]::new()
    if ($Sections -contains 'rateCard' -and $Answers.rateCard -is [System.Collections.IDictionary]) {
        $card = Resolve-CoreAnswerPath $BaseDirectory $Answers.rateCard.path
        if (-not (Test-Path -LiteralPath $card -PathType Leaf)) { $p.Add((New-CoreRuleProblem 'rateCard.path' 'rate_card_missing' 'file not found')) }
        else {
            $version = $null
            try { $version = (ConvertFrom-CoreJson (Get-Content -LiteralPath $card -Raw)).version } catch { $version = $null }
            if (-not [string]::Equals([string]$version, [string]$Answers.rateCard.version, 'Ordinal')) {
                $p.Add((New-CoreRuleProblem 'rateCard.version' 'rate_card_version_mismatch' 'must equal the version inside the rate card file'))
            }
        }
        if (-not (Test-Path -LiteralPath (Resolve-CoreAnswerPath $BaseDirectory $Answers.rateCard.contractSchedulePath) -PathType Leaf)) {
            $p.Add((New-CoreRuleProblem 'rateCard.contractSchedulePath' 'contract_schedule_missing' 'file not found'))
        }
    }
    $alerts = if ($Sections -contains 'telemetry' -and $Answers.telemetry -is [System.Collections.IDictionary]) { $Answers.telemetry.alertConfigurationFile } else { $null }
    if ($null -ne $alerts -and -not (Test-Path -LiteralPath (Resolve-CoreAnswerPath $BaseDirectory $alerts) -PathType Leaf)) {
        $p.Add((New-CoreRuleProblem 'telemetry.alertConfigurationFile' 'alert_configuration_missing' 'file not found'))
    }
    if ($RepositoryRoot -and (Test-CorePathInside (Resolve-CoreAnswerPath $BaseDirectory $Answers.output.directory) $RepositoryRoot)) {
        $p.Add((New-CoreRuleProblem 'output.directory' 'output_inside_repository' 'keep generated files outside the repository'))
    }
    return $p.ToArray()
}

function Find-CorePendingValues {
    <#
    .SYNOPSIS
        Strings of the form "PENDING:<who>:<reason>" mark a decision someone still has to make
        (WP-Validation's answers files). Each is reported as pending_decision with its path.
    #>
    param($Value, [string]$Path)
    if ($Value -is [string] -and $Value.StartsWith('PENDING:', [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ path = $Path; code = 'pending_decision'; detail = 'marked PENDING; a decision is still needed' }
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) { Find-CorePendingValues -Value $Value[$key] -Path $(if ($Path) { "$Path.$key" } else { $key }) }
    }
    elseif ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        for ($i = 0; $i -lt $Value.Count; $i++) { Find-CorePendingValues -Value $Value[$i] -Path "$Path[$i]" }
    }
}

function Read-CoreAnswers {
    <#
    .SYNOPSIS
        Reads, completes and checks an answers file for one stage (D1, D2 or D3). Returns Answers,
        Problems, Digest and paths. Makes no Azure call. Problems is empty only when the stage may
        continue. -Sections narrows the stage to the sections a run reads (D2 -Steps): each must be
        one of the stage's sections, and only these are checked for PENDING and missing decisions.
        Schema problems and cross-field rules still cover the whole file.
    #>
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [ValidateSet('D1', 'D2', 'D3')] [string]$Stage,
        [string]$RepositoryRoot,
        [AllowEmptyCollection()] [string[]]$Sections,
        [string]$SchemaPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/core.answers.schema.json')
    )
    $result = [ordered]@{ Answers = $null; Problems = @(); Digest = $null; AnswersPath = $null; AnswersDirectory = $null; AvailabilitySource = 'inline'; Stage = $Stage }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $result.AnswersPath = $fullPath
    $result.AnswersDirectory = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $result.Problems = @(New-CoreRuleProblem 'answers' 'answers_not_found' 'file not found'); return [pscustomobject]$result
    }
    $raw = Get-Content -LiteralPath $fullPath -Raw
    try { $answers = ConvertFrom-CoreJson $raw }
    catch { $result.Problems = @(New-CoreRuleProblem 'answers' 'answers_not_json' 'the file is not valid JSON'); return [pscustomobject]$result }
    $schema = ConvertFrom-CoreJson (Get-Content -LiteralPath $SchemaPath -Raw)
    $stageList = @($schema['x-ccof-stages'][$Stage])
    if ($PSBoundParameters.ContainsKey('Sections')) {
        $outside = @($Sections | Where-Object { $stageList -cnotcontains $_ })
        if (@($Sections).Count -eq 0 -or $outside.Count) {
            $result.Problems = @(New-CoreRuleProblem 'sections' 'unknown_section' "each must be one of the $Stage sections: $($stageList -join ', ')"); return [pscustomobject]$result
        }
        $stageList = @($Sections)
    }
    $problems = [System.Collections.Generic.List[object]]::new()
    # A decision still PENDING blocks only the stages that read its section; the always-required
    # top-level keys (target, output, ...) are read by every stage.
    $stageSections = @(@($stageList | ForEach-Object { $_ -split '\|' }) + @($schema['required']))
    $pending = @(Find-CorePendingValues -Value $answers -Path '')
    $pendingSections = @($pending | ForEach-Object { ($_.path -split '[.\[]')[0] } | Select-Object -Unique)
    foreach ($x in $pending) { if ($stageSections -contains ($x.path -split '[.\[]')[0]) { $problems.Add($x) } }
    $pendingPaths = @($pending | ForEach-Object { $_.path })
    foreach ($x in @(Test-CoreSchema -Value $answers -Schema $schema)) { if ($pendingPaths -notcontains $x.path) { $problems.Add($x) } }
    if ($answers -isnot [System.Collections.IDictionary]) { $result.Problems = $problems.ToArray(); return [pscustomobject]$result }
    foreach ($x in @(Get-CoreStageProblems -Answers $answers -Schema $schema -Stage $Stage -Sections $stageList)) { $problems.Add($x) }
    if ($answers.Contains('availability') -and $answers.Contains('availabilityFile')) {
        $problems.Add((New-CoreRuleProblem 'availability | availabilityFile' 'conflict' 'give exactly one of these, not both'))
    }
    elseif ($answers.Contains('availabilityFile') -and $answers.availabilityFile -is [string]) {
        $stage0Path = Resolve-CoreAnswerPath $result.AnswersDirectory $answers.availabilityFile
        $result.AvailabilitySource = $stage0Path
        if (-not (Test-Path -LiteralPath $stage0Path -PathType Leaf)) { $problems.Add((New-CoreRuleProblem 'availabilityFile' 'availability_file_missing' 'file not found')) }
        else {
            try {
                $stage0 = ConvertFrom-CoreJson (Get-Content -LiteralPath $stage0Path -Raw)
                foreach ($x in @(Test-CoreSchema -Value $stage0 -Schema $schema['$defs']['availability'] -Root $schema -Path 'availability')) { $problems.Add($x) }
                $answers.availability = $stage0
            }
            catch { $problems.Add((New-CoreRuleProblem 'availabilityFile' 'availability_file_not_json' 'the file is not valid JSON')) }
        }
    }
    if ($problems.Count -eq 0) {
        foreach ($x in @(Test-CoreAnswerRules -Answers $answers -SkipSections $pendingSections)) { $problems.Add($x) }
        $sections = @($stageList | ForEach-Object { $_ -split '\|' })
        foreach ($x in @(Test-CoreLocalFiles -Answers $answers -BaseDirectory $result.AnswersDirectory -RepositoryRoot $RepositoryRoot -Sections $sections)) { $problems.Add($x) }
    }
    $result.Answers = $answers
    $result.Problems = $problems.ToArray()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-CoreCanonicalJson $answers))
    $result.Digest = ([System.Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    return [pscustomobject]$result
}

function Format-CoreProblems {
    <#
    .SYNOPSIS
        Administrator-facing lines for a refusal: every missing decision, then every other problem.
    #>
    param([object[]]$Problems)
    $lines = [System.Collections.Generic.List[string]]::new()
    $all = @($Problems)
    $lines.Add("REFUSED before any Azure call: the answers file has $($all.Count) problem(s). Nothing was changed.")
    $missing = @($all | Where-Object code -eq 'missing')
    if ($missing.Count) {
        $lines.Add("Missing decisions ($($missing.Count)) - add each to the answers file (docs/DEPLOYMENT-STAGES.md):")
        foreach ($m in $missing) { $lines.Add("  - $($m.path)") }
    }
    $pending = @($all | Where-Object code -eq 'pending_decision')
    if ($pending.Count) {
        $lines.Add("Decisions still marked PENDING ($($pending.Count)):")
        foreach ($m in $pending) { $lines.Add("  - $($m.path)") }
    }
    $other = @($all | Where-Object { $_.code -notin @('missing', 'pending_decision') })
    if ($other.Count) {
        $lines.Add("Other problems ($($other.Count)):")
        foreach ($o in $other) { $lines.Add("  - $($o.path) [$($o.code)]: $($o.detail)") }
    }
    return $lines.ToArray()
}

Export-ModuleMember -Function Read-CoreAnswers, Test-CoreAnswerRules, Get-CoreStageProblems, Format-CoreProblems, Resolve-CoreAnswerPath, Test-CorePathInside, Find-CorePendingValues
