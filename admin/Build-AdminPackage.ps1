#Requires -Version 7.0
# Builds the project admin API package (admin.zip) for the admin Function App only. Nothing is deployed.
[CmdletBinding()]
param([string]$OutFile = (Join-Path $PSScriptRoot 'admin.zip'))
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$stage = Join-Path $root '.package-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Push-Location $root
try {
    npm ci --no-audit --no-fund | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    npx tsc -p tsconfig.json
    if ($LASTEXITCODE -ne 0) { throw 'TypeScript build failed.' }
    node --test tests/*.test.ts
    if ($LASTEXITCODE -ne 0) { throw 'Unit tests failed; package not built.' }
    New-Item -ItemType Directory $stage | Out-Null
    Copy-Item dist, host.json, package.json, package-lock.json -Destination $stage -Recurse
    Push-Location $stage
    try {
        npm ci --omit=dev --no-audit --no-fund | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Production npm ci failed.' }
    } finally { Pop-Location }
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $OutFile
    $hash = (Get-FileHash $OutFile -Algorithm SHA256).Hash.ToLowerInvariant()
    "Built $OutFile sha256=$hash"
} finally {
    Pop-Location
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
}
