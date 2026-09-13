@echo off
setlocal EnableExtensions DisableDelayedExpansion
if /I "%TOROUTE_INVOKED_BY_ROOT%"=="1" goto :main
if /I "%GITHUB_ACTIONS%"=="true" goto :main
call "%~dp0..\..\RUN_DOCKER_VALIDATION.cmd" %*
exit /b %ERRORLEVEL%

:main
cd /d "%~dp0..\.."
set "TOROUTE_REPO=%CD%"
set "TOROUTE_PS1=%~dp0Run-ToRoute-Docker-Validation.ps1"
set "TOROUTE_RESULTS=%TOROUTE_REPO%\validation-results"
set "TOROUTE_LAUNCH_LOG=%TOROUTE_RESULTS%\last-launch.log"

if not exist "%TOROUTE_RESULTS%" mkdir "%TOROUTE_RESULTS%" >nul 2>nul
>"%TOROUTE_LAUNCH_LOG%" echo ToRoute Docker validation launcher
>>"%TOROUTE_LAUNCH_LOG%" echo Started: %DATE% %TIME%
>>"%TOROUTE_LAUNCH_LOG%" echo Repository: %TOROUTE_REPO%
>>"%TOROUTE_LAUNCH_LOG%" echo Script: %TOROUTE_PS1%
>>"%TOROUTE_LAUNCH_LOG%" echo Arguments: %*

if not exist "%TOROUTE_PS1%" (
  echo ERROR: PowerShell validation script is missing.
  echo Expected: %TOROUTE_PS1%
  >>"%TOROUTE_LAUNCH_LOG%" echo ERROR: PowerShell validation script is missing.
  exit /b 90
)

set "TOROUTE_POWERSHELL="
where pwsh.exe >nul 2>nul
if not errorlevel 1 set "TOROUTE_POWERSHELL=pwsh.exe"
if not defined TOROUTE_POWERSHELL (
  where powershell.exe >nul 2>nul
  if not errorlevel 1 set "TOROUTE_POWERSHELL=powershell.exe"
)
if not defined TOROUTE_POWERSHELL (
  echo ERROR: PowerShell was not found.
  echo Windows PowerShell 5.1 or PowerShell 7 is required.
  >>"%TOROUTE_LAUNCH_LOG%" echo ERROR: PowerShell was not found.
  exit /b 91
)

echo PowerShell: %TOROUTE_POWERSHELL%
>>"%TOROUTE_LAUNCH_LOG%" echo PowerShell: %TOROUTE_POWERSHELL%
"%TOROUTE_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$tokens=$null;$errors=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($env:TOROUTE_PS1,[ref]$tokens,[ref]$errors);if($errors.Count -gt 0){foreach($item in $errors){[Console]::Error.WriteLine($item.ToString())};exit 92}" >>"%TOROUTE_LAUNCH_LOG%" 2>&1
if errorlevel 1 (
  echo ERROR: PowerShell script parsing failed.
  echo.
  type "%TOROUTE_LAUNCH_LOG%"
  exit /b 92
)

echo PowerShell parser preflight: PASS
>>"%TOROUTE_LAUNCH_LOG%" echo PowerShell parser preflight: PASS
if /I "%TOROUTE_PARSE_ONLY%"=="1" (
  echo Parse-only validation completed successfully.
  >>"%TOROUTE_LAUNCH_LOG%" echo Parse-only validation completed successfully.
  exit /b 0
)
>>"%TOROUTE_LAUNCH_LOG%" echo Main validation starting.

echo.
echo Starting Docker validation. Initial builds can take several minutes.
echo Live output follows below.
echo.
"%TOROUTE_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%TOROUTE_PS1%" %*
set "TOROUTE_RC=%ERRORLEVEL%"
>>"%TOROUTE_LAUNCH_LOG%" echo Main validation exit code: %TOROUTE_RC%
echo.
echo Main validation exit code: %TOROUTE_RC%
exit /b %TOROUTE_RC%
