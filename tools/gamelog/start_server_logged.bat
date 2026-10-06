@echo off
rem Logged server launcher: wraps the newest server exe (or Godot server scene)
rem and captures a full session report into gamelogs\. ASCII-only + CRLF.
cd /d "%~dp0..\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\gamelog\capture_session.ps1" -Target server %*
pause
