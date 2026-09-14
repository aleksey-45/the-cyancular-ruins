@echo off
rem Log viewer (DevTools/gamelog) launcher. ASCII-only + CRLF.
cd /d "%~dp0.."
if not exist "DevTools\gamelog\log_viewer.tscn" (
  echo [ERROR] DevTools\gamelog\log_viewer.tscn not found on this branch.
  pause
  exit /b 1
)
start "" "C:\Godot\Godot_v4.7.1-stable_win64.exe" --path "%~dp0.." res://DevTools/gamelog/log_viewer.tscn
