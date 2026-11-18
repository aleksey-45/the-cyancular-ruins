@echo off
rem The Node.js server opens the map editor in the default browser.
rem Selects UTF-8 before the server prints its startup messages.
chcp 65001 >nul
cd /d "%~dp0"
echo [serve] starting editor server (node editor_server.js) ...
node editor_server.js
echo.
echo [serve] server exited (exit code %ERRORLEVEL%).
pause
