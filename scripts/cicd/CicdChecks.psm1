# Read-only prerequisite checks for a CCOF environment deployed by .github/workflows/deploy-environment.yml
# (docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md). Every check returns one record:
#   id, area, title, status (pass | fail | manual), evidence (one line), source (file or Learn reference).
# All Azure reads go through Invoke-CicdAz, which tests replace with Set-CicdAzInvoker. Nothing is written.
Set-StrictMode -Version Latest

$script:AzInvoker = $null
$script:AzLauncher = $null
$script:RoleDefinitionCache = @{}
$script:Statuses = @('pass', 'fail', 'manual')

function Set-CicdAzInvoker { param([scriptblock]$Invoker) $script:AzInvoker = $Invoker; $script:RoleDefinitionCache = @{} }

# On Windows az is az.cmd, and cmd.exe splits an argument at & ( ) (for example "&$filter=" in a URL).
# Start the CLI's own Python directly, as az.cmd does, so arguments pass unchanged. Linux runners use az.
function Get-CicdAzLauncher {
    param([bool]$OnWindows = $IsWindows, [string]$AzCmdPath)
    if (-not $OnWindows) { return @('az') }
    if (-not $AzCmdPath) { $AzCmdPath = (Get-Command az.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    $python = if ($AzCmdPath) { Join-Path (Split-Path (Split-Path $AzCmdPath)) 'python.exe' } else { '' }
    if ($python -and (Test-Path -LiteralPath $python)) { return @($python, '-IBm', 'azure.cli') }
    return @('az')
}

# One az call. Returns @{ Ok; Data; Error }. Never throws for an Azure error: a check decides what it means.
function Invoke-CicdAz {
    param([string[]]$Arguments)
    if ($script:AzInvoker) { return & $script:AzInvoker $Arguments }
    $errFile = [IO.Path]::GetTempFileName()
    try {
        if (-not $script:AzLauncher) { $script:AzLauncher = @(Get-CicdAzLauncher) }
        $exe, $pre = $script:AzLauncher[0], @($script:AzLauncher | Select-Object -Skip 1)
        $out = & $exe @pre @Arguments --output json --only-show-errors 2>$errFile
        $code = $LASTEXITCODE
        $err = (Get-Content -LiteralPath $errFile -Raw) ?? ''
    } finally { Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue }
    if ($code -ne 0) { return @{ Ok = $false; Data = $null; Error = ($err.Trim() -replace '\s+', ' ') } }
    $text = ($out -join "`n").Trim()
    $data = if ($text) { $text | ConvertFrom-Json -AsHashtable -Depth 100 } else { $null }
    return @{ Ok = $true; Data = $data; Error = '' }
}

function Invoke-CicdArmGet { param([string]$Path, [string]$ApiVersion)
    Invoke-CicdAz @('rest', '--method', 'get', '--url', "https://management.azure.com$Path`?api-version=$ApiVersion")
}

function New-CicdCheck {
    param([string]$Id, [string]$Area, [string]$Title, [string]$Status, [string]$Evidence, [string]$Source)
    if ($Status -cnotin $script:Statuses) { throw "check $Id has invalid status '$Status'" }
    if (-not $Evidence) { throw "check $Id has no evidence" }
    [ordered]@{ id = $Id; area = $Area; title = $Title; status = $Status; evidence = ($Evidence -replace '\s+', ' ').Trim(); source = $Source }
}

function Get-CicdValue {
    param($Object, [string]$Path)
    $cur = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [Collections.IDictionary]) { $cur = if ($cur.Contains($part)) { $cur[$part] } else { $null } }
        else { $p = $cur.PSObject.Properties[$part]; $cur = if ($p) { $p.Value } else { $null } }
    }
    return $cur
}

function Test-CicdDenied { param([string]$Text) return $Text -match 'AuthorizationFailed|Authorization_RequestDenied|Forbidden|\(403\)|does not have authorization|Insufficient privileges' }
function Test-CicdNotFound { param([string]$Text) return $Text -match 'NotFound|could not be found|\(404\)|was not found|does not exist' }

function Get-CicdAzReason { param([string]$Text)
    if (Test-CicdDenied $Text) { return "read denied: $($Text.Substring(0, [Math]::Min(160, $Text.Length)))" }
    if (Test-CicdNotFound $Text) { return 'not found' }
    return $Text.Substring(0, [Math]::Min(200, $Text.Length))
}

