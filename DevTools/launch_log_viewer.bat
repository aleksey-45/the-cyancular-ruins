@echo off
rem Log viewer (DevTools/gamelog) launcher. ASCII-only + CRLF.
cd /d "%~dp0.."
if not exist "DevTools\gamelog\log_viewer.tscn" (
  echo [ERROR] DevTools\gamelog\log_viewer.tscn not found on this branch.
  pause
  exit /b 1
)
set "GODOT="
if defined GODOT_EXE if exist "%GODOT_EXE%" set "GODOT=%GODOT_EXE%"
if not defined GODOT for %%P in ("C:\Godot\Godot_v4.7.1-stable_win64.exe" "D:\Godot\Godot_v4.7.1-stable_win64.exe" "C:\Program Files\Godot\Godot_v4.7.1-stable_win64.exe") do if not defined GODOT if exist %%P set "GODOT=%%~P"
if not defined GODOT for /f "delims=" %%P in ('where Godot_v4.7.1-stable_win64.exe 2^>nul') do if not defined GODOT set "GODOT=%%P"
if not defined GODOT (
  echo [ERROR] Godot not found. Set environment variable GODOT_EXE to your Godot exe.
  pause
  exit /b 1
)
start "" "%GODOT%" --path "%~dp0.." res://DevTools/gamelog/log_viewer.tscn
