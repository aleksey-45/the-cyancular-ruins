#!/usr/bin/env bash
# tests/run_all.sh —— 聚合回归入口(**headless 默认批**)。
#
# 用法:
#   bash tests/run_all.sh                 # 全批
#   bash tests/run_all.sh --list          # 只列清单(跑哪些 / 排除哪些 + 每条理由),不跑
#   bash tests/run_all.sh --only probe    # 只跑相对路径里含 "probe" 的支(便宜的子集)
#
# 判据(**一律 grep 文本;退出码从来不是判据**):
#   · 逐支判词分**五类**(判据仍是判词文本,`rc` 只用来把"判词肯定"的那一类再分一层):
#       `OK`          判词肯定 **且** rc == 0;
#       `OK+RC`       判词肯定 **但** rc != 0 —— **不算红**(退出码不是判据),但**单独成类**印出来,
#                     **绝不混进 OK**:`elite_drop_probe` 实测先打 OK 再在退出时 SIGSEGV(rc=139);
#       `FAIL`        判词否定(含脚本自己打的 `[FAIL]`);
#       `NO-VERDICT`  两个判词都没有(= `--quit-after` 安全网耗尽 / 挂住);
#       `TIMEOUT`     被外层 `timeout` 掐掉(rc 124)。
#     ★ 后两类**归红**:它们正是"守卫自己瞎了"的形态(安全网耗尽与真失败在输出上长得一样)。
#   · **已知红基线 `tests/known_red.txt`**:每行 `路径 类别 理由…`(理由**必填**;`#` 是注释;
#     **空行 = 违规**;类别 ∈ `OK+RC|FAIL|NO-VERDICT|TIMEOUT|*`)。基线内的红 = `KNOWN-RED` ⇒
#     **不进**新红计数,但**永远**印出文件名与条数。★ 需要它的理由是本仓自己的话:
#     `tests/probe/allscript_probe.gd:14` 的"**一条永远红的闸等于没有闸**" —— 一建起来就永远 FAIL
#     的入口,后面几个包**没法**拿它判断"我这次改坏了没有"。
#     ★ 销一条就要**删行**;"修好了却没删行"= 过期基线条目 ⇒ 也红(与 §三「销掉时删行」同规)。
#   · 全批判词:
#       `RUN_ALL OK(n 支 / m 断言闸)`                                    —— 一条红都没有
#       `RUN_ALL OK-WITH-KNOWN-RED(n 支,其中 k 支已登记)`                 —— 只有已登记红
#       `RUN_ALL FAIL(r 支新红 + k 支已登记)`                             —— 有新红 / 闸问题
#     ★ 退出码:**有新红 ⇒ 非 0;只有已登记红 ⇒ 0**。但判词行**永远**把已登记红的条数与文件名
#       印出来 —— 防"OK 被读成全绿"。
#   · `m` = **带 `EXPECTED_CHECKS` 条数闸**的那些支的闸值之和(**不是**全批断言总数):
#     `-s` 冒烟与不带闸的场景探针贡献 0(它们仍受下面那条纪律约束)。
#
# ★★ 它给的最强保证 / 测不到什么(照实写,别读多):
#   · **自动枚举**:`tests/smoke/*.gd` + `tests/probe/*.tscn` 用 glob,文件清单**不写死**
#     (写死会让新探针**永不进默认批**而入口照样打 OK)。落选走 `EXCLUDED` 显式清单 + 每条理由。
#   · **枚举到 0 支 / 跑 0 支 = 直接红**(防止 glob 与过滤器静默空转仍报 OK)。
#   · **过期排除项 = 直接红**:改名的探针会让旧条目失效 —— 若不红,一个改名后的
#     `royale_probe` 会悄悄进默认批并**占 7777**(会端掉用户正在跑的对局)。
#   · **承重安全检查**:默认批里不许出现 `NetBus.start_server(` / `ENetMultiplayerPeer` /
#     `OS.create_process(` 的支(会开端口 / 拉子进程)⇒ 命中即红,强制人去"显式排除(带理由)"
#     或改探针。★ **它的盲区**:只看**整行注释以外**的文本,且**看不见经 helper 间接开端口**
#     (如 `WorkerLauncher.spawn_worker`)—— 今天默认批里那两支(29014/29015)正是这种形状,
#     已知且无害(池外,不占 7777);新增的间接形状**这条守卫不会响**。
#   · 单支 OK **只证明"没有失败输出"**,**不证明每条断言都跑过**:脚本错误只结束出错的那个函数、
#     调用方继续、verdict 照打 `ALL-OK`(权威表述:`tests/lib/probe_base.gd` 文件头)。
#     本入口**不替代**探针自己的 `EXPECTED_CHECKS` 条数闸 —— 表里 `GATE` 栏是 `-` 就表示
#     "这一支没有闸",那条纪律对它仍然成立。
#   · **默认批不含真链路**(占 7777 / 多进程 / 非 headless 取图)⇒ **默认批绿 ≠ 真链路绿**。
#     那些支走 `tests/run_real.sh`(带认领闸);清单与理由见 `--list` 与 tests/README.md。
#   · 控制台输出**一律 ASCII**(本机控制台是 GBK:中文 / ⇒ / ✓ 会把脚本打崩)。判词**原文**
#     (含中文)落在 `tests/.run_all_logs/summary.log`(UTF-8)与每支日志里;控制台那一栏是
#     **剥掉非 ASCII 字节**后的形态 —— 判词 token 本身是 ASCII,所以它一定还在。
set -u

# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

QUIT_AFTER=3600                     # 场景探针的统一安全网(帧);理由见 docs/eng/tests.md「场景探针」
SMOKE_BUDGET=60                     # `-s` 冒烟的外层墙钟预算(秒)
SCENE_BUDGET=120                    # 场景探针的外层墙钟预算(秒)
LOG_DIR="tests/.run_all_logs"
SUMMARY="$LOG_DIR/summary.log"
FAILED_LIST="$LOG_DIR/failed.log"

# ── 逐支的墙钟预算**加长**清单(smoke 名 = 秒)─────────────────────────────────
# 为什么需要:各支自己在文件头声明了 `timeout N`,统一 60 会把它们**误杀**(误杀与真失败在
# 输出上长得一样,是本仓最怕的那类假红)。★ 这里只列**文件头自己声明过**的加长值。
# ★ 预算给**小**了是**可见的红**(TIMEOUT 栏会点名),不会静默变成绿 —— 方向是安全的。
declare -A BUDGET_OVERRIDE=(
	["team_spawn_smoke.gd"]=90          # 头注:`timeout 90`
	["duel_spawn_timeout_smoke.gd"]=150 # 头注:`timeout 150`(真拉起一个池外 worker)
	["spawn_pool_smoke.gd"]=120         # 头注:`timeout 120`
	["menu_theme_mirror_smoke.gd"]=120  # 头注:`timeout 120`
	["ui_palette_single_source_smoke.gd"]=120 # 头注:`timeout 120`
)

# ── 排除清单(`pattern|理由`)─────────────────────────────────────────────────
# pattern 是相对仓库根的路径,**支持 `*` 通配**。三类:
#   A 非 headless(取图 / 真渲染探针)—— 会弹窗抢用户的焦点,硬规定不许 agent 自跑。
#   B 真链路 / 多进程 / 占 7777 —— 会开端口或拉子进程;走 tests/run_real.sh。
#   C 登记在册的仪器 —— 见 docs/eng/registered-debt.md §一。
# ★ 任何一条**匹配不到文件**= 过期 ⇒ 入口直接红(防"改名后偷偷进批")。所以改探针名时
#   必须同步改这里。
EXCLUDED=(
	# ── A 非 headless(取图 / 真渲染)────────────────────────────────────────
	"tests/probe/combat_hud_visual_probe.tscn|A 非 headless:头注『必须带真实渲染,不能加 --headless』"
	"tests/probe/hue_tint_probe.tscn|A 非 headless:头注『必须真渲染』;headless 下 get_image() 返回 null ⇒ 量不到像素"
	"tests/probe/kh_l3_visual_probe.tscn|A 非 headless:头注『必须带真实渲染』"
	"tests/probe/kh_l4_visual_probe.tscn|A 非 headless:头注『必须带真实渲染』"
	"tests/probe/kh_visual_probe.tscn|A 非 headless:头注『必须带真实渲染』"
	"tests/probe/match_result_probe.tscn|A 非 headless:头注『必须真渲染;headless 下取不到像素』"
	"tests/probe/menu_shot_probe.tscn|A 非 headless:头注『必须不带 --headless』"
	"tests/probe/minimap_circle_probe.tscn|A 非 headless:头注『必须带真实渲染,不能加 --headless』"
	"tests/probe/render_forensics.tscn|A 非 headless:头注『窗口模式跑,非 headless』"
	"tests/probe/squash_stretch_probe.tscn|A 非 headless:头注『不要加 --headless —— 本探针要取图』"
	# ── B 真链路 / 多进程 / 占 7777 ────────────────────────────────────────
	"tests/probe/ground_net_probe.tscn|B 真链路:NetBus.start_server() 默认端口 = 7777 + 拉两个 royale_game 客户端子进程"
	"tests/probe/reconnect_probe.tscn|B 真链路:全部子进程由本进程 OS.create_process 拉起"
	"tests/probe/rejoin_probe.tscn|B 真链路:自当大厅(池外 29300)+ 拉子进程;由 tests/probe/rejoin_probe.sh 编排"
	"tests/probe/royale_bound_probe.tscn|B 真链路:NetBus.start_server() 默认端口 = 7777 + 拉客户端子进程"
	"tests/probe/royale_c2_probe.tscn|B 真链路:NetBus.start_server() 默认端口 = 7777 + 拉客户端子进程"
	"tests/probe/royale_probe.tscn|B 真链路:NetBus.start_server() 默认端口 = 7777 + 拉客户端子进程"
	"tests/probe/royale_soak_probe.tscn|B 真链路(压力):起大厅 + N 个真 royale_game 客户端;其 .sh 会 kill_port 7777"
	"tests/probe/team_match_probe.tscn|B 真链路:六人;自当大厅(池外 29200)+ 拉子进程"
	"tests/smoke/pvp_match_smoke.gd|B 真链路客户端:要 --role、且要 7777 上有大厅;由 tests/smoke/pvp_match_smoke.sh 编排"
	# ── C 登记在册的仪器(不属"便宜判据")────────────────────────────────────
	"tests/probe/brawl_rollback_probe.tscn|C 登记:registered-debt.md §一第 3 行(读 N>=4 自身在抖 + 变异下有一格假绿);docs/eng/tests.md『本批不跑,真要跑得给 --quit-after 30000』(约 8 分钟,失败形状 = 无裁决行 + exit 0)"
	# ── D 形状不合默认批口径 ──────────────────────────────────────────────
	'tests/smoke/menu_autotest.gd|D 形状:extends Node 但**没有同名 .tscn**(它不是独立入口,由 scenes/main_menu.gd 按 `-- --autotest-*` 挂到树根)'
)

