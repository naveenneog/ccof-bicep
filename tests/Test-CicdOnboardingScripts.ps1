#Requires -Version 7.0
# Offline tests for the pipeline onboarding scripts (docs/runbooks/CICD-FOUNDRY-ONBOARDING.md, ADR 0040):
# scripts/cicd/Test-CicdBackendOnboarding.ps1 (validate), Set-CicdBackendDescriptor.ps1 (Cosmos
# descriptor) and Test-CicdBackendSmoke.ps1, with Azure and Cosmos replaced by fakes. No Azure call.
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$root = Split-Path $PSScriptRoot -Parent
$cicd = Join-Path $root 'scripts\cicd'
Import-Module (Join-Path $cicd 'CicdOnboarding.psm1') -Force
$scratch = Join-Path $root ".env.cicd-onboarding-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
# Scripts report refusals on [Console]::Error; keep the test output to the check lines.
function Invoke-Quiet([scriptblock]$Body) { $keep = [Console]::Error; [Console]::SetError([IO.TextWriter]::Null); try { & $Body } finally { [Console]::SetError($keep) } }
function Save-Json([string]$Path, $Value) { New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null; $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM }
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 }
function Copy-Deep($Value) { $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 }

$sub = '00000000-0000-4000-8000-000000000002'; $fsub = '00000000-0000-4000-8000-000000000009'
$apimA = "/subscriptions/$sub/resourceGroups/rg-new/providers/Microsoft.ApiManagement/service/apim-a"
$apimB = "/subscriptions/$sub/resourceGroups/rg-new/providers/Microsoft.ApiManagement/service/apim-b"
$pA = '00000000-0000-4000-8000-0000000000a1'; $pB = '00000000-0000-4000-8000-0000000000b1'; $applyId = '00000000-0000-4000-8000-0000000000c1'
function New-Backend([string]$Id, [string]$Account) {
    [ordered]@{ id = $Id; subscriptionId = $fsub; resourceGroup = 'foundry-rg'; accountName = $Account; url = "https://$Account.services.ai.azure.com/anthropic"
        resource = 'https://cognitiveservices.azure.com'; deploymentInferenceGeo = [ordered]@{ 'claude-haiku-4-5' = 'global' }; assignCognitiveServicesUser = $true; privateEndpoint = $false }
}
$base = Read-Json (Join-Path $root 'infra\staged\staged.config.example.json')
$base.tenantId = '00000000-0000-4000-8000-000000000001'; $base.subscriptionId = $sub; $base.resourceGroup = 'rg-new'
$vnet = "/subscriptions/$sub/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets"
$base.network.existing = @{ functionsSubnetId = "$vnet/functions"; privateEndpointSubnetId = "$vnet/private"; apimSubnetId = "$vnet/apim" }
$base.backends = @(New-Backend 'be1' 'acct1')
foreach ($g in $base.groups) { $g.backendId = 'be1' }
foreach ($k in @($base.client.models.Keys)) { $base.client.models[$k] = 'claude-haiku-4-5' }
$head = Copy-Deep $base; $head.backends += @(New-Backend 'be2' 'acct2')
$env1 = Join-Path $scratch 'deploy\lab'
$basePath = Join-Path $scratch 'base.json'; $cfgPath = Join-Path $env1 'staged.config.json'
Save-Json $basePath $base; Save-Json $cfgPath $head
Save-Json (Join-Path $env1 '.staged-state\state.json') @{ stages = @{
    '1' = @{ outputs = @{ apimId = $apimA; apimPrincipalId = $pA; cosmosEndpoint = 'https://cosmos1.documents.azure.com:443/'; cosmosAccountId = "/subscriptions/$sub/resourceGroups/rg-new/providers/Microsoft.DocumentDB/databaseAccounts/cosmos1" } }
    '3' = @{ outputs = @{ apimPrincipalId = $pA } } } }
Save-Json (Join-Path $env1 'dr-standby.config.json') @{ standby = @{ stagedConfigPath = 'staged.config.json'; stagedStateDirectory = '.staged-state'; stateDirectory = '.dr-state' } }
$standby = @{ schema = 'ccof.dr.standby.v1'; phases = @{ Shells = @{ outputs = @{ apimId = $apimB; apimPrincipalId = $pB } }; Grants = @{ outputs = @{} }; Config = @{ outputs = @{} }; Code = @{ outputs = @{} } } }
Save-Json (Join-Path $env1 '.dr-state\standby.state.json') $standby

