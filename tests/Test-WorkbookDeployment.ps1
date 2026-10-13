#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:Pass = 0
$script:Fail = 0
function Assert-True([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:Pass++; Write-Host "PASS: $Name" }
    else { $script:Fail++; Write-Host "FAIL: $Name $Detail" }
}
$deploy = Join-Path $root 'infra\workbook\deploy.ps1'
$verify = Join-Path $root 'infra\workbook\Test-WorkbookKql.ps1'
$preconditions = Join-Path $root 'infra\workbook\preconditions.ps1'
Assert-True 'workbook deploy script exists' (Test-Path $deploy)
Assert-True 'explicit live KQL script exists' (Test-Path $verify)
Assert-True 'workbook resource response guard exists' (Test-Path $preconditions)
if (Test-Path $preconditions) {
    . $preconditions
    $id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/fixture-rg/providers/Microsoft.Insights/workbooks/33333333-3333-4333-8333-333333333333'
    $resource = [PSCustomObject]@{ id = $id.ToLowerInvariant(); name = '33333333-3333-4333-8333-333333333333'; kind = 'shared'; type = $null }
    Assert-True 'live ARM null type still requires exact resource identity and shared kind' (Test-WorkbookResource $resource $id)
    $resource.type = 'Microsoft.Insights/workbooks'
    Assert-True 'documented ARM type is also accepted' (Test-WorkbookResource $resource $id)
    foreach ($field in 'id', 'name', 'kind', 'type') {
        $changed = $resource | ConvertTo-Json | ConvertFrom-Json
        $changed.$field = 'wrong-value'
        Assert-True "negative workbook resource $field" (-not (Test-WorkbookResource $changed $id))
    }
    Assert-True 'a missing workbook is not an existing prerequisite' (-not (Test-WorkbookResource $null $id))
    Assert-True 'a mismatched target is not an existing prerequisite' (-not (Test-WorkbookResource $resource ($id + '-other')))
}
if (Test-Path $deploy) {
    $code = Get-Content $deploy -Raw
    Assert-True 'offline validation is before Azure use' ($code.Contains('if ($ValidateOnly)') -and $code.IndexOf('if ($ValidateOnly)') -lt $code.IndexOf('az account show'))
    Assert-True 'deployment explicitly scopes subscription' ($code.Contains('az deployment group create --subscription $answers.subscriptionId'))
    Assert-True 'deployment never signs in or changes shared subscription' ($code -notmatch 'az\s+(login|account\s+set)')
    Assert-True 'tenant equality uses ordinal comparison' ($code.Contains("[string]::Equals($('$tenant'), $('$answers.tenantId'), 'Ordinal')"))
    Assert-True 'deployment verifies terminal success' ($code.Contains("'Succeeded'"))
    Assert-True 'D2 checks that D1 created the workbook before a content write' ($code.Contains('workbook_prerequisite_missing') -and $code.IndexOf('workbook_prerequisite_missing') -lt $code.IndexOf('az deployment group create'))
    foreach ($guard in 'gateway_unavailable', 'reconciler_unavailable', 'retention_mismatch') {
        Assert-True "D2 refuses with $guard before a content write" ($code.Contains("throw '$guard'") -and $code.IndexOf("throw '$guard'") -lt $code.IndexOf('az deployment group create'))
    }
    Assert-True 'D2 requires the build outcome validated, not only exit code 0' ($code.Contains("outcome, 'validated', 'Ordinal'") -and $code.IndexOf("outcome, 'validated', 'Ordinal'") -lt $code.IndexOf('if ($ValidateOnly)'))
    Assert-True 'retention answer must equal the live workspace retention' ($code.Contains('--query properties.retentionInDays') -and $code.Contains("-not [string]::Equals([string]`$retention, [string]`$answers.retentionDays, 'Ordinal')) { throw 'retention_mismatch' }"))
    $output = & pwsh -NoProfile -File $deploy -ValidateOnly 2>&1
    Assert-True 'missing answers refuse without a prompt' ($LASTEXITCODE -ne 0 -and ($output -join "`n") -match 'answers_required')
}
if (Test-Path $verify) {
    $old = $env:CCOF_LIVE_TESTS
    try {
        $env:CCOF_LIVE_TESTS = '0'
        $output = & pwsh -NoProfile -File $verify 2>&1
        Assert-True 'live KQL refuses without explicit opt-in' ($LASTEXITCODE -ne 0 -and ($output -join "`n") -match 'live_opt_in_required')
    } finally { $env:CCOF_LIVE_TESTS = $old }
}
$verifyDeployment = Join-Path $root 'infra\workbook\verify.ps1'
Assert-True 'deployed workbook verifier exists' (Test-Path $verifyDeployment)
if (Test-Path $verifyDeployment) {
    $code = Get-Content $verifyDeployment -Raw
    Assert-True 'verifier reads content only with canFetchContent' ($code.Contains('canFetchContent=true') -and $code -notmatch 'Method\s+(Put|Patch|Delete|Post)\s+-Uri\s+"https://management')
    $contentGuard = "if (`$LASTEXITCODE -ne 0 -or -not (Get-NodeOutcome `$compare 'content_matches')) { throw 'deployed_content_differs' }"
    Assert-True 'verifier compares content before running any query' ($code.Contains($contentGuard) -and $code.IndexOf($contentGuard) -lt $code.IndexOf('api.loganalytics.azure.com'))
    foreach ($outcome in 'validated', 'content_matches', 'rendered', 'summarized') {
        Assert-True "verifier requires the node outcome $outcome, not only exit code 0" ($code.Contains("Get-NodeOutcome `$") -and $code -match "Get-NodeOutcome \`$\w+ '$outcome'")
    }
    Assert-True 'verifier writes no query result or deployed content to disk' ($code -notmatch '\$(response|deployed)\b[^\r\n]*\|\s*Set-Content' -and $code -notmatch 'Set-Content[^\r\n]*\$(response|deployed|serialized)')
    Assert-True 'verifier removes its rendered queries file' ($code -match '(?s)finally\s*\{.*Remove-Item -LiteralPath \$queriesPath')
    Assert-True 'verifier never signs in or changes shared subscription' ($code -notmatch 'az\s+(login|account\s+set)')
    Assert-True 'verifier clears both tokens' ($code -match '(?s)finally\s*\{\s*\$armToken = \$null\s*\$queryToken = \$null')
    # A literal project id: PowerShell on Linux globs a bare * passed to a native command.
    $refusals = @(
        @{ name = 'missing answers'; args = @(); reason = 'answers_required' },
        @{ name = 'missing period'; args = @('-AnswersPath', 'x.json', '-Project', 'CCOFPILOT01'); reason = 'period_required' },
        @{ name = 'unknown period'; args = @('-AnswersPath', 'x.json', '-Period', 'Month', '-Project', 'CCOFPILOT01'); reason = 'period_required' },
        @{ name = 'missing project'; args = @('-AnswersPath', 'x.json', '-Period', 'month'); reason = 'project_required' },
        @{ name = 'custom without range'; args = @('-AnswersPath', 'x.json', '-Period', 'custom', '-Project', 'CCOFPILOT01'); reason = 'custom_range_required_only_for_custom' },
        @{ name = 'range outside custom'; args = @('-AnswersPath', 'x.json', '-Period', 'month', '-Project', 'CCOFPILOT01', '-From', '2026-10-01T00:00:00Z', '-To', '2026-10-02T00:00:00Z'); reason = 'custom_range_required_only_for_custom' },
        @{ name = 'unreadable answers'; args = @('-AnswersPath', (Join-Path $root '.env.absent-answers.json'), '-Period', 'month', '-Project', 'CCOFPILOT01'); reason = 'answers_file_unavailable' }
    )
    foreach ($case in $refusals) {
        $caseArgs = $case.args
        $output = & pwsh -NoProfile -File $verifyDeployment @caseArgs 2>&1
        Assert-True "verifier refuses $($case.name) before any Azure call" ($LASTEXITCODE -ne 0 -and ($output -join "`n") -match $case.reason)
    }
}

