#!/usr/bin/env bash
# 「回大厅后回局」的真链路端到端探针(三端:actor / 对手 / 第三人;详见 tests/probe/rejoin_probe.gd 文件头)。
#
# 用法:  timeout 900 bash tests/probe/rejoin_probe.sh
# 判据:  文本 `REJOIN PROBE: ALL-OK`(**不看退出码** —— 挂住时 --quit-after 到期仍 exit 0
#        且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
# 整跑量级:约 60~110 秒(c1 回局 ≈20s;c2 的观察窗 40s、c3 的拒绝窗口 40s 并行跑)。
#
# 注意：本探针使用独立端口 29300，且对局与大厅在同进程单端口运行，不占用默认的 7777 端口。
# 本脚本不会清理 7777 端口上的进程，避免影响可能正在运行的其它服务端实例。
set -u

# 引擎路径($GODOT,可用环境变量覆盖)+ cd 到仓库根 + kill_procs/kill_port
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/probe/rejoin_probe.log"
PROBE_LOBBY_PORT=29300

# 检查默认 7777 端口状态；UDP 无 LISTENING 状态列，详见 env.sh 中的 lobby_alive 实现。
if lobby_alive; then
  echo "[rejoin] 注意: 7777 端口已被占用，本探针使用独立端口 29300，继续执行。"
fi

# 单进程单端口架构下，对局运行在当前探针进程内，无多余子进程或端口范围需要提前清理。

echo "[rejoin] 起探针(大厅 $PROBE_LOBBY_PORT,对局与它同端口;整跑约 60~110 秒)"
echo "[rejoin] 若长时间无输出:看 user://rejoin_probe_client_c{1,2,3}.godotlog(子进程 stdout 父进程看不到)"
"$GODOT" --headless --path . --quit-after 36000 res://tests/probe/rejoin_probe.tscn 2>&1 | tee "$LOG"
# 获取管道前段探针进程的退出码。
RC=${PIPESTATUS[0]}

echo "[rejoin] 清理本探针占用的端口"
kill_port "$PROBE_LOBBY_PORT"

echo
if grep -q "REJOIN PROBE: ALL-OK" "$LOG"; then
  echo "[rejoin] PASS —— 读数见 $LOG"
  exit 0
fi
echo "[rejoin] FAIL(退出码 $RC)—— 见 $LOG"
grep -nE "SCRIPT ERROR|Parse Error|FAIL|✗" "$LOG" | head -30
echo "[rejoin] 失败时的第一手材料:每端的引擎日志(user://rejoin_probe_client_cN.godotlog)"
exit 1
