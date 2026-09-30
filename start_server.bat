@echo off
rem PvP server launcher (headless, listens on 7777). ★ 单进程、单端口:大厅与对局同进程
rem (配合完成后直接建 MatchSession 节点),不拉任何子进程、也不转连。
rem This bat is pure ASCII + CRLF so Windows cmd parses it in any locale.
rem It cd's to its own directory so --path . always resolves to the project,
rem regardless of how this window was opened.
rem Keep this window open = server running. Close it = stop it.
rem ★ 不传 --port 时回落 NetBus.DEFAULT_PORT(7777)。正常玩法里端口由**客户端**挑
rem   (core/net/local_server.gd,20000~59999 随机 + 探活重试),这个 bat 只服务"手跑一台
rem   固定端口的大厅"那种开发/联调场景。
rem 启动前先杀掉旧残留:占 7777 的旧服务端。★ 只杀这一个端口 —— 客户端自建的那些服务端
rem   在别的端口上跑着,按端口区间扫会把它们一起端掉。
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   Killing old server on port 7777 (if any)...
echo ============================================
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /r ":7777"') do taskkill /F /PID %%p >nul 2>&1
timeout /t 1 /nobreak >nul
echo ============================================
echo   Starting PvP server on port 7777...
echo   Wait for "server ready" output below, then keep this window open.
echo   Close this window = stop the server.
echo ============================================
rem 引擎路径可用环境变量 GODOT 覆盖(换机器/换引擎版本只需设一次,不必改这些脚本)
if not defined GODOT set "GODOT=D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64_console.exe"
"%GODOT%" --headless --path . res://server/server_main.tscn
echo.
echo Server exited. If "listen failed" appeared above, port 7777 is in use.
pause
