#!/usr/bin/env bash
# 下蹲/冲刺手感冒烟。通过 = SMOKE_MOVE_FEEL OK 退出 0。用户自跑。
set -u
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
LOG="tests/move_feel_smoke.log"
"$GODOT" --headless --path . res://tests/move_feel_smoke.tscn 2>&1 | tee "$LOG"
if grep -q "SMOKE_MOVE_FEEL OK" "$LOG"; then
  echo "[move_feel] PASS"
  exit 0
else
  echo "[move_feel] FAIL —— 见 $LOG"
  exit 1
fi