# JSON paths whose string value still contains REPLACE- (the example files' placeholders).
function Find-CicdPlaceholders {
    param($Object, [string]$Prefix = '', [Collections.Generic.List[string]]$Found)
    $top = -not $Found
    if ($top) { $Found = [Collections.Generic.List[string]]::new() }
    if ($Object -is [string]) { if ($Object -match 'REPLACE-') { $Found.Add($Prefix) } }
    elseif ($Object -is [Collections.IDictionary]) { foreach ($k in $Object.Keys) { Find-CicdPlaceholders $Object[$k] $(if ($Prefix) { "$Prefix.$k" } else { "$k" }) $Found } }
    elseif ($Object -is [Collections.IEnumerable]) { $i = 0; foreach ($v in $Object) { Find-CicdPlaceholders $v "$Prefix[$i]" $Found; $i++ } }
    if ($top) { return [string[]]$Found.ToArray() }
}

# ---------------------------------------------------------------- identity and roles

# The signed-in identity's object ID from the ARM access token's oid claim (no Microsoft Graph call).
# The token itself is never printed or returned.
function Get-CicdSignedInIdentity {
    $acct = Invoke-CicdAz @('account', 'show')
    if (-not $acct.Ok) { return @{ Ok = $false; Error = $acct.Error } }
    $tok = Invoke-CicdAz @('account', 'get-access-token', '--resource', 'https://management.azure.com/')
    $oid = $null
    if ($tok.Ok -and $tok.Data.accessToken) {
        $payload = ($tok.Data.accessToken -split '\.')[1].Replace('-', '+').Replace('_', '/')
        $payload += '=' * ((4 - $payload.Length % 4) % 4)
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
        $oid = $claims.oid
    }
    return @{ Ok = $true; TenantId = $acct.Data.tenantId; SubscriptionId = $acct.Data.id; Name = $acct.Data.user.name; Type = $acct.Data.user.type; ObjectId = $oid }
}

function Test-CicdActionGranted {
    param([string]$Action, [string[]]$Actions, [string[]]$NotActions)
    $granted = @($Actions | Where-Object { $Action -like $_ }).Count -gt 0
    $denied = @($NotActions | Where-Object { $Action -like $_ }).Count -gt 0
    return $granted -and -not $denied
}

function Get-CicdRoleDefinition { param([string]$RoleDefinitionId)
    if ($script:RoleDefinitionCache.ContainsKey($RoleDefinitionId)) { return $script:RoleDefinitionCache[$RoleDefinitionId] }
    $r = Invoke-CicdArmGet $RoleDefinitionId '2022-04-01'
    $def = if ($r.Ok) { $r.Data } else { $null }
    $script:RoleDefinitionCache[$RoleDefinitionId] = $def
    return $def
}

# Required actions at a scope, evaluated against every role assignment of the principal in that
# subscription (assignedTo includes group-inherited assignments), using each role's actions/notActions.
function Test-CicdScopeActions {
    param([string]$Id, [string]$Title, [string]$ObjectId, [string]$Scope, [string[]]$RequiredActions, [string]$Source)
    if (-not $ObjectId) { return New-CicdCheck $Id 'access' $Title 'manual' 'signed-in object ID unreadable from the token; confirm the role assignments in the Portal' $Source }
    $sub = ($Scope -split '/')[2]
    $list = Invoke-CicdArmGet "/subscriptions/$sub/providers/Microsoft.Authorization/roleAssignments" "2022-04-01&`$filter=assignedTo('$ObjectId')"
    if (-not $list.Ok) { return New-CicdCheck $Id 'access' $Title 'manual' "role assignments unreadable ($(Get-CicdAzReason $list.Error)); confirm in the Portal: $($RequiredActions -join ', ') at $Scope" $Source }
    $applicable = @($list.Data.value | Where-Object { $Scope.ToLowerInvariant().StartsWith(([string]$_.properties.scope).ToLowerInvariant().TrimEnd('/')) })
    # notActions subtract only from their own permission block; an action is held when any block grants it.
    $blocks = [Collections.Generic.List[object]]::new(); $roles = [Collections.Generic.List[string]]::new()
    foreach ($a in $applicable) {
        $def = Get-CicdRoleDefinition $a.properties.roleDefinitionId
        if (-not $def) { continue }
        $roles.Add("$($def.properties.roleName)@$(($a.properties.scope -split '/')[-1])")
        foreach ($p in @($def.properties.permissions)) { $blocks.Add($p) }
    }
    $missing = @($RequiredActions | Where-Object { $act = $_; -not @($blocks | Where-Object { Test-CicdActionGranted $act @($_.actions) @($_.notActions) }).Count })
    $held = if ($roles.Count) { $roles -join ', ' } else { 'none' }
    if ($missing.Count) { return New-CicdCheck $Id 'access' $Title 'fail' "missing $($missing -join ', ') at $Scope; roles held: $held" $Source }
    return New-CicdCheck $Id 'access' $Title 'pass' "roles held: $held" $Source
}

