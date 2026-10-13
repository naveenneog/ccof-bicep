#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the availability decision modules: named refusals that WP-ONB's stage runner
    reports as reason codes, and invariant-culture decimal parsing.
#>

function Stop-Availability {
    param([Parameter(Mandatory)] [string]$Code, [Parameter(Mandatory)] [string]$Message)
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['AvailabilityCode'] = $Code
    $exception.Data['OnboardingRefusal'] = $true
    $exception.Data['OnboardingCode'] = $Code
    throw $exception
}

function ConvertTo-AvailabilityDecimal {
    param($Value, [string]$Name = 'value')
    if ($Value -is [decimal]) { return $Value }
    if ($Value -is [int] -or $Value -is [long]) { return [decimal]$Value }
    $parsed = [decimal]0
    if ($Value -is [string] -and [decimal]::TryParse($Value, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    if ($Value -is [double]) {
        # JSON numbers parsed by ConvertFrom-Json arrive as double; round-trip through invariant text.
        return [decimal]::Parse($Value.ToString('R', [Globalization.CultureInfo]::InvariantCulture), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture)
    }
    Stop-Availability 'number_invalid' "$Name is not a number."
}

Export-ModuleMember -Function Stop-Availability, ConvertTo-AvailabilityDecimal
