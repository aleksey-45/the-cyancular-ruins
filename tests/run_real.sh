#!/usr/bin/env bash
# tests/run_real.sh —— **真链路批入口**(带认领闸)。
#
# 用法:
#   bash tests/run_real.sh              # 打印清单/端口/耗时估计,然后要交互确认
#   bash tests/run_real.sh --yes        # 无确认直接跑(agent/CI 用;仍过下面全部闸)
#   bash tests/run_real.sh --list       # 只打清单,不跑
#   bash tests/run_real.sh --only soak  # 只跑路径含 "soak" 的支
#
# 为什么与 `tests/run_all.sh` 分开:这一批**会占 7777 / 开真端口 / 拉子进程**,而
# `run_all.sh` 的默认批明文承诺**不碰 7777、不拉子进程**。判据同样是 **grep 文本**
# (退出码从来不是判据;真链路挂住时 `--quit-after` 到期照样 exit 0 且一行裁决都不打)。
#
# ★★ 它给的最强保证 / 测不到什么(照实写):
#   · **闸一(lobby_alive)**:7777 上有活大厅 ⇒ **拒绝**(大厅 `_ready` 会 `kill_udp_port(7777)`,
#     硬跑会端掉用户正在跑的对局)。★ 本入口**自己也不**在跑前杀 7777 —— 只查。
#   · **闸二(认领)**:没有 `--yes` 且 stdin 不是交互终端 ⇒ **拒绝**并提示手动跑。
#     ★ 它的保证只在"没人拿 `--yes` 硬闯"这句上:`--yes` 是**显式**认领,不是"我替你决定"。
#   · **闸三(前后无 Godot)**:跑前/跑后 `tasklist | grep -i godot` 必须为空 —— worker 是
#     `OS.create_process` 起的**孙进程**,不在任何脚本记下的 PID 里,孤儿会**毒害下一支**
#     (新大厅的端口分配集合是进程内内存 ⇒ 又选中同一端口 ⇒ 新 worker 报 `监听失败 20`)。
#     ★ 判空带"最多 ~10 秒的收尾等待",否则会把"刚杀掉、还在回收"误判成残留。
#     ★★ **2026-10-04 事故与加固(真实发生过,不是假想)**:在 `run_all.sh` 跑批期间调用本脚本
#     (`--yes`),那一次**单点采样**恰好落在两个 headless 测试之间的空档 ⇒ 计数 0 ⇒ 闸放行 ⇒
#     **真链路脚本真的跑了起来**(`pvp_match_smoke.sh`,短暂占了 7777;它自己因固定 `sleep` 太短
#     而 FAIL 走早退路径,顺带**复现了 `registered-debt.md` §五.9** 那条"早退路径漏杀孙进程")。
#     ⇒ 现在跑前要求:① `run_all` 的 summary 在 `RUNALL_QUIET_SECS` 秒内被写过 ⇒ 拒绝;
#     ② Godot 进程必须**连续** `GODOT_QUIET_SAMPLES` 次采样为空才放行。
#     ★ 去掉①或②:同一场景仍可能放行(单点采样骗得过)。
#     ★★ **它们都不替代人工纪律**:"别在另一批跑着的时候开这一批" —— 两道加强只把窗口收窄,
#     ★★ **2026-10-05 起:主判据是 R20 锁** —— `run_all.sh` 运行期持 `tests/.run_all.lock`
#     (pid / start / heartbeat),本脚本见活锁即拒;**陈旧锁(pid 已死 / 心跳超时)打醒目警告后放行**。
#     下面 ②③ 两条降为**副保险**(锁被 SIGKILL 之后它们才起作用)。
#     ★ 覆盖上限:心跳只在**每支之间**刷新,所以"一支挂住 120~150s"期间心跳会旧 ——
#     ★★ **按代码写清(2026-10-05 修复轮3 订正 —— 原句"主判据是 pid、不看心跳"与实现相反)**:
#     **活锁 = pid 还活着 **且** 心跳在 `LOCK_STALE_SECS`(600s)内**;两者**任一**不成立 ⇒ **陈旧 ⇒ 放行**。
#     心跳只在**支间**刷新 ⇒ 单支挂住 120~150s 期间心跳会旧,但仍在 600s 内 ⇒ 判活成立;
#     ★ **阈值必须跟着预算走**:谁把单支预算调到 >600s,这里就会把**正在跑的**批判成陈旧(⇒ 锁失效)。
#     三条都在 `tests/README.md` 的「聚合入口 → run_real.sh」一节里落纸(评审 I4 指出原先指向失效)。
#   · **闸四(清单不许烂)**:`tests/{smoke,probe}/*.sh` 里每一支**必须**出现在 `ENTRIES`
#     (跑)或 `WRAPPERS`(不跑 + 理由)之一,且两边每条都必须匹配到真实文件 ⇒ 否则**红**。
#     去掉这条:新加一支真链路 `.sh` 会**静默不进批**(而入口照样打 OK)。
#   · **端口回收只对池内那几支**:池外 `rejoin_probe.sh`(29300/29350)与 `team_match_probe.sh`
#     (29200/29250)**一律不扫** `[7800,8300)` —— 那是实现事实,也是**不许端掉用户对局**那条
#     硬规定的落点;它们各自扫自己的那一段。
#   · **测不到什么**:① 它**不替代**各支自己的判据(每支的日志里还有更细的断言);
#     ② `tests/probe/team_match_probe.sh` **今天仍不可当 3v3 的端到端守卫** ——
#     `docs/eng/registered-debt.md` §一第 1 行:根因已修(`9003dae`),但**修复后没有留下六人整跑的判决**。
#     本入口**照实标注**它,不会因为"跑过"就把它当绿。
#   · ASCII 射程(**与 `run_all.sh` 同一口径,权威表述在它的文件头**,2026-10-05 修复轮2 订正 ——
#     原句"一律 ASCII(同 run_all.sh)"两边都对不上):**全批判词行(`RUN_REAL …`)是纯 ASCII**;
#     gate 说明行原样含中文;**判词原文**(含中文)落在 `tests/.run_real_logs/*.log`。
set -u

# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

LOG_DIR="tests/.run_real_logs"
SUMMARY="$LOG_DIR/summary.log"
POOL_LO=7800
POOL_HI=8300
GODOT_SETTLE_TRIES=10          # 判"Godot 真的没了"最多等几秒(见文件头闸三)
# ★★ 闸三(跑前)的**两道**加强 —— 由来是一次**真事故**(2026-10-04 本批实测):
#   在 `tests/run_all.sh` 正跑着的时候调用 `run_real.sh --yes`,那一次**单点采样** `tasklist`
#   恰好落在两个 headless 测试之间的空档 ⇒ 计数为 0 ⇒ 闸放行 ⇒ **真链路脚本真的跑了起来**
#   (它短暂占了 7777)。两批交错既污染"Godot 进程必须为空"这条纪律,也污染真链路的时序结论。
#   ⇒ 现在要求:① 见下 **R20 锁**(主判据,"在飞"是**状态**不是**采样**);
#             ② `run_all` 的 summary 在 RUNALL_QUIET_SECS 秒内被写过 ⇒ 拒绝(副保险);
#             ③ Godot 进程必须**连续** GODOT_QUIET_SAMPLES 次采样都为空才放行(副保险)。
#   ★ 去掉①:窗口最大的时刻(有一支挂住/正在 TIMEOUT)恰好是"summary 很久没动"的时刻
#     ⇒ ②③ 都可能放行 —— 这正是 2026-10-04 那次事故的形状(评审 I4)。
#   ★ 去掉②③:锁文件被 SIGKILL 掉之后没有兜底。
#   ★ 三者都**不**替代"别在跑批时开另一批"这条人工纪律:它们只让"没注意到"变成"拒绝"。
GODOT_QUIET_SAMPLES=3
RUNALL_SUMMARY="tests/.run_all_logs/summary.log"
# ★ I4 修(2026-10-05):原值 90s **小于**单支最长静默(场景默认 120s / `duel_spawn_timeout_smoke` 150s)
#   ⇒ "有支挂住时"这条判据会**放行**。现在取 **> 单支最大预算 + 余量**(150 + 90 = 240)。
RUNALL_QUIET_SECS="${RUN_REAL_QUIET_SECS:-240}"
# R20 锁:由 `tests/run_all.sh` 运行期持有(内容 = pid / start / heartbeat)。
RUN_ALL_LOCK="tests/.run_all.lock"
LOCK_STALE_SECS="${RUN_REAL_LOCK_STALE_SECS:-600}"
# 判词判据(与 run_all.sh 同一套):边界类含 `_`(否则 `NET_INPUT_OK` 这种判词会被读漏);
# FAIL 侧放宽到 FAIL[A-Z]{0,4},覆盖现网的 FAIL / FAILED / FAILURES 形状。
FAIL_RE='(^|[^A-Za-z0-9])FAIL[A-Z]{0,4}([^A-Za-z0-9]|$)'

