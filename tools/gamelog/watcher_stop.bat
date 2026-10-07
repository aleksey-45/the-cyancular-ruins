@echo off
rem 停止后台日志监控进程。
cd /d "%~dp0..\.."
python tools\crashlog_capture.py stop
pause
