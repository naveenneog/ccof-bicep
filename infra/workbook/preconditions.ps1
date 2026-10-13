#Requires -Version 7.0
Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts' 'Onboarding.Azure.psm1')

# az.cmd passes every argument through cmd.exe on Windows: & runs a command, ( or ) breaks its IF
# block. Each value a WP-WB script gives az (answers, ids built from them, checkout paths) goes through
# WP-ONB's guard before the script's first az call. The scripts' other az arguments are literals.
function Assert-WorkbookAzArguments([string]$SubscriptionId, [string[]]$Values) {
    foreach ($value in $Values) {
        try { Assert-OnboardingAzArguments @('--subscription', $SubscriptionId, $value) }
        catch { throw 'az_arguments_refused' }
    }
}

function Test-WorkbookResource {
    param([object]$Resource, [string]$ExpectedId)
    if ($null -eq $Resource -or [string]::IsNullOrWhiteSpace($ExpectedId)) { return $false }
    foreach ($field in 'id', 'name', 'kind') {
        if ($Resource.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($Resource.$field)) { return $false }
    }
    if ($null -ne $Resource.type -and (
        $Resource.type -isnot [string] -or
        -not [string]::Equals($Resource.type.ToLowerInvariant(), 'microsoft.insights/workbooks', 'Ordinal')
    )) { return $false }
    # Workbooks GET 2023-06-01 returned type:null live; id, name and kind are still authoritative.
    return (
        [string]::Equals($Resource.id.ToLowerInvariant(), $ExpectedId.ToLowerInvariant(), 'Ordinal') -and
        [string]::Equals($Resource.name.ToLowerInvariant(), $ExpectedId.Split('/')[-1].ToLowerInvariant(), 'Ordinal') -and
        [string]::Equals($Resource.kind, 'shared', 'Ordinal')
    )
}
