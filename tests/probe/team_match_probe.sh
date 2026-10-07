#!/usr/bin/env bash
# 3v3 六人真链路端到端探针(阶段 1~阶段 5;详见 tests/probe/team_match_probe.gd 文件头)。
#
# 用法:  timeout 1800 bash tests/probe/team_match_probe.sh
# 判据:  文本 `TEAM MATCH PROBE: ALL-OK`(**不看退出码** —— 挂住时 --quit-after 到期仍 exit 0
#        且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
# 整跑量级:3~10 分钟(阶段 4 要打到 9 杀 —— 脚本机器人尽力交火 + 回退模式,是本探针最大的
#          时间不确定项;预算与安全网见 tests/probe/team_match_probe.gd 文件头「时间预算」)。
#
# 注意：本探针使用独立端口 29200，且对局与大厅在同进程单端口运行，不占用默认的 7777 端口。
# 本脚本不会清理 7777 端口上的进程，避免影响可能正在运行的其它服务端实例。
# 探针进程按 PID 清理启动的客户端子进程，脚本退出时清理大厅端口。
set -u

# 引擎路径($GODOT,可用环境变量覆盖)+ cd 到仓库根 + kill_procs/kill_port
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/probe/team_match_probe.log"
PROBE_LOBBY_PORT=29200

# 检查默认 7777 端口状态；UDP 无 LISTENING 状态列，详见 env.sh 中的 lobby_alive 实现。
if lobby_alive; then
  echo "[team] 注意: 7777 端口已被占用，本探针使用独立端口 29200，继续执行。"
fi

# 单进程单端口架构下，对局运行在当前探针进程内，无多余子进程或端口范围需要提前清理。

echo "[team] 起探针(大厅端口 $PROBE_LOBBY_PORT,对局与它同端口;整跑 3~6 分钟)"
echo "[team] 若长时间无输出:看 user://team_match_probe_cN.godotlog(子进程 stdout 父进程看不到)"
"$GODOT" --headless --path . --quit-after 54000 res://tests/probe/team_match_probe.tscn 2>&1 | tee "$LOG"
# 获取管道前段探针进程的退出码。
RC=${PIPESTATUS[0]}

echo "[team] 清理本探针占用的端口"
kill_port "$PROBE_LOBBY_PORT"

echo
if grep -q "TEAM MATCH PROBE: ALL-OK" "$LOG"; then
  echo "[team] PASS —— 读数见 $LOG(以及 .superpowers/sdd/b-task-8-report.md 的复现段)"
  exit 0
fi
echo "[team] FAIL(退出码 $RC)—— 见 $LOG"
grep -nE "SCRIPT ERROR|Parse Error|FAIL|✗" "$LOG" | head -30
echo "[team] 失败时的第一手材料:每个客户端的引擎日志(user://team_match_probe_cN.godotlog)"
exit 1
