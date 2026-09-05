#!/usr/bin/env bash
# C2 孪生冒烟(单进程,scene 模式 headless):证明 capture_state/restore_state 完整。
# 通过 = 打印 SMOKE_TWIN OK 退出 0;B 每 12 tick 被搞乱后 restore(A) 仍与 A 逐 tick 收敛。
# 用户自跑:bash Tests/pvp_twin_smoke.sh(CLAUDE.md 约定测试由用户自己跑)。
set -u
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
LOG="tests/pvp_twin_smoke.log"
"$GODOT" --headless --path . res://tests/pvp_twin_smoke.tscn 2>&1 | tee "$LOG"
if grep -q "SMOKE_TWIN OK" "$LOG"; then
  echo "[pvp_twin] PASS"
  exit 0
else
  echo "[pvp_twin] FAIL —— 见 $LOG(字段发散=capture_state 漏变量)"
  exit 1
fi
