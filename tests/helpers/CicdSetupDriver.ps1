# Dot-sourced by tests/Test-CicdSetup.ps1: runs infra/cicd/Invoke-CicdSetup.ps1 end to end in a child pwsh with
# a stub `az` and `gh` that log their arguments. Uses Check, New-Cfg, $repo, $sub and $tenant from the caller.
$dir = Join-Path $repo '.env.public-test-scratch/cicd-setup'
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$stub = Join-Path $dir 'stub.ps1'
@'
function global:az {
    $l = $args -join ' '; Add-Content -LiteralPath $env:FAKE_AZ_LOG -Value $l; $global:LASTEXITCODE = 0
    $rg = "/subscriptions/$env:FAKE_SUB/resourceGroups/rg-cicd/providers"
    if ($l -match '^group show .*--name rg-cicd') { if ($env:FAKE_NO_RG) { $global:LASTEXITCODE = 3; Write-Error '(ResourceGroupNotFound) Resource group could not be found'; return }; return '{"name":"rg-cicd"}' }
    if ($l -match '^identity show .*--name lab-cicd-(preview|deploy)-id') {
        if ($env:FAKE_NO_ID) { $global:LASTEXITCODE = 3; Write-Error '(ResourceNotFound) not found'; return }
        $n = $Matches[1]; $c = if ($n -eq 'preview') { '11111111-1111-4111-8111-111111111111' } else { '22222222-2222-4222-8222-222222222222' }
        return '{"id":"' + $rg + '/Microsoft.ManagedIdentity/userAssignedIdentities/lab-cicd-' + $n + '-id","clientId":"' + $c + '","principalId":"' + $c.Replace('1', '3').Replace('2', '4') + '"}'
    }
    if ($l -match '^vm show --ids \S+/virtualMachines/(\w+)-vm') { return (Get-Content -LiteralPath $env:FAKE_VM -Raw).Replace('@ROLE@', $Matches[1]) }
    if ($l -match '^deployment (group|sub) what-if ') { return '{"changes":[{"changeType":"Create","resourceId":"/x/stub-resource"}]}' }
    if ($l -match '^deployment group create ') { return '{"properties":{"outputs":{"identities":{"value":[{"role":"preview","name":"lab-cicd-preview-id","clientId":"c1"}]}}}}' }
    if ($l -match '^deployment sub create |^vm identity assign |^group create ') { return '{}' }
    if ($l -match '^vm run-command create .*--script @(\S+)') { Copy-Item -LiteralPath $Matches[1] -Destination (Join-Path (Split-Path $env:FAKE_AZ_LOG) 'last-script.sh') -Force; return '{}' }
    if ($l -match '^vm run-command show ') { $o = if ($env:FAKE_RC_FAIL) { 'failed' } else { 'succeeded' }; return '{"instanceView":{"exitCode":0,"output":"noise\n{\"schema\":\"ccof.cicd.runner.v1\",\"phase\":\"x\",\"outcome\":\"' + $o + '\",\"step\":\"done\",\"detail\":\"ok\"}"}}' }
    if ($l -match '^vm run-command delete ') { return '' }
    $global:LASTEXITCODE = 3; Write-Error "(BadRequest) stub: unexpected $l"
}
function global:gh {
    $l = $args -join ' '; Add-Content -LiteralPath $env:FAKE_GH_LOG -Value $l; $global:LASTEXITCODE = 0
    if ($l -match 'registration-token') { return ('T' * 29) }
    if ($l -match '^api users/alice --jq .id') { return '42' }
    if ($l -match '^api -X PUT repos/octo/ccof-lab/environments/(\S+) --input (\S+)') { Copy-Item -LiteralPath $Matches[2] -Destination (Join-Path (Split-Path $env:FAKE_GH_LOG) "env-$($Matches[1]).json") -Force; return '{}' }
    if ($l -match 'deployment-branch-policies --jq') { return '' }
    if ($l -match '^api -X POST .*deployment-branch-policies') { return '{}' }
    if ($l -match '^api repos/octo/ccof-lab/actions/runners$') { return '{"runners":[{"name":"lab-cicd-apply","status":"online","labels":[{"name":"self-hosted"},{"name":"ccof-apply"}]}]}' }
    $global:LASTEXITCODE = 1; Write-Error "stub gh: unexpected $l"
}
'@ | Set-Content -LiteralPath $stub -Encoding utf8NoBOM
function Run-Setup([string[]]$ScriptArgs, $Cfg, [string]$VmIdentity = '{"type":"None"}', [hashtable]$Env = @{}) {
    $env:FAKE_SUB = $sub; $env:FAKE_AZ_LOG = Join-Path $dir 'az.log'; $env:FAKE_GH_LOG = Join-Path $dir 'gh.log'
    Set-Content $env:FAKE_AZ_LOG ''; Set-Content $env:FAKE_GH_LOG ''
    Get-ChildItem $dir -Filter 'env-*.json' | Remove-Item; Remove-Item (Join-Path $dir 'last-script.sh') -ErrorAction SilentlyContinue
    $env:FAKE_VM = Join-Path $dir 'vm.json'; Set-Content $env:FAKE_VM ('{"name":"@ROLE@-vm","identity":' + $VmIdentity + '}')
    $cfgPath = Join-Path $dir 'cicd.config.json'; $Cfg | ConvertTo-Json -Depth 20 | Set-Content $cfgPath
    $state = Join-Path $dir 'state'; Remove-Item $state -Recurse -Force -ErrorAction SilentlyContinue
    $sets = ($Env.Keys | ForEach-Object { "`$env:$_ = '$($Env[$_])'; " }) -join ''
    $cmd = ". '$stub'; $sets`$env:AZURE_CONFIG_DIR = '$dir'; & '$(Join-Path $repo 'infra/cicd/Invoke-CicdSetup.ps1')' -ConfigPath '$cfgPath' -StateDirectory '$state' $($ScriptArgs -join ' '); exit `$LASTEXITCODE"
    $out = pwsh -NoProfile -Command $cmd 2>&1 | Out-String
    $stateText = (Get-ChildItem $state -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    @{ code = $LASTEXITCODE; out = $out; az = @(Get-Content $env:FAKE_AZ_LOG | Where-Object { $_ }); gh = @(Get-Content $env:FAKE_GH_LOG | Where-Object { $_ }); state = $stateText }
}
$writes = '^(group create|deployment (group|sub) create|vm identity assign|vm run-command create)|^api -X (PUT|POST)'
$vmCfg = New-Cfg @{ 'runner.createVms' = $false; 'runner.existingVms' = @{ preview = "/subscriptions/$sub/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/preview-vm"; apply = "/subscriptions/$sub/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/apply-vm" } }

$r = Run-Setup @() $vmCfg
Check 'driver preview: exit 0, what-if for infra and roles, no write to Azure or GitHub' ($r.code -eq 0 -and $r.out -match 'Preview only' -and
    @($r.az | Where-Object { $_ -match '^deployment group what-if .*cicd\.bicep' }).Count -eq 1 -and @($r.az | Where-Object { $_ -match '^deployment sub what-if .*roles\.bicep' }).Count -eq 1 -and
    @(@($r.az) + @($r.gh) | Where-Object { $_ -match $writes }).Count -eq 0)
Check 'driver preview: prints the admin bootstrap commands with the identity client ID and no token' ($r.out -match 'sudo bash Install-CcofRunner\.sh install --role preview' -and
    $r.out -match "register --role apply .*--client-id 22222222-2222-4222-8222-222222222222 .*--labels ccof-vnet,ccof-apply --allowed-refs refs/heads/main" -and $r.out -match 'read -rs RUNNER_TOKEN')
Check 'driver preview: states the reviewed-main requirement and prints register without the attestation' ($r.out -match 'REQUIRED before register' -and $r.out -match 'no bypass, administrators' -and
    $r.out -match 'Default branch protection only blocks force pushes and deletion' -and $r.out -match 'register --role apply ' -and $r.out -notmatch 'reviewed-main-enforced yes')
Check 'driver: az and gh arguments carry no character az.cmd quoting breaks, no Graph, no secret or variable' (@(@($r.az) + @($r.gh) | Where-Object { $_ -match '[()|&<>^]' -or $_ -match '^ad |graph\.microsoft|secrets|variables' }).Count -eq 0)
$r = Run-Setup @('-Phase', 'Host', '-ReviewedMainEnforced') $vmCfg
Check 'driver preview: -ReviewedMainEnforced adds --reviewed-main-enforced yes to register only' ($r.code -eq 0 -and @(($r.out -split "`n") | Where-Object { $_ -match 'reviewed-main-enforced yes' -and $_ -match ' register --role ' }).Count -eq 2 -and
    @(($r.out -split "`n") | Where-Object { $_ -match 'reviewed-main-enforced' -and $_ -match ' install --role ' }).Count -eq 0)
$r = Run-Setup @('-Apply', '-Phase', 'Host', '-ViaRunCommand', '-Role', 'apply') $vmCfg -Env @{ CCOF_RUNNER_TOKEN = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAB' }
Check 'run command: without -ReviewedMainEnforced Host -Apply is refused before any Run Command (exit 3)' ($r.code -eq 3 -and $r.out -match 'needs -ReviewedMainEnforced' -and @($r.az | Where-Object { $_ -match 'run-command' }).Count -eq 0)
$r = Run-Setup @('-Apply') (New-Cfg @{ 'github.applyBranches' = @('feat/*') })
Check 'driver: a configuration problem stops before any call (exit 2)' ($r.code -eq 2 -and $r.az.Count -eq 0 -and $r.out -match 'applyBranches')
$r = Run-Setup @('-Phase', 'Roles') (New-Cfg @{ 'roles' = @{ foundryRolesBy = 'foundry-owner' } })
Check 'roles: foundryRolesBy foundry-owner assigns nothing on Foundry and prints the module command for the Foundry owner' ($r.code -eq 0 -and
    $r.state -match '"foundry":\s*\{\s*"value":\s*\[\s*\]' -and $r.out -match 'az deployment group create --subscription \S+ --resource-group rg-foundry .*modules/foundry-roles\.bicep --parameters @\S+foundry-roles-0\.parameters\.json' -and
    $r.state -match '"accountName":\s*\{\s*"value":\s*"lab-foundry"')
$r = Run-Setup @('-Apply', '-Phase', 'Attach') $vmCfg '{"type":"SystemAssigned, UserAssigned","userAssignedIdentities":{}}'
Check 'attach: a VM with a system-assigned identity is refused (exit 3), nothing attached' ($r.code -eq 3 -and $r.out -match 'system-assigned' -and @($r.az | Where-Object { $_ -match '^vm identity assign' }).Count -eq 0)
$r = Run-Setup @('-Apply', '-Phase', 'Attach') $vmCfg
Check 'attach: each VM gets only its role identity' ($r.code -eq 0 -and @($r.az | Where-Object { $_ -match '^vm identity assign' }).Count -eq 2 -and
    @($r.az | Where-Object { $_ -match 'virtualMachines/preview-vm --identities \S+/lab-cicd-preview-id( |$)' }).Count -eq 1 -and @($r.az | Where-Object { $_ -match 'virtualMachines/apply-vm --identities \S+/lab-cicd-deploy-id( |$)' }).Count -eq 1)
$r = Run-Setup @('-Apply', '-Phase', 'Attach', '-Role', 'preview') $vmCfg ('{"type":"UserAssigned","userAssignedIdentities":{"/subscriptions/' + $sub + '/resourceGroups/rg-cicd/providers/Microsoft.ManagedIdentity/userAssignedIdentities/lab-cicd-deploy-id":{}}}')
Check 'attach: a VM that already carries the other runner identity is refused' ($r.code -eq 3 -and $r.out -match 'other runner identity')
$r = Run-Setup @('-Apply', '-Phase', 'Host', '-ViaRunCommand', '-ReviewedMainEnforced') $vmCfg
Check 'run command: no registration token -> refused before any Run Command (exit 3)' ($r.code -eq 3 -and @($r.az | Where-Object { $_ -match 'run-command create' }).Count -eq 0)
$tok = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAB'
$r = Run-Setup @('-Apply', '-Phase', 'Host', '-ViaRunCommand', '-Role', 'apply', '-ReviewedMainEnforced') $vmCfg -Env @{ CCOF_RUNNER_TOKEN = $tok }
$script = if (Test-Path (Join-Path $dir 'last-script.sh')) { Get-Content -Raw (Join-Path $dir 'last-script.sh') } else { '' }
Check 'run command: install then register on the apply VM, each run command deleted afterwards' ($r.code -eq 0 -and
    (@($r.az | Where-Object { $_ -match '^vm run-command (create|delete)' } | ForEach-Object { ($_ -split ' ')[2] + ':' + [regex]::Match($_, 'ccof-runner-\w+').Value }) -join ',') -ceq 'create:ccof-runner-install,delete:ccof-runner-install,create:ccof-runner-register,delete:ccof-runner-register')
Check 'run command: the token is only a protected parameter of register, never in a script, state file or output' (
    @($r.az | Where-Object { $_ -match [regex]::Escape($tok) }).Count -eq 1 -and @($r.az | Where-Object { $_ -match "register .*--protected-parameters RUNNER_TOKEN=$tok" }).Count -eq 1 -and
    $script -and -not $script.Contains($tok) -and -not $r.state.Contains($tok) -and -not $r.out.Contains($tok))
Check 'run command: the script carries the arguments in place of the marker' ($script -match "(?m)^set -- 'register' '--role' 'apply' .*'--client-id' '22222222-2222-4222-8222-222222222222'" -and $script -notmatch '(?m)^# @@ARGS@@$')
$r = Run-Setup @('-Apply', '-Phase', 'Host', '-ViaRunCommand', '-Role', 'preview', '-ReviewedMainEnforced') $vmCfg -Env @{ CCOF_RUNNER_TOKEN = $tok; FAKE_RC_FAIL = '1' }
Check 'run command: a failed run line stops the run (exit 3) and still deletes the run command' ($r.code -eq 3 -and @($r.az | Where-Object { $_ -match '^vm run-command delete' }).Count -eq 1 -and @($r.az | Where-Object { $_ -match 'ccof-runner-register' }).Count -eq 0)
$r = Run-Setup @('-Apply', '-Phase', 'GitHub', '-ConfigureGitHub') $vmCfg
$envApply = if (Test-Path (Join-Path $dir 'env-stg-apply.json')) { Get-Content -Raw (Join-Path $dir 'env-stg-apply.json') | ConvertFrom-Json -AsHashtable } else { @{} }
$envPreview = if (Test-Path (Join-Path $dir 'env-stg-preview.json')) { Get-Content -Raw (Join-Path $dir 'env-stg-preview.json') | ConvertFrom-Json -AsHashtable } else { @{} }
Check 'github: six environments, apply/gates with reviewer IDs and a main-only branch policy, preview open' ($r.code -eq 0 -and @($r.gh | Where-Object { $_ -match '^api -X PUT ' }).Count -eq 6 -and
    $envApply.Contains('reviewers') -and $envApply.reviewers[0].id -eq 42 -and $envApply.deployment_branch_policy.custom_branch_policies -and
    $envPreview.Contains('reviewers') -and @($envPreview.reviewers).Count -eq 0 -and $null -eq $envPreview.deployment_branch_policy -and
    @($r.gh | Where-Object { $_ -match 'deployment-branch-policies -f name=main -f type=branch' }).Count -eq 5 -and $r.az.Count -eq 2)
$r = Run-Setup @('-Phase', 'GitHub', '-ConfigureGitHub') $vmCfg
Check 'github: without -Apply nothing is created' ($r.code -eq 0 -and $r.gh.Count -eq 0)
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
