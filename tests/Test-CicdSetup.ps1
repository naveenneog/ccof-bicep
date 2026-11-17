# Offline tests for the CI/CD runners and their managed identities (docs/runbooks/CICD-SETUP.md):
# infra/cicd/Cicd.psm1, scripts/cicd (Install-CcofRunner, its job-started hook, Test-RunnerHost), .github/actions/azure-login-mi,
# the Bicep templates, the roles table in the runbook, and infra/cicd/Invoke-CicdSetup.ps1 with a stub `az`
# and `gh` (tests/helpers/CicdSetupDriver.ps1). No Azure or GitHub call is made. The bash scripts are run
# with Git for Windows bash when it is installed, and skipped otherwise.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++; Write-Host "FAIL $Name" -ForegroundColor Red } }
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'infra/cicd/Cicd.psm1') -Force
$sub = '00000000-0000-4000-8000-000000000002'; $tenant = '00000000-0000-4000-8000-000000000001'; $fsub = '00000000-0000-4000-8000-000000000003'
function Restore-Env([hashtable]$Saved) { foreach ($k in $Saved.Keys) { if ($null -eq $Saved[$k]) { Remove-Item -LiteralPath "env:$k" -ErrorAction SilentlyContinue } else { Set-Item -LiteralPath "env:$k" -Value $Saved[$k] } } }
function New-Cfg([hashtable]$Patch = @{}) {
    $c = Get-Content -LiteralPath (Join-Path $repo 'infra/cicd/cicd.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
    $c.tenantId = $tenant; $c.subscriptionId = $sub
    $c.cicdResourceGroup = 'rg-cicd'; $c.workloadResourceGroup = 'rg-work'; $c.networkResourceGroup = 'rg-net'; $c.namePrefix = 'lab-cicd'
    $c.runner.subnetId = "/subscriptions/$sub/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet1/subnets/cicd-runner"
    $c.github.owner = 'octo'; $c.github.repo = 'ccof-lab'; $c.github.reviewers = @('alice')
    $c.runner.existingVms = @{ preview = "/subscriptions/$sub/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/preview-vm"; apply = "/subscriptions/$sub/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/apply-vm" }
    $c.cosmos.accountName = 'lab-cosmos'
    $c.foundry = @(@{ subscriptionId = $fsub; resourceGroup = 'rg-foundry'; accountName = 'lab-foundry' })
    foreach ($k in $Patch.Keys) {
        $parts = $k.Split('.'); $o = $c
        for ($i = 0; $i -lt $parts.Count - 1; $i++) { $o = $o[$parts[$i]] }
        $o[$parts[-1]] = $Patch[$k]
    }
    return $c
}
function Problems($Patch) { @(Get-CicdConfigProblems (New-Cfg $Patch)) }

# ---- configuration
Check 'a filled configuration has no problem' (@(Problems @{}).Count -eq 0)
$example = Get-Content -LiteralPath (Join-Path $repo 'infra/cicd/cicd.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
Check 'the example is refused until REPLACE values and zero GUIDs are replaced' ((@(Get-CicdConfigProblems $example) -match 'REPLACE|placeholder').Count -ge 1)
Check 'the runner RG must differ from the workload RG' ((@(Problems @{ cicdResourceGroup = 'RG-WORK' }) -match '^cicdResourceGroup').Count -eq 1)
Check 'subnet must be a full ID in the same subscription' ((@(Problems @{ 'runner.subnetId' = 'cicd-runner' }) -match '^runner.subnetId').Count -eq 1 -and
    (@(Problems @{ 'runner.subnetId' = "/subscriptions/$fsub/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet1/subnets/s" }) -match 'subscriptionId').Count -eq 1)
Check 'subnet must be in networkResourceGroup' ((@(Problems @{ networkResourceGroup = 'rg-other' }) -match 'networkResourceGroup').Count -eq 1)
Check 'runner tarball digest must be a SHA-256' ((@(Problems @{ 'runner.runnerSha256' = 'abc' }) -match 'runnerSha256').Count -eq 1)
Check 'createSubnet needs a /24-/29 prefix' ((@(Problems @{ 'runner.createSubnet' = @{ addressPrefix = '10.0.0.0/16' } }) -match 'createSubnet').Count -eq 1)
Check 'apply branches must be plain branch names' ((@(Problems @{ 'github.applyBranches' = @('main', 'feat/*') }) -match 'applyBranches').Count -eq 1 -and (@(Problems @{ 'github.applyBranches' = @() }) -match 'applyBranches').Count -eq 1)
Check 'apply workflows must be .github/workflows/*.yml paths' ((@(Problems @{ 'github.applyWorkflows' = @('.github/workflows/deploy.yml', '../x.yml') }) -match 'applyWorkflows').Count -eq 1)
Check 'a quote in an environment name is refused' ((@(Problems @{ 'github.environments' = @("stg'x") }) -match 'github.environments').Count -eq 1)
Check 'roles.foundryRolesBy accepts operator or foundry-owner only' ((@(Problems @{ roles = @{ foundryRolesBy = 'someone' } }) -match 'foundryRolesBy').Count -eq 1 -and @(Problems @{ roles = @{ foundryRolesBy = 'foundry-owner' } }).Count -eq 0)

# ---- runners, identities and the GitHub plan
$runners = @(Get-CicdRunners (New-Cfg))
Check 'two runners: preview then apply' ((@($runners | ForEach-Object role) -join ',') -ceq 'preview,apply')
Check 'runner names, VMs and identities follow the prefix' ($runners[0].vmName -ceq 'lab-cicd-preview-vm' -and $runners[0].identityName -ceq 'lab-cicd-preview-id' -and
    $runners[1].vmName -ceq 'lab-cicd-apply-vm' -and $runners[1].identityName -ceq 'lab-cicd-deploy-id' -and $runners[1].runnerName -ceq 'lab-cicd-apply')
Check 'labels: ccof-vnet plus the role label (self-hosted is added by GitHub)' ($runners[0].labels -ceq 'ccof-vnet,ccof-preview' -and $runners[1].labels -ceq 'ccof-vnet,ccof-apply')
$gh = Get-CicdGitHubPlan (New-Cfg)
$byName = @{}; foreach ($e in $gh.environments) { $byName[$e.name] = $e }
Check 'GitHub: preview environment has no reviewers and any branch' (@($byName['stg-preview'].reviewers).Count -eq 0 -and @($byName['stg-preview'].branches).Count -eq 0)
Check 'GitHub: apply and every gate need reviewers and main only' (@('stg-apply', 'stg-gate-network', 'stg-gate-entra', 'stg-gate-privatelink', 'stg-gate-marketplace' | Where-Object { "$($byName[$_].reviewers)" -ceq 'alice' -and "$($byName[$_].branches)" -ceq 'main' }).Count -eq 5)
Check 'GitHub: no Azure credential or client ID is stored as a variable or secret' (-not ($gh.PSObject.Properties.Name -match 'ariable|ecret'))

# ---- Install-CcofRunner.sh arguments and the Run Command script
$cfgAll = New-Cfg @{ 'runner.proxy' = 'http://proxy.corp:8080'; 'runner.caCert' = '/etc/pki/corp.pem'; 'github.applyWorkflows' = @('.github/workflows/deploy.yml') }
$ia = @(Get-CicdInstallArgs $cfgAll 'apply' 'register' -ClientId $tenant)
$line = ConvertTo-CicdArgsLine $ia
Check 'args: register carries identity, repository, labels, refs, workflows, proxy and CA, never a token' ($line -match "^set -- 'register' '--role' 'apply' " -and $line -match "'--client-id' '$tenant'" -and
    $line -match "'--repository' 'octo/ccof-lab'" -and $line -match "'--labels' 'ccof-vnet,ccof-apply'" -and $line -match "'--allowed-refs' 'refs/heads/main'" -and
    $line -match "'--allowed-workflows' '.github/workflows/deploy.yml'" -and $line -match "'--proxy' 'http://proxy.corp:8080'" -and $line -match "'--ca-cert' '/etc/pki/corp.pem'" -and $line -notmatch 'TOKEN')
Check 'args: install needs no identity; register refuses without a client ID' ((@(Get-CicdInstallArgs (New-Cfg) 'preview' 'install') -join ' ') -notmatch 'client-id' -and
    $(try { $null = Get-CicdInstallArgs (New-Cfg) 'preview' 'register'; $false } catch { "$_" -match 'input_refused' }))
foreach ($bad in "a'b", 'x;id', '$(id)', 'a`b', "a`nb", 'a"b') {
    Check "args: refused character in $([regex]::Escape($bad))" $(try { $null = ConvertTo-CicdArgsLine @('install', $bad); $false } catch { "$_" -match 'input_refused' })
}
$rc = New-CicdRunCommandScript -Arguments $ia
Check 'run command script: the marker is replaced once by the args line, LF only' ($rc.Contains("`n$line`n") -and $rc -notmatch '(?m)^# @@ARGS@@$' -and -not $rc.Contains("`r"))
$sh = [IO.File]::ReadAllText((Join-Path $repo 'scripts/cicd/Install-CcofRunner.sh'))
Check 'Install-CcofRunner.sh: the token comes only from RUNNER_TOKEN in the environment and is never printed' ($sh -match '--token "\$RUNNER_TOKEN"' -and
    @(($sh -split "`n") | Where-Object { $_ -match 'RUNNER_TOKEN' -and $_ -match '\b(echo|printf|note|emit|tee)\b' }).Count -eq 0 -and $sh -notmatch '--token-file|RUNNER_TOKEN=')
Check 'Install-CcofRunner.sh: downloads verified with sha256sum before extraction' ($sh -match 'sha256sum' -and $sh.IndexOf('sha256sum') -lt $sh.IndexOf('tar x'))
Check 'Install-CcofRunner.sh: no sudo, no NOPASSWD, not run as root, no cloud-init or extension' ($sh -notmatch 'sudo -u|sudoers' -and $sh -notmatch 'NOPASSWD' -and $sh -notmatch 'RUNNER_ALLOW_RUNASROOT' -and $sh -match 'runuser' -and $sh -notmatch '(?m)^[^#]*(cloud-init|waagent)')
Check 'Install-CcofRunner.sh: runner .env sets identity, role, hook, TMPDIR in _work and NO_PROXY with IMDS' ($sh -match 'CCOF_RUNNER_IDENTITY_CLIENT_ID=' -and $sh -match 'CCOF_RUNNER_ROLE=' -and
    $sh -match 'ACTIONS_RUNNER_HOOK_JOB_STARTED=' -and $sh -match 'TMPDIR=.*_work' -and $sh -match 'IMDS=169\.254\.169\.254' -and $sh -match 'DEFAULT_NO_PROXY="[^"]*\$IMDS')
Check 'Install-CcofRunner.sh: SELinux contexts restored for the runner and tools' ($sh -match 'restorecon' -and $sh -match 'semanage fcontext')
foreach ($f in 'scripts/cicd/Install-CcofRunner.sh', 'scripts/cicd/Test-RunnerHost.sh', '.github/actions/azure-login-mi/azure-login-mi.sh') {
    Check "$f has LF line endings" (-not [IO.File]::ReadAllText((Join-Path $repo $f)).Contains("`r"))
}
$vmIdA = '/subscriptions/s/resourceGroups/r/providers/Microsoft.ManagedIdentity/userAssignedIdentities/a'
Check 'attach: no identity -> assign; only its own -> none' ((Get-CicdAttachDecision @{ identity = $null } $vmIdA).action -eq 'assign' -and
    (Get-CicdAttachDecision @{ identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $vmIdA = @{} } } } $vmIdA).action -eq 'none')
