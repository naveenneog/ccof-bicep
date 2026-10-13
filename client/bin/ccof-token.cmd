@echo off
setlocal DisableDelayedExpansion
node.exe "%~dp0ccof-token.mjs" %*
exit /b %errorlevel%