# Requests 6, 8 and 9 (docs/status/WP-WB.md): the real scripts run in this process against a fake
# Azure. az, Invoke-RestMethod and node are the helper's functions, which take precedence over the
# Azure CLI, the cmdlet and the executable, so no test reaches Azure (U-new-WB-13).
Import-Module (Join-Path $PSScriptRoot 'helpers' 'workbook-fake-cloud.psm1') -Force
Import-Module (Join-Path $root 'scripts' 'Onboarding.Azure.psm1') -Force
$tmp = Join-Path ([IO.Path]::GetTempPath()) "ccof-workbook-$(Get-Random)"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$outputDirectory = ".env.workbook-test-$(Get-Random)"
function New-WorkbookAnswers([hashtable]$Change = @{}) {
    $subscription = '11111111-1111-4111-8111-111111111111'
    $scope = "/subscriptions/$subscription/resourceGroups/fixture-rg/providers"
    $values = [ordered]@{
        schemaVersion = 1; subscriptionId = $subscription; tenantId = '22222222-2222-4222-8222-222222222222'
        resourceGroupName = 'fixture-rg'; location = 'eastus2'; deploymentName = 'fixture-workbook-deployment'
        workbookResourceName = '33333333-3333-4333-8333-333333333333'; workbookDisplayName = 'Fixture chargeback'
        workspaceResourceId = "$scope/Microsoft.OperationalInsights/workspaces/fixture-law"
        gatewayResourceId = "$scope/Microsoft.ApiManagement/service/fixture-apim"
        reconcilerResourceId = "$scope/Microsoft.Web/sites/fixture-reconciler"
        rateCardPath = (Join-Path $root 'tests' 'fixtures' 'workbook' 'pilot-rate-card.json'); ledgerPath = (Join-Path $root 'analytics' 'ledger.kql')
        outputDirectory = $outputDirectory; defaultProjectId = 'CCOFPILOT01'
        maxRows = 500; topUsers = 20; maxQueryDays = 62; budgetLookbackDays = 31; retentionDays = 35
    }
    foreach ($key in $Change.Keys) { $values[$key] = $Change[$key] }
    $path = Join-Path $tmp "answers-$(Get-Random).json"
    $values | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    @{ Path = $path; Values = $values }
}
function Test-GuardAccepts([string]$Argument) {
    try { Assert-OnboardingAzArguments @('--subscription', '11111111-1111-4111-8111-111111111111', $Argument); $true } catch { $false }
}
# Runs a WP-WB script here (not from inside the helper module) with the fake Azure enabled: its output
# lines, exit code, last audit outcome and reason, and the az and node calls it made.
function Invoke-WorkbookScript([hashtable]$Cloud, [string]$Path, [hashtable]$Parameters) {
    $azBefore = $Cloud.Az.Count; $nodeBefore = $Cloud.Node.Count
    Enable-WorkbookFakeCloud $Cloud
    try {
        $global:LASTEXITCODE = 0
        $lines = @(& $Path @Parameters 2>&1 | ForEach-Object { [string]$_ })
        $exit = $global:LASTEXITCODE
    }
    finally { Disable-WorkbookFakeCloud }
    $audit = @($lines | Where-Object { $_ -match '^\{"schema":"ccof\.workbook\.(deploy|verify)\.v1"' }) | Select-Object -Last 1
    $parsed = if ($audit) { $audit | ConvertFrom-Json } else { $null }
    [pscustomobject]@{
        Lines = $lines; Exit = $exit; Outcome = [string]$parsed.outcome; Reason = [string]$parsed.reason
        Az = $Cloud.Az.GetRange($azBefore, $Cloud.Az.Count - $azBefore).ToArray()
        Node = $Cloud.Node.GetRange($nodeBefore, $Cloud.Node.Count - $nodeBefore).ToArray()
    }
}
$deployScript = Join-Path $root 'infra' 'workbook' 'deploy.ps1'
$verifyScript = Join-Path $root 'infra' 'workbook' 'verify.ps1'
try {
    # Request 8: node on Linux reads \ as part of a file name (U-new-WB-9), so 'analytics\workbooks\build.ts'
    # names no file there. No WP-WB script writes a node argument with \ ...
    $offenders = foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'infra' 'workbook') -Filter '*.ps1') {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        $strings = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
        foreach ($s in $strings) {
            if ($s.Value.Contains('\') -and $s.Parent -is [System.Management.Automation.Language.CommandAst] -and $s.Parent.GetCommandName() -ceq 'node') { "$($file.Name):$($s.Extent.StartLineNumber)" }
        }
    }
    Assert-True 'no WP-WB script gives node a path written with \ (node on Linux reads it as one file name)' (-not $offenders) ($offenders -join ', ')
    # ... and every node call gets the script's full path in this platform's separators. These runs use
    # the real node, so on Linux (CI) they also fail outright on the old form.
    $answers = New-WorkbookAnswers
    $cloud = New-WorkbookFakeCloud -Answers $answers.Values
    $verifyParameters = @{ AnswersPath = $answers.Path; Period = 'month'; Project = 'CCOFPILOT01' }
    $validate = Invoke-WorkbookScript $cloud $deployScript @{ AnswersPath = $answers.Path; ValidateOnly = $true }
    Assert-True 'deploy.ps1 -ValidateOnly runs the real build and makes no az call' ($validate.Outcome -ceq 'validated' -and -not $validate.Az.Count) "$($validate.Outcome) $($validate.Reason); az calls: $($validate.Az.Count)"
    # Request 6, WP-WB's side: verify.ps1 tells reviewed content from a D1 shell, which D2 redeploys on.
    $shell = Invoke-WorkbookScript $cloud $verifyScript $verifyParameters
    Assert-True 'verify.ps1 refuses a D1 shell that holds no reviewed content: deployed_content_differs' ($shell.Outcome -ceq 'refused' -and $shell.Reason -ceq 'deployed_content_differs' -and $shell.Exit -eq 1) "$($shell.Outcome) $($shell.Reason) exit $($shell.Exit)"
    $deployed = Invoke-WorkbookScript $cloud $deployScript @{ AnswersPath = $answers.Path }
    $verified = Invoke-WorkbookScript $cloud $verifyScript $verifyParameters
    Assert-True 'deploy.ps1 then verify.ps1: deployed, then verified with every rendered query run' ($deployed.Outcome -ceq 'deployed' -and $verified.Outcome -ceq 'verified' -and $cloud.Queries -gt 0 -and ($verified.Lines[-1] | ConvertFrom-Json).queries -eq $cloud.Queries) "$($deployed.Outcome) $($deployed.Reason); $($verified.Outcome) $($verified.Reason); queries $($cloud.Queries)"
    Assert-True 'every az call deploy.ps1 made names --subscription and passes the Azure CLI guard as made' ($deployed.Az.Count -eq 7 -and -not @($deployed.Az | Where-Object { try { Assert-OnboardingAzArguments $_; $false } catch { $true } }).Count) "az calls: $($deployed.Az.Count)"
    # Council (QA): az gets no value but literals and the values each script guards, so a value added
    # to an az call later fails here until it joins its script's guard and this list.
    $whatIf = Invoke-WorkbookScript $cloud $deployScript @{ AnswersPath = $answers.Path; WhatIf = $true }
    $literals = @('account', 'show', 'get-access-token', 'resource', 'monitor', 'log-analytics', 'workspace', 'deployment', 'group', 'create', 'what-if', 'tsv', 'json',
        'tenantId', 'type', 'customerId', 'accessToken', 'properties.retentionInDays', 'properties.provisioningState', 'https://management.azure.com', 'https://api.loganalytics.io')
    $a = $answers.Values
    $guarded = @{
        deploy = @($a.subscriptionId, $a.resourceGroupName, $a.deploymentName, $a.workspaceResourceId, $a.gatewayResourceId, $a.reconcilerResourceId,
            "/subscriptions/$($a.subscriptionId)/resourceGroups/$($a.resourceGroupName)/providers/Microsoft.Insights/workbooks/$($a.workbookResourceName)",
            (Join-Path $root 'infra' 'workbook' 'main.bicep'), "@$(Join-Path $root (Join-Path $outputDirectory 'parameters.json'))")
        verify = @($a.subscriptionId, $a.workspaceResourceId)
    }
    $unexpected = @(foreach ($run in @{ Name = 'deploy'; Az = $deployed.Az }, @{ Name = 'deploy'; Az = $whatIf.Az }, @{ Name = 'verify'; Az = $verified.Az }) {
            $run.Az | ForEach-Object { $_ } | Where-Object { $_ -notmatch '^--[a-z-]+$' -and $literals -cnotcontains $_ -and $guarded[$run.Name] -cnotcontains $_ } | ForEach-Object { "$($run.Name): $_" }
        })
    Assert-True 'deploy.ps1 (with and without -WhatIf) and verify.ps1 give az no value but literals and the values each guards' ($whatIf.Reason -ceq 'what_if_recorded' -and $whatIf.Az.Count -eq 7 -and $verified.Az.Count -eq 4 -and -not $unexpected.Count) "what-if: $($whatIf.Outcome) $($whatIf.Reason), az calls $($whatIf.Az.Count); verify az calls $($verified.Az.Count); unexpected: $($unexpected -join ' | ')"
    Reset-WorkbookFakeShell $cloud
    $reset = Invoke-WorkbookScript $cloud $verifyScript $verifyParameters
    Assert-True 'a D1 shell re-created after D2 resets the content: verify.ps1 reports deployed_content_differs' ($reset.Outcome -ceq 'refused' -and $reset.Reason -ceq 'deployed_content_differs') "$($reset.Outcome) $($reset.Reason)"
    $scripts = @((Join-Path $root 'analytics' 'workbooks' 'build.ts'), (Join-Path $root 'analytics' 'workbooks' 'render.ts'))
    $calls = @($validate, $shell, $deployed, $verified, $reset | ForEach-Object { $_.Node } | ForEach-Object { , $_ })
    $wrong = @($calls | Where-Object { $scripts -cnotcontains $_[0] -or -not [IO.File]::Exists($_[0]) } | ForEach-Object { $_[0] })
    Assert-True 'deploy.ps1 and verify.ps1 give node the full path of build.ts and render.ts in this platform''s separators' ($calls.Count -ge 9 -and -not $wrong.Count) "node calls: $($calls.Count); wrong: $($wrong -join ', ')"

    # Request 9: az.cmd passes every argument through cmd.exe on Windows (& runs a command; ( or )
    # breaks its IF block). A value the Azure CLI guard refuses never reaches az, and a refusal comes
    # before the first az call. Each character is tried on its own. The build is a stand-in here, so
    # the guard alone decides.
    $azKeys = @{ deploy = @('subscriptionId', 'resourceGroupName', 'deploymentName', 'workbookResourceName', 'workspaceResourceId', 'gatewayResourceId', 'reconcilerResourceId', 'outputDirectory'); verify = @('subscriptionId', 'workspaceResourceId') }
    $stringKeys = @($answers.Values.Keys | Where-Object { $answers.Values[$_] -is [string] })
    foreach ($name in 'deploy', 'verify') {
        $path = if ($name -ceq 'deploy') { $deployScript } else { $verifyScript }
        foreach ($key in $stringKeys) {
            # One run per character where the value reaches az; one run with all three where it does not.
            $markers = if ($azKeys[$name] -ccontains $key) { '&', '(', ')' } else { , '&()' }
            $runs = foreach ($char in $markers) {
                $marked = New-WorkbookAnswers @{ $key = "$($answers.Values[$key])x${char}1" }
                $parameters = @{ AnswersPath = $marked.Path }
                if ($name -ceq 'verify') { $parameters += @{ Period = 'month'; Project = 'CCOFPILOT01' } }
                $r = Invoke-WorkbookScript (New-WorkbookFakeCloud -Answers $answers.Values -StubNode) $path $parameters
                $reached = @($r.Az | ForEach-Object { $_ } | Where-Object { -not (Test-GuardAccepts $_) })
                [pscustomobject]@{
                    Refused = $r.Reason -ceq 'az_arguments_refused' -and $r.Exit -eq 1 -and -not $r.Az.Count; Passed = $r.Reason -cne 'az_arguments_refused' -and -not $reached.Count
                    Detail = "${char}: $($r.Outcome) $($r.Reason), az calls $($r.Az.Count), refused values passed to az: $($reached -join ' | ')"
                }
            }
            $detail = ($runs | ForEach-Object Detail) -join '; '
            if ($azKeys[$name] -ccontains $key) {
                Assert-True "$name.ps1, $key holding &, ( or ): refused az_arguments_refused before any az call" (-not @($runs | Where-Object { -not $_.Refused }).Count) $detail
            } else {
                Assert-True "$name.ps1, $key holding &, ( or ), not an az argument: not refused by the guard, nothing refused reaches az" (-not @($runs | Where-Object { -not $_.Passed }).Count) $detail
            }
        }
    }
    # The case request 9 names: a checkout under a folder with &, ( or ) puts it in the template and
    # parameters file paths, which no answer check sees.
    $checkouts = foreach ($char in '&', '(', ')') {
        $checkout = Join-Path $tmp "ccof${char}1"
        foreach ($folder in 'scripts', (Join-Path 'infra' 'workbook')) {
            New-Item -ItemType Directory -Path (Join-Path $checkout $folder) -Force | Out-Null
            Copy-Item -Path (Join-Path $root $folder '*') -Destination (Join-Path $checkout $folder) -Include '*.ps1', '*.psm1', '*.bicep'
        }
        $checkout
    }
    foreach ($mode in @{}, @{ ValidateOnly = $true }) {
        $runs = foreach ($checkout in $checkouts) {
            $r = Invoke-WorkbookScript (New-WorkbookFakeCloud -Answers $answers.Values -StubNode) (Join-Path $checkout 'infra' 'workbook' 'deploy.ps1') (@{ AnswersPath = $answers.Path } + $mode)
            [pscustomobject]@{ Refused = $r.Reason -ceq 'az_arguments_refused' -and $r.Exit -eq 1 -and -not $r.Az.Count; Detail = "$(Split-Path $checkout -Leaf): $($r.Outcome) $($r.Reason), az calls $($r.Az.Count)" }
        }
        Assert-True "a checkout under a folder with &, ( or ): deploy.ps1$(if ($mode.Count) { ' -ValidateOnly' }) refuses az_arguments_refused before any az call" (-not @($runs | Where-Object { -not $_.Refused }).Count) (($runs | ForEach-Object Detail) -join '; ')
    }
}
catch { Assert-True 'the fake-Azure tests ran to completion' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" }
finally {
    Disable-WorkbookFakeCloud
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $root $outputDirectory) -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