# ── 真链路清单:$path|端口|耗时估计|判词(grep 文本;`&&` = 必须同时命中)|回收范围 ──
# 顺序 = 从"最短 + 最基础"到"最长 + 不确定性最大",这样先跑的先给出便宜信号。
# 耗时估计取自各支自己的头注(不是猜的);改了头注就要同步改这里。
ENTRIES=(
	"tests/smoke/pvp_match_smoke.sh|7777 + pool[7800,8300]|~20s|SMOKE PASS|pool"
	"tests/smoke/pvp_room_smoke.sh|7777 + pool[7800,8300]|~40s|SMOKE PASS|pool"
	"tests/probe/rejoin_probe.sh|lobby 29300 / worker 29350 (OUT of pool)|60~110s|REJOIN PROBE: ALL-OK|nopool"
	"tests/probe/royale_soak_probe.sh|7777 + pool[7800,8300]|~150-200s|SOAK: ALL-OK|pool"
	"tests/probe/royale_role_cap_probe.sh|7777 + pool[7800,8300]|~3-5min|ROLE CAP PROBE: ALL-OK(9/9)|pool"
	"tests/probe/team_match_probe.sh|lobby 29200 / worker 29250 (OUT of pool)|3~10min|TEAM MATCH PROBE: ALL-OK|nopool"
)

# ── 同目录下的 .sh 里**不进真链路批**的那些(`path|理由`)────────────────────────
# 判据 = "它是不是**单进程**:只起一个 Godot + tee 日志"。单进程的那几支**已经被
# `tests/run_all.sh` 的默认批覆盖**(同一个 `.gd` / `.tscn`),再进真链路批只是重复计费。
# ★ 任何一条都必须在闸四那里匹配到真实文件,否则红。
# ★★ 2026-10-09(测试面削减 90%):本表 **4 条 → 0 条**。原来那 4 支
#   (`bullet_tile_fx` / `move_feel` / `pvp_reconcile` / `pvp_twin`)连同它们的 `.gd` / `.tscn`
#   一起被删了,所以既没有"不跑的包装",也没有"跑的理由"。台账:
#   `docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md`。
#   **别把本数组删掉**:闸四同时遍历 `ENTRIES` 与 `WRAPPERS`,数组不存在会让 `set -u` 下的
#   展开报错;留着空数组 = "现在一支包装都没有"这件事**看得见**。
WRAPPERS=()

ASSUME_YES=0
LIST_ONLY=0
ONLY=""
while [ $# -gt 0 ]; do
	case "$1" in
		--yes|-y) ASSUME_YES=1; shift ;;
		--list) LIST_ONLY=1; shift ;;
		--only) ONLY="${2:-}"; shift 2 ;;
		--only=*) ONLY="${1#--only=}"; shift ;;
		-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
		*) echo "[real] unknown arg: $1" >&2; exit 2 ;;
	esac
done

godot_proc_count() { tasklist 2>/dev/null | grep -ci godot || true; }

# 闸三的判据:等它真的没了(最多 $GODOT_SETTLE_TRIES 秒),返回 0 = 干净
wait_no_godot() {
	local i n
	for i in $(seq 1 "$GODOT_SETTLE_TRIES"); do
		n=$(godot_proc_count)
		[ "$n" -eq 0 ] && return 0
		sleep 1
	done
	return 1
}

