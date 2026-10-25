# Pure functions for the routing publisher (ADR 0034, infra/dr/Publish-ProjectRouting.ps1).
# They shape APIM backend resources from one routing plan (GET /api/v3/routing/pending) and compare a
# read-back with that plan. No Azure call happens here, so tests/Test-ProjectRouting.ps1 runs offline.
#
# APIM resources (API 2024-05-01, https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/backends):
#   member: properties.url, protocol http, optional properties.circuitBreaker.rules[1]
#   pool:   properties.type Pool, properties.pool.services[{ id, priority, weight }]

Set-StrictMode -Version Latest

$script:PoolId = '^ccof-pool-[a-z0-9-]{1,50}-r[0-9]{1,9}$'
$script:MemberId = '^ccof-m-[a-z0-9-]{1,50}-r[0-9]{1,9}-[0-9]$'
$script:ApimId = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]{1,90}/providers/Microsoft\.ApiManagement/service/[A-Za-z0-9-]{1,50}$'
# Gateway LastErrorReason values for a backend that gave no response; APIM accepted them in failureCondition.errorReasons
# and the breaker then opened on an unreachable primary (lab drill 2026-10-25, docs/DR-NOVICE-WALKTHROUGH-2026-10-25.md).
$script:NoResponseErrorReasons = @('BackendConnectionFailure', 'Timeout')

function ConvertTo-IsoSeconds([int]$Seconds) { "PT$($Seconds)S" }

function Assert-RoutingPlan {
    param([Parameter(Mandatory)] $Plan)
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($Plan.poolBackendId -cnotmatch $script:PoolId) { $problems.Add('poolBackendId:invalid') }
    if (@($Plan.problems).Count -gt 0) { $problems.Add('plan:has_problems') }
    $members = @($Plan.members)
    if ($members.Count -lt 2) { $problems.Add('members:fewer_than_two') }
    foreach ($m in $members) {
        if ($m.memberBackendId -cnotmatch $script:MemberId) { $problems.Add("member:$($m.backendId):id_invalid") }
        if ($m.url -cnotmatch '^https://[a-z0-9][a-z0-9-]{1,62}\.(services\.ai\.azure\.com|cognitiveservices\.azure\.com|openai\.azure\.com)/anthropic$') { $problems.Add("member:$($m.backendId):url_invalid") }
    }
    if ($members.Count -gt 0 -and $members[0].backendId -cne $Plan.primaryBackendId) { $problems.Add('members:primary_not_first') }
    $problems.ToArray()
}

function New-MemberBackendBody {
    param([Parameter(Mandatory)] $Member, [Parameter(Mandatory)] [string]$ProjectId)
    $props = [ordered]@{
        description = "CCOF ${ProjectId} pool member $($Member.priority): $($Member.backendId) (ADR 0034)"
        url         = $Member.url
        protocol    = 'http'
    }
    $b = $Member.circuitBreaker
    if ($null -ne $b -and $b.enabled) {
        $props.circuitBreaker = [ordered]@{
            rules = @([ordered]@{
                    name             = 'ccof-breaker'
                    failureCondition = [ordered]@{
                        count            = [int]$b.failureCount
                        interval         = ConvertTo-IsoSeconds $b.failureIntervalSeconds
                        statusCodeRanges = @($b.statusCodeRanges | ForEach-Object { [ordered]@{ min = [int]$_.min; max = [int]$_.max } })
                        # A primary that does not answer has no status code; without these a regional outage never opens the breaker.
                        errorReasons     = $script:NoResponseErrorReasons
                    }
                    tripDuration     = ConvertTo-IsoSeconds $b.tripDurationSeconds
                    acceptRetryAfter = [bool]$b.acceptRetryAfter
                })
        }
    }
    [ordered]@{ properties = $props }
}

function New-PoolBackendBody {
    param([Parameter(Mandatory)] $Plan, [Parameter(Mandatory)] [string]$ApimId)
    if ($ApimId -cnotmatch $script:ApimId) { throw "ApimId is not an API Management resource ID: $ApimId" }
    [ordered]@{
        properties = [ordered]@{
            description = "CCOF $($Plan.projectId) failover pool, revision $($Plan.revision) (ADR 0034)"
            type        = 'Pool'
            pool        = [ordered]@{
                services = @(@($Plan.members) | ForEach-Object {
                        [ordered]@{ id = "$ApimId/backends/$($_.memberBackendId)"; priority = [int]$_.priority; weight = [int]$_.weight }
                    })
            }
        }
    }
}

# Differences between what APIM returned and what the plan needs; empty means verified.
function Compare-PublishedRouting {
    param([Parameter(Mandatory)] $Plan, [Parameter(Mandatory)] [string]$ApimId, [Parameter(Mandatory)] $Pool, [Parameter(Mandatory)] [hashtable]$Members)
    $diff = [System.Collections.Generic.List[string]]::new()
    if ($Pool.properties.type -cne 'Pool') { $diff.Add('pool:type') }
    $want = @(@($Plan.members) | ForEach-Object { "$ApimId/backends/$($_.memberBackendId)|$($_.priority)|$($_.weight)".ToLowerInvariant() })
    $got = @(@($Pool.properties.pool.services) | ForEach-Object { "$($_.id)|$($_.priority)|$($_.weight)".ToLowerInvariant() })
    if ((($want | Sort-Object) -join ';') -ne (($got | Sort-Object) -join ';')) { $diff.Add('pool:services') }
    foreach ($m in @($Plan.members)) {
        $r = $Members[$m.memberBackendId]
        if ($null -eq $r) { $diff.Add("member:$($m.memberBackendId):missing"); continue }
        if ($r.properties.url -cne $m.url) { $diff.Add("member:$($m.memberBackendId):url") }
        $wantBreaker = $null -ne $m.circuitBreaker -and $m.circuitBreaker.enabled
        $rules = @(if ($r.properties.PSObject.Properties['circuitBreaker'] -and $r.properties.circuitBreaker) { $r.properties.circuitBreaker.rules })
        if ($wantBreaker -and $rules.Count -ne 1) { $diff.Add("member:$($m.memberBackendId):breaker_missing") }
        if (-not $wantBreaker -and $rules.Count -ne 0) { $diff.Add("member:$($m.memberBackendId):breaker_unexpected") }
        if ($wantBreaker -and $rules.Count -eq 1 -and [int]$rules[0].failureCondition.count -ne [int]$m.circuitBreaker.failureCount) { $diff.Add("member:$($m.memberBackendId):breaker_count") }
        if ($wantBreaker -and $rules.Count -eq 1) {
            $reasons = @(if ($rules[0].failureCondition.PSObject.Properties['errorReasons']) { $rules[0].failureCondition.errorReasons })
            if ((($reasons | Sort-Object) -join ',') -cne (($script:NoResponseErrorReasons | Sort-Object) -join ',')) { $diff.Add("member:$($m.memberBackendId):breaker_error_reasons") }
        }
    }
    $diff.ToArray()
}

Export-ModuleMember -Function Assert-RoutingPlan, New-MemberBackendBody, New-PoolBackendBody, Compare-PublishedRouting, ConvertTo-IsoSeconds
