# Pieces of infra/admin/Update-AdminFromVm.ps1 that tests/Test-AdminVmUpdate.ps1 checks offline: input
# checks, the Run Command script built from infra/admin/vm/admin-update.sh, and the run-line parser.
Set-StrictMode -Version Latest

$script:Patterns = [ordered]@{
    Subscription = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    ResourceGroup = '^[A-Za-z0-9._-]{1,90}$'
    VmName = '^[A-Za-z0-9._-]{1,64}$'
    App = '^[A-Za-z0-9-]{2,60}$'
    Commit = '^[0-9a-f]{40}$'
    PreviousCommit = '^[0-9a-f]{40}$'
    PreviousPackageSha256 = '^[0-9a-f]{64}$'
    PreviousSource = '^(commit|recovered)$'
    PackageKind = '^(admin|sync|reconciler)$'
    PackageSha256 = '^[0-9a-f]{64}$'
    RepoUrl = '^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._-]+)+$'
}

# Values are written into the bash script in single quotes, so every pattern excludes quotes, spaces
# and shell metacharacters.
function Get-AdminVmInputProblems {
    param([Parameter(Mandatory)] [Collections.IDictionary]$Values, [switch]$RequireCommit)
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($k in $script:Patterns.Keys) {
        if (-not $Values.Contains($k)) { continue }
        $v = [string]$Values[$k]
        if ($k -in 'Commit', 'PreviousCommit', 'PreviousPackageSha256', 'PackageSha256' -and -not $v) { continue }
        if ($v -cnotmatch $script:Patterns[$k]) { $problems.Add("${k}: '$v' does not match $($script:Patterns[$k])") }
    }
    if ($RequireCommit -and -not ($Values.Contains('Commit') -and $Values['Commit'])) { $problems.Add('Commit: required for -Phase Update') }
    if ($RequireCommit -and $Values.Contains('PackageKind') -and $Values['PackageKind'] -in @('sync', 'reconciler')) {
        if (-not ($Values.Contains('PackageSha256') -and $Values['PackageSha256'])) { $problems.Add('PackageSha256: required for an approved worker artifact') }
        if (-not ($Values.Contains('SafeUpgrade') -and $Values['SafeUpgrade'])) { $problems.Add('SafeUpgrade: required for worker updates') }
    }
    if ($Values.Contains('PackageKind') -and $Values['PackageKind'] -in @('sync', 'reconciler')) {
        $approved = @(if ($Values.Contains('ApprovedWorkerResourceIds')) { $Values['ApprovedWorkerResourceIds'] })
        $sitePattern = '^/subscriptions/[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}/resourceGroups/[A-Za-z0-9._-]{1,90}/providers/Microsoft\.Web/sites/[A-Za-z0-9-]{2,60}$'
        if ($approved.Count -lt 1 -or $approved.Count -gt 4 -or @($approved | Where-Object { $_ -isnot [string] -or $_ -notmatch $sitePattern }).Count) {
            $problems.Add('ApprovedWorkerResourceIds: one to four explicit full Function App resource IDs required')
        } elseif (@($approved | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique).Count -ne $approved.Count) {
            $problems.Add('ApprovedWorkerResourceIds: duplicate or case-aliased resource IDs are not allowed')
        } else {
            $target = "/subscriptions/$($Values['Subscription'])/resourceGroups/$($Values['ResourceGroup'])/providers/Microsoft.Web/sites/$($Values['App'])"
            if ($target -notin $approved) { $problems.Add('ApprovedWorkerResourceIds: exact target resource ID is not approved') }
        }
    }
    # 'recovered': the previous package is the platform-active archive, identified only by its SHA-256.
    # Its source commit is unknown, so a commit label is refused rather than attached to those bytes.
    $recovered = $Values.Contains('PreviousSource') -and [string]$Values['PreviousSource'] -ceq 'recovered'
    if ($recovered -and $Values.Contains('PreviousCommit') -and $Values['PreviousCommit']) {
        $problems.Add('PreviousCommit: must be empty with PreviousSource recovered; recovered bytes are identified by PreviousPackageSha256 only')
    }
    if ($Values.Contains('SafeUpgrade') -and $Values['SafeUpgrade']) {
        foreach ($k in @(if (-not $recovered) { 'PreviousCommit' }) + 'PreviousPackageSha256') {
            if (-not ($Values.Contains($k) -and $Values[$k])) { $problems.Add("${k}: required for safe upgrade or rollback") }
        }
    }
    return @($problems)
}

