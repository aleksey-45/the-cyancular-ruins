@echo off
rem 带日志捕获的游戏启动脚本：包装最新客户端可执行文件运行，并将完整运行会话报告归档至 gamelogs/ 目录。
rem 支持拖拽特定可执行文件到此脚本上运行并记录对应版本日志。
cd /d "%~dp0..\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\gamelog\capture_session.ps1" -Target game %*
pause
