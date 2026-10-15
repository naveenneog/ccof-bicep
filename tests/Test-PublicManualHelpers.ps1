#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/manual/Session-Helpers.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Refuses([scriptblock]$Call, [string]$Pattern) {
    $message = $null
    try { & $Call | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -and $message -like $Pattern) "Expected refusal matching $Pattern; received $message"
}
$scratch = Join-Path $root ".env.manual-helpers-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
$sub = '11111111-1111-4111-8111-111111111111'
$tenant = '22222222-2222-4222-8222-222222222222'
$base = "/subscriptions/$sub/resourceGroups/Sample-RG/providers"
$account = "$base/Microsoft.DocumentDB/databaseAccounts/sample-cosmos"
$workspace = "$base/Microsoft.OperationalInsights/workspaces/sample-law"
$gateway = '88888888-8888-4888-8888-888888888888'
$resolver = '99999999-9999-4999-8999-999999999999'
$script:Definitions = @()
$script:Assignments = @()
$script:Creates = [Collections.Generic.List[object]]::new()
$script:ListReads = 0
$script:VisibleAfter = 0
$script:OmitAttachmentIds = $false
$fixture = @{
    subscriptionId=$sub;tenantId=$tenant;resourceGroup='Sample-RG';cosmosAccount='sample-cosmos';database='Registry'
    workspaceResourceId=$workspace;apimResourceId="$base/Microsoft.ApiManagement/service/sample-apim"
    gatewayAppId=$gateway;gatewayIdentifierUri="api://$gateway";resolverApiAppId=$resolver;apps=@{}
}
foreach ($app in 'resolver','sync','reconciler') {
    $fixture.apps[$app] = @{
        name="sample-$app";storageAccount="sample${app}storage"
        appInsightsResourceId=if ($app -eq 'reconciler') {$null} else {"$base/Microsoft.Insights/components/sample-$app-ai"}
        identityResourceId=if ($app -eq 'resolver') {$null} else {"$base/Microsoft.ManagedIdentity/userAssignedIdentities/sample-$app-id/"}
    }
}
function global:az {
    $global:LASTEXITCODE = 0
    $arguments = @($args)
    $command = $arguments -join ' '
    function Arg([string]$Name) { $index=[array]::IndexOf($arguments,$Name); if ($index -ge 0) { $arguments[$index+1] } }
    $value = switch -regex ($command) {
        '^account show' { @{id=$sub;tenantId=$tenant}; break }
        '^account list-locations' { @(@{name='eastus2';displayName='East US 2'}); break }
        '^cosmosdb sql database show' { @{resource=@{id='Registry'}}; break }
        '^cosmosdb show' { @{id=$account;documentEndpoint='https://sample-cosmos.documents.azure.com/';disableLocalAuth=$true}; break }
        '^ad sp show' { @{appId='55555555-5555-4555-8555-555555555555'}; break }
        '^ad app show' {
            $id=Arg '--id'
            @{signInAudience='AzureADMyOrg';identifierUris=@("api://$id");api=@{requestedAccessTokenVersion=2;oauth2PermissionScopes=@(@{value='access_as_user';isEnabled=$true})}}; break
        }
        '^identity show' { throw 'Discovery must use the attached identity map or ARM fallback, not this redundant lookup.' }
        '^resource show' {
            if ($command -match 'workspaces') { @{properties=@{customerId='33333333-3333-4333-8333-333333333333';retentionInDays=30}}; break }
            if ($command -match 'ApiManagement') { @{name='sample-apim';id=$fixture.apimResourceId;identity=@{principalId='44444444-4444-4444-8444-444444444444'};properties=@{gatewayUrl='https://sample-apim.azure-api.net'}}; break }
            if ($command -match 'userAssignedIdentities') { @{properties=@{principalId='66666666-6666-4666-8666-666666666666';clientId='77777777-7777-4777-8777-777777777777'}}; break }
            if ($command -match 'components') { @{properties=@{WorkspaceResourceId=$workspace;ConnectionString='InstrumentationKey=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'}}; break }
            $name=Arg '-n';$app=$name.Substring('sample-'.Length)
            $auth=@{type='SystemAssignedIdentity'};$identity=@{principalId='66666666-6666-4666-8666-666666666666'}
            if ($app -ne 'resolver') {
                $id=$fixture.apps[$app].identityResourceId.TrimEnd('/').ToLowerInvariant()
                $entry=if($script:OmitAttachmentIds){@{}}else{@{principalId='66666666-6666-4666-8666-666666666666';clientId='77777777-7777-4777-8777-777777777777'}}
                $identity=@{userAssignedIdentities=@{$id=$entry}}
                $auth=@{type='UserAssignedIdentity';userAssignedIdentityResourceId=$id}
            }
            @{id="$base/Microsoft.Web/sites/$name";location='East US 2';identity=$identity;properties=@{
                defaultHostName="$name.azurewebsites.net"
                functionAppConfig=@{runtime=@{name='node';version='22'};deployment=@{storage=@{value="https://sample${app}storage.blob.core.windows.net/pkg";authentication=$auth}}}
            }}; break
        }
        '^storage account show' { @{id="$base/Microsoft.Storage/storageAccounts/$(Arg '-n')";allowSharedKeyAccess=$false}; break }
        '^functionapp config appsettings list' { return '[]' }
        '^cosmosdb sql role definition list' { return (ConvertTo-Json -InputObject @($script:Definitions) -Depth 30) }
        '^cosmosdb sql role definition create' {
            $body=Get-Content -LiteralPath (Arg '--body').Substring(1) -Raw | ConvertFrom-Json -AsHashtable
            $script:Creates.Add(@{kind='definition';id=$body.Id})
            $script:Definitions += @{id="$account/sqlRoleDefinitions/$($body.Id)";roleName=$body.RoleName;type='Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions';assignableScopes=@($account.ToLowerInvariant());permissions=@(@{dataActions=$body.Permissions[0].DataActions;notDataActions=@()})}
            return
        }
        '^cosmosdb sql role assignment list' {
            $script:ListReads++
            if ($script:ListReads -lt $script:VisibleAfter) { return '[]' }
            return (ConvertTo-Json -InputObject @($script:Assignments) -Depth 30)
        }
        '^cosmosdb sql role assignment create' {
            $script:Creates.Add(@{kind='assignment';id=(Arg '--role-assignment-id')})
            $script:Assignments=@(@{id="$account/sqlRoleAssignments/$(Arg '--role-assignment-id')";principalId=(Arg '--principal-id');roleDefinitionId=(Arg '--role-definition-id');scope=($account.ToLowerInvariant() + (Arg '--scope'))})
            return
        }
        default { throw "Unmocked command: $command" }
    }
    ConvertTo-Json -InputObject $value -Depth 40
}
try {
    $inputs=Join-Path $scratch 'inputs.json';$values=Join-Path $scratch 'values.json'
    Save-CcofJson $fixture $inputs
    Read-CcofCustomerValues $inputs $values
    $C=Get-Content $values -Raw | ConvertFrom-Json -AsHashtable
    Assert ($C.apps.sync.location -ceq 'eastus2') 'Display region was not converted before output.'
    Assert ($C.apps.sync.clientId -eq '77777777-7777-4777-8777-777777777777') 'Mixed-case attached UAMI not reused.'
    $script:OmitAttachmentIds=$true
    Read-CcofCustomerValues $inputs $values
    Assert ((Get-Content $values -Raw | ConvertFrom-Json -AsHashtable).apps.sync.clientId -eq $C.apps.sync.clientId) 'Missing attachment IDs did not use ARM fallback.'
    $before=$script:Creates.Count
    Refuses { Set-CcofCosmosRole -C $fixture -Kind sync -Directory $scratch -Apply } '*cosmosResourceId is empty*'
    Assert ($script:Creates.Count -eq $before) 'Incomplete values caused a write.'

    foreach($kind in 'sync','reconciler','seed') { Set-CcofCosmosRole -C $C -Kind $kind -Directory $scratch -Apply -Sleep {} }
    Assert ($script:Creates.Count -eq 3) 'Expected three custom roles.'
    foreach($kind in 'sync','reconciler','seed') { Set-CcofCosmosRole -C $C -Kind $kind -Directory $scratch -Apply }
    Assert ($script:Creates.Count -eq 3) 'Existing ARM-type custom roles were not reused.'
    $script:Definitions[0].permissions[0].dataActions += '*'
    Refuses { Set-CcofCosmosRole -C $C -Kind sync -Directory $scratch -Apply } '*Existing custom role differs*'
    $script:Definitions[0].permissions[0].dataActions = @(Get-CcofCosmosActions sync)

    $script:VisibleAfter=3;$script:ListReads=0
    Grant-CcofCosmosRole -C $C -App resolver -Kind reader -Apply -Sleep {}
    $count=$script:Creates.Count
    Grant-CcofCosmosRole -C $C -App resolver -Kind reader -Apply
    Assert ($script:Creates.Count -eq $count) 'ARM casing caused a duplicate assignment.'
    $script:Assignments[0].scope = $account.ToLowerInvariant() + '/dbs/registry'
    Grant-CcofCosmosRole -C $C -App resolver -Kind reader -Apply -VerificationTimeoutSeconds 0
    Assert ($script:Assignments[0].scope.EndsWith('/dbs/Registry', [StringComparison]::Ordinal)) 'A different-case database was treated as the same database.'
    Assert ($script:Creates.Count -eq $count + 1) 'The intended case-distinct database grant was not created.'

    $script:VisibleAfter=999;$script:ListReads=0;$script:Assignments=@()
    $count=$script:Creates.Count
    1..2 | ForEach-Object {
        Refuses { Grant-CcofCosmosRole -C $C -App resolver -Kind reader -Apply -VerificationTimeoutSeconds 0 } '*Write may have succeeded*'
    }
    $retryIds=@($script:Creates | Select-Object -Skip $count | ForEach-Object id | Sort-Object -Unique)
    Assert ($retryIds.Count -eq 1) 'A retry after eventual-consistency timeout generated duplicate assignment IDs.'

    $seedId='0123456789abcdef0123456789abcdef'
    $documents=@{projects=@(@{id='PROJECT01'});backends=@(@{id='foundry-primary'})}
    $result=@{schema='ccof.seed.result.v1';seedId=$seedId;outcome='succeeded';documents=@(
        @{container='projects';id='PROJECT01';outcome='created'},
        @{container='backends';id='foundry-primary';outcome='present-equal'}
    )}
    Assert-CcofSeedResult -Result $result -SeedId $seedId -Documents $documents
    $result.documents[0].outcome='present-differs'
    Refuses { Assert-CcofSeedResult -Result $result -SeedId $seedId -Documents $documents } '*Seed did not verify every expected document*'
    $result.documents[0].outcome='created';$result.documents=@($result.documents[0])
    Refuses { Assert-CcofSeedResult -Result $result -SeedId $seedId -Documents $documents } '*Seed did not verify every expected document*'
} finally {
    Remove-Item Function:\global:az
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
'Public manual discovery, region normalization, identity attachments, fail-closed values and Cosmos role/assignment read-back: PASS'
