@echo off
rem Asset editor (DevTools/editor) launcher. ASCII-only + CRLF.
rem Double-click = open DevTools/editor/asset_editor.tscn GUI (weapons/operators/props,
rem art upload slots, prompt -> local Claude Code). Editor branch only.
cd /d "%~dp0.."
if not exist "DevTools\editor\asset_editor.tscn" (
  echo [ERROR] DevTools\editor\asset_editor.tscn not found on this branch.
  echo The asset editor only exists on the editor branch.
  pause
  exit /b 1
)
start "" "C:\Godot\Godot_v4.7.1-stable_win64.exe" --path "%~dp0.." res://DevTools/editor/asset_editor.tscn
