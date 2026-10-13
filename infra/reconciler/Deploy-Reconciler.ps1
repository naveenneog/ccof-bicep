#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys, packages, permits or rolls back the CCU budget reconciler (docs/PILOT.md C-7, ADR-0018).

.DESCRIPTION
    Every value comes from the answers file (-AnswersFile), validated before any Azure call by
    infra/reconciler/ReconcilerDeploy.psm1 and by the app's own validator (src/reconciler/settings.ts).
    The script never signs in, never switches subscription, and passes --subscription to every
    command. Each step writes one JSON audit line (ids and outcomes only) to -AuditPath.

    The actions follow the stages of docs/PILOT.md C-9:
      Validate        offline checks only
      WhatIf          Validate, then ARM what-if of the D1 resources; no change
      Resources       D1: WhatIf, then deploy reconciler-resources.bicep (no role assignment, no setting);
                      a Modify or Delete in the what-if needs -ConfirmChanges
      LeaseContainer  D2 schema: the reconciler's lease container (/id), if absent
      Permissions     D3: this package's reconciler-permissions.json, applied for this resource group
                      only, each grant created if absent and read back (WP-CORE's Stage-D3 script
                      applies the same file in a staged deployment)
      Settings        D2: the app settings, validated by the app's own code first
      Package         D2: build, stage the reconciler's files, deploy with OneDeploy
      Rollback        stop the timer, remove the identity's grants, then delete what this script created
                      and still carries the ccof-package tag (needs -ConfirmRollback)

.EXAMPLE
    pwsh -NoProfile -File infra/reconciler/Deploy-Reconciler.ps1 -AnswersFile infra/reconciler/reconciler.answers.pilot.json -Action WhatIf -AuditPath .env.rec-audit.jsonl
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AnswersFile,
    [Parameter(Mandatory)] [ValidateSet('Validate', 'WhatIf', 'Resources', 'LeaseContainer', 'Permissions', 'Settings', 'Package', 'Rollback')] [string] $Action,
    [Parameter(Mandatory)] [string] $AuditPath,
    [switch] $ConfirmRollback,
    [switch] $ConfirmChanges
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'ReconcilerDeploy.psm1') -Force

function Stop-Reconciler {
    param([string] $Message, [string] $Reason)
    Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = $Action; outcome = 'refused'; reason = $Reason })
    throw $Message
}

function Invoke-Az {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0..2] -join ' ') failed: $(($output | Select-Object -Last 3) -join ' ')" }
    return ($output | Where-Object { $_ -is [string] }) -join "`n"
}

# Offline validation: the answers, then the app's own validator over the settings the app will see.
$answers = Read-ReconcilerAnswers -Path $AnswersFile
$problems = Test-ReconcilerAnswers $answers
if ($problems.Count -gt 0) { Stop-Reconciler "The answers file is incomplete or invalid: $($problems -join ', ')" 'answers_invalid' }
Push-Location $repoRoot
try {
    npx tsc -p tsconfig.json | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Reconciler 'The TypeScript build failed; run npm ci and npx tsc -p tsconfig.json.' 'build_failed' }
    $settingsFile = Join-Path $repoRoot '.env.rec-validate.json'
    # A placeholder client id stands in for the identity's until D1 has created it.
    Get-ReconcilerAppSettings $answers -IdentityClientId '00000000-0000-4000-8000-000000000000' | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding utf8NoBOM
    $check = "import { readReconcilerSettings } from './dist/reconciler/settings.js'; import { readFileSync } from 'node:fs'; const r = readReconcilerSettings(JSON.parse(readFileSync(process.argv[1], 'utf8'))); console.log(r.ok ? 'ok' : r.problems.map((p) => p.setting + ':' + p.problem).join(', '));"
    $verdict = node --input-type=module -e $check $settingsFile
    Remove-Item -LiteralPath $settingsFile -ErrorAction SilentlyContinue
    if ($verdict -ne 'ok') { Stop-Reconciler "The reconciler settings are refused by the app's validator: $verdict" 'settings_invalid' }
}
finally { Pop-Location }
$sub = $answers.subscriptionId
$rg = $answers.resourceGroup
Write-ReconcilerAudit -Path $AuditPath -Record ([ordered]@{ action = 'validate'; outcome = 'succeeded'; subscriptionId = $sub; resourceGroup = $rg; decisionSource = $answers.decisionSource })
if ($Action -eq 'Validate') { return }

# The signed-in tenant must be the answers' tenant; the subscription is passed explicitly, never set.
$tenant = Invoke-Az @('account', 'show', '--subscription', $sub, '--query', 'tenantId', '-o', 'tsv')
if (-not [string]::Equals($tenant.Trim(), $answers.tenantId, 'OrdinalIgnoreCase')) {
    Stop-Reconciler "The Azure CLI login is in tenant $($tenant.Trim()), not the answers' tenant $($answers.tenantId). Sign in to that tenant with your own profile, then rerun." 'tenant_mismatch'
}

$scriptPath = Join-Path $PSScriptRoot 'Deploy-ReconcilerSteps.ps1'
. $scriptPath
switch ($Action) {
    { $_ -in 'WhatIf', 'Resources' } { Invoke-ReconcilerResources -Answers $answers -Apply:($Action -eq 'Resources') -ConfirmChanges:$ConfirmChanges }
    'LeaseContainer' { Invoke-ReconcilerLeaseContainer -Answers $answers }
    'Permissions' { Invoke-ReconcilerPermissions -Answers $answers }
    'Settings' { Invoke-ReconcilerSettings -Answers $answers }
    'Package' { Invoke-ReconcilerPackage -Answers $answers }
    'Rollback' {
        if (-not $ConfirmRollback) { Stop-Reconciler 'Rollback deletes the reconciler app, its identity and its access; rerun with -ConfirmRollback. Switch the resolver to token-limits-only first if it enforces budget state: without the reconciler every state goes stale.' 'rollback_not_confirmed' }
        Invoke-ReconcilerRollback -Answers $answers
    }
}
