# Pipeline Foundry onboarding checks (docs/runbooks/CICD-FOUNDRY-ONBOARDING.md, ADR 0040). Pure
# functions: Azure reads go through an injected -Arm scriptblock (param($path, $apiVersion)) so that the
# offline tests run without Azure. Used by scripts/cicd/Test-CicdBackendOnboarding.ps1 and
# scripts/cicd/Test-CicdBackendSmoke.ps1.
# Not strict: ARM bodies are hashtables whose optional properties are read with dot access.

$script:CicdGuid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

function ConvertTo-CicdCanonicalJson($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $o = [ordered]@{}; foreach ($k in @($Value.Keys | Sort-Object)) { $o[$k] = ConvertTo-CicdCanonicalJson $Value[$k] }; return $o
    }
    if ($Value -is [Collections.IList]) { return ,@($Value | ForEach-Object { ConvertTo-CicdCanonicalJson $_ }) }
    return $Value
}
function Get-CicdJson($Value) { ConvertTo-Json -InputObject (ConvertTo-CicdCanonicalJson $Value) -Depth 100 -Compress }

# The change between the configuration on the base branch and on the head: only backends added.
# Returns @{ added = [ids]; problems = [string] }.
function Get-CicdBackendChange {
    param([Parameter(Mandatory)] [Collections.IDictionary]$Base, [Parameter(Mandatory)] [Collections.IDictionary]$Head)
    $problems = [Collections.Generic.List[string]]::new()
    $byId = { param($cfg) $h = [ordered]@{}; foreach ($b in @($cfg['backends'])) { if ($b -is [Collections.IDictionary]) { $h[[string]$b['id']] = $b } }; $h }
    $baseIds = & $byId $Base; $headIds = & $byId $Head
    foreach ($id in $baseIds.Keys) {
        if (-not $headIds.Contains($id)) { $problems.Add("backend_removed: $id. Removing a backend is not onboarding; follow docs/runbooks/ADMIN-OPERATIONS.md with the platform owner.") }
        elseif ((Get-CicdJson $baseIds[$id]) -cne (Get-CicdJson $headIds[$id])) { $problems.Add("backend_changed: $id. Only new backends may be added here; change existing ones with the deployment pipeline.") }
    }
    $baseOrder = @($baseIds.Keys); $headExisting = @($headIds.Keys | Where-Object { $baseIds.Contains($_) })
    if (-not $problems.Count -and ($baseOrder -join "`n") -cne ($headExisting -join "`n")) { $problems.Add('backends_reordered: keep existing backends in their order and append new ones.') }
    foreach ($k in @(@($Base.Keys) + @($Head.Keys) | Sort-Object -Unique)) {
        if ($k -ceq 'backends') { continue }
        $b = if ($Base.Contains($k)) { Get-CicdJson $Base[$k] } else { '<absent>' }
        $h = if ($Head.Contains($k)) { Get-CicdJson $Head[$k] } else { '<absent>' }
        if ($b -cne $h) { $problems.Add("config_changed: $k. An onboarding change adds backends only; other changes go through the deployment pipeline.") }
    }
    $added = @($headIds.Keys | Where-Object { -not $baseIds.Contains($_) })
    if (-not $added.Count -and -not $problems.Count) { $problems.Add('no_backend_added: the head configuration adds no backend.') }
    return @{ added = $added; problems = @($problems) }
}

# Offline field checks for a new backend entry (in addition to Read-StgConfig).
function Get-CicdBackendFieldProblems {
    param([Parameter(Mandatory)] [Collections.IDictionary]$Backend)
    $id = [string]$Backend['id']
    if ($id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,78}[A-Za-z0-9]$') { "backends[$id].id: letters, digits and hyphens, 2-80 characters (APIM backend name)" }
    if ([string]$Backend['subscriptionId'] -notmatch $script:CicdGuid) { "backends[$id].subscriptionId must be a GUID" }
    foreach ($k in 'resourceGroup', 'accountName') { if ([string]$Backend[$k] -match '^\s*$|^REPLACE') { "backends[$id].$k must be set" } }
    $account = [regex]::Escape([string]$Backend['accountName'])
    if ([string]$Backend['url'] -cnotmatch "^https://$account\.(services\.ai|cognitiveservices)\.azure\.com/anthropic$") { "backends[$id].url must be https://<accountName>.services.ai.azure.com/anthropic" }
    $geo = $Backend['deploymentInferenceGeo']
    if ($geo -isnot [Collections.IDictionary] -or -not $geo.Count) { "backends[$id].deploymentInferenceGeo must name at least one model deployment" }
    foreach ($k in 'assignCognitiveServicesUser', 'privateEndpoint') { if ($Backend[$k] -isnot [bool]) { "backends[$id].$k must be true or false" } }
    if ($Backend['assignCognitiveServicesUser'] -is [bool] -and -not $Backend['assignCognitiveServicesUser']) {
        "backends[$id].assignCognitiveServicesUser false: APIM in both regions then needs Cognitive Services User granted by the Foundry owner; the pipeline cannot verify that. Set true."
    }
}

