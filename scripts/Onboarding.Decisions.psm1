#Requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot 'Checkpoint.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Json.psm1')

function Stop-Onboarding {
    param([string]$Message, [string]$Code = 'precondition_refused')
    $error = [InvalidOperationException]::new($Message)
    $error.Data['OnboardingRefusal'] = $true
    $error.Data['OnboardingCode'] = $Code
    throw $error
}

function ConvertTo-OnboardingCanonical {
    param($Value)
    function Normalize($v) {
        if ($v -is [System.Collections.IDictionary]) {
            $ordered = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            [string[]]$keys = @($v.Keys)
            [array]::Sort($keys, [StringComparer]::Ordinal)
            foreach ($key in $keys) { $ordered[$key] = Normalize $v[$key] }
            return $ordered
        }
        if ($v -is [array]) { return ,@($v | ForEach-Object { Normalize $_ }) }
        if ($null -ne $v -and $v.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
            return Normalize (ConvertFrom-OnboardingJson ($v | ConvertTo-Json -Depth 64))
        }
        return $v
    }
    ConvertTo-Json -InputObject (Normalize $Value) -Depth 64 -Compress
}

function Write-OnboardingAudit {
    param($Context, [string]$Event, [hashtable]$Data = @{})
    $safe = @{}
    foreach ($key in @('questionId','source','operation','target','resourceId','scopeId','projectId','personId','subscriptionId','reasonCode')) {
        if ($Data[$key] -is [string]) { $safe[$key] = $Data[$key] }
    }
    if ($Data.discoveryOnly) { $safe.reasonCode = 'discovery_only' }
    $entry = [ordered]@{
        schemaVersion = 1; timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        runId = $Context.RunId; stageId = $Context.StageId; event = $Event
        actorId = $Context.Actor.objectId; tenantId = $Context.Actor.tenantId; data = $safe
    }
    $parent = Split-Path $Context.CheckpointPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $entry | ConvertTo-Json -Depth 64 -Compress | Add-Content -LiteralPath "$($Context.CheckpointPath).audit.jsonl" -Encoding utf8 -ErrorAction Stop
}

function Get-OnboardingMissingDecisions {
    param($Value, $Schema, [string]$Prefix = '')
    if($Schema.if){
        $condition=Test-Json -Json (ConvertTo-Json -InputObject $Value -Depth 64) -Schema ($Schema.if|ConvertTo-Json -Depth 64) -ErrorAction SilentlyContinue
        $branch=if($condition){$Schema.then}else{$Schema.else}
        if($branch){Get-OnboardingMissingDecisions $Value $branch $Prefix}
    }
    if ($Schema.anyOf) {
        foreach ($choice in $Schema.anyOf) {
            if ($choice.type -eq 'object' -and $Value -is [System.Collections.IDictionary]) {
                Get-OnboardingMissingDecisions $Value $choice $Prefix
            }
        }
        return
    }
    if ($Schema.type -eq 'object') {
        foreach ($name in $Schema.required) {
            $path = if ($Prefix) { "$Prefix.$name" } else { $name }
            if ($Value -isnot [System.Collections.IDictionary] -or -not $Value.Contains($name)) { $path }
        }
        foreach ($name in $Schema.properties.Keys) {
            if ($Value -is [System.Collections.IDictionary] -and $Value.Contains($name)) {
                $path = if ($Prefix) { "$Prefix.$name" } else { $name }
                Get-OnboardingMissingDecisions $Value[$name] $Schema.properties[$name] $path
            }
        }
        if ($Schema.additionalProperties -is [System.Collections.IDictionary] -and $Value -is [System.Collections.IDictionary]) {
            foreach ($name in $Value.Keys) {
                if (-not $Schema.properties -or -not $Schema.properties.Contains($name)) {
                    Get-OnboardingMissingDecisions $Value[$name] $Schema.additionalProperties "$Prefix.$name"
                }
            }
        }
    }
    elseif ($Schema.type -eq 'array' -and $Value -is [array]) {
        for ($i = 0; $i -lt $Value.Count; $i++) { Get-OnboardingMissingDecisions $Value[$i] $Schema.items "$Prefix[$i]" }
    }
}

