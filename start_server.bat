@echo off
rem PvP lobby launcher (headless, listens on 7777). 大厅只做配对;每局配对完成会自动
rem 拉起一个对局 worker 子进程(独占 UDP 7800 起的端口)。不同对局 = 不同进程 = 隔离。
rem This bat keeps CRLF (pinned by .gitattributes).
rem NOTE: the rem comments below contain UTF-8 Chinese, so they only display right after
rem the chcp 65001 further down; the *commands* themselves stay ASCII.
rem It cd's to its own directory so --path . always resolves to the project,
rem regardless of how this window was opened.
rem Keep this window open = lobby running. Close it = stop everything (workers随对局结束退出)。
rem 启动前先杀掉旧残留:占 7777 的旧大厅,以及占 7800~8299 的僵尸 worker(端口池 = 7800 起 500 个)。
rem ★ 2026-10-04 已修(本批):下面那条 findstr 原先只覆盖 :78xx 与 :79xx,杀不到 8000~8299 的 worker
rem   (需该大厅累计 spawn 过 200 次以上才会用到那段,而分配器是"唯一递增"的 ⇒ 长跑必到)。
rem   现模式 = `:78[0-9][0-9] :79[0-9][0-9] :8[0-2][0-9][0-9]` ⇒ 正好覆盖整个池 [7800,8300)。
rem   ★ 命中差实测(真实 netstat -ano -p UDP,临时占 8000 / 7801 / 8300):旧模式漏掉 :8000,新模式命中。
chcp 65001 >nul
cd /d "%~dp0"
rem 引擎路径可用环境变量 GODOT 覆盖(换机器/换引擎版本只需设一次,不必改这些脚本)
if not defined GODOT set "GODOT=D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64_console.exe"
rem ★ 名族判定里的第 4 条 =「**该 exe 自己的名字**」。发布版 exe 被改过名(如 `RoF_server.exe`)时,
rem   旧实例的进程名**就是这个名字** ⇒ 光靠 `Godot*`/`Cyancular*` 前缀认不出来、清不掉,
rem   于是又 bind 失败闪退(Review Focus 5 点名的失败模式)。这里从 %GODOT% 取 base name 当第 4 条。
for %%f in ("%GODOT%") do set "PH_SELF_EXE=%%~nf"
echo ============================================
echo   Killing old server on port 7777 (if any)...
echo ============================================
rem ★ 2026-10-04 修(审计 §2.1):原先这两条清理行都是**死行** —— `netstat -ano` 的 UDP 行只有
rem   4 列(`UDP  0.0.0.0:7777  *:*  <PID>`,实测),第 5 列只在 TCP 行上才是 PID;所以
rem   `tokens=5` 一个 PID 都取不到,「启动前杀旧残留」从来**没生效过**(dry-run 实证:零输出)。
rem   改成 `tokens=4` 才有用。同时加 `-p UDP` 把 TCP 行挡掉:TCP 行第 4 列是 State
rem   (如 LISTENING)而不是 PID,留着会被当成"一个读不出名字的 PID"喂进下面的护栏。
rem ★ 同时加**保守护栏**(取向:**证不出是"我们这一族"的,就不杀**):按端口取到 PID 后先查
rem   属主进程名,只有 `Godot*` / `Cyancular*` / `The Cyancular*`(= 本项目自己的进程与
rem   它的发布版 exe 名)**或 == `%PH_SELF_EXE%`(本脚本要拉起的那个 exe 的名字)** 才 taskkill;
rem   明显是别的程序、或名字读不出来(权限/竞态)⇒ 打警告、**不杀**。子过程见文件末尾
rem   `:reap_port_holder`。
rem   ★ 动机没修坏(见 core/net/proc_util.gd:5-9):旧实例**就是我们这一类** ⇒ 照样被清掉,
rem     「占着 7777 ⇒ 新实例 bind 失败闪退」那个坑仍然堵着。
for /f "tokens=4" %%p in ('netstat -ano -p UDP ^| findstr /r ":7777"') do call :reap_port_holder %%p
for /f "tokens=4" %%p in ('netstat -ano -p UDP ^| findstr /r ":78[0-9][0-9] :79[0-9][0-9] :8[0-2][0-9][0-9]"') do call :reap_port_holder %%p
rem ★ 收口:清理跑完**再查一次端口**。还查得到 ⇒ 占主不是我们这一族(或名字读不出来)⇒
rem   **不硬起**大厅 —— 硬起只会 bind 失败瞬间退出(= proc_util.gd:5-9 记的那个坑),不如把话
rem   说明白。最多等 3 轮、每轮 1 秒:taskkill 之后内核回收 socket 要一点时间,不等就查会把
rem   "刚杀掉、还在收尾"误判成"清不掉",那就**又把动机修坏了**。
rem   ★ 睡眠用 `ping -n 2 127.0.0.1`(= 约 1 秒)而不是 `timeout /t 1`:后者会**从 Git Bash 起
rem     .bat 时被 MSYS 的 /usr/bin/timeout 盖掉**(实测报 "invalid time interval '/t'")⇒ 等待
rem     变成 0 秒、三轮检查在同一瞬间跑完 ⇒ 又回到误判。ping 只在 System32,哪个入口都稳。
set "PH_TRIES=3"
:wait_7777
ping -n 2 127.0.0.1 >nul
set "PH_STILL_PID="
for /f "tokens=4" %%p in ('netstat -ano -p UDP ^| findstr /r ":7777"') do set "PH_STILL_PID=%%p"
if not defined PH_STILL_PID goto :launch_lobby
set /a PH_TRIES-=1
if %PH_TRIES% gtr 0 goto :wait_7777
goto :port_blocked