# ── 不在本入口 glob 直径内、但要**显式交代**的候选(`pattern|理由`)────────────────
# 为什么单列:它们**不是测试**,而是 `tests/scripts/` 下的**诊断/迁移工具**。本入口只 glob
# `tests/smoke/*.gd` + `tests/probe/*.tscn`(R1 的口径),所以它们不进批 —— 但"不进批"这件事
# 必须**看得见**(否则就是"枚举会过期"那一类静默遗漏)。★ 也正因如此**不把** `tests/scripts/*.gd`
# 加进 glob:那等于让以后任何一个新工具脚本(可能原地写盘)**自动进回归批**。
OUT_OF_SCOPE=(
	"tests/scripts/convert_map.gd|工具(迁移):**原地写回** res://maps/*.cyrm。★ 且今天跑它**会毁图**:两张在库图已是 v4 二进制(CYRM\\x04),它认不出 v2/v3 标记 ⇒ 落进『v1 单字符 250x150』那一支并覆盖写回。"
	"tests/scripts/convert_map_v4.gd|工具(迁移):把 maps/ 全量转 v4 并**原地覆盖**。今天两张图已是 v4 ⇒ 它只会打『跳过』(此刻无害),但它是写盘工具、且没有任何判词行。"
	"tests/scripts/seam_analyze.gd|工具(一次性分析):读 res://tests/_seam_a_old.png / _seam_b_fixed.png —— **这两张图不在库里**(由 seam_screenshot.gd 生成)⇒ 今天跑它会 load 出 null 再解引用。无判词。"
	'tests/scripts/seam_screenshot.gd|工具 + **非 headless**(头注:需要真实渲染(非 --headless))⇒ 会弹窗抢焦点,硬规定不许 agent 自跑。'
)

# ── 承重安全检查的模式(见文件头「它的盲区」)────────────────────────────────
DANGER_RE='NetBus\.start_server\(|ENetMultiplayerPeer|OS\.create_process\('

ONLY=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
	case "$1" in
		--list) LIST_ONLY=1; shift ;;
		--only) ONLY="${2:-}"; shift 2 ;;
		--only=*) ONLY="${1#--only=}"; shift ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) echo "[run_all] unknown arg: $1" >&2; exit 2 ;;
	esac
done

ascii_only() { LC_ALL=C sed 's/[^ -~]//g'; }

# ── 已知红基线(tests/known_red.txt)────────────────────────────────────────
# 为什么需要它:本仓自己的话 —— `tests/probe/allscript_probe.gd:14` 的"**一条永远红的闸等于
# 没有闸**"(原话在 `docs/eng/tests.md` 的同类讨论里)。当时钟摆的另一头是:`run_all.sh` 一建
# 起来就**永远** FAIL(3 支既有红)⇒ 后面几个工作包**没法**用它判断"我这次改坏了没有"。
# 所以:基线内的红 = `KNOWN-RED`,**不进**新红计数、**不**改全批判词为全绿(**永远**印出文件名
# 与条数),但也不再挡路。★ 要销一条就把行**删掉**(与 `registered-debt.md` §三"销掉时删行"同规)。
KNOWN_RED_FILE="tests/known_red.txt"
declare -A KNOWN_RED_CLASS=()
KNOWN_RED_N=0
BASELINE_BAD=0                  # 基线文件本身的问题(空行 / 没理由 / 类别不合法)

