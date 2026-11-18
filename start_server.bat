@echo off
rem PvP 独立服务端启动脚本（Headless 模式，默认监听端口 7777）。
rem 单进程、单端口架构：大厅与对局在同一进程内运行，无需创建额外 Worker 子进程。
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   Starting PvP server on port 7777...
echo   Wait for "server ready" output below, then keep this window open.
echo   Close this window = stop the server.
echo ============================================
if not defined GODOT set "GODOT=godot"
"%GODOT%" --headless --path . res://server/server_main.tscn
echo.
echo Server exited with code %ERRORLEVEL%.
pause
