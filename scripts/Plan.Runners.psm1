#Requires -Version 7.0
<#
.SYNOPSIS
    The stage functions the plan report reuses in their read-only forms (WP-PLAN): D2 and D3
    -Action Plan, and onboarding Stages 1, 2 and 3 in -DiscoverOnly (Stage 3 as its public preflight).
    Nothing here writes to Azure, Microsoft Graph, Cosmos, the checkpoint or the answers.

.DESCRIPTION
    - Every provider call goes through the Send of the run context: New-PlanReadOnlySend's guard,
      which sends only GET.
    - D3's Plan writes an audit line when it refuses, and an onboarding -DiscoverOnly run writes
      stage_start and completed audit lines, next to the checkpoint they are given. Each stage gets a
      temporary copy (New-PlanCheckpointCopy), never the real record.
    - The onboarding stages' write operations (CreateGroup, AddOwner, CreateBackend, AssignRole,
      CreateProject) are stubs that refuse and are logged in the context's Writes. D2's pieces are
      stubs too; its Plan does not call them.
    The stage scripts are dot-sourced here as their own tests do; the modules their closures call are
    then imported globally, where those closures look for them.
#>

foreach ($stageScript in @('Stage-D2-DeploySchemaAndApps.ps1', 'Stage-D3-GrantPermissions.ps1', 'Stage1-CreateClassificationGroups.ps1', 'Stage2-RegisterBackend.ps1', 'Stage3-RegisterProject.ps1')) {
    . (Join-Path $PSScriptRoot $stageScript) -DotSourceOnly
}
foreach ($name in @('Checkpoint', 'StagePrecondition', 'Onboarding.Json', 'Onboarding.Decisions', 'Onboarding.Schemas', 'Onboarding.Azure', 'Onboarding.Groups', 'Onboarding.Prerequisites', 'Onboarding.Backend', 'Onboarding.Projects', 'Onboarding.Cosmos', 'Onboarding.DependencyPlan', 'Core.Schema', 'Core.Answers', 'Core.Rest', 'Core.Permissions', 'Core.PermissionsApply', 'Core.D2Steps', 'Core.D2Apim', 'Core.D2Code', 'Core.D2Stage')) {
    Import-Module (Join-Path $PSScriptRoot "$name.psm1") -Global -DisableNameChecking
}

function New-PlanCheckpointCopy {
    <# A copy of the checkpoint (or none, for an empty record) in a new folder, with no audit file yet. #>
    param([Parameter(Mandatory)] [string]$CheckpointPath, [string]$WorkDirectory = [IO.Path]::GetTempPath())
    $directory = Join-Path $WorkDirectory "ccof-plan-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $path = Join-Path $directory 'checkpoint.json'
    if (Test-Path -LiteralPath $CheckpointPath -PathType Leaf) { Copy-Item -LiteralPath $CheckpointPath -Destination $path }
    [pscustomobject]@{ Directory = $directory; Path = $path }
}

function Remove-PlanCheckpointCopy {
    param([Parameter(Mandatory)] $Copy)
    if ($Copy.Directory -and (Test-Path -LiteralPath $Copy.Directory)) { Remove-Item -LiteralPath $Copy.Directory -Recurse -Force }
}

function New-PlanRunContext {
    <# What every runner needs: the guard's Send, the operator, the role lookups, the checkpoint copy. #>
    param(
        [Parameter(Mandatory)] [scriptblock]$Send, [Parameter(Mandatory)] [hashtable]$Identity, [Parameter(Mandatory)] [hashtable]$Access,
        [Parameter(Mandatory)] [string]$CheckpointCopy, [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent), [string]$SourcesPath
    )
    @{ Send = $Send; Identity = $Identity; Access = $Access; Checkpoint = $CheckpointCopy; RepositoryRoot = $RepositoryRoot; SourcesPath = $SourcesPath; Writes = [System.Collections.Generic.List[string]]::new() }
}

function New-PlanRefusal {
    # A stub for a write operation: logs it and refuses.
    param([System.Collections.Generic.List[string]]$Writes, [string]$Name)
    { $Writes.Add($Name); throw "The plan report refused the write operation $Name." }.GetNewClosure()
}

function Get-PlanOnboardingOperations {
    <# The operations an onboarding stage reads through, over the guard, with its write operations refused. #>
    param([Parameter(Mandatory)] [hashtable]$Context, [Parameter(Mandatory)] [ValidateSet('1', '2', '3')] [string]$Stage, [Parameter(Mandatory)] [System.Collections.IDictionary]$Decisions)
    $send = $Context.Send
    # Invoke-OnboardingRest's semantics: GET 404 is $null, any other non-2xx throws.
    $adapter = { param($m, $u, $b) $x = & $send $m $u $b; if ($x.Status -eq 404 -and $m -eq 'GET') { return $null }; if ($x.Status -lt 200 -or $x.Status -ge 300) { throw "Provider request failed (HTTP $($x.Status))." }; $x.Content }.GetNewClosure()
    $graph = New-OnboardingGraphOperations -SubscriptionId ([string]$Decisions.subscriptionId) -Send $adapter
    foreach ($write in @('CreateGroup', 'AddOwner')) { $graph[$write] = New-PlanRefusal $Context.Writes $write }
    if ($Stage -eq '1') { return $graph }
    $backend = New-OnboardingBackendOperations -Decisions $Decisions -Send $adapter
    foreach ($write in @('CreateBackend', 'AssignRole')) { $backend[$write] = New-PlanRefusal $Context.Writes $write }
    if ($Stage -eq '2') { return $backend }
    @{ GetGroup = $graph.GetGroup; GetMembers = $graph.GetMembers; GetBackend = $backend.GetBackend
        GetRegistryAccount = (New-PlanRefusal $Context.Writes 'GetRegistryAccount'); GetPrivateAddresses = (New-PlanRefusal $Context.Writes 'GetPrivateAddresses')
        GetProject = (New-PlanRefusal $Context.Writes 'GetProject'); CreateProject = (New-PlanRefusal $Context.Writes 'CreateProject') }
}

