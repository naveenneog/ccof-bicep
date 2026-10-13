#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'infra\quickstart\Deploy-Quickstart.ps1') -DotSourceOnly
$pass = 0
function Assert-True([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:pass++
    Write-Host "PASS: $Name"
}

$script:name = '  Synthetic & R&D <"One"> / O''Brien \ Ω  '
$script:group = '44444444-4444-4444-8444-444444444444'
$script:graphCalls = 0
function Get-QsGraph {
    param([string]$Path)
    $script:graphCalls++
    Assert-True 'metadata selects actual group id and displayName' ($Path -ceq "groups/$script:group`?`$select=id,displayName")
    return @{ id = $script:group; displayName = $script:name }
}
$p = @{ groups = @(@{ projectId = 'SYNTHETIC'; classification = 'STD'; groupId = $script:group }) }
$names = @(Get-QsWorkbookGroups -P $p)
Assert-True 'exact Graph name retains spacing, punctuation and unicode' ($names[0].displayName -ceq $script:name)
Assert-True 'stable object ID accompanies displayName' ($names[0].groupId -ceq $script:group)
Assert-True 'metadata read once per configured group' ($script:graphCalls -eq 1)
$json = $names | ConvertTo-Json -Depth 10 -AsArray
Assert-True 'JSON round-trip preserves group name' (($json | ConvertFrom-Json)[0].displayName -ceq $script:name)

function Get-QsGraph { param([string]$Path) return @{ id = '55555555-5555-4555-8555-555555555555'; displayName = 'Wrong group' } }
$rejected = $false
try { Get-QsWorkbookGroups -P $p | Out-Null } catch { $rejected = $_.Exception.Message -match 'group_identity_mismatch' }
Assert-True 'wrong Graph object never supplies a directory label' $rejected
function Get-QsGraph { param([string]$Path) throw 'graph unavailable' }
$unknown = @(Get-QsWorkbookGroups -P $p)
Assert-True 'unavailable metadata is explicitly null, never classification label' ($null -eq $unknown[0].displayName)

function Add-SyntheticRouting($Parameters) {
    $limit = @{ tokensPerMinute = 1000; tokenQuota = $null; tokenQuotaPeriod = $null }
    $Parameters.backends = @(@{ id = 'synthetic-backend'; subscriptionId = '11111111-1111-4111-8111-111111111111'; resource = 'https://cognitiveservices.azure.com' })
    $Parameters.groups = @(@{
        groupId = $script:group; projectId = 'SYNTHETIC'; classification = 'STD'
        familyPolicy = @{ aggregateLimits = @{ person = $limit; group = $limit }
            families = @{ haiku = @{ models = @('claude-haiku-4-5'); person = $limit; group = $limit } } }
        personBudget = @{ amount = 100; currency = 'CCU'; period = 'monthly' }
        aggregateBudget = $null; aggregateMode = 'notify'; onboardingMode = 'warn'
    })
}

$ctx = @{
    GeneratedDir = $root
    P = @{ names = @{ subscriptionId = '11111111-1111-4111-8111-111111111111'; resourceGroup = 'synthetic' }
        workbook = @{ resourceName = '33333333-3333-4333-8333-333333333333' } }
    State = @{ completed = @{ '1' = @{ outputs = @{} }; '2' = @{ outputs = @{} } } }
}
Add-SyntheticRouting $ctx.P
function Invoke-QsAz { param([string[]]$Arguments) throw 'AZURE_CALL_FORBIDDEN' }
$refused = $false
try { Invoke-QsDeploy -Ctx $ctx | Out-Null } catch {
    $refused = $_.Exception.Message -match 'workbook_content_required' -and $_.Exception.Message -notmatch 'AZURE_CALL_FORBIDDEN'
}
Assert-True 'Only 3 without build artifact refuses before Azure or empty-shell overwrite' $refused
$bicep = Get-Content (Join-Path $root 'infra\quickstart\main.bicep') -Raw
Assert-True 'direct Bicep defaults to preserving existing workbook when content missing' ($bicep -notmatch 'module workbookShell')
Assert-True 'full serialized workbook is wired' ($bicep -match 'workbookContent: workbookContent')

$fixtureDir = Join-Path $root ".env.chargeback-quickstart-test-$PID"
New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
try {
    $sub = '11111111-1111-4111-8111-111111111111'
    $p = @{
        tenantId = '22222222-2222-4222-8222-222222222222'; location = 'eastus2'; logRetentionDays = 31
        names = @{ subscriptionId = $sub; resourceGroup = 'synthetic'; resourceGroupMode = 'existing'
            deploymentPrefix = 'synthetic'; logAnalyticsWorkspace = 'synthetic-law'
            apps = @{ reconciler = @{ functionApp = 'synthetic-reconciler' } } }
        workbook = @{ resourceName = '33333333-3333-4333-8333-333333333333'; displayName = 'Synthetic chargeback'
            settings = @{ defaultProjectId = '*'; maxRows = 500; topUsers = 20; maxQueryDays = 62; budgetLookbackDays = 31 } }
        rateCard = @{ path = '../../config/rate-card.json' }
    }
    Add-SyntheticRouting $p
    $apimId = "/subscriptions/$sub/resourceGroups/synthetic/providers/Microsoft.ApiManagement/service/synthetic-apim"
    $answers = New-QsWorkbookAnswers -P $p -ApimId $apimId -Directory $fixtureDir
    $groupsPath = Join-Path $fixtureDir 'synthetic.groups.json'
    $names | ConvertTo-Json -Depth 20 -AsArray | Set-Content -LiteralPath $groupsPath -Encoding utf8NoBOM
    $build = Invoke-QsWorkbookBuild -AnswersPath $answers -GroupsPath $groupsPath -Directory $fixtureDir
    $parameters = (Get-Content $build.parametersPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100).parameters
    Assert-True 'offline generator writes full query content, not shell' (@($parameters.workbookContent.value.items | Where-Object { $_.type -eq 3 }).Count -eq 10)
    Assert-True 'offline artifact retains fixed-price report marker' ($parameters.contentTags.value.'ccof-report' -ceq 'fixed-price-v1')
    $ctx = @{ P = $p; GeneratedDir = $fixtureDir; ParametersPath = 'unused-fixture.bicepparam'
        State = @{ completed = @{
            '1' = @{ outputs = @{ apimId = $apimId; apimIdentityAppId = '55555555-5555-4555-8555-555555555555' } }
            '2' = @{ outputs = @{ workbookParametersPath = $build.parametersPath } }
        } } }
    $script:azCalls = 0
    function Invoke-QsAz {
        param([string[]]$Arguments)
        $script:azCalls++
        if ($Arguments[0] -eq 'bicep') { return @{ parametersJson = '{"parameters":{}}' } }
        if ($Arguments[0] -eq 'deployment') {
            $file = $Arguments[([array]::IndexOf($Arguments, '--parameters') + 1)].Substring(1)
            $script:deployment = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            return @{ properties = @{ outputs = @{} } }
        }
        throw 'unexpected mock Azure operation'
    }
    Invoke-QsDeploy -Ctx $ctx | Out-Null
    Assert-True 'step3 forwards full workbook serializedData to Bicep' ($script:deployment.parameters.workbookContent.value.version -ceq 'Notebook/1.0')
    Assert-True 'step3 forwards content provenance tags' ($script:deployment.parameters.workbookContentTags.value.'ccof-content' -ceq $build.contentSha256)
    $before = $script:azCalls
    $parameters.workbookContent.value.items[0].content.json = 'tampered'
    @{ parameters = $parameters } | ConvertTo-Json -Depth 100 | Set-Content $build.parametersPath -Encoding utf8NoBOM
    $refused = $false
    try { Invoke-QsDeploy -Ctx $ctx | Out-Null } catch { $refused = $_.Exception.Message -match 'digest failed' }
    Assert-True 'tampered full workbook refuses before mock Azure deployment' ($refused -and $script:azCalls -eq $before)
} finally {
    Remove-Item -LiteralPath $fixtureDir -Recurse -Force
}
Write-Host "$pass chargeback quickstart checks passed"