# 基线文件的一行 = `路径 类别 理由…`(理由**必填**;`#` 开头是注释;空行 = 违规)。
# 类别 ∈ {OK+RC, FAIL, NO-VERDICT, TIMEOUT} 或 `*`(任意红类)。
load_known_red() {
	local line path cls reason n=0
	[ -f "$KNOWN_RED_FILE" ] || { KNOWN_RED_N=0; return 0; }
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		case "$line" in
			''|' '*|$'\t'*)
				# 注意:这里只拦**整行空白**,不拦行首缩进(理由里允许有空格)
				if [ -z "${line//[[:space:]]/}" ]; then
					echo "[baseline] FATAL: $KNOWN_RED_FILE:$n is a blank line -- every line must be 'path class reason'."
					BASELINE_BAD=$((BASELINE_BAD + 1))
					continue
				fi
				;;
		esac
		case "$line" in
			'#'*) continue ;;
		esac
		# ★ `set -f`:类别那一栏可能是 `*`(任意红类),不关 glob 会被**文件名展开**吃掉。
		set -f
		# shellcheck disable=SC2086
		set -- $line
		set +f
		path="${1:-}"; cls="${2:-}"
		reason="${line#*"$path"}"; reason="${reason#*"$cls"}"; reason="${reason#"${reason%%[![:space:]]*}"}"
		if [ -z "$path" ] || [ -z "$cls" ] || [ -z "$reason" ]; then
			echo "[baseline] FATAL: $KNOWN_RED_FILE:$n needs 'path class reason' (reason is mandatory): $line"
			BASELINE_BAD=$((BASELINE_BAD + 1))
			continue
		fi
		case "$cls" in
			OK+RC|FAIL|NO-VERDICT|TIMEOUT|'*') ;;
			*) echo "[baseline] FATAL: $KNOWN_RED_FILE:$n has unknown class '$cls' (use OK+RC|FAIL|NO-VERDICT|TIMEOUT|*)."
			   BASELINE_BAD=$((BASELINE_BAD + 1)); continue ;;
		esac
		KNOWN_RED_CLASS["$path"]="$cls"
	done <"$KNOWN_RED_FILE"
	KNOWN_RED_N=${#KNOWN_RED_CLASS[@]}
	return 0
}

# 判词判据:
#   · 边界类 = `[^A-Za-z0-9]`(**含 `_`**)—— 否则 `NET_INPUT_OK` 这种「下划线接 OK」的判词
#     会被判成 NO-VERDICT(network_input_smoke 首跑实测就是这么假红的)。
#   · FAIL 侧放宽到 `FAIL[A-Z]{0,4}` —— 覆盖仓库现网出现过的 FAIL / FAILED / FAILURES /
#     `[FAIL]` / `FAIL(` 形状(`enemy_logic_smoke` 失败时打的是 `FAILURES: ...`,只认裸 FAIL 会漏)。
FAIL_RE='(^|[^A-Za-z0-9])FAIL[A-Z]{0,4}([^A-Za-z0-9]|$)'
OK_RE='(^|[^A-Za-z0-9])OK([^A-Za-z0-9]|$)'

# 单支分类:$1 = 日志路径,$2 = 退出码 ⇒ 设置 VERDICT / VLINE / VLINE_N
# VERDICT ∈ {OK, OK+RC, FAIL, NO-VERDICT, TIMEOUT};见文件头「判据分层」。
classify() {
	local log="$1" rc="$2" hit=""
	VLINE_N="-"
	if [ "$rc" -eq 124 ]; then
		VERDICT="TIMEOUT"; VLINE="(killed by outer timeout)"
		return
	fi
	# FAIL 优先(fail-closed):一个跑出过 FAIL 的支即使后面又打了 OK 也不算绿。
	hit=$(grep -nE "$FAIL_RE" "$log" 2>/dev/null | head -1)
	if [ -n "$hit" ]; then VERDICT="FAIL"; VLINE_N="${hit%%:*}"; VLINE="${hit#*:}"; return; fi
	hit=$(grep -nE "$OK_RE" "$log" 2>/dev/null | tail -1)
	if [ -n "$hit" ]; then
		VLINE_N="${hit%%:*}"; VLINE="${hit#*:}"
		if [ "$rc" -eq 0 ]; then VERDICT="OK"; else VERDICT="OK+RC"; VLINE="(rc=$rc) $VLINE"; fi
		return
	fi
	VERDICT="NO-VERDICT"; VLINE=""
}

