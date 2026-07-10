@echo off
REM =====================================================================
REM  ezFOV offline sanity test runner.
REM  Runs the pre-deploy smoke test from the repo root, which is required
REM  for the test's relative module paths (./ezFOV/Scripts/...) to resolve.
REM
REM  Usage:
REM    run-tests.cmd          -> uses "lua" from PATH
REM    run-tests.cmd lua54    -> uses a specific interpreter (e.g. lua5.4)
REM =====================================================================
setlocal
cd /d "%~dp0"

set "LUA=%~1"
if "%LUA%"=="" set "LUA=lua"

"%LUA%" ezFOV\Scripts\tests\sanity_test.lua
set "EXITCODE=%ERRORLEVEL%"

REM Pause only when double-clicked (launched in its own window) so that runs
REM from a terminal or CI don't block waiting for a keypress.
echo %cmdcmdline% | find /i "%~nx0" >nul && pause

exit /b %EXITCODE%
