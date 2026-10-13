#Requires -Version 7.0
& (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/client/tests/Test-GatewayClients.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
