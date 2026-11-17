Set-StrictMode -Version Latest
# Pure helpers for infra/cicd/Invoke-CicdSetup.ps1 (docs/runbooks/CICD-SETUP.md): configuration checks, runner
# and identity names, the GitHub environment plan, the Install-CcofRunner.sh arguments and Run Command script, the existing-VM identity check, and key generation.
# No Azure or GitHub call is made here; tests/Test-CicdSetup.ps1 covers every function.

$script:Guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$script:ZeroGuid = '00000000-0000-0000-0000-000000000000'
$script:RgName = '^[-\w\._\(\)]{1,90}$'
$script:SafeName = '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'
$script:Branch = '^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$'
$script:Workflow = '^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$'

function Get-CicdValue {
    param([object]$Object, [string]$Path)
    $o = $Object
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $o) { return $null }
        if ($o -is [System.Collections.IDictionary]) { $o = if ($o.Contains($p)) { $o[$p] } else { $null } }
        elseif ($o.PSObject.Properties[$p]) { $o = $o.$p }
        else { return $null }
    }
    return $o
}

function Get-CicdConfigProblems {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)
    $problems = [System.Collections.Generic.List[string]]::new()
    $v = { param($p) Get-CicdValue $Config $p }
    $json = $Config | ConvertTo-Json -Depth 10 -Compress
    if ($json -match 'REPLACE-' -or $json.Contains($script:ZeroGuid)) { $problems.Add('the configuration still has REPLACE values or zero GUIDs (placeholder); replace them') }
    foreach ($k in 'tenantId', 'subscriptionId') { if ("$(& $v $k)" -notmatch $script:Guid) { $problems.Add("$k must be a GUID") } }
    if ("$(& $v 'location')" -notmatch '^[a-z0-9]{3,30}$') { $problems.Add('location must be an Azure region name such as eastus2') }
    foreach ($k in 'cicdResourceGroup', 'workloadResourceGroup', 'networkResourceGroup') { if ("$(& $v $k)" -notmatch $script:RgName) { $problems.Add("$k must be a resource group name") } }
    if ("$(& $v 'cicdResourceGroup')" -ieq "$(& $v 'workloadResourceGroup')") { $problems.Add('cicdResourceGroup must differ from workloadResourceGroup: Stage 1 refuses a non-empty workload RG and the deploy identity must not manage its own runner') }
    if ("$(& $v 'namePrefix')" -notmatch '^[a-z][a-z0-9-]{2,30}$') { $problems.Add('namePrefix must be 3-31 lowercase letters, digits or hyphens, starting with a letter') }
    $subnet = "$(& $v 'runner.subnetId')"
    $m = [regex]::Match($subnet, '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Network/virtualNetworks/([^/]+)/subnets/([^/]+)$', 'IgnoreCase')
    if (-not $m.Success) { $problems.Add('runner.subnetId must be a full subnet resource ID') }
    else {
        if ($m.Groups[1].Value -ine "$(& $v 'subscriptionId')") { $problems.Add('runner.subnetId must be in subscriptionId: the runners and their identities stay in the subscription they deploy') }
        if ($m.Groups[2].Value -ine "$(& $v 'networkResourceGroup')") { $problems.Add('runner.subnetId must be in networkResourceGroup') }
    }
    $create = & $v 'runner.createSubnet'
    if ($null -ne $create) {
        $prefix = "$(Get-CicdValue $create 'addressPrefix')"
        $pm = [regex]::Match($prefix, '^(\d{1,3}\.){3}\d{1,3}/(\d{1,2})$')
        if (-not $pm.Success -or [int]$pm.Groups[2].Value -lt 24 -or [int]$pm.Groups[2].Value -gt 29) { $problems.Add('runner.createSubnet.addressPrefix must be an IPv4 /24 to /29 prefix') }
    }
    if ("$(& $v 'runner.vmSize')" -notmatch '^Standard_[A-Za-z0-9_]+$') { $problems.Add('runner.vmSize must be a VM size such as Standard_B2s') }
    if ("$(& $v 'runner.runnerVersion')" -notmatch '^\d+\.\d+\.\d+$') { $problems.Add('runner.runnerVersion must be a version such as 2.338.2') }
    if ("$(& $v 'runner.runnerSha256')" -notmatch '^[0-9a-f]{64}$') { $problems.Add('runner.runnerSha256 must be the SHA-256 of actions-runner-linux-x64-<version>.tar.gz from the release page') }
    if ("$(& $v 'runner.bicepVersion')" -notmatch '^v\d+\.\d+\.\d+$') { $problems.Add('runner.bicepVersion must be a version such as v0.46.1') }
    if ("$(& $v 'runner.nodeVersion')" -notmatch '^22\.\d+\.\d+$') { $problems.Add('runner.nodeVersion must be a Node.js 22 version such as 22.23.5') }
    if ("$(& $v 'runner.pwshVersion')" -notmatch '^7\.\d+\.\d+$') { $problems.Add('runner.pwshVersion must be a PowerShell 7 version such as 7.7.0') }
    foreach ($k in 'nodeSha256', 'pwshSha256', 'bicepSha256') { if ("$(& $v "runner.$k")" -notmatch '^[0-9a-f]{64}$') { $problems.Add("runner.$k must be a lowercase SHA-256") } }
    $stage = "$(& $v 'runner.stage')"
    if ($stage -and $stage -notmatch '^(/[A-Za-z0-9._/-]+|https://[A-Za-z0-9.-]+(:\d+)?(/[A-Za-z0-9._/%-]*)?)$') { $problems.Add('runner.stage must be an absolute directory on the VM or an https:// mirror URL') }
    $proxy = "$(& $v 'runner.proxy')"
    if ($proxy -and $proxy -notmatch '^https?://[A-Za-z0-9.:_%-]+/?$') { $problems.Add('runner.proxy must be http(s)://host:port without credentials') }
    $np = "$(& $v 'runner.noProxy')"
    if ($np -and $np -notmatch '^[A-Za-z0-9.,*_/:-]+$') { $problems.Add('runner.noProxy must be a comma-separated host list') }
    $ca = "$(& $v 'runner.caCert')"
    if ($ca -and $ca -notmatch '^/[A-Za-z0-9._/-]+$') { $problems.Add('runner.caCert must be an absolute path of a PEM file on the VM') }
    $vmId = '^/subscriptions/([^/]+)/resourceGroups/[^/]+/providers/Microsoft\.Compute/virtualMachines/[^/]+$'
    if ("$(& $v 'runner.createVms')" -eq 'True') {
        foreach ($role in 'preview', 'apply') {
            $img = Get-CicdValue $Config "runner.images.$role"
            $okImg = $img -and ("$(Get-CicdValue $img 'id')" -match '^/subscriptions/.+/providers/Microsoft\.Compute/' -or
                ("$(Get-CicdValue $img 'publisher')" -and "$(Get-CicdValue $img 'offer')" -and "$(Get-CicdValue $img 'sku')"))
            if (-not $okImg) { $problems.Add("runner.images.$role must be { id } of a gallery or managed image, or { publisher, offer, sku, version }") }
        }
    } else {
        $ids = foreach ($role in 'preview', 'apply') {
            $id = "$(& $v "runner.existingVms.$role")"
            $m2 = [regex]::Match($id, $vmId, 'IgnoreCase')
            if (-not $m2.Success) { $problems.Add("runner.existingVms.$role must be a VM resource ID when runner.createVms is false") }
            elseif ($m2.Groups[1].Value -ine "$(& $v 'subscriptionId')") { $problems.Add("runner.existingVms.$role must be in subscriptionId") }
            $id
        }
        if (@($ids)[0] -and @($ids)[0] -ieq @($ids)[1]) { $problems.Add('runner.existingVms: the preview and apply runners must be different VMs (one identity per VM)') }
    }
    if ("$(& $v 'github.owner')" -notmatch '^[A-Za-z0-9](-?[A-Za-z0-9]){0,38}$') { $problems.Add('github.owner must be a GitHub user or organization name') }
    if ("$(& $v 'github.repo')" -notmatch '^[A-Za-z0-9._-]{1,100}$') { $problems.Add('github.repo must be a repository name') }
    $envs = @(& $v 'github.environments')
    if ($envs.Count -lt 1 -or @($envs | Where-Object { "$_" -notmatch '^[a-z][a-z0-9-]{0,30}$' }).Count) { $problems.Add('github.environments must be one or more lowercase names such as stg') }
    if (@(@(& $v 'github.gates') | Where-Object { "$_" -notmatch '^[a-z][a-z0-9-]{0,30}$' }).Count) { $problems.Add('github.gates must be lowercase names such as network') }
    if (@(@(& $v 'github.reviewers') | Where-Object { "$_" -notmatch '^[A-Za-z0-9](-?[A-Za-z0-9]){0,38}(/[A-Za-z0-9._-]+)?$' }).Count) { $problems.Add('github.reviewers must be GitHub user names or org/team slugs') }
    $branches = @(& $v 'github.applyBranches')
    if ($branches.Count -lt 1 -or @($branches | Where-Object { "$_" -notmatch $script:Branch }).Count) { $problems.Add('github.applyBranches must be one or more plain branch names such as main (no wildcards); both runners accept only these protected branches') }
    foreach ($k in 'github.previewWorkflows', 'github.applyWorkflows') {
        $wfs = @(@(& $v $k) | Where-Object { "$_" })
        if ($wfs.Count -lt 1 -or @($wfs | Where-Object { "$_" -notmatch $script:Workflow }).Count) { $problems.Add("$k must list one or more paths such as .github/workflows/deploy.yml (the runner refuses every other workflow)") }
    }
    if ("$(& $v 'cosmos.accountName')" -notmatch '^[a-z0-9][a-z0-9-]{1,49}$') { $problems.Add('cosmos.accountName must be a Cosmos DB account name') }
    if ("$(& $v 'cosmos.databaseName')" -notmatch '^[A-Za-z0-9_-]{1,255}$') { $problems.Add('cosmos.databaseName must be a database name') }
    $foundry = @(& $v 'foundry')
    if ($foundry.Count -lt 1) { $problems.Add('foundry must list at least one Foundry account') }
    foreach ($f in $foundry) {
        if ("$(Get-CicdValue $f 'subscriptionId')" -notmatch $script:Guid -or "$(Get-CicdValue $f 'resourceGroup')" -notmatch $script:RgName -or "$(Get-CicdValue $f 'accountName')" -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{1,63}$') {
            $problems.Add('foundry entries need subscriptionId (GUID), resourceGroup and accountName')
        }
    }
    $ids = @(& $v 'roles.assignablePrincipalIds' | Where-Object { $null -ne $_ })
    if (@($ids | Where-Object { "$_" -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' }).Count) { $problems.Add('roles.assignablePrincipalIds must be a list of object IDs (GUIDs)') }
    if ("$(& $v 'roles.foundryRolesBy')" -notin @('', 'operator', 'foundry-owner')) { $problems.Add('roles.foundryRolesBy must be operator (default) or foundry-owner') }
    return $problems.ToArray()
}

function Get-CicdRunners {
    # One VM per role, each with exactly one user-assigned identity: privilege is separated by runner.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)
    $p = Get-CicdValue $Config 'namePrefix'
    foreach ($r in @(@{ role = 'preview'; id = 'preview' }, @{ role = 'apply'; id = 'deploy' })) {
        [pscustomobject]@{
            role         = $r.role
            vmName       = "$p-$($r.role)-vm"
            identityName = "$p-$($r.id)-id"
            runnerName   = "$p-$($r.role)"
            labels       = "ccof-vnet,ccof-$($r.role)"
        }
    }
}

function Get-CicdGitHubPlan {
    # GitHub environments only: no Azure credential, client ID or subscription is stored in GitHub.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)
    $reviewers = @(Get-CicdValue $Config 'github.reviewers')
    $branches = @(Get-CicdValue $Config 'github.applyBranches')
    $envs = foreach ($e in @(Get-CicdValue $Config 'github.environments')) {
        [pscustomobject]@{ name = "$e-preview"; runner = 'preview'; reviewers = @(); branches = @() }
        [pscustomobject]@{ name = "$e-apply"; runner = 'apply'; reviewers = $reviewers; branches = $branches }
        foreach ($g in @(Get-CicdValue $Config 'github.gates')) { [pscustomobject]@{ name = "$e-gate-$g"; runner = 'apply'; reviewers = $reviewers; branches = $branches } }
    }
    [pscustomobject]@{
        repository   = "$(Get-CicdValue $Config 'github.owner')/$(Get-CicdValue $Config 'github.repo')"
        environments = @($envs)
        runners      = @(Get-CicdRunners $Config | ForEach-Object { [pscustomobject]@{ name = $_.runnerName; labels = "self-hosted,$($_.labels)" } })
    }
}

function Test-CicdRegistrationToken {
    param([string]$Token)
    return [bool]($Token -cmatch '^[A-Za-z0-9_-]{20,200}$')
}

function ConvertTo-CicdArgsLine {
    # The `set -- ...` line that replaces "# @@ARGS@@" in Install-CcofRunner.sh for Run Command. Every argument
    # is pasted inside single quotes, so a strict character set is enforced (no quote, $, backtick or ;).
    param([Parameter(Mandatory)][string[]]$Arguments)
    foreach ($a in $Arguments) { if ($a -cnotmatch '^[A-Za-z0-9 ._,/:@%+=*-]*$') { throw "input_refused: argument '$a' has a character that is not allowed" } }
    return 'set -- ' + (($Arguments | ForEach-Object { "'$_'" }) -join ' ')
}

function Get-CicdInstallArgs {
    # Arguments of scripts/cicd/Install-CcofRunner.sh for one runner, from the configuration. The same list is
    # printed for the VM admin and, in the lab, injected for Run Command. The registration token is never an
    # argument: the script reads RUNNER_TOKEN from the environment.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config, [Parameter(Mandatory)][ValidateSet('preview', 'apply')][string]$Role,
        [Parameter(Mandatory)][ValidateSet('install', 'register', 'status', 'remove')][string]$Command, [string]$ClientId)
    $v = { param($p) "$(Get-CicdValue $Config $p)" }
    $r = @(Get-CicdRunners $Config | Where-Object role -eq $Role)[0]
    $a = [System.Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@($Command, '--role', $Role))
    $map = [ordered]@{ '--runner-version' = 'runner.runnerVersion'; '--runner-sha256' = 'runner.runnerSha256'; '--node-version' = 'runner.nodeVersion'; '--node-sha256' = 'runner.nodeSha256'
        '--pwsh-version' = 'runner.pwshVersion'; '--pwsh-sha256' = 'runner.pwshSha256'; '--bicep-version' = 'runner.bicepVersion'; '--bicep-sha256' = 'runner.bicepSha256'
        '--stage' = 'runner.stage'; '--proxy' = 'runner.proxy'; '--no-proxy' = 'runner.noProxy'; '--ca-cert' = 'runner.caCert' }
    foreach ($k in $map.Keys) { $x = & $v $map[$k]; if ($x) { $a.AddRange([string[]]@($k, $x)) } }
    if ($Command -eq 'register') {
        if ($ClientId -notmatch $script:Guid) { throw "input_refused: the $Role identity client ID is not known yet (run -Phase Infra first)" }
        $refs = (@(Get-CicdValue $Config 'github.applyBranches') | ForEach-Object { "refs/heads/$_" }) -join ' '
        $a.AddRange([string[]]@('--client-id', $ClientId, '--subscription-id', (& $v 'subscriptionId'), '--tenant-id', (& $v 'tenantId'),
                "--repository", "$(& $v 'github.owner')/$(& $v 'github.repo')", '--runner-name', $r.runnerName, '--labels', $r.labels, '--allowed-refs', $refs))
        $wf = (@(Get-CicdValue $Config "github.$($Role)Workflows") | Where-Object { $_ }) -join ' '
        if (-not $wf) { throw "input_refused: github.$($Role)Workflows is empty; the runner accepts only listed workflows" }
        $a.AddRange([string[]]@('--allowed-workflows', $wf))
    }
    $null = ConvertTo-CicdArgsLine $a.ToArray()
    return $a.ToArray()
}

function New-CicdRunCommandScript {
    # Install-CcofRunner.sh with its arguments injected, for `az vm run-command create --script`.
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$ScriptPath = (Join-Path $PSScriptRoot '../../scripts/cicd/Install-CcofRunner.sh'))
    $template = [IO.File]::ReadAllText($ScriptPath).Replace("`r`n", "`n")
    if (([regex]::Matches($template, '(?m)^# @@ARGS@@$')).Count -ne 1) { throw 'Install-CcofRunner.sh must contain the # @@ARGS@@ marker line exactly once' }
    $line = ConvertTo-CicdArgsLine $Arguments
    return $template -replace '(?m)^# @@ARGS@@$', $line
}