function Assert-OnboardingSchema {
    param($Value, $Schema)
    $valid = Test-Json -Json (ConvertTo-Json -InputObject $Value -Depth 64 -Compress) `
        -Schema (ConvertTo-Json -InputObject $Schema -Depth 64 -Compress) -ErrorAction SilentlyContinue
    if (-not $valid) { Stop-Onboarding 'Answers failed schema validation (unknown field, invalid type, value or range). See Get-OnboardingSchema and docs/ONBOARDING.md.' }
}

function Add-OnboardingDecision {
    param($Context, [string]$QuestionId, $Value, [string]$Source)
    $entry = @{
        stageId = $Context.StageId; questionId = $QuestionId; value = $Value
        who = $Context.Actor.objectId; when = [DateTimeOffset]::UtcNow.ToString('o'); source = $Source
    }
    Add-CheckpointDecisions -Path $Context.CheckpointPath -Decisions @($entry)
    Write-OnboardingAudit $Context 'decision_recorded' $entry
}

function Save-OnboardingAnswers {
    param($Context, $Values, [string]$Prefix = '')
    foreach ($key in $Values.Keys) {
        $id = if ($Prefix) { "$Prefix.$key" } else { $key }
        if ($Values[$key] -is [System.Collections.IDictionary]) { Save-OnboardingAnswers $Context $Values[$key] $id }
        else { Add-OnboardingDecision $Context $id $Values[$key] $Context.Source }
    }
}

function Confirm-OnboardingDiscovery {
    param($Context, $Discovery)
    $Context.Discovery = $Discovery
    if ($Context.DiscoverOnly) { return $false }
    if ($Context.Interactive) {
        $confirmed = & $Context.Prompt 'confirmedDiscovery' @{ type = 'boolean'; const = $true } $Discovery
        if ($confirmed -isnot [bool] -or -not $confirmed) { Stop-Onboarding 'Discovery was not explicitly confirmed; no remote write was performed.' }
    }
    elseif (-not [string]::Equals((ConvertTo-OnboardingCanonical $Context.Answers.confirmedDiscovery),
            (ConvertTo-OnboardingCanonical $Discovery), 'Ordinal')) {
        Stop-Onboarding 'confirmedDiscovery differs from the live discovery. Review -DiscoverOnly output and confirm the new snapshot before apply.'
    }
    Add-OnboardingDecision $Context 'confirmedDiscovery' $Discovery 'confirmed_discovery'
    $Context.Confirmed = $true
    return $true
}

function Invoke-OnboardingWrite {
    param($Context, [string]$Operation, [string]$Target, [scriptblock]$Action)
    if (-not $Context.Confirmed -or $Context.DiscoverOnly) { Stop-Onboarding 'A remote write requires explicit decision and discovery confirmation.' }
    $result = & $Action
    Write-OnboardingAudit $Context 'write_performed' @{ operation = $Operation; target = $Target }
    return $result
}

function Invoke-OnboardingRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Stage,
        [Parameter(Mandatory)] [hashtable]$Schema,
        [Parameter(Mandatory)] [string]$CheckpointPath,
        [string]$AnswersFile, [switch]$Interactive, [switch]$DiscoverOnly,
        [scriptblock]$Prompt = {
            param($id, $shape, $suggested)
            if ($null -ne $suggested) { Write-Host ($suggested | ConvertTo-Json -Depth 64) }
            $text = Read-Host "$id (JSON; no default; schema: $($shape | ConvertTo-Json -Depth 64 -Compress))"
            if ([string]::IsNullOrWhiteSpace($text)) { Stop-Onboarding "No explicit answer was supplied for $id." }
            ConvertFrom-OnboardingJson $text
        },
        [scriptblock]$GetIdentity = { param($a) Get-OnboardingIdentity -SubscriptionId $a.subscriptionId },
        [Parameter(Mandatory)] [scriptblock]$Body
    )
    $ErrorActionPreference = 'Stop'
    $context = @{
        RunId = [guid]::NewGuid().ToString(); StageId = "stage-$Stage"; CheckpointPath = $CheckpointPath
        Actor = $null; Confirmed = $false; Interactive = [bool]$Interactive; DiscoverOnly = [bool]$DiscoverOnly
        Prompt = $Prompt; Source = if ($Interactive) { 'prompt' } else { 'answers_file' }
    }
    try {
        Write-OnboardingAudit $context 'stage_start'
        if ($Interactive -and $AnswersFile) { Stop-Onboarding 'Choose -Interactive or -AnswersFile, not both.' }
        $answers = @{ schemaVersion = 1; decisions = @{} }
        if ($AnswersFile) {
            try { $answers = ConvertFrom-OnboardingJson (Get-Content -LiteralPath $AnswersFile -Raw) }
            catch { Stop-Onboarding 'AnswersFile is not readable JSON. No remote write was performed.' }
        }
        elseif ($Interactive) {
            foreach ($name in $Schema.required) { $answers.decisions[$name] = & $Prompt $name $Schema.properties[$name] $null }
            if($Schema.if){
                $condition=Test-Json -Json ($answers.decisions|ConvertTo-Json -Depth 64) -Schema ($Schema.if|ConvertTo-Json -Depth 64) -ErrorAction SilentlyContinue
                $branch=if($condition){$Schema.then}else{$Schema.else}
                foreach($name in $branch.required){
                    if(-not $answers.decisions.Contains($name)){$answers.decisions[$name]=& $Prompt $name $Schema.properties[$name] $null}
                }
            }
            if (-not $DiscoverOnly) { $answers.confirm = & $Prompt 'confirm' @{ type = 'boolean'; const = $true } $null }
        }
        $envelope = @{
            type = 'object'; additionalProperties = $false; required = @('schemaVersion', 'decisions')
            properties = @{
                schemaVersion = @{ const = 1 }; decisions = $Schema
                confirm = @{ type = 'boolean' }; confirmedDiscovery = @{ type = 'object' }
                provenance = @{
                    type='object';additionalProperties=$false;required=@('allDecisionValues','ownerConfirmed')
                    properties=@{allDecisionValues=@{const='coordinator_default'};ownerConfirmed=@{type='boolean'}}
                }
            }
        }
        if (-not $DiscoverOnly) {
            $envelope.required += 'confirm'
            if (-not $Interactive) { $envelope.required += 'confirmedDiscovery' }
        }
        $missing = @(Get-OnboardingMissingDecisions $answers $envelope)
        if ($missing.Count) { Stop-Onboarding "Missing decisions: $($missing -join ', '). Supply -AnswersFile or -Interactive. No remote write was performed." }
        Assert-OnboardingSchema $answers $envelope
        if (-not $DiscoverOnly -and -not $answers.confirm) {
            Stop-Onboarding 'An explicit true confirmation is required before apply.' 'confirmation_required'
        }
        if (-not $DiscoverOnly -and $answers.provenance -and -not $answers.provenance.ownerConfirmed) {
            Stop-Onboarding 'Coordinator defaults require explicit owner confirmation before apply.' 'owner_confirmation_required'
        }
        $context.Answers = $answers
        $context.Decisions = $answers.decisions
        $context.Actor = & $GetIdentity $answers.decisions
        if (-not $context.Actor.objectId -or -not [string]::Equals($context.Actor.tenantId, $answers.decisions.tenantId, 'Ordinal')) {
            Stop-Onboarding 'The signed-in identity is missing or belongs to a different tenant than tenantId.'
        }
        if (-not $DiscoverOnly) {
            Save-OnboardingAnswers $context $answers.decisions
            Add-OnboardingDecision $context 'confirm' $true $context.Source
            if ($answers.provenance) { Add-OnboardingDecision $context 'provenance' $answers.provenance $context.Source }
        }
        $evidence = & $Body $context
        if ($DiscoverOnly) {
            Write-OnboardingAudit $context 'completed' @{ discoveryOnly = $true }
            return [pscustomobject]@{ Satisfied = $true; DiscoveryOnly = $true; Discovery = $context.Discovery; Remedy = $null }
        }
        if (-not $context.Confirmed) { Stop-Onboarding 'The stage did not confirm its live discoveries.' }
        Set-CheckpointStageComplete -Path $CheckpointPath -StageId $context.StageId -CompletedBy $context.Actor.objectId -Evidence $evidence
        Write-OnboardingAudit $context 'completed'
        return [pscustomobject]@{ Satisfied = $true; StageId = $context.StageId; Evidence = $evidence; Remedy = $null }
    }
    catch {
        $refused = $_.Exception.Data['OnboardingRefusal'] -eq $true
        $remedy = if ($refused) { $_.Exception.Message } else { 'Stage failed before completion. Verify operator access and provider health, then retry. Provider payloads are not logged.' }
        $code = if ($refused) { $_.Exception.Data['OnboardingCode'] } else { 'provider_operation_failed' }
        Write-OnboardingAudit $context $(if ($refused) { 'precondition_refused' } else { 'failed' }) @{ reasonCode = $code }
        return [pscustomobject]@{ Satisfied = $false; StageId = $context.StageId; ReasonCode = $code; Remedy = $remedy }
    }
}

Export-ModuleMember -Function Invoke-OnboardingRun, Stop-Onboarding, ConvertTo-OnboardingCanonical, Write-OnboardingAudit, Assert-OnboardingSchema, Add-OnboardingDecision, Confirm-OnboardingDiscovery, Invoke-OnboardingWrite, ConvertFrom-OnboardingJson