Check 'attach: system-assigned or another identity -> refuse' ((Get-CicdAttachDecision @{ identity = @{ type = 'SystemAssigned' } } $vmIdA).action -eq 'refuse' -and
    (Get-CicdAttachDecision @{ identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ "$vmIdA-other" = @{} } } } $vmIdA).action -eq 'refuse')
Check 'config: existing VMs must be two different VM IDs when createVms is false' ((@(Problems @{ 'runner.createVms' = $false; 'runner.existingVms' = @{ preview = 'x'; apply = 'y' } }) -match 'existingVms').Count -eq 2 -and
    (@(Problems @{ 'runner.createVms' = $false; 'runner.existingVms' = @{ preview = "/subscriptions/$sub/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/v"; apply = "/subscriptions/$sub/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/v" } }) -match 'different VMs').Count -eq 1)
Check 'config: createVms needs an image per role; proxy without credentials-free URL and relative CA path refused' ((@(Problems @{ 'runner.createVms' = $true; 'runner.images' = @{ preview = @{ id = 'x' } } }) -match 'runner.images').Count -eq 2 -and
    (@(Problems @{ 'runner.proxy' = 'ftp://x' }) -match 'runner.proxy').Count -eq 1 -and (@(Problems @{ 'runner.caCert' = 'corp.pem' }) -match 'caCert').Count -eq 1)