$script:CicdRoles = @{
    CognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'
    # Roles that can create the Cognitive Services User assignment that Stage 3 makes in each region.
    Assigners = @('8e3af657-a8ff-443c-a75c-2fe8c4bcb635', '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9', 'f58310d9-a9f6-439a-9e8d-f62e7b41a168')
}

# True for RFC 1918 and RFC 6598 (100.64.0.0/10) IPv4 addresses: a private endpoint answer.
function Test-CicdPrivateAddress([string]$Address) {
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { return $false }
    $b = $ip.GetAddressBytes()
    return ($b[0] -eq 10) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)
}

# Read-only Azure checks for one new backend. -Arm param($path) returns the ARM GET body (the path
# carries its own api-version). -Resolve param($hostName) returns IP strings (run inside the VNet).
# Returns @{ problems; warnings; facts }; facts.needsPrivateLinkGate is true when the account is private
# and no approved private endpoint (or private DNS answer) exists yet: the network team creates it
# and the Foundry owner approves it, outside the pipeline (Stage 6 creates endpoints only for accounts
# in the workload subscription and resource group).
function Get-CicdBackendAzureFindings {
    param(
        [Parameter(Mandatory)] [Collections.IDictionary]$Backend,
        [Parameter(Mandatory)] [scriptblock]$Arm,
        [string[]]$ApimPrincipalIds = @(),
        [string]$ApplyPrincipalId,
        [scriptblock]$Resolve
    )
    $problems = [Collections.Generic.List[string]]::new(); $warnings = [Collections.Generic.List[string]]::new()
    $id = [string]$Backend['id']
    $path = "/subscriptions/$($Backend['subscriptionId'])/resourceGroups/$($Backend['resourceGroup'])/providers/Microsoft.CognitiveServices/accounts/$($Backend['accountName'])"
    $facts = [ordered]@{ backendId = $id; accountId = $path; needsPrivateLinkGate = $false }
    $acct = $null
    try { $acct = & $Arm "$path`?api-version=2024-10-01" } catch { $problems.Add("foundry_unreachable: $id account $path could not be read ($($_.Exception.Message)). The preview identity needs Reader on it.") }
    if (-not $acct) { return @{ problems = @($problems); warnings = @($warnings); facts = $facts } }
    $props = $acct.properties
    $facts.kind = [string]$acct.kind; $facts.location = [string]$acct.location
    $facts.publicNetworkAccess = [string]$props.publicNetworkAccess; $facts.customSubDomainName = [string]$props.customSubDomainName
    if ($facts.kind -cne 'AIServices') { $problems.Add("foundry_kind: $id is $($facts.kind); Claude on Foundry needs an AIServices account.") }
    if ([string]$props.provisioningState -cne 'Succeeded') { $problems.Add("foundry_state: $id provisioningState is $($props.provisioningState).") }
    if ($facts.customSubDomainName -and ([string]$Backend['url']) -inotmatch "^https://$([regex]::Escape($facts.customSubDomainName))\.") { $problems.Add("foundry_url: $id url host does not match the account subdomain $($facts.customSubDomainName).") }
    $deployments = @()
    try { $deployments = @((& $Arm "$path/deployments?api-version=2024-10-01").value) } catch { $problems.Add("foundry_deployments_unreadable: $id ($($_.Exception.Message)).") }
    $facts.deployments = [ordered]@{}
    foreach ($name in @($Backend['deploymentInferenceGeo'].Keys | Sort-Object)) {
        $d = @($deployments | Where-Object { [string]$_.name -ceq $name })
        if (-not $d.Count) { $problems.Add("foundry_deployment_missing: $id has no deployment named $name."); continue }
        $m = $d[0].properties.model
        $facts.deployments[$name] = [ordered]@{ model = "$($m.format)/$($m.name)@$($m.version)"; state = [string]$d[0].properties.provisioningState }
        if ([string]$d[0].properties.provisioningState -cne 'Succeeded') { $problems.Add("foundry_deployment_state: $id deployment $name is $($d[0].properties.provisioningState).") }
        if ([string]$m.format -cne 'Anthropic') { $warnings.Add("foundry_deployment_format: $id deployment $name is $($m.format), not Anthropic; the gateway's Messages API needs a Claude deployment.") }
    }
    $pecs = @(@($props.privateEndpointConnections) | Where-Object { $_ })
    $facts.privateEndpointConnections = @($pecs | ForEach-Object { [ordered]@{ id = [string]$_.properties.privateEndpoint.id; status = [string]$_.properties.privateLinkServiceConnectionState.status } })
    $approved = @($facts.privateEndpointConnections | Where-Object { $_.status -ceq 'Approved' }).Count
    if ($Resolve) {
        $hostName = ([uri][string]$Backend['url']).Host
        $addresses = @(try { & $Resolve $hostName } catch { @() })
        $facts.dns = [ordered]@{ host = $hostName; addresses = $addresses; private = [bool]($addresses.Count -and -not @($addresses | Where-Object { -not (Test-CicdPrivateAddress $_) }).Count) }
    }
    if ($facts.publicNetworkAccess -ceq 'Disabled' -and $Backend['privateEndpoint'] -ne $true) {
        $dnsOk = -not $facts.Contains('dns') -or $facts.dns.private
        $facts.needsPrivateLinkGate = -not ($approved -and $dnsOk)
        if ($facts.needsPrivateLinkGate) { $warnings.Add("foundry_private_link: $id has public network access Disabled and $(if ($approved) { 'its host does not resolve to a private address from the runner' } else { 'no approved private endpoint' }). The network team creates the endpoint in the workload VNet (DNS zone group on the shared privatelink zones) and the Foundry owner approves it; then approve the privatelink gate.") }
    } elseif ($facts.publicNetworkAccess -cne 'Disabled') {
        $warnings.Add("foundry_public: $id has public network access $($facts.publicNetworkAccess); the gateway reaches it over the internet unless a private endpoint and DNS are in place.")
    }
    if ($Backend['assignCognitiveServicesUser'] -ne $false) {
        $assignments = $null
        try { $assignments = @((& $Arm "$path/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01").value) } catch { $warnings.Add("foundry_roles_unreadable: $id role assignments could not be read ($($_.Exception.Message)).") }
        if ($null -ne $assignments) {
            $roleOf = { param($a) ([string]$a.properties.roleDefinitionId -split '/')[-1].ToLowerInvariant() }
            $missing = @($ApimPrincipalIds | Where-Object { $_ } | Where-Object { $p = $_; -not @($assignments | Where-Object { [string]$_.properties.principalId -ieq $p -and (& $roleOf $_) -ceq $script:CicdRoles.CognitiveServicesUser }).Count })
            $facts.apimPrincipalsWithoutRole = $missing
            if ($missing.Count -and $ApplyPrincipalId) {
                $canAssign = @($assignments | Where-Object { [string]$_.properties.principalId -ieq $ApplyPrincipalId -and (& $roleOf $_) -cin $script:CicdRoles.Assigners }).Count
                $facts.applyIdentityCanAssign = [bool]$canAssign
                if (-not $canAssign) { $problems.Add("foundry_role_prerequisite: Stage 3 must grant Cognitive Services User on $id to APIM principal(s) $($missing -join ', ') but the apply identity $ApplyPrincipalId holds no Owner, User Access Administrator or Role Based Access Control Administrator on the account. Ask the Foundry owner to grant one (or to assign the role to the APIM principals and set assignCognitiveServicesUser false).") }
            }
        }
    }
    return @{ problems = @($problems); warnings = @($warnings); facts = $facts }
}

