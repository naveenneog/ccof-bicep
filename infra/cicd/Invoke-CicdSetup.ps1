#Requires -Version 7.2
<#
.SYNOPSIS
  Self-hosted GitHub Actions runners for CCOF with managed identities (docs/runbooks/CICD-SETUP.md).

.DESCRIPTION
  Two runners, each on its own Linux VM in the workload VNet, each VM with exactly one user-assigned identity:
  ccof-preview (<prefix>-preview-id, read-only roles) and ccof-apply (<prefix>-deploy-id, deploy roles).
  Workflows sign in with `az login --identity` (.github/actions/azure-login-mi). Nothing is stored in GitHub:
  no secret, no federated credential, no Azure variable. Microsoft Graph is not used.

  Phases (-Phase, default all, in this order):
    Infra   resource group, optional subnet (runner.createSubnet), the two identities and, with
            runner.createVms true, the VMs (no public IP, no extension, no custom data).
    Attach  runner.createVms false: attaches each identity to the customer's existing VM. Refused when the VM
            has a system-assigned identity or any other user-assigned identity.
    Roles   infra/cicd/roles.bicep at subscription scope (what-if in preview).
    Host    prints the commands the VM admin runs (scripts/cicd/Install-CcofRunner.sh). -ViaRunCommand runs
            them through Azure Run Command instead (lab, or where the customer allows Run Command).
    GitHub  prints the environments; with -ConfigureGitHub creates them with gh (reviewers, branch policy).

  (default)  Preview: reads, what-if, prints the plan; nothing is changed.
  -Apply     Changes Azure (and GitHub with -ConfigureGitHub).
  Registration token (Host with -ViaRunCommand -Apply): -RegistrationToken, else $env:CCOF_RUNNER_TOKEN,
  else -FetchToken (gh, repository admin). It is passed as a Run Command protected parameter and never written.
  Exit codes: 0 done, 2 input refused, 3 refused or failed.

.EXAMPLE
  pwsh -File infra/cicd/Invoke-CicdSetup.ps1 -ConfigPath ~/cicd.stg.json
  pwsh -File infra/cicd/Invoke-CicdSetup.ps1 -ConfigPath ~/cicd.stg.json -Apply -Phase Infra, Attach, Roles
  pwsh -File infra/cicd/Invoke-CicdSetup.ps1 -ConfigPath ~/cicd.stg.json -Apply -Phase GitHub -ConfigureGitHub
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ConfigPath,
    [ValidateSet('Infra', 'Attach', 'Roles', 'Host', 'GitHub')] [string[]]$Phase = @('Infra', 'Attach', 'Roles', 'Host', 'GitHub'),
    [ValidateSet('preview', 'apply')] [string[]]$Role = @('preview', 'apply'),
    [switch]$Apply,
    [switch]$ViaRunCommand,
    [switch]$ConfigureGitHub,
    [string]$RegistrationToken,
    [switch]$FetchToken,
    [string]$StateDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'Cicd.psm1') -Force
function Stop-Cicd([string]$Message, [int]$Code) { [Console]::Error.WriteLine($Message); exit $Code }
function Say([string]$Text) { Write-Host $Text }

