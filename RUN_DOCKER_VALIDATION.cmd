@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
set "TOROUTE_RESULTS=%~dp0validation-results"
set "TOROUTE_BOOTSTRAP_LOG=%TOROUTE_RESULTS%\launcher-bootstrap.log"
if not exist "%TOROUTE_RESULTS%" mkdir "%TOROUTE_RESULTS%" >nul 2>nul

if /I "%TOROUTE_CONSOLE_SESSION%"=="1" goto :run
if /I "%GITHUB_ACTIONS%"=="true" goto :run

>"%TOROUTE_BOOTSTRAP_LOG%" echo ToRoute launcher bootstrap
>>"%TOROUTE_BOOTSTRAP_LOG%" echo Started: %DATE% %TIME%
>>"%TOROUTE_BOOTSTRAP_LOG%" echo Source: %~f0
>>"%TOROUTE_BOOTSTRAP_LOG%" echo Directory: %CD%
>>"%TOROUTE_BOOTSTRAP_LOG%" echo ComSpec: %ComSpec%
>>"%TOROUTE_BOOTSTRAP_LOG%" echo Starting persistent child console.
set "TOROUTE_CONSOLE_SESSION=1"
"%ComSpec%" /d /k call "%~f0" %*
set "TOROUTE_CHILD_RC=%ERRORLEVEL%"
>>"%TOROUTE_BOOTSTRAP_LOG%" echo Persistent child console closed with exit code: %TOROUTE_CHILD_RC%
exit /b %TOROUTE_CHILD_RC%

:run
title ToRoute Docker Validation
>>"%TOROUTE_BOOTSTRAP_LOG%" echo Console session: %TOROUTE_CONSOLE_SESSION%
>>"%TOROUTE_BOOTSTRAP_LOG%" echo Arguments: %*

echo ============================================================
echo  ToRoute Docker Validation
echo ============================================================
echo.
echo This console is persistent and will not close automatically.
echo Do not close it while Docker build or Tor bootstrap is running.
echo Bootstrap log:
echo   %TOROUTE_BOOTSTRAP_LOG%
echo.

if not exist "%~dp0tools\windows\Run-ToRoute-Docker-Validation.cmd" (
  echo ERROR: Validation files are missing.
  echo Extract the entire ZIP before running this file.
  echo Do not run the CMD directly inside the compressed ZIP view.
  echo Expected: %~dp0tools\windows\Run-ToRoute-Docker-Validation.cmd
  >>"%TOROUTE_BOOTSTRAP_LOG%" echo ERROR: Inner validation launcher is missing.
  set "TOROUTE_RC=90"
  goto :finish
)

set "TOROUTE_INVOKED_BY_ROOT=1"
call "%~dp0tools\windows\Run-ToRoute-Docker-Validation.cmd" %*
set "TOROUTE_RC=%ERRORLEVEL%"
set "TOROUTE_INVOKED_BY_ROOT="

:finish
if not defined TOROUTE_RC set "TOROUTE_RC=99"
>>"%TOROUTE_BOOTSTRAP_LOG%" echo Final exit code: %TOROUTE_RC%
echo.
echo ============================================================
if "%TOROUTE_RC%"=="0" (
  echo  RESULT: SUCCESS
) else (
  echo  RESULT: FAILED ^(exit code %TOROUTE_RC%^)
)
echo ============================================================
echo.
echo Launcher logs:
echo   %TOROUTE_BOOTSTRAP_LOG%
echo   %~dp0validation-results\last-launch.log
echo.
echo Detailed result ZIP, when created:
echo   %~dp0validation-results\ToRoute-Docker-Validation-*.zip
echo.
if not "%TOROUTE_RC%"=="0" (
  echo Please attach launcher-bootstrap.log, last-launch.log,
  echo. Keep raw logs and result ZIP private; share only a sanitized summary.
  echo.
)
if /I "%GITHUB_ACTIONS%"=="true" exit /b %TOROUTE_RC%

echo This console is intentionally kept open.
echo Press any key to return to an open command prompt.
pause >nul
exit /b %TOROUTE_RC%