# ---------------------------------------------------------------- subscription-level checks

function Test-CicdProviders {
    param([string]$SubscriptionId, [string[]]$Namespaces)
    $r = Invoke-CicdAz @('provider', 'list', '--subscription', $SubscriptionId, '--query', '[].{ns:namespace,state:registrationState}')
    $src = 'infra/staged/Staged.Resources.ps1 Invoke-Stage0; https://learn.microsoft.com/azure/azure-resource-manager/management/resource-providers-and-types'
    if (-not $r.Ok) { return @(New-CicdCheck "providers.$SubscriptionId" 'subscription' "Resource providers in $SubscriptionId" 'fail' "provider list failed: $(Get-CicdAzReason $r.Error)" $src) }
    $out = foreach ($ns in $Namespaces) {
        $state = [string](@($r.Data | Where-Object { $_.ns -ieq $ns })[0] ?? @{ state = 'absent' }).state
        New-CicdCheck "providers.$ns" 'subscription' "Provider $ns registered" $(if ($state -ceq 'Registered') { 'pass' } else { 'fail' }) "$ns is $state in $SubscriptionId" $src
    }
    return @($out)
}

function Test-CicdRegionOffers {
    param([string]$SubscriptionId, [string]$Location, [string]$Label, [switch]$Cosmos, [switch]$Flex, [switch]$Apim)
    $norm = { param($x) ([string]$x).Replace(' ', '').ToLowerInvariant() }
    $want = & $norm $Location
    $out = [Collections.Generic.List[object]]::new()
    if ($Flex) {
        $r = Invoke-CicdAz @('functionapp', 'list-flexconsumption-locations', '--subscription', $SubscriptionId)
        $ok = $r.Ok -and (@($r.Data | ForEach-Object { & $norm $_.name }) -contains $want)
        $out.Add((New-CicdCheck "region.flex.$Label" 'quota' "Flex Consumption offered in $Location" $(if ($ok) { 'pass' } elseif ($r.Ok) { 'fail' } else { 'manual' }) $(if ($r.Ok) { "$Location $(if ($ok) { 'is' } else { 'is not' }) in list-flexconsumption-locations" } else { Get-CicdAzReason $r.Error }) 'https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to'))
    }
    if ($Apim) {
        $r = Invoke-CicdAz @('provider', 'show', '--namespace', 'Microsoft.ApiManagement', '--subscription', $SubscriptionId, '--query', "resourceTypes[?resourceType=='service'].locations | [0]")
        $ok = $r.Ok -and (@($r.Data | ForEach-Object { & $norm $_ }) -contains $want)
        $out.Add((New-CicdCheck "region.apim.$Label" 'quota' "API Management offered in $Location" $(if ($ok) { 'pass' } elseif ($r.Ok) { 'fail' } else { 'manual' }) $(if ($r.Ok) { "Microsoft.ApiManagement/service $(if ($ok) { 'lists' } else { 'does not list' }) $Location" } else { Get-CicdAzReason $r.Error }) 'https://learn.microsoft.com/azure/api-management/api-management-region-availability'))
        $out.Add((New-CicdCheck "quota.apim.$Label" 'quota' "API Management v2 capacity in $Location" 'manual' 'no quota API for API Management units; confirm StandardV2 capacity in the region with the subscription owner (Stage 1 or Shells fails on capacity)' 'https://learn.microsoft.com/azure/api-management/v2-service-tiers-overview'))
    }
    if ($Cosmos) {
        $r = Invoke-CicdAz @('cosmosdb', 'locations', 'show', '--location', $Location, '--subscription', $SubscriptionId)
        $allowed = if ($r.Ok) { Get-CicdValue $r.Data 'properties.isSubscriptionRegionAccessAllowedForRegular' } else { $null }
        $status = if (-not $r.Ok) { 'manual' } elseif ($allowed -eq $true) { 'pass' } else { 'fail' }
        $out.Add((New-CicdCheck "region.cosmos.$Label" 'quota' "Cosmos DB regional access in $Location" $status $(if ($r.Ok) { "isSubscriptionRegionAccessAllowedForRegular=$allowed" } else { Get-CicdAzReason $r.Error }) 'https://learn.microsoft.com/azure/cosmos-db/high-availability'))
    }
    return $out.ToArray()
}

