#!/usr/bin/env bash
# 子弹击中瓦片受击反馈冒烟测试：源码级结构校验。判定标准：输出 SMOKE_BULLET_TILE_FX OK 且退出码为 0。
set -u
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/smoke/bullet_tile_fx_smoke.log"
"$GODOT" --headless --path . -s res://tests/smoke/bullet_tile_fx_smoke.gd 2>&1 | tee "$LOG"
if grep -q "SMOKE_BULLET_TILE_FX OK" "$LOG"; then
  echo "[bullet_tile_fx] PASS"
  exit 0
else
  echo "[bullet_tile_fx] FAIL —— 见 $LOG"
  exit 1
fi
