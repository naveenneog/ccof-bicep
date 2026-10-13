#Requires -Version 7.0
<#
.SYNOPSIS
    Prints the sync's recent telemetry lines (ccof.sync.run.v1 and ccof.sync.event.v1) from the
    Log Analytics workspace behind the sync app's Application Insights (docs/SYNC.md).

.DESCRIPTION
    Read-only. Uses the caller's Azure CLI login for a Log Analytics token and the query API
    (Learn "Azure Monitor Logs API request format"). The KQL goes in a JSON body, not on the az
    command line, because az.cmd on Windows re-parses '|'.

.EXAMPLE
    pwsh -NoProfile -File infra/sync/Get-SyncRunLines.ps1 -AnswersFile infra/sync/sync.answers.pilot.json -Minutes 30
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AnswersFile,
    [Parameter(Mandatory)] [ValidateRange(1, 1440)] [int] $Minutes,
    [switch] $RunLinesOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SyncDeploy.psm1') -Force
$answers = Read-SyncAnswers -Path $AnswersFile
$problems = Test-SyncAnswers $answers
if ($problems.Count -gt 0) { throw "The answers file is incomplete or invalid: $($problems -join ', ')" }

$customerId = az monitor log-analytics workspace show --ids $answers.logAnalyticsWorkspaceId --subscription $answers.subscriptionId --query customerId -o tsv
if ($LASTEXITCODE -ne 0 -or -not $customerId) { throw 'Cannot read the workspace id; check the login and logAnalyticsWorkspaceId.' }
$token = az account get-access-token --resource https://api.loganalytics.io --subscription $answers.subscriptionId --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Cannot get a Log Analytics token with the current login.' }

$schemaFilter = if ($RunLinesOnly) { '{"schema":"ccof.sync.run.v1"' } else { '{"schema":"ccof.sync.' }
$query = @"
AppTraces
| where AppRoleName =~ '$($answers.functionAppName)'
| where Message startswith '$schemaFilter'
| project TimeGenerated, Message
| order by TimeGenerated asc
"@
$body = @{ query = $query; timespan = "PT$($Minutes)M" } | ConvertTo-Json
$result = Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.azure.com/v1/workspaces/$customerId/query" `
    -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $body
foreach ($row in $result.tables[0].rows) { $row[1] }
