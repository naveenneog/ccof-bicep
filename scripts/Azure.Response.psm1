#Requires -Version 7.0

function Get-CcofJsonField {
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $keys = @($InputObject.Keys | Where-Object { [string]::Equals([string]$_, $Name, 'OrdinalIgnoreCase') })
        if ($keys.Count -gt 1) { throw "azure_response_ambiguous_field: $Name" }
        if ($keys.Count) { return ,$InputObject[$keys[0]] }
        return $null
    }
    $properties = @($InputObject.PSObject.Properties | Where-Object { [string]::Equals($_.Name, $Name, 'OrdinalIgnoreCase') })
    if ($properties.Count -gt 1) { throw "azure_response_ambiguous_field: $Name" }
    if ($properties.Count) { return ,$properties[0].Value }
    return $null
}

function Get-CcofQueryMessages {
    param([Parameter(Mandatory)]$Response)
    if ($null -ne (Get-CcofJsonField $Response 'error')) { throw 'azure_query_failed: inspect the provider error privately.' }
    $tables = Get-CcofJsonField $Response 'tables'
    if ($null -eq $tables -or $tables -isnot [System.Collections.IList]) { throw 'azure_query_tables_missing: expected a query response, not an empty default.' }
    $matched = 0
    foreach ($table in $tables) {
        $columns = Get-CcofJsonField $table 'columns'
        $names = @($columns | ForEach-Object {
            $name = Get-CcofJsonField $_ 'name'
            if ($null -eq $name) { $name = Get-CcofJsonField $_ 'ColumnName' }
            [string]$name
        })
        $messageColumns = @(for ($i = 0; $i -lt $names.Count; $i++) { if ($names[$i] -ieq 'message') { $i } })
        if (-not $messageColumns.Count) { continue }
        if ($messageColumns.Count -ne 1) { throw 'azure_query_message_column_ambiguous' }
        $matched++
        $rows = Get-CcofJsonField $table 'rows'
        if ($null -eq $rows -or $rows -isnot [System.Collections.IList]) { throw 'azure_query_rows_missing' }
        foreach ($row in $rows) {
            if ($row -isnot [System.Collections.IList] -or $row.Count -le $messageColumns[0] -or $row[$messageColumns[0]] -isnot [string]) {
                throw 'azure_query_message_row_invalid'
            }
            $row[$messageColumns[0]]
        }
    }
    if ($tables.Count -and -not $matched) { throw 'azure_query_message_column_missing' }
}

function Get-CcofCanonicalLocation {
    param([Parameter(Mandatory)][string]$Location, [Parameter(Mandatory)][object[]]$Locations)
    $matches = @($Locations | Where-Object {
        $_.name -ieq $Location.Trim() -or $_.displayName -ieq $Location.Trim() -or $_.regionalDisplayName -ieq $Location.Trim()
    })
    $names = @($matches | ForEach-Object name | Sort-Object -Unique)
    if ($names.Count -ne 1 -or $names[0] -cnotmatch '^[a-z][a-z0-9]+$') {
        throw 'azure_location_unknown: select an actual short region name from the approved subscription locations.'
    }
    $names[0]
}

function Test-CcofArmIdEqual {
    param([AllowNull()][string]$A, [AllowNull()][string]$B)
    -not [string]::IsNullOrWhiteSpace($A) -and -not [string]::IsNullOrWhiteSpace($B) -and
        [string]::Equals($A.Trim().TrimEnd('/'), $B.Trim().TrimEnd('/'), 'OrdinalIgnoreCase')
}

function Test-CcofArmScopeCovers {
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Child)
    (Test-CcofArmIdEqual $Parent $Child) -or $Child.TrimEnd('/').StartsWith($Parent.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Get-CcofCosmosScopeParts {
    param([Parameter(Mandatory)][string]$Scope)
    $pattern = '^(?<account>/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.DocumentDB/databaseAccounts/[^/]+)(?<data>(?:/dbs/[^/]+(?:/colls/[^/]+)?)?)$'
    $match = [regex]::Match($Scope.Trim().TrimEnd('/'), $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { throw 'cosmos_scope_invalid: expected an account, database or container scope.' }
    @{ Account = $match.Groups['account'].Value; Data = $match.Groups['data'].Value }
}

function Test-CcofCosmosScopeEqual {
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
    $left = Get-CcofCosmosScopeParts $A
    $right = Get-CcofCosmosScopeParts $B
    [string]::Equals($left.Account, $right.Account, 'OrdinalIgnoreCase') -and [string]::Equals($left.Data, $right.Data, 'Ordinal')
}

function Test-CcofCosmosScopeCovers {
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Child)
    $left = Get-CcofCosmosScopeParts $Parent
    $right = Get-CcofCosmosScopeParts $Child
    if (-not [string]::Equals($left.Account, $right.Account, 'OrdinalIgnoreCase')) { return $false }
    $left.Data -ceq $right.Data -or -not $left.Data -or $right.Data.StartsWith($left.Data + '/', [StringComparison]::Ordinal)
}

function New-CcofCosmosAssignmentId {
    param([Parameter(Mandatory)][string]$Scope, [Parameter(Mandatory)][string]$PrincipalId, [Parameter(Mandatory)][string]$RoleId)
    $parts = Get-CcofCosmosScopeParts $Scope
    # ARM IDs are case-insensitive; Cosmos database/container IDs are not.
    New-CcofStableId -Parts @($parts.Account.ToLowerInvariant(), $parts.Data, $PrincipalId.ToLowerInvariant(), $RoleId.TrimEnd('/').ToLowerInvariant())
}

function New-CcofStableId {
    param([Parameter(Mandatory)][string[]]$Parts)
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($Parts -join '|')))[0..15]
    $bytes[6] = ($bytes[6] -band 15) -bor 80
    $bytes[8] = ($bytes[8] -band 63) -bor 128
    $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
    "$($hex.Substring(0,8))-$($hex.Substring(8,4))-$($hex.Substring(12,4))-$($hex.Substring(16,4))-$($hex.Substring(20,12))"
}

Export-ModuleMember -Function Get-CcofJsonField, Get-CcofQueryMessages, Get-CcofCanonicalLocation, Test-CcofArmIdEqual, Test-CcofArmScopeCovers, Get-CcofCosmosScopeParts, Test-CcofCosmosScopeEqual, Test-CcofCosmosScopeCovers, New-CcofCosmosAssignmentId, New-CcofStableId
