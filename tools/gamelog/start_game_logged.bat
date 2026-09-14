@echo off
rem Logged game launcher: wraps the newest game exe (or Godot project run) and
rem captures a full session report into gamelogs\. ASCII-only + CRLF.
rem Drag an exe onto this file to record that specific build.
cd /d "%~dp0..\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\gamelog\capture_session.ps1" -Target game %*
pause
