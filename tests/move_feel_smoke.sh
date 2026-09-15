#!/usr/bin/env bash
# 下蹲/冲刺手感冒烟。通过 = SMOKE_MOVE_FEEL OK 退出 0。用户自跑。
set -u
# shellcheck source=tests/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
LOG="tests/move_feel_smoke.log"
"$GODOT" --headless --path . res://tests/move_feel_smoke.tscn 2>&1 | tee "$LOG"
if grep -q "SMOKE_MOVE_FEEL OK" "$LOG"; then
  echo "[move_feel] PASS"
  exit 0
else
  echo "[move_feel] FAIL —— 见 $LOG"
  exit 1
fi
