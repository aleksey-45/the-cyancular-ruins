@echo off
rem Stop the background watcher. ASCII-only + CRLF.
cd /d "%~dp0..\.."
python tools\crashlog_capture.py stop
pause
