@echo off
setlocal enabledelayedexpansion
rem repo root derived from this bat's own dir: keeps this file ASCII-only
set "REPO=%~dp0..\..\.."
for %%i in ("%REPO%") do set "REPO=%%~fi"
cd /d "%REPO%"
set "PROMPT=%REPO%\DevTools\editor\.prompts\prop_pr_attraction_154238.md"
set "LOGF=%REPO%\DevTools\editor\.logs\prop_pr_attraction_154238.log"
> "%LOGF%" echo __AGENT_STARTED__
claude -p --permission-mode acceptEdits --output-format text --verbose < "%PROMPT%" >> "%LOGF%" 2>&1
>> "%LOGF%" echo __AGENT_EXIT_!ERRORLEVEL!__
