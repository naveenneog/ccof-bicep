#Requires -Version 7.0
<#
.SYNOPSIS
    The persisted, multi-stage checkpoint record mechanism (docs/CHECKPOINT-SETUP.md): "a persisted,
    multi-stage record naming which identity completed each stage... resumable by a different person
    and a different machine." Phase 5 (docs/ROADMAP.md M1.5): turns that prose into a real,
    reusable mechanism every checkpointed stage script builds on.

.DESCRIPTION
    This module is deliberately narrow: it only reads and writes the record file. It does not decide
    *whether* a given identity is allowed to complete a stage (role-precondition checking is a
    separate concern - docs/CHECKPOINT-SETUP.md's role matrix varies per stage: Azure RBAC for some,
    Entra directory roles for others, Cosmos data-plane roles for others still). Keeping the record
    mechanism itself stage-agnostic and role-agnostic is what makes it reusable across all of them.
#>
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Json.psm1')

function ConvertTo-CheckpointPayload {
    param($Value)
    if($Value -is [System.Collections.IDictionary]){
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($key in $Value.Keys){if(-not $names.Add($key)){return $Value}}
        $object=[ordered]@{}
        foreach($key in $Value.Keys){$object[$key]=ConvertTo-CheckpointPayload $Value[$key]}
        return [pscustomobject]$object
    }
    if($Value -is [array]){
        $items=[Collections.Generic.List[object]]::new()
        foreach($item in $Value){$items.Add((ConvertTo-CheckpointPayload $item))}
        return ,$items.ToArray()
    }
    return $Value
}

function Get-CheckpointRecord {
    <#
    .SYNOPSIS
        Reads the checkpoint record at Path, or an empty one if it does not exist yet - resuming a
        run (or starting one) never depends on an error path to recognise "nothing has happened yet".
    #>
    param(
        [Parameter(Mandatory)] [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ stages = @(); decisions = @() }
    }
    $raw = ConvertTo-CheckpointPayload (ConvertFrom-OnboardingJson (Get-Content -LiteralPath $Path -Raw))
    # ConvertFrom-Json turns a single-element JSON array into a scalar, not a 1-element array -
    # without this, a record with exactly one completed stage would read back as not an array at
    # all, breaking .Count and Where-Object for every caller.
    $raw | Add-Member -NotePropertyName stages -NotePropertyValue @($raw.stages | Where-Object { $null -ne $_ }) -Force
    $raw | Add-Member -NotePropertyName decisions -NotePropertyValue @($raw.decisions | Where-Object { $null -ne $_ }) -Force
    return $raw
}

function Test-CheckpointStageComplete {
    <#
    .SYNOPSIS
        True if StageId appears as a completed stage in Record (from Get-CheckpointRecord).
    #>
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Record,
        [Parameter(Mandatory)] [string]$StageId
    )
    return $null -ne ($Record.stages | Where-Object { [string]::Equals($_.stageId, $StageId, 'Ordinal') })
}

function Set-CheckpointStageComplete {
    <#
    .SYNOPSIS
        Records StageId as completed by CompletedBy, with Evidence, at the current UTC time.
        Re-completing an already-recorded stage id updates it in place (the same stage retried after
        a transient failure must not leave two conflicting entries for the same stage).
    #>
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$StageId,
        [Parameter(Mandatory)] [string]$CompletedBy,
        [hashtable]$Evidence = @{}
    )
    $record = Get-CheckpointRecord -Path $Path
    $newStage = [PSCustomObject]@{
        stageId     = $StageId
        completedBy = $CompletedBy
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        evidence    = [PSCustomObject]$Evidence
    }

    $remaining = @($record.stages | Where-Object { -not [string]::Equals($_.stageId, $StageId, 'Ordinal') })
    $updatedStages = $remaining + @($newStage)

    $record.stages = $updatedStages
    Save-CheckpointRecord -Path $Path -Record $record
}

function Add-CheckpointDecisions {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object[]]$Decisions
    )
    $record = Get-CheckpointRecord -Path $Path
    $record.decisions = @($record.decisions) + $Decisions
    Save-CheckpointRecord -Path $Path -Record $record
}

function Save-CheckpointRecord {
    param([string]$Path, [object]$Record)
    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # Not Set-Content: it first truncates the file sharing write only, so it fails while any other process (a search
    # indexer, a scanner, an operator's Get-Content) has the record open for reading. This stream shares read; it opens
    # and truncates the file as Set-Content did, because Windows refuses to recreate a hidden file.
    # .NET resolves relative paths against the process directory; resolve them against the current location.
    # A .NET exception only ends the statement, and throw obeys a caller's SilentlyContinue. Write-Error -ErrorAction Stop
    # ends the caller at any preference, as Set-Content -ErrorAction Stop did, with the cause's own message.
    try {
        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 64))
        $stream = [IO.FileStream]::new($fullPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $stream.SetLength(0); $stream.Write($bytes, 0, $bytes.Length) }
        finally { $stream.Dispose() }
    }
    catch {
        $failure = if ($_.Exception -is [Management.Automation.MethodInvocationException] -and $_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
        Write-Error -Exception $failure -Category WriteError -TargetObject $Path -ErrorAction Stop
    }
}

Export-ModuleMember -Function Get-CheckpointRecord, Test-CheckpointStageComplete, Set-CheckpointStageComplete, Add-CheckpointDecisions
