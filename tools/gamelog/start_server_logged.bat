@echo off
rem 带日志捕获的服务端启动脚本：包装最新服务端可执行文件（或服务端场景）运行，并将完整运行会话报告归档至 gamelogs/ 目录。
cd /d "%~dp0..\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\gamelog\capture_session.ps1" -Target server %*
pause
