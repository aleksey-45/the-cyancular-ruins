@echo off
rem PvP lobby launcher (headless, listens on 7777). 大厅只做配对;每局配对完成会自动
rem 拉起一个对局 worker 子进程(独占 UDP 7800 起的端口)。不同对局 = 不同进程 = 隔离。
rem This bat is pure ASCII + CRLF so Windows cmd parses it in any locale.
rem It cd's to its own directory so --path . always resolves to the project,
rem regardless of how this window was opened.
rem Keep this window open = lobby running. Close it = stop everything (workers随对局结束退出)。
rem 启动前先杀掉旧残留:占 7777 的旧大厅,以及占 7800~8299 的僵尸 worker(端口池 = 7800 起 500 个)。
rem ⚠ 已知缺口:下面那条 findstr 只覆盖 :78xx 与 :79xx,杀不到 8000~8299 的 worker(需该大厅
rem   累计 spawn 过 200 次以上才会用到那段)。待修:把模式扩到 :8[0-2][0-9][0-9]。
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
rem 引擎路径可用环境变量 GODOT 覆盖(换机器/换引擎版本只需设一次,不必改这些脚本)
if not defined GODOT set "GODOT=D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64_console.exe"
"%GODOT%" --headless --path . res://server/server_main.tscn
echo.
echo Server exited. If "listen failed" appeared above, port 7777 is in use.
pause
