#Requires -Version 7.0
<#
.SYNOPSIS
    Local checks of compiled Bicep for the deployment stages (docs/PILOT.md C-9): resource-creation
    templates (D1) contain no role assignment, no application setting and no hardcoded id. Every
    grant is D3 data and every setting is D2's. No Azure call: `az bicep build` compiles locally.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.Schema.psm1')

$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:IgnoredWarnings = @('bicep.use_binary_from_path', 'A new Bicep release is available', 'az bicep upgrade')

function Invoke-CoreBicepBuild {
    <#
    .SYNOPSIS
        Compiles one Bicep file. Returns ExitCode, Template (parsed ARM JSON) and Warnings (linter and
        compiler diagnostics, environment notices removed).
    #>
    param([Parameter(Mandatory)] [string]$Path)
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = az bicep build --file $Path --stdout 2> $stderrFile
        $exit = $LASTEXITCODE
        $diagnostics = @(Get-Content -LiteralPath $stderrFile | Where-Object { $_ -and $_.Trim() })
    }
    finally { Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue }
    $warnings = @($diagnostics | Where-Object {
            $line = $_
            -not @($script:IgnoredWarnings | Where-Object { $line -match [regex]::Escape($_) }).Count
        })
    $template = $null
    if ($exit -eq 0) {
        try { $template = ConvertFrom-CoreJson (($stdout | Out-String)) } catch { $exit = 98; $warnings += 'compiled output is not JSON' }
    }
    [pscustomobject]@{ ExitCode = $exit; Template = $template; Warnings = $warnings }
}

function Get-CoreTemplateResources {
    param($Template)
    $resources = $Template['resources']
    $list = if ($resources -is [System.Collections.IDictionary]) { @($resources.Values) } else { @($resources) }
    foreach ($resource in @($list | Where-Object { $_ })) {
        $resource
        if ([string]$resource['type'] -eq 'Microsoft.Resources/deployments' -and $resource['properties'] -and $resource['properties']['template']) {
            Get-CoreTemplateResources -Template $resource['properties']['template']
        }
    }
}

function Find-CoreTemplateViolations {
    <#
    .SYNOPSIS
        Returns one line per finding: a role assignment or definition, an application or
        authentication setting, or a GUID literal anywhere in the template.
    #>
    param([Parameter(Mandatory)] $Template)
    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($resource in @(Get-CoreTemplateResources -Template $Template)) {
        $type = [string]$resource['type']
        $name = [string]$resource['name']
        if ($type -match '/(roleAssignments|sqlRoleAssignments|sqlRoleDefinitions|roleDefinitions)$') {
            $findings.Add("role assignment or definition: $type (D3 applies grants from data)")
        }
        $siteConfig = if ($resource['properties']) { $resource['properties']['siteConfig'] } else { $null }
        if ($type -eq 'Microsoft.Web/sites' -and $siteConfig -is [System.Collections.IDictionary] -and $siteConfig.Contains('appSettings')) {
            $findings.Add("application setting in $type (D2 deploys settings)")
        }
        if ($type -eq 'Microsoft.Web/sites/config' -and $name -match '(appsettings|authsettingsV2)') {
            $findings.Add("application setting resource $type (D2 deploys settings)")
        }
    }
    $text = ConvertTo-CoreCanonicalJson $Template
    foreach ($match in [regex]::Matches($text, $script:GuidPattern)) {
        $findings.Add("hardcoded id $($match.Value.Substring(0, 8))... (ids come from answers or the D1 record)")
    }
    return $findings.ToArray()
}

Export-ModuleMember -Function Invoke-CoreBicepBuild, Find-CoreTemplateViolations
