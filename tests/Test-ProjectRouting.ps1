# Offline contract tests for the routing publisher (infra/dr/ProjectRouting.psm1, ADR 0034).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\infra\dr\ProjectRouting.psm1') -Force
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }

$apim = '/subscriptions/00000000-0000-4000-8000-00000000dd02/resourceGroups/rg-lab-shared/providers/Microsoft.ApiManagement/service/apim-a'
$breaker = [pscustomobject]@{ enabled = $true; failureCount = 3; failureIntervalSeconds = 60; tripDurationSeconds = 30; statusCodeRanges = @([pscustomobject]@{ min = 500; max = 599 }); acceptRetryAfter = $true }
function New-Plan { [pscustomobject]@{ projectId = 'SASLAB1'; revision = 2; poolBackendId = 'ccof-pool-saslab1-1a2b3c4d-r2'; primaryBackendId = 'foundry-a'; problems = @()
    members = @(
        [pscustomobject]@{ backendId = 'foundry-a'; memberBackendId = 'ccof-m-saslab1-1a2b3c4d-r2-0'; url = 'https://acct-a.services.ai.azure.com/anthropic'; priority = 1; weight = 1; circuitBreaker = $breaker },
        [pscustomobject]@{ backendId = 'foundry-b'; memberBackendId = 'ccof-m-saslab1-1a2b3c4d-r2-1'; url = 'https://acct-b.services.ai.azure.com/anthropic'; priority = 2; weight = 1; circuitBreaker = $null }) } }

$plan = New-Plan
Check 'valid plan has no problems' (@(Assert-RoutingPlan $plan).Count -eq 0)
$bad = New-Plan; $bad.poolBackendId = 'foundry-a'; Check 'non-pool id refused' (@(Assert-RoutingPlan $bad) -contains 'poolBackendId:invalid')
$bad = New-Plan; $bad.problems = @('primary:circuit_breaker_required'); Check 'plan problems block' (@(Assert-RoutingPlan $bad) -contains 'plan:has_problems')
$bad = New-Plan; $bad.members = @($bad.members[1], $bad.members[0]); Check 'primary must be first' (@(Assert-RoutingPlan $bad) -contains 'members:primary_not_first')
$bad = New-Plan; $bad.members[1].url = 'https://evil.example.com/anthropic'; Check 'non-Foundry url refused' (@(Assert-RoutingPlan $bad) -contains 'member:foundry-b:url_invalid')
$bad = New-Plan; $bad.members = @($bad.members[0]); Check 'single member refused' (@(Assert-RoutingPlan $bad) -contains 'members:fewer_than_two')

$m0 = New-MemberBackendBody $plan.members[0] 'SASLAB1'
$rule = $m0.properties.circuitBreaker.rules[0]
Check 'breaker count' ($rule.failureCondition.count -eq 3)
Check 'breaker interval ISO' ($rule.failureCondition.interval -eq 'PT60S')
Check 'breaker trip ISO' ($rule.tripDuration -eq 'PT30S')
Check 'breaker ranges' ($rule.failureCondition.statusCodeRanges[0].min -eq 500 -and $rule.failureCondition.statusCodeRanges[0].max -eq 599)
# A primary that does not answer (region or network outage) has no status code; only errorReasons count it (drill 2026-10-25).
Check 'breaker counts no-response failures' ((@($rule.failureCondition.errorReasons) -join ',') -ceq 'BackendConnectionFailure,Timeout')
Check 'member url' ($m0.properties.url -ceq 'https://acct-a.services.ai.azure.com/anthropic')
$m1 = New-MemberBackendBody $plan.members[1] 'SASLAB1'
Check 'no breaker when registry has none' (-not $m1.properties.Contains('circuitBreaker'))
$off = New-Plan; $off.members[0].circuitBreaker = [pscustomobject]@{ enabled = $false; failureCount = 3; failureIntervalSeconds = 60; tripDurationSeconds = 30; statusCodeRanges = @(); acceptRetryAfter = $false }
Check 'disabled breaker is not published' (-not (New-MemberBackendBody $off.members[0] 'SASLAB1').properties.Contains('circuitBreaker'))