# 闸三(跑前)的两道加强 —— 由来见文件头那段的真事故。返回 0 = 可以跑。
# R20 锁的状态:设置 LOCK_STATE=absent|live|stale 与 LOCK_INFO(供打印/拒绝)
lock_state() {
	local pid start hb now age
	LOCK_STATE=absent; LOCK_INFO=""
	[ -f "$RUN_ALL_LOCK" ] || return 0
	pid=$(sed -n 's/^pid=//p' "$RUN_ALL_LOCK" 2>/dev/null | head -1)
	start=$(sed -n 's/^start=//p' "$RUN_ALL_LOCK" 2>/dev/null | head -1)
	hb=$(sed -n 's/^heartbeat=//p' "$RUN_ALL_LOCK" 2>/dev/null | head -1)
	now=$(date +%s)
	age=$(( now - ${hb:-0} ))
	LOCK_INFO="pid=$pid start=$(date -d "@${start:-0}" '+%F %T' 2>/dev/null || echo "${start:-?}") heartbeat_age=${age}s"
	# 活锁 = pid 还活着 **且** 心跳在阈值内;任一不成立 ⇒ 陈旧(见文件头:阈值必须跟着预算走)
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$age" -lt "$LOCK_STALE_SECS" ]; then
		LOCK_STATE=live
	else
		LOCK_STATE=stale
	fi
}

gate3_precheck() {
	local age=0 i n
	# ── ① R20 锁(主判据)──────────────────────────────────────────────
	lock_state
	if [ "$LOCK_STATE" = live ]; then
		echo "[gate3] REFUSED: tests/run_all.sh is running (lock $RUN_ALL_LOCK: $LOCK_INFO)."
		echo "        This is the R20 lock, not a sample: a headless batch is in flight right now."
		echo "        Wait for it to finish (the lock is removed on exit / Ctrl-C)."
		return 1
	fi
	if [ "$LOCK_STATE" = stale ]; then
		echo "[gate3] WARNING: STALE lock $RUN_ALL_LOCK ($LOCK_INFO) --"
		echo "        the owning pid is gone or the heartbeat timed out. Treating it as stale and"
		echo "        PROCEEDING (an always-refusing gate would be as useless as an always-red one)."
		echo "        If you know a batch is actually running, Ctrl-C now. Remove the file to silence this:"
		echo "          rm -f $RUN_ALL_LOCK"
	fi
	# ── ② summary mtime(副保险)────────────────────────────────────────
	if [ -f "$RUNALL_SUMMARY" ]; then
		age=$(( $(date +%s) - $(stat -c %Y "$RUNALL_SUMMARY" 2>/dev/null || echo 0) ))
		if [ "$age" -lt "$RUNALL_QUIET_SECS" ]; then
			echo "[gate3] REFUSED: $RUNALL_SUMMARY was written ${age}s ago (< ${RUNALL_QUIET_SECS}s)."
			echo "        A headless batch (tests/run_all.sh) looks in flight. Refusing so the two"
			echo "        do not interleave. Wait, or delete that file if you know it is stale."
			return 1
		fi
	fi
	# ── ③ 连续空采样(副保险)──────────────────────────────────────────
	for i in $(seq 1 "$GODOT_QUIET_SAMPLES"); do
		n=$(godot_proc_count)
		if [ "$n" -ne 0 ]; then
			echo "[gate3] REFUSED: $n Godot process(es) alive (quiet sample $i/$GODOT_QUIET_SAMPLES)."
			echo "        A single sample can land in the gap between two headless tests -- that is"
			echo "        exactly how a real-link script got started by accident once (see the header)."
			return 1
		fi
		sleep 1
	done
	return 0
}