function Get-PlanStageRoleLookup {
    <# The stages' -GetCurrentAssignments, answered from the plan's read-only role lookups. #>
    param([Parameter(Mandatory)] [hashtable]$Access)
    {
        param($Scope, $Kind, $Context)
        $found = switch ($Kind) {
            'directory' { & $Access.DirectoryRoles }
            'cosmos' { & $Access.CosmosRoles ([string]$Context.Decisions.registry.accountResourceId) $Scope }
            default { & $Access.AzureRoles $Scope }
        }
        @($found.Roles) | ForEach-Object { [pscustomobject]@{ roleDefinitionName = $_ } }
    }.GetNewClosure()
}

function Invoke-PlanD2 {
    <# D2 -Action Plan (Invoke-StageD2), with -Steps when given. Returns D2's own result. #>
    param([Parameter(Mandatory)] [hashtable]$Context, [Parameter(Mandatory)] [string]$AnswersPath, [string[]]$Steps)
    $identity = $Context.Identity
    $pieces = @{}
    foreach ($piece in @('Build', 'InstallProduction', 'Publish', 'Http', 'GatewayRender', 'GatewayDeploy', 'Diagnostics', 'ResolverAuth', 'Workbook')) { $pieces[$piece] = New-PlanRefusal $Context.Writes "D2 piece $piece" }
    $arguments = @{ Action = 'Plan'; AnswersPath = $AnswersPath; CheckpointPath = $Context.Checkpoint; RepositoryRoot = $Context.RepositoryRoot
        Send = $Context.Send; Pieces = $pieces; GetIdentity = { param($s) $identity }.GetNewClosure(); Sleep = { param($s) } }
    if ($PSBoundParameters.ContainsKey('Steps')) { $arguments.Steps = $Steps }
    Invoke-StageD2 @arguments
}

function Invoke-PlanD3 {
    <# D3 -Action Plan (Invoke-StageD3). Returns D3's own result: ReasonCode, Digest, Summary or Remedy. #>
    param([Parameter(Mandatory)] [hashtable]$Context, [Parameter(Mandatory)] [string]$AnswersPath)
    $identity = $Context.Identity
    $arguments = @{ Action = 'Plan'; AnswersPath = $AnswersPath; CheckpointPath = $Context.Checkpoint; RepositoryRoot = $Context.RepositoryRoot
        Send = $Context.Send; GetIdentity = { param($s) $identity }.GetNewClosure(); Sleep = { param($s) } }
    if ($Context.SourcesPath) { $arguments.SourcesPath = $Context.SourcesPath }
    Invoke-StageD3 @arguments
}

function Invoke-PlanDiscovery {
    <#
    .SYNOPSIS
        Onboarding Stage 1, 2 or 3 (the public preflight) in -DiscoverOnly, from an onboarding answers
        file. Returns the stage's own result: Satisfied, DiscoveryOnly and Discovery, or ReasonCode
        and Remedy.
    #>
    param([Parameter(Mandatory)] [hashtable]$Context, [Parameter(Mandatory)] [ValidateSet('1', '2', '3')] [string]$Stage, [Parameter(Mandatory)] [string]$AnswersFile)
    try { $decisions = (ConvertFrom-OnboardingJson (Get-Content -LiteralPath $AnswersFile -Raw -ErrorAction Stop)).decisions }
    catch { return [pscustomobject]@{ Satisfied = $false; ReasonCode = 'answers_unreadable'; Remedy = "The onboarding answers file $AnswersFile is not readable JSON." } }
    if ($decisions -isnot [System.Collections.IDictionary] -or [string]$decisions.subscriptionId -notmatch '^[0-9a-fA-F-]{36}$') {
        return [pscustomobject]@{ Satisfied = $false; ReasonCode = 'answers_unreadable'; Remedy = "The onboarding answers file $AnswersFile has no decisions.subscriptionId." }
    }
    $identity = $Context.Identity
    $arguments = @{ AnswersFile = $AnswersFile; CheckpointPath = $Context.Checkpoint; DiscoverOnly = $true
        GetIdentity = { param($a) $identity }.GetNewClosure(); GetCurrentAssignments = (Get-PlanStageRoleLookup -Access $Context.Access)
        Operations = (Get-PlanOnboardingOperations -Context $Context -Stage $Stage -Decisions $decisions) }
    switch ($Stage) {
        '1' { Invoke-Stage1CreateGroups @arguments }
        '2' { Invoke-Stage2RegisterBackend @arguments }
        '3' { Invoke-Stage3RegisterProject @arguments -PublicPreflight }
    }
}

Export-ModuleMember -Function New-PlanCheckpointCopy, Remove-PlanCheckpointCopy, New-PlanRunContext, Get-PlanOnboardingOperations, Invoke-PlanD2, Invoke-PlanD3, Invoke-PlanDiscovery