:launch_lobby
echo ============================================
echo   Starting PvP lobby on port 7777 (workers auto-spawn)...
echo   Wait for "server ready" output below, then keep this window open.
echo   Close this window = stop the lobby.
echo ============================================
"%GODOT%" --headless --path . res://server/server_main.tscn
echo.
echo Server exited. If "listen failed" appeared above, port 7777 is in use.
pause
exit /b 0

rem ══ 端口被**别人**占着:警告 + 不硬起(★ 绝不能走到下面的子过程里)══
:port_blocked
echo ============================================
echo   [!] Port 7777 is still held after cleanup -- lobby NOT started.
echo   [!] The holder was not recognised as this project's Godot/lobby process,
echo       so it was NOT killed (kill first, ask later is what we refuse to do).
set "PH_NAME="
for /f "delims=" %%n in ('powershell.exe -NoProfile -Command "(Get-Process -Id %PH_STILL_PID% -ErrorAction SilentlyContinue).ProcessName" 2^>nul') do set "PH_NAME=%%n"
if defined PH_NAME echo   [!] Holder: PID %PH_STILL_PID% = %PH_NAME%
if not defined PH_NAME echo   [!] Holder: PID %PH_STILL_PID% -- process name unreadable
echo   [!] Free UDP port 7777 by hand, then run this script again.
echo ============================================
pause
exit /b 1

rem ══ 子过程:清理**端口属主**(★ 保守护栏:证不出是"我们这一族"的,就不杀)══
rem %1 = 端口属主 PID(由上面两条 for /f 取 netstat 第 4 列得来)。
rem 名族名单与 core/net/proc_util.gd 的 kill_udp_port 是**同一取向**(Godot* / Cyancular* /
rem The Cyancular* + "该 exe 自己的名字" %PH_SELF_EXE%)—— 两处各一份(bat 没法 import
rem GDScript),改一处必须同时改另一处。
rem 三条分支:① 是我们这一族 → taskkill;② 明显是别的程序 → 警告 + 不杀;
rem          ③ 名字读不出来(权限/竞态/进程已退出) → 警告 + 不杀(保守取向:**不默认杀**)。
:reap_port_holder
setlocal
set "PH_PID=%~1"
set "PH_NAME="
for /f "delims=" %%n in ('powershell.exe -NoProfile -Command "(Get-Process -Id %PH_PID% -ErrorAction SilentlyContinue).ProcessName" 2^>nul') do set "PH_NAME=%%n"
if not defined PH_NAME goto :reap_unknown
if /i "%PH_NAME%"=="%PH_SELF_EXE%" goto :reap_kill
if /i "%PH_NAME:~0,5%"=="Godot" goto :reap_kill
if /i "%PH_NAME:~0,9%"=="Cyancular" goto :reap_kill
if /i "%PH_NAME:~0,13%"=="The Cyancular" goto :reap_kill
echo   [!] PID %PH_PID% = %PH_NAME% -- NOT this project's process, NOT killing it.
endlocal & exit /b 0
:reap_unknown
echo   [!] PID %PH_PID% -- process name unreadable, NOT killing it.
endlocal & exit /b 0
:reap_kill
taskkill /F /PID %PH_PID% >nul 2>&1
endlocal & exit /b 0
