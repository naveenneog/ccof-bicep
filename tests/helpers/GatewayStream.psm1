#Requires -Version 7.0
<#
.SYNOPSIS
    Helpers for tests/Test-GatewayLive.ps1: a streamed request whose server-sent events are timed as
    they arrive (AC14), the verdict on whether they arrived progressively, and the roles and client id
    in an access token (AC15, WP-NET S1). A token is used only in the request it authorises and is never
    printed.
#>

function Invoke-GatewayStreamProbe {
    <# POSTs Body to Uri and records when each server-sent event arrives, reading the body as it comes. #>
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$Body,
        [hashtable]$Headers = @{},
        [securestring]$Token,
        [int]$TimeoutSeconds = 180
    )
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Uri)
        if ($Token) {
            $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', [System.Net.NetworkCredential]::new('', $Token).Password)
        }
        foreach ($name in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name]) }
        $request.Content = [System.Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, 'application/json')
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $headersMs = $clock.Elapsed.TotalMilliseconds
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $decoder = [Text.Encoding]::UTF8.GetDecoder()
        $bytes = [byte[]]::new(16384)
        $chars = [char[]]::new(16384)
        $text = [Text.StringBuilder]::new()
        $events = [System.Collections.Generic.List[object]]::new()
        $pending = ''
        while (($n = $stream.Read($bytes, 0, $bytes.Length)) -gt 0) {
            $at = $clock.Elapsed.TotalMilliseconds
            $chunk = [string]::new($chars, 0, $decoder.GetChars($bytes, 0, $n, $chars, 0))
            $null = $text.Append($chunk)
            $pending += $chunk.Replace("`r`n", "`n")
            while (($i = $pending.IndexOf("`n`n")) -ge 0) {
                $block = $pending.Substring(0, $i)
                $pending = $pending.Substring($i + 2)
                $events.Add([pscustomobject]@{ Ms = $at; Type = $(if ($block -match '(?m)^event: *(\S+)') { $Matches[1] } else { '' }) })
            }
        }
        $values = $null
        [pscustomobject]@{
            Status = [int]$response.StatusCode
            ContentType = "$($response.Content.Headers.ContentType)"
            HeadersMs = $headersMs
            TotalMs = $clock.Elapsed.TotalMilliseconds
            Events = $events.ToArray()
            Text = $text.ToString()
            RequestId = $(if ($response.Headers.TryGetValues('x-ccof-request-id', [ref]$values)) { $values -join ',' } else { '' })
        }
    } finally {
        $client.Dispose()
    }
}

function Test-ProgressiveStream {
    <#
    AC14: a 200 event stream from message_start to message_stop whose events arrived in at least
    MinIntervals different 100 ms intervals. Learn "forward-request": with buffer-response true the
    gateway holds chunks back (8 KB, unless end of stream), so a buffered reply arrives in a few bursts.
    #>
    param([Parameter(Mandatory)] $Probe, [int]$MinIntervals = 5)
    $start = @($Probe.Events | Where-Object { $_.Type -eq 'message_start' })[0]
    $stop = @($Probe.Events | Where-Object { $_.Type -eq 'message_stop' })[0]
    $intervals = @($Probe.Events | ForEach-Object { [math]::Floor($_.Ms / 100) } | Select-Object -Unique).Count
    $reason = if ($Probe.Status -ne 200) { "status $($Probe.Status)" }
        elseif ($Probe.ContentType -notlike 'text/event-stream*') { "content type '$($Probe.ContentType)'" }
        elseif (-not $start -or -not $stop) { 'no message_start or no message_stop event' }
        elseif ($intervals -lt $MinIntervals) { "the events arrived in $intervals 100-ms interval(s), fewer than $MinIntervals" }
        else { '' }
    [pscustomobject]@{
        Ok = ($reason -eq '')
        Reason = $reason
        Events = @($Probe.Events).Count
        Intervals = $intervals
        FirstEventMs = $(if ($start) { [math]::Round($start.Ms) } else { $null })
        LastEventMs = $(if ($stop) { [math]::Round($stop.Ms) } else { $null })
    }
}

function Read-AccessTokenClaims {
    <# A JWT's payload claims, read without validation (the gateway validates the token); $null if malformed. #>
    param([Parameter(Mandatory)] [securestring]$Token)
    try {
        $payload = ([System.Net.NetworkCredential]::new('', $Token).Password.Split('.'))[1].Replace('-', '+').Replace('_', '/')
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '='))) | ConvertFrom-Json
    } catch {
        $null
    }
}

function Get-AccessTokenRoles {
    <# The values of a JWT's roles claim. #>
    param([Parameter(Mandatory)] [securestring]$Token)
    $claims = Read-AccessTokenClaims -Token $Token
    @($claims.roles | Where-Object { $_ -is [string] })
}

function Get-AccessTokenClientId {
    <# The client id as the policy reads it (ccofClientAppId): azp (v2.0), else appid (v1.0), lower case. #>
    param([Parameter(Mandatory)] [securestring]$Token)
    $claims = Read-AccessTokenClaims -Token $Token
    $id = if ($claims.azp -is [string] -and $claims.azp) { $claims.azp } elseif ($claims.appid -is [string]) { $claims.appid } else { '' }
    $id.ToLowerInvariant()
}

Export-ModuleMember -Function Invoke-GatewayStreamProbe, Test-ProgressiveStream, Get-AccessTokenRoles, Get-AccessTokenClientId