function Test-CicdResourceGroup {
    param([string]$SubscriptionId, [string]$ResourceGroup)
    $r = Invoke-CicdAz @('group', 'show', '--subscription', $SubscriptionId, '--name', $ResourceGroup)
    $src = 'docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md#2-prerequisites'
    if ($r.Ok) { return New-CicdCheck 'access.resource-group' 'access' "Resource group $ResourceGroup" 'pass' "exists in $($r.Data.location)" $src }
    if (Test-CicdNotFound $r.Error) { return New-CicdCheck 'access.resource-group' 'access' "Resource group $ResourceGroup" 'fail' 'not found; the subscription owner creates it (the pipeline creates no resource group)' $src }
    return New-CicdCheck 'access.resource-group' 'access' "Resource group $ResourceGroup" 'fail' (Get-CicdAzReason $r.Error) $src
}

# ---------------------------------------------------------------- Foundry, Marketplace, Front Door, Entra

function Test-CicdFoundryBackends {
    param($Staged)
    $out = [Collections.Generic.List[object]]::new()
    foreach ($b in @($Staged.backends)) {
        $id = "/subscriptions/$($b.subscriptionId)/resourceGroups/$($b.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($b.accountName)"
        $want = @(@($b.deploymentInferenceGeo.Keys) | Sort-Object)
        if ((Get-CicdValue $Staged 'stage1.foundry.create') -and $b.accountName -ceq (Get-CicdValue $Staged 'stage1.foundry.accountName')) {
            $out.Add((New-CicdCheck "foundry.$($b.id)" 'foundry' "Foundry backend $($b.id)" 'manual' "account $($b.accountName) is created by Stage 1; Stage 0 checks the model offer; deployments $($want -join ', ')" 'infra/staged/Staged.Resources.ps1 Invoke-Stage0'))
            $out.Add((New-CicdCheck "marketplace.$($b.id)" 'foundry' "Marketplace terms for Claude models ($($b.id))" 'manual' 'Stage 1 creates the deployments; the subscription owner accepts the Anthropic Marketplace offer first (gate marketplace)' 'https://learn.microsoft.com/azure/ai-foundry/foundry-models/how-to/use-foundry-models-claude'))
            continue
        }
        $r = Invoke-CicdArmGet "$id/deployments" '2024-10-01'
        if (-not $r.Ok) { $out.Add((New-CicdCheck "foundry.$($b.id)" 'foundry' "Foundry backend $($b.id) deployments" $(if (Test-CicdDenied $r.Error) { 'manual' } else { 'fail' }) "$($b.accountName): $(Get-CicdAzReason $r.Error)" 'infra/staged/Staged.Resources.ps1 Invoke-Stage0')); continue }
        $have = @($r.Data.value | ForEach-Object { $_.name })
        $missing = @($want | Where-Object { $have -cnotcontains $_ })
        $out.Add((New-CicdCheck "foundry.$($b.id)" 'foundry' "Foundry backend $($b.id) deployments" $(if ($missing.Count) { 'fail' } else { 'pass' }) $(if ($missing.Count) { "$($b.accountName) lacks $($missing -join ', '); has $($have -join ', ')" } else { "$($b.accountName) has $($want -join ', ')" }) 'infra/staged/Staged.Resources.ps1 Invoke-Stage0'))
        $out.Add((New-CicdCheck "marketplace.$($b.id)" 'foundry' "Marketplace terms for Claude models ($($b.id))" $(if ($missing.Count) { 'manual' } else { 'pass' }) $(if ($missing.Count) { 'confirm the Anthropic Marketplace offer is accepted before the missing deployments are created' } else { 'the deployments exist, so the offer was accepted for that subscription' }) 'https://learn.microsoft.com/azure/ai-foundry/foundry-models/how-to/use-foundry-models-claude'))
    }
    $out.Add((New-CicdCheck 'quota.foundry' 'foundry' 'Claude model capacity' 'manual' 'Claude deployment capacity is not exposed through ARM usage for every subscription; confirm the capacity in the Foundry portal (Quota) against the expected tokens per minute' 'https://learn.microsoft.com/azure/ai-foundry/foundry-models/quotas-limits'))
    return $out.ToArray()
}

