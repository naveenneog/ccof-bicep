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

# Smoke checks after apply: the APIM backend entity (Stage 5 apim-api.bicep, name = backend id) and the
# policy, whose %%BACKEND_IDS%% list holds the id in double quotes, in one region.
function Get-CicdApimBackendFindings {
    param([Parameter(Mandatory)] [string]$ApimId, [Parameter(Mandatory)] [string]$ApiId, [Parameter(Mandatory)] [Collections.IDictionary]$Backend, [Parameter(Mandatory)] [scriptblock]$Arm)
    $problems = [Collections.Generic.List[string]]::new(); $id = [string]$Backend['id']
    $entity = $null
    try { $entity = & $Arm "$ApimId/backends/$id`?api-version=2024-05-01" } catch { $problems.Add("apim_backend_missing: $ApimId has no backend $id ($($_.Exception.Message)).") }
    $expectedUrl = ([string]$Backend['url']).TrimEnd('/')
    if ($entity -and ([string]$entity.properties.url).TrimEnd('/') -cne $expectedUrl) { $problems.Add("apim_backend_url: $ApimId backend $id url is $($entity.properties.url), expected $expectedUrl.") }
    $policy = $null
    try { $policy = [string](& $Arm "$ApimId/apis/$ApiId/policies/policy?api-version=2024-05-01").properties.value } catch { $problems.Add("apim_policy_unreadable: $ApimId api $ApiId ($($_.Exception.Message)).") }
    if ($null -ne $policy -and -not $policy.Contains("""$id""")) { $problems.Add("apim_policy_backend: the $ApiId policy on $ApimId does not name backend $id.") }
    return @(foreach ($p in $problems) { $p })
}

Export-ModuleMember -Function Get-CicdBackendChange, Get-CicdBackendFieldProblems, Get-CicdBackendAzureFindings, Get-CicdStandbyCoverage, Get-CicdApimBackendFindings, Get-CicdJson, Test-CicdPrivateAddress