# Region B coverage from the DR configuration: region B copies every primary backend (privateEndpoint
# false) when -Phase Backends runs; it needs a standby that has completed Config.
function Get-CicdStandbyCoverage {
    param($DrConfig, $StandbyState)
    if ($null -eq $DrConfig) { return @{ hasStandby = $false; problems = @(); note = 'no dr-standby.config.json: single region' } }
    $phases = if ($StandbyState -is [Collections.IDictionary] -and $StandbyState['phases'] -is [Collections.IDictionary]) { $StandbyState['phases'] } else { @{} }
    $missing = @('Grants', 'Config', 'Code' | Where-Object { -not $phases.Contains($_) })
    if ($missing.Count) { return @{ hasStandby = $true; problems = @("standby_incomplete: region B has not completed $($missing -join ', '); finish the standby build (docs/runbooks/DR-STANDBY.md) before onboarding."); note = '' } }
    return @{ hasStandby = $true; problems = @(); note = 'region B gets the backend with Invoke-DrStandby.ps1 -Phase Backends' }
}

# ARM response body to an object. Some ARM responses (APIM policies) can start with a UTF-8 byte order mark,
# which ConvertFrom-Json rejects: it is removed here, whatever the platform.
function ConvertFrom-CicdArmBody {
    param([AllowNull()] $Body)
    $text = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) } else { [string]$Body }
    $text = $text.TrimStart([char]0xFEFF)
    if (-not $text.Trim()) { return $null }
    return ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100
}

