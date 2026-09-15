#!/usr/bin/env bash
# 僵尸房间清理——源码级结构检查。通过 = SMOKE_ROOM_SWEEP OK 退出 0。用户自跑。
set -u
# shellcheck source=tests/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
LOG="tests/room_sweep_smoke.log"
"$GODOT" --headless --path . -s res://tests/room_sweep_smoke.gd 2>&1 | tee "$LOG"
if grep -q "SMOKE_ROOM_SWEEP OK" "$LOG"; then
  echo "[room_sweep] PASS"
  exit 0
else
  echo "[room_sweep] FAIL —— 见 $LOG"
  exit 1
fi
