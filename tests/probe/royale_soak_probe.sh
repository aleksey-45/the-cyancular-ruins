#!/usr/bin/env bash
# 大乱斗压力探针:起大厅 + N 个跑真 royale_game 的 headless 客户端,压一局,汇总读数。
# 用法:  bash tests/probe/royale_soak_probe.sh [客户端数] [一局秒数] [观测窗秒数]
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
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
LOG="tests/probe/royale_soak_probe.log"
PYDIR="$ENV_DIR"   # 仓库根(env.sh 已算好并 cd 过去;保留别名以免动下面所有引用)

echo "[soak] 检查 7777 是否空闲…"
# ★ 判据**不带 `LISTENING`**:ENet 走 UDP、UDP 行没有状态列 ⇒ 带它是**结构性恒假**
#   (2026-09-27 实测),原先这一支的"已被占用 ⇒ 清理"**从未触发过**。理由见 env.sh 的 lobby_alive。
# ★★ 2026-10-15:**改了处置** —— 从前是"占用 ⇒ 杀属主 + 扫池",那会**端掉用户正在进行的对局**
#   (服务器 `_ready` 本来就 `kill_udp_port(7777)`,这里再杀一次只是让它更早)。按 AGENTS.md §1:
#   为真则**跳过并问** ⇒ 现在拒跑(exit 2)。
if lobby_alive; then
  echo "[gate1] REFUSED: 7777 上有活大厅(可能有人在打)—— 本支会先杀属主再 bind,故拒跑。"
  echo "         先停掉那个大厅,或按 AGENTS.md §1 先问用户。"
  exit 2
fi
kill_port_range 7800 8300     # 没有活大厅 ⇒ 池里的是上一跑遗留的孤儿 worker

echo "[soak] 客户端=$CLIENTS 一局=${MATCH}s 观测窗=${RUN}s"
cd "$PYDIR" || exit 1
"$GODOT" --headless --path . res://tests/probe/royale_soak_probe.tscn \
    -- --clients="$CLIENTS" --match="$MATCH" --run="$RUN" 2>&1 | tee "$LOG"
# ★★ 2026-10-15:必须取 PIPESTATUS[0](探针的退出码),`$?` 拿到的是 **tee** 的 —— 结构性恒 0,
#   于是"探针崩了"这条读数被静默变成 0。兄弟支(rejoin/team)都用 PIPESTATUS,本支漏了。
RC=${PIPESTATUS[0]}

echo "[soak] 清理残留 headless Godot / 端口"
kill_port 7777
# ★ 原先这里只列了 7800~7810 十一个端口,而真实池是 [7800, 8300)(`WorkerLauncher`)——
#   分配器是"唯一递增"的,一局一 worker,长跑里只要走过一次 7811 就会漏掉孤儿。
kill_port_range 7800 8300

echo
if grep -q "SOAK: ALL-OK" "$LOG" && ! grep -qE "SCRIPT ERROR|无结果文件|Parse Error" "$LOG"; then
  echo "[soak] PASS —— 读数见 $LOG"
  exit 0
fi
echo "[soak] FAIL(退出码 $RC)—— 见 $LOG"
grep -nE "SCRIPT ERROR|无结果文件|Parse Error|FAIL" "$LOG" | head -20
exit 1
