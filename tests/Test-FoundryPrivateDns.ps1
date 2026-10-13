#Requires -Version 7.0
<#
.SYNOPSIS
    Tests infra/poc/foundry-private-dns.bicep (ADR-0013): it compiles, and the compiled template creates the
    Foundry privatelink zones, links them to the VNet with fallback to the internet, and adds one zone group
    to the existing Foundry private endpoint.

.DESCRIPTION
    `az bicep build` compiles locally; no Azure call is made.
#>

$ErrorActionPreference = 'Continue'
$script:Pass = 0
$script:Fail = 0
# An error inside an assertion's condition would otherwise skip that assertion without counting it.
trap { Write-Host "FAIL: unexpected error: $_" -ForegroundColor Red; $script:Fail++; continue }
$bicepPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'infra' 'poc' 'foundry-private-dns.bicep'
$expectedZones = @('privatelink.cognitiveservices.azure.com', 'privatelink.openai.azure.com', 'privatelink.services.ai.azure.com')

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "PASS: $Name" -ForegroundColor Green
        $script:Pass++
    }
    else {
        Write-Host "FAIL: $Name $Detail" -ForegroundColor Red
        $script:Fail++
    }
}

Assert-True "foundry-private-dns.bicep exists" (Test-Path $bicepPath)
if (-not (Test-Path $bicepPath)) {
    Write-Host "`n$script:Pass passed, $script:Fail failed"
    exit 1
}

$stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) "ccof-bicep-$(Get-Random).txt"
$compiled = az bicep build --file $bicepPath --stdout 2>$stderrFile
$compileExit = $LASTEXITCODE
$diagnostics = (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue) + ''
Remove-Item $stderrFile -ErrorAction SilentlyContinue
Assert-True "compiles (az bicep build exit 0)" ($compileExit -eq 0) "exit=$compileExit $diagnostics"
# Only compiler and linter diagnostics count ("<file>(line,col) : Warning <code>: ..."), not az's install or upgrade notices.
$compilerDiagnostics = @($diagnostics -split "`r?`n" | Where-Object { $_ -match '\(\d+,\d+\)\s*:\s*(Warning|Error)\s' })
Assert-True "compiles without warnings" ($compilerDiagnostics.Count -eq 0) "diagnostics: $($compilerDiagnostics -join ' | ')"
if ($compileExit -ne 0) {
    Write-Host "`n$script:Pass passed, $script:Fail failed"
    exit 1
}
$template = ($compiled -join "`n") | ConvertFrom-Json -AsHashtable
$parameters = $template.parameters
$resources = @($template.resources)
function Get-Resource([string]$Type) { @($resources | Where-Object { $_.type -eq $Type }) }

# Parameters: targets come in from outside; Azure-defined zone names and the decided policy are defaults.
Assert-True "the VNet and the private endpoint are required parameters, with no default" ($parameters.vnetName -and $parameters.privateEndpointName -and
    -not $parameters.vnetName.ContainsKey('defaultValue') -and -not $parameters.privateEndpointName.ContainsKey('defaultValue'))
$defaultZones = @($parameters.zoneNames.defaultValue)
Assert-True "the default zones are exactly the three Foundry privatelink zones" ($defaultZones.Count -eq 3 -and
    @($expectedZones | Where-Object { $defaultZones -cnotcontains $_ }).Count -eq 0) "default: $($defaultZones -join ', ')"
Assert-True "at most five zones are accepted (one zone group's limit)" ($parameters.zoneNames.maxLength -eq 5)
Assert-True "the links fall back to the internet by default (ADR-0013)" ($parameters.resolutionPolicy.defaultValue -eq 'NxDomainRedirect' -and
    @($parameters.resolutionPolicy.allowedValues) -contains 'Default')
Assert-True "new resources are tagged ccof-wp=net by default" ($parameters.tags.defaultValue['ccof-wp'] -eq 'net')

# Zones.
$zones = @(Get-Resource 'Microsoft.Network/privateDnsZones')
Assert-True "one private DNS zone resource, looped over zoneNames" ($zones.Count -eq 1 -and $zones[0].copy.count -match "length\(parameters\('zoneNames'\)\)")
Assert-True "zones are global and tagged" ($zones[0].location -eq 'global' -and $zones[0].tags -match "parameters\('tags'\)")
Assert-True "the zone API version supports links with a resolution policy (2024-06-01 or later)" ($zones[0].apiVersion -ge '2024-06-01') "apiVersion: $($zones[0].apiVersion)"

# VNet links.
$links = @(Get-Resource 'Microsoft.Network/privateDnsZones/virtualNetworkLinks')
$link = $links | Select-Object -First 1
Assert-True "one VNet link per zone, looped over zoneNames" ($links.Count -eq 1 -and $link.copy.count -match "length\(parameters\('zoneNames'\)\)")
Assert-True "links do not auto-register VM records" ($link.properties.registrationEnabled -eq $false)
Assert-True "links use the resolution policy parameter" ($link.properties.resolutionPolicy -eq "[parameters('resolutionPolicy')]")
Assert-True "links point at the named VNet" ($link.properties.virtualNetwork.id -match "resourceId\('Microsoft\.Network/virtualNetworks', parameters\('vnetName'\)\)")
Assert-True "the link API version supports resolutionPolicy (2024-06-01 or later)" ($link.apiVersion -ge '2024-06-01') "apiVersion: $($link.apiVersion)"
Assert-True "links are created after the zone group, so records exist before the VNet sees the zones" ([bool](@($link.dependsOn) -match 'privateDnsZoneGroups'))

# Zone group on the existing endpoint.
$groups = @(Get-Resource 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups')
$group = $groups | Select-Object -First 1
Assert-True "exactly one zone group, named default, on the named endpoint" ($groups.Count -eq 1 -and $group.name -match "parameters\('privateEndpointName'\)" -and $group.name -match "'default'")
$configs = @($group.properties.copy | Where-Object { $_.name -eq 'privateDnsZoneConfigs' })
Assert-True "the zone group names every zone (one config per zoneNames entry)" ($configs.Count -eq 1 -and $configs[0].count -match "length\(parameters\('zoneNames'\)\)" -and
    $configs[0].input.properties.privateDnsZoneId -match "resourceId\('Microsoft\.Network/privateDnsZones', parameters\('zoneNames'\)\[copyIndex\('privateDnsZoneConfigs'\)\]\)")
Assert-True "the endpoint itself is not redeployed" (@(Get-Resource 'Microsoft.Network/privateEndpoints').Count -eq 0)
Assert-True "the VNet itself is not redeployed" (@(Get-Resource 'Microsoft.Network/virtualNetworks').Count -eq 0)

# No environment-specific literal in the template.
$source = Get-Content $bicepPath -Raw
Assert-True "the template names no PoC resource" ($source -notmatch 'sample-pilot')
Assert-True "the template contains no GUID" ($source -notmatch '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')

Write-Host "`n$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
exit 0