# --- fake ARM ---------------------------------------------------------------------------------------
$acct2 = "/subscriptions/$fsub/resourceGroups/foundry-rg/providers/Microsoft.CognitiveServices/accounts/acct2"
function Reset-Arm {
    $global:CicdArm = @{
        "$acct2`?api-version=2024-10-01" = @{ kind = 'AIServices'; location = 'eastus2'; properties = @{ provisioningState = 'Succeeded'; publicNetworkAccess = 'Disabled'; customSubDomainName = 'acct2'
            privateEndpointConnections = @(@{ properties = @{ privateEndpoint = @{ id = '/pe/1' }; privateLinkServiceConnectionState = @{ status = 'Approved' } } }) } }
        "$acct2/deployments?api-version=2024-10-01" = @{ value = @(@{ name = 'claude-haiku-4-5'; properties = @{ provisioningState = 'Succeeded'; model = @{ format = 'Anthropic'; name = 'claude-haiku-4-5'; version = '1' } } }) }
        "$acct2/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" = @{ value = @(
            @{ properties = @{ principalId = $pA; roleDefinitionId = '/x/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908' } }
            @{ properties = @{ principalId = $pB; roleDefinitionId = '/x/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908' } }) }
    }
    foreach ($apim in $apimA, $apimB) {
        $global:CicdArm["$apim/backends/be2?api-version=2024-05-01"] = @{ properties = @{ url = 'https://acct2.services.ai.azure.com/anthropic' } }
        $global:CicdArm["$apim/apis/claude-messages/policies/policy?api-version=2024-05-01"] = @{ properties = @{ value = '<x value="@(new string[] { "be1", "be2" })" />' } }
    }
}
$arm = { param($p) if (-not $global:CicdArm.ContainsKey($p)) { throw "404 $p" }; $global:CicdArm[$p] }
$resolvePrivate = { param($h) @('100.80.22.9') }
$ev = Join-Path $scratch 'validate.json'
function Invoke-Validate([hashtable]$Extra) {
    Remove-Item -LiteralPath $ev -ErrorAction SilentlyContinue
    $p = @{ ConfigPath = $cfgPath; BaseConfigPath = $basePath; Arm = $arm; ApplyPrincipalId = $applyId; EvidencePath = $ev }
    foreach ($k in $Extra.Keys) { if ($null -eq $Extra[$k]) { $p.Remove($k) } else { $p[$k] = $Extra[$k] } }
    $code = Invoke-Quiet { $null = & (Join-Path $cicd 'Test-CicdBackendOnboarding.ps1') @p 6>$null 2>$null 3>$null; $LASTEXITCODE }
    @{ code = $code; report = $(if (Test-Path -LiteralPath $ev) { Read-Json $ev } else { @{ problems = @() } }) }
}
function Problems($r) { @($r.report.problems) -join ' | ' }

