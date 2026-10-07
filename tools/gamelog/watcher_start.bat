@echo off
rem 后台日志监控脚本：监控游戏会话并在异常退出时归档日志（归档 Godot 运行日志与 Windows 崩溃事件）。
rem 需要 Python 3 环境。
cd /d "%~dp0..\.."
python tools\crashlog_capture.py start
pause
