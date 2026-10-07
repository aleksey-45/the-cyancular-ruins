#!/usr/bin/env bash
# 失效房间清理逻辑冒烟测试：源码级结构校验。判定标准：输出 SMOKE_ROOM_SWEEP OK 且退出码为 0。
set -u
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/smoke/room_sweep_smoke.log"
"$GODOT" --headless --path . -s res://tests/smoke/room_sweep_smoke.gd 2>&1 | tee "$LOG"
if grep -q "SMOKE_ROOM_SWEEP OK" "$LOG"; then
  echo "[room_sweep] PASS"
  exit 0
else
  echo "[room_sweep] FAIL —— 见 $LOG"
  exit 1
fi
