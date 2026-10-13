#Requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Decisions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Azure.psm1')

function Get-OnboardingCreatedGroupId {
    param($Context,[string]$Classification)
    $path="$($Context.CheckpointPath).audit.jsonl"
    if (-not (Test-Path -LiteralPath $path)) {return $null}
    $target="$($Context.Decisions.projectId):$Classification"
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in Get-Content -LiteralPath $path) {
        $event=$line|ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ([string]::Equals($event.stageId,$Context.StageId,'Ordinal') -and
            $event.event -eq 'resource_created' -and [string]::Equals($event.data.target,$target,'Ordinal')) {
            Assert-OnboardingGuid $event.data.resourceId
            $null=$ids.Add($event.data.resourceId)
        }
    }
    if ($ids.Count -gt 1) {Stop-Onboarding "Multiple creation receipts exist for '$target'; operator review is required." 'group_receipt_conflict'}
    if ($ids.Count -eq 1) {return @($ids)[0]}
    return $null
}
Export-ModuleMember -Function Get-OnboardingCreatedGroupId
