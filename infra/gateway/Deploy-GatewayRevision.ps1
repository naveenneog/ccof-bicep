#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the gateway policy as a NEW, NON-CURRENT revision of the configured API, or makes an
    existing revision current (-MakeCurrent). Rollback is -MakeCurrent for the previous revision.

.DESCRIPTION
    Create (default):
      1. Renders the policy from -ConfigPath (infra/gateway/render.ts validates the configuration;
         a missing or invalid value refuses here, before any Azure call).
      2. Reads the API, its revisions and the current revision's policy through ARM REST.
      3. Shows the whitespace-insensitive diff against the current policy and writes it to -OutDir.
      4. Asks the operator to type the rendered policy's 12-character digest prefix, or reads an
         answers file (-AnswersPath) that pins the API, configuration, current revision, policy
         SHA-256 and the approver's object id. A non-interactive run without one refuses.
      5. Creates revision N+1 from the current revision, saves the policy to it and verifies it is
         not current. It never calls the releases endpoint.

    -MakeCurrent -Revision N -ReleaseNote '...': after confirmation (typed `<apiId>;rev=N`, or an
    answers file with action makeCurrent), creates an API release that makes revision N current,
    verifies it, and prints the rollback command (the previous revision).

    Each step writes one JSON audit line (ids, digests, reason codes) to the console and to
    <OutDir>/audit.jsonl. Every Azure call passes the configured subscription; the Azure CLI login
    is never changed. See docs/GATEWAY.md.

.EXAMPLE
    ./infra/gateway/Deploy-GatewayRevision.ps1 -ConfigPath infra/gateway/config/sample-pilot.json

.EXAMPLE
    ./infra/gateway/Deploy-GatewayRevision.ps1 -ConfigPath infra/gateway/config/sample-pilot.json -AnswersPath ./answers.json -NonInteractive

.EXAMPLE
    ./infra/gateway/Deploy-GatewayRevision.ps1 -ConfigPath infra/gateway/config/sample-pilot.json -MakeCurrent -Revision 3 -ReleaseNote 'Pilot gateway policy, smoke suite passed'
#>
[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    [Parameter(Mandatory)] [string]$ConfigPath,
    [string]$AnswersPath,
    [string]$OutDir,
    [switch]$NonInteractive,
    [Parameter(Mandatory, ParameterSetName = 'MakeCurrent')] [switch]$MakeCurrent,
    [Parameter(Mandatory, ParameterSetName = 'TakeOffline')] [switch]$TakeOffline,
    [Parameter(Mandatory, ParameterSetName = 'MakeCurrent')]
    [Parameter(Mandatory, ParameterSetName = 'TakeOffline')]
    [ValidatePattern('^[1-9][0-9]{0,5}$')] [string]$Revision,
    [Parameter(ParameterSetName = 'MakeCurrent')] [string]$ReleaseNote
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayDeploy.psm1') -Force

$target = Read-GatewayTarget -ConfigPath $ConfigPath
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' $target.ConfigurationId }

if ($MakeCurrent) {
    Invoke-GatewayMakeCurrent -ConfigPath $ConfigPath -Revision $Revision -ReleaseNote $ReleaseNote -AnswersPath $AnswersPath -OutDir $OutDir -NonInteractive:$NonInteractive
} elseif ($TakeOffline) {
    Invoke-GatewayTakeOffline -ConfigPath $ConfigPath -Revision $Revision -AnswersPath $AnswersPath -OutDir $OutDir -NonInteractive:$NonInteractive
} else {
    Invoke-GatewayRevisionDeployment -ConfigPath $ConfigPath -AnswersPath $AnswersPath -OutDir $OutDir -NonInteractive:$NonInteractive
}
