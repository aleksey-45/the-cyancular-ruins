#!/usr/bin/env bash
# 1v1 Bot 真链路探针:2 个真实客户端(真 mp_lobby → 真 pvp_game),由 bot_watcher 驱动。
# 判据:文本 `BOT 1V1 PROBE: ALL-OK`(**不看退出码** —— 挂住时 --quit-after 到期仍 exit 0)。
# 用法:timeout 600 bash tests/probe/bot_1v1_probe.sh
# ⚠ 本支**不占 7777**、不用 7800~8299;端口 29400(大厅)/ 29450 起(worker)是本支自己的。
set -u

source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/probe/bot_1v1_probe.log"
PROBE_LOBBY_PORT=29400

if lobby_alive; then
  echo "[bot] 注意:7777 上有活大厅(可能有人在打)。本支不占 7777、不用 worker 池,照跑不误。"
fi

# 起跑前清本支自己的孤儿 worker(OS.create_process 起的孙进程)。
kill_port_range 29450 29550

"$GODOT" --headless --path . --quit-after 36000 res://tests/probe/bot_1v1_probe.tscn 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

kill_port "$PROBE_LOBBY_PORT"
kill_port_range 29450 29550
kill_clients_by_cmdline 'bot_1v1_probe.tscn'

echo
if grep -q "BOT 1V1 PROBE: ALL-OK" "$LOG"; then
  echo "[bot] PASS —— 读数见 $LOG"
  exit 0
fi
echo "[bot] FAIL(退出码 $RC)—— 见 $LOG"
grep -nE "SCRIPT ERROR|Parse Error|FAIL" "$LOG" | head -30
