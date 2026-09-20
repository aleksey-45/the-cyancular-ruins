@echo off
rem serve.bat —— 起本地编辑器服务器并打开浏览器(规格 §4.9)。
rem ★ 编辑器只通过 HTTP 打开:file:// 下没有 Worker、没有同源、也读不到 maps/。
rem ★ 中文错误信息要靠 UTF-8 代码页,否则 cmd 里是乱码。
chcp 65001 >nul
cd /d "%~dp0"
echo [serve] 正在启动编辑器服务器(node editor_server.js)...
node editor_server.js
echo.
echo [serve] 服务器已退出(退出码 %ERRORLEVEL%)。
pause
