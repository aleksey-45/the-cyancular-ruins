#!/usr/bin/env bash
# C2 回滚协调器进程内冒烟测试：双端模拟（权威端与预测端）+ 人工注入 ACK 延迟与外部事件。
# 判定标准：输出 SMOKE_RECONCILE OK 且退出码为 0。
set -u
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/smoke/pvp_reconcile_smoke.log"
"$GODOT" --headless --path . res://tests/smoke/pvp_reconcile_smoke.tscn 2>&1 | tee "$LOG"
if grep -q "SMOKE_RECONCILE OK" "$LOG"; then
  echo "[reconcile] PASS"
  exit 0
else
  echo "[reconcile] FAIL —— 见 $LOG"
  exit 1
fi
