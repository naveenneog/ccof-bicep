#Requires -Version 7.0
Import-Module (Join-Path $PSScriptRoot 'Checkpoint.psm1')
Import-Module (Join-Path $PSScriptRoot 'Onboarding.Decisions.psm1')
function Assert-OnboardingPrerequisites {
    param($Context,[string[]]$RequiredStages)
    $record=Get-CheckpointRecord $Context.CheckpointPath
    $missing=@($RequiredStages|Where-Object{-not (Test-CheckpointStageComplete $record $_)})
    if($missing.Count){Stop-Onboarding "Missing prerequisite checkpoint stages: $($missing -join ', '). The C-9 deployment stages must complete first." 'deployment_prerequisite_missing'}
}
Export-ModuleMember -Function Assert-OnboardingPrerequisites
