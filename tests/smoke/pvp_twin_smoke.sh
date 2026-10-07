#!/usr/bin/env bash
# C2 客户端预测与状态同步冒烟测试（单进程，headless 场景模式）：验证 capture_state 与 restore_state 的完整性。
# 判定标准：输出 SMOKE_TWIN OK 且退出码为 0；验证客户端 B 在被注入扰动数据后，通过状态恢复（restore）依然能够与权威端 A 逐物理帧同步收敛。
# 运行方式：bash tests/smoke/pvp_twin_smoke.sh
set -u
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/smoke/pvp_twin_smoke.log"
"$GODOT" --headless --path . res://tests/smoke/pvp_twin_smoke.tscn 2>&1 | tee "$LOG"
if grep -q "SMOKE_TWIN OK" "$LOG"; then
  echo "[pvp_twin] PASS"
  exit 0
else
  echo "[pvp_twin] FAIL —— 见 $LOG(字段发散=capture_state 漏变量)"
  exit 1
fi
