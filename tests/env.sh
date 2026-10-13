#!/usr/bin/env bash
## 测试脚本公共运行环境配置。
# 使用方法（置于脚本开头，放在 set -u 之后引入）：
#   source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"   # 适用于 tests/{smoke,probe,harness,scripts}/ 各子目录脚本
#
# 主要功能：
#   1. 导出 $GODOT 可执行文件路径（支持通过环境变量 GODOT 覆写）；
#   2. 切换当前工作目录至工程根目录，统一各脚本执行时的相对路径上下文；
#   3. 提供仅用于结束本测试已记录 PID 的 kill_procs。
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
