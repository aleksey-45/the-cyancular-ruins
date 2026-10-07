@echo off
rem 打印输出归档的运行会话与崩溃历史记录（最近 20 次运行记录）。
cd /d "%~dp0..\.."
python tools\crashlog_capture.py report --last 20
pause
