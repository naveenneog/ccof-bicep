#Requires -Version 7.0
function Merge-CcofProjectHeaders {
    param([object[]]$Sources, [Parameter(Mandatory)]$Project)
    $headers = [ordered]@{}
    foreach ($source in $Sources) {
        if ($null -eq $source -or $source -ceq '') { continue }
        $pairs = @()
        if ($source -is [Collections.IDictionary]) {
            foreach ($key in $source.Keys) { $pairs += @{ Name = [string]$key; Value = $source[$key] } }
        } elseif ($source -is [string]) {
            foreach ($line in ($source -split "`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $colon = $line.IndexOf(':')
                if ($colon -lt 1) { throw 'Existing custom headers are malformed. No client settings were changed.' }
                $pairs += @{ Name = $line.Substring(0, $colon).Trim(); Value = $line.Substring($colon + 1).Trim() }
            }
        } else { throw 'Existing custom headers must be an object or a header string. No settings were changed.' }
        foreach ($pair in $pairs) {
            if ($pair.Name -cnotmatch '^[A-Za-z][A-Za-z0-9-]{0,63}$' -or
                $pair.Value -isnot [string] -or $pair.Value -match "[`r`n`0]") {
                throw 'Existing custom headers are invalid. No client settings were changed.'
            }
            if ($pair.Name.ToLowerInvariant() -in @('authorization', 'proxy-authorization', 'x-api-key', 'api-key', 'cookie', 'set-cookie')) {
                throw 'Remove static credential headers before configuring a project profile; use the Entra helper instead.'
            }
            if ([string]::Equals($pair.Name, $Project.selectorHeader, 'OrdinalIgnoreCase')) { continue }
            if ($headers.Contains($pair.Name) -and -not [string]::Equals($headers[$pair.Name], $pair.Value, 'Ordinal')) {
                throw 'Unrelated custom header values conflict between clients. Align them before configuring a project profile.'
            }
            $headers[$pair.Name] = $pair.Value
        }
    }
    if ($null -ne $Project.id) { $headers[$Project.selectorHeader] = [string]$Project.id }
    return $headers
}