function Test-CicdFrontDoorInputs {
    param($Dr, [string]$StateDirectory)
    $fd = Get-CicdValue $Dr 'frontDoor'
    $src = 'docs/runbooks/DR-FRONT-DOOR.md'
    $out = [Collections.Generic.List[object]]::new()
    $stem = [string](Get-CicdValue $fd 'stem')
    $okStem = $stem -cmatch '^[a-z][a-z0-9-]{2,39}$'
    $out.Add((New-CicdCheck 'frontdoor.stem' 'frontdoor' 'Front Door stem' $(if ($okStem) { 'pass' } else { 'fail' }) "stem '$stem' $(if ($okStem) { 'is valid' } else { 'must be 3-40 lowercase letters, digits or -, starting with a letter' })" $src))
    $waf = [string](Get-CicdValue $fd 'wafMode')
    $okWaf = (-not $waf) -or $waf -cin @('Detection', 'Prevention')
    $out.Add((New-CicdCheck 'frontdoor.waf' 'frontdoor' 'WAF mode' $(if ($okWaf) { 'pass' } else { 'fail' }) "wafMode '$(if ($waf) { $waf } else { 'Detection (default)' })'" $src))
    if (-not $okStem) { return $out.ToArray() }
    $statePath = Join-Path $StateDirectory 'frontdoor-state.json'
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $out.Add((New-CicdCheck 'names.frontdoor-endpoint' 'names' "Front Door endpoint name $stem" 'pass' "owned by this deployment: saved state profile $(Get-CicdValue $state 'profileName') host $(Get-CicdValue $state 'endpointHostName')" 'infra/dr/Invoke-DrFrontDoor.ps1'))
        return $out.ToArray()
    }
    $sub = $Dr.subscriptionId; $rg = (Get-CicdValue $Dr 'secondary.resourceGroup')
    $body = (@{ name = $stem; type = 'Microsoft.Cdn/Profiles/AfdEndpoints'; autoGeneratedDomainNameLabelScope = 'TenantReuse' } | ConvertTo-Json -Compress)
    $r = Invoke-CicdAz @('rest', '--method', 'post', '--url', "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Cdn/checkEndpointNameAvailability?api-version=2024-02-01", '--body', $body)
    $status = if (-not $r.Ok) { 'manual' } elseif ($r.Data.nameAvailable -eq $true) { 'pass' } else { 'fail' }
    $ev = if ($r.Ok) { "nameAvailable=$($r.Data.nameAvailable) $($r.Data.message)" } else { "availability unreadable: $(Get-CicdAzReason $r.Error)" }
    $out.Add((New-CicdCheck 'names.frontdoor-endpoint' 'names' "Front Door endpoint name $stem" $status $ev 'https://learn.microsoft.com/rest/api/frontdoor/azurefrontdoorstandardpremium/check-endpoint-name-availability'))
    return $out.ToArray()
}

