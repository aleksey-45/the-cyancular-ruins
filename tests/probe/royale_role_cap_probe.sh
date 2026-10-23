#!/usr/bin/env bash
# 大乱斗 9 人真链路 —— 钉 X1:worker 的 role 上界必须跟着 ModeDefs.ROLE_MAX(16),
# 第 9 人起不能再被当"串线"踢掉(16 人上限只改了大厅/UI、worker 仍卡 8 的那个洞)。
#
# 做法:复用 `royale_soak_probe.sh` 的 9 客户端档(它的 max_players 取客户端数,
# 于是 role 号天然是 1..9),本支只负责判词 —— 不复制编排。
#
# 跑法(占 7777 + 端口池,会拉起 9 个客户端;串行纪律与 run_real.sh 相同):
#   bash tests/probe/royale_role_cap_probe.sh
# 判据:grep 文本 `ROLE CAP PROBE: ALL-OK(9/9)`;退出码不作判据。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

LOG="tests/probe/royale_role_cap_probe.log"
echo "[role-cap] 9 客户端大乱斗真链路(约 3~5 分钟;占 7777 + 端口池)…"
# soak 自己带 lobby_alive 闸(有活大厅 exit 2);这里不重复判,只把判词翻译成本支的。
bash tests/probe/royale_soak_probe.sh 9 45 90 2>&1 | tee "$LOG"

verdict=$(grep -E "SOAK: (ALL-OK|有 [0-9]+ 个客户端异常)" "$LOG" | tail -1)
echo "[role-cap] 判词原文: ${verdict:-（无 SOAK 判词行）}"
if echo "$verdict" | grep -q "SOAK: ALL-OK(9/9"; then
	echo "ROLE CAP PROBE: ALL-OK(9/9)"
	exit 0
fi
echo "ROLE CAP PROBE: FAIL(期望 SOAK: ALL-OK(9/9);实得:${verdict:-无})"
exit 1
