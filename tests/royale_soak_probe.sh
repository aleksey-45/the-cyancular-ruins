#!/usr/bin/env bash
# 大乱斗压力探针:起大厅 + N 个跑真 royale_game 的 headless 客户端,压一局,汇总读数。
# 用法:  bash tests/royale_soak_probe.sh [客户端数] [一局秒数] [观测窗秒数]
# 默认:  4 个客户端,一局 60s,观测窗 120s
#
# ⚠ Windows 下 bash `kill` 杀不死 headless Godot,会留僵尸占 7777 —— 收尾一律 taskkill 按 PID,
#   再按端口找属主补杀(同 pvp_*_smoke.sh 的既有做法)。
# ⚠ 崩溃判据:`grep "SOAK: ALL-OK"` **且** 没有 "SCRIPT ERROR"/"无结果文件"。
#   只看退出码会把"没跑完"读成通过(--quit-after 之类安全网可能让它 exit 0)。
set -u

CLIENTS="${1:-4}"
MATCH="${2:-60}"
RUN="${3:-120}"

# 引擎路径($GODOT,可用环境变量覆盖)+ cd 到仓库根 + kill_procs/kill_port
# shellcheck source=tests/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
LOG="tests/royale_soak_probe.log"
PYDIR="$ENV_DIR"   # 仓库根(env.sh 已算好并 cd 过去;保留别名以免动下面所有引用)

echo "[soak] 检查 7777 是否空闲…"
if netstat -ano 2>/dev/null | grep -qE "[:.]7777[[:space:]].*LISTENING"; then
  echo "[soak] 7777 已被占用 —— 先清理僵尸 Godot:"
  kill_port 7777
  sleep 1
fi

echo "[soak] 客户端=$CLIENTS 一局=${MATCH}s 观测窗=${RUN}s"
cd "$PYDIR" || exit 1
"$GODOT" --headless --path . res://tests/royale_soak_probe.tscn \
    -- --clients="$CLIENTS" --match="$MATCH" --run="$RUN" 2>&1 | tee "$LOG"
RC=$?

echo "[soak] 清理残留 headless Godot / 端口"
kill_port 7777
for p in 7800 7801 7802 7803 7804 7805 7806 7807 7808 7809 7810; do
  kill_port "$p"
done

echo
if grep -q "SOAK: ALL-OK" "$LOG" && ! grep -qE "SCRIPT ERROR|无结果文件|Parse Error" "$LOG"; then
  echo "[soak] PASS —— 读数见 $LOG"
  exit 0
fi
echo "[soak] FAIL(退出码 $RC)—— 见 $LOG"
grep -nE "SCRIPT ERROR|无结果文件|Parse Error|FAIL" "$LOG" | head -20
exit 1
