#Requires -Version 7.0
function New-CcofChildStartInfo {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment = @{})
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $extension = [IO.Path]::GetExtension($FilePath)
    if ($extension -ieq '.ps1') {
        $start.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $FilePath) + $Arguments) {
            $start.ArgumentList.Add($argument)
        }
    } elseif ($extension -in @('.cmd', '.bat')) {
        $all = @($FilePath) + $Arguments
        if (@($all | Where-Object { $_ -match '["%!\r\n]' }).Count) { throw 'Unsafe cmd argument. Use a native executable for this verification.' }
        $start.FileName = $env:ComSpec
        $start.Arguments = '/d /s /c "' + (($all | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
    } else {
        foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    }
    foreach ($key in $Environment.Keys) { $start.Environment[$key] = [string]$Environment[$key] }
    [void]$start.Environment.Remove('NODE_TEST_CONTEXT')
    return $start
}

function Invoke-CcofChild {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][ValidateRange(1, 600)][int]$TimeoutSeconds,
        [hashtable]$Environment = @{})
    $start = New-CcofChildStartInfo -FilePath $FilePath -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory -Environment $Environment
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            # This handle identifies only the child we just created, including its descendants.
            try { $process.Kill($true) } catch [InvalidOperationException] { }
            $process.WaitForExit()
        }
        return @{ ExitCode = $(if ($timedOut) { -1 } else { $process.ExitCode }); TimedOut = $timedOut
            Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult() }
    } finally {
        $process.Dispose()
    }
}
