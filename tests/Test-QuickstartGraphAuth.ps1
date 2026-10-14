#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'infra\quickstart\Deploy-Quickstart.ps1') -DotSourceOnly
$tenant = '00000000-0000-4000-8000-000000000001'
$script:failure = ''
$script:tokenFailure = ''
$script:restFailure = ''
$script:tokenCalls = 0
$script:restCalls = 0
$script:passes = 0

function Assert-True([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passes++
    Write-Host "PASS: $Name"
}
function Invoke-QsAz {
    param([string[]]$Arguments)
    if ($script:failure) { throw $script:failure }
    return @{ id = 'expected'; securityEnabled = $true }
}
function Get-AzAccessToken {
    param($ResourceTypeName, $TenantId, [switch]$AsSecureString, $ErrorAction)
    $script:tokenCalls++
    Assert-True 'alternate token uses Graph, explicit tenant and secure output' ($ResourceTypeName -ceq 'MSGraph' -and $TenantId -ceq $tenant -and $AsSecureString)
    if ($script:tokenFailure) { throw $script:tokenFailure }
    return @{ Token = ConvertTo-SecureString 'synthetic-token' -AsPlainText -Force }
}
function Invoke-RestMethod {
    param($Method, $Uri, $Authentication, $Token, $TimeoutSec, $ErrorAction)
    $script:restCalls++
    Assert-True 'Graph request uses secure bearer token and original path' ($Method -ceq 'Get' -and $Uri -ceq 'https://graph.microsoft.com/v1.0/groups/expected' -and $Authentication -ceq 'Bearer' -and $Token -is [System.Security.SecureString] -and $TimeoutSec -eq 60)
    if ($script:restFailure) { throw $script:restFailure }
    return [pscustomobject]@{ id = 'expected'; securityEnabled = $true }
}

$result = Get-QsGraph 'groups/expected' -TenantId $tenant
Assert-True 'normal CLI success does not acquire another token' ($result.id -ceq 'expected' -and $script:tokenCalls -eq 0 -and $script:restCalls -eq 0)
$script:failure = 'az rest failed: ERROR: Timedout waiting for token from portal. Audience: https://graph.microsoft.com/'
$result = Get-QsGraph 'groups/expected' -TenantId $tenant
Assert-True 'portal timeout recovers using existing PowerShell authentication' ($result -is [hashtable] -and $result.securityEnabled -and $script:tokenCalls -eq 1 -and $script:restCalls -eq 1)
$script:failure = 'ERROR: Audience https://graph.microsoft.com/ is not a supported MSI token audience'
$result = Get-QsGraph 'groups/expected' -TenantId $tenant
Assert-True 'unsupported MSI audience also uses the existing PowerShell authentication' ($result.id -ceq 'expected' -and $script:tokenCalls -eq 2)
$script:failure = 'az rest failed: Authorization_RequestDenied: HTTP 403'
$message = try { Get-QsGraph 'groups/expected' -TenantId $tenant; '' } catch { $_.Exception.Message }
Assert-True 'permission denial is not retried with another identity' ($message -ceq $script:failure -and $script:tokenCalls -eq 2)
$script:failure = 'Timedout waiting for token from portal'
$script:tokenFailure = 'Conditional Access denied'
$message = try { Get-QsGraph 'groups/expected' -TenantId $tenant; '' } catch { $_.Exception.Message }
Assert-True 'both sign-ins failing stops with actionable guidance' ($message -like 'graph_authentication_unavailable:*' -and $message.Contains('No prerequisite checks were skipped') -and $message.Contains('Do not run az logout') -and $script:restCalls -eq 2)
$script:tokenFailure = ''
$script:restFailure = 'Request_ResourceNotFound: HTTP 404'
$message = try { Get-QsGraph 'groups/expected' -TenantId $tenant; '' } catch { $_.Exception.Message }
Assert-True 'Graph response failure propagates unchanged' ($message -ceq $script:restFailure)
Write-Host "$script:passes passed"
