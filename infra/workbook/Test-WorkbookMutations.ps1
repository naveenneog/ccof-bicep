#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Push-Location $root
try {
    $testFiles = @(Get-ChildItem 'tests' -Filter 'workbook-*.test.ts' | Sort-Object Name | ForEach-Object FullName)
    function Invoke-WorkbookTests {
        $lines = @(& node --test --test-reporter=tap @testFiles 2>&1)
        $code = $LASTEXITCODE
        $output = $lines -join "`n"
        $count = [regex]::Match($output, '(?m)^# tests (\d+)\s*$')
        @{ code = $code; count = if ($count.Success) { [int]$count.Groups[1].Value } else { -1 }; output = $output }
    }
    $baseline = Invoke-WorkbookTests
    if ($baseline.code -ne 0 -or $baseline.count -lt 1) { throw 'mutation_baseline_not_green' }
    $mutations = @(
        @{ id = 'unknown-field'; file = 'analytics\workbooks\rate-card.ts'; from = 'if (![...required, ...optional].includes(key))'; to = 'if (false)'; test = 'workbook card refuses unknown field' },
        @{ id = 'positive-number'; file = 'analytics\workbooks\rate-card.ts'; from = 'value <= 0'; to = 'value < 0'; test = 'workbook configuration refuses invalid budgetLookbackDays' },
        @{ id = 'positive-rate'; file = 'analytics\workbooks\rate-card.ts'; from = '!new Money(value).gt(0)'; to = '!new Money(value).gte(0)'; test = 'workbook card refuses zero rate' },
        @{ id = 'decimal-precision'; file = 'analytics\workbooks\rate-card.ts'; from = 'value.precision() > 28 || value.decimalPlaces() > 28'; to = 'value.precision() > 60 || value.decimalPlaces() > 60'; test = 'workbook card refuses excess precision' },
        @{ id = 'currency'; file = 'analytics\workbooks\rate-card.ts'; from = 'if (unit.currency !== "USD")'; to = 'if (false)'; test = 'workbook card refuses currency' },
        @{ id = 'geo-sentinel'; file = 'analytics\workbooks\rate-card.ts'; from = ' || geo === "unknown"'; to = ''; test = 'workbook card refuses geo unknown sentinel' },
        @{ id = 'rate-unit'; file = 'analytics\workbooks\rate-card.ts'; from = '.mul(100).div(perTokens)'; to = '.mul(200).div(perTokens)'; test = 'every generated rate-card datatable cell matches the source fixture' },
        @{ id = 'kql-escaping'; file = 'analytics\workbooks\rate-card.ts'; from = '=> JSON.stringify(value);'; to = '=> value;'; test = 'workbook KQL string encoding contains quotes and line breaks inside one literal' },
        @{ id = 'resource-format'; file = 'analytics\workbooks\config.ts'; from = 'if (!pattern.test(answers[key] as string))'; to = 'if (false)'; test = 'workbook configuration refuses invalid subscriptionId' },
        @{ id = 'required-answer'; file = 'analytics\workbooks\config.ts'; from = '"maxRows", "topUsers", "maxQueryDays", "budgetLookbackDays",'; to = '"maxRows", "topUsers", "maxQueryDays",'; test = 'workbook configuration preserves explicit answers without deriving identities or thresholds' },
        @{ id = 'project-encoding'; file = 'analytics\workbooks\queries.ts'; from = 'base64_decode_tostring("{Project:base64}")'; to = 'tostring("{Project}")'; test = 'workbook builder includes all required sections, time selectors, IDs and export provenance' },
        @{ id = 'template-boundary'; file = 'infra\workbook\main.bicep'; from = 'Microsoft.Insights/workbooks@2023-06-01'; to = 'Microsoft.Web/sites@2023-06-01'; test = 'Bicep deploys only a shared workbook and has no environment defaults or hardcoded IDs' },
        @{ id = 'template-serialization'; file = 'infra\workbook\main.bicep'; from = 'serializedData: string(workbookContent)'; to = "serializedData: '{}'"; test = 'Bicep deploys only a shared workbook and has no environment defaults or hardcoded IDs' },
        @{ id = 'template-source'; file = 'infra\workbook\main.bicep'; from = 'sourceId: workspaceResourceId'; to = "sourceId: 'azure monitor'"; test = 'Bicep deploys only a shared workbook and has no environment defaults or hardcoded IDs' },
        @{ id = 'template-hardcoded-id'; file = 'infra\workbook\main.bicep'; from = "targetScope = 'resourceGroup'"; to = "targetScope = 'resourceGroup'`nvar accidentalId = '11111111-1111-4111-8111-111111111111'"; test = 'Bicep deploys only a shared workbook and has no environment defaults or hardcoded IDs' },
        @{ id = 'template-default'; file = 'infra\workbook\main.bicep'; from = 'param location string'; to = "param location string = 'eastus2'"; test = 'Bicep deploys only a shared workbook and has no environment defaults or hardcoded IDs' },
        @{ id = 'unknown-price-detector'; file = 'analytics\workbooks\pricing.kql'; from = 'candidateCcu, decimal(null)'; to = 'candidateCcu, decimal(0)'; test = 'workbook query sources guard partial costs, counts, time windows and latest budget state' },
        @{ id = 'budget-freshness-detector'; file = 'analytics\workbooks\budgets.kql'; from = 'arg_max(computedAt, *)'; to = 'arg_max(TimeGenerated, *)'; test = 'workbook query sources guard partial costs, counts, time windows and latest budget state' },
        @{ id = 'run-freshness-detector'; file = 'analytics\workbooks\budgets.kql'; from = 'arg_max(loggedAt, payload, eventIngestedAt)'; to = 'arg_min(loggedAt, payload, eventIngestedAt)'; test = 'workbook query sources guard partial costs, counts, time windows and latest budget state' },
        @{ id = 'no-usage-detector'; file = 'analytics\workbooks\pricing.kql'; from = '| where not(noUsage)'; to = '| where true'; test = 'workbook query sources guard partial costs, counts, time windows and latest budget state' },
        @{ id = 'no-backend-call-detector'; file = 'analytics\workbooks\pricing.kql'; from = 'usageSource == "no-backend-call"'; to = 'false'; test = 'workbook query sources guard partial costs, counts, time windows and latest budget state' },
        @{ id = 'health-no-usage'; file = 'analytics\workbooks\queries.ts'; from = 'noBackendCallRequests = tolong(NoUsage.refused), zeroTokenRequests = tolong(NoUsage.zeroTokens),'; to = ''; test = 'workbook health counts no-usage rows separately instead of pricing them' },
        @{ id = 'pilot-card-provenance'; file = 'tests\fixtures\workbook\pilot-rate-card.json'; from = '"version": "2026-10-11"'; to = '"version": "2026-10-12"'; test = 'the WP-COST pilot card compiles to exact CCU per token, with the dated Haiku alias and prompt tiers' },
        @{ id = 'render-unresolved'; file = 'analytics\workbooks\render.ts'; from = 'if (parameterToken.test(rendered)) throw new Error("render: unresolved_parameter");'; to = ''; test = 'workbook rendering refuses a query with an unresolved portal parameter' },
        @{ id = 'render-custom-range'; file = 'analytics\workbooks\render.ts'; from = 'if (custom ? !utc.test(value[key] ?? "") : value[key] !== null)'; to = 'if (false)'; test = 'workbook rendering refuses custom without range' },
        @{ id = 'compare-any-content'; file = 'analytics\workbooks\render.ts'; from = 'return isDeepStrictEqual(expected, JSON.parse(deployedSerializedData));'; to = 'return true;'; test = 'deployed content matches only the reviewed workbook, whatever its key order or spacing' },
        @{ id = 'summary-identity'; file = 'analytics\workbooks\render.ts'; from = 'const states = ["reportState",'; to = 'const states = ["person", "reportState",'; test = 'verification summaries carry counts and states, never person, scope or request ids' },
        @{ id = 'settings-unknown-field'; file = 'analytics\workbooks\config.ts'; from = 'const settings = fields(value, "settings", [...workbookSettingKeys]);'; to = 'const settings = fields(value, "settings", [...workbookSettingKeys], ["subscriptionId"]);'; test = "workbook settings for WP-CORE's answers file accept exactly the report settings" },
        @{ id = 'assignment-role-id'; file = 'infra\workbook\assignments.json'; from = '"roleDefinitionId": "73c42c96-874c-492b-b04d-ab87d138a893"'; to = '"roleDefinitionId": "acdd72a7-3385-48ef-bd42-f606fba81ae7"'; test = 'D3 data grants workbook readers read-only access to the workbook and its workspace, nothing else' },
        @{ id = 'assignment-scope'; file = 'infra\workbook\assignments.json'; from = '"scope": "${d1.workspace.id}"'; to = '"scope": "${d1.target.resourceGroup}"'; test = 'D3 data grants workbook readers read-only access to the workbook and its workspace, nothing else' },
        @{ id = 'screenshot-title-drift'; file = 'infra\workbook\screenshot-steps.json'; from = '"Coverage and observed delivery lag", "Usage'; to = '"Coverage and delivery lag", "Usage'; test = 'every screenshot step names items, titles and selector labels that the built workbook really has' },
        @{ id = 'unc-guard'; file = 'analytics\workbooks\config.ts'; from = '/^(?:[\\/]{2}|[a-z][a-z0-9+.-]*:[\\/]{2})/i'; to = '/^(?:\\\\|\/\/|[a-z]+:\/\/)/i'; test = 'workbook configuration refuses UNC, device and URL paths in any separator mix' },
        @{ id = 'calendar-month'; file = 'analytics\workbooks\config.ts'; from = 'if ((settings.maxQueryDays as number) < 31)'; to = 'if (false)'; test = "workbook settings for WP-CORE's answers file accept exactly the report settings" },
        @{ id = 'lf-normalization'; file = 'analytics\workbooks\build.ts'; from = 'value.replace(/\r\n/g, "\n");'; to = 'value;'; test = 'workbook content and digests do not depend on line endings or machine-specific paths' },
        @{ id = 'content-tag'; file = 'analytics\workbooks\build.ts'; from = ', "ccof-content": digest(JSON.stringify(workbook)),'; to = ','; test = 'workbook builder includes all required sections, time selectors, IDs and export provenance' },
        @{ id = 'entry-guard-realpath'; file = 'analytics\workbooks\main.ts'; from = 'return realpathSync(entry) === realpathSync(fileURLToPath(moduleUrl));'; to = 'return entry === fileURLToPath(moduleUrl);'; test = 'command-line entry guard runs through a junction or symlink checkout and nowhere else' },
        @{ id = 'retention-in-rollup'; file = 'analytics\workbooks\queries.ts'; from = 'listCcu = iff(not(RetentionTruncated) and requests > 0'; to = 'listCcu = iff(requests > 0'; test = 'workbook builder includes all required sections, time selectors, IDs and export provenance' },
        @{ id = 'reason-detector'; file = 'analytics\workbooks\pricing.kql'; from = 'anyInForce == 0, "no_rate_in_force"'; to = 'not(inForce), "no_rate_in_force"'; test = 'workbook query sources guard partial costs, counts, time windows and latest budget state' },        @{ id = 'summary-missing-as-zero'; file = 'analytics\workbooks\render.ts'; from = 'values.length === 0 ? null'; to = 'values.length === -1 ? null'; test = 'verification summaries carry counts and states, never person, scope or request ids' },
        @{ id = 'summary-precision'; file = 'analytics\workbooks\render.ts'; from = 'Decimal.clone({ precision: 60 })'; to = 'Decimal.clone({ precision: 20 })'; test = 'verification summaries carry counts and states, never person, scope or request ids' },
        @{ id = 'screenshot-save-allowed'; file = 'infra\workbook\screenshot-steps.json'; from = '"Edit", "Save", "Save As"'; to = '"Edit", "Save As"'; test = 'screenshot steps cover the resource, selectors, usage, budgets and export, read-only and redacted' },
        @{ id = 'budget-version-untyped'; file = 'analytics\workbooks\budgets.kql'; from = 'extract_json("$.rateCardVersion", Message, typeof(string))'; to = 'tostring(payload.rateCardVersion)'; test = 'workbook query sources guard partial costs, counts, time windows and latest budget state' },
        @{ id = 'budget-version-detector'; file = 'analytics\workbooks\build.ts'; from = '/rateCardVersion = extract_json\("\$\.rateCardVersion", Message, typeof\(string\)\)/'; to = '/rateCardVersion = /'; test = 'workbook query sources guard partial costs, counts, time windows and latest budget state' }
    )
    $caught = 0
    foreach ($mutation in $mutations) {
        $original = Get-Content -LiteralPath $mutation.file -Raw
        if (-not $original.Contains($mutation.from)) { throw "mutation_anchor_missing_$($mutation.id)" }
        try {
            [IO.File]::WriteAllText((Join-Path $root $mutation.file), $original.Replace($mutation.from, $mutation.to), [Text.UTF8Encoding]::new($false))
            $result = Invoke-WorkbookTests
            $target = '(?m)^not ok \d+ - ' + [regex]::Escape($mutation.test) + '\s*$'
            if ($result.code -eq 0 -or $result.count -ne $baseline.count -or $result.output -notmatch $target) {
                throw "mutation_not_proved_$($mutation.id)"
            }
            $caught++
            [ordered]@{ schema = 'ccof.workbook.mutation.v1'; id = $mutation.id; outcome = 'caught'; tests = $result.count } | ConvertTo-Json -Compress
        } finally {
            [IO.File]::WriteAllText((Join-Path $root $mutation.file), $original, [Text.UTF8Encoding]::new($false))
        }
    }
    $restored = Invoke-WorkbookTests
    if ($restored.code -ne 0 -or $restored.count -ne $baseline.count) { throw 'restored_suite_not_green' }
    [ordered]@{ schema = 'ccof.workbook.mutation.v1'; outcome = 'passed'; mutations = $caught; tests = $baseline.count } | ConvertTo-Json -Compress
} finally {
    Pop-Location
}