# 该支声明的条数闸(真相源 = 它自己的 .gd 源码)⇒ 设置 GATE(空 = 无闸)
gate_of() {
	local src="$1"
	GATE=""
	[ -f "$src" ] || return 0
	GATE=$(grep -oE 'EXPECTED_CHECKS[[:space:]]*:=[[:space:]]*[0-9]+' "$src" 2>/dev/null |
		head -1 | grep -oE '[0-9]+')
}

# ── 枚举(glob;绝不写死清单)────────────────────────────────────────────
load_known_red
shopt -s nullglob
ENUM=()
for f in tests/smoke/*.gd; do ENUM+=("$f"); done
for f in tests/probe/*.tscn; do ENUM+=("$f"); done
shopt -u nullglob

N_ENUM=${#ENUM[@]}
if [ "$N_ENUM" -eq 0 ]; then
	echo "[enum] enumerated 0 files -- glob matched nothing. Aborting (a silent empty batch would still print OK)."
	echo "RUN_ALL FAIL(0 支 / 枚举到 0 支)"
	exit 1
fi

# 排除项是否都真的匹配到了文件(= 是否过期)
STALE=()
for line in "${EXCLUDED[@]}"; do
	pat="${line%%|*}"
	found=0
	for f in "${ENUM[@]}"; do
		# shellcheck disable=SC2053
		if [[ "$f" == $pat ]]; then found=1; break; fi
	done
	[ "$found" -eq 1 ] || STALE+=("$pat")
done

# 分桶 + 组装运行清单
RUN_MODE=(); RUN_PATH=(); RUN_SRC=(); RUN_TARGET=(); RUN_BUDGET=()
N_PROBE_ENUM=0; N_EXCLUDED=0; N_FILTERED=0
for f in "${ENUM[@]}"; do
	case "$f" in
		tests/probe/*.tscn) N_PROBE_ENUM=$((N_PROBE_ENUM + 1)) ;;
	esac
done
N_SMOKE_ENUM=$((N_ENUM - N_PROBE_ENUM))

for f in "${ENUM[@]}"; do
	skip=0
	for line in "${EXCLUDED[@]}"; do
		pat="${line%%|*}"
		# shellcheck disable=SC2053
		if [[ "$f" == $pat ]]; then skip=1; break; fi
	done
	if [ "$skip" -eq 1 ]; then N_EXCLUDED=$((N_EXCLUDED + 1)); continue; fi

	case "$f" in
		tests/smoke/*.gd)
			first=$(head -1 "$f" | tr -d '\r')
			if [[ "$first" == extends\ SceneTree* ]]; then
				mode=smoke; src="$f"; target="res://$f"
			else
				# `extends Node` / `Control` 等 ⇒ 必须走同名 .tscn(跑法见 docs/eng/tests.md)
				tscn="${f%.gd}.tscn"
				if [ ! -f "$tscn" ]; then
					echo "[enum] FATAL: $f is '${first}', but has no sibling ${tscn##*/} -- add it to EXCLUDED with a reason."
					echo "RUN_ALL FAIL(0 支 / $f 既没跑也没排除)"
					exit 1
				fi
				mode=scene; src="$f"; target="res://$tscn"
			fi
			;;
		tests/probe/*.tscn)
			mode=scene; src="${f%.tscn}.gd"; target="res://$f"
			;;
		*) echo "[enum] FATAL: unexpected enumerated path $f"; exit 1 ;;
	esac

	# 承重安全检查(只扫**整行注释以外**的文本)
	if [ -f "$src" ]; then
		if grep -vE '^[[:space:]]*#' "$src" | grep -qE "$DANGER_RE"; then
			echo "[enum] FATAL: $f opens a socket / spawns a process (matches: $DANGER_RE)."
			echo "        Either EXCLUDE it with a reason or fix the probe -- it must not enter the headless batch."
			echo "RUN_ALL FAIL(0 支 / $f trip the 7777-guard)"
			exit 1
		fi
	fi

	base=$(basename "$f"); base="${base%.*}"
	budget=$([ "$mode" = smoke ] && echo "$SMOKE_BUDGET" || echo "$SCENE_BUDGET")
	if [ -n "${BUDGET_OVERRIDE[$base]:-}" ]; then budget="${BUDGET_OVERRIDE[$base]}"; fi

	if [ -n "$ONLY" ]; then
		case "$f" in *"$ONLY"*) ;; *) continue ;; esac
	fi

	RUN_MODE+=("$mode"); RUN_PATH+=("$f"); RUN_SRC+=("$src")
	RUN_TARGET+=("$target"); RUN_BUDGET+=("$budget")
done

N_RUN=${#RUN_PATH[@]}

# ── 打印环境口径 + 清单头 ────────────────────────────────────────────────
echo "==== run_all: headless default batch ===="
echo "[env] GODOT      = $GODOT"
echo "[env] version    = $("$GODOT" --version 2>/dev/null | head -1)"
if lobby_alive; then echo "[env] lobby_alive = true  (7777 has a live lobby -- this batch does NOT touch 7777)";
else echo "[env] lobby_alive = false"; fi
echo "[env] godot procs before = $(tasklist 2>/dev/null | grep -ci godot || true)"
echo "[env] log dir    = $LOG_DIR"
echo "[env] quit-after = $QUIT_AFTER frames (scene probes) ; budget: smoke=${SMOKE_BUDGET}s scene=${SCENE_BUDGET}s (+per-file overrides)"
echo "[enum] enumerated $N_ENUM files (tests/smoke/*.gd = $N_SMOKE_ENUM, tests/probe/*.tscn = $N_PROBE_ENUM)"
echo "[enum] excluded   $N_EXCLUDED files of the enumeration ($(( ${#EXCLUDED[@]} )) rules) -> see --list"
echo "[enum] out of glob scope: ${#OUT_OF_SCOPE[@]} files (tests/scripts/*.gd tools) -> see --list"
echo "[enum] running    $N_RUN files${ONLY:+ (filter: --only $ONLY)}"

if [ "$LIST_ONLY" -eq 1 ]; then
	echo
	echo "---- EXCLUDED (pattern | reason) ----"
	for line in "${EXCLUDED[@]}"; do
		echo "  ${line%%|*}"
		echo "      reason: ${line#*|}"
	done
	echo
	echo "---- OUT OF GLOB SCOPE (pattern | reason) ----"
	for line in "${OUT_OF_SCOPE[@]}"; do
		echo "  ${line%%|*}"
		echo "      reason: ${line#*|}"
	done
	echo
	echo "---- KNOWN-RED BASELINE ($KNOWN_RED_FILE; $KNOWN_RED_N 条) ----"
	if [ -f "$KNOWN_RED_FILE" ]; then
		grep -vE '^[[:space:]]*(#|$)' "$KNOWN_RED_FILE" | sed 's/^/  /'
	else
		echo "  (no baseline file -- every red counts as new)"
	fi
	echo
	echo "---- STALE EXCLUSIONS (${#STALE[@]}) ----"
	for p in "${STALE[@]:-}"; do [ -n "$p" ] && echo "  $p  (matched no file -- rename drift?)"; done
	echo
	echo "---- RUN LIST ($N_RUN) ----"
	for i in $(seq 0 $((N_RUN - 1))); do
		printf '  %-8s %-4ss  %s\n' "${RUN_MODE[$i]}" "${RUN_BUDGET[$i]}" "${RUN_PATH[$i]}"
	done
	# ★ `--list` **也要**为过期排除项 / 烂基线变红:否则它会把"清单已经烂了"报成 exit 0
	#   —— 而那种形状(= 一条排查看起来生效、却匹配不到任何文件)正是"改名后的探针悄悄进批"的入口。
	if [ "${#STALE[@]}" -gt 0 ] || [ "$BASELINE_BAD" -gt 0 ]; then
		echo
		echo "RUN_ALL FAIL(${#STALE[@]} 条过期排除项 + $BASELINE_BAD 条基线问题 / 一条测试都没跑)"
		exit 1
	fi
	exit 0
fi

if [ "$N_RUN" -eq 0 ]; then
	echo "[enum] running 0 files -- nothing would be verified. Aborting."
	echo "RUN_ALL FAIL(0 支 / 枚举到 $N_ENUM 支,过滤后 0 支)"
	exit 1
fi

mkdir -p "$LOG_DIR/smoke" "$LOG_DIR/probe"
: >"$SUMMARY"
: >"$FAILED_LIST"

{
	echo "run_all summary (UTF-8, 判词原文;控制台那份是剥掉非 ASCII 的)"
	echo "date: $(date '+%Y-%m-%d %H:%M:%S')"
	echo "GODOT: $GODOT"
	echo "version: $("$GODOT" --version 2>/dev/null | head -1)"
} >>"$SUMMARY"

printf '%-50s %-11s %-6s %4s  %-34s %s\n' "FILE" "VERDICT" "GATE" "SEC" "LOG" "VERDICT LINE (ASCII-stripped)"
printf '%-50s %-11s %-6s %4s  %-34s %s\n' "--------------------------------------------------" "-----------" "------" "----" "----------------------------------" "-------------------------------"

N_OK=0; N_FAIL=0; N_NV=0; N_TO=0; N_OKRC=0; GATE_SUM=0
N_NEWRED=0; N_KNOWN=0
OKRC_LIST=""; KNOWN_LIST=""; NEWRED_LIST=""
SEEN_KNOWN=""; SEEN_RUN=""
for i in $(seq 0 $((N_RUN - 1))); do
	mode="${RUN_MODE[$i]}"; path="${RUN_PATH[$i]}"; src="${RUN_SRC[$i]}"
	target="${RUN_TARGET[$i]}"; budget="${RUN_BUDGET[$i]}"

	sub=probe; case "$path" in tests/smoke/*) sub=smoke ;; esac
	base=$(basename "$path"); base="${base%.*}"
	log="$LOG_DIR/$sub/$base.log"

	t0=$(date +%s)
	if [ "$mode" = smoke ]; then
		timeout "$budget" "$GODOT" --headless --path . -s "$target" >"$log" 2>&1
		rc=$?
	else
		timeout "$budget" "$GODOT" --headless --path . --quit-after "$QUIT_AFTER" "$target" >"$log" 2>&1
		rc=$?
	fi
	t1=$(date +%s)
	sec=$((t1 - t0))

	classify "$log" "$rc"
	gate_of "$src"
	SEEN_RUN="$SEEN_RUN$path"$'\n'

	# 红的三类(FAIL / NO-VERDICT / TIMEOUT)再看基线:命中且**类别对得上** ⇒ KNOWN-RED
	DISPLAY="$VERDICT"
	case "$VERDICT" in
		OK) N_OK=$((N_OK + 1)); [ -n "$GATE" ] && GATE_SUM=$((GATE_SUM + GATE)) ;;
		OK+RC)
			# 退出码不是判据 ⇒ 不算红;但**单独成类**印出来,不许混进 OK
			N_OKRC=$((N_OKRC + 1))
			OKRC_LIST="$OKRC_LIST$path(rc=$rc) "
			;;
		FAIL|NO-VERDICT|TIMEOUT)
			bc="${KNOWN_RED_CLASS[$path]:-}"
			if [ -n "$bc" ] && { [ "$bc" = "$VERDICT" ] || [ "$bc" = "*" ]; }; then
				N_KNOWN=$((N_KNOWN + 1)); DISPLAY="KNOWN-RED"
				KNOWN_LIST="$KNOWN_LIST$path [$VERDICT]\n"
				SEEN_KNOWN="$SEEN_KNOWN$path"$'\n'
			else
				N_NEWRED=$((N_NEWRED + 1))
				if [ -n "$bc" ]; then
					NEWRED_LIST="$NEWRED_LIST$path [$VERDICT, baseline says $bc]\n"
				else
					NEWRED_LIST="$NEWRED_LIST$path [$VERDICT]\n"
				fi
			fi
			case "$VERDICT" in
				FAIL) N_FAIL=$((N_FAIL + 1)) ;;
				NO-VERDICT) N_NV=$((N_NV + 1)) ;;
				TIMEOUT) N_TO=$((N_TO + 1)) ;;
			esac
			;;
	esac

	vline_disp=$(printf '%s' "$VLINE" | ascii_only | tr -s ' ' | cut -c1-72)
	printf '%-50s %-11s %-6s %4s  %-34s %s\n' "$path" "$DISPLAY" "${GATE:--}" "$sec" "$sub/$base.log" "$vline_disp"

	# 完整判词原文(含中文)进 summary
	{
		printf '%s\t%s\tgate=%s\trc=%s\t%ss\tline=%s\t%s\n' "$DISPLAY" "$path" "${GATE:--}" "$rc" "$sec" "$VLINE_N" "$log"
		printf '    line %s: %s\n' "$VLINE_N" "$VLINE"
	} >>"$SUMMARY"

	if [ "$DISPLAY" != "OK" ] && [ "$DISPLAY" != "OK+RC" ]; then
		{
			echo "$DISPLAY  $path  (rc=$rc, ${sec}s)  log=$log"
			echo "    line $VLINE_N: $VLINE"
		} >>"$FAILED_LIST"
	fi
done

# 基线里**没有任何红与之对应**的条目 ⇒ 过期(修好了却没删行,或路径写错)⇒ 也是红的。
# ★ 只判**这一趟真的跑过**的文件:配 `--only <子集>` 时,没跑到的基线条目"没红"是正常的
#   (若按"整张基线"判,`--only` 会把每一趟都判红,那条路就废了)。
STALE_BASELINE=0
if [ "$KNOWN_RED_N" -gt 0 ]; then
	for p in "${!KNOWN_RED_CLASS[@]}"; do
		case "$SEEN_RUN" in
			*"$p"$'\n'*) ;;   # 这一趟没跑它 ⇒ 不判
			*) continue ;;
		esac
		case "$SEEN_KNOWN" in
			*"$p"$'\n'*) ;;
			*) echo "[baseline] STALE: $p is listed in $KNOWN_RED_FILE, was run this time, but did not go red -- delete the row (see that file's header)."
			   STALE_BASELINE=$((STALE_BASELINE + 1)) ;;
		esac
	done
fi

N_PROCS_AFTER=$(tasklist 2>/dev/null | grep -ci godot || true)

echo
echo "==== notes ===="
echo "[env] godot procs after  = $N_PROCS_AFTER"
if [ "$N_PROCS_AFTER" -gt 0 ]; then
	echo "[env] WARNING: godot processes are still alive after the batch. The default batch does not use the"
	echo "      7800-8299 pool, so this is not expected to poison run_real.sh -- but check before a real-link run."
fi
if [ "${#STALE[@]}" -gt 0 ]; then
	echo "[enum] STALE EXCLUSIONS (${#STALE[@]}) -- pattern matched no file. A renamed probe leaves its old rule dead:"
	for p in "${STALE[@]}"; do echo "         $p"; done
fi
if [ -n "$OKRC_LIST" ]; then
	echo "[ok+rc] verdict is affirmative but exit code != 0 ($N_OKRC) -- NOT counted as red, but never"
	echo "        mixed into OK (exit code is not a criterion; a run can crash on exit after OK):"
	echo "        $OKRC_LIST"
fi
echo "[logs] full text: $LOG_DIR/smoke/*.log , $LOG_DIR/probe/*.log"
echo "[logs] summary  : $SUMMARY"
echo "[logs] failures : $FAILED_LIST"
echo "[logs] baseline : $KNOWN_RED_FILE"

# ★★ 已登记红**永远**印出来(名字 + 条数)—— 哪怕全批判词是 OK 形状。
#    防的正是"OK 被读成全绿"那件事。
echo
if [ "$N_KNOWN" -gt 0 ]; then
	echo "[known-red] $N_KNOWN 支已登记(按 $KNOWN_RED_FILE 不计入新红;销掉时请删行):"
	printf '%b' "$KNOWN_LIST" | sed 's/^/  KNOWN-RED  /'
else
	echo "[known-red] 0 支($KNOWN_RED_FILE 里 $( [ "$KNOWN_RED_N" -eq 0 ] && echo 0 || echo "$KNOWN_RED_N" ) 条)$( [ "$KNOWN_RED_N" -eq 0 ] && echo '' || echo ' -- 但本次一条都没红:可能已修好,请删行' )"
fi
if [ "$N_NEWRED" -gt 0 ]; then
	echo "[new-red] $N_NEWRED 支新红(不在基线里):"
	printf '%b' "$NEWRED_LIST" | sed 's/^/  NEW-RED    /'
fi
if [ "$BASELINE_BAD" -gt 0 ]; then
	echo "[baseline] $BASELINE_BAD 条基线文件问题(空行 / 缺理由 / 类别不合法)"
fi
if [ "$STALE_BASELINE" -gt 0 ]; then
	echo "[baseline] $STALE_BASELINE 条基线条目已过期(这次没红)"
fi

GATE_BAD=$(( ${#STALE[@]} + BASELINE_BAD + STALE_BASELINE ))
if [ "$N_NEWRED" -gt 0 ] || [ "$GATE_BAD" -gt 0 ]; then
	echo
	echo "==== 新红 / 闸问题 ===="
	echo "counts: total=$N_RUN ok=$N_OK ok+rc=$N_OKRC fail=$N_FAIL no-verdict=$N_NV timeout=$N_TO known-red=$N_KNOWN new-red=$N_NEWRED"
	echo "        stale-exclusions=${#STALE[@]} baseline-problems=$BASELINE_BAD stale-baseline=$STALE_BASELINE"
	if [ "$N_NEWRED" -gt 0 ]; then printf '%b' "$NEWRED_LIST" | sed 's/^/  NEW-RED  /'; fi
	if [ -s "$FAILED_LIST" ]; then cat "$FAILED_LIST" | ascii_only; fi
	for p in "${STALE[@]:-}"; do [ -n "$p" ] && echo "  STALE-EXCLUSION  $p"; done
	echo
	if [ "$GATE_BAD" -gt 0 ]; then
		echo "RUN_ALL FAIL($N_NEWRED 支新红 + $N_KNOWN 支已登记 + $GATE_BAD 条闸问题)"
	else
		echo "RUN_ALL FAIL($N_NEWRED 支新红 + $N_KNOWN 支已登记)"
	fi
	exit 1
fi

echo
if [ "$N_KNOWN" -gt 0 ]; then
	echo "RUN_ALL OK-WITH-KNOWN-RED($N_RUN 支,其中 $N_KNOWN 支已登记)"
else
	echo "RUN_ALL OK($N_RUN 支 / $GATE_SUM 断言闸)"
fi
exit 0