# One external call (az or gh); JSON out. -AllowMissing returns $null for a 404.
function Invoke-CicdTool([string]$Tool, [string[]]$Arguments, [switch]$AllowMissing, [switch]$Raw) {
    foreach ($a in $Arguments) { if ($a -match '[()|&<>^"]') { throw "internal: $Tool argument has a character that az.cmd/gh quoting breaks: $a" } }
    $ErrorActionPreference = 'Continue'
    $extra = @(if ($Tool -eq 'az' -and -not $Raw) { '--output', 'json', '--only-show-errors' })
    $out = try { & $Tool @Arguments @extra 2>&1 } catch { $_ }
    $code = $LASTEXITCODE
    $err = (@($out | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) -join ' ').Trim()
    $text = (@($out | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n").Trim()
    if ($code -ne 0) {
        if ($AllowMissing -and "$err $text" -match 'NotFound|could not be found|\(404\)|Not Found|HTTP 404') { return $null }
        $msg = "$err $text".Trim()
        throw "$Tool $($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ') failed: $($msg.Substring(0, [Math]::Min(500, $msg.Length)))"
    }
    if (-not $text -or $Raw) { return $text }
    return $text | ConvertFrom-Json -AsHashtable -Depth 100
}
function Format-Args([string[]]$A) { ($A | ForEach-Object { if ($_ -match ' ') { "'$_'" } else { $_ } }) -join ' ' }
function Invoke-Az([string[]]$A, [switch]$AllowMissing) { Invoke-CicdTool 'az' $A -AllowMissing:$AllowMissing }
function Save-Json([string]$Name, $Object) { $p = Join-Path $stateDir $Name; $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $p -Encoding utf8NoBOM; return $p }
function Save-Params([string]$Name, [hashtable]$Values) {
    $p = @{}; foreach ($k in $Values.Keys) { $p[$k] = @{ value = $Values[$k] } }
    Save-Json $Name @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $p }
}
function Show-WhatIf($Result) {
    $changes = @(if ($Result -and $Result.Contains('changes')) { $Result.changes } else { @() })
    foreach ($c in $changes) { if ($c.changeType -ne 'Ignore') { Say ("    {0,-9} {1}" -f $c.changeType, $c.resourceId) } }
    if (-not $changes.Count) { Say '    (no change reported)' }
}

# ---- configuration
if (-not (Test-Path -LiteralPath $ConfigPath)) { Stop-Cicd "input_refused: $ConfigPath not found" 2 }
try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20 } catch { Stop-Cicd "input_refused: $ConfigPath is not valid JSON: $_" 2 }
$problems = @(Get-CicdConfigProblems $cfg)
if ($problems.Count) { Stop-Cicd ("input_refused: fix the configuration:`n  - " + ($problems -join "`n  - ")) 2 }
if ($RegistrationToken -and -not (Test-CicdRegistrationToken $RegistrationToken)) { Stop-Cicd 'input_refused: -RegistrationToken does not look like a runner registration token' 2 }
if (-not $env:AZURE_CONFIG_DIR -and -not $env:ACC_CLOUD) { Stop-Cicd 'input_refused: set AZURE_CONFIG_DIR to an Azure CLI profile signed in to the target tenant, or run in Azure Cloud Shell.' 2 }
$sub = $cfg.subscriptionId; $loc = $cfg.location; $cicdRg = $cfg.cicdResourceGroup
$createVms = [bool]$cfg.runner.createVms
$runners = @(Get-CicdRunners $cfg | Where-Object { $Role -contains $_.role })
$allRunners = @(Get-CicdRunners $cfg)
$ghRepo = "$($cfg.github.owner)/$($cfg.github.repo)"
$mode = if ($Apply) { 'apply' } else { 'preview' }
$stateDir = if ($StateDirectory) { [IO.Path]::GetFullPath($StateDirectory) } else { Join-Path (Split-Path (Resolve-Path -LiteralPath $ConfigPath).Path -Parent) '.cicd-state' }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$evidence = [ordered]@{ schema = 'ccof.cicd.setup.v1'; mode = $mode; phases = $Phase; started = (Get-Date).ToUniversalTime().ToString('o'); identities = @(); attach = @(); host = @(); github = @() }
Say "CCOF CI/CD setup ($mode): subscription $sub, resource group $cicdRg, repository $ghRepo"
$tags = @{ 'ccof-component' = 'cicd-runner' }

function Get-Identities {
    foreach ($r in $allRunners) {
        $i = Invoke-Az @('identity', 'show', '--subscription', $sub, '--resource-group', $cicdRg, '--name', $r.identityName) -AllowMissing
        [pscustomobject]@{ role = $r.role; name = $r.identityName; id = if ($i) { $i.id } else { '' }; clientId = if ($i) { $i.clientId } else { '' }; principalId = if ($i) { $i.principalId } else { '' } }
    }
}

