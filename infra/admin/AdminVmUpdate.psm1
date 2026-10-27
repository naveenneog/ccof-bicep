# Pieces of infra/admin/Update-AdminFromVm.ps1 that tests/Test-AdminVmUpdate.ps1 checks offline: input
# checks, the Run Command script built from infra/admin/vm/admin-update.sh, and the run-line parser.
Set-StrictMode -Version Latest

$script:Patterns = [ordered]@{
    Subscription = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    ResourceGroup = '^[A-Za-z0-9._-]{1,90}$'
    VmName = '^[A-Za-z0-9._-]{1,64}$'
    App = '^[A-Za-z0-9-]{2,60}$'
    Commit = '^[0-9a-f]{40}$'
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
        if ($k -eq 'Commit' -and -not $v) { continue }
        if ($v -cnotmatch $script:Patterns[$k]) { $problems.Add("${k}: '$v' does not match $($script:Patterns[$k])") }
    }
    if ($RequireCommit -and -not ($Values.Contains('Commit') -and $Values['Commit'])) { $problems.Add('Commit: required for -Phase Update') }
    return @($problems)
}

function New-AdminVmScript {
    param([Parameter(Mandatory)] [ValidateSet('setup', 'check', 'update')] [string]$Phase, [Parameter(Mandatory)] [Collections.IDictionary]$Values,
        [string]$TemplatePath = (Join-Path $PSScriptRoot 'vm/admin-update.sh'))
    $problems = @(Get-AdminVmInputProblems $Values -RequireCommit:($Phase -eq 'update'))
    if ($problems.Count) { throw "input_refused: $($problems -join '; ')" }
    $template = [IO.File]::ReadAllText($TemplatePath).Replace("`r`n", "`n")
    $marker = '# @@VALUES@@'
    if (([regex]::Matches($template, [regex]::Escape($marker))).Count -ne 1) { throw "template_invalid: $TemplatePath must hold the line '$marker' once" }
    $commit = if ($Values.Contains('Commit')) { [string]$Values['Commit'] } else { '' }
    $line = "PHASE='$Phase'; SUB='$($Values['Subscription'])'; RG='$($Values['ResourceGroup'])'; APP='$($Values['App'])'; COMMIT='$commit'; REPO_URL='$($Values['RepoUrl'])'"
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
