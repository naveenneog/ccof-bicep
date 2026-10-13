#Requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Azure.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Decisions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Schemas.psm1')

function Test-OnboardingPrivateAddress {
    param([string]$Address)
    $ip=$null
    if (-not [Net.IPAddress]::TryParse($Address,[ref]$ip)) { return $false }
    $b=$ip.GetAddressBytes()
    if ($b.Length -eq 16) { return ($b[0] -band 254) -eq 252 }
    return $b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168)
}

# ARM returns documentEndpoint with the default port (https://<account>.documents.azure.com:443/),
# and the answers schema allows no port, so endpoints compare as scheme, host and effective port.
# Anything other than a bare https origin (whitespace, user info, path, query, fragment) has no
# canonical form: [uri] would silently trim whitespace that the schema pattern lets through.
function ConvertTo-OnboardingCosmosOrigin {
    param([string]$Endpoint)
    $uri=$null
    if ($Endpoint -match '\s' -or -not [uri]::TryCreate($Endpoint,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or
        $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) { return $null }
    "https://$($uri.Host):$($uri.Port)"
}

function Assert-OnboardingPrivateRegistry {
    param([hashtable]$Registry, [hashtable]$Operations)
    Assert-OnboardingSchema $Registry (Get-OnboardingRegistrySchema)
    $account=& $Operations.GetRegistryAccount
    $discovered=ConvertTo-OnboardingCosmosOrigin ([string]$account.properties.documentEndpoint)
    if (-not [string]::Equals($account.id,$Registry.accountResourceId,'Ordinal') -or
        -not $discovered -or -not [string]::Equals($discovered,(ConvertTo-OnboardingCosmosOrigin $Registry.endpoint),'Ordinal') -or
        $account.properties.publicNetworkAccess -ne 'Disabled') {
        Stop-Onboarding 'The selected registry must match the discovered Cosmos endpoint with public network access Disabled.'
    }
    $addresses=@(& $Operations.GetPrivateAddresses)
    if ($addresses.Count -eq 0 -or @($addresses|Where-Object{-not (Test-OnboardingPrivateAddress $_)}).Count) {
        Stop-Onboarding 'Cosmos is private. This stage needs an in-VNet runner and private-endpoint DNS; every resolved address must be private.'
    }
    @{endpoint=$Registry.endpoint;database=$Registry.database;addresses=$addresses}
}

function Get-OnboardingCosmosRoles {
    param($Context,[string]$Scope,[scriptblock]$Send)
    $registry=$Context.Decisions.registry; $accountId=$registry.accountResourceId
    if (-not $Send) {
        $sub=($accountId -split '/')[2]
        $Send={param($m,$u,$b) Invoke-OnboardingRest $sub $m $u $b}.GetNewClosure()
    }
    $assignments=@(Get-OnboardingPages "https://management.azure.com$accountId/sqlRoleAssignments?api-version=2024-05-15" $Send)
    $definitions=@(Get-OnboardingPages "https://management.azure.com$accountId/sqlRoleDefinitions?api-version=2024-05-15" $Send)
    $wanted=$Scope.Substring($accountId.Length)
    $actions=[Collections.Generic.List[string]]::new()
    foreach ($assignment in $assignments) {
        if (-not [string]::Equals($assignment.properties.principalId,$Context.Actor.objectId,'Ordinal')) { continue }
        $assigned=[string]$assignment.properties.scope
        if ($assigned.StartsWith($accountId,'Ordinal')) { $assigned=$assigned.Substring($accountId.Length) }
        if ($assigned -ne '/' -and -not [string]::Equals($assigned,$wanted,'Ordinal') -and -not $wanted.StartsWith("$assigned/",'Ordinal')) { continue }
        $definition=@($definitions|Where-Object{[string]::Equals($_.id,$assignment.properties.roleDefinitionId,'Ordinal')})
        foreach ($permission in $definition.properties.permissions) {
            foreach ($action in $permission.dataActions) { $actions.Add($action) }
        }
    }
    function HasAction([string]$name) {
        foreach ($pattern in $actions) {
            if ([Management.Automation.WildcardPattern]::new($pattern,'IgnoreCase').IsMatch($name)) { return $true }
        }
        return $false
    }
    $base='Microsoft.DocumentDB/databaseAccounts'
    if (-not (HasAction "$base/readMetadata")) { return }
    $read=HasAction "$base/sqlDatabases/containers/items/read"
    $create=HasAction "$base/sqlDatabases/containers/items/create"
    if ($read) { @{roleDefinitionName='Cosmos Onboarding Reader'} }
    if ($read -and $create) { @{roleDefinitionName='Cosmos Onboarding Writer'} }
    if ($read -and (HasAction "$base/sqlDatabases/containers/executeQuery")) { @{roleDefinitionName='Cosmos Onboarding Query Reader'} }
    if ($read -and $create -and (HasAction "$base/sqlDatabases/containers/items/delete")) { @{roleDefinitionName='Cosmos Onboarding Lease Writer'} }
}

function Invoke-OnboardingCosmosRequest {
    [CmdletBinding()]
    param(
        [hashtable]$Registry,[string]$Method,[string]$Container,[string]$Id,$Partition,$Body,[hashtable]$Options=@{},
        [scriptblock]$GetToken={param($sub,$resource) Get-OnboardingToken $sub $resource},
        [scriptblock]$Http={param($request) Invoke-WebRequest @request}
    )
    Assert-OnboardingSchema $Registry (Get-OnboardingRegistrySchema)
    $token=& $GetToken (($Registry.accountResourceId -split '/')[2]) 'https://cosmos.azure.com/'
    $url="$($Registry.endpoint.TrimEnd('/'))/dbs/$([uri]::EscapeDataString($Registry.database))/colls/$Container/docs"
    if ($Id) { $url+="/$([uri]::EscapeDataString($Id))" }
    $headers=@{
        authorization=[uri]::EscapeDataString("type=aad&ver=1.0&sig=$token")
        'x-ms-date'=[DateTime]::UtcNow.ToString('r',[Globalization.CultureInfo]::InvariantCulture);'x-ms-version'='2018-12-31'
    }
    if ($null -ne $Partition) { $headers['x-ms-documentdb-partitionkey']=ConvertTo-Json -InputObject @($Partition) -Compress }
    if ($Options.etag) { $headers['If-Match']=$Options.etag }
    $contentType='application/json'
    if ($Options.query) {
        $headers['x-ms-documentdb-isquery']='true';$headers['x-ms-documentdb-query-enablecrosspartition']='true'
        $contentType='application/query+json'
    }
    if ($Options.continuation) { $headers['x-ms-continuation']=$Options.continuation }
    if ($Options.sessionToken) { $headers['x-ms-session-token']=$Options.sessionToken }
    $args=@{Uri=$url;Method=$Method;Headers=$headers;ContentType=$contentType;MaximumRedirection=0;SkipHttpErrorCheck=$true;ErrorAction='Stop'}
    if ($null -ne $Body) { $args.Body=ConvertTo-Json -InputObject $Body -Depth 64 -Compress }
    try { $response=& $Http $args }
    catch { throw 'Cosmos transport failed. Verify the in-VNet runner and private endpoint.' }
    if ($response.StatusCode -eq 403 -or $response.StatusCode -eq 401) {
        Stop-Onboarding 'Cosmos access was refused. The stage requires in-VNet private-endpoint access and the operator Cosmos data-plane grant.'
    }
    if ($response.StatusCode -notin @(200,201,204,404,409,412)) { throw "Cosmos request failed (HTTP $($response.StatusCode))." }
    @{
        status=[int]$response.StatusCode
        body=if ($response.Content) {$response.Content|ConvertFrom-Json -AsHashtable} else {$null}
        etag=[string]($response.Headers['ETag']|Select-Object -First 1)
        requestChargeRu=if ($response.Headers['x-ms-request-charge']) {[decimal]::Parse([string]($response.Headers['x-ms-request-charge']|Select-Object -First 1),[Globalization.CultureInfo]::InvariantCulture)} else {$null}
        continuation=[string]($response.Headers['x-ms-continuation']|Select-Object -First 1)
        sessionToken=[string]($response.Headers['x-ms-session-token']|Select-Object -First 1)
    }
}

function New-OnboardingRegistryOperations {
    param([hashtable]$Registry,[scriptblock]$Send)
    Assert-OnboardingSchema $Registry (Get-OnboardingRegistrySchema)
    if (-not $Send) {
        $Send={param($m,$container,$id,$partition,$body,$options) Invoke-OnboardingCosmosRequest $Registry $m $container $id $partition $body $options}.GetNewClosure()
    }
    $session=@{token=$null}
    @{
        GetRegistryAccount={
            Invoke-OnboardingRest (($Registry.accountResourceId -split '/')[2]) 'GET' "https://management.azure.com$($Registry.accountResourceId)?api-version=2024-05-15" $null
        }.GetNewClosure()
        GetPrivateAddresses={ [Net.Dns]::GetHostAddresses(([uri]$Registry.endpoint).Host)|ForEach-Object{$_.ToString()} }.GetNewClosure()
        GetProject={
            param($id)
            $r=& $Send 'GET' 'projects' $id $id $null @{sessionToken=$session.token}
            if ($r.status -eq 404) { return $null }
            if ($r.status -ne 200) { throw 'Cosmos project read failed.' }
            $r.body
        }.GetNewClosure()
        CreateProject={
            param($doc)
            $r=& $Send 'POST' 'projects' $null $doc.projectId $doc @{}
            if ($r.status -eq 409) { Stop-Onboarding 'The project was created by another operator. Rediscovery is required; no overwrite was performed.' }
            if ($r.status -ne 201) { throw 'Cosmos project creation failed.' }
            $session.token=$r.sessionToken
            @{requestChargeRu=$r.requestChargeRu;etag=$r.etag}
        }.GetNewClosure()
    }
}
Export-ModuleMember -Function Test-OnboardingPrivateAddress, Assert-OnboardingPrivateRegistry, Get-OnboardingCosmosRoles, Invoke-OnboardingCosmosRequest, New-OnboardingRegistryOperations