$msg = "[stdout]`nnoise`n{`"schema`":`"ccof.cicd.runner.v1`",`"phase`":`"status`",`"outcome`":`"succeeded`",`"step`":`"status`",`"detail`":`"active`"}`n"
Check 'run line parsed; none when absent' ((Read-CicdRunLine $msg).detail -ceq 'active' -and $null -eq (Read-CicdRunLine 'nothing'))
Check 'registration token shape' ((Test-CicdRegistrationToken ('A' * 29)) -and -not (Test-CicdRegistrationToken "AAAA'; rm -rf /") -and -not (Test-CicdRegistrationToken ''))
$key = New-CicdDiscardedSshPublicKey
$blob = [Convert]::FromBase64String($key.Split(' ')[1])
Check 'discarded SSH key: OpenSSH ssh-rsa public key format' ($key.StartsWith('ssh-rsa ') -and [Text.Encoding]::ASCII.GetString($blob, 4, 7) -ceq 'ssh-rsa' -and $blob.Length -gt 380)

# ---- bash: job-started hook and azure-login-mi (Git for Windows bash; WSL bash is not used)
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", '/bin/bash') | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ($bash) {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("cicd-bash-" + [guid]::NewGuid().ToString('n')); New-Item -ItemType Directory $scratch | Out-Null
    $toBash = { param($p) ($p -replace '\\', '/') -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLowerInvariant() } }
    $policy = Join-Path $scratch 'policy'
    $hookFile = Join-Path $scratch 'job-started.sh'
    [IO.File]::WriteAllText($hookFile, ((& $bash (& $toBash (Join-Path $repo 'scripts/cicd/Install-CcofRunner.sh')) print-hook) -join "`n") + "`n")
    function Invoke-Hook([string]$PolicyText, [hashtable]$Env) {
        [IO.File]::WriteAllText($policy, $PolicyText.Replace("`r", ''))
        $saved = @{}; foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
        try { $out = & $bash (& $toBash $hookFile) (& $toBash $policy) 2>&1; return @{ code = $LASTEXITCODE; out = "$out" } }
        finally { Restore-Env $saved }
    }
    function Merge([hashtable]$A, [hashtable]$B) { $h = @{} + $A; foreach ($k in $B.Keys) { $h[$k] = $B[$k] }; $h }
    $applyPolicy = "RUNNER_ROLE=apply`nREPOSITORY=octo/ccof-lab`nALLOWED_REFS=refs/heads/main`nALLOWED_WORKFLOWS=`n"
    $ok = @{ GITHUB_REPOSITORY = 'octo/ccof-lab'; GITHUB_EVENT_NAME = 'workflow_dispatch'; GITHUB_REF = 'refs/heads/main'; GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/deploy.yml@refs/heads/main' }
    Check 'hook: apply runner accepts workflow_dispatch on main' ((Invoke-Hook $applyPolicy $ok).code -eq 0)
    $r = Invoke-Hook $applyPolicy (Merge $ok @{ GITHUB_EVENT_NAME = 'pull_request' })
    Check 'hook: apply runner refuses pull_request' ($r.code -ne 0 -and $r.out -match 'pull_request')
    Check 'hook: apply runner refuses pull_request_target and workflow_run' ((Invoke-Hook $applyPolicy (Merge $ok @{ GITHUB_EVENT_NAME = 'pull_request_target' })).code -ne 0 -and (Invoke-Hook $applyPolicy (Merge $ok @{ GITHUB_EVENT_NAME = 'workflow_run' })).code -ne 0)
    Check 'hook: apply runner refuses another branch' ((Invoke-Hook $applyPolicy (Merge $ok @{ GITHUB_REF = 'refs/heads/feature' })).code -ne 0)
    Check 'hook: any runner refuses another repository' ((Invoke-Hook "RUNNER_ROLE=preview`nREPOSITORY=octo/ccof-lab`n" (Merge $ok @{ GITHUB_REPOSITORY = 'evil/fork' })).code -ne 0)
    Check 'hook: preview runner accepts pull_request on any branch' ((Invoke-Hook "RUNNER_ROLE=preview`nREPOSITORY=octo/ccof-lab`n" (Merge $ok @{ GITHUB_EVENT_NAME = 'pull_request'; GITHUB_REF = 'refs/pull/1/merge' })).code -eq 0)
    $wfPolicy = $applyPolicy.Replace('ALLOWED_WORKFLOWS=', 'ALLOWED_WORKFLOWS=.github/workflows/deploy.yml')
    Check 'hook: workflow allow-list accepts a listed workflow and refuses another' ((Invoke-Hook $wfPolicy $ok).code -eq 0 -and
        (Invoke-Hook $wfPolicy (Merge $ok @{ GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/other.yml@refs/heads/main' })).code -ne 0)
    Check 'hook: a missing policy file refuses the job' ((& { [IO.File]::Delete($policy); & $bash (& $toBash $hookFile) (& $toBash $policy) 2>&1 | Out-Null; $LASTEXITCODE }) -ne 0)

    # azure-login-mi with a stub az on PATH that logs its arguments
    $bin = Join-Path $scratch 'bin'; New-Item -ItemType Directory $bin | Out-Null
    [IO.File]::WriteAllText((Join-Path $bin 'az'), "#!/bin/bash`necho `"`$*`" >>`"`$FAKE_AZ_LOG`"`ncase `"`$1 `$2`" in 'account show') echo $tenant;; esac`nexit 0`n")
    function Invoke-Login([hashtable]$Env) {
        $runnerTemp = Join-Path $scratch ('t' + [guid]::NewGuid().ToString('n').Substring(0, 6)); New-Item -ItemType Directory $runnerTemp | Out-Null
        $all = @{ RUNNER_TEMP = (& $toBash $runnerTemp); GITHUB_ENV = (& $toBash "$runnerTemp/env"); GITHUB_OUTPUT = (& $toBash "$runnerTemp/out"); FAKE_AZ_LOG = (& $toBash "$runnerTemp/az.log")
            CCOF_RUNNER_ROLE = 'preview'; CCOF_RUNNER_IDENTITY_CLIENT_ID = $tenant; CCOF_RUNNER_SUBSCRIPTION_ID = $sub; IN_MODE = 'login'; IN_ROLE = ''; IN_CLIENT_ID = ''; IN_SUBSCRIPTION_ID = '' } 
        foreach ($k in $Env.Keys) { $all[$k] = $Env[$k] }
        $saved = @{}; foreach ($k in $all.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
        $oldPath = $env:PATH
        try {
            $out = & $bash -c "export PATH=`"$(& $toBash $bin)`":`$PATH; bash '$(& $toBash (Join-Path $repo '.github/actions/azure-login-mi/azure-login-mi.sh'))'" 2>&1
            $code = $LASTEXITCODE
            $log = if (Test-Path "$runnerTemp/az.log") { Get-Content -Raw "$runnerTemp/az.log" } else { '' }
            $envFile = if (Test-Path "$runnerTemp/env") { Get-Content -Raw "$runnerTemp/env" } else { '' }
            return @{ code = $code; out = "$out"; log = $log; env = $envFile; temp = $runnerTemp }
        } finally { $env:PATH = $oldPath; Restore-Env $saved }
    }
    $r = Invoke-Login @{}
    Check 'login: az login --identity with the runner client ID, per-job config dir under RUNNER_TEMP' ($r.code -eq 0 -and $r.log -match "login --identity --client-id $tenant" -and $r.log -match "account set --subscription $sub" -and $r.env -match 'AZURE_CONFIG_DIR=.*/azcfg\.')
    Check 'login: no secret or federated token is used' ($r.log -notmatch 'service-principal|--password|--federated-token')
    $r = Invoke-Login @{ IN_ROLE = 'apply' }
    Check 'login: a job expecting apply on a preview runner fails before az is called' ($r.code -ne 0 -and $r.out -match 'ccof-apply' -and -not $r.log)
    $r = Invoke-Login @{ CCOF_RUNNER_ROLE = '' }
    Check 'login: a runner without CCOF_RUNNER_ROLE is refused' ($r.code -ne 0 -and -not $r.log)
    $r = Invoke-Login @{ IN_CLIENT_ID = 'x;id' }
    Check 'login: a non-GUID client ID is refused' ($r.code -ne 0 -and -not $r.log)
    $r = Invoke-Login @{ IN_MODE = 'logout'; AZURE_CONFIG_DIR = '/etc' }
    Check 'logout: refuses to remove a directory it did not create' ($r.code -ne 0 -and -not $r.log)
    Remove-Item -Recurse -Force $scratch
} else { Write-Host 'SKIP bash checks: Git for Windows bash not found' }

# ---- Windows: job-started hook from Install-CcofRunner.ps1 print-hook, and Test-RunnerHost.ps1 output format
$wscratch = Join-Path ([IO.Path]::GetTempPath()) ("cicd-win-" + [guid]::NewGuid().ToString('n')); New-Item -ItemType Directory $wscratch | Out-Null
$whook = Join-Path $wscratch 'job-started.ps1'
(& pwsh -NoProfile -File (Join-Path $repo 'scripts/cicd/Install-CcofRunner.ps1') print-hook) | Set-Content -LiteralPath $whook
$wpolicy = Join-Path $wscratch 'policy'
function Invoke-WinHook([string]$PolicyText, [hashtable]$Env) {
    Set-Content -LiteralPath $wpolicy $PolicyText
    $saved = @{}; foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try { $null = & pwsh -NoProfile -File $whook $wpolicy 2>&1; $LASTEXITCODE } finally { Restore-Env $saved }
}
$wok = @{ GITHUB_REPOSITORY = 'octo/ccof-lab'; GITHUB_EVENT_NAME = 'push'; GITHUB_REF = 'refs/heads/main'; GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/deploy.yml@refs/heads/main' }
$wpol = "RUNNER_ROLE=apply`nREPOSITORY=octo/ccof-lab`nALLOWED_REFS=refs/heads/main`nALLOWED_WORKFLOWS=.github/workflows/deploy.yml"
Check 'windows hook: apply accepts push on main from an allowed workflow' ((Invoke-WinHook $wpol $wok) -eq 0)
Check 'windows hook: apply refuses pull_request, another branch and another workflow' ((Invoke-WinHook $wpol (& { $h = @{} + $wok; $h.GITHUB_EVENT_NAME = 'pull_request'; $h })) -ne 0 -and
    (Invoke-WinHook $wpol (& { $h = @{} + $wok; $h.GITHUB_REF = 'refs/heads/dev'; $h })) -ne 0 -and (Invoke-WinHook $wpol (& { $h = @{} + $wok; $h.GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/x.yml@refs/heads/main'; $h })) -ne 0)
$pf = @(& pwsh -NoProfile -File (Join-Path $repo 'scripts/cicd/Test-RunnerHost.ps1') -NoLogin -ImdsUri 'http://127.0.0.1:9/' -TimeoutSec 2 -MinDiskGb 0 2>&1)
Check 'windows preflight: IMDS first, evidence lines only, exit 1 when IMDS is unreachable' ($LASTEXITCODE -eq 1 -and "$($pf[0])" -match '^FAIL imds' -and
    @($pf | Where-Object { "$_" -and "$_" -notmatch '^(PASS|FAIL|WARN|INFO) [^:]+: |^Test-RunnerHost: ' }).Count -eq 0)
Remove-Item -Recurse -Force $wscratch
# ---- templates and roles table
$built = @{}
foreach ($t in 'cicd.bicep', 'roles.bicep', 'runner-subnet.bicep') {
    $json = (& az bicep build --file (Join-Path $repo "infra/cicd/$t") --stdout --only-show-errors 2>$null) -join "`n"
    $built[$t] = $json
    Check "$t builds" ($json -match '"\$schema"')
}
Check 'cicd.bicep: no public IP, no federated credential, no system-assigned identity' ($built['cicd.bicep'] -notmatch 'Microsoft.Network/publicIPAddresses' -and
    $built['cicd.bicep'] -notmatch 'federatedIdentityCredentials' -and $built['cicd.bicep'] -notmatch 'SystemAssigned')
Check 'cicd.bicep: each VM has exactly one user-assigned identity' ($built['cicd.bicep'] -match '"type"\s*:\s*"UserAssigned"' -and $built['cicd.bicep'] -match 'userAssignedIdentities')
Check 'cicd.bicep: password authentication disabled' ($built['cicd.bicep'] -match '"disablePasswordAuthentication"\s*:\s*true')
Check 'runner-subnet.bicep: NSG denies all inbound' ($built['runner-subnet.bicep'] -match '"access"\s*:\s*"Deny"' -and $built['runner-subnet.bicep'] -match '"direction"\s*:\s*"Inbound"')
$rolesText = (Get-ChildItem (Join-Path $repo 'infra/cicd') -Recurse -Filter '*roles*.bicep' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$doc = Get-Content -LiteralPath (Join-Path $repo 'docs/runbooks/CICD-SETUP.md') -Raw
$ids = @([regex]::Matches($rolesText, "'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Check 'roles: every role definition ID is in the runbook roles table' ($ids.Count -ge 6 -and @($ids | Where-Object { $doc -notmatch $_ }).Count -eq 0)
Check 'roles: no Owner and no User Access Administrator' ($rolesText -notmatch '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' -and $rolesText -notmatch '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9')
Check 'roles: role assignment administration is conditioned on the role IDs Stage 3 assigns' ($rolesText -match "conditionVersion: '2.0'" -and @('b7e6dc6d-f1e8-4753-8033-0f276bb0955b', '3913510d-42f4-4e42-8a64-420c390055eb', '73c42c96-874c-492b-b04d-ab87d138a893', 'a97b65f3-24c7-4388-baec-2e87135dc908' | Where-Object { $rolesText -notmatch $_ }).Count -eq 0)
Check 'roles: the preview identity gets only read roles' ($rolesText -match '(?s)var previewRoleIds = \[\s*reader\s*\]')
$stage3 = Get-Content -LiteralPath (Join-Path $repo 'infra/staged/stage3-grants.bicep') -Raw
$foundryRole = Get-Content -LiteralPath (Join-Path $repo 'infra/quickstart/modules/foundry-role.bicep') -Raw
$assigned = @([regex]::Matches($stage3 + $foundryRole, "var \w+ = '([0-9a-f-]{36})'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Check 'every Azure role Stage 3 assigns is allowed by the deploy identity condition' ($assigned.Count -eq 4 -and @($assigned | Where-Object { $rolesText -notmatch $_ }).Count -eq 0)
$all = (@('infra/cicd/Invoke-CicdSetup.ps1', 'infra/cicd/Cicd.psm1', 'scripts/cicd/Install-CcofRunner.sh', 'scripts/cicd/Install-CcofRunner.ps1', 'infra/cicd/cicd.bicep', 'infra/cicd/roles.bicep', '.github/actions/azure-login-mi/azure-login-mi.sh') | ForEach-Object { Get-Content -LiteralPath (Join-Path $repo $_) -Raw }) -join "`n"
Check 'no Microsoft Graph, no az ad, no app registration, no federated credential' ($all -notmatch 'graph\.microsoft|\baz ad\b|''ad'',|applications|federated-credential|federatedIdentityCredentials')

. (Join-Path $PSScriptRoot 'helpers/CicdSetupDriver.ps1')

Write-Host "Test-CicdSetup: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
