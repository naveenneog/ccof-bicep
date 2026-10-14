<#
.SYNOPSIS
Windows only: runs the Azure CLI with Python UTF-8 mode, for "'charmap' codec can't encode".

.DESCRIPTION
On Windows, az.cmd starts Python with -I, which ignores PYTHONUTF8 and PYTHONIOENCODING, so
`az deployment group what-if` can fail on characters such as U+2212. This wrapper is named az.ps1
so that, with its folder first on PATH, `az` (also in child pwsh processes) resolves here.
Cloud Shell (Linux) does not need it.

.EXAMPLE
$env:PATH = "$PWD/scripts/diagnostics/windows-az-utf8;" + $env:PATH
pwsh -File infra/quickstart/Deploy-Quickstart.ps1 -ParametersPath $p -WhatIfOnly
#>
$azCmd = Get-Command az.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $azCmd) { throw 'az.cmd not found on PATH; install the Azure CLI.' }
$python = Join-Path (Split-Path (Split-Path $azCmd.Source)) 'python.exe'
if (-not (Test-Path $python)) { throw "Azure CLI python not found at $python." }
& $python -X utf8 -IBm azure.cli @args
exit $LASTEXITCODE
