#!/usr/bin/env bash
# 3v3 六人真链路端到端探针(阶段 1~阶段 5;详见 tests/probe/team_match_probe.gd 文件头)。
#
# 用法:  timeout 1800 bash tests/probe/team_match_probe.sh
# 判据:  文本 `TEAM MATCH PROBE: ALL-OK`(**不看退出码** —— 挂住时 --quit-after 到期仍 exit 0
#        且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
# 整跑量级:3~10 分钟(阶段 4 要打到 9 杀 —— 脚本机器人尽力交火 + 回退模式,是本探针最大的
#          时间不确定项;预算与安全网见 tests/probe/team_match_probe.gd 文件头「时间预算」)。
#
# ⚠ **跑前先确认没有别的 Godot 占着 7777** —— 本探针**不占 7777**(自当大厅,但用池外端口
#   29200;worker 也拨到池外 29250),可本机上可能跑着用户自己的服务端。**本脚本绝不杀 7777
#   的属主**(与 royale_soak_probe.sh 的"发现占用就 kill_port 7777"**刻意不同**:那条会把用户
#   正在跑服的对局一起端掉)。真有一个大厅在 7777 上也不影响本探针 —— 它既不 bind 7777、
#   也不碰 7800~8299 那个 worker 端口池,两者的端口集合不相交。
# ⚠ Windows 下 bash `kill` 杀不死 headless Godot,会留僵尸 —— 收尾一律 taskkill 按 PID
#   (探针进程自己按 PID 杀它启动过的全部子进程),本脚本再按**本探针自己的**两个端口保底处理。
set -u

# 引擎路径($GODOT,可用环境变量覆盖)+ cd 到仓库根 + kill_procs/kill_port
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/probe/team_match_probe.log"
PROBE_LOBBY_PORT=29200
PROBE_WORKER_PORT=29250

# - 判据**不带 `LISTENING`**:ENet 走 UDP、UDP 行没有状态列  ->  带它是**结构性恒假**
#   (2026-09-27 实测),原先这两行提示**从未打印过**。理由见 env.sh 的 lobby_alive。
if lobby_alive; then
  echo "[team] 注意:7777 已被占用(大概是用户自己的服务端)。本探针不占 7777、也不用 7800~8299,"
  echo "[team]       所以**照跑不误,且不会动它**;这里只是把这件事说出来。"
fi

# - 起跑前清**本探针自己那一段**的孤儿 worker(`OS.create_process` 起的孙进程,不属于本脚本
#   记下的 PID)。-  区间只到 [29250, 29400):**绝不能**扫 [7800, 8300) —— 那是大厅的 worker 池,
#   而本探针的既有承诺是"不碰 7800~8299"(那会端掉用户正在跑的对局),见文件头。
kill_port_range "$PROBE_WORKER_PORT" 29400

echo "[team] 起探针(大厅端口 $PROBE_LOBBY_PORT,worker 起投 $PROBE_WORKER_PORT;整跑 3~6 分钟)"
echo "[team] 若长时间无输出:看 user://team_match_probe_cN.godotlog(子进程 stdout 父进程看不到)"
"$GODOT" --headless --path . --quit-after 54000 res://tests/probe/team_match_probe.tscn 2>&1 | tee "$LOG"
# - 取**探针进程自己**的退出码,不是 `tee` 的:`RC=$?` 拿到的是管道最后一环(tee 恒 0),
#   于是 FAIL 分支会打印"退出码 0"这个**结构性永远为真**的数,把人引向"退出码没问题"。
RC=${PIPESTATUS[0]}

echo "[team] 清理本探针自己的两个端口(兜底;正常路径探针已按 PID 杀干净)"
kill_port "$PROBE_LOBBY_PORT"
kill_port "$PROBE_WORKER_PORT"
# - 只杀单个端口不够:worker 的端口是 `pick_port()` 发出来的那一个(同一跑里通常等于起投点,
#   但不是同一个概念)。区间仍**不含** 7800~8299(见文件头的既有承诺)。
kill_port_range "$PROBE_WORKER_PORT" 29400

echo
if grep -q "TEAM MATCH PROBE: ALL-OK" "$LOG"; then
  echo "[team] PASS —— 读数见 $LOG(以及 .superpowers/sdd/b-task-8-report.md 的复现段)"
  exit 0
fi
echo "[team] FAIL(退出码 $RC)—— 见 $LOG"
grep -nE "SCRIPT ERROR|Parse Error|FAIL|✗" "$LOG" | head -30
echo "[team] 失败时的第一手材料:每个客户端的引擎日志(user://team_match_probe_cN.godotlog)"
exit 1
