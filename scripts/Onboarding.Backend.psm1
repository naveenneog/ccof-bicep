#Requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Azure.psm1')

function New-OnboardingBackendOperations {
    param([hashtable]$Decisions, [scriptblock]$Send)
    $a = $Decisions
    if (-not $Send) {
        $Send = {
            param($m,$u,$b)
            $sub = if (([uri]$u).AbsolutePath -match '^/subscriptions/([^/]+)/') { $Matches[1] } else { $a.subscriptionId }
            Invoke-OnboardingRest $sub $m $u $b
        }.GetNewClosure()
    }
    @{
        GetCredentialReference = {
            param($auth)
            if($auth.mode -eq 'credential-manager'){
                $value=& $Send 'GET' "https://management.azure.com$($a.apimResourceId)/authorizationProviders/$($auth.providerId)/authorizations/$($auth.connectionId)?api-version=2024-05-01" $null
                return @{exists=($null -ne $value);secure=$true}
            }
            $value=& $Send 'GET' "https://management.azure.com$($a.apimResourceId)/namedValues/$($auth.secretNamedValueId)?api-version=2024-05-01" $null
            @{exists=($null -ne $value);secure=($value.properties.secret -is [bool] -and $value.properties.secret)}
        }.GetNewClosure()
        GetApim = { & $Send 'GET' "https://management.azure.com$($a.apimResourceId)?api-version=2024-05-01" $null }.GetNewClosure()
        GetFoundry = { & $Send 'GET' "https://management.azure.com$($a.foundryAccountResourceId)?api-version=2024-10-01" $null }.GetNewClosure()
        GetSubscription = { & $Send 'GET' "https://management.azure.com/subscriptions/$($a.designatedSubscriptionId)?api-version=2022-12-01" $null }.GetNewClosure()
        GetReconciler = {
            $version = if ($a.reconcilerResourceId.Contains('/Microsoft.Web/')) { '2024-04-01' } else { '2023-01-31' }
            & $Send 'GET' "https://management.azure.com$($a.reconcilerResourceId)?api-version=$version" $null
        }.GetNewClosure()
        GetBackend = {
            param($id)
            if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { Stop-Onboarding 'Invalid backend identifier.' }
            & $Send 'GET' "https://management.azure.com$($a.apimResourceId)/backends/$id`?api-version=2024-05-01" $null
        }.GetNewClosure()
        CreateBackend = {
            param($id, $body)
            & $Send 'PUT' "https://management.azure.com$($a.apimResourceId)/backends/$id`?api-version=2024-05-01" $body | Out-Null
        }.GetNewClosure()
        GetRoleDefinition = {
            param($sub,$name)
            $filter = [uri]::EscapeDataString("roleName eq '$name'")
            $url = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&`$filter=$filter"
            $roles = @(Get-OnboardingPages $url $Send | Where-Object { [string]::Equals($_.properties.roleName, $name, 'Ordinal') })
            if ($roles.Count -ne 1) { Stop-Onboarding "The required role '$name' did not resolve unambiguously." }
            $roles[0]
        }.GetNewClosure()
        HasRoleAssignment = {
            param($grant)
            $url = "https://management.azure.com$($grant.scope)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()"
            $assignments = @(Get-OnboardingPages $url $Send)
            return @($assignments | Where-Object {
                [string]::Equals($_.properties.principalId, $grant.principalId, 'Ordinal') -and
                [string]::Equals(($_.properties.roleDefinitionId -split '/')[-1], ($grant.roleDefinitionId -split '/')[-1], 'Ordinal') -and
                -not $_.properties.condition
            }).Count -gt 0
        }.GetNewClosure()
        AssignRole = {
            param($grant)
            $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$($grant.scope)|$($grant.principalId)|$($grant.roleDefinitionId)"))
            $name = [guid]::new([byte[]]$bytes[0..15]).ToString()
            & $Send 'PUT' "https://management.azure.com$($grant.scope)/providers/Microsoft.Authorization/roleAssignments/$name`?api-version=2022-04-01" @{
                properties = @{ principalId=$grant.principalId; roleDefinitionId=$grant.roleDefinitionId; principalType='ServicePrincipal' }
            } | Out-Null
        }.GetNewClosure()
        QueryCost = {
            & $Send 'POST' "https://management.azure.com/subscriptions/$($a.designatedSubscriptionId)/providers/Microsoft.CostManagement/query?api-version=2025-03-01" @{
                type='ActualCost'; timeframe='Custom'; timePeriod=$a.costQueryPeriod
                dataset=@{ granularity='None'; aggregation=@{ totalCost=@{ name='PreTaxCost'; function='Sum' } } }
            }
        }.GetNewClosure()
    }
}
Export-ModuleMember -Function New-OnboardingBackendOperations