$pool = New-PoolBackendBody $plan $apim
Check 'pool type' ($pool.properties.type -ceq 'Pool')
Check 'pool services ordered by priority' (($pool.properties.pool.services | ForEach-Object { "$($_.priority)" }) -join ',' -eq '1,2')
Check 'pool member ids are full ARM ids' ($pool.properties.pool.services[0].id -ceq "$apim/backends/ccof-m-saslab1-1a2b3c4d-r2-0")
$threw = $false; try { New-PoolBackendBody $plan '/subscriptions/x/resourceGroups/rg(1)/providers/Microsoft.ApiManagement/service/a' | Out-Null } catch { $threw = $true }
Check 'APIM id with cmd metacharacters refused' $threw

# read-back comparison: round-trip JSON as APIM would return it
$json = { param($o) $o | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
$members = @{ 'ccof-m-saslab1-1a2b3c4d-r2-0' = (& $json $m0); 'ccof-m-saslab1-1a2b3c4d-r2-1' = (& $json $m1) }
Check 'faithful read-back verifies' (@(Compare-PublishedRouting $plan $apim (& $json $pool) $members).Count -eq 0)
$p2 = & $json $pool; $p2.properties.pool.services[1].priority = 1
Check 'changed priority detected' (@(Compare-PublishedRouting $plan $apim $p2 $members) -contains 'pool:services')
$mm = $members.Clone(); $mm.Remove('ccof-m-saslab1-1a2b3c4d-r2-1')
Check 'missing member detected' (@(Compare-PublishedRouting $plan $apim (& $json $pool) $mm) -contains 'member:ccof-m-saslab1-1a2b3c4d-r2-1:missing')
$mm = $members.Clone(); $mm['ccof-m-saslab1-1a2b3c4d-r2-0'] = & $json $m1
Check 'primary without breaker detected' (@(Compare-PublishedRouting $plan $apim (& $json $pool) $mm) -contains 'member:ccof-m-saslab1-1a2b3c4d-r2-0:breaker_missing')
$mm = $members.Clone(); $old = & $json $m0; $old.properties.circuitBreaker.rules[0].failureCondition.PSObject.Properties.Remove('errorReasons'); $mm['ccof-m-saslab1-1a2b3c4d-r2-0'] = $old
Check 'breaker without error reasons detected' (@(Compare-PublishedRouting $plan $apim (& $json $pool) $mm) -contains 'member:ccof-m-saslab1-1a2b3c4d-r2-0:breaker_error_reasons')
$mm = $members.Clone(); $mm['ccof-m-saslab1-1a2b3c4d-r2-1'] = & $json $m0
$got = @(Compare-PublishedRouting $plan $apim (& $json $pool) $mm) -join ','; Check 'unexpected breaker and url detected' ($got -match 'r2-1:url.*r2-1:breaker_unexpected')

# The publisher script refuses bad inputs before any az call.
$script = Join-Path $PSScriptRoot '..\infra\dr\Publish-ProjectRouting.ps1'
$out = & pwsh -NoProfile -File $script -AdminBaseUrl 'https://admin.example' -AdminScope 'api://x/Projects.Manage' -ApimResourceId '/subscriptions/x/resourceGroups/a&b/providers/Microsoft.ApiManagement/service/a' 2>&1
Check 'script refuses an APIM id with &' ($LASTEXITCODE -ne 0 -and "$out" -match 'Not an APIM resource ID')
$out = & pwsh -NoProfile -File $script -AdminBaseUrl 'https://admin.example' -AdminScope 'https://graph.microsoft.com/.default' -ApimResourceId $apim 2>&1
Check 'script refuses a non-admin scope' ($LASTEXITCODE -ne 0 -and "$out" -match 'AdminScope')

Write-Host "Test-ProjectRouting: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0 -or $script:pass -lt 26) { exit 1 }
