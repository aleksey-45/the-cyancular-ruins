@echo off
rem 干员卡/武器卡编辑器 双击启动器(DevTools,仅 KH-char-weap 分支)。
rem 双击本文件 = 直接打开编辑器 GUI 窗口,不走游戏主菜单。
rem CRLF + chcp 65001(与 start_server.bat 同惯例);cd /d 按本文件所在目录定位项目,
rem 无论从哪里双击/调用都成立;文件不存在(切了分支)时明确报错,不会闪退。
chcp 65001 >nul
cd /d "%~dp0"
if not exist "DevTools\card_editor.tscn" (
  echo [错误] 当前目录找不到 DevTools\card_editor.tscn:
  echo 本工具只存在于 KH-char-weap 分支,请先执行 git checkout KH-char-weap 再双击本启动器。
  pause
  exit /b 1
)
echo 正在启动 干员卡/武器卡 编辑器...
start "" "C:\Godot\Godot_v4.7.1-stable_win64.exe" --path "%~dp0" res://DevTools/card_editor.tscn
