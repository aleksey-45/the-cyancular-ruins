@echo off
rem PvP dedicated server launcher (headless, listens on port 7777).
rem This bat is pure ASCII + CRLF so Windows cmd parses it in any locale.
rem It cd's to its own directory so --path . always resolves to the project,
rem regardless of how this window was opened.
rem Keep this window open = server running. Close it = stop the server.
rem If you see "server: listen failed" (error 20), port 7777 is occupied -
rem kill the old server process first (see docs/pvp-networking.md).
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   Starting PvP server on port 7777...
echo   Wait for "server ready" output below, then keep this window open.
echo   Close this window = stop the server.
echo ============================================
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn
echo.
echo Server exited. If "listen failed" appeared above, port 7777 is in use.
pause
