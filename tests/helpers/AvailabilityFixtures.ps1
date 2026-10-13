#Requires -Version 7.0
# Recorded Retail Prices API responses (tests/fixtures/retail-prices, captured once by WP-HADEC on
# 2026-10-11). A query the index does not hold throws, so a test can never reach the live API.
$script:AvailabilityFixtureDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'fixtures/retail-prices'

function Get-AvailabilityFixtureIndex {
    Get-Content -Raw (Join-Path $script:AvailabilityFixtureDir 'index.json') | ConvertFrom-Json -AsHashtable
}

function Get-AvailabilityFixturePath {
    param($Index, [string]$Url)
    $entry = @($Index.queries | Where-Object { [string]::Equals($_.url, $Url, 'Ordinal') })
    if ($entry.Count -ne 1) { throw "UNEXPECTED_LIVE_QUERY: no recorded response for $Url" }
    Join-Path $script:AvailabilityFixtureDir $entry[0].file
}

function New-AvailabilityFixtureSend {
    param($Index)
    $dir = $script:AvailabilityFixtureDir
    {
        param($Url)
        $entry = @($Index.queries | Where-Object { [string]::Equals($_.url, $Url, 'Ordinal') })
        if ($entry.Count -ne 1) { throw "UNEXPECTED_LIVE_QUERY: no recorded response for $Url" }
        [IO.File]::ReadAllText((Join-Path $dir $entry[0].file))
    }.GetNewClosure()
}

function Read-AvailabilityGzipFixture {
    param([string]$Name)
    $stream = [IO.File]::OpenRead((Join-Path $script:AvailabilityFixtureDir $Name))
    try {
        $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
        $reader = [IO.StreamReader]::new($gzip, [Text.Encoding]::UTF8)
        try { $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-AvailabilityPagingFixture {
    $index = Get-AvailabilityFixtureIndex
    $pages = @{}
    for ($i = 0; $i -lt $index.paging.urls.Count; $i++) { $pages[$index.paging.urls[$i]] = Read-AvailabilityGzipFixture $index.paging.files[$i] }
    $send = {
        param($Url)
        if (-not $pages.ContainsKey($Url)) { throw "UNEXPECTED_LIVE_QUERY: no recorded page for $Url" }
        $pages[$Url]
    }.GetNewClosure()
    [pscustomobject]@{ FirstUrl = $index.paging.urls[0]; SecondUrl = $index.paging.urls[1]; Send = $send; ExpectedCount = $index.paging.expectedCount }
}
