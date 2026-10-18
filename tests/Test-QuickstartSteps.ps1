#Requires -Version 7.0
<#
.SYNOPSIS
    Tests quick-start steps 1, 3 and 4 of infra/quickstart/Deploy-Quickstart.ps1 (ADR-0024) with
    fakes for az and Microsoft Graph (no Azure call):
    - step 1 refuses a missing prerequisite by name and changes nothing; "Allow public client flows"
      off on the Developer Sign-in app is a warning, not a refusal (only `ccof-token login
      --device-code` needs it; docs/CLIENTS.md);
    - steps 3 and 4 name --subscription on every az call that takes one.
#>

$ErrorActionPreference = 'Continue'
$script:Pass = 0
$script:Fail = 0
trap { Write-Host "FAIL: unexpected error: $_" -ForegroundColor Red; $script:Fail++; continue }
$root = Split-Path $PSScriptRoot -Parent

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green; $script:Pass++ }
    else { Write-Host "FAIL: $Name $Detail" -ForegroundColor Red; $script:Fail++ }
}

. (Join-Path $root 'infra' 'quickstart' 'Deploy-Quickstart.ps1') -DotSourceOnly
$built = az bicep build-params --file (Join-Path $root 'infra' 'quickstart' 'main.bicepparam') --stdout 2>$null | ConvertFrom-Json -AsHashtable
$P = @{}; $parameters = ($built.parametersJson | ConvertFrom-Json -AsHashtable -Depth 100).parameters; foreach ($k in $parameters.Keys) { $P[$k] = $parameters[$k].value }
$P.tenantId = '00000000-0000-4000-8000-000000000aaa'
$P.names.subscriptionId = '11111111-1111-4111-8111-111111111111'
$P.workbook.resourceName = '00000000-0000-4000-8000-000000010000'
foreach ($backend in $P.backends) { $backend.subscriptionId = $P.names.subscriptionId }
foreach ($group in $P.groups) { $group.groupId = $group.groupId.Replace('REPLACE-', '') }
$P.registrations.gatewayApi.appId = '00000000-0000-4000-8000-000001110100'
$P.registrations.developerSignIn.appId = '00000000-0000-4000-8000-000001110101'
$P.registrations.resolverApi.appId = '00000000-0000-4000-8000-000001110110'

# --- Fakes: az (account, APIM) and Graph (applications, groups) ---
$script:Graph = @{}
$script:AzCalls = [System.Collections.Generic.List[string]]::new()
function Reset-Fakes {
    $script:Graph = @{
        apim = @{ identity = @{ type = 'SystemAssigned'; principalId = '00000000-0000-4000-8000-000001110111' }; properties = @{ gatewayUrl = 'https://example-sampleqs-apim.azure-api.net' } }
        gateway = @{ appId = $P.registrations.gatewayApi.appId; identifierUris = @("api://$($P.registrations.gatewayApi.appId)"); api = @{ requestedAccessTokenVersion = $P.registrations.gatewayApi.accessTokenVersion; oauth2PermissionScopes = @(@{ value = 'access_as_user'; isEnabled = $true }) } }
        developer = @{ appId = $P.registrations.developerSignIn.appId; isFallbackPublicClient = $null; publicClient = @{ redirectUris = @('http://localhost', 'https://login.microsoftonline.com/common/oauth2/nativeclient') } }
        resolver = @{ appId = $P.registrations.resolverApi.appId; identifierUris = @("api://$($P.registrations.resolverApi.appId)"); api = @{ requestedAccessTokenVersion = 2 } }
        groups = @{}
    }
    foreach ($g in $P.groups) { $script:Graph.groups[$g.groupId] = @{ id = $g.groupId; securityEnabled = $true; displayName = 'Exact Ω Graph name' } }
    $script:AzCalls.Clear()
}
function Invoke-QsAz {
    param([string[]]$Arguments)
    $script:AzCalls.Add($Arguments -join ' ')
    if ($Arguments[0] -eq 'account') { return @{ tenantId = $P.tenantId; id = $P.names.subscriptionId } }
    if ($Arguments[0] -eq 'rest' -and ($Arguments -join ' ') -match 'Microsoft\.ApiManagement/service') { return $script:Graph.apim }
    if ($Arguments[0] -eq 'deployment') { return @{ properties = @{ outputs = @{ gatewayUrl = @{ value = 'https://x/anthropic-qs' } } } } }
    return ''
}
function Get-QsGraph {
    param([string]$Path, [string]$TenantId)
    if ($Path -match '^servicePrincipals/') { return @{ appId = '00000000-0000-4000-8000-000001111000' } }
    if ($Path -match "appId eq '([0-9a-f-]+)'") {
        $id = $Matches[1]
        $app = @($script:Graph.gateway, $script:Graph.developer, $script:Graph.resolver | Where-Object { $_ -and $_.appId -eq $id })
        return @{ value = $app }
    }
    if ($Path -match '^groups/([0-9a-f-]+)$') {
        if ($script:GroupReadError) { throw $script:GroupReadError }
        if ($script:Graph.groups.Contains($Matches[1])) { return $script:Graph.groups[$Matches[1]] }
        throw 'Request_ResourceNotFound'
    }
    throw "unexpected Graph path $Path"
}
function New-Step1Context { @{ P = $P; ParametersText = '// no placeholders'; Roles = { param($Ctx) @() } } }

