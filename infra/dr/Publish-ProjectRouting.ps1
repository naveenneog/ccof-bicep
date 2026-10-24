<#
.SYNOPSIS
  Routing publisher for per-project backend failover (ADR 0034, docs/design/DR-IMPLEMENTATION.md).

.DESCRIPTION
  Reads GET /api/v3/routing/pending from the admin app. For each project plan without problems and for
  every APIM instance in -ApimResourceId it:
    1. checks that the project's primary APIM backend exists with the registry URL,
    2. creates or updates one member backend per pool member (with the registry circuit breaker, if any),
    3. creates or updates the project's pool backend (primary priority 1, fallbacks in order),
    4. reads everything back and compares it with the plan.
  Only when every target verifies does it POST /api/v3/routing/{projectId}/publication, which makes the
  admin store failover.active; the sync then copies the pool ID into memberships.

  Without -Apply it prints the plan and the request bodies and changes nothing.
  Use a dedicated AZURE_CONFIG_DIR signed in to the APIM tenant; the admin token is requested for
  -AdminScope (the admin app's Projects.Manage scope; Azure CLI must be a pre-authorized client).

.EXAMPLE
  pwsh -NoProfile -File infra/dr/Publish-ProjectRouting.ps1 -AdminBaseUrl https://<admin>.azurewebsites.net `
    -AdminScope api://<admin-app-id>/Projects.Manage -ApimResourceId /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<apim> -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AdminBaseUrl,
    [Parameter(Mandatory)] [string]$AdminScope,
    [Parameter(Mandatory)] [string[]]$ApimResourceId,
    [string]$ProjectId,
    [string]$ApiVersion = '2024-05-01',
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ProjectRouting.psm1') -Force

if ($AdminBaseUrl -notmatch '^https://[A-Za-z0-9.-]+(:[0-9]+)?$' -and $AdminBaseUrl -notmatch '^http://127\.0\.0\.1:[0-9]+$') { throw 'AdminBaseUrl must be https://host (or http://127.0.0.1:port for the local demo).' }
if ($AdminScope -notmatch '^api://[A-Za-z0-9.-]+/Projects\.Manage$') { throw 'AdminScope must be api://<admin app>/Projects.Manage.' }
foreach ($id in $ApimResourceId) {
    if ($id -cnotmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]{1,90}/providers/Microsoft\.ApiManagement/service/[A-Za-z0-9-]{1,50}$') { throw "Not an APIM resource ID: $id" }
}

function Invoke-Az([string[]]$Arguments) {
    $errFile = New-TemporaryFile
    try { $out = & az @Arguments 2>$errFile; $code = $LASTEXITCODE; $err = Get-Content -LiteralPath $errFile -Raw } finally { Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue }
    if ($code -ne 0) { throw "az $($Arguments[0..1] -join ' ') failed: $err" }
    $out -join "`n"
}

function Get-Arm([string]$Path) {
    $errFile = New-TemporaryFile
    try { $out = & az rest --method get --url "https://management.azure.com$($Path)?api-version=$ApiVersion" --output json 2>$errFile; $code = $LASTEXITCODE; $err = Get-Content -LiteralPath $errFile -Raw } finally { Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue }
    if ($code -ne 0) { if ("$err" -match 'NotFound|ResourceNotFound|404') { return $null } throw "GET $Path failed: $err" }
    ($out -join "`n") | ConvertFrom-Json
}

function Set-Arm([string]$Path, $Body) {
    $file = New-TemporaryFile
    try {
        $Body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
        $null = Invoke-Az @('rest', '--method', 'put', '--url', "https://management.azure.com$($Path)?api-version=$ApiVersion", '--body', "@$file", '--headers', 'Content-Type=application/json', '--output', 'none')
    } finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
}

$token = Invoke-Az @('account', 'get-access-token', '--scope', $AdminScope, '--query', 'accessToken', '--output', 'tsv')
$headers = @{ authorization = "Bearer $($token.Trim())"; 'content-type' = 'application/json' }
$pending = Invoke-RestMethod -Uri "$AdminBaseUrl/api/v3/routing/pending" -Headers $headers -Method Get
$plans = @($pending.pending | Where-Object { -not $ProjectId -or $_.projectId -ceq $ProjectId })
Write-Host "pending plans: $($plans.Count)$(if ($ProjectId) { " (filtered to $ProjectId)" })"

$results = foreach ($plan in $plans) {
    $problems = @(Assert-RoutingPlan $plan)
    if ($problems.Count) { Write-Warning "$($plan.projectId) r$($plan.revision): skipped, $($problems -join ', ') $(@($plan.problems) -join ', ')"; [pscustomobject]@{ projectId = $plan.projectId; outcome = 'skipped'; detail = $problems -join ',' }; continue }
    Write-Host "$($plan.projectId) r$($plan.revision): pool $($plan.poolBackendId) = $((@($plan.members) | ForEach-Object { "$($_.priority):$($_.backendId)$(if ($_.circuitBreaker -and $_.circuitBreaker.enabled) { '[breaker]' })" }) -join ' > ')"
    if (-not $Apply) {
        foreach ($m in @($plan.members)) { Write-Host "  member $($m.memberBackendId): $((New-MemberBackendBody $m $plan.projectId) | ConvertTo-Json -Depth 20 -Compress)" }
        Write-Host "  pool: $((New-PoolBackendBody $plan $ApimResourceId[0]) | ConvertTo-Json -Depth 20 -Compress)"
        [pscustomobject]@{ projectId = $plan.projectId; outcome = 'preview'; detail = '' }; continue
    }
    $verified = @()
    $failed = $null
    foreach ($apim in $ApimResourceId) {
        $primary = Get-Arm "$apim/backends/$($plan.primaryBackendId)"
        if ($null -eq $primary) { $failed = "$apim primary backend $($plan.primaryBackendId) not found"; break }
        if ($primary.properties.url -cne $plan.members[0].url) { $failed = "$apim primary backend URL differs from the registry"; break }
        foreach ($m in @($plan.members)) { Set-Arm "$apim/backends/$($m.memberBackendId)" (New-MemberBackendBody $m $plan.projectId) }
        Set-Arm "$apim/backends/$($plan.poolBackendId)" (New-PoolBackendBody $plan $apim)
        $members = @{}
        foreach ($m in @($plan.members)) { $members[$m.memberBackendId] = Get-Arm "$apim/backends/$($m.memberBackendId)" }
        $pool = Get-Arm "$apim/backends/$($plan.poolBackendId)"
        $diff = @(if ($null -eq $pool) { @('pool:missing') } else { Compare-PublishedRouting $plan $apim $pool $members })
        if ($diff.Count) { $failed = "$apim read-back: $($diff -join ', ')"; break }
        $verified += $apim
        Write-Host "  verified in $($apim.Split('/')[-1])"
    }
    if ($failed) { Write-Warning "$($plan.projectId): not published, $failed"; [pscustomobject]@{ projectId = $plan.projectId; outcome = 'failed'; detail = $failed }; continue }
    $body = @{ revision = $plan.revision; poolBackendId = $plan.poolBackendId; verifiedTargets = $verified } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod -Uri "$AdminBaseUrl/api/v3/routing/$([uri]::EscapeDataString($plan.projectId))/publication" -Headers $headers -Method Post -Body $body
    Write-Host "  published: state $($r.state)"
    [pscustomobject]@{ projectId = $plan.projectId; outcome = 'published'; detail = $plan.poolBackendId }
}
$results | Format-Table -AutoSize | Out-String | Write-Host
if (@($results | Where-Object outcome -eq 'failed').Count) { exit 1 }
