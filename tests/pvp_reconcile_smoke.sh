#!/usr/bin/env bash
# C2 rollback 控制器 in-process 冒烟:权威+预测双 sim + 人工 ack 延迟 + 外部事件注入。
# 通过 = SMOKE_RECONCILE OK 退出 0。用户自跑。
set -u
# shellcheck source=tests/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
LOG="tests/pvp_reconcile_smoke.log"
"$GODOT" --headless --path . res://tests/pvp_reconcile_smoke.tscn 2>&1 | tee "$LOG"
if grep -q "SMOKE_RECONCILE OK" "$LOG"; then
  echo "[reconcile] PASS"
  exit 0
else
  echo "[reconcile] FAIL —— 见 $LOG"
  exit 1
fi
