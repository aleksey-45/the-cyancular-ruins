#!/usr/bin/env bash
# 大乱斗压力探针：启动大厅服务端与 N 个无头客户端加载 royale_game 场景，执行长时间对局压测并汇总性能指标。
# 运行方式：bash tests/probe/royale_soak_probe.sh [客户端数] [单局时长秒数] [观测窗口秒数]
# 默认参数：4 个客户端，单局 60 秒，观测窗口 120 秒
#
# - Windows 环境下 bash 的 kill 命令无法完全回收无头 Godot 进程，可能遗留僵尸进程占用端口 7777；
#   因此收尾统一通过 taskkill 按 PID 终止，并按端口占用精准清理。
# - 测试通过验收标准：日志包含 "SOAK: ALL-OK" 且无 "SCRIPT ERROR" 或 "无结果文件" 报错。
#   严禁仅依据退出码判定，避免因 --quit-after 超时导致的假阳性结果。
set -u

CLIENTS="${1:-4}"
MATCH="${2:-60}"
RUN="${3:-120}"

# 引擎路径($GODOT,可用环境变量覆盖)+ cd 到仓库根 + kill_procs/kill_port
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/probe/royale_soak_probe.log"
PYDIR="$ENV_DIR"   # 仓库根(env.sh 已算好并 cd 过去;保留别名以免动下面所有引用)

echo "[soak] 检查 7777 是否空闲…"
# 注意：判定条件不得过滤 LISTENING 状态（ENet 基于 UDP 协议，UDP 端口在 netstat 中无 LISTENING 状态字样）。
if lobby_alive; then
  echo "[soak] 7777 已被占用 —— 先清理僵尸 Godot:"
  kill_port 7777
  sleep 1
fi

echo "[soak] 客户端=$CLIENTS 一局=${MATCH}s 观测窗=${RUN}s"
cd "$PYDIR" || exit 1
"$GODOT" --headless --path . res://tests/probe/royale_soak_probe.tscn \
    -- --clients="$CLIENTS" --match="$MATCH" --run="$RUN" 2>&1 | tee "$LOG"
RC=$?

echo "[soak] 清理残留 headless Godot / 端口"
kill_port 7777
# 单进程架构下仅需清理大厅监听端口。

echo
if grep -q "SOAK: ALL-OK" "$LOG" && ! grep -qE "SCRIPT ERROR|无结果文件|Parse Error" "$LOG"; then
  echo "[soak] PASS —— 读数见 $LOG"
  exit 0
fi
echo "[soak] FAIL(退出码 $RC)—— 见 $LOG"
grep -nE "SCRIPT ERROR|无结果文件|Parse Error|FAIL" "$LOG" | head -20
exit 1