try {
    # ---- Infra
    if ($Phase -contains 'Infra') {
        Say "`n== Infra"
        $rg = Invoke-Az @('group', 'show', '--subscription', $sub, '--name', $cicdRg) -AllowMissing
        if (-not $rg) {
            Say "  resource group $cicdRg does not exist: it $(if ($Apply) { 'is' } else { 'would be' }) created"
            if ($Apply) { $null = Invoke-Az @('group', 'create', '--subscription', $sub, '--name', $cicdRg, '--location', $loc, '--tags', 'ccof-component=cicd-runner') }
        }
        if ($cfg.runner.createSubnet) {
            $sm = [regex]::Match($cfg.runner.subnetId, '/virtualNetworks/([^/]+)/subnets/([^/]+)$')
            $pf = Save-Params 'runner-subnet.parameters.json' @{ vnetName = $sm.Groups[1].Value; subnetName = $sm.Groups[2].Value; addressPrefix = $cfg.runner.createSubnet.addressPrefix
                defaultOutboundAccess = [bool]$cfg.runner.createSubnet.defaultOutboundAccess }
            $common = @('--subscription', $sub, '--resource-group', $cfg.networkResourceGroup, '--name', 'ccof-cicd-subnet', '--template-file', (Join-Path $PSScriptRoot 'runner-subnet.bicep'), '--parameters', "@$pf")
            Say "  subnet $($sm.Groups[2].Value) $($cfg.runner.createSubnet.addressPrefix) in $($sm.Groups[1].Value):"
            if ($Apply) { $null = Invoke-Az (@('deployment', 'group', 'create') + $common) ; Say '    deployed' } else { Show-WhatIf (Invoke-Az (@('deployment', 'group', 'what-if', '--no-pretty-print') + $common)) }
        }
        $key = ''
        if ($createVms) {
            $existing = Invoke-Az @('vm', 'show', '--subscription', $sub, '--resource-group', $cicdRg, '--name', $allRunners[0].vmName) -AllowMissing
            # An existing VM keeps its key: Azure refuses to change osProfile.
            $key = if ($existing) { @(Get-CicdValue $existing 'osProfile.linuxConfiguration.ssh.publicKeys')[0].keyData } else { New-CicdDiscardedSshPublicKey }
        }
        $pf = Save-Params 'cicd.parameters.json' @{ location = $loc; namePrefix = $cfg.namePrefix; createVms = $createVms; subnetId = $cfg.runner.subnetId; vmSize = $cfg.runner.vmSize
            images = $cfg.runner.images; adminPublicKey = $key; tags = $tags }
        $common = @('--subscription', $sub, '--resource-group', $cicdRg, '--name', 'ccof-cicd', '--template-file', (Join-Path $PSScriptRoot 'cicd.bicep'), '--parameters', "@$pf")
        Say "  identities$(if ($createVms) { ' and VMs' }) in ${cicdRg}:"
        if ($Apply) {
            $d = Invoke-Az (@('deployment', 'group', 'create') + $common)
            foreach ($i in @($d.properties.outputs.identities.value)) { Say "    $($i.role): $($i.name) clientId $($i.clientId)" }
        } elseif ($rg) { Show-WhatIf (Invoke-Az (@('deployment', 'group', 'what-if', '--no-pretty-print') + $common)) }
        else { foreach ($r in $allRunners) { Say "    Create    $($r.identityName)$(if ($createVms) { ", $($r.vmName)" })" } }
    }
    $ids = @(Get-Identities)
    $evidence.identities = $ids
    $idOf = @{}; foreach ($i in $ids) { $idOf[$i.role] = $i }

    # ---- Attach (existing customer VMs)
    if ($Phase -contains 'Attach' -and -not $createVms) {
        Say "`n== Attach"
        foreach ($r in $runners) {
            $vmIdText = "$($cfg.runner.existingVms[$r.role])"
            $vm = Invoke-Az @('vm', 'show', '--ids', $vmIdText) -AllowMissing
            if (-not $vm) { throw "VM $vmIdText not found or not readable" }
            if (-not $idOf[$r.role].id) { Say "  $($r.role): identity $($r.identityName) does not exist yet (run -Phase Infra -Apply)"; continue }
            $other = @($ids | Where-Object { $_.role -ne $r.role -and $_.id } | ForEach-Object id)
            $dec = Get-CicdAttachDecision -Vm $vm -IdentityId $idOf[$r.role].id -ForbiddenIdentityIds $other
            $evidence.attach += [pscustomobject]@{ role = $r.role; vm = $vmIdText; action = $dec.action; reason = $dec.reason }
            Say "  $($r.role): $($vm.name): $($dec.action) - $($dec.reason)"
            if ($dec.action -eq 'refuse') { throw "refused: $($vm.name): $($dec.reason)" }
            if ($dec.action -eq 'assign' -and $Apply) { $null = Invoke-Az @('vm', 'identity', 'assign', '--ids', $vmIdText, '--identities', $idOf[$r.role].id); Say '    attached' }
        }
    }

    # ---- Roles
    if ($Phase -contains 'Roles') {
        Say "`n== Roles"
        if (-not $idOf['preview'].principalId -or -not $idOf['apply'].principalId) { Say '  the identities do not exist yet; run -Phase Infra -Apply first' }
        else {
            # Empty: the conditioned administrator may grant the Stage 3 roles to any service principal (rbac-condition.bicep).
            $assignable = @(Get-CicdValue $cfg 'roles.assignablePrincipalIds' | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
            if (-not $assignable.Count) { Say '  note: roles.assignablePrincipalIds is empty: the deploy identity may assign the Stage 3 roles to ANY service principal (managed identity or application) in the tenant' }
            $foundryByOwner = "$(Get-CicdValue $cfg 'roles.foundryRolesBy')" -eq 'foundry-owner'
            $pf = Save-Params 'roles.parameters.json' @{ previewPrincipalId = $idOf['preview'].principalId; deployPrincipalId = $idOf['apply'].principalId
                workloadResourceGroup = $cfg.workloadResourceGroup; networkResourceGroup = $cfg.networkResourceGroup; cosmosAccountName = $cfg.cosmos.accountName
                cosmosDatabaseName = $cfg.cosmos.databaseName; foundry = @(if (-not $foundryByOwner) { $cfg.foundry }); foundryPrivateEndpointApproval = [bool](Get-CicdValue $cfg 'roles.foundryPrivateEndpointApproval')
                deployCosmosDataWriter = [bool](Get-CicdValue $cfg 'roles.deployCosmosDataWriter'); assignablePrincipalIds = $assignable }
            $common = @('--subscription', $sub, '--location', $loc, '--name', "ccof-cicd-roles-$($cfg.namePrefix)", '--template-file', (Join-Path $PSScriptRoot 'roles.bicep'), '--parameters', "@$pf")
            if ($Apply) { $null = Invoke-Az (@('deployment', 'sub', 'create') + $common); Say '  role assignments deployed (see the Roles table in docs/runbooks/CICD-SETUP.md)' }
            else { Show-WhatIf (Invoke-Az (@('deployment', 'sub', 'what-if', '--no-pretty-print') + $common)) }
            if ($foundryByOwner) {
                # The Foundry owner deploys the same module; nothing is assigned on the Foundry accounts from here.
                $i = 0
                foreach ($f in @($cfg.foundry)) {
                    $fp = Save-Params "foundry-roles-$i.parameters.json" @{ accountName = $f.accountName; previewPrincipalId = $idOf['preview'].principalId; deployPrincipalId = $idOf['apply'].principalId
                        privateEndpointApproval = [bool](Get-CicdValue $cfg 'roles.foundryPrivateEndpointApproval'); assignablePrincipalIds = $assignable }
                    Say "  Foundry $($f.accountName): roles.foundryRolesBy is foundry-owner. The Foundry owner (Owner or unconditioned User Access Administrator) runs:"
                    Say "    az deployment group create --subscription $($f.subscriptionId) --resource-group $($f.resourceGroup) --name ccof-cicd-roles-foundry --template-file infra/cicd/modules/foundry-roles.bicep --parameters @$fp"
                    $i++
                }
            }
        }
    }

    # ---- Host
    if ($Phase -contains 'Host') {
        Say "`n== Host"
        $script = Join-Path $repo 'scripts/cicd/Install-CcofRunner.sh'
        if (-not $ViaRunCommand) {
            Say '  The VM admin copies scripts/cicd/Install-CcofRunner.sh and Test-RunnerHost.sh to each VM and runs, as root:'
            foreach ($r in $runners) {
                $cid = $idOf[$r.role].clientId
                Say "  [$($r.role)] $(if ($createVms) { $r.vmName } else { $cfg.runner.existingVms[$r.role] })"
                Say "    sudo bash Install-CcofRunner.sh $(Format-Args (Get-CicdInstallArgs $cfg $r.role 'install'))"
                if ($cid) { Say "    read -rs RUNNER_TOKEN && sudo env RUNNER_TOKEN=`"`$RUNNER_TOKEN`" bash Install-CcofRunner.sh $(Format-Args (Get-CicdInstallArgs $cfg $r.role 'register' -ClientId $cid))" }
                else { Say '    register: the identity does not exist yet (run -Phase Infra -Apply)' }
            }
            Say "  Registration token: gh api -X POST repos/$ghRepo/actions/runners/registration-token --jq .token (valid one hour)."
        } else {
            $token = if ($RegistrationToken) { $RegistrationToken } elseif ($env:CCOF_RUNNER_TOKEN) { $env:CCOF_RUNNER_TOKEN } else { '' }
            if ($Apply -and -not $token -and $FetchToken) { $token = "$(Invoke-CicdTool 'gh' @('api', '-X', 'POST', "repos/$ghRepo/actions/runners/registration-token", '--jq', '.token') -Raw)".Trim() }
            if ($Apply -and -not (Test-CicdRegistrationToken $token)) { throw 'refused: Host -ViaRunCommand -Apply needs a registration token (-RegistrationToken, CCOF_RUNNER_TOKEN or -FetchToken)' }
            foreach ($r in $runners) {
                $vmIdText = if ($createVms) { "/subscriptions/$sub/resourceGroups/$cicdRg/providers/Microsoft.Compute/virtualMachines/$($r.vmName)" } else { "$($cfg.runner.existingVms[$r.role])" }
                $vm = [regex]::Match($vmIdText, '/resourceGroups/([^/]+)/providers/Microsoft\.Compute/virtualMachines/([^/]+)$')
                foreach ($cmd in 'install', 'register') {
                    $a = Get-CicdInstallArgs $cfg $r.role $cmd -ClientId $idOf[$r.role].clientId
                    $file = Join-Path $stateDir "runcommand-$($r.role)-$cmd.sh"
                    [IO.File]::WriteAllText($file, (New-CicdRunCommandScript -Arguments $a -ScriptPath $script))
                    Say "  [$($r.role)] $($vm.Groups[2].Value): Run Command $cmd"
                    if (-not $Apply) { continue }
                    $name = "ccof-runner-$cmd"
                    $rc = @('vm', 'run-command', 'create', '--subscription', $sub, '--resource-group', $vm.Groups[1].Value, '--vm-name', $vm.Groups[2].Value, '--run-command-name', $name,
                        '--script', "@$file", '--timeout-in-seconds', '3600', '--async-execution', 'false')
                    if ($cmd -eq 'register') { $rc += @('--protected-parameters', "RUNNER_TOKEN=$token") }
                    try {
                        $null = Invoke-Az $rc
                        $view = Invoke-Az @('vm', 'run-command', 'show', '--subscription', $sub, '--resource-group', $vm.Groups[1].Value, '--vm-name', $vm.Groups[2].Value, '--run-command-name', $name, '--instance-view')
                    } finally {
                        $null = Invoke-Az @('vm', 'run-command', 'delete', '--subscription', $sub, '--resource-group', $vm.Groups[1].Value, '--vm-name', $vm.Groups[2].Value, '--run-command-name', $name, '--yes') -AllowMissing
                    }
                    $line = Read-CicdRunLine "$(Get-CicdValue $view 'instanceView.output')"
                    $evidence.host += [pscustomobject]@{ role = $r.role; command = $cmd; run = $line; exitCode = Get-CicdValue $view 'instanceView.exitCode' }
                    Say "    $(if ($line) { "$($line.outcome) at $($line.step): $($line.detail)" } else { 'no run line; see instanceView.error' })"
                    if (-not $line -or $line.outcome -ne 'succeeded') { throw "Run Command $cmd on $($vm.Groups[2].Value) did not succeed: $(Get-CicdValue $view 'instanceView.error')" }
                }
            }
            $token = $null
            if ($Apply) {
                $list = Invoke-CicdTool 'gh' @('api', "repos/$ghRepo/actions/runners") -Raw | ConvertFrom-Json
                foreach ($x in @($list.runners)) { Say "  runner $($x.name): $($x.status) [$(@($x.labels | ForEach-Object name) -join ', ')]" }
            }
        }
    }

    # ---- GitHub
    if ($Phase -contains 'GitHub') {
        Say "`n== GitHub ($ghRepo)"
        $plan = Get-CicdGitHubPlan $cfg
        foreach ($e in $plan.environments) {
            Say ("  environment {0,-28} runner ccof-{1,-8} reviewers: {2}; branches: {3}" -f $e.name, $e.runner, $(if ($e.reviewers) { $e.reviewers -join ', ' } else { 'none' }), $(if ($e.branches) { $e.branches -join ', ' } else { 'any' }))
            $evidence.github += $e
            if (-not ($ConfigureGitHub -and $Apply)) { continue }
            $rev = @(foreach ($n in $e.reviewers) {
                    if ($n -match '^([^/]+)/(.+)$') { @{ type = 'Team'; id = [int64](Invoke-CicdTool 'gh' @('api', "orgs/$($Matches[1])/teams/$($Matches[2])", '--jq', '.id') -Raw) } }
                    else { @{ type = 'User'; id = [int64](Invoke-CicdTool 'gh' @('api', "users/$n", '--jq', '.id') -Raw) } }
                })
            $body = @{ reviewers = $rev; deployment_branch_policy = if ($e.branches) { @{ protected_branches = $false; custom_branch_policies = $true } } else { $null } }
            $bf = Save-Json "github-env-$($e.name).json" $body
            try { $null = Invoke-CicdTool 'gh' @('api', '-X', 'PUT', "repos/$ghRepo/environments/$($e.name)", '--input', $bf) -Raw }
            catch {
                if ("$_" -match 'billing plan') { throw "$_ -- in a private repository, required reviewers need GitHub Enterprise and deployment branch policies need GitHub Pro, Team or Enterprise; without them the apply gate is only the runner job-started hook (docs/runbooks/CICD-SETUP.md)" }
                throw
            }
            foreach ($b in $e.branches) {
                $have = Invoke-CicdTool 'gh' @('api', "repos/$ghRepo/environments/$($e.name)/deployment-branch-policies", '--jq', '.branch_policies[].name') -Raw
                if (@("$have" -split "`n") -notcontains $b) { $null = Invoke-CicdTool 'gh' @('api', '-X', 'POST', "repos/$ghRepo/environments/$($e.name)/deployment-branch-policies", '-f', "name=$b", '-f', 'type=branch') -Raw }
            }
            Say '    configured'
        }
        foreach ($x in $plan.runners) { Say "  runner $($x.name): labels $($x.labels)" }
        Say '  No secret and no variable is created: the runner VM identity signs in (az login --identity).'
        if (-not $ConfigureGitHub) { Say '  Add -ConfigureGitHub -Apply to create the environments with gh.' }
    }
} catch {
    $evidence.error = "$_"
    $null = Save-Json "setup-$mode-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).json" $evidence
    Stop-Cicd "failed: $_" 3
}
$null = Save-Json "setup-$mode-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).json" $evidence
if (-not $Apply) { Say "`nPreview only: nothing was changed. Run again with -Apply." }
exit 0
