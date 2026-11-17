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
# The staged driver's Stage 3, 5 and 6 input hashes, computed in a child process (the driver is dot-sourced there).
function Get-StageHashes([string]$Path) {
    $cmd = ". '$root/infra/staged/Invoke-StagedDeployment.ps1' -DotSourceOnly; `$c = Read-StgConfig '$Path'; @{ '3' = (Get-StgStageInput `$c 3); '5' = (Get-StgStageInput `$c 5); '6' = (Get-StgStageInput `$c 6) } | ConvertTo-Json -Compress"
    (& pwsh -NoProfile -Command $cmd) | ConvertFrom-Json -AsHashtable
}
$baseHash = Get-StageHashes $basePath; $headHash = Get-StageHashes $cfgPath
$statePath = Join-Path $env1 '.staged-state\state.json'
function Save-PrimaryState([hashtable]$Hashes) {
    Save-Json $statePath @{ stages = @{
        '1' = @{ outputs = @{ apimId = $apimA; apimPrincipalId = $pA; cosmosEndpoint = 'https://cosmos1.documents.azure.com:443/'; cosmosAccountId = "/subscriptions/$sub/resourceGroups/rg-new/providers/Microsoft.DocumentDB/databaseAccounts/cosmos1" } }
        '3' = @{ configHash = $Hashes['3']; outputs = @{ apimPrincipalId = $pA } }; '5' = @{ configHash = $Hashes['5'] }; '6' = @{ configHash = $Hashes['6'] } } }
}
Save-PrimaryState $baseHash
Save-Json (Join-Path $env1 'dr-standby.config.json') @{ standby = @{ stagedConfigPath = 'staged.config.json'; stagedStateDirectory = '.staged-state'; stateDirectory = '.dr-state' } }
$standby = @{ schema = 'ccof.dr.standby.v1'; phases = @{ Shells = @{ outputs = @{ apimId = $apimB; apimPrincipalId = $pB } }; Grants = @{ outputs = @{} }; Config = @{ outputs = @{} }; Code = @{ outputs = @{} } } }
Save-Json (Join-Path $env1 '.dr-state\standby.state.json') $standby

