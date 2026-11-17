#Requires -Version 7.0
<#
.SYNOPSIS
  Creates or verifies the Cosmos `backends` descriptor of Foundry backends (docs/runbooks/CICD-FOUNDRY-ONBOARDING.md).

.DESCRIPTION
  For each backend id the resolver reads one document from the `backends` container (partition key
  /backendId, id = backendId; src/resolver/backend.ts):
    { id, backendId, status: "active", apiFormat: "anthropic-messages",
      auth: { mode: "managed-identity", resource: <backends[].resource or https://cognitiveservices.azure.com> } }
  The URL is not in the document: it is the APIM backend entity that Stage 5 creates.

  Without -Apply the script reads only and reports present / would_create / mismatch. With -Apply it
  creates a missing document (POST, never replace) and reads it back. An existing document that
  differs (for example status "disabled" set by an administrator) is reported and never changed; the
  run fails so that a person decides.

  The caller needs Cosmos data-plane read + create on `backends` (Stage 3 grant for
  automation.backendWriterPrincipalIds, or the sync identity), runs inside the VNet (the account has
  public network access Disabled) and is signed in with the Azure CLI.

.EXAMPLE
  pwsh -File scripts/cicd/Set-CicdBackendDescriptor.ps1 -ConfigPath deploy/stg/staged.config.json -BackendIds foundry2
  pwsh -File scripts/cicd/Set-CicdBackendDescriptor.ps1 -ConfigPath deploy/stg/staged.config.json -BackendIds foundry2 -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ConfigPath,
    [Parameter(Mandatory)] [string[]]$BackendIds,
    [string]$StateDirectory,
    [switch]$Apply,
    [string]$EvidencePath,
    # Test seams, passed to Invoke-OnboardingCosmosRequest -GetToken / -Http.
    [scriptblock]$GetToken,
    [scriptblock]$Http
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repo 'scripts/Onboarding.Cosmos.psm1') -Force
function Stop-Descriptor([string]$Message) { [Console]::Error.WriteLine($Message); exit 3 }

function Get-CicdDescriptorExpected([Collections.IDictionary]$Backend) {
    $resource = if ($Backend.Contains('resource') -and $Backend['resource']) { [string]$Backend['resource'] } else { 'https://cognitiveservices.azure.com' }
    [ordered]@{ id = [string]$Backend['id']; backendId = [string]$Backend['id']; status = 'active'; apiFormat = 'anthropic-messages'
        auth = [ordered]@{ mode = 'managed-identity'; resource = $resource } }
}

# Fields that differ between the document and the expected descriptor (extra fields are allowed).
function Get-CicdDescriptorDifferences($Doc, [Collections.IDictionary]$Expected) {
    if ($Doc -isnot [Collections.IDictionary]) { return 'document' }
    foreach ($k in 'id', 'backendId', 'status', 'apiFormat') { if (-not $Doc.Contains($k) -or "$($Doc[$k])" -cne $Expected[$k]) { $k } }
    $auth = if ($Doc.Contains('auth')) { $Doc['auth'] } else { $null }
    if ($auth -isnot [Collections.IDictionary] -or "$($auth['mode'])" -cne $Expected.auth.mode) { 'auth.mode' }
    elseif ("$($auth['resource'])" -cne $Expected.auth.resource) { 'auth.resource' }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { Stop-Descriptor "descriptor_config_missing: $ConfigPath" }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
if (-not $StateDirectory) { $StateDirectory = Join-Path (Split-Path (Resolve-Path -LiteralPath $ConfigPath).Path -Parent) '.staged-state' }
$statePath = Join-Path $StateDirectory 'state.json'
if (-not (Test-Path -LiteralPath $statePath)) { Stop-Descriptor "descriptor_state_missing: $statePath (the primary staged state; restore it before running)." }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$s1 = if ($state['stages'] -is [Collections.IDictionary] -and $state['stages'].Contains('1')) { $state['stages']['1'] } else { $null }
if (-not $s1) { Stop-Descriptor 'descriptor_state_missing: Stage 1 has not completed.' }
# Stage 1 records the account's documentEndpoint (https://<account>.documents.azure.com:443/); the
# registry schema of Invoke-OnboardingCosmosRequest takes it without the default port.
$uri = $null
$endpoint = [string]$s1['outputs']['cosmosEndpoint']
if (-not [uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.AbsolutePath -ne '/' -or $uri.Host -notmatch '^[a-z0-9-]+\.documents\.azure\.com$') {
    Stop-Descriptor "descriptor_registry_invalid: Stage 1 cosmosEndpoint '$endpoint' is not an https Cosmos endpoint."
}
$database = 'ccof'
if ($cfg['cosmos'] -is [Collections.IDictionary] -and $cfg['cosmos']['databaseName']) { $database = [string]$cfg['cosmos']['databaseName'] }
$registry = @{ accountResourceId = [string]$s1['outputs']['cosmosAccountId']; endpoint = "https://$($uri.Host)/"; database = $database }

$ids = @($BackendIds | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $ids.Count) { Stop-Descriptor 'descriptor_ids_required: name at least one backend id.' }
$backends = @($cfg['backends'])
$send = @{ Registry = $registry }
if ($GetToken) { $send.GetToken = $GetToken }
if ($Http) { $send.Http = $Http }
$results = [Collections.Generic.List[object]]::new()
try {
foreach ($id in $ids) {
    $backend = @($backends | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_['id'] -ceq $id })
    if ($backend.Count -ne 1) { Stop-Descriptor "descriptor_backend_unknown: '$id' is not exactly one entry in backends[] of $ConfigPath." }
    $expected = Get-CicdDescriptorExpected $backend[0]
    $r = Invoke-OnboardingCosmosRequest @send -Method 'GET' -Container 'backends' -Id $id -Partition $id
    $diff = @()
    if ($r.status -eq 200) {
        $diff = @(Get-CicdDescriptorDifferences $r.body $expected)
        $outcome = if ($diff.Count) { 'mismatch' } else { 'present' }
    } elseif ($r.status -eq 404) {
        $outcome = 'would_create'
        if ($Apply) {
            # 409: created meanwhile by someone else; the read-back decides whether it is the same.
            $c = Invoke-OnboardingCosmosRequest @send -Method 'POST' -Container 'backends' -Partition $id -Body $expected
            if ($c.status -notin 201, 409) { Stop-Descriptor "descriptor_create_failed: HTTP $($c.status) for '$id'." }
            $back = Invoke-OnboardingCosmosRequest @send -Method 'GET' -Container 'backends' -Id $id -Partition $id
            if ($back.status -ne 200) { Stop-Descriptor "descriptor_readback_failed: HTTP $($back.status) for '$id' after create." }
            $diff = @(Get-CicdDescriptorDifferences $back.body $expected)
            $outcome = if ($diff.Count) { 'mismatch' } elseif ($c.status -eq 201) { 'created' } else { 'present' }
        }
    } else { Stop-Descriptor "descriptor_read_failed: HTTP $($r.status) for '$id'." }
    $results.Add([ordered]@{ backendId = $id; outcome = $outcome; differences = $diff; expected = $expected })
    Write-Host "descriptor ${id}: $outcome$(if ($diff.Count) { " ($($diff -join ', ') differ)" })"
}
} catch { Stop-Descriptor "descriptor_failed: $($_.Exception.Message) (nothing further was written)." }
if ($EvidencePath) {
    $report = [ordered]@{ checkedAt = [DateTime]::UtcNow.ToString('o'); mode = $(if ($Apply) { 'apply' } else { 'preview' }); registry = $registry; results = $results }
    New-Item -ItemType Directory -Force -Path (Split-Path $EvidencePath -Parent) | Out-Null
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $EvidencePath -Encoding utf8NoBOM
}
$bad = @($results | Where-Object { $_.outcome -ceq 'mismatch' } | ForEach-Object { $_.backendId })
if ($bad.Count) { Stop-Descriptor "descriptor_mismatch: $($bad -join ', ') already has a different descriptor. Nothing was overwritten; review it with the registry owner (admin console or Cosmos Data Explorer)." }
exit 0
