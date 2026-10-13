#Requires -Version 7.0
<#
.SYNOPSIS
    A fake Azure for running WP-WB's infra/workbook/deploy.ps1 and verify.ps1 in a test process, with
    no Azure call. Global az, Invoke-RestMethod and node functions take precedence over the Azure CLI,
    the cmdlet and the node executable (about_Command_Precedence), so the scripts run unchanged. az and
    Invoke-RestMethod answer from one in-memory workbook (a D1 shell until a deployment fills it),
    workspace, gateway and reconciler. node runs the real node and records its arguments; with
    -StubNode it answers only the build, with "validated", and runs nothing.
#>

$script:Cloud = $null
$script:RealNode = $null
# The content infra/workbook/resource.bicep (D1) writes: what a re-created shell holds.
$script:Placeholder = '{"version":"Notebook/1.0","items":[{"type":1,"name":"awaiting-configuration","content":{"json":"This workbook resource is ready for D2. Report configuration has not been deployed."}}]}'

function New-WorkbookFakeCloud {
    param([Parameter(Mandatory)] [System.Collections.IDictionary]$Answers, [switch]$StubNode)
    $id = "/subscriptions/$($Answers.subscriptionId)/resourceGroups/$($Answers.resourceGroupName)/providers/Microsoft.Insights/workbooks/$($Answers.workbookResourceName)"
    $cloud = @{
        StubNode = [bool]$StubNode; Tenant = [string]$Answers.tenantId; Retention = [string]$Answers.retentionDays
        WorkspaceCustomerId = '44444444-4444-4444-8444-444444444444'
        Workbook = @{ id = $id; name = [string]$Answers.workbookResourceName; revision = 0; serializedData = $null; tags = @{} }
        Az = [System.Collections.Generic.List[string[]]]::new()
        Node = [System.Collections.Generic.List[string[]]]::new()
        Rest = [System.Collections.Generic.List[string]]::new()
        Queries = 0
    }
    Reset-WorkbookFakeShell $cloud
    return $cloud
}

function Reset-WorkbookFakeShell {
    <# What re-running D1's resource.bicep does to a filled workbook: placeholder content, no ccof-* tags. #>
    param([Parameter(Mandatory)] [hashtable]$Cloud)
    $Cloud.Workbook.serializedData = $script:Placeholder
    $Cloud.Workbook.tags = @{}
    $Cloud.Workbook.revision++
}

function Get-FakeArgument([string[]]$Arguments, [string]$Name) {
    $i = [array]::IndexOf($Arguments, $Name)
    if ($i -ge 0 -and $i + 1 -lt $Arguments.Count) { return $Arguments[$i + 1] }
    return $null
}

function Invoke-FakeAz {
    param([string[]]$Arguments)
    $cloud = $script:Cloud
    $cloud.Az.Add($Arguments)
    $global:LASTEXITCODE = 0
    $ids = Get-FakeArgument $Arguments '--ids'
    $query = Get-FakeArgument $Arguments '--query'
    switch -Regex ((($Arguments | Select-Object -First 4) -join ' ') + ' ') {
        '^account show ' { return $cloud.Tenant }
        '^account get-access-token ' { return 'fake-token' }
        '^monitor log-analytics workspace show ' { return $cloud.WorkspaceCustomerId }
        '^resource show ' {
            if ($query -ceq 'properties.retentionInDays') { return $cloud.Retention }
            if ($query -ceq 'type' -and $ids -match '/providers/([^/]+/[^/]+)/[^/]+$') { return $Matches[1] }
            if (-not $query -and $ids -ieq $cloud.Workbook.id) { return (@{ id = $cloud.Workbook.id; name = $cloud.Workbook.name; kind = 'shared'; type = 'Microsoft.Insights/workbooks' } | ConvertTo-Json -Compress) }
        }
        '^deployment group what-if ' { return '{"changes":[]}' }
        '^deployment group create ' {
            # The deployment writes what the parameters file holds, byte for byte (no JSON round trip).
            $file = [string](Get-FakeArgument $Arguments '--parameters') -replace '^@', ''
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $parameters = [System.Text.Json.JsonDocument]::Parse((Get-Content -LiteralPath $file -Raw)).RootElement.GetProperty('parameters')
                $cloud.Workbook.serializedData = $parameters.GetProperty('workbookContent').GetProperty('value').GetRawText()
                $tags = @{}
                foreach ($tag in $parameters.GetProperty('contentTags').GetProperty('value').EnumerateObject()) { $tags[$tag.Name] = $tag.Value.GetString() }
                $cloud.Workbook.tags = $tags
                $cloud.Workbook.revision++
                return 'Succeeded'
            }
        }
    }
    $global:LASTEXITCODE = 1
}

function Invoke-FakeRest {
    param([string]$Method, [string]$Uri)
    $cloud = $script:Cloud
    $cloud.Rest.Add("$Method $Uri")
    $workbook = $cloud.Workbook
    if ($Method -ceq 'Get' -and $Uri -ceq "https://management.azure.com$($workbook.id)?api-version=2023-06-01&canFetchContent=true") {
        return [pscustomobject]@{
            id = $workbook.id; tags = [pscustomobject]$workbook.tags
            properties = [pscustomobject]@{ serializedData = $workbook.serializedData; revision = "revision-$($workbook.revision)"; timeModified = '2026-10-12T00:00:00Z' }
        }
    }
    if ($Method -ceq 'Post' -and $Uri -ceq "https://api.loganalytics.azure.com/v1/workspaces/$($cloud.WorkspaceCustomerId)/query") {
        $cloud.Queries++
        return [pscustomobject]@{ tables = @([pscustomobject]@{ name = 'PrimaryResult'; columns = @([pscustomobject]@{ name = 'requests'; type = 'long' }); rows = @(, @(2)) }) }
    }
    throw "fake Azure: no such endpoint: $Method $Uri"
}

function Invoke-FakeNode {
    param([string[]]$Arguments, [object[]]$Piped)
    $cloud = $script:Cloud
    $cloud.Node.Add($Arguments)
    if ($cloud.StubNode) {
        $global:LASTEXITCODE = 0
        if ($Arguments.Count -eq 3 -and $Arguments[1] -ceq '--answers') { return '{"schema":"ccof.workbook.build.v1","outcome":"validated"}' }
        $global:LASTEXITCODE = 1
        return '{"outcome":"refused","reason":"stub_node_runs_only_the_build"}'
    }
    if ($Piped.Count) { $Piped | & $script:RealNode @Arguments } else { & $script:RealNode @Arguments }
}

function Enable-WorkbookFakeCloud {
    param([Parameter(Mandatory)] [hashtable]$Cloud)
    $script:Cloud = $Cloud
    $script:RealNode = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    function global:az { Invoke-FakeAz -Arguments ([string[]]$args) }
    function global:Invoke-RestMethod { param([string]$Method, [string]$Uri, $Headers, [string]$ContentType, $Body, $TimeoutSec) Invoke-FakeRest -Method $Method -Uri $Uri }
    function global:node { $piped = @($input); Invoke-FakeNode -Arguments ([string[]]$args) -Piped $piped }
}

function Disable-WorkbookFakeCloud {
    foreach ($name in 'az', 'Invoke-RestMethod', 'node') { Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue }
    $script:Cloud = $null
}

# No function here runs the scripts: a script started from a module function runs in the module's
# session state, where $script: in these stubs would name that script's scope, not this module's.
Export-ModuleMember -Function New-WorkbookFakeCloud, Reset-WorkbookFakeShell, Enable-WorkbookFakeCloud, Disable-WorkbookFakeCloud
