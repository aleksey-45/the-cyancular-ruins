@echo off
rem Card editor (DevTools) launcher. ASCII-only + CRLF (cmd mis-parses UTF-8
rem batch content, which previously executed fragments of comments as commands).
rem Launch = same as running Godot GUI exe directly with the card_editor scene:
rem   "C:\Godot\Godot_v4.7.1-stable_win64.exe" --path <repo> res://DevTools/card_editor.tscn
rem A window titled "The Cyancular Ruins (DEBUG)" opens (that is the card editor,
rem not the game). Card editor only exists on branch KH-char-weap.
cd /d "%~dp0"
for /f %%b in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set BRANCH=%%b
if not exist "DevTools\card_editor.tscn" (
  echo [ERROR] DevTools\card_editor.tscn not found on branch %BRANCH%.
  echo Card editor only exists on branch KH-char-weap.
  echo Run: git checkout KH-char-weap
  pause
  exit /b 1
)
start "" "C:\Godot\Godot_v4.7.1-stable_win64.exe" --path "%~dp0" res://DevTools/card_editor.tscn
