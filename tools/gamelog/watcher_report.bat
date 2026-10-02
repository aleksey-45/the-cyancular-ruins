@echo off
rem Print archived sessions + crash history (last 20 runs / 30 days). ASCII-only + CRLF.
cd /d "%~dp0..\.."
python tools\crashlog_capture.py report --last 20
pause
