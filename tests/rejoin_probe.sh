#!/usr/bin/env bash
# 「回大厅后回局」的真链路端到端探针(三端:actor / 对手 / 第三人;详见 tests/rejoin_probe.gd 文件头)。
#
# 用法:  timeout 900 bash tests/rejoin_probe.sh
# 判据:  文本 `REJOIN PROBE: ALL-OK`(**不看退出码** —— 挂住时 --quit-after 到期仍 exit 0
#        且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
# 整跑量级:约 60~110 秒(c1 回局 ≈20s;c2 的观察窗 40s、c3 的拒绝窗口 40s 并行跑)。
#
# ⚠ **跑前先确认没有别的 Godot 占着 7777** —— 本探针**不占 7777**(自当大厅,池外端口 29300;
#   worker 起投也拨到池外 29350),可本机上可能跑着用户自己的服务端。**本脚本绝不杀 7777 的
#   属主**(与 royale_soak_probe.sh 的"发现占用就 kill_port 7777"刻意不同)。
#   真有一个大厅在 7777 上也不影响本探针:两边的端口集合不相交(29300/29350 vs 7777/7800~8299)。
set -u

# 引擎路径($GODOT,可用环境变量覆盖)+ cd 到仓库根 + kill_procs/kill_port
# shellcheck source=tests/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
LOG="tests/rejoin_probe.log"
PROBE_LOBBY_PORT=29300
PROBE_WORKER_PORT=29350

# ★ 判据**不带 `LISTENING`**:ENet 走 UDP、UDP 行没有状态列 ⇒ 带它是**结构性恒假**
#   (2026-09-27 实测),原先这句提示**从未打印过**。理由见 env.sh 的 lobby_alive。
if lobby_alive; then
  echo "[rejoin] 注意:7777 已被占用(大概是用户自己的服务端)。本探针不占 7777,**照跑不误、不会动它**。"
fi

# ★ 起跑前清**本探针自己那一段**的孤儿 worker(`OS.create_process` 起的孙进程,不属于本脚本
#   记下的 PID)。★ 区间只到 [29350, 29400):**绝不能**扫 [7800, 8300) —— 那是大厅的 worker 池,
#   而本探针的既有承诺是"不碰 7800~8299"(那会端掉用户正在跑的对局),见文件头。
kill_port_range "$PROBE_WORKER_PORT" 29400

echo "[rejoin] 起探针(大厅 $PROBE_LOBBY_PORT,worker 起投 $PROBE_WORKER_PORT;整跑约 60~110 秒)"
echo "[rejoin] 若长时间无输出:看 user://rejoin_probe_client_c{1,2,3}.godotlog(子进程 stdout 父进程看不到)"
"$GODOT" --headless --path . --quit-after 36000 res://tests/rejoin_probe.tscn 2>&1 | tee "$LOG"
# ★ 取**探针进程自己**的退出码,不是 tee 的(管道最后一环恒 0,照它写会打印一个结构性恒真的数)
RC=${PIPESTATUS[0]}

echo "[rejoin] 清理本探针自己的端口(兜底;正常路径探针已按 PID + 端口杀干净)"
kill_port "$PROBE_LOBBY_PORT"
kill_port "$PROBE_WORKER_PORT"
# ★ 只杀单个端口不够:worker 的端口是 `pick_port()` 发出来的那一个(同一跑里通常等于起投点,
#   但不是同一个概念 —— 见 tests/rejoin_probe.gd 文件头)。区间仍**不含** 7800~8299。
kill_port_range "$PROBE_WORKER_PORT" 29400

echo
if grep -q "REJOIN PROBE: ALL-OK" "$LOG"; then
  echo "[rejoin] PASS —— 读数见 $LOG"
  exit 0
fi
echo "[rejoin] FAIL(退出码 $RC)—— 见 $LOG"
grep -nE "SCRIPT ERROR|Parse Error|FAIL|✗" "$LOG" | head -30
echo "[rejoin] 失败时的第一手材料:每端的引擎日志(user://rejoin_probe_client_cN.godotlog)"
exit 1
