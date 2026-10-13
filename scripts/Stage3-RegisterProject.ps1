#Requires -Version 7.0
<#
.SYNOPSIS
    Stage 3: validate a project document and create it from a private-endpoint-reachable runner.
#>
[CmdletBinding()]
param([switch]$DotSourceOnly,[string]$AnswersFile,[string]$CheckpointPath,[switch]$Interactive,[switch]$DiscoverOnly,
    [switch]$PublicPreflight,[string]$PlanPath,[string]$DependencyPlan)
foreach ($module in @('Decisions','Schemas','Azure','Backend','Projects','Cosmos','DependencyPlan','Prerequisites')) { Import-Module (Join-Path $PSScriptRoot "Onboarding.$module.psm1") }

function Invoke-Stage3RegisterProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CheckpointPath,[string]$AnswersFile,[switch]$Interactive,[switch]$DiscoverOnly,
        [scriptblock]$Prompt,[scriptblock]$GetIdentity,[scriptblock]$GetCurrentAssignments,[hashtable]$Operations,
        [switch]$PublicPreflight,[string]$PlanPath,[string]$DependencyPlan,[scriptblock]$Clock={[DateTimeOffset]::UtcNow}
    )
    $run=@{Stage='3';Schema=(Get-OnboardingSchema '3');CheckpointPath=$CheckpointPath;AnswersFile=$AnswersFile;Interactive=$Interactive;DiscoverOnly=$DiscoverOnly}
    if ($Prompt) {$run.Prompt=$Prompt};if ($GetIdentity) {$run.GetIdentity=$GetIdentity}
    $body={
        param($c)
        $a=$c.Decisions
        $project=ConvertTo-OnboardingProjectDocument $a.project
        $c.StageId="stage-3-project:$($project.projectId)"
        Assert-OnboardingPrerequisites $c @('stage-D1')
        if(-not $PublicPreflight){Assert-OnboardingPrerequisites $c @('stage-D2:schema','stage-D3')}
        Assert-OnboardingResilience $a.resilience
        $usePlan=[string]::Equals($a.dependencyValidation.mode,'approved_plan','Ordinal')
        $c.RequireGraphFreeAzureRoleLookup=$usePlan -and -not $PublicPreflight
        if(($PublicPreflight -or $DependencyPlan) -and -not $usePlan){Stop-Onboarding 'The selected operation needs dependencyValidation.mode approved_plan.' 'dependency_mode_mismatch'}
        if(-not $usePlan -and $null -ne $a.dependencyValidation.validUntil){Stop-Onboarding 'Live dependency validation uses an explicit null validUntil.' 'dependency_mode_mismatch'}
        if($PublicPreflight -and -not $DiscoverOnly -and -not $PlanPath){Stop-Onboarding 'PlanPath is required for a reviewed public preflight.' 'plan_path_required'}
        $ops=if ($Operations) {$Operations} else {
            $all=New-OnboardingRegistryOperations $a.registry
            $graph=New-OnboardingGraphOperations $a.subscriptionId
            $backend=New-OnboardingBackendOperations $a
            foreach ($name in @('GetGroup','GetMembers')) {$all[$name]=$graph[$name]}
            $all.GetBackend=$backend.GetBackend
            $all
        }
        $plan=$null
        if($PublicPreflight -or -not $usePlan){
            Assert-OnboardingRole $c $a.apimResourceId @('Reader','Contributor','Owner','API Management Service Reader Role','API Management Service Contributor') $GetCurrentAssignments
            if($PublicPreflight){$null=Assert-OnboardingPlanDeadline $a (& $Clock)}
            $dependencies=Get-OnboardingDependencyEvidence $project $ops $a.backendRegistrationMode
        }
        else {
            $plan=Read-OnboardingDependencyPlan $DependencyPlan $a (& $Clock)
            $dependencies=$plan.evidence
        }
        if($PublicPreflight){
            $c.StageId="stage-3-preflight:$($project.projectId)"
            $discovery=@{dependencies=$dependencies;validUntil=$a.dependencyValidation.validUntil;preparedBy=$c.Actor.objectId}
            if(-not (Confirm-OnboardingDiscovery $c $discovery)){return}
            $plan=New-OnboardingDependencyPlan $c $dependencies (& $Clock)
            $parent=Split-Path $PlanPath -Parent
            if($parent -and -not (Test-Path -LiteralPath $parent)){New-Item -ItemType Directory $parent -Force|Out-Null}
            $plan|ConvertTo-Json -Depth 64|Set-Content -LiteralPath $PlanPath -Encoding utf8 -ErrorAction Stop
            return @{projectId=$project.projectId;planDigest=$plan.digest;preparedBy=$plan.preparedBy;validUntil=$plan.validUntil}
        }
        Assert-OnboardingRole $c $a.registry.accountResourceId @('Reader','Contributor','Owner') $GetCurrentAssignments
        $scope="$($a.registry.accountResourceId)/dbs/$($a.registry.database)/colls/projects"
        Assert-OnboardingRole $c $scope @('Cosmos Onboarding Writer') $GetCurrentAssignments 'cosmos'
        $network=Assert-OnboardingPrivateRegistry $a.registry $ops
        $existing=& $ops.GetProject $project.projectId
        if ($existing) {
            $existing=ConvertTo-OnboardingProjectDocument $existing -FromCosmos
            if (-not [string]::Equals((ConvertTo-OnboardingCanonical $existing),(ConvertTo-OnboardingCanonical $project),'Ordinal')) {
                Stop-Onboarding 'An existing project has different configuration. Registration does not overwrite budgets, models or routing; an approved configuration-change stage is required.'
            }
        }
        $discovery=@{registry=$network;dependencyEvidenceHash=(Get-OnboardingDependencyHash $dependencies);backendId=$project.backendId
            projectState=$(if($existing){'present'}else{'absent'});runnerId=$c.Actor.objectId;planDigest=$plan.digest}
        if(-not $usePlan){$discovery.dependencies=$dependencies}
        if (-not (Confirm-OnboardingDiscovery $c $discovery)) {return}
        if($usePlan){$plan=Read-OnboardingDependencyPlan $DependencyPlan $a (& $Clock)}
        $charge=$null
        if (-not $existing) {
            $write=Invoke-OnboardingWrite $c 'create_project' $project.projectId ({& $ops.CreateProject $project}.GetNewClosure())
            $charge=$write.requestChargeRu
        }
        $readBack=& $ops.GetProject $project.projectId
        if(-not $readBack){Stop-Onboarding 'The project could not be read back; registration is not complete.' 'project_readback_missing'}
        $verified=ConvertTo-OnboardingProjectDocument $readBack -FromCosmos
        if(-not [string]::Equals((ConvertTo-OnboardingCanonical $verified),(ConvertTo-OnboardingCanonical $project),'Ordinal')){
            Stop-Onboarding 'Project read-back differs from the approved document; registration is not complete.' 'project_readback_mismatch'
        }
        @{projectId=$project.projectId;backendId=$project.backendId;requestChargeRu=$charge;alreadyComplete=($null -ne $existing);resilience=$a.resilience
            readBackVerified=$true;preparedBy=$plan.preparedBy;planDigest=$plan.digest}
    }.GetNewClosure()
    Invoke-OnboardingRun @run -Body $body
}
if (-not $DotSourceOnly) {
    $result=Invoke-Stage3RegisterProject -AnswersFile $AnswersFile -CheckpointPath $CheckpointPath -Interactive:$Interactive -DiscoverOnly:$DiscoverOnly `
        -PublicPreflight:$PublicPreflight -PlanPath $PlanPath -DependencyPlan $DependencyPlan
    $result|ConvertTo-Json -Depth 64
    if (-not $result.Satisfied) {exit 1}
}
