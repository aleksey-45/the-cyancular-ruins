@echo off
rem Background watcher: captures sessions even when the game is launched by
rem double-clicking the exe directly (archives Godot logs + Windows crash events).
rem Requires Python 3. ASCII-only + CRLF.
cd /d "%~dp0..\.."
python tools\crashlog_capture.py start
pause
