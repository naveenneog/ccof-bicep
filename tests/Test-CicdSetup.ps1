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
    $c.github.previewWorkflows = @('.github/workflows/check.yml'); $c.github.applyWorkflows = @('.github/workflows/deploy.yml')
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
Check 'runner workflows: both lists required, .github/workflows/*.yml paths only' ((@(Problems @{ 'github.applyWorkflows' = @('.github/workflows/deploy.yml', '../x.yml') }) -match 'applyWorkflows').Count -eq 1 -and
    (@(Problems @{ 'github.previewWorkflows' = @() }) -match 'previewWorkflows').Count -eq 1 -and (@(Problems @{ 'github.applyWorkflows' = @('') }) -match 'applyWorkflows').Count -eq 1)
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
Check 'args: each runner gets its own workflow allow-list; an empty list is refused' ((@(Get-CicdInstallArgs (New-Cfg @{ 'github.previewWorkflows' = @('.github/workflows/check.yml') }) 'preview' 'register' -ClientId $tenant) -join ' ') -match '--allowed-workflows \.github/workflows/check\.yml$' -and
    $(try { $null = Get-CicdInstallArgs (New-Cfg @{ 'github.applyWorkflows' = @() }) 'apply' 'register' -ClientId $tenant; $false } catch { "$_" -match 'applyWorkflows is empty' }))
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
    $sha1 = 'a' * 40
    $ok = @{ GITHUB_REPOSITORY = 'octo/ccof-lab'; GITHUB_EVENT_NAME = 'workflow_dispatch'; GITHUB_REF = 'refs/heads/main'; GITHUB_REF_TYPE = 'branch'; GITHUB_HEAD_REF = ''
        GITHUB_SHA = $sha1; GITHUB_WORKFLOW_SHA = $sha1; GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/deploy.yml@refs/heads/main' }
    # Untrusted triggers seen live (same-repository pull request, feature-branch push and dispatch) must be refused on BOTH runners.
    $denied = [ordered]@{
        'same-repo pull_request' = @{ GITHUB_EVENT_NAME = 'pull_request'; GITHUB_REF = 'refs/pull/1/merge'; GITHUB_REF_TYPE = 'branch'; GITHUB_HEAD_REF = 'feature' }
        'pull_request on a main-looking ref' = @{ GITHUB_EVENT_NAME = 'pull_request' }
        'pull_request_target' = @{ GITHUB_EVENT_NAME = 'pull_request_target' }
        'workflow_run' = @{ GITHUB_EVENT_NAME = 'workflow_run' }
        'missing event' = @{ GITHUB_EVENT_NAME = '' }
        'feature-branch push' = @{ GITHUB_EVENT_NAME = 'push'; GITHUB_REF = 'refs/heads/feature'; GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/deploy.yml@refs/heads/feature' }
        'feature-branch dispatch' = @{ GITHUB_REF = 'refs/heads/feature'; GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/deploy.yml@refs/heads/feature' }
        'tag push' = @{ GITHUB_EVENT_NAME = 'push'; GITHUB_REF = 'refs/tags/main'; GITHUB_REF_TYPE = 'tag' }
        'workflow file from another ref' = @{ GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/deploy.yml@refs/heads/feature' }
        'workflow not in the allow-list' = @{ GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/other.yml@refs/heads/main' }
        'workflow commit differs from the job commit' = @{ GITHUB_WORKFLOW_SHA = 'b' * 40 }
        'missing commit' = @{ GITHUB_SHA = ''; GITHUB_WORKFLOW_SHA = '' }
        'another repository' = @{ GITHUB_REPOSITORY = 'evil/fork' }
        'pull request head ref set' = @{ GITHUB_HEAD_REF = 'feature' }
    }
    foreach ($role in 'preview', 'apply') {
        $pol = "RUNNER_ROLE=$role`nREPOSITORY=octo/ccof-lab`nALLOWED_REFS=refs/heads/main`nALLOWED_WORKFLOWS=.github/workflows/deploy.yml .github/workflows/check.yml`n"
        $r = Invoke-Hook $pol $ok
        Check "hook ($role): trusted workflow_dispatch on main from an allowed workflow is accepted and logs its context" ($r.code -eq 0 -and $r.out -match "context role=$role .*event=workflow_dispatch ref=refs/heads/main")
        Check "hook ($role): push and schedule on main are accepted" ((Invoke-Hook $pol (Merge $ok @{ GITHUB_EVENT_NAME = 'push' })).code -eq 0 -and (Invoke-Hook $pol (Merge $ok @{ GITHUB_EVENT_NAME = 'schedule' })).code -eq 0)
        foreach ($k in $denied.Keys) {
            $r = Invoke-Hook $pol (Merge $ok $denied[$k])
            Check "hook ($role): $k is refused" ($r.code -ne 0 -and $r.out -match 'job refused')
        }
        Check "hook ($role): an empty workflow allow-list refuses every job" ((Invoke-Hook $pol.Replace('ALLOWED_WORKFLOWS=.github/workflows/deploy.yml .github/workflows/check.yml', 'ALLOWED_WORKFLOWS=') $ok).code -ne 0)
        Check "hook ($role): a policy without ALLOWED_REFS refuses every job" ((Invoke-Hook $pol.Replace('ALLOWED_REFS=refs/heads/main', 'ALLOWED_REFS=') $ok).code -ne 0)
    }
    Check 'hook: an unknown role refuses the job' ((Invoke-Hook "RUNNER_ROLE=admin`nREPOSITORY=octo/ccof-lab`nALLOWED_REFS=refs/heads/main`nALLOWED_WORKFLOWS=.github/workflows/deploy.yml`n" $ok).code -ne 0)
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
$wok = @{ GITHUB_REPOSITORY = 'octo/ccof-lab'; GITHUB_EVENT_NAME = 'push'; GITHUB_REF = 'refs/heads/main'; GITHUB_REF_TYPE = 'branch'; GITHUB_HEAD_REF = ''; GITHUB_SHA = 'c' * 40; GITHUB_WORKFLOW_SHA = 'c' * 40
    GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/deploy.yml@refs/heads/main' }
function WinCase([hashtable]$Patch) { $h = @{} + $wok; foreach ($k in $Patch.Keys) { $h[$k] = $Patch[$k] }; $h }
foreach ($role in 'preview', 'apply') {
    $wpol = "RUNNER_ROLE=$role`nREPOSITORY=octo/ccof-lab`nALLOWED_REFS=refs/heads/main`nALLOWED_WORKFLOWS=.github/workflows/deploy.yml"
    Check "windows hook ($role): accepts push on main from an allowed workflow" ((Invoke-WinHook $wpol $wok) -eq 0)
    Check "windows hook ($role): refuses same-repo pull_request, feature-branch push and dispatch, another workflow, a workflow from another commit" (
        (Invoke-WinHook $wpol (WinCase @{ GITHUB_EVENT_NAME = 'pull_request'; GITHUB_REF = 'refs/pull/1/merge'; GITHUB_HEAD_REF = 'feature' })) -ne 0 -and
        (Invoke-WinHook $wpol (WinCase @{ GITHUB_REF = 'refs/heads/dev'; GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/deploy.yml@refs/heads/dev' })) -ne 0 -and
        (Invoke-WinHook $wpol (WinCase @{ GITHUB_EVENT_NAME = 'workflow_dispatch'; GITHUB_REF = 'refs/heads/dev'; GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/deploy.yml@refs/heads/dev' })) -ne 0 -and
        (Invoke-WinHook $wpol (WinCase @{ GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/x.yml@refs/heads/main' })) -ne 0 -and
        (Invoke-WinHook $wpol (WinCase @{ GITHUB_WORKFLOW_REF = 'octo/ccof-lab/.github/workflows/deploy.yml@refs/heads/dev' })) -ne 0 -and
        (Invoke-WinHook $wpol (WinCase @{ GITHUB_WORKFLOW_SHA = 'd' * 40 })) -ne 0)
    Check "windows hook ($role): an empty workflow allow-list refuses every job" ((Invoke-WinHook ($wpol -replace 'ALLOWED_WORKFLOWS=.*$', 'ALLOWED_WORKFLOWS=') $wok) -ne 0)
}
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

# ---- RBAC condition: evaluated from the real Bicep function (az bicep build-params), not restated here.
Check 'config: roles.assignablePrincipalIds must be GUIDs' ((@(Problems @{ 'roles.assignablePrincipalIds' = @('not-a-guid') }) -match 'assignablePrincipalIds').Count -eq 1)
Check 'config: GUID roles.assignablePrincipalIds are accepted' ((@(Problems @{ 'roles.assignablePrincipalIds' = @('11111111-2222-3333-4444-555555555555') }) -match 'assignablePrincipalIds').Count -eq 0)
$cicdText = (Get-ChildItem (Join-Path $repo 'infra/cicd') -Recurse -Include '*.bicep', '*.ps1', '*.psm1' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
Check 'roles wording: the type-only condition is not described as managed-identity only' ($cicdText + $doc -notmatch '(?i)(to|for) (service principals \()?managed identities\)?[.'']|service principals only|only to service principals')
Check 'roles wording: the runbook says application service principals are covered' ($doc -match '(?s)covers managed identities and\s+also ordinary\s+application')
function Get-Condition([string[]]$Roles, [string[]]$Principals) {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("ccof-cond-" + [guid]::NewGuid().ToString('n')); New-Item -ItemType Directory $d | Out-Null
    try {
        Copy-Item (Join-Path $repo 'infra/cicd/modules/rbac-condition.bicep') $d
        Set-Content (Join-Path $d 'm.bicep') "param c string`noutput o string = c"
        $list = { param($a) '[' + (($a | ForEach-Object { "'$_'" }) -join ', ') + ']' }
        Set-Content (Join-Path $d 'm.bicepparam') "using 'm.bicep'`nimport { ccofRbacCondition } from 'rbac-condition.bicep'`nparam c = ccofRbacCondition($(& $list $Roles), $(& $list $Principals))"
        $out = & $bicepExe build-params (Join-Path $d 'm.bicepparam') --stdout 2>$null
        return ((($out | Out-String | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters.c.value)
    } finally { Remove-Item -Recurse -Force $d }
}
# Minimal evaluator for the write branch of this condition grammar: role IDs, principal type and optional principal IDs.
function Test-ConditionAllowsWrite([string]$Condition, [string]$RoleId, [string]$PrincipalType, [string]$PrincipalId) {
    $set = { param($attr) $m = [regex]::Match($Condition, "@Request\[Microsoft\.Authorization/roleAssignments:$attr\] ForAnyOfAnyValues:\w+ \{([^}]*)\}"); if ($m.Success) { @($m.Groups[1].Value -split ',\s*' | ForEach-Object { $_.Trim("' ") }) } else { $null } }
    $roles = & $set 'RoleDefinitionId'; $types = & $set 'PrincipalType'; $ids = & $set 'PrincipalId'
    ($roles -contains $RoleId) -and ($types -contains $PrincipalType) -and ($null -eq $ids -or $ids -contains $PrincipalId)
}
$bicepExe = @((Get-Command bicep -ErrorAction SilentlyContinue | ForEach-Object Source), (Join-Path $HOME '.azure/bin/bicep.exe'), (Join-Path $HOME '.azure/bin/bicep')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ($bicepExe) {
    $blob = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'; $appSp = '9f0e4c1a-0000-4000-8000-0000000000aa'; $mi = '3c2b1a00-0000-4000-8000-0000000000bb'
    $open = Get-Condition @($blob) @()
    Check 'condition (no IDs): an arbitrary application service principal IS allowed (type-only boundary)' ($open -and (Test-ConditionAllowsWrite $open $blob 'ServicePrincipal' $appSp))
    Check 'condition (no IDs): users and groups are blocked' ($open -and -not (Test-ConditionAllowsWrite $open $blob 'User' $appSp) -and -not (Test-ConditionAllowsWrite $open $blob 'Group' $appSp))
    Check 'condition (no IDs): another role is blocked' ($open -and -not (Test-ConditionAllowsWrite $open '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' 'ServicePrincipal' $appSp))
    $exact = Get-Condition @($blob) @($mi)
    Check 'condition (exact IDs): the approved identity is allowed' ($exact -and (Test-ConditionAllowsWrite $exact $blob 'ServicePrincipal' $mi))
    Check 'condition (exact IDs): an arbitrary application service principal is blocked' ($exact -and -not (Test-ConditionAllowsWrite $exact $blob 'ServicePrincipal' $appSp))
    Check 'condition (exact IDs): deletes are limited to the approved IDs too' ($exact -match "@Resource\[Microsoft\.Authorization/roleAssignments:PrincipalId\] ForAnyOfAnyValues:GuidEquals \{$mi\}")
    Check 'roles.bicep passes assignablePrincipalIds to both conditioned modules' (([regex]::Matches((Get-Content -Raw (Join-Path $repo 'infra/cicd/roles.bicep')), 'assignablePrincipalIds: assignablePrincipalIds')).Count -eq 2)
} else { Write-Host 'SKIP condition evaluation: bicep CLI not found' }

. (Join-Path $PSScriptRoot 'helpers/CicdSetupDriver.ps1')

Write-Host "Test-CicdSetup: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
