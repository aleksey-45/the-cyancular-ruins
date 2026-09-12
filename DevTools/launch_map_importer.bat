@echo off
rem Map importer launcher (DevTools). ASCII-only + CRLF.
cd /d "%~dp0.."
if not exist "DevTools\map_importer.tscn" (
	echo [ERROR] DevTools\map_importer.tscn missing.
	pause
	exit /b 1
)
echo Opening map importer...
"C:\Godot\Godot_v4.7.1-stable_win64_console.exe" --path "%~dp0.." res://DevTools/map_importer.tscn
