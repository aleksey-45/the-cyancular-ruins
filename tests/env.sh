#!/usr/bin/env bash
# 测试脚本的共用环境。用法(脚本开头,放在 `set -u` 之后):
#   source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
#
# 它做三件事,替掉此前在 8 个 .sh 里各抄一份的东西:
#   1. 导出 $GODOT(**可用环境变量覆盖** —— 换机器 / 换引擎版本只需设一次环境变量,
#      不必改 8 个文件;这也是 `tools/check_naming.py` 之外的「别再散落本机绝对路径」那条);
#   2. 把工作目录切到**仓库根**(各脚本原本各自 `cd "$(dirname "$0")/.."`,而 5 个简单冒烟
#      干脆没 cd、只能从仓库根跑 —— 现在从哪儿跑都行,`--path .` 与 `tests/*.log` 都成立);
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

# ── Windows 下 bash `kill` 杀不死 headless Godot(会留僵尸占 7777),改用 taskkill 强杀 ──
kill_procs() {
	for p in "$@"; do
		[ -n "$p" ] || continue
		taskkill //F //PID "$p" >/dev/null 2>&1 || true
	done
}

# 按**端口**强杀:Git Bash 的 $! 不一定等于 Windows 进程 PID(实测 taskkill 按 $! 杀不掉),
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
