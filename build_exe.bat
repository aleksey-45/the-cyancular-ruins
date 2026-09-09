@echo off
rem One-click pack: exports BOTH the game client and the dedicated server exe.
rem - client exe  : "The Cyancular Ruins_<branch>_<timestamp>.exe"  (versioned name)
rem - server exe  : "Cyancular Ruins Server.exe" in repo root (fixed name, always
rem                 the newest; the client's in-game "start/restart local server"
rem                 button looks for exactly this file next to the client)
rem               + a versioned copy archived to the history folder
rem - old exes in repo root are moved to the history folder first.
rem ASCII-only + CRLF on purpose: cmd mis-parses UTF-8 batch content. The history
rem folder name is ASCII (exe_history) - no char-code trickery needed.
cd /d %~dp0

rem -- branch name / timestamp --
for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD') do set BRANCH=%%b
for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmm"') do set TS=%%t

rem -- history folder (sibling of repo root; ASCII name for mac/win) --
set HISTDIR=..xe_history

set OUT=The Cyancular Ruins_%BRANCH%_%TS%.exe
set SRV=Cyancular Ruins Server.exe
set SRVARC=Cyancular Ruins Server_%BRANCH%_%TS%.exe

echo Packing client: %OUT%
echo Packing server: %SRV% (archived as %SRVARC%)

rem -- archive old exes before exporting (root keeps only the newest pair) --
if not exist "%HISTDIR%" mkdir "%HISTDIR%"
for /f "delims=" %%f in ('dir /b /a-d "The Cyancular Ruins"*.exe 2^>nul') do (
	move /y "%%f" "%HISTDIR%\" >nul
)
for /f "delims=" %%f in ('dir /b /a-d "Cyancular Ruins Server"*.exe 2^>nul') do (
	move /y "%%f" "%HISTDIR%\" >nul
)

rem -- export client. Console Godot so cmd waits and errorlevel is reliable. --
"C:\Godot\Godot_v4.7.1-stable_win64_console.exe" --headless --path . --export-release "Windows Desktop" "%OUT%"
if errorlevel 1 (
	echo CLIENT pack failed! Common causes: the game is running / preset name mismatch.
	pause
	exit /b 1
)

rem -- export dedicated server (same branch, same content as the client) --
"C:\Godot\Godot_v4.7.1-stable_win64_console.exe" --headless --path . --export-release "Dedicated Server" "%SRV%"
if errorlevel 1 (
	echo SERVER pack failed! Common causes: server exe is running / preset name mismatch.
	pause
	exit /b 1
)

rem -- keep a versioned copy of the server in the history folder --
copy /y "%SRV%" "%HISTDIR%\%SRVARC%" >nul

echo.
echo Done.
echo   client: %OUT%
echo   server: %SRV%   (archived copy: %SRVARC%)
echo Old exes moved to: %HISTDIR%
echo Tip: in game, the lobby pages have a "start/restart local server" button.
pause