function Get-CicdAttachDecision {
    # Existing VM mode: the VM must carry only its role's identity, because any job on the runner can ask IMDS
    # for any identity of the VM. Returns assign, none (already attached) or refuse with the reason.
    param([Parameter(Mandatory)][object]$Vm, [Parameter(Mandatory)][string]$IdentityId, [string[]]$ForbiddenIdentityIds = @())
    $type = "$(Get-CicdValue $Vm 'identity.type')"
    $ids = @()
    $uai = Get-CicdValue $Vm 'identity.userAssignedIdentities'
    if ($uai) { $ids = @(if ($uai -is [System.Collections.IDictionary]) { $uai.Keys } else { $uai.PSObject.Properties.Name }) }
    if ($type -match 'SystemAssigned') { return [pscustomobject]@{ action = 'refuse'; reason = 'the VM has a system-assigned identity; remove it (az vm identity remove --identities [system]) so the runner has only its role identity' } }
    $others = @($ids | Where-Object { $_ -ine $IdentityId })
    if (@($others | Where-Object { $o = $_; @($ForbiddenIdentityIds | Where-Object { $_ -ieq $o }).Count }).Count) { return [pscustomobject]@{ action = 'refuse'; reason = 'the VM already carries the other runner identity; preview and apply runners must be separate VMs' } }
    if ($others.Count) { return [pscustomobject]@{ action = 'refuse'; reason = "the VM has other user-assigned identities ($($others -join ', ')); jobs could use them, remove them first" } }
    if ($ids.Count -eq 1) { return [pscustomobject]@{ action = 'none'; reason = 'the identity is already attached' } }
    return [pscustomobject]@{ action = 'assign'; reason = 'attach the role identity' }
}
function Read-CicdRunLine {
    # Last JSON line Install-CcofRunner.sh prints (Run Command returns only the last 4 KB of output).
    param([string]$Message)
    $line = @(("$Message" -split "`n") | Where-Object { $_ -match '^\{"schema":"ccof\.cicd\.runner\.v1"' } | Select-Object -Last 1)
    if (-not $line) { return $null }
    try { return $line[0] | ConvertFrom-Json } catch { return $null }
}

