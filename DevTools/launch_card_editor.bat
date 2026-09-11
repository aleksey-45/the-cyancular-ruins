@echo off
rem Card editor (DevTools) launcher. ASCII-only + CRLF:
rem LF/UTF-8 batch gets mis-parsed by cmd and the window flashes away.
rem Lives in DevTools/; cd to the repo root so --path and the branch guard work.
cd /d "%~dp0.."
for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set BRANCH=%%b
if not exist "DevTools\card_editor.tscn" (
	echo [ERROR] DevTools\card_editor.tscn not found on branch %BRANCH%.
	echo Card editor is missing here - check out a DevTools-enabled branch.
	pause
	exit /b 1
)
echo Starting card editor...
echo The Godot window titled "The Cyancular Ruins (DEBUG)" IS the editor.
echo Close that window (or this console) to quit.
"C:\Godot\Godot_v4.7.1-stable_win64_console.exe" --path "%~dp0.." res://DevTools/card_editor.tscn
echo.
echo Card editor closed.
pause