# --- fake ARM ---------------------------------------------------------------------------------------
$acct2 = "/subscriptions/$fsub/resourceGroups/foundry-rg/providers/Microsoft.CognitiveServices/accounts/acct2"
# Policy fixtures modelled on infra/gateway/policy/claude-messages.template.xml: the legacy inline policy
# with a static list, and the split form (the infsim lab today) whose API policy only includes fragments and
# whose inbound fragment admits registry backends by the descriptor auth mode.
$miRoute = '<choose><when condition="@((string)context.Variables["ccofBackendAuthMode"] == "managed-identity")"><authentication-managed-identity id="x" resource="@((string)context.Variables["ccofBackendAuthResource"])" /><!-- ADR 0034 --><set-backend-service backend-id="@((string)context.Variables["ccofRouteBackendId"] != "" ? (string)context.Variables["ccofRouteBackendId"] : (string)context.Variables["ccofBackendId"])" /></when></choose>'
function Get-AllowXml([string]$Ids, [switch]$Registry) { '<set-variable name="ccofBackendAllowed" value="@(Array.IndexOf(new string[] { ' + $Ids + ' }, (string)context.Variables["ccofBackendId"]) >= 0' + $(if ($Registry) { ' || (string)context.Variables["ccofBackendAuthMode"] != ""' }) + ')" />' }
function Get-InlinePolicy([string]$Ids) { "<policies><inbound>$(Get-AllowXml $Ids)$miRoute</inbound><backend /><outbound /></policies>" }
$splitApi = '<policies><inbound><include-fragment fragment-id="claude-messages-inbound" /></inbound><backend><include-fragment fragment-id="claude-messages-backend" /></backend><outbound><include-fragment fragment-id="claude-messages-outbound" /></outbound></policies>'
function Set-SplitPolicy([string]$Apim, [string]$Inbound = "<fragment>$(Get-AllowXml '' -Registry)$miRoute</fragment>") {
    $global:CicdArm["$Apim/apis/claude-messages/policies/policy?api-version=2024-05-01&format=rawxml"] = @{ properties = @{ value = $splitApi } }
    $global:CicdArm["$Apim/policyFragments/claude-messages-inbound?api-version=2024-05-01&format=rawxml"] = @{ properties = @{ value = $Inbound } }
    $global:CicdArm["$Apim/policyFragments/claude-messages-backend?api-version=2024-05-01&format=rawxml"] = @{ properties = @{ value = '<fragment><forward-request /></fragment>' } }
    $global:CicdArm["$Apim/policyFragments/claude-messages-outbound?api-version=2024-05-01&format=rawxml"] = @{ properties = @{ value = '<fragment>"be2|claude-haiku-4-5=global"</fragment>' } }
}
function Reset-Arm {    $global:CicdArm = @{
        "$acct2`?api-version=2024-10-01" = @{ kind = 'AIServices'; location = 'eastus2'; properties = @{ provisioningState = 'Succeeded'; publicNetworkAccess = 'Disabled'; customSubDomainName = 'acct2'
            privateEndpointConnections = @(@{ properties = @{ privateEndpoint = @{ id = '/pe/1' }; privateLinkServiceConnectionState = @{ status = 'Approved' } } }) } }
        "$acct2/deployments?api-version=2024-10-01" = @{ value = @(@{ name = 'claude-haiku-4-5'; properties = @{ provisioningState = 'Succeeded'; model = @{ format = 'Anthropic'; name = 'claude-haiku-4-5'; version = '1' } } }) }
        "$acct2/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" = @{ value = @(
            @{ properties = @{ principalId = $pA; roleDefinitionId = '/x/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908' } }
            @{ properties = @{ principalId = $pB; roleDefinitionId = '/x/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908' } }) }
    }
    foreach ($apim in $apimA, $apimB) {
        $global:CicdArm["$apim/backends/be2?api-version=2024-05-01"] = @{ properties = @{ url = 'https://acct2.services.ai.azure.com/anthropic' } }
        $global:CicdArm["$apim/apis/claude-messages/policies/policy?api-version=2024-05-01&format=rawxml"] = @{ properties = @{ value = (Get-InlinePolicy '"be1", "be2"') } }
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

# --- validate: region A scope (the Stage 3, 5 and 6 records) -------------------------------------------
Check 'region A: fixture hashes differ only because of the added backend' ($baseHash['3'] -cne $headHash['3'] -and $baseHash['6'] -cne $headHash['6'])
Save-PrimaryState @{ '3' = $headHash['3']; '5' = $baseHash['5']; '6' = $baseHash['6'] }
Check 'region A: a rerun after a partial apply (Stage 3 done) passes' ((Invoke-Validate @{ SkipAzure = $true; Arm = { throw 'called' } }).code -eq 0)
Save-PrimaryState $baseHash
$pending = Copy-Deep $head; $pending.sync.schedule = '0 */5 * * * *'; $pendingPath = Join-Path $env1 'pending.config.json'; Save-Json $pendingPath $pending
$r = Invoke-Validate @{ ConfigPath = $pendingPath; BaseConfigPath = $null; BackendIds = @('be2'); SkipAzure = $true; Arm = { throw 'called' } }
Check 'region A: a config with another unapplied change is refused in dispatch mode' ($r.code -eq 3 -and (Problems $r) -match 'primary_scope: standby_backends_scope: region A Stage 5')
Remove-Item $pendingPath
Save-PrimaryState @{ '3' = $baseHash['3']; '5' = $baseHash['5'] }
$r = Invoke-Validate @{ SkipAzure = $true; Arm = { throw 'called' } }
Check 'region A: a missing Stage 6 record is refused' ($r.code -eq 3 -and (Problems $r) -match 'region A Stage 6 has no verified record')
Save-PrimaryState $baseHash

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
Remove-Item $sbPath
$r = Invoke-Validate @{ SkipAzure = $true; Arm = { throw 'called' } }
Check 'region B: offline (-SkipAzure) without standby state warns instead of refusing' ($r.code -eq 0 -and (@($r.report.warnings) -join ';') -match 'standby_state_not_checked')
Check 'region B: online without standby state is refused' ((Problems (Invoke-Validate @{})) -match 'standby_incomplete')
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
$descriptorPresent = { param($c, $i, $e) Save-Json $e @{ results = @($i | ForEach-Object { @{ backendId = $_; outcome = 'present' } }) }; 0 }
function Invoke-Smoke([scriptblock]$Descriptor = $descriptorPresent) {
    Remove-Item -LiteralPath $smokeEv -ErrorAction SilentlyContinue
    $code = Invoke-Quiet { $null = & (Join-Path $cicd 'Test-CicdBackendSmoke.ps1') -ConfigPath $cfgPath -BackendIds be2 -Arm $arm -Descriptor $Descriptor -EvidencePath $smokeEv 6>$null 2>$null 3>$null; $LASTEXITCODE }
    @{ code = $code; report = (Read-Json $smokeEv) }
}
function SmokeProblems($s) { @($s.report.problems) -join ';' }
$polA = "$apimA/apis/claude-messages/policies/policy?api-version=2024-05-01&format=rawxml"
Reset-Arm; $s = Invoke-Smoke
Check 'smoke: inline policy with the id in the static list, entities in A and B and a present descriptor pass' ($s.code -eq 0 -and (@($s.report.regions.Keys) -join ',') -ceq 'A,B' -and $s.report.regions.A.backends.be2.routing -ceq 'static')
$global:CicdArm.Remove("$apimB/backends/be2?api-version=2024-05-01"); $s = Invoke-Smoke
Check 'smoke: a missing region B backend entity fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'region B: apim_backend_missing')
Reset-Arm; $global:CicdArm[$polA].properties.value = Get-InlinePolicy '"be1", "be22"'; $s = Invoke-Smoke
Check 'smoke: a static list without the exact id and no registry admission fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'region A: apim_policy_backend_not_allowed')
Reset-Arm; $global:CicdArm["$apimA/backends/be2?api-version=2024-05-01"].properties.url = 'https://acct1.services.ai.azure.com/anthropic'; $s = Invoke-Smoke
Check 'smoke: an entity with another URL fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'apim_backend_url')
Reset-Arm; Set-SplitPolicy $apimA; Set-SplitPolicy $apimB; $s = Invoke-Smoke
Check 'smoke: split policy (fragments) with an empty static list admits the id by registry auth mode' ($s.code -eq 0 -and $s.report.regions.A.backends.be2.routing -ceq 'registry' -and (@($s.report.regions.B.backends.be2.fragments) -join ',') -ceq 'claude-messages-inbound,claude-messages-backend,claude-messages-outbound')
Reset-Arm; Set-SplitPolicy $apimA ([Net.WebUtility]::HtmlEncode("<fragment>$(Get-AllowXml '' -Registry)$miRoute</fragment>")); $s = Invoke-Smoke
Check 'smoke: an XML-escaped (&quot;) fragment is decoded and passes' ($s.code -eq 0 -and $s.report.regions.A.backends.be2.routing -ceq 'registry')
Reset-Arm; Set-SplitPolicy $apimA; $global:CicdArm.Remove("$apimA/policyFragments/claude-messages-inbound?api-version=2024-05-01&format=rawxml"); $s = Invoke-Smoke
Check 'smoke: a missing included fragment fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'region A: apim_policy_fragment_missing: .* claude-messages-inbound' -and (SmokeProblems $s) -match 'apim_policy_unrecognized')
Reset-Arm; Set-SplitPolicy $apimA "<fragment>$(Get-AllowXml '')$miRoute</fragment>"; $s = Invoke-Smoke
Check 'smoke: a split policy with an empty static list and no registry admission fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'region A: apim_policy_backend_not_allowed')
$cmRoute = $miRoute.Replace('== "managed-identity"', '== "credential-manager"'); Reset-Arm; Set-SplitPolicy $apimB "<fragment>$(Get-AllowXml '' -Registry)$cmRoute</fragment>"; $s = Invoke-Smoke
Check 'smoke: a policy without the managed-identity route to ccofBackendId fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'region B: apim_policy_no_route')
Reset-Arm; $global:CicdArm[$polA].properties.value = '<policies><inbound><x value="@(new string[] { &quot;be2&quot; })" /></inbound></policies>'; $s = Invoke-Smoke
Check 'smoke: a policy that only mentions the id without the admission decision fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'region A: apim_policy_unrecognized')
Reset-Arm; Set-SplitPolicy $apimA '<fragment><include-fragment fragment-id="claude-messages-inbound" /></fragment>'; $s = Invoke-Smoke
Check 'smoke: a cyclic fragment include fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'region A: apim_policy_fragment_(cycle|depth)')
Reset-Arm; $s = Invoke-Smoke { param($c, $i, $e) 3 }
Check 'smoke: a descriptor script failure fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'smoke_descriptor: Set-CicdBackendDescriptor.ps1 exited 3')
$s = Invoke-Smoke { param($c, $i, $e) Save-Json $e @{ results = @(@{ backendId = 'be2'; outcome = 'would_create' }) }; 0 }
Check 'smoke: a descriptor that would still be created fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'not present and active: be2=would_create')
$s = Invoke-Smoke { param($c, $i, $e) 0 }
Check 'smoke: a descriptor step that reports no outcome fails' ($s.code -eq 3 -and (SmokeProblems $s) -match 'be2=no result')
$bomJson = '{"properties":{"value":"<policies />"}}'
$bomBytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes($bomJson))
$bomOk = try { (ConvertFrom-CicdArmBody $bomBytes).properties.value -ceq '<policies />' -and (ConvertFrom-CicdArmBody ([string][char]0xFEFF + $bomJson)).properties.value -ceq '<policies />' } catch { $false }
Check 'ARM reader: a body with a UTF-8 byte order mark parses (bytes and string)' $bomOk
Reset-Arm; Set-SplitPolicy $apimA '<fragment><include-fragment fragment-id="n1" /></fragment>'; foreach ($k in 1..6) { $global:CicdArm["$apimA/policyFragments/n$k`?api-version=2024-05-01&format=rawxml"] = @{ properties = @{ value = ('<fragment><include-fragment fragment-id="n{0}" /></fragment>' -f ($k + 1)) } } }; $s = Invoke-Smoke
Check 'smoke: includes nested deeper than 5 levels fail' ($s.code -eq 3 -and (SmokeProblems $s) -match 'region A: apim_policy_fragment_depth')
$geo = Get-CicdPolicyRouting -Policy "$(Get-AllowXml '' -Registry)$miRoute" -Id be2 -InferenceGeo @{ 'claude-haiku-4-5' = 'global' }
Check 'smoke: a missing inference geo entry is a warning, not a failure' (@($geo.problems).Count -eq 0 -and (@($geo.warnings) -join ';') -match 'be2\|claude-haiku-4-5=global')
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
# Smoke without -EvidencePath still reads each descriptor outcome (the preview exits 0 for would_create).
$global:CosmosDocs.Clear(); Reset-Arm
$runnerTemp = Join-Path $scratch 'runner-temp'; $null = New-Item -ItemType Directory -Force -Path $runnerTemp; $keepRunnerTemp = $env:RUNNER_TEMP; $env:RUNNER_TEMP = $runnerTemp
$realDescriptor = { param($c, $i, $e) & (Join-Path $cicd 'Set-CicdBackendDescriptor.ps1') -ConfigPath $c -BackendIds $i -EvidencePath $e -GetToken $token -Http $fakeHttp; $global:DescriptorExit = $global:LASTEXITCODE; $global:DescriptorExit }.GetNewClosure()
function Invoke-SmokeNoEvidence { Invoke-Quiet { $null = & (Join-Path $cicd 'Test-CicdBackendSmoke.ps1') -ConfigPath $cfgPath -BackendIds be2 -Arm $arm -Descriptor $realDescriptor 6>$null 2>$null 3>$null; $LASTEXITCODE } }
$global:DescriptorExit = $null; $code = Invoke-SmokeNoEvidence
Check 'smoke without -EvidencePath: a descriptor 404 (would_create, exit 0) fails' ($code -eq 3 -and $global:DescriptorExit -eq 0 -and -not $global:CosmosDocs.Count)
$global:CosmosDocs['be2'] = @{ id = 'be2'; backendId = 'be2'; status = 'active'; apiFormat = 'anthropic-messages'; auth = @{ mode = 'managed-identity'; resource = 'https://cognitiveservices.azure.com' } }
$code = Invoke-SmokeNoEvidence
Check 'smoke without -EvidencePath: a present descriptor passes and the temporary evidence is removed' ($code -eq 0 -and -not @(Get-ChildItem -LiteralPath $runnerTemp).Count)
$env:RUNNER_TEMP = $keepRunnerTemp
$global:CosmosDocs.Clear()
$raceHttp = { param($request) if ($request.Method -eq 'POST') { $global:CosmosDocs['be2'] = $request.Body | ConvertFrom-Json -AsHashtable; return @{ StatusCode = 409; Content = ''; Headers = @{} } }; & $fakeHttp $request }
$code = Invoke-Quiet { $null = & (Join-Path $cicd 'Set-CicdBackendDescriptor.ps1') -ConfigPath $cfgPath -BackendIds be2 -Apply -EvidencePath $dEv -GetToken $token -Http $raceHttp 6>$null 2>$null; $LASTEXITCODE }
Check 'descriptor: a create race (409) with the same document is present' ($code -eq 0 -and (Test-Path $dEv) -and (Read-Json $dEv).results[0].outcome -ceq 'present')
$pwsh = (Get-Process -Id $PID).Path
$o = & $pwsh -NoProfile -File (Join-Path $cicd 'Set-CicdBackendDescriptor.ps1') -ConfigPath $cfgPath -BackendIds nope 2>&1
Check 'descriptor: an id that is not in backends[] is refused' ($LASTEXITCODE -eq 3 -and "$o" -match 'descriptor_backend_unknown')
$o = & $pwsh -NoProfile -File (Join-Path $cicd 'Set-CicdBackendDescriptor.ps1') -ConfigPath $cfgPath -BackendIds be2 -StateDirectory (Join-Path $scratch 'none') 2>&1
Check 'descriptor: missing driver state is refused' ($LASTEXITCODE -eq 3 -and "$o" -match 'descriptor_state_missing')

# Workflow step commands (Get-CicdOnboardingCommand, Invoke-CicdOnboardingStep.ps1) and rollback text.
$cmdOf = { param([hashtable]$P) $P.Environment = 'lab'; $P.RepoRoot = $scratch; Get-CicdOnboardingCommand @P }
$refused = { param([hashtable]$P) try { $null = & $cmdOf $P; $false } catch { $true } }
$c = & $cmdOf @{ Step = 'stage5'; Apply = $true }
Check 'step: stage5 apply runs Invoke-StagedDeployment -Stage 5 on deploy/<env> with -Apply' ($c.File -like '*infra*staged*Invoke-StagedDeployment.ps1' -and ($c.Arguments -join ' ') -ceq "-Stage 5 -ConfigPath $cfgPath -Apply" -and $c.Mode -ceq 'apply')
$c = & $cmdOf @{ Step = 'standby-backends'; BackendIds = @('be2, be3') }
Check 'step: standby-backends previews -Phase Backends with the ids and no -Apply' (($c.Arguments -join ' ') -ceq "-Phase Backends -ConfigPath $(Join-Path $env1 'dr-standby.config.json') -BackendIds be2,be3" -and $c.Log -like '*onboard-standby-backends-preview.log')
$c = & $cmdOf @{ Step = 'validate'; BaseConfigPath = $basePath }
Check 'step: validate compares with the base configuration and resolves DNS' ($c.Arguments -contains '-BaseConfigPath' -and $c.Arguments -contains '-ResolveDns' -and $c.Arguments -notcontains '-Apply' -and $c.Arguments -notcontains '-RequirePrivateLink')
$c = & $cmdOf @{ Step = 'validate'; BaseConfigPath = $basePath; Offline = $true }
Check 'step: offline validate (pull requests) skips Azure and DNS' ($c.Arguments -contains '-SkipAzure' -and $c.Arguments -notcontains '-ResolveDns')
Check 'step: only validate runs offline' (& $refused @{ Step = 'stage3'; Offline = $true })
Check 'step: Stage 7 is not an onboarding step' (& $refused @{ Step = 'stage7'; Apply = $true })
Check 'step: read-only steps refuse -Apply' ((& $refused @{ Step = 'smoke'; BackendIds = 'be2'; Apply = $true }) -and (& $refused @{ Step = 'validate'; BackendIds = 'be2'; Apply = $true }) -and (& $refused @{ Step = 'standby-verify'; Apply = $true }))
Check 'step: backend steps refuse an empty id list' ((& $refused @{ Step = 'descriptor' }) -and (& $refused @{ Step = 'standby-backends'; BackendIds = ' , ' }) -and (& $refused @{ Step = 'validate' }))
Check 'step: invalid environment or backend id is refused' ((& $refused @{ Step = 'smoke'; BackendIds = 'be2;rm' }) -and $(try { $null = Get-CicdOnboardingCommand -Step stage3 -Environment '../x' -RepoRoot $scratch; $false } catch { $true }))
Move-Item (Join-Path $env1 'dr-standby.config.json') (Join-Path $env1 'dr.keep')
Check 'step: region B steps need dr-standby.config.json' ((& $refused @{ Step = 'standby-verify' }) -and (& $refused @{ Step = 'frontdoor-verify' }) -and -not (& $refused @{ Step = 'stage6' }))
Move-Item (Join-Path $env1 'dr.keep') (Join-Path $env1 'dr-standby.config.json')
$rb = Get-CicdOnboardingRollback -Environment lab -BackendIds be2 -Completed stage3, stage5
Check 'rollback: names the completed steps, the revert and the region B phases' ("$rb" -match 'Completed apply steps: stage3, stage5\.' -and "$rb" -match 'deploy/lab/staged\.config\.json' -and "$rb" -match 'Phase Grants then Config' -and "$rb" -match 'backends/be2')
$stepScript = Join-Path $cicd 'Invoke-CicdOnboardingStep.ps1'
$keepGa = $env:GITHUB_ACTIONS; $keepRole = $env:CCOF_RUNNER_ROLE
try {
    $env:GITHUB_ACTIONS = 'true'; $env:CCOF_RUNNER_ROLE = 'preview'
    $o = & $pwsh -NoProfile -File $stepScript -Environment lab -Step stage3 -Apply -PrintOnly 2>&1
    Check 'step script: an apply on the preview runner is refused' ($LASTEXITCODE -eq 2 -and "$o" -match 'runner_role_mismatch')
    $o = & $pwsh -NoProfile -File $stepScript -Environment lab -Step stage3 -PrintOnly 2>&1
    Check 'step script: a preview prints the command on the preview runner' ($LASTEXITCODE -eq 0 -and "$o" -match 'Invoke-StagedDeployment\.ps1 -Stage 3 -ConfigPath')
    $env:CCOF_RUNNER_ROLE = 'apply'
    $o = & $pwsh -NoProfile -File $stepScript -Environment lab -Step stage8 -Apply -PrintOnly 2>&1
    Check 'step script: an unknown step is refused with exit 2' ($LASTEXITCODE -eq 2 -and "$o" -match 'refused')

    # Approval enforcement (private repositories need GitHub Enterprise for required reviewers).
    $env:GITHUB_RUN_ID = '901'; $env:GITHUB_RUN_ATTEMPT = '1'; $env:GITHUB_REPOSITORY = 'octo/ccof'; $env:GITHUB_ACTOR = 'starter'
    $okEnv = { [pscustomobject]@{ can_admins_bypass = $false
        protection_rules = @([pscustomobject]@{ type = 'required_reviewers'; prevent_self_review = $true; reviewers = @([pscustomobject]@{ type = 'User' }) }, [pscustomobject]@{ type = 'branch_policy' })
        deployment_branch_policy = [pscustomobject]@{ protected_branches = $false; custom_branch_policies = $true } } }
    $main = @([pscustomobject]@{ name = 'main'; type = 'branch' })
    $approved = { param($envName = 'lab-apply', $state = 'approved', $who = 'reviewer') @([pscustomobject]@{ state = $state; user = [pscustomobject]@{ login = $who }; environments = @([pscustomobject]@{ name = $envName }) }) }
    $ap = { param($E, $B = $main, $A = (& $approved)) Get-CicdApprovalProblems -Name 'lab-apply' -Environment $E -BranchPolicies $B -Approvals $A -Actor 'starter' }
    $r = & $ap (& $okEnv)
    Check 'approval: reviewers, main-only branches and an approval in this run pass' ($r.problems.Count -eq 0 -and $r.warnings.Count -eq 0 -and "$($r.approvers)" -ceq 'reviewer')
    $e = & $okEnv; $e.protection_rules = @([pscustomobject]@{ type = 'branch_policy' })
    $r = & $ap $e
    Check 'approval: no required reviewers (private repo below Enterprise) fails and names the plan' ("$($r.problems)" -match '^no_required_reviewers' -and "$($r.problems)" -match 'GitHub Enterprise')
    $e = & $okEnv; $e.protection_rules[0].reviewers = @()
    Check 'approval: a reviewers rule with nobody in it fails' ("$((& $ap $e).problems)" -match 'no_required_reviewers')
    Check 'approval: a missing environment fails' ("$((& $ap $null).problems)" -match '^environment_missing')
    $e = & $okEnv; $e.deployment_branch_policy = $null
    Check 'approval: no deployment branch policy fails' ("$((& $ap $e).problems)" -match 'no_branch_policy')
    $e = & $okEnv; $e.deployment_branch_policy = [pscustomobject]@{ protected_branches = $true; custom_branch_policies = $false }
    Check 'approval: protected-branches policy is not main only' ("$((& $ap $e).problems)" -match 'branch_policy_not_main_only')
    Check 'approval: an extra branch rule is not main only' ("$((& $ap (& $okEnv) @(@($main) + [pscustomobject]@{ name = 'feat/*'; type = 'branch' })).problems)" -match 'branch_policy_not_main_only')
    Check 'approval: a tag rule named main is not main only' ("$((& $ap (& $okEnv) @([pscustomobject]@{ name = 'main'; type = 'tag' })).problems)" -match 'branch_policy_not_main_only')
    Check 'approval: no approval in this run (bypass) fails' ("$((& $ap (& $okEnv) $main @()).problems)" -match '^not_approved')
    Check 'approval: an approval of another environment does not count' ("$((& $ap (& $okEnv) $main (& $approved 'lab-gate-privatelink')).problems)" -match '^not_approved')
    Check 'approval: a rejection fails' ("$((& $ap (& $okEnv) $main @(@(& $approved) + @(& $approved 'lab-apply' 'rejected' 'other'))).problems)" -match '^rejected')
    $e = & $okEnv; $e.protection_rules[0].prevent_self_review = $false
    $r = & $ap $e $main (& $approved 'lab-apply' 'approved' 'starter')
    Check 'approval: self-review and self-approval are warnings' ($r.problems.Count -eq 0 -and "$($r.warnings)" -match 'self_review_allowed' -and "$($r.warnings)" -match 'self_approved')
    # Administrator bypass fails closed whether it is on, absent or not a boolean (same contract as
    # Test-CicdGhEnvironment in CicdGitHubEnvironments.psm1): a bypassed job runs without any review.
    $e = & $okEnv; $e.can_admins_bypass = $true
    $r = & $ap $e
    Check 'approval: administrator bypass on fails even with an approval in this run' ($r.problems.Count -eq 1 -and "$($r.problems)" -match '^admins_can_bypass' -and "$($r.warnings)" -notmatch 'admins_can_bypass')
    $e = & $okEnv; $e.PSObject.Properties.Remove('can_admins_bypass')
    Check 'approval: an unreadable (absent) administrator bypass fails' ("$((& $ap $e).problems)" -match '^admins_bypass_unreadable')
    foreach ($v in @('false', 0, $null)) {
        $e = & $okEnv; $e.can_admins_bypass = $v
        Check "approval: a non-boolean administrator bypass ($(if ($null -eq $v) { 'null' } else { "$($v.GetType().Name) $v" })) fails" ("$((& $ap $e).problems)" -match '^admins_bypass_unreadable')
    }
    # One reviewed job per environment and run: a second approval of the same environment means another job
    # (or an unexpected review) used it, so this job cannot tell which approval is its own.
    $two = @(@(& $approved) + @(& $approved 'lab-apply' 'approved' 'second'))
    Check 'approval: two approvals of the environment in one run fail (one reviewed job per environment)' ("$((& $ap (& $okEnv) $main $two).problems)" -match '^approval_not_unique')

    $assert = Join-Path $cicd 'Assert-CicdApproval.ps1'
    $record = Join-Path $root 'evidence/lab/approval-lab-apply.json'
    $fixture = Join-Path $scratch 'approval-fixture.json'
    @{ environment = (& $okEnv); branchPolicies = $main; approvals = (& $approved) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture
    $o = & $pwsh -NoProfile -File $assert -Environment lab -GitHubEnvironment lab-apply -FixturePath $fixture 2>&1
    $rec = Get-Content -Raw -LiteralPath $record | ConvertFrom-Json
    Check 'approval script: an enforced approval exits 0 and records this run attempt' ($LASTEXITCODE -eq 0 -and $rec.verified -eq $true -and $rec.runId -ceq '901' -and $rec.runAttempt -ceq '1')
    $o = & $pwsh -NoProfile -File $stepScript -Environment lab -Step stage3 -Apply -PrintOnly 2>&1
    Check 'step script: an apply with this run''s verified approval runs' ($LASTEXITCODE -eq 0 -and "$o" -match '-Stage 3 .*-Apply')
    $env:GITHUB_RUN_ATTEMPT = '3'
    $o = & $pwsh -NoProfile -File $stepScript -Environment lab -Step stage3 -Apply -PrintOnly 2>&1
    Check 'step script: an approval from another run attempt is refused' ($LASTEXITCODE -eq 2 -and "$o" -match 'approval_not_enforced')
    $env:GITHUB_RUN_ATTEMPT = '1'
    $e = & $okEnv; $e.protection_rules = @()
    @{ environment = $e; branchPolicies = $main; approvals = @() } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture
    $o = & $pwsh -NoProfile -File $assert -Environment lab -GitHubEnvironment lab-apply -FixturePath $fixture 2>&1
    Check 'approval script: no reviewers exits 4 and records verified false' ($LASTEXITCODE -eq 4 -and (Get-Content -Raw -LiteralPath $record | ConvertFrom-Json).verified -eq $false -and "$o" -match 'no_required_reviewers')
    $o = & $pwsh -NoProfile -File $stepScript -Environment lab -Step stage5 -Apply -PrintOnly 2>&1
    Check 'step script: an unverified approval record refuses the apply' ($LASTEXITCODE -eq 2 -and "$o" -match 'approval_not_enforced.*not verified')
    Remove-Item -LiteralPath $record
    $o = & $pwsh -NoProfile -File $stepScript -Environment lab -Step descriptor -BackendIds be2 -Apply -PrintOnly 2>&1
    Check 'step script: an apply without an approval record is refused; a preview needs none' ($LASTEXITCODE -eq 2 -and "$o" -match 'approval_not_enforced: no approval record' -and $(& $pwsh -NoProfile -File $stepScript -Environment lab -Step stage3 -PrintOnly *>$null; $LASTEXITCODE -eq 0))
    $auto = [pscustomobject]@{ can_admins_bypass = $true; protection_rules = @(); deployment_branch_policy = $null }
    $r = & $ap $auto $main @()
    Check 'approval: an auto-created (unprotected) environment fails on reviewers, branches and approval' ("$($r.problems)" -match 'no_required_reviewers' -and "$($r.problems)" -match 'no_branch_policy' -and "$($r.problems)" -match 'not_approved')
    $r = Get-CicdApprovalProblems -Name 'lab-apply' -Environment (& $okEnv) -BranchPolicies $main -Approvals (& $approved) -RunAttempt 2
    Check 'approval: a rerun attempt fails closed (approvals are per run, not per attempt)' ("$($r.problems)" -match '^rerun_attempt')
    @{ environment = (& $okEnv); branchPolicies = $main; approvals = (& $approved) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture
    $env:GITHUB_RUN_ATTEMPT = '2'
    $o = & $pwsh -NoProfile -File $assert -Environment lab -GitHubEnvironment lab-apply -FixturePath $fixture 2>&1
    Check 'approval script: a rerun attempt exits 4 even with an approval in the run' ($LASTEXITCODE -eq 4 -and "$o" -match 'rerun_attempt')
    $env:GITHUB_RUN_ATTEMPT = '1'
    $e = & $okEnv; $e.can_admins_bypass = $true
    @{ environment = $e; branchPolicies = $main; approvals = (& $approved) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture
    $o = & $pwsh -NoProfile -File $assert -Environment lab -GitHubEnvironment lab-apply -FixturePath $fixture 2>&1
    Check 'approval script: administrator bypass exits 4 and records verified false' ($LASTEXITCODE -eq 4 -and (Get-Content -Raw -LiteralPath $record | ConvertFrom-Json).verified -eq $false -and "$o" -match 'admins_can_bypass')
    @{ environment = (& $okEnv); branchPolicies = $main; approvals = (& $approved) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture
    $env:GITHUB_RUN_ID = ''
    $o = & $pwsh -NoProfile -File $assert -Environment lab -GitHubEnvironment lab-apply -FixturePath $fixture 2>&1
    Check 'approval script: without the run context it refuses (exit 2)' ($LASTEXITCODE -eq 2)
} finally {
    $env:GITHUB_ACTIONS = $keepGa; $env:CCOF_RUNNER_ROLE = $keepRole
    foreach ($n in 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_REPOSITORY', 'GITHUB_ACTOR') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $root 'evidence/lab/approval-lab-apply.json') -Force -ErrorAction SilentlyContinue
}
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name CicdArm, CosmosDocs, CosmosCalls -Scope Global -ErrorAction SilentlyContinue
}
$floor = 103
Write-Host "Test-CicdOnboardingScripts: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -or ($script:pass + $script:fail) -lt $floor) { Write-Host "expected at least $floor checks" -ForegroundColor Red; exit 1 }
exit 0
