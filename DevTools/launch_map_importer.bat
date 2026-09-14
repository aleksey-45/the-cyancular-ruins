@echo off
rem Map importer launcher (DevTools). ASCII-only + CRLF.
cd /d "%~dp0.."
if not exist "DevTools\map_importer.tscn" (
	echo [ERROR] DevTools\map_importer.tscn missing.
	pause
	exit /b 1
)
echo Opening map importer...
set "GODOT="
if defined GODOT_EXE if exist "%GODOT_EXE%" set "GODOT=%GODOT_EXE%"
if not defined GODOT for %%P in ("C:\Godot\Godot_v4.7.1-stable_win64_console.exe" "D:\Godot\Godot_v4.7.1-stable_win64_console.exe" "C:\Program Files\Godot\Godot_v4.7.1-stable_win64_console.exe") do if not defined GODOT if exist %%P set "GODOT=%%~P"
if not defined GODOT for /f "delims=" %%P in ('where Godot_v4.7.1-stable_win64_console.exe 2^>nul') do if not defined GODOT set "GODOT=%%P"
if not defined GODOT (
	echo [ERROR] Godot not found. Set environment variable GODOT_EXE to your Godot console exe.
	pause
	exit /b 1
)
"%GODOT%" --path "%~dp0.." res://DevTools/map_importer.tscn