# GET https://management.azure.com<Path> with the signed-in az identity. The token stays in memory: it is
# never printed, logged or put on a command line. HTTP errors throw with the status and ARM error code only.
function Invoke-CicdArmGet {
    param([Parameter(Mandatory)] [string]$Path, [scriptblock]$Token = { az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv --only-show-errors })
    $tok = (& $Token | Select-Object -Last 1)
    if ($LASTEXITCODE -or -not $tok) { throw 'arm_token_unavailable: az account get-access-token failed (sign in first)' }
    $r = Invoke-WebRequest -Uri "https://management.azure.com$Path" -Headers @{ Authorization = "Bearer $tok" } -Method Get -SkipHttpErrorCheck
    $bytes = $r.RawContentStream.ToArray()
    if ([int]$r.StatusCode -ge 300) {
        $code = try { (ConvertFrom-CicdArmBody $bytes).error.code } catch { '' }
        throw "HTTP $([int]$r.StatusCode) $code"
    }
    return ConvertFrom-CicdArmBody $bytes
}

# The API policy with every <include-fragment> replaced by the fragment's policy, XML entities decoded (the
# default format escapes quotes as &quot;; format=rawxml does not). Nested includes up to 5 levels; a
# missing or cyclic fragment is reported, never skipped.
function Get-CicdApimEffectivePolicy {
    param([Parameter(Mandatory)] [string]$ApimId, [Parameter(Mandatory)] [string]$ApiId, [Parameter(Mandatory)] [scriptblock]$Arm)
    $problems = [Collections.Generic.List[string]]::new(); $fragments = [Collections.Generic.List[string]]::new()
    $read = { param($path) $o = & $Arm $path; [Net.WebUtility]::HtmlDecode([string]$o.properties.value) }
    $text = $null
    try { $text = & $read "$ApimId/apis/$ApiId/policies/policy?api-version=2024-05-01&format=rawxml" } catch { $problems.Add("apim_policy_unreadable: $ApimId api $ApiId ($($_.Exception.Message)).") }
    if ($null -eq $text) { return @{ text = $null; fragments = @(); problems = @($problems) } }
    $include = [regex]'<include-fragment\s+fragment-id="([^"]+)"\s*/>'
    for ($depth = 0; $depth -le 5 -and $include.IsMatch($text); $depth++) {
        if ($depth -eq 5) { $problems.Add("apim_policy_fragment_depth: includes nest deeper than 5 levels."); break }
        $text = $include.Replace($text, {
            param($m) $fid = $m.Groups[1].Value
            if ($fragments -ccontains $fid -and $depth -gt 0) { $problems.Add("apim_policy_fragment_cycle: $fid"); return '' }
            $fragments.Add($fid)
            try { return (& $read "$ApimId/policyFragments/$fid`?api-version=2024-05-01&format=rawxml") }
            catch { $problems.Add("apim_policy_fragment_missing: $ApimId policy fragment $fid ($($_.Exception.Message))."); return '' }
        })
    }
    return @{ text = $text; fragments = @($fragments); problems = @($problems) }
}

