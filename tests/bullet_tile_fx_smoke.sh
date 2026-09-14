#!/usr/bin/env bash
# 打墙命中反馈——源码级结构检查。通过 = SMOKE_BULLET_TILE_FX OK 退出 0。用户自跑。
set -u
# shellcheck source=tests/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
LOG="tests/bullet_tile_fx_smoke.log"
"$GODOT" --headless --path . -s res://tests/bullet_tile_fx_smoke.gd 2>&1 | tee "$LOG"
if grep -q "SMOKE_BULLET_TILE_FX OK" "$LOG"; then
  echo "[bullet_tile_fx] PASS"
  exit 0
else
  echo "[bullet_tile_fx] FAIL —— 见 $LOG"
  exit 1
fi
