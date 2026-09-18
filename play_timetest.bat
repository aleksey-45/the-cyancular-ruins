@echo off
rem Play the time-map demo (timetest.cyrm, 25-second timeline). ASCII-only + CRLF.
rem Godot resolution follows repo convention: GODOT_EXE env -> common paths -> PATH.
cd /d "%~dp0"

set "GODOT="
if defined GODOT_EXE if exist "%GODOT_EXE%" set "GODOT=%GODOT_EXE%"
if not defined GODOT for %%P in ("C:\Godot\Godot_v4.7.1-stable_win64.exe" "D:\Godot\Godot_v4.7.1-stable_win64.exe" "C:\Program Files\Godot\Godot_v4.7.1-stable_win64.exe") do if not defined GODOT if exist %%P set "GODOT=%%~P"
if not defined GODOT for /f "delims=" %%P in ('where Godot_v4.7.1-stable_win64.exe 2^>nul') do if not defined GODOT set "GODOT=%%~P"
if not defined GODOT (
  echo [ERROR] Godot exe not found. Set GODOT_EXE.
  pause
  exit /b 1
)

echo Starting The Cyancular Ruins - time-map demo...
echo.
echo IN GAME: "Single Player" - map dropdown - select "timetest.cyrm" - Start.
echo Watch the countdown top-center:
echo   T-15  middle corridor COLLAPSES (path blocked)
echo   T-10  right secret room wall BLASTS OPEN
echo.
"%GODOT%" --path "%~dp0"
