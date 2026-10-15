#Requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Decisions.psm1')
Import-Module (Join-Path $PSScriptRoot 'StagePrecondition.psm1')

function Assert-OnboardingGuid {
    param([string]$Value)
    if ($Value -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        Stop-Onboarding 'A supplied or discovered object/subscription id is not a GUID.'
    }
}

function Assert-OnboardingAzArguments {
    param([string[]]$Arguments)
    foreach ($argument in $Arguments) {
        if ($argument -match '["''()%&|<>^`\r\n]') { Stop-Onboarding 'Azure CLI arguments contain a forbidden command-shell character.' }
    }
    $index = [array]::IndexOf($Arguments, '--subscription')
    if ($index -lt 0 -or $index + 1 -ge $Arguments.Count) { Stop-Onboarding 'Every Azure CLI operation requires an explicit --subscription.' }
    Assert-OnboardingGuid $Arguments[$index + 1]
}

function Invoke-OnboardingAzJson {
    param([string[]]$Arguments)
    Assert-OnboardingAzArguments $Arguments
    $raw = & az @Arguments --only-show-errors -o json 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI operation failed. Verify the selected subscription and signed-in access.' }
    $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function Get-OnboardingToken {
    param([string]$SubscriptionId, [string]$Resource)
    $token = Invoke-OnboardingAzJson @('account','get-access-token','--subscription',$SubscriptionId,'--resource',$Resource)
    if (-not $token.accessToken) { throw 'Azure CLI returned no access token.' }
    return $token.accessToken
}

function Get-OnboardingIdentity {
    param([string]$SubscriptionId)
    $token = Get-OnboardingToken $SubscriptionId 'https://management.azure.com/'
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight([int]([Math]::Ceiling($payload.Length / 4.0) * 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    Assert-OnboardingGuid $claims.oid
    Assert-OnboardingGuid $claims.tid
    @{ objectId = $claims.oid; tenantId = $claims.tid }
}

function Assert-OnboardingProviderUri {
    param([string]$Url)
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or
        $uri.UserInfo -or -not $uri.IsDefaultPort -or $uri.Fragment -or
        $uri.Host -notin @('graph.microsoft.com','management.azure.com')) {
        Stop-Onboarding 'The provider URI must be HTTPS on graph.microsoft.com or management.azure.com with no credentials, fragment or custom port.'
    }
}

function Invoke-OnboardingRest {
    param([string]$SubscriptionId, [string]$Method, [string]$Url, $Body)
    Assert-OnboardingProviderUri $Url
    $resource = if (([uri]$Url).Host -eq 'graph.microsoft.com') { 'https://graph.microsoft.com/' } else { 'https://management.azure.com/' }
    $token = Get-OnboardingToken $SubscriptionId $resource
    $args = @{
        Uri = $Url; Method = $Method; Headers = @{ Authorization = "Bearer $token" }
        MaximumRedirection = 0; SkipHttpErrorCheck = $true; ErrorAction = 'Stop'
    }
    if ($null -ne $Body) { $args.Body = ConvertTo-Json -InputObject $Body -Depth 64 -Compress; $args.ContentType = 'application/json' }
    try { $response = Invoke-WebRequest @args }
    catch { throw 'Provider transport failed. Verify private routing and provider health.' }
    if ($response.StatusCode -eq 404 -and $Method -eq 'GET') { return $null }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "Provider request failed (HTTP $($response.StatusCode))." }
    if ($response.Content) { ([string]$response.Content).TrimStart([char]0xfeff) | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
}

function Get-OnboardingPages {
    param([string]$Url, [scriptblock]$Send)
    Assert-OnboardingProviderUri $Url
    $hostName = ([uri]$Url).Host
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($Url) {
        Assert-OnboardingProviderUri $Url
        if (-not [string]::Equals(([uri]$Url).Host, $hostName, 'Ordinal') -or -not $visited.Add($Url)) {
            Stop-Onboarding 'Provider pagination changed host or repeated a page.'
        }
        $page = & $Send 'GET' $Url $null
        if ($null -eq $page -or -not $page.Contains('value')) { throw 'Provider returned an incomplete collection.' }
        foreach ($item in $page.value) { $item }
        $Url = $page.'@odata.nextLink'
        if (-not $Url) { $Url = $page.nextLink }
    }
}

function Assert-OnboardingRole {
    param($Context, [string]$Scope, [string[]]$Roles, [scriptblock]$GetCurrentAssignments, [string]$Kind = 'azure')
    if (-not $GetCurrentAssignments) {
        $GetCurrentAssignments = {
            param($scope, $kind, $context)
            if ($kind -eq 'directory') {
                $send = { param($m,$u,$b) Invoke-OnboardingRest $context.Decisions.subscriptionId $m $u $b }.GetNewClosure()
                Get-OnboardingPages -Url 'https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole' -Send $send |
                    ForEach-Object { @{ roleDefinitionName = $_.displayName } }
            }
            elseif ($kind -eq 'cosmos') {
                Get-OnboardingCosmosRoles -Context $context -Scope $scope
            }
            else {
                $subscription = if ($scope -match '^/subscriptions/([^/]+)') { $Matches[1] } else { $context.Decisions.subscriptionId }
                $arguments=@('role','assignment','list','--subscription',$subscription,
                    '--assignee-object-id',$context.Actor.objectId,'--scope',$scope,'--include-inherited',
                    '--fill-principal-name','false')
                if(-not $context.RequireGraphFreeAzureRoleLookup){$arguments+='--include-groups'}
                Invoke-OnboardingAzJson $arguments | Where-Object { -not $_.condition }
            }
        }
    }
    $lookup = { param($s) & $GetCurrentAssignments $s $Kind $Context }.GetNewClosure()
    $result = Test-StageRolePrecondition -Scope $Scope -AcceptableRoles $Roles -GetCurrentAssignments $lookup
    if (-not $result.Satisfied) { Stop-Onboarding $result.Remedy }
}

function New-OnboardingGraphOperations {
    param([string]$SubscriptionId, [scriptblock]$Send)
    Assert-OnboardingGuid $SubscriptionId
    if (-not $Send) { $Send = { param($m,$u,$b) Invoke-OnboardingRest $SubscriptionId $m $u $b }.GetNewClosure() }
    @{
        GetCreationPolicy = {
            & $Send 'GET' 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' $null
        }.GetNewClosure()
        FindGroups = {
            param($name)
            $filter = [uri]::EscapeDataString("displayName eq '$($name.Replace("'", "''"))'")
            $url = 'https://graph.microsoft.com/v1.0/groups?$filter=' + $filter + '&$select=id,displayName,mailNickname,securityEnabled,mailEnabled,groupTypes,isAssignableToRole'
            Get-OnboardingPages -Url $url -Send $Send
        }.GetNewClosure()
        GetGroup = {
            param($id)
            Assert-OnboardingGuid $id
            & $Send 'GET' "https://graph.microsoft.com/v1.0/groups/$id`?`$select=id,displayName,mailNickname,securityEnabled,mailEnabled,groupTypes,isAssignableToRole" $null
        }.GetNewClosure()
        GetPrincipal = {
            param($id)
            Assert-OnboardingGuid $id
            $user = & $Send 'GET' "https://graph.microsoft.com/v1.0/users/$id`?`$select=id,accountEnabled,userType" $null
            if ($user) { $user['@odata.type'] = '#microsoft.graph.user' }
            return $user
        }.GetNewClosure()
        GetOwners = {
            param($id)
            Assert-OnboardingGuid $id
            Get-OnboardingPages -Url "https://graph.microsoft.com/v1.0/groups/$id/owners" -Send $Send | ForEach-Object { $_.id }
        }.GetNewClosure()
        GetMembers = {
            param($id)
            Assert-OnboardingGuid $id
            Get-OnboardingPages -Url "https://graph.microsoft.com/v1.0/groups/$id/members" -Send $Send
        }.GetNewClosure()
        CreateGroup = {
            param($spec)
            & $Send 'POST' 'https://graph.microsoft.com/v1.0/groups' @{
                displayName = $spec.groupName; mailNickname = $spec.mailNickname
                securityEnabled = $true; mailEnabled = $false; groupTypes = @()
            }
        }.GetNewClosure()
        AddOwner = {
            param($groupId, $ownerId)
            Assert-OnboardingGuid $groupId; Assert-OnboardingGuid $ownerId
            try {
                & $Send 'POST' "https://graph.microsoft.com/v1.0/groups/$groupId/owners/`$ref" @{
                    '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$ownerId"
                } | Out-Null
            }
            catch {
                $current = @(Get-OnboardingPages -Url "https://graph.microsoft.com/v1.0/groups/$groupId/owners" -Send $Send)
                if (-not @($current | Where-Object { [string]::Equals($_.id, $ownerId, 'Ordinal') }).Count) { throw }
            }
        }.GetNewClosure()
    }
}
Export-ModuleMember -Function Assert-OnboardingGuid, Assert-OnboardingAzArguments, Invoke-OnboardingAzJson, Get-OnboardingToken, Get-OnboardingIdentity, Assert-OnboardingProviderUri, Invoke-OnboardingRest, Get-OnboardingPages, Assert-OnboardingRole, New-OnboardingGraphOperations
