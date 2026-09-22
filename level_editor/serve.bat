@echo off
rem serve.bat -- start the local editor server and open the browser (spec 4.9).
rem The editor is served over HTTP only: under file:// there is no Worker,
rem no same-origin, and maps/ cannot be read.
rem
rem ASCII-ONLY ON PURPOSE: cmd.exe parses a batch file byte by byte in the
rem console code page, so a UTF-8 line containing Chinese loses alignment and
rem fragments of it get executed as commands (symptom: a burst of
rem "'xxx' is not recognized as an internal or external command" and, when the
rem flow breaks, the window closes instantly). Keep this file ASCII-only.
rem chcp 65001 below is for NODE's own output (the server prints Chinese).
chcp 65001 >nul
cd /d "%~dp0"
echo [serve] starting editor server (node editor_server.js) ...
node editor_server.js
echo.
echo [serve] server exited (exit code %ERRORLEVEL%).
pause
