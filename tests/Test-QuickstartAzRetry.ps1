#Requires -Version 7.0
<#
.SYNOPSIS
    Invoke-QsAz retries only the Cloud Shell token-broker timeout ("Timeout waiting for token from
    portal", live 2026-10-14) and fails at once on every other az error. Fake az; no Azure call.
#>
$ErrorActionPreference = 'Continue'
$script:Pass = 0; $script:Fail = 0
$root = Split-Path $PSScriptRoot -Parent
function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green; $script:Pass++ }
    else { Write-Host "FAIL: $Name $Detail" -ForegroundColor Red; $script:Fail++ }
}
. (Join-Path $root 'infra' 'quickstart' 'Deploy-Quickstart.ps1') -DotSourceOnly
$script:QsTokenRetrySeconds = @(0, 0, 0)
$timeout = 'ERROR: Timeout waiting for token from portal. Audience: https://graph.microsoft.com/'

function az { $script:Calls++; $answer = $script:Answers[[Math]::Min($script:Calls, $script:Answers.Count) - 1]; $global:LASTEXITCODE = $answer.Code; $answer.Out }

$script:Calls = 0; $script:Answers = @(@{ Code = 1; Out = $timeout }, @{ Code = 0; Out = '{"id":"g1"}' })
$r = $null; $m = ''; try { $r = Invoke-QsAz @('rest', '--method', 'get', '--url', 'https://graph.microsoft.com/v1.0/groups/g1') } catch { $m = $_.Exception.Message }
Assert-True 'a token-broker timeout is retried and the later answer returned' ($r.id -ceq 'g1' -and $script:Calls -eq 2 -and -not $m) "calls=$script:Calls $m"

$script:Calls = 0; $script:Answers = @(@{ Code = 1; Out = $timeout })
$m = ''; try { $null = Invoke-QsAz @('rest', '--method', 'get', '--url', 'https://graph.microsoft.com/v1.0/groups/g1') } catch { $m = $_.Exception.Message }
Assert-True 'a timeout that persists fails after three retries, naming the recovery' ($script:Calls -eq 4 -and $m -match 'Reload the Azure Portal' -and $m -match 'get-access-token --resource https://graph') "calls=$script:Calls $m"

$script:Calls = 0; $script:Answers = @(@{ Code = 1; Out = "ERROR: Please run 'az login' to setup account." })
$m = ''; try { $null = Invoke-QsAz @('rest', '--method', 'get', '--url', 'https://graph.microsoft.com/v1.0/groups/g1') } catch { $m = $_.Exception.Message }
Assert-True 'any other az error fails at once without retry' ($script:Calls -eq 1 -and $m -match "az login") "calls=$script:Calls $m"

Write-Host "$script:Pass passed, $script:Fail failed"
if ($script:Fail) { exit 1 }