try {
# --- validate: change detection ---------------------------------------------------------------------
Reset-Arm
$r = Invoke-Validate @{}
Check 'validate: an appended backend with complete Azure prerequisites passes' ($r.code -eq 0 -and (@($r.report.backendIds) -join ',') -ceq 'be2')
Check 'validate: region B coverage is reported' ($r.report.regionB.hasStandby -eq $true)
Check 'validate: an approved private endpoint needs no gate' ($r.report.needsPrivateLinkGate -eq $false)
$out = Join-Path $scratch 'gh-output.txt'; Remove-Item $out -ErrorAction SilentlyContinue; $env:GITHUB_OUTPUT = $out
$null = Invoke-Validate @{}; $env:GITHUB_OUTPUT = $null
Check 'validate: GitHub outputs name the ids, the gate and region B' ((Get-Content $out -Raw) -match 'backend-ids=be2' -and (Get-Content $out -Raw) -match 'needs-privatelink-gate=false' -and (Get-Content $out -Raw) -match 'has-standby=true')

$changed = Copy-Deep $head; $changed.backends[0].url = 'https://other.services.ai.azure.com/anthropic'; $changedPath = Join-Path $scratch 'changed.json'; Save-Json $changedPath $changed
$x = Get-CicdBackendChange -Base $base -Head $changed
Check 'change: a changed existing backend is refused' ((@($x.problems) -join ';') -match 'backend_changed: be1')
$x = Get-CicdBackendChange -Base $base -Head (Copy-Deep $base)
Check 'change: no added backend is refused' ((@($x.problems) -join ';') -match 'no_backend_added')
$removed = Copy-Deep $head; $removed.backends = @($removed.backends[1])
Check 'change: a removed backend is refused' ((@((Get-CicdBackendChange -Base $base -Head $removed).problems) -join ';') -match 'backend_removed: be1')
$other = Copy-Deep $head; $other.sync.schedule = '0 */5 * * * *'
Check 'change: another configuration change is refused' ((@((Get-CicdBackendChange -Base $base -Head $other).problems) -join ';') -match 'config_changed: sync')
$two = Copy-Deep $base; $two.backends += @(New-Backend 'be0' 'acct0'); $reorder = Copy-Deep $two; $reorder.backends = @($reorder.backends[1], $reorder.backends[0], (New-Backend 'be2' 'acct2'))
Check 'change: reordering existing backends is refused' ((@((Get-CicdBackendChange -Base $two -Head $reorder).problems) -join ';') -match 'backends_reordered')
Check 'change: key order inside a backend is not a change' (@((Get-CicdBackendChange -Base $base -Head (Read-Json $cfgPath)).problems).Count -eq 0)
$r = Invoke-Validate @{ BaseConfigPath = $null; BackendIds = @('be2') }
Check 'validate: dispatch mode with -BackendIds passes' ($r.code -eq 0)
$r = Invoke-Validate @{ BackendIds = @('be1') }
Check 'validate: -BackendIds that differ from the change are refused' ($r.code -eq 3 -and (Problems $r) -match 'backend_ids_mismatch')

# --- validate: fields ---------------------------------------------------------------------------------
foreach ($bad in @(
    @{ n = 'url of another account'; k = 'url'; v = 'https://acct9.services.ai.azure.com/anthropic'; m = 'url must be' }
    @{ n = 'subscription not a GUID'; k = 'subscriptionId'; v = 'sub'; m = 'subscriptionId must be a GUID' }
    @{ n = 'no deployments'; k = 'deploymentInferenceGeo'; v = @{}; m = 'deploymentInferenceGeo' }
    @{ n = 'role assignment off'; k = 'assignCognitiveServicesUser'; v = $false; m = 'assignCognitiveServicesUser false' }
    @{ n = 'id with an underscore'; k = 'id'; v = 'be_2'; m = 'letters, digits and hyphens' })) {
    $b = New-Backend 'be2' 'acct2'; $b[$bad.k] = $bad.v
    Check "fields: $($bad.n) is refused" ((@(Get-CicdBackendFieldProblems $b) -join ';') -match $bad.m)
}
Check 'fields: a complete backend has no problem' (@(Get-CicdBackendFieldProblems (New-Backend 'be2' 'acct2')).Count -eq 0)

# --- validate: Azure findings ------------------------------------------------------------------------
Reset-Arm; $global:CicdArm.Remove("$acct2`?api-version=2024-10-01")
$r = Invoke-Validate @{}
Check 'azure: an unreadable account fails closed' ($r.code -eq 3 -and (Problems $r) -match 'foundry_unreachable')
Reset-Arm; $global:CicdArm["$acct2`?api-version=2024-10-01"].kind = 'OpenAI'
Check 'azure: a non-AIServices account is refused' ((Problems (Invoke-Validate @{})) -match 'foundry_kind')
Reset-Arm; $global:CicdArm["$acct2/deployments?api-version=2024-10-01"].value = @()
$r = Invoke-Validate @{}
Check 'azure: a missing model deployment is refused' ($r.code -eq 3 -and (Problems $r) -match 'foundry_deployment_missing: be2 has no deployment named claude-haiku-4-5')
Reset-Arm; $global:CicdArm["$acct2/deployments?api-version=2024-10-01"].value[0].properties.provisioningState = 'Creating'
Check 'azure: a deployment that has not succeeded is refused' ((Problems (Invoke-Validate @{})) -match 'foundry_deployment_state')
Reset-Arm; $global:CicdArm["$acct2`?api-version=2024-10-01"].properties.privateEndpointConnections[0].properties.privateLinkServiceConnectionState.status = 'Pending'
$r = Invoke-Validate @{}
Check 'azure: a pending private endpoint asks for the privatelink gate and still validates' ($r.code -eq 0 -and $r.report.needsPrivateLinkGate -eq $true)
$r = Invoke-Validate @{ RequirePrivateLink = $true }
Check 'azure: -RequirePrivateLink fails while the endpoint is pending' ($r.code -eq 3 -and (Problems $r) -match 'private_link_pending')
Reset-Arm
$r = Invoke-Validate @{ Resolve = { param($h) @('20.1.2.3') } }
Check 'azure: a public DNS answer from the runner asks for the gate' ($r.report.needsPrivateLinkGate -eq $true)
$r = Invoke-Validate @{ Resolve = $resolvePrivate; RequirePrivateLink = $true }
Check 'azure: approved endpoint and private DNS answer pass -RequirePrivateLink' ($r.code -eq 0 -and $r.report.backends[0].dns.private -eq $true)
Check 'private address: RFC 1918 and 100.64/10 are private, others not' ((Test-CicdPrivateAddress '10.1.2.3') -and (Test-CicdPrivateAddress '172.31.0.1') -and (Test-CicdPrivateAddress '192.168.1.1') -and (Test-CicdPrivateAddress '100.127.0.1') -and -not (Test-CicdPrivateAddress '100.128.0.1') -and -not (Test-CicdPrivateAddress '172.32.0.1') -and -not (Test-CicdPrivateAddress 'x'))
Reset-Arm; $global:CicdArm["$acct2/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"].value = @()
$r = Invoke-Validate @{}
Check 'azure: APIM principals without the role and an apply identity that cannot assign it are refused' ($r.code -eq 3 -and (Problems $r) -match "foundry_role_prerequisite.*$pA, $pB")
$global:CicdArm["$acct2/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"].value = @(@{ properties = @{ principalId = $applyId; roleDefinitionId = '/x/roleDefinitions/f58310d9-a9f6-439a-9e8d-f62e7b41a168' } })
Check 'azure: an apply identity with RBAC Administrator on the account passes' ((Invoke-Validate @{}).code -eq 0)
Reset-Arm; $r = Invoke-Validate @{ SkipAzure = $true; Arm = { throw 'called' } }
Check 'validate: -SkipAzure makes no Azure read' ($r.code -eq 0 -and (@($r.report.warnings) -join ';') -match 'azure_skipped')

# --- validate: region B -------------------------------------------------------------------------------
$sbPath = Join-Path $env1 '.dr-state\standby.state.json'
$partial = Copy-Deep $standby; $partial.phases.Remove('Code'); Save-Json $sbPath $partial
Check 'region B: an unfinished standby is refused' ((Problems (Invoke-Validate @{})) -match 'standby_incomplete: region B has not completed Code')
Save-Json $sbPath $standby
$drPath = Join-Path $env1 'dr-standby.config.json'; $drKeep = Get-Content $drPath -Raw
Save-Json $drPath @{ standby = @{ stagedConfigPath = '../other/staged.config.json'; stagedStateDirectory = '.staged-state'; stateDirectory = '.dr-state' } }
Check 'region B: a DR configuration built from another staged configuration is refused' ((Problems (Invoke-Validate @{})) -match 'standby_config_mismatch')
Remove-Item $drPath
$r = Invoke-Validate @{}
Check 'region B: without dr-standby.config.json the change is region A only' ($r.code -eq 0 -and $r.report.regionB.hasStandby -eq $false)
Set-Content -LiteralPath $drPath -Value $drKeep -NoNewline

# --- smoke ----------------------------------------------------------------------------------------------
$smokeEv = Join-Path $scratch 'smoke\smoke.json'
function Invoke-Smoke([scriptblock]$Descriptor = { param($c, $i, $e) 0 }) {
    Remove-Item -LiteralPath $smokeEv -ErrorAction SilentlyContinue
    $code = Invoke-Quiet { $null = & (Join-Path $cicd 'Test-CicdBackendSmoke.ps1') -ConfigPath $cfgPath -BackendIds be2 -Arm $arm -Descriptor $Descriptor -EvidencePath $smokeEv 6>$null 2>$null; $LASTEXITCODE }
    @{ code = $code; report = (Read-Json $smokeEv) }
}
Reset-Arm; $s = Invoke-Smoke
Check 'smoke: entity and policy in A and B with a present descriptor pass' ($s.code -eq 0 -and (@($s.report.regions.Keys) -join ',') -ceq 'A,B')
$global:CicdArm.Remove("$apimB/backends/be2?api-version=2024-05-01"); $s = Invoke-Smoke
Check 'smoke: a missing region B backend entity fails' ($s.code -eq 3 -and (@($s.report.problems) -join ';') -match 'region B: apim_backend_missing')
Reset-Arm; $global:CicdArm["$apimA/apis/claude-messages/policies/policy?api-version=2024-05-01"].properties.value = '<x value="@(new string[] { "be1", "be22" })" />'; $s = Invoke-Smoke
Check 'smoke: a policy without the exact quoted id fails' ($s.code -eq 3 -and (@($s.report.problems) -join ';') -match 'region A: apim_policy_backend')
Reset-Arm; $global:CicdArm["$apimA/backends/be2?api-version=2024-05-01"].properties.url = 'https://acct1.services.ai.azure.com/anthropic'; $s = Invoke-Smoke
Check 'smoke: an entity with another URL fails' ($s.code -eq 3 -and (@($s.report.problems) -join ';') -match 'apim_backend_url')
Reset-Arm; $s = Invoke-Smoke { param($c, $i, $e) 3 }
Check 'smoke: a missing or different descriptor fails' ($s.code -eq 3 -and (@($s.report.problems) -join ';') -match 'smoke_descriptor')
Save-Json (Join-Path $scratch 'smoke\descriptor-smoke.json') @{ results = @(@{ backendId = 'be2'; outcome = 'would_create' }) }
$s = Invoke-Smoke { param($c, $i, $e) 0 }
Check 'smoke: a descriptor that would still be created fails' ($s.code -eq 3 -and (@($s.report.problems) -join ';') -match 'not present: be2=would_create')
Remove-Item (Join-Path $scratch 'smoke\descriptor-smoke.json')

# --- descriptor --------------------------------------------------------------------------------------
$global:CosmosDocs = @{}; $global:CosmosCalls = [Collections.Generic.List[object]]::new()
$fakeHttp = {
    param($request)
    $global:CosmosCalls.Add($request)
    $id = ($request.Uri -split '/docs')[1].TrimStart('/')
    if ($request.Method -eq 'GET') {
        if ($global:CosmosDocs.ContainsKey($id)) { return @{ StatusCode = 200; Content = ($global:CosmosDocs[$id] | ConvertTo-Json -Depth 10); Headers = @{} } }
        return @{ StatusCode = 404; Content = ''; Headers = @{} }
    }
    $doc = $request.Body | ConvertFrom-Json -AsHashtable
    if ($global:CosmosDocs.ContainsKey($doc.id)) { return @{ StatusCode = 409; Content = ''; Headers = @{} } }
    $global:CosmosDocs[$doc.id] = $doc; @{ StatusCode = 201; Content = $request.Body; Headers = @{} }
}
$token = { param($s, $r) 'token' }
$dEv = Join-Path $scratch 'descriptor.json'
function Invoke-Descriptor([switch]$Apply, [string[]]$Ids = @('be2')) {
    $global:CosmosCalls.Clear(); Remove-Item -LiteralPath $dEv -ErrorAction SilentlyContinue
    $code = Invoke-Quiet { $null = & (Join-Path $cicd 'Set-CicdBackendDescriptor.ps1') -ConfigPath $cfgPath -BackendIds $Ids -Apply:$Apply -EvidencePath $dEv -GetToken $token -Http $fakeHttp 6>$null 2>$null; $LASTEXITCODE }
    @{ code = $code; report = $(if (Test-Path $dEv) { Read-Json $dEv } else { @{ results = @(@{}) } }); methods = @($global:CosmosCalls | ForEach-Object Method) }
}
$d = Invoke-Descriptor
Check 'descriptor: preview reports would_create and writes nothing' ($d.code -eq 0 -and $d.report.results[0].outcome -ceq 'would_create' -and ($d.methods -join ',') -ceq 'GET' -and -not $global:CosmosDocs.Count)
Check 'descriptor: the endpoint port is removed and the database is cosmos.databaseName' ($global:CosmosCalls[0].Uri -ceq 'https://cosmos1.documents.azure.com/dbs/ccof/colls/backends/docs/be2' -and $global:CosmosCalls[0].Headers['x-ms-documentdb-partitionkey'] -ceq '["be2"]')
$d = Invoke-Descriptor -Apply
$doc = $global:CosmosDocs['be2']
Check 'descriptor: apply creates the resolver descriptor and reads it back' ($d.code -eq 0 -and $d.report.results[0].outcome -ceq 'created' -and ($d.methods -join ',') -ceq 'GET,POST,GET')
Check 'descriptor: the document has the resolver shape' ($doc.id -ceq 'be2' -and $doc.backendId -ceq 'be2' -and $doc.status -ceq 'active' -and $doc.apiFormat -ceq 'anthropic-messages' -and $doc.auth.mode -ceq 'managed-identity' -and $doc.auth.resource -ceq 'https://cognitiveservices.azure.com' -and -not $doc.ContainsKey('url'))
$d = Invoke-Descriptor -Apply
Check 'descriptor: a second apply is a no-op (present, read only)' ($d.code -eq 0 -and $d.report.results[0].outcome -ceq 'present' -and ($d.methods -join ',') -ceq 'GET')
$global:CosmosDocs['be2'] = @{ id = 'be2'; backendId = 'be2'; status = 'disabled'; apiFormat = 'anthropic-messages'; auth = @{ mode = 'managed-identity'; resource = 'https://cognitiveservices.azure.com' } }
$d = Invoke-Descriptor -Apply
Check 'descriptor: a different existing document fails and is not overwritten' ($d.code -eq 3 -and $d.report.results[0].outcome -ceq 'mismatch' -and ($d.methods -join ',') -ceq 'GET' -and $global:CosmosDocs['be2'].status -ceq 'disabled')
$global:CosmosDocs.Clear()
$raceHttp = { param($request) if ($request.Method -eq 'POST') { $global:CosmosDocs['be2'] = $request.Body | ConvertFrom-Json -AsHashtable; return @{ StatusCode = 409; Content = ''; Headers = @{} } }; & $fakeHttp $request }
$code = Invoke-Quiet { $null = & (Join-Path $cicd 'Set-CicdBackendDescriptor.ps1') -ConfigPath $cfgPath -BackendIds be2 -Apply -EvidencePath $dEv -GetToken $token -Http $raceHttp 6>$null 2>$null; $LASTEXITCODE }
Check 'descriptor: a create race (409) with the same document is present' ($code -eq 0 -and (Test-Path $dEv) -and (Read-Json $dEv).results[0].outcome -ceq 'present')
$pwsh = (Get-Process -Id $PID).Path
$o = & $pwsh -NoProfile -File (Join-Path $cicd 'Set-CicdBackendDescriptor.ps1') -ConfigPath $cfgPath -BackendIds nope 2>&1
Check 'descriptor: an id that is not in backends[] is refused' ($LASTEXITCODE -eq 3 -and "$o" -match 'descriptor_backend_unknown')
$o = & $pwsh -NoProfile -File (Join-Path $cicd 'Set-CicdBackendDescriptor.ps1') -ConfigPath $cfgPath -BackendIds be2 -StateDirectory (Join-Path $scratch 'none') 2>&1
Check 'descriptor: missing driver state is refused' ($LASTEXITCODE -eq 3 -and "$o" -match 'descriptor_state_missing')
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name CicdArm, CosmosDocs, CosmosCalls -Scope Global -ErrorAction SilentlyContinue
}
$floor = 48
Write-Host "Test-CicdOnboardingScripts: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -or ($script:pass + $script:fail) -lt $floor) { Write-Host "expected at least $floor checks" -ForegroundColor Red; exit 1 }
exit 0
