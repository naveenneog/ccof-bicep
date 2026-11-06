Set-StrictMode -Version Latest

# Shared access to frontdoor-state.json for every writer. Reads and writes run under a short exclusive lock
# file next to the state. A save succeeds only while the file still has the content (hash) the caller read,
# so a long-running phase cannot write back a snapshot that another run has changed in the meantime.
function Invoke-DrFrontDoorStateLocked([string]$StatePath, [scriptblock]$Action) {
    $lockPath = Join-Path (Split-Path $StatePath -Parent) 'frontdoor-state.lock'
    $lock = $null
    for ($attempt = 1; -not $lock; $attempt++) {
        try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ($attempt -ge 50) { throw "frontdoor_state_locked: another run is using $StatePath; retry after it finishes." }
            [Threading.Thread]::Sleep(100)
        }
    }
    try { & $Action } finally { $lock.Dispose() }
}

function Get-DrFrontDoorStateHash([byte[]]$Bytes) {
    if ($null -eq $Bytes) { return 'absent' }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}

function Get-DrFrontDoorStateBytes([string]$StatePath) {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    return , [IO.File]::ReadAllBytes($StatePath)
}

# Atomic replace: readers never see a partially written file.
function Write-DrFrontDoorStateBytes([string]$StatePath, [byte[]]$Bytes) {
    $temp = "$StatePath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        [IO.File]::Move($temp, $StatePath, $true)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

# Returns @{ State = <hashtable or $null when absent>; Hash = <hash to pass to Save-DrFrontDoorState> }.
function Read-DrFrontDoorState([Parameter(Mandatory)] [string]$StatePath) {
    $holder = @{ bytes = $null }
    Invoke-DrFrontDoorStateLocked $StatePath { $holder.bytes = Get-DrFrontDoorStateBytes $StatePath }
    $state = $null
    if ($null -ne $holder.bytes) {
        $state = [Text.Encoding]::UTF8.GetString($holder.bytes) | ConvertFrom-Json -AsHashtable -Depth 100
        if ($state -isnot [Collections.IDictionary]) { throw 'frontdoor_state_invalid: inspect and restore the Front Door state before continuing.' }
    }
    return @{ State = $state; Hash = (Get-DrFrontDoorStateHash $holder.bytes) }
}

# Writes atomically when the file still matches ExpectedHash and returns the new hash.
function Save-DrFrontDoorState([Parameter(Mandatory)] [string]$StatePath, [Parameter(Mandatory)] $Value,
    [Parameter(Mandatory)] [string]$ExpectedHash) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 100))
    Invoke-DrFrontDoorStateLocked $StatePath {
        if ((Get-DrFrontDoorStateHash (Get-DrFrontDoorStateBytes $StatePath)) -cne $ExpectedHash) {
            throw "frontdoor_state_changed: $StatePath changed after this run read it; no state was written. Inspect it and rerun the phase."
        }
        Write-DrFrontDoorStateBytes $StatePath $bytes
    }
    return Get-DrFrontDoorStateHash $bytes
}

# Removes evidence fields from the current state regardless of concurrent changes (removing evidence fails
# safe) and records verificationInvalidatedAt, which changes the file so in-flight runs cannot save over it.
# With ExpectedHash, this is a compare-and-clear: nothing is written while the file still matches it.
# Returns $true when the file had changed (or no ExpectedHash was given) and was cleared.
function Clear-DrFrontDoorStateEvidence([Parameter(Mandatory)] [string]$StatePath, [Parameter(Mandatory)] [string[]]$Fields,
    [string]$ExpectedHash) {
    $holder = @{ changed = $false }
    Invoke-DrFrontDoorStateLocked $StatePath {
        $current = Get-DrFrontDoorStateBytes $StatePath
        if ($ExpectedHash -and (Get-DrFrontDoorStateHash $current) -ceq $ExpectedHash) { return }
        $holder.changed = $true
        if ($null -eq $current) { return }
        $state = [Text.Encoding]::UTF8.GetString($current) | ConvertFrom-Json -AsHashtable -Depth 100
        if ($state -isnot [Collections.IDictionary]) { throw 'frontdoor_state_invalid: inspect and restore the Front Door state before continuing.' }
        foreach ($field in $Fields) { $state.Remove($field) }
        $state.verificationInvalidatedAt = [DateTime]::UtcNow.ToString('o')
        Write-DrFrontDoorStateBytes $StatePath ([Text.UTF8Encoding]::new($false).GetBytes(($state | ConvertTo-Json -Depth 100)))
    }
    return $holder.changed
}

Export-ModuleMember -Function Read-DrFrontDoorState, Save-DrFrontDoorState, Clear-DrFrontDoorStateEvidence