# Entra: the configured IDs must be GUIDs; a Graph GET is tried read-only and a denial means "verify manually".
function Test-CicdEntra {
    param($Staged, [switch]$Offline)
    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $out = [Collections.Generic.List[object]]::new()
    $src = 'infra/staged/Staged.Entra.ps1 Invoke-StgStage4Manual; docs/runbooks/CICD-NETWORK-ENTRA-CHECKLIST.md'
    $mv = Get-CicdValue $Staged 'entra.manualVerification'
    $out.Add((New-CicdCheck 'entra.manual-mode' 'entra' 'Entra manual mode (no Graph write by the pipeline)' $(if ($mv) { 'pass' } else { 'fail' }) $(if ($mv) { "entra.manualVerification confirmedBy '$(Get-CicdValue $mv 'confirmedBy')' on $(Get-CicdValue $mv 'confirmedOn')" } else { 'entra.manualVerification missing: Stage 4 would create or patch registrations through Graph; the pipeline refuses that' }) $src))
    $kinds = @('gatewayAppId', 'resolverAppId') + $(if ((Get-CicdValue $Staged 'stage1.includeAdmin') -ne $false) { @('adminAppId') } else { @() })
    $items = @(foreach ($k in $kinds) { @{ id = "entra.$k"; title = "App registration $k"; value = [string](Get-CicdValue $Staged "entra.existing.$k"); path = "applications(appId='{0}')?`$select=appId,displayName" } }) +
        @(foreach ($g in @($Staged.groups)) { @{ id = "entra.group.$($g.projectId)-$($g.classification)"; title = "Security group $($g.projectId)/$($g.classification)"; value = [string](Get-CicdValue $g 'groupId'); path = 'groups/{0}?$select=id,displayName,securityEnabled' } })
    foreach ($i in $items) {
        if ($i.value -notmatch $guid) { $out.Add((New-CicdCheck $i.id 'entra' $i.title 'fail' "configured value '$($i.value)' is not a GUID" $src)); continue }
        if ($Offline) { $out.Add((New-CicdCheck $i.id 'entra' $i.title 'manual' "$($i.value): offline run, not read" $src)); continue }
        $r = Invoke-CicdAz @('rest', '--method', 'get', '--url', ("https://graph.microsoft.com/v1.0/" + ($i.path -f $i.value)))
        if ($r.Ok) {
            $bad = $i.id -like 'entra.group.*' -and $r.Data.securityEnabled -ne $true
            $out.Add((New-CicdCheck $i.id 'entra' $i.title $(if ($bad) { 'fail' } else { 'pass' }) "Graph GET: $($r.Data.displayName)$(if ($bad) { ' is not a security group' })" $src))
        } elseif ((Test-CicdNotFound $r.Error) -and -not (Test-CicdDenied $r.Error)) { $out.Add((New-CicdCheck $i.id 'entra' $i.title 'fail' "Graph GET: $($i.value) not found in the tenant" $src)) }
        else { $out.Add((New-CicdCheck $i.id 'entra' $i.title 'manual' "$($i.value): Graph read not available to this identity ($(Get-CicdAzReason $r.Error)); the Entra team confirms it" $src)) }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------- report

function Get-CicdSummary { param([object[]]$Checks)
    [ordered]@{ pass = @($Checks | Where-Object { $_.status -eq 'pass' }).Count; fail = @($Checks | Where-Object { $_.status -eq 'fail' }).Count; manual = @($Checks | Where-Object { $_.status -eq 'manual' }).Count }
}

function ConvertTo-CicdMarkdown {
    param([object[]]$Checks, [string]$Title)
    $s = Get-CicdSummary $Checks
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("## $Title"); $lines.Add(''); $lines.Add("pass $($s.pass), fail $($s.fail), manual $($s.manual)"); $lines.Add('')
    $lines.Add('| Status | Check | Evidence | Source |'); $lines.Add('| --- | --- | --- | --- |')
    $icon = @{ pass = 'PASS'; fail = '**FAIL**'; manual = '[ ] MANUAL' }
    $order = @('fail', 'manual', 'pass')
    foreach ($c in @($Checks | Sort-Object @{ e = { $order.IndexOf($_.status) } }, @{ e = { $_.area } }, @{ e = { $_.id } })) {
        $cell = { param($t) ([string]$t).Replace('|', '\|') }
        $lines.Add("| $($icon[$c.status]) | $(& $cell $c.title) (``$($c.id)``) | $(& $cell $c.evidence) | $(& $cell $c.source) |")
    }
    return ($lines -join "`n") + "`n"
}

Export-ModuleMember -Function Set-CicdAzInvoker, Get-CicdAzLauncher, Invoke-CicdAz, Invoke-CicdArmGet, New-CicdCheck, Get-CicdValue, Test-CicdDenied, Test-CicdNotFound,
    Get-CicdAzReason, Find-CicdPlaceholders, Get-CicdSignedInIdentity, Test-CicdActionGranted, Test-CicdScopeActions, Test-CicdProviders,
    Test-CicdRegionOffers, Test-CicdResourceGroup, Test-CicdFoundryBackends, Test-CicdFrontDoorInputs, Test-CicdEntra, Get-CicdSummary, ConvertTo-CicdMarkdown
