#!/usr/bin/env bash
## 测试脚本公共运行环境配置。
# 使用方法（置于脚本开头，放在 set -u 之后引入）：
#   source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"   # 适用于 tests/{smoke,probe,harness,scripts}/ 各子目录脚本
#
# 主要功能：
#   1. 导出 $GODOT 可执行文件路径（支持通过环境变量 GODOT 覆写）；
#   2. 切换当前工作目录至工程根目录，统一各脚本执行时的相对路径上下文；
#   3. 提供进程与端口清理辅助函数（kill_procs / kill_port / kill_port_range）。
#
# 注意事项：
# - 本文件会被声明了 set -u 的调用方脚本引入，所有变量引用必须提供默认值 ${VAR:-默认}。
# - 本文件内部禁止执行 set -e 或 set -u，避免破坏调用方原有的错误处理逻辑。

# ── 引擎可执行文件解析：优先读取环境变量，未设置时回退至本地默认路径 ──
GODOT="${GODOT:-D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe}"
export GODOT
if [ ! -f "$GODOT" ]; then
	echo "[env] 找不到引擎可执行文件: $GODOT" >&2
	echo "[env] 请配置环境变量 GODOT 指向 Godot 控制台程序路径，例如:" >&2
	echo "[env]   export GODOT='D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe'" >&2
	exit 1
fi

# ── 定位并切换至工程根目录 ──
ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ENV_DIR" || exit 1

# ── 强制终止指定 PID 进程（Windows 下使用 taskkill 确保无头进程被完全回收）──
kill_procs() {
	for p in "$@"; do
		[ -n "$p" ] || continue
		taskkill //F //PID "$p" >/dev/null 2>&1 || true
	done
}

# ── 强制释放指定 UDP 端口占用的属主进程（默认端口 7777，对应大厅服务）──
kill_port() {
	local port="${1:-7777}"
	local pids
	pids=$(netstat -ano 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | awk '{print $NF}' | sort -u)
	for p in $pids; do
		[ "$p" = "0" ] && continue
		echo "  清理占用端口 $port 的进程 PID=$p"
		taskkill //F //PID "$p" >/dev/null 2>&1 || true
	done
}

# ── 按端口范围批量清理残留的 Worker 子进程 ──
# 作用说明：
# 对局 Worker 进程通常由大厅服务派生。若前序测试异常中断，残留的孤儿进程仍会占用 UDP 端口，
# 导致后续测试重新分配到相同端口时绑定失败（如 ENet 报监听失败），从而引起网络测试阻塞挂起。
# 调用方按需传入端口范围参数（大厅 Worker 端口池默认为 [7800, 8300)）。
kill_port_range() {
	local lo="${1:-7800}" hi="${2:-8300}"
	local pids
	pids=$(netstat -ano 2>/dev/null | awk -v lo="$lo" -v hi="$hi" '
		$1 == "UDP" { n = split($2, a, ":"); p = a[n] + 0
			if (p >= lo && p < hi) print $NF }' | sort -u)
	for p in $pids; do
		[ -n "$p" ] || continue
		[ "$p" = "0" ] && continue
		echo "  清理残留进程(占用端口 $lo-$((hi - 1))) PID=$p"
		taskkill //F //PID "$p" >/dev/null 2>&1 || true
	done
}

# ── 检查 7777 端口是否存在活跃的大厅服务 ──
# 注意事项：ENet 基于 UDP 协议，netstat 输出中无 TCP 的 LISTENING 状态列，需直接匹配端口号。
lobby_alive() {
	netstat -ano 2>/dev/null | grep -qE "[:.]7777[[:space:]]"
}