# --- Step 1 ---
Reset-Fakes
$script:GroupReadError = 'graph_authentication_unavailable: portal token timed out'
$message = try { $null = Test-QsPrerequisites (New-Step1Context); '' } catch { $_.Exception.Message }
Assert-True 'group authentication failures are not reported as missing groups' ($message -ceq $script:GroupReadError)
$script:GroupReadError = ''
$out = $null; $message = ''
try { $out = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 passes when only "Allow public client flows" is off on the Developer Sign-in app' ($null -ne $out -and -not $message) $message
Assert-True 'step 1 records developer_sign_in_not_public as a warning' (@($out.warnings | Where-Object { $_ -match '^developer_sign_in_not_public' }).Count -eq 1) "warnings: $(@($out.warnings) -join ' | ')"
Assert-True 'step 1 outputs the APIM identity and the gateway identifier URI' ($out.apimPrincipalId -eq '00000000-0000-4000-8000-000001110111' -and $out.gatewayIdentifierUri -eq "api://$($P.registrations.gatewayApi.appId)")
Assert-True 'step 1 persists actual Graph display names, not generic form labels' ($out.classificationGroupDisplayNames[$P.groups[0].groupId] -ceq 'Exact Ω Graph name')

Reset-Fakes; $script:Graph.developer.isFallbackPublicClient = $true
$out = $null; try { $out = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 has no warning when public client flows are allowed' ($null -ne $out -and @($out.warnings).Count -eq 0)

Reset-Fakes; $script:Graph.groups.Remove($P.groups[0].groupId)
$message = ''; try { $null = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 still refuses a missing group, by name, and changes nothing' ($message -match 'group_missing' -and $message -match [regex]::Escape($P.groups[0].groupId) -and @($script:AzCalls | Where-Object { $_ -notmatch '^(account show|rest --method get)' }).Count -eq 0) $message

Reset-Fakes; $script:Graph.developer = $null
$message = ''; try { $null = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 refuses a missing Developer Sign-in app' ($message -match 'developer_sign_in_missing')

Reset-Fakes; $script:Graph.resolver.api.requestedAccessTokenVersion = 1
$message = ''; try { $null = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 refuses a Resolver API without token version 2' ($message -match 'resolver_api_token_version')

# Both role settings must be checked on the combined app; resolver remains a different audience.
$savedDeveloperId = $P.registrations.developerSignIn.appId
$P.registrations.developerSignIn.appId = $P.registrations.gatewayApi.appId
Reset-Fakes
$script:Graph.gateway.publicClient = @{ redirectUris = @('http://localhost', 'https://login.microsoftonline.com/common/oauth2/nativeclient') }
$script:Graph.gateway.isFallbackPublicClient = $true
$script:Graph.developer = $null
$out = $null; $message = ''; try { $out = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 accepts one app with API and public-client settings' ($null -ne $out -and -not $message) $message
$script:Graph.gateway.publicClient.redirectUris = @()
$message = ''; try { $null = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 refuses a combined app without public-client redirects' ($message -match 'developer_sign_in_redirect_uri_missing') $message
$script:Graph.gateway.publicClient.redirectUris = @('http://localhost', 'https://login.microsoftonline.com/common/oauth2/nativeclient')
$script:Graph.gateway.identifierUris = @()
$message = ''; try { $null = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 refuses a combined app without API identifier URI' ($message -match 'gateway_api_identifier_uri_missing') $message
$script:Graph.gateway.identifierUris = @("api://$($P.registrations.gatewayApi.appId)")
$script:Graph.gateway.api.requestedAccessTokenVersion = 3 - $P.registrations.gatewayApi.accessTokenVersion
$message = ''; try { $null = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 refuses an API token version different from its answer' ($message -match 'gateway_api_token_version_mismatch') $message
$P.registrations.developerSignIn.appId = $savedDeveloperId
$savedResolverId = $P.registrations.resolverApi.appId
foreach ($role in @('gatewayApi', 'developerSignIn')) {
    $P.registrations.resolverApi.appId = $P.registrations[$role].appId
    Reset-Fakes
    $message = ''; try { $null = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
    Assert-True "step 1 rejects resolver sharing the $role ID before Azure calls" ($message -match 'resolver_app_shared' -and $script:AzCalls.Count -eq 0) $message
}
$P.registrations.resolverApi.appId = $savedResolverId
Reset-Fakes; $script:Graph.resolver.publicClient = @{ redirectUris = @('http://localhost') }
$message = ''; try { $null = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 refuses public-client redirects on the resolver' ($message -match 'resolver_public_client') $message

# --- Step 1: delegated-snapshot needs the runner VM, which is off by default (ccof-bicep da86afb) ---
$savedSync = $P.sync; $savedRunner = $P.runner
$P.sync = @{} + $savedSync; $P.sync.mode = 'delegated-snapshot'
foreach ($case in @(@{ Name = 'absent enabled'; Runner = @{ vmSize = 'Standard_D2as_v7' } }, @{ Name = 'enabled false'; Runner = @{ enabled = $false } })) {
    Reset-Fakes; $P.runner = $case.Runner
    $message = ''; try { $null = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
    Assert-True "step 1 refuses delegated-snapshot without the runner ($($case.Name)), and changes nothing" ($message -match 'runner_required_for_delegated_snapshot' -and @($script:AzCalls | Where-Object { $_ -notmatch '^(account show|rest --method get)' }).Count -eq 0) $message
}
Reset-Fakes; $P.runner = @{ enabled = $true; vmSize = 'Standard_D2as_v7'; adminUsername = 'ccofadmin'; sshPublicKey = 'ssh-rsa AAAA example' }
$out = $null; $message = ''; try { $out = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 passes delegated-snapshot with runner.enabled true' ($null -ne $out -and $message -notmatch 'runner_required') $message
$P.sync = $savedSync; $P.runner = @{ enabled = $false }
Reset-Fakes
$out = $null; $message = ''; try { $out = Test-QsPrerequisites (New-Step1Context) } catch { $message = $_.Exception.Message }
Assert-True 'step 1 passes application-permission without the runner' ($null -ne $out -and -not $message) $message
$P.runner = $savedRunner

# --- Steps 3 and 4 name the subscription ---
Reset-Fakes
$gen = Join-Path $PSScriptRoot ".env.qs-steps-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $gen | Out-Null
function Read-QsParameters { param([string]$Path) $P }
$fakeBuild = @{ parametersJson = (@{ parameters = @{ tenantId = @{ value = $P.tenantId } } } | ConvertTo-Json -Depth 5) }
function Invoke-QsAz {
    param([string[]]$Arguments)
    $script:AzCalls.Add($Arguments -join ' ')
    if ($Arguments[0] -eq 'bicep') { return $fakeBuild }
    if ($Arguments[0] -eq 'deployment') { return @{ properties = @{ outputs = @{ gatewayUrl = @{ value = 'https://x/anthropic-qs' } } } } }
    if ($Arguments[0] -eq 'rest') { return @{ value = @(@{ name = 'x/resolve' }, @{ name = 'x/health' }, @{ name = 'x/syncEntitlement' }, @{ name = 'x/reconcileBudgets' }) } }
    return ''
}
$ctx = @{ P = $P; ParametersPath = (Join-Path $root 'infra' 'quickstart' 'main.bicepparam'); GeneratedDir = $gen; State = @{ completed = @{ '1' = @{ outputs = @{ apimIdentityAppId = 'a' } }; '2' = @{ outputs = @{} } } } }
# Step 3 now requires the full step-2 report. This fixture tests subscription forwarding;
# Test-ChargebackQuickstart separately builds and validates the actual report.
$workbookPath = Join-Path $gen 'synthetic-workbook.parameters.json'
$workspaceId = "/subscriptions/$($P.names.subscriptionId)/resourceGroups/$($P.names.resourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($P.names.logAnalyticsWorkspace)"
$content = [ordered]@{ version = 'Notebook/1.0'; items = @(1..10 | ForEach-Object { @{ type = 3; name = "synthetic-query-$_"; content = @{ query = 'print 1' } } }) }
@{ parameters = @{
    workbookResourceName = @{ value = $P.workbook.resourceName }; workspaceResourceId = @{ value = $workspaceId }
    workbookContent = @{ value = $content }; contentTags = @{ value = @{ 'ccof-report' = 'fixed-price-v1' } }
} } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $workbookPath -Encoding utf8NoBOM
node -e "const fs=require('node:fs'),crypto=require('node:crypto'),p=process.argv[1],d=JSON.parse(fs.readFileSync(p,'utf8'));d.parameters.contentTags.value['ccof-content']=crypto.createHash('sha256').update(JSON.stringify(d.parameters.workbookContent.value)).digest('hex');fs.writeFileSync(p,JSON.stringify(d));" $workbookPath
Assert-True 'step3 subscription fixture full report digest is generated offline' ($LASTEXITCODE -eq 0)
$ctx.State.completed['2'].outputs.workbookParametersPath = $workbookPath
$null = Invoke-QsDeploy $ctx
$deployCall = @($script:AzCalls | Where-Object { $_ -match '^deployment group create' })
Assert-True 'step 3 deploys with --subscription' ($deployCall.Count -eq 1 -and $deployCall[0] -match "--subscription $($P.names.subscriptionId)( |$)") "calls: $($script:AzCalls -join ' | ')"

function New-CoreAppPackage { param($RepositoryRoot, $App, $Answers, $AnswersDirectory, $StageRoot) $d = Join-Path $StageRoot $App; New-Item -ItemType Directory -Force -Path $d | Out-Null; [pscustomobject]@{ Directory = $d; Digest = "digest-$App"; Missing = @() } }
function New-CoreZip { param($Directory, $ZipPath) Set-Content -LiteralPath $ZipPath -Value 'zip' }
function Invoke-QsNpmCi { param([string]$Directory, [string]$App) }
$script:AzCalls.Clear()
$code = $null; $message = ''; try { $code = Invoke-QsCode $ctx } catch { $message = $_.Exception.Message }
$zipCalls = @($script:AzCalls | Where-Object { $_ -match '^functionapp deployment source config-zip' })
Assert-True 'step 4 deploys each app with config-zip and --subscription' ($zipCalls.Count -eq 3 -and @($zipCalls | Where-Object { $_ -match "--subscription $($P.names.subscriptionId)( |$)" }).Count -eq 3) "message: $message calls: $($script:AzCalls -join ' | ')"
foreach ($app in 'resolver', 'sync', 'reconciler') {
    Assert-True "step 4 deploys the $app package to its app" (@($zipCalls | Where-Object { $_ -match "--name $($P.names.apps[$app].functionApp) " -and $_ -match "$app\.zip" }).Count -eq 1)
}
Remove-Item -LiteralPath $gen -Recurse -Force -ErrorAction SilentlyContinue

# --- After the Graph grant: -Only 3 (the template alone), never -From 3, which reruns steps 4 and 5 ---
$ctx = @{ P = $P; State = @{ completed = @{ '3' = @{ outputs = @{ syncPrincipalId = '00000000-0000-4000-8000-000000000011' } } } } }
$printed = (Show-QsGraphStep $ctx 6>&1 | ForEach-Object { "$_" }) -join "`n"
Assert-True 'step 6 prints the grant command and then -Only 3, never -From 3' ($printed -match 'Grant-SyncGraphPermissions\.ps1' -and $printed -match 'syncTimerEnabled = true' -and $printed -match 'Deploy-Quickstart\.ps1 -Only 3' -and $printed -notmatch '-From 3') $printed
$grant = Get-Content (Join-Path $root 'infra' 'quickstart' 'Grant-SyncGraphPermissions.ps1') -Raw
Assert-True 'Grant-SyncGraphPermissions.ps1 says -Only 3 after the grant, never -From 3' ($grant -match 'Deploy-Quickstart\.ps1 -Only 3' -and $grant -notmatch '-From 3')
$guide = Get-Content (Join-Path $root 'docs' 'QUICKSTART.md') -Raw
Assert-True 'docs/QUICKSTART.md: after the grant, syncTimerEnabled = true and -Only 3' ($guide -match 'syncTimerEnabled = true[^\r\n]*\r?\n[^\r\n]*Deploy-Quickstart\.ps1 -Only 3')
foreach ($file in 'main.bicepparam', 'customer-form.bicepparam') {
    $text = Get-Content (Join-Path $root 'infra' 'quickstart' $file) -Raw
    $line = @(($text -split "`n") | Where-Object { $_ -match 'syncTimerEnabled|Grant-SyncGraphPermissions|-From 3|-Only 3' })
    Assert-True "$file says -Only 3 for syncTimerEnabled, never -From 3" (($line -join ' ') -match '-Only 3' -and $text -notmatch '-From 3') ($line -join ' | ')
}

Write-Host "`n$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
exit 0