# ── 闸四:清单不许烂 ─────────────────────────────────────────────────────
shopt -s nullglob
ALL_SH=()
for f in tests/smoke/*.sh; do ALL_SH+=("$f"); done
for f in tests/probe/*.sh; do ALL_SH+=("$f"); done
shopt -u nullglob

LIST_BAD=0
for f in "${ALL_SH[@]}"; do
	found=0
	for line in "${ENTRIES[@]}" "${WRAPPERS[@]}"; do
		[ "${line%%|*}" = "$f" ] && { found=1; break; }
	done
	if [ "$found" -eq 0 ]; then
		echo "[gate4] FATAL: $f is neither in ENTRIES nor in WRAPPERS -- it would silently never run."
		LIST_BAD=$((LIST_BAD + 1))
	fi
done
for line in "${ENTRIES[@]}" "${WRAPPERS[@]}"; do
	p="${line%%|*}"
	[ -f "$p" ] || { echo "[gate4] FATAL: listed path does not exist: $p (rename drift?)"; LIST_BAD=$((LIST_BAD + 1)); }
done

# ── 打印清单(永远先打,认领的人要先看见)────────────────────────────────
echo "==== run_real: real-link batch ===="
echo "[env] GODOT = $GODOT"
echo "[env] version = $("$GODOT" --version 2>/dev/null | head -1)"
echo "[env] godot procs = $(godot_proc_count)"
echo "[env] log dir = $LOG_DIR"
echo "[plan] order | ports | estimate | verdict | pool-sweep"
for line in "${ENTRIES[@]}"; do
	IFS='|' read -r p ports est verdict sweep <<<"$line"
	printf '  %-36s %-38s %-10s %-24s %s\n' "$p" "$ports" "$est" "$verdict" "$sweep"
done
echo "[plan] not in this batch (single-process wrappers; already covered by run_all.sh):"
for line in "${WRAPPERS[@]}"; do
	echo "  ${line%%|*}"
	echo "      reason: ${line#*|}"
done
TOTAL_EST="sum of the estimates above: ~4-12 min (team_match_probe dominates; it is 3-10 min by itself)"
echo "[plan] $TOTAL_EST"
echo "[plan] pool range swept for in-pool entries only: [$POOL_LO,$POOL_HI) ; rejoin/team are swept by themselves"

# ── 闸四先判:清单烂了就**不跑** ─────────────────────────────────────────
# ★ 它在 `--list` 的提前退出**之前**判 —— 否则"清单已经烂了"会被 `--list` 报成 exit 0
#   (那正是这道闸要防的形状:一支真链路 `.sh` 静默不进批,而入口照样绿)。
if [ "$LIST_BAD" -gt 0 ]; then
	echo
	echo "RUN_REAL FAIL($LIST_BAD list-problems ; nothing was run)"
	exit 1
fi

if [ "$LIST_ONLY" -eq 1 ]; then exit 0; fi

# ── 闸一:7777 上有活大厅 ⇒ 拒绝 ───────────────────────────────────────
if lobby_alive; then
	echo
	echo "[gate1] REFUSED: a live lobby is listening on 7777."
	echo "        The lobby's _ready calls kill_udp_port(7777) -- running now would end the match"
	echo "        the user is playing. Stop that lobby first, then re-run."
	echo "RUN_REAL REFUSED(lobby_alive)"
	exit 2
fi

# ── 闸二:认领 ─────────────────────────────────────────────────────────
if [ "$ASSUME_YES" -ne 1 ]; then
	if [ ! -t 0 ]; then
		echo
		echo "[gate2] REFUSED: no --yes and stdin is not an interactive terminal."
		echo "        Re-run with:  bash tests/run_real.sh --yes"
		echo "        ...or paste the individual commands above and run them yourself."
		echo "RUN_REAL REFUSED(not claimed)"
		exit 2
	fi
	printf "Type 'yes' to run the batch above: "
	read -r ans
	case "$ans" in
		yes|YES|y|Y) ;;
		*) echo "[gate2] aborted by the operator."; echo "RUN_REAL REFUSED(not claimed)"; exit 2 ;;
	esac
fi

# ── 选支(过滤后为空 ⇒ 拒绝)────────────────────────────────────────────
SEL=()
for line in "${ENTRIES[@]}"; do
	p="${line%%|*}"
	if [ -n "$ONLY" ]; then
		case "$p" in *"$ONLY"*) ;; *) continue ;; esac
	fi
	SEL+=("$line")
done
if [ "${#SEL[@]}" -eq 0 ]; then
	echo "[gate] REFUSED: the filter matched 0 entries (--only '$ONLY')."
	echo "RUN_REAL FAIL(0 entries)"
	exit 1
fi

# ── 闸三(跑前)──────────────────────────────────────────────────────────
if ! gate3_precheck; then
	echo "RUN_REAL REFUSED(not quiet: leftover Godot / another batch in flight)"
	exit 1
fi

mkdir -p "$LOG_DIR"
: >"$SUMMARY"
{
	echo "run_real summary (UTF-8)"
	echo "date: $(date '+%Y-%m-%d %H:%M:%S')"
	echo "GODOT: $GODOT"
} >>"$SUMMARY"

echo
printf '%-36s %-11s %4s  %-30s %s\n' "ENTRY" "VERDICT" "SEC" "LOG" "VERDICT LINE (ASCII-stripped)"
printf '%-36s %-11s %4s  %-30s %s\n' "------------------------------------" "-----------" "----" "------------------------------" "-------------------------------"

N_OK=0; N_ENTRY_FAIL=0; N_GATE=0
for line in "${SEL[@]}"; do
	IFS='|' read -r p ports est verdict sweep <<<"$line"
	base=$(basename "$p"); base="${base%.sh}"
	log="$LOG_DIR/$base.log"

	# 回收范围:池内才扫池;池外由它们自己扫自己那一段(硬规定,见文件头)
	if [ "$sweep" = pool ]; then
		if ! lobby_alive; then kill_port_range "$POOL_LO" "$POOL_HI" >/dev/null 2>&1 || true; fi
	fi

	t0=$(date +%s)
	timeout 1200 bash "$p" >"$log" 2>&1
	rc=$?
	t1=$(date +%s)
	sec=$((t1 - t0))

	# 分类:先看 FAIL 词(fail-closed),再看判词是否**全部**命中(`&&` 分隔),都没有 ⇒ NO-VERDICT
	# 判据与 run_all.sh 同一套(边界类含 `_`;FAIL 侧放宽到 FAIL[A-Z]{0,4} 覆盖 FAILED/FAILURES)。
	pat_hit=1
	IFS='&&' read -ra PATS <<<"$verdict"
	for pat in "${PATS[@]}"; do
		grep -qF -- "$pat" "$log" || pat_hit=0
	done
	fail_line=$(grep -nE "$FAIL_RE" "$log" | head -1)
	if [ -n "$fail_line" ]; then
		VD="FAIL"; VLINE="${fail_line#*:}"; N_ENTRY_FAIL=$((N_ENTRY_FAIL + 1))
	elif [ "$pat_hit" -eq 1 ]; then
		VD="OK"; VLINE=$(grep -F -- "${PATS[0]}" "$log" | tail -1); N_OK=$((N_OK + 1))
	else
		VD="NO-VERDICT"; VLINE="(expected verdict not found: $verdict)"; N_ENTRY_FAIL=$((N_ENTRY_FAIL + 1))
	fi
	vline_disp=$(printf '%s' "$VLINE" | LC_ALL=C sed 's/[^ -~]//g' | tr -s ' ' | cut -c1-72)
	printf '%-36s %-11s %4s  %-30s %s\n' "$p" "$VD" "$sec" "$base.log" "$vline_disp"

	{
		printf '%s\t%s\trc=%s\t%ss\t%s\n' "$VD" "$p" "$rc" "$sec" "$log"
		printf '    line: %s\n' "$VLINE"
	} >>"$SUMMARY"

	# 池内支收尾:扫池 + 判空(池外不扫)
	if [ "$sweep" = pool ]; then
		if ! lobby_alive; then kill_port_range "$POOL_LO" "$POOL_HI" >/dev/null 2>&1 || true; fi
	fi
	if ! wait_no_godot; then
		echo "[gate3] FAIL: Godot processes still alive after $p ($(godot_proc_count))."
		echo "        Stopping here -- a leftover worker would poison every following entry."
		tasklist 2>/dev/null | grep -i godot | head -10
		N_GATE=$((N_GATE + 1))
		break
	fi
done

echo
echo "[logs] full text: $LOG_DIR/*.log"
echo "[logs] summary  : $SUMMARY"
N_BAD=$((N_ENTRY_FAIL + N_GATE))
if [ "$N_BAD" -gt 0 ]; then
	echo
	echo "RUN_REAL FAIL(entries: ok=$N_OK fail=$N_ENTRY_FAIL ; gate-failures=$N_GATE)"
	exit 1
fi
echo
echo "RUN_REAL OK($N_OK entries)"
echo "[note] team_match_probe is registered in docs/eng/registered-debt.md sec.1 as NOT yet a trustworthy"
echo "       3v3 end-to-end guard (root cause fixed, no 6-player verdict since) -- a green here does not change that."
exit 0