function New-CicdDiscardedSshPublicKey {
    # Azure requires an admin credential on a Linux VM. This creates an RSA key pair and returns only the OpenSSH
    # public key; the private key is never written, so nobody can sign in with it. Maintenance is Run Command only.
    $rsa = [System.Security.Cryptography.RSA]::Create(3072)
    try {
        $p = $rsa.ExportParameters($false)
        $ms = [IO.MemoryStream]::new()
        $write = {
            param([byte[]]$b)
            $len = [BitConverter]::GetBytes([int]$b.Length); [Array]::Reverse($len)
            $ms.Write($len, 0, 4); $ms.Write($b, 0, $b.Length)
        }
        $mpint = { param([byte[]]$b) if ($b[0] -band 0x80) { , ([byte[]](@([byte]0) + $b)) } else { , $b } }
        & $write ([Text.Encoding]::ASCII.GetBytes('ssh-rsa'))
        & $write (& $mpint $p.Exponent)
        & $write (& $mpint $p.Modulus)
        return "ssh-rsa $([Convert]::ToBase64String($ms.ToArray())) ccof-cicd-discarded"
    } finally { $rsa.Dispose() }
}

Export-ModuleMember -Function Get-CicdValue, Get-CicdConfigProblems, Get-CicdRunners, Get-CicdGitHubPlan, Test-CicdRegistrationToken,
    ConvertTo-CicdArgsLine, Get-CicdInstallArgs, New-CicdRunCommandScript, Get-CicdAttachDecision, Read-CicdRunLine, New-CicdDiscardedSshPublicKey