# Whether the effective policy admits and routes backend $Id (infra/gateway/policy/claude-messages.template.xml):
# ccofBackendAllowed admits it by the static list (%%BACKEND_IDS%%, credential backends) or, for registry
# backends, by the resolver's descriptor auth mode; the managed-identity branch then sets the APIM backend
# ccofBackendId. Returns @{ problems; warnings; routing = static|registry }.
function Get-CicdPolicyRouting {
    param([AllowNull()] [string]$Policy, [Parameter(Mandatory)] [string]$Id, [Collections.IDictionary]$InferenceGeo)
    $problems = [Collections.Generic.List[string]]::new(); $warnings = [Collections.Generic.List[string]]::new(); $routing = $null
    $allow = [regex]::Match("$Policy", '<set-variable\s+name="ccofBackendAllowed"\s+value="@\((.*?)\)"\s*/>', 'Singleline')
    if (-not $allow.Success) {
        $problems.Add('apim_policy_unrecognized: no ccofBackendAllowed decision in the effective policy (fragments followed); the routing cannot be proven.')
    } else {
        $expr = $allow.Groups[1].Value
        $list = [regex]::Match($expr, 'Array\.IndexOf\(new string\[\]\s*\{([^}]*)\}\s*,\s*\(string\)context\.Variables\["ccofBackendId"\]\)\s*>=\s*0')
        $static = if ($list.Success) { @([regex]::Matches($list.Groups[1].Value, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) } else { @() }
        $registry = $expr -match '\|\|\s*\(string\)context\.Variables\["ccofBackendAuthMode"\]\s*!=\s*""'
        if ($static -ccontains $Id) { $routing = 'static' } elseif ($registry) { $routing = 'registry' }
        else { $problems.Add("apim_policy_backend_not_allowed: $Id is not in the static backend list and the policy has no registry (descriptor auth mode) admission.") }
    }
    $route = '<when\s+condition="@\(\(string\)context\.Variables\["ccofBackendAuthMode"\]\s*==\s*"managed-identity"\)">(?:(?!</when>).)*?<set-backend-service\s+backend-id="@\((?:(?!/>).)*?context\.Variables\["ccofBackendId"\]'
    if (-not [regex]::IsMatch("$Policy", $route, 'Singleline')) { $problems.Add('apim_policy_no_route: no managed-identity branch sets the APIM backend to ccofBackendId.') }
    if ($InferenceGeo) {
        foreach ($dep in @($InferenceGeo.Keys | Sort-Object)) {
            if (-not "$Policy".Contains("""$Id|$dep=$($InferenceGeo[$dep])""")) { $warnings.Add("apim_policy_geo: no inference geo entry $Id|$dep=$($InferenceGeo[$dep]) (the gateway then sends no geo hint for that deployment).") }
        }
    }
    return @{ problems = @($problems); warnings = @($warnings); routing = $routing }
}

# Smoke checks after apply in one region: the APIM backend entity (Stage 5 apim-api.bicep, name = backend id,
# configured URL) and the effective policy's admission and routing for the id. Registry routing also needs
# the active descriptor, which the smoke script checks separately. $Detail receives routing, fragments, warnings.
function Get-CicdApimBackendFindings {
    param([Parameter(Mandatory)] [string]$ApimId, [Parameter(Mandatory)] [string]$ApiId, [Parameter(Mandatory)] [Collections.IDictionary]$Backend, [Parameter(Mandatory)] [scriptblock]$Arm, [hashtable]$Detail)
    $problems = [Collections.Generic.List[string]]::new(); $id = [string]$Backend['id']
    $entity = $null
    try { $entity = & $Arm "$ApimId/backends/$id`?api-version=2024-05-01" } catch { $problems.Add("apim_backend_missing: $ApimId has no backend $id ($($_.Exception.Message)).") }
    $expectedUrl = ([string]$Backend['url']).TrimEnd('/')
    if ($entity -and ([string]$entity.properties.url).TrimEnd('/') -cne $expectedUrl) { $problems.Add("apim_backend_url: $ApimId backend $id url is $($entity.properties.url), expected $expectedUrl.") }
    $eff = Get-CicdApimEffectivePolicy -ApimId $ApimId -ApiId $ApiId -Arm $Arm
    foreach ($p in $eff.problems) { $problems.Add($p) }
    $route = $null
    if ($null -ne $eff.text) {
        $geo = $Backend['deploymentInferenceGeo']; if ($geo -isnot [Collections.IDictionary]) { $geo = $null }
        $route = Get-CicdPolicyRouting -Policy $eff.text -Id $id -InferenceGeo $geo
        foreach ($p in $route.problems) { $problems.Add($p) }
    }
    if ($null -ne $Detail) { $Detail.routing = $route.routing; $Detail.fragments = @($eff.fragments); $Detail.warnings = @($route.warnings) }
    return @(foreach ($p in $problems) { $p })
}
# The command for one onboarding workflow step (.github/workflows/onboard-foundry.yml). Only these steps
# exist: Stage 7 (code, seed, client) and Stage 8 are never part of onboarding, and standby phases other
# than Backends and Verify are refused. Returns @{ File; Arguments; Mode; Log }.
function Get-CicdOnboardingCommand {
    param(
        [Parameter(Mandatory)] [ValidateSet('validate', 'stage3', 'stage5', 'stage6', 'standby-backends', 'standby-verify', 'frontdoor-verify', 'descriptor', 'smoke')] [string]$Step,
        [Parameter(Mandatory)] [string]$Environment,
        [Parameter(Mandatory)] [string]$RepoRoot,
        [switch]$Apply,
        [string[]]$BackendIds = @(),
        [string]$BaseConfigPath,
        [switch]$RequirePrivateLink,
        [string]$ApplyPrincipalId,
        [switch]$Offline
    )
    if ($Environment -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') { throw "invalid environment '$Environment'" }
    $ids = @($BackendIds | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($id in $ids) { if ($id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,78}[A-Za-z0-9]$') { throw "invalid backend id '$id'" } }
    $dir = Join-Path $RepoRoot "deploy/$Environment"
    $cfg = Join-Path $dir 'staged.config.json'; $dr = Join-Path $dir 'dr-standby.config.json'
    $evidence = Join-Path $RepoRoot "evidence/$Environment"
    $mode = if ($Apply) { 'apply' } else { 'preview' }
    if ($Apply -and $Step -cnotin 'stage3', 'stage5', 'stage6', 'standby-backends', 'descriptor') { throw "$Step is read-only; -Apply is refused" }
    if ($Step -cin 'standby-backends', 'descriptor', 'smoke' -and -not $ids.Count) { throw "$Step needs backend ids" }
    if ($Offline -and $Step -cne 'validate') { throw 'only validate runs offline' }
    switch ($Step) {
        'validate' {
            if (-not $BaseConfigPath -and -not $ids.Count) { throw 'validate needs a base configuration or backend ids' }
            $file = Join-Path $RepoRoot 'scripts/cicd/Test-CicdBackendOnboarding.ps1'
            # Offline: pull request checks on a GitHub-hosted runner (no Azure, no driver state, no private DNS).
            $a = @('-ConfigPath', $cfg, '-EvidencePath', (Join-Path $evidence 'onboard-validate.json'))
            $a += if ($Offline) { @('-SkipAzure') } else { @('-ResolveDns') }
            if ($BaseConfigPath) { $a += @('-BaseConfigPath', $BaseConfigPath) }
            if ($ids.Count) { $a += @('-BackendIds', ($ids -join ',')) }
            if ($RequirePrivateLink) { $a += '-RequirePrivateLink' }
            if ($ApplyPrincipalId) { $a += @('-ApplyPrincipalId', $ApplyPrincipalId) }
        }
        { $_ -cin 'stage3', 'stage5', 'stage6' } {
            $file = Join-Path $RepoRoot 'infra/staged/Invoke-StagedDeployment.ps1'
            $a = @('-Stage', $Step.Substring(5), '-ConfigPath', $cfg)
        }
        'standby-backends' {
            $file = Join-Path $RepoRoot 'infra/dr/Invoke-DrStandby.ps1'
            $a = @('-Phase', 'Backends', '-ConfigPath', $dr, '-BackendIds', ($ids -join ','))
        }
        # Verify records verification in the standby state, so the workflow runs it in the apply job.
        'standby-verify' { $file = Join-Path $RepoRoot 'infra/dr/Invoke-DrStandby.ps1'; $a = @('-Phase', 'Verify', '-ConfigPath', $dr) }
        'frontdoor-verify' { $file = Join-Path $RepoRoot 'infra/dr/Invoke-DrFrontDoor.ps1'; $a = @('-Phase', 'Verify', '-ConfigPath', $dr) }
        'descriptor' {
            $file = Join-Path $RepoRoot 'scripts/cicd/Set-CicdBackendDescriptor.ps1'
            $a = @('-ConfigPath', $cfg, '-BackendIds', ($ids -join ','), '-EvidencePath', (Join-Path $evidence "onboard-descriptor-$mode.json"))
        }
        'smoke' {
            $file = Join-Path $RepoRoot 'scripts/cicd/Test-CicdBackendSmoke.ps1'
            $a = @('-ConfigPath', $cfg, '-BackendIds', ($ids -join ','), '-EvidencePath', (Join-Path $evidence 'onboard-smoke.json'))
        }
    }
    if ($Apply) { $a += '-Apply' }
    if ($Step -clike 'standby-*' -or $Step -ceq 'frontdoor-verify') { if (-not (Test-Path -LiteralPath $dr)) { throw "$Step needs $dr (region B)" } }
    return @{ File = $file; Arguments = $a; Mode = $mode; Log = (Join-Path $evidence "onboard-$Step-$mode.log") }
}

# What to undo, printed when an apply job fails (docs/runbooks/CICD-FOUNDRY-ONBOARDING.md, Rollback).
function Get-CicdOnboardingRollback {
    param([string]$Environment, [string[]]$BackendIds, [string[]]$Completed = @())
    $ids = $BackendIds -join ', '
    $done = if ($Completed.Count) { $Completed -join ', ' } else { 'none' }
    return @(
        "Onboarding of $ids in $Environment stopped. Completed apply steps: $done.",
        'Nothing is rolled back automatically. Every applied step is additive and safe to rerun: fix the cause and rerun the workflow.',
        'To withdraw the backend instead:',
        "1. Revert the deploy/$Environment/staged.config.json change by pull request so backends[] no longer lists $ids.",
        '2. From a runner shell (the pipeline only adds backends): rerun Stage 3 and Stage 5 for region A, and Invoke-DrStandby.ps1 -Phase Grants then Config for region B (-Phase Backends refuses removals). The policy is rendered without the id, so requests to it are refused.',
        "3. If the descriptor was created: set it to disabled in the admin console, or delete backends/$ids in Cosmos Data Explorer. The pipeline never deletes it.",
        '4. APIM backend entities and Cognitive Services User role assignments stay (deployments are incremental); remove them only if the Foundry owner asks.',
        '5. Restore readiness: Invoke-DrStandby.ps1 -Phase Verify, then Invoke-DrFrontDoor.ps1 -Phase Verify if Front Door is deployed.'
    )
}

# Whether a reviewer approval was enforced for this run in GitHub environment $Name (Assert-CicdApproval.ps1).
# $Environment: GET /repos/{repo}/environments/{name} ($null when it does not exist); $BranchPolicies: names and
# types from .../deployment-branch-policies; $Approvals: GET /repos/{repo}/actions/runs/{run}/approvals.
# Required reviewers on a private repository need GitHub Enterprise (Free, Pro and Team: public repositories
# only), so on those plans the rule is absent and this fails closed. The job token cannot read an organization's
# plan; the approval observed in this run for this environment is the per-run proof that GitHub enforced the
# review. Administrator bypass must be readable and false. GitHub creates a missing environment
# without protection when a job references it, so 'exists' alone is not enough. Returns @{ problems; warnings; approvers }.
function Get-CicdApprovalProblems {
    param([Parameter(Mandatory)] [string]$Name, $Environment, $BranchPolicies = @(), $Approvals = @(), [string]$Actor, [int]$RunAttempt = 1)
    $problems = [Collections.Generic.List[string]]::new(); $warnings = [Collections.Generic.List[string]]::new()
    $approvers = @()
    if (-not $Environment) {
        $problems.Add("environment_missing: GitHub environment '$Name' does not exist; create it with required reviewers")
        return @{ problems = @($problems); warnings = @($warnings); approvers = $approvers }
    }
    $rules = @($Environment.protection_rules | Where-Object { $_ })
    $reviewRule = @($rules | Where-Object { $_.type -ceq 'required_reviewers' -and @($_.reviewers | Where-Object { $_ }).Count -gt 0 }) | Select-Object -First 1
    if (-not $reviewRule) {
        $problems.Add("no_required_reviewers: '$Name' has no required reviewers. For a private repository they need GitHub Enterprise (on Free, Pro and Team plans they exist for public repositories only); the apply does not run without them")
    } elseif (-not $reviewRule.prevent_self_review) {
        $warnings.Add("self_review_allowed: enable 'Prevent self-review' on '$Name' so the person who starts the run cannot approve it")
    }
    $dbp = $Environment.deployment_branch_policy
    if (-not $dbp) {
        $problems.Add("no_branch_policy: '$Name' allows every branch; set deployment branches to the selected branch main only")
    } elseif ($dbp.protected_branches -or -not $dbp.custom_branch_policies) {
        $problems.Add("branch_policy_not_main_only: '$Name' must use selected branches with main as the only rule")
    } else {
        $names = @($BranchPolicies | Where-Object { $_ } | ForEach-Object { "$($_.type)`:$($_.name)" })
        if ($names.Count -ne 1 -or $names[0] -cne 'branch:main') { $problems.Add("branch_policy_not_main_only: '$Name' branch rules are [$($names -join ', ')]; expected [branch:main]") }
    }
    if ($Environment.PSObject.Properties['can_admins_bypass'] -and $Environment.can_admins_bypass -is [bool]) {
        if ($Environment.can_admins_bypass) { $problems.Add("admins_can_bypass: administrators can bypass the reviewers of '$Name', so a bypassed job runs without approval; turn off 'Allow administrators to bypass configured protection rules'") }
    } else {
        $problems.Add("admins_bypass_unreadable: can_admins_bypass of '$Name' is not readable as true/false; administrator bypass cannot be ruled out")
    }
    # The review history is per run, not per attempt: an approval of attempt 1 would also satisfy a rerun.
    if ($RunAttempt -gt 1) { $problems.Add("rerun_attempt: attempt $RunAttempt of this run cannot be bound to its own approval (the review history is per run); dispatch a new run instead of re-running") }
    $forEnv = @($Approvals | Where-Object { $_ -and @($_.environments | Where-Object { $_ -and $_.name -ceq $Name }).Count })
    $approved = @($forEnv | Where-Object { $_.state -ceq 'approved' })
    $approvers = @($approved | ForEach-Object { "$($_.user.login)" } | Sort-Object -Unique)
    if (@($forEnv | Where-Object { $_.state -ceq 'rejected' }).Count) { $problems.Add("rejected: a reviewer rejected '$Name' in this run") }
    elseif (-not $approved.Count) { $problems.Add("not_approved: this run has no reviewer approval for '$Name' (bypassed, or no reviewers)") }
    elseif ($approved.Count -gt 1) { $problems.Add("approval_not_unique: $($approved.Count) approvals of '$Name' in this run; only one job per run uses this environment, so this job cannot tell which approval is its own") }
    elseif ($Actor -and $approvers.Count -eq 1 -and $approvers[0] -ceq $Actor) { $warnings.Add("self_approved: '$Name' was approved by the run's own actor $Actor") }
    return @{ problems = @($problems); warnings = @($warnings); approvers = $approvers }
}

# An apply step in GitHub Actions needs the approval record written by Assert-CicdApproval.ps1 for this run
# attempt. Returns '' when it is valid, otherwise the reason.
function Test-CicdApprovalRecord {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Name, [string]$RunId, [string]$RunAttempt)
    if (-not (Test-Path -LiteralPath $Path)) { return "no approval record $Path (run scripts/cicd/Assert-CicdApproval.ps1 first)" }
    try { $r = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json } catch { return "approval record $Path is not JSON" }
    if ($r.verified -ne $true) { return "approval for '$Name' was not verified: $(@($r.problems) -join '; ')" }
    if ("$($r.environment)" -cne $Name -or "$($r.runId)" -cne $RunId -or "$($r.runAttempt)" -cne $RunAttempt) {
        return "approval record is for '$($r.environment)' run $($r.runId)/$($r.runAttempt), not '$Name' run $RunId/$RunAttempt"
    }
    return ''
}

Export-ModuleMember -Function Get-CicdOnboardingCommand, Get-CicdOnboardingRollback, Get-CicdBackendChange, Get-CicdBackendFieldProblems, Get-CicdBackendAzureFindings, Get-CicdStandbyCoverage, Get-CicdApimBackendFindings, Get-CicdJson, Test-CicdPrivateAddress, ConvertFrom-CicdArmBody, Invoke-CicdArmGet, Get-CicdApimEffectivePolicy, Get-CicdPolicyRouting, Get-CicdApprovalProblems, Test-CicdApprovalRecord
