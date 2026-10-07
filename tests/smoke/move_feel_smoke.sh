#!/usr/bin/env bash
# 下蹲与冲刺移动手感冒烟测试：验证角色下蹲、冲刺加速度与摩擦力逻辑。判定标准：输出 SMOKE_MOVE_FEEL OK 且退出码为 0。
set -u
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/smoke/move_feel_smoke.log"
"$GODOT" --headless --path . res://tests/smoke/move_feel_smoke.tscn 2>&1 | tee "$LOG"
if grep -q "SMOKE_MOVE_FEEL OK" "$LOG"; then
  echo "[move_feel] PASS"
  exit 0
else
  echo "[move_feel] FAIL —— 见 $LOG"
  exit 1
fi
