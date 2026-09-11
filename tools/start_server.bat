@echo off
rem PvP lobby launcher (headless, listens on 7777). 大厅只做配对;每局配对完成会自动
rem 拉起一个对局 worker 子进程(独占 UDP 7800 起的端口)。不同对局 = 不同进程 = 隔离。
rem This bat is pure ASCII + CRLF so Windows cmd parses it in any locale.
rem It cd's to its own directory so --path . always resolves to the project,
rem regardless of how this window was opened.
rem Keep this window open = lobby running. Close it = stop everything (workers随对局结束退出)。
rem 启动前先杀掉旧残留:占 7777 的旧大厅,以及占 7800~7999 的僵尸 worker。
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   Killing old server on port 7777 (if any)...
echo ============================================
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /r ":7777"') do taskkill /F /PID %%p >nul 2>&1
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /r ":78[0-9][0-9] :79[0-9][0-9]"') do taskkill /F /PID %%p >nul 2>&1
timeout /t 1 /nobreak >nul
echo ============================================
echo   Starting PvP lobby on port 7777 (workers auto-spawn)...
echo   Wait for "server ready" output below, then keep this window open.
echo   Close this window = stop the lobby.
echo ============================================
"C:/Godot/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn
echo.
echo Server exited. If "listen failed" appeared above, port 7777 is in use.
pause
