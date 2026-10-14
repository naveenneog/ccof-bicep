<#
.SYNOPSIS
Names the exact form field behind "seed_document_invalid: Answers failed schema validation".

.DESCRIPTION
Read-only. Compiles the parameters file, builds the same project documents the quick-start's step 1
and step 5 build, and validates each one against the onboarding schemas. Prints "ok" per group and
per project, or the failing JSON path and the rule it breaks. It also reports duplicate
project/classification pairs and projects whose groups select different backends.

.EXAMPLE
pwsh -File scripts/diagnostics/Find-SeedError.ps1 -ParametersPath infra/quickstart/.env.customer.bicepparam
#>
param([string]$ParametersPath = 'infra/quickstart/.env.customer.bicepparam')
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'Onboarding.Schemas.psm1') -Force

$built = az bicep build-params --file $ParametersPath --stdout 2>$null | ConvertFrom-Json -Depth 100
if ($LASTEXITCODE -ne 0 -or -not $built) { throw "Bicep could not compile $ParametersPath. Run: az bicep build-params --file $ParametersPath" }
$params = ($built.parametersJson | ConvertFrom-Json -AsHashtable -Depth 100).parameters
$groups = $params.groups.value
$backends = @{}; foreach ($b in $params.backends.value) { $backends[$b.id] = $b }

$famSchema = ConvertTo-Json (Get-OnboardingFamilyPolicySchema) -Depth 64 -Compress
$projSchema = ConvertTo-Json (Get-OnboardingProjectSchema) -Depth 64 -Compress
# The schemas have alternative branches (null versus set limits, optional families). A failure lists
# every branch's complaint; these patterns drop the complaints of branches that were not meant.
$noise = 'but should be "null"|Required properties \["(fable|mythos)"\]|"null" but should be "(integer|string|object)"|specified by the enum at .*/tokenQuotaPeriod'

function Write-Result([string]$Label, $Errors) {
    if (-not $Errors) { "ok   $Label"; return }
    $all = @($Errors | ForEach-Object { $_.Exception.Message -replace '^The JSON is not valid with the schema: ', '' })
    $real = @($all | Where-Object { $_ -notmatch $noise } | Sort-Object -Unique)
    "FAIL $Label"
    if ($real) { $real | ForEach-Object { "     $_" } } else { $all | Sort-Object -Unique | ForEach-Object { "     $_" } }
}

$projects = [ordered]@{}
$failed = $false
foreach ($g in $groups) {
    $label = "$($g.projectId)/$($g.classification)"
    $e = $null
    $null = Test-Json -Json (ConvertTo-Json $g.familyPolicy -Depth 64 -Compress) -Schema $famSchema -ErrorVariable e -ErrorAction SilentlyContinue
    if ($e) { $failed = $true }
    Write-Result "familyPolicy of $label" $e
    if (-not $backends.ContainsKey([string]$g.backendId)) { $failed = $true; "FAIL $label backendId '$($g.backendId)' is not a backends[].id"; continue }
    if (-not $projects.Contains($g.projectId)) {
        $projects[$g.projectId] = [ordered]@{ id = $g.projectId; projectId = $g.projectId; displayName = $g.projectId; status = 'active'; backendId = $g.backendId; designatedSubscriptionId = $backends[$g.backendId].subscriptionId; supersedes = $null; retiredAt = $null; classifications = [ordered]@{} }
    }
    elseif ($projects[$g.projectId].backendId -cne $g.backendId) { $failed = $true; "FAIL $label uses backendId '$($g.backendId)' but project $($g.projectId) uses '$($projects[$g.projectId].backendId)' (seed_backend_conflict)" }
    if ($projects[$g.projectId].classifications.Contains($g.classification)) { $failed = $true; "FAIL $label appears twice (seed_group_duplicate)"; continue }
    $projects[$g.projectId].classifications[$g.classification] = [ordered]@{ groupId = $g.groupId; familyPolicy = $g.familyPolicy; personBudget = $g.personBudget; aggregateBudget = $g.aggregateBudget; aggregateMode = $g.aggregateMode; onboardingMode = $g.onboardingMode }
}
foreach ($proj in $projects.Values) {
    $e = $null
    $null = Test-Json -Json (ConvertTo-Json $proj -Depth 64 -Compress) -Schema $projSchema -ErrorVariable e -ErrorAction SilentlyContinue
    if ($e) { $failed = $true }
    Write-Result "project $($proj.projectId)" $e
}
if ($failed) { exit 1 }