function New-AdminVmScript {
    param([Parameter(Mandatory)] [ValidateSet('setup', 'check', 'update', 'rollback')] [string]$Phase, [Parameter(Mandatory)] [Collections.IDictionary]$Values,
        [string]$TemplatePath = (Join-Path $PSScriptRoot 'vm/admin-update.sh'))
    $problems = @(Get-AdminVmInputProblems $Values -RequireCommit:($Phase -eq 'update'))
    if ($problems.Count) { throw "input_refused: $($problems -join '; ')" }
    if ($Phase -eq 'rollback' -and -not ($Values.Contains('SafeUpgrade') -and $Values['SafeUpgrade'])) { throw 'input_refused: rollback requires SafeUpgrade and an approved previous artifact.' }
    $template = [IO.File]::ReadAllText($TemplatePath).Replace("`r`n", "`n")
    $marker = '# @@VALUES@@'
    if (([regex]::Matches($template, [regex]::Escape($marker))).Count -ne 1) { throw "template_invalid: $TemplatePath must hold the line '$marker' once" }
    $commit = if ($Values.Contains('Commit')) { [string]$Values['Commit'] } else { '' }
    $line = "PHASE='$Phase'; SUB='$($Values['Subscription'])'; RG='$($Values['ResourceGroup'])'; APP='$($Values['App'])'; COMMIT='$commit'; REPO_URL='$($Values['RepoUrl'])'"
    $safe = if ($Values.Contains('SafeUpgrade') -and $Values['SafeUpgrade']) { 'true' } else { 'false' }
    $previous = if ($Values.Contains('PreviousCommit')) { [string]$Values['PreviousCommit'] } else { '' }
    $previousHash = if ($Values.Contains('PreviousPackageSha256')) { [string]$Values['PreviousPackageSha256'] } else { '' }
    $previousSource = if ($Values.Contains('PreviousSource') -and $Values['PreviousSource']) { [string]$Values['PreviousSource'] } else { 'commit' }
    $line += "; SAFE_UPGRADE='$safe'; PREVIOUS_COMMIT='$previous'; PREVIOUS_SHA256='$previousHash'; PREVIOUS_SOURCE='$previousSource'"
    $packageKind = if ($Values.Contains('PackageKind')) { [string]$Values['PackageKind'] } else { 'admin' }
    $packageHash = if ($Values.Contains('PackageSha256')) { [string]$Values['PackageSha256'] } else { '' }
    $line += "; PACKAGE_KIND='$packageKind'; PACKAGE_SHA256='$packageHash'"
    $approved = if ($Values.Contains('ApprovedWorkerResourceIds')) { @($Values['ApprovedWorkerResourceIds']) -join ',' } else { '' }
    if ($packageKind -eq 'admin') { $approved = '' }
    $line += "; APPROVED_WORKER_RESOURCE_IDS='$approved'"
    return $template.Replace($marker, $line)
}

# The last line that starts with the run-line schema, parsed; $null when there is none.
function Read-AdminVmRunLine {
    param([string]$Message)
    $line = @(("$Message" -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith('{"schema":"ccof.admin.vmupdate.v1"') }) | Select-Object -Last 1
    if (-not $line) { return $null }
    try { return $line | ConvertFrom-Json } catch { return $null }
}

Export-ModuleMember -Function Get-AdminVmInputProblems, New-AdminVmScript, Read-AdminVmRunLine
