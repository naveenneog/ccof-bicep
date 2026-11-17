# Drift check over the structured preview results that Invoke-CicdDriver.ps1 writes per step
# (docs/runbooks/CICD-ENVIRONMENT-DEPLOYMENT.md, "Drift check"):
#   <step>-preview.result.json   ccof.driver-result.v1: the driver's exit code
#   <step>-preview.whatif.jsonl  ccof.whatif.v1 records: what-if changes (Staged.Common.ps1 Write-StgWhatIfResult,
#                                Invoke-HealthAlerts.ps1), or kind deploymentRecordMatch (Stage 1 after completion)
# Fail closed: a step is clean only when its preview succeeded and every change it measured is NoChange or Ignore.
# Log text is never parsed, so a log that says nothing cannot pass.
Set-StrictMode -Version Latest

$script:Clean = @('NoChange', 'Ignore')
$script:Drift = @('Create', 'Delete', 'Modify')
$script:Unverifiable = @('Deploy', 'Unsupported')

function Read-CicdDriftStep {
    param([string]$Directory, [string]$Step)
    $row = { param($Status, $Detail, $Drift = @(), $Review = @()) [pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail; Drift = @($Drift); Review = @($Review); Counts = '' } }
    $resultPath = Join-Path $Directory "$Step-preview.result.json"
    if (-not (Test-Path -LiteralPath $resultPath)) { return & $row 'NoResult' "no $Step-preview.result.json (the preview did not run through Invoke-CicdDriver.ps1)" }
    try { $res = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 10 } catch { return & $row 'NoResult' "$Step-preview.result.json is not JSON" }
    if ($res -isnot [pscustomobject] -or $res.PSObject.Properties['schema']?.Value -cne 'ccof.driver-result.v1' -or $res.PSObject.Properties['step']?.Value -cne $Step -or $res.PSObject.Properties['mode']?.Value -cne 'preview') {
        return & $row 'NoResult' "$Step-preview.result.json is not a ccof.driver-result.v1 preview record for $Step"
    }
    if ($res.exitCode -isnot [long] -and $res.exitCode -isnot [int]) { return & $row 'NoResult' "$Step-preview.result.json has no exit code" }
    if ($res.exitCode -ne 0) { return & $row 'PreviewFailed' "preview exited $($res.exitCode)" }
    $jsonl = Join-Path $Directory "$Step-preview.whatif.jsonl"
    if (-not (Test-Path -LiteralPath $jsonl)) { return & $row 'Unmeasured' 'preview succeeded but wrote no what-if record' }
    $lines = @(Get-Content -LiteralPath $jsonl | Where-Object { $_.Trim() })
    if (-not $lines.Count) { return & $row 'Unmeasured' 'what-if record file is empty' }
    $drift = [Collections.Generic.List[object]]::new(); $review = [Collections.Generic.List[object]]::new()
    $counts = [ordered]@{}; $matched = @()
    foreach ($l in $lines) {
        try { $rec = $l | ConvertFrom-Json -Depth 20 } catch { return & $row 'Unmeasured' 'what-if record is not JSON' }
        if ($rec -isnot [pscustomobject] -or $rec.PSObject.Properties['schema']?.Value -cne 'ccof.whatif.v1') { return & $row 'Unmeasured' 'what-if record is not ccof.whatif.v1' }
        $source = [string]$rec.PSObject.Properties['source']?.Value
        switch -CaseSensitive ([string]$rec.PSObject.Properties['kind']?.Value) {
            'deploymentRecordMatch' { $matched += $source; continue }
            'whatIf' {
                $changes = @($rec.PSObject.Properties['changes']?.Value | Where-Object { $null -ne $_ })
                if (-not $changes.Count) { return & $row 'Unmeasured' "what-if $source listed no resources" }
                foreach ($c in $changes) {
                    $type = [string]$c.PSObject.Properties['change']?.Value; $id = [string]$c.PSObject.Properties['id']?.Value
                    if (-not $id -or $type -cnotin ($script:Clean + $script:Drift + $script:Unverifiable)) { return & $row 'Unmeasured' "what-if $source has an unrecognised change '$type'" }
                    $counts[$type] = 1 + [int]$counts[$type]
                    $item = [pscustomobject]@{ Step = $Step; Source = $source; Change = $type; Id = $id }
                    if ($type -cin $script:Drift) { $drift.Add($item) } elseif ($type -cin $script:Unverifiable) { $review.Add($item) }
                }
            }
            default { return & $row 'Unmeasured' "what-if record kind '$($rec.PSObject.Properties['kind']?.Value)' is not recognised" }
        }
    }
    $r = if ($drift.Count) { & $row 'Drift' "$($drift.Count) Create, Delete or Modify" $drift $review }
    elseif ($review.Count) { & $row 'Unverifiable' "$($review.Count) Deploy or Unsupported: what-if cannot evaluate them" $drift $review }
    elseif ($counts.Count) { & $row 'Clean' 'every resource NoChange or Ignore' }
    else { & $row 'RecordMatch' "parameters match the recorded deployment ($($matched -join ', ')); resource what-if not run" }
    $r.Counts = ($counts.Keys | ForEach-Object { "$_=$($counts[$_])" }) -join ', '
    return $r
}

# Ok only when every expected step is Clean or RecordMatch.
function Get-CicdDrift {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string[]]$ExpectedStep)
    $names = @($ExpectedStep | Where-Object { $_ } | Select-Object -Unique)
    if (-not $names.Count) { throw 'drift_no_expected_step: name every preview the check must measure (-ExpectedStep).' }
    foreach ($n in $names) { if ($n -cnotmatch '^[a-z0-9][a-z0-9-]{0,60}$') { throw "drift_invalid_step: '$n'" } }
    $steps = @($names | ForEach-Object { Read-CicdDriftStep -Directory $Directory -Step $_ })
    [pscustomobject]@{
        Steps  = $steps
        Drift  = @($steps | ForEach-Object { $_.Drift })
        Review = @($steps | ForEach-Object { $_.Review })
        Ok     = -not @($steps | Where-Object { $_.Status -notin 'Clean', 'RecordMatch' }).Count
    }
}

Export-ModuleMember -Function Get-CicdDrift
