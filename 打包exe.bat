@echo off
rem 一键打包:文件名自动带分支名与时间码。用法:双击,或在仓库根执行 打包exe.bat
cd /d %~dp0

rem ── 取当前分支名 ──
for /f %%b in ('git rev-parse --abbrev-ref HEAD') do set BRANCH=%%b

rem ── 取时间码(yyyyMMdd_HHmm)──
for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmm"') do set TS=%%t

set OUT="The Cyancular Ruins_%BRANCH%_%TS%.exe"
echo 正在打包: %OUT%

rem ── 导出(导出前请关闭正在运行的游戏,否则 exe 写入失败)──
"C:\Godot\Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" %OUT%
if errorlevel 1 (
	echo 打包失败!常见原因:游戏正在运行占用 exe / 导出预设名不对。
	pause
	exit /b 1
)

echo.
echo 打包完成: %OUT%
echo 提示:进游戏后「版本信息」面板可核对分支名与提交序号。
pause
