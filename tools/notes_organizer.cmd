@echo off
rem Organize the inbox (docs\Temp.txt) into docs\DevelopHistoryAndPlan.xlsx
rem Double-click to run. Extra arguments are passed through, e.g. --dry-run
rem The console is switched to UTF-8 (65001) and Python is forced to match, so the
rem Chinese output cannot end up as UTF-8 bytes rendered by a GBK console.
rem Waiting for a keypress is done inside the Python script - cmd's own pause prompt
rem is localised in the console codepage and would mix encodings.
setlocal
chcp 65001 >nul
set PYTHONUTF8=1
cd /d "%~dp0.."
python "%~dp0notes_organizer.py" %*
