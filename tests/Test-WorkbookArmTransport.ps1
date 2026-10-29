#Requires -Version 7.0
<#
.SYNOPSIS
    Offline regression for Stage 5's nested ARM workbook parameter boundary.
    Checks the compiled transport, not Azure what-if acceptance.
#>
[CmdletBinding()]
param([string]$BicepPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $BicepPath) {
    $command = Get-Command bicep -ErrorAction SilentlyContinue
    if ($command) { $BicepPath = $command.Source }
    else { $BicepPath = Join-Path $HOME '.azure\bin\bicep.exe' }
}
$compiled = & $BicepPath build (Join-Path $root 'infra\staged\stage5-config.bicep') --stdout 2>$null
if ($LASTEXITCODE) { throw 'Stage 5 Bicep build failed.' }
$arm = ($compiled -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100
$module = @($arm.resources | Where-Object { $_.properties.template.resources.type -contains 'Microsoft.Insights/workbooks' })[0]

function Assert-Transport($Deployment) {
    $p = $Deployment.properties.parameters
    if ($p.workbookContent.value.Count -ne 0 -or
        $p.workbookSerializedData.value -cne "[string(parameters('workbookContent'))]") {
        throw 'workbook_arm_transport: serialize before the nested deployment; never pass content as an object.'
    }
    $template = $Deployment.properties.template
    if ($template.parameters.workbookSerializedData.type -cne 'string' -or
        $template.parameters.workbookSerializedData.defaultValue -cne "[string(parameters('workbookContent'))]" -or
        $template.resources[0].properties.serializedData -cne "[parameters('workbookSerializedData')]") {
        throw 'workbook_arm_transport: retain legacy object serialization and consume serialized data without reparsing.'
    }
}
Assert-Transport $module
if ($module.condition -cne "[not(empty(parameters('workbookContent')))]" -or
    $module.properties.parameters.contentTags.value -cne "[parameters('workbookContentTags')]") {
    throw 'Empty workbook opt-out or content tags changed.'
}

# Negative control: restore the old object transport while retaining the other new wiring.
$mutant = $module | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
$mutant.properties.parameters.workbookContent.value = "[parameters('workbookContent')]"
$caught = $false
try { Assert-Transport $mutant } catch { $caught = $_.Exception.Message -like 'workbook_arm_transport:*' }
if (-not $caught) { throw 'Negative control: the original unsafe object transport was accepted.' }

# Use the real builder, including its Period dropdown string and canonical content digest.
Push-Location $root
try {
    $json = node --input-type=module -e @'
import { buildChargebackWorkbook } from "./analytics/workbooks/chargeback.ts";
import { workbookAnswers, workbookRateCard } from "./tests/helpers/workbook-fixtures.ts";
const ledger = "let CcofUsageLedger = (fromTime:datetime, toTime:datetime, resourceId:string) { datatable(timestamp:datetime)[] };";
const built = buildChargebackWorkbook(workbookAnswers(), workbookRateCard(), ledger, []);
console.log(JSON.stringify({ workbook: built.workbook, digest: built.contentSha256 }));
'@
    if ($LASTEXITCODE) { throw 'Workbook fixture build failed.' }
} finally { Pop-Location }
$built = $json | ConvertFrom-Json -AsHashtable -Depth 100
$period = @($built.workbook.items | Where-Object name -CEQ 'period')[0]
$selector = @($period.content.parameters | Where-Object name -CEQ 'Period')[0].jsonData
if ($selector -cnotlike '[[]*' -or ($selector | ConvertFrom-Json).Count -ne 3) { throw 'Fixture no longer reproduces the JSON-array string.' }

# ARM does not parse the contents of a serialized JSON string as template expressions.
# Mirror string(object), then consume the child string parameter directly, as the compiled template requires.
$serialized = $built.workbook | ConvertTo-Json -Depth 100 -Compress
$roundTrip = $serialized | ConvertFrom-Json -AsHashtable -Depth 100
if (($roundTrip | ConvertTo-Json -Depth 100 -Compress) -cne $serialized) { throw 'Workbook round trip changed its content.' }
$digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($serialized))).ToLowerInvariant()
if ($digest -cne $built.digest) { throw 'Workbook content digest changed.' }
if (@($roundTrip.items | Where-Object name -CEQ 'period')[0].content.parameters[0].jsonData -cne $selector) {
    throw 'Period JSON was escaped or changed.'
}
Write-Host 'PASS: compiled Stage 5 string transport, legacy fallback, real dropdown round trip and unsafe-object negative control.'
