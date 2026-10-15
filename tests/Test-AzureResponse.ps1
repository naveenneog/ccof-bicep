#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/Azure.Response.psm1') -Force -DisableNameChecking
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Refuses([scriptblock]$Call) {
    $failed = $false
    try { & $Call | Out-Null } catch { $failed = $true }
    Assert $failed 'Expected an invalid response to fail closed.'
}

$arm = '{"Tables":[{"Columns":[{"ColumnName":"message"},{"ColumnName":"timestamp"}],"Rows":[["one","now"],["two","then"]]}]}'
$data = '{"tables":[{"columns":[{"name":"timestamp"},{"name":"message"}],"rows":[["now","one"],["then","two"]]}]}'
foreach ($json in $arm, $data) {
    foreach ($dictionary in $true, $false) {
        $response = if ($dictionary) { $json | ConvertFrom-Json -AsHashtable } else { $json | ConvertFrom-Json }
        Assert ((@(Get-CcofQueryMessages $response) -join ',') -ceq 'one,two') 'ARM/data-plane query messages or column order were lost.'
    }
}
$single = '{"Tables":[{"Columns":[{"ColumnName":"message"}],"Rows":[["only-one"]]}]}' | ConvertFrom-Json -AsHashtable
Assert ((@(Get-CcofQueryMessages $single) -join ',') -ceq 'only-one') 'A single row was flattened.'
$empty = '{"Tables":[{"Columns":[{"ColumnName":"message"}],"Rows":[]}]}' | ConvertFrom-Json -AsHashtable
Assert (@(Get-CcofQueryMessages $empty).Count -eq 0) 'An empty result is not a successful seed message.'
Refuses { Get-CcofQueryMessages (@{error=@{code='Forbidden'}}) }
Refuses { Get-CcofQueryMessages (@{}) }
Refuses { Get-CcofQueryMessages (@{tables=@(@{columns=@(@{name='unrelated'});rows=@()})}) }
Refuses { Get-CcofQueryMessages (@{tables=@(@{columns=@(@{name='message'});rows=@(@('a'),@())})}) }
Refuses { Get-CcofJsonField ('{"Tables":[],"tables":[]}' | ConvertFrom-Json -AsHashtable) 'tables' }

$locations = @(@{name='eastus2';displayName='East US 2'}, @{name='centralindia';displayName='Central India'})
Assert ((Get-CcofCanonicalLocation 'East US 2' $locations) -ceq 'eastus2') 'Display region was not normalized from provider metadata.'
Assert ((Get-CcofCanonicalLocation 'centralindia' $locations) -ceq 'centralindia') 'Canonical region changed.'
Refuses { Get-CcofCanonicalLocation 'not an approved region' $locations }
Assert (-not (Test-CcofArmIdEqual '' '')) 'Missing IDs cannot compare equal.'

$account = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/Sample-RG/providers/Microsoft.DocumentDB/databaseAccounts/sample-cosmos'
$scope = "$account/dbs/Registry/colls/Projects"
$cased = $account.ToLowerInvariant() + '/dbs/Registry/colls/Projects/'
Assert (Test-CcofCosmosScopeEqual $scope $cased) 'ARM casing or trailing slash caused a false scope mismatch.'
Assert (-not (Test-CcofCosmosScopeEqual $scope ($account + '/dbs/registry/colls/Projects'))) 'Cosmos database IDs were incorrectly case-folded.'
Assert (-not (Test-CcofCosmosScopeEqual $scope ($account + '/dbs/Registry/colls/projects'))) 'Cosmos container IDs were incorrectly case-folded.'
Assert (Test-CcofCosmosScopeCovers $account $scope) 'Account read scope did not cover the database.'
Assert (Test-CcofCosmosScopeCovers ($account + '/dbs/Registry') $scope) 'Database scope did not cover its container.'
Assert (-not (Test-CcofCosmosScopeCovers ($account + '/dbs/Registry') ($account + '/dbs/Registry2'))) 'Prefix collision covered another database.'
$principal = '22222222-2222-4222-8222-222222222222'
$role = "$account/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001"
$id = New-CcofCosmosAssignmentId $scope $principal $role
Assert ($id -ceq (New-CcofCosmosAssignmentId $cased $principal $role.ToLowerInvariant())) 'Retry IDs changed with ARM casing.'
Assert ($id -cne (New-CcofCosmosAssignmentId ($account + '/dbs/registry/colls/Projects') $principal $role)) 'Case-distinct Cosmos scopes collided.'

Import-Module (Join-Path $root 'scripts/Onboarding.Azure.psm1') -Force -DisableNameChecking
& (Get-Module Onboarding.Azure) { function script:Get-OnboardingToken { 'not-a-real-token' } }
function global:Invoke-WebRequest {
    param($Uri, $Method, $Headers, $MaximumRedirection, $SkipHttpErrorCheck, $ErrorAction)
    @{StatusCode=200;Content=([string][char]0xfeff + '{"Tables":[]}')}
}
try {
    $response = Invoke-OnboardingRest -SubscriptionId '11111111-1111-4111-8111-111111111111' -Method GET -Url 'https://management.azure.com/subscriptions/11111111-1111-4111-8111-111111111111'
    Assert ($response.Contains('Tables')) 'A BOM-prefixed provider response did not parse.'
} finally { Remove-Item Function:\global:Invoke-WebRequest }
'Azure query shapes, canonical regions, exact Cosmos paths, deterministic retry IDs and BOM transport: PASS'
