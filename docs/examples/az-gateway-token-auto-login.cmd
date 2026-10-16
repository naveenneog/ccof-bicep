@echo off
setlocal DisableDelayedExpansion
set "TENANT=REPLACE-tenant-guid"
set "SCOPE=api://REPLACE-gateway-app-client-guid/access_as_user"
set "AZURE_CORE_LOGIN_EXPERIENCE_V2=off"
if "%TENANT:~0,8%"=="REPLACE-" (
  >&2 echo Configure the customer TENANT and SCOPE in this file first.
  exit /b 1
)
if "%SCOPE:~0,14%"=="api://REPLACE-" (
  >&2 echo Configure the gateway SCOPE in this file first.
  exit /b 1
)
where az.cmd >nul 2>nul
if errorlevel 1 (
  >&2 echo Azure CLI az.cmd is not on PATH. Contact your desktop administrator.
  exit /b 1
)
call az.cmd account get-access-token --tenant "%TENANT%" --scope "%SCOPE%" --query accessToken --output tsv --only-show-errors 2>nul
if not errorlevel 1 exit /b 0
>&2 echo Gateway token unavailable. Starting Microsoft interactive sign-in.
call az.cmd login --tenant "%TENANT%" --scope "%SCOPE%" --allow-no-subscriptions --output none --only-show-errors <nul 1>&2
if errorlevel 1 exit /b 1
call az.cmd account get-access-token --tenant "%TENANT%" --scope "%SCOPE%" --query accessToken --output tsv --only-show-errors
exit /b %errorlevel%
