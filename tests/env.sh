#!/usr/bin/env bash
# 测试脚本的共用环境。用法(脚本开头,放在 `set -u` 之后):
#   source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"   # 调用方在 tests/{smoke,probe,harness,scripts}/ 下一层
#
# 它做三件事,替掉此前在 8 个 .sh 里各抄一份的东西:
#   1. 导出 $GODOT(**可用环境变量覆盖** —— 换机器 / 换引擎版本只需设一次环境变量,
#      不必改 8 个文件;这也是 `tools/check_naming.py` 之外的「别再散落本机绝对路径」那条);
#   2. 把工作目录切到**仓库根**(各脚本原本各自 `cd "$(dirname "$0")/.."`,而 5 个简单冒烟
#      干脆没 cd、只能从仓库根跑 —— 现在从哪儿跑都行,`--path .` 与 `tests/*/*.log` 都成立);
#   3. 提供 kill_procs / kill_port。
#
# ⚠ 本文件会被 `set -u` 的脚本 source,故**不得**依赖任何未定义变量(一律用 ${VAR:-默认})。
# ⚠ 不要在这里 `set -e`/`set -u`:各脚本自己已有(`set -e` 的 3 个多进程脚本 / `set -u` 的 5 个
#   简单冒烟),在此强加会改变 `|| true` 那类写法的语义。

# ── 引擎可执行文件:优先环境变量,回落本机默认(4.7.1 **console** 版;截图类探针要非 headless)──
GODOT="${GODOT:-D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe}"
export GODOT
if [ ! -f "$GODOT" ]; then
	echo "[env] 找不到引擎: $GODOT" >&2
	echo "[env] 设环境变量 GODOT 指向 Godot 的 console 可执行文件,例如:" >&2
	echo "[env]   export GODOT='D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe'" >&2
	# 本文件只被 source:这里的 exit 结束的是**调用方脚本** —— 找不到引擎就没法跑,正该如此。
	exit 1
fi

# ── 仓库根:BASH_SOURCE 才在 source 场景下也算得对本文件的位置 ──
ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ENV_DIR" || exit 1

# ── Windows 下 bash `kill` 杀不死 headless Godot(会留僵尸占 7777),改用 taskkill 强制终止进程 ──
kill_procs() {
	for p in "$@"; do
		[ -n "$p" ] || continue
		taskkill //F //PID "$p" >/dev/null 2>&1 || true
	done
}

# 按**端口**强制终止进程:Git Bash 的 $! 不一定等于 Windows 进程 PID(实测 taskkill 按 $! 杀不掉),
# 用 netstat 找持有该端口的 PID 才是权威。默认 7777(大厅)。
kill_port() {
	local port="${1:-7777}"
	local pids
	pids=$(netstat -ano 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | awk '{print $NF}' | sort -u)
	for p in $pids; do
		[ "$p" = "0" ] && continue
		echo "  kill 端口 $port 属主 PID=$p"
		taskkill //F //PID "$p" >/dev/null 2>&1 || true
	done
}

# ── 按**端口区间**强清理残留孤儿进程 worker(2026-09-27 新增)──
# - 为什么需要:worker 由大厅 `OS.create_process` 启动,是**孙进程** —— 不属于任何脚本记下的
#   PID,而各脚本收尾只杀自己记下的 PID + 按端口杀大厅  ->  worker 会一直活着占住自己的端口。
#   紧接着跑下一支真链路测试时,新大厅的分配器是"唯一递增 + 占用集合"、而那个**集合是进程内
#   内存**(新进程里是空的) ->  会**再次选中同一端口**  ->  新 worker 报 `监听失败 20`  ->  客户端
#   连到的是**上一支的僵尸 worker**  ->  永远收不到 `match_start`  ->  客户端的内建超时(只在
#   match_start **之后**才计帧)永不触发  ->  整支**挂到外层 timeout,一行裁决都不打**(与真失败
#   在输出上长得一样)。2026-09-27 实测先后测试失败 `pvp_match_smoke` 与 `royale_probe`,
#   清掉孤儿后重跑**测试均通过**;worker 日志里的 `Couldn't create an ENet host` 是判据。
# - 区间**由调用方给**,因为池不止一个:大厅自己的池 = `WorkerLauncher` 的 [7800, 8300);
#   池外探针(rejoin / team)把分配器起点拨到 29350 / 29250,而它们**明文承诺不碰 7800~8299**
#   (那会端掉用户正在跑的对局) ->  那两支只能扫自己那一段。
kill_port_range() {
	local lo="${1:-7800}" hi="${2:-8300}"
	local pids
	pids=$(netstat -ano 2>/dev/null | awk -v lo="$lo" -v hi="$hi" '
		$1 == "UDP" { n = split($2, a, ":"); p = a[n] + 0
			if (p >= lo && p < hi) print $NF }' | sort -u)
	for p in $pids; do
		[ -n "$p" ] || continue
		[ "$p" = "0" ] && continue
		echo "  kill 孤儿(端口 $lo-$((hi - 1)) 占用)PID=$p"
		taskkill //F //PID "$p" >/dev/null 2>&1 || true
	done
}

# 7777 上有没有活着的大厅。
# 注意： 判据**不能带 `LISTENING`**:ENet 走 **UDP**,而 UDP 行没有状态列
#   (`UDP  0.0.0.0:7777   *:*   PID`)。2026-09-27 实测:7777 被 PID 28836 占着时,
#   带 `.*LISTENING` 的判据**不命中**,去掉就命中  ->  那一版是**结构性恒假**。
#   本仓三支脚本(`royale_soak_probe` / `rejoin_probe` / `team_match_probe`)原先都用的那版
#    ->  它们的"7777 已被占用"提示与连带清理**从未触发过**(登记见 docs/eng/tests.md)。
lobby_alive() {
	netstat -ano 2>/dev/null | grep -qE "[:.]7777[[:space:]]"
}
