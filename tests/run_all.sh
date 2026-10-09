#!/usr/bin/env bash
# tests/run_all.sh —— 聚合回归入口(**headless 默认批**)。
#
# 用法:
#   bash tests/run_all.sh                 # 全批
#   bash tests/run_all.sh --list          # 只列清单(跑哪些 / 排除哪些 + 每条理由),不跑
#   bash tests/run_all.sh --only probe    # 只跑相对路径里含 "probe" 的支(便宜的子集)
#
# 判据(**一律 grep 文本;`rc` 不用来判红** —— 它只做两件事:把"判词肯定"那一类分 `OK`/`OK+RC`、
#   以及识别外壳超时 `rc == 124`。**"红不红"完全由判词文本决定**):
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
#     `tests/probe/allscript_probe.gd:14` 的"一条**永远红**的闸等于没有闸" —— 一建起来就永远 FAIL
#     的入口,后面几个包**没法**拿它判断"我这次改坏了没有"。
#     ★ 销一条就要**删行**;"修好了却没删行"= 过期基线条目 ⇒ 也红(与 §三「销掉时删行」同规)。
#   · 全批判词:
#       `RUN_ALL OK(n runs / m gated-assertions)`                         -- no red at all
#       `RUN_ALL OK-WITH-KNOWN-RED(n runs, k registered)`                -- only registered reds
#       `RUN_ALL FAIL(r new-red + k registered)`                          -- new reds / gate problems
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
#   · ★★ **ASCII 的射程(2026-10-05 订正;评审 I3)**:要说清"哪一部分"是 ASCII,别两处都说满 ——
#     - **机器可读的那部分** = **全批判词行**(`RUN_ALL ...`)**与逐支表那一栏**:**纯 ASCII**。
#       (原先全批判词行掺中文 ⇒ 在 GBK 控制台上是乱码,而 AGENTS.md / README / known_red.txt
#        把它当机器可读判词登记 —— 那条"保证"在**最关键的地方为假**。现已改成 ASCII。)
#     - **给人读的那部分** = `[env]`/`[enum]`/`[baseline]`/`[known-red]`/`[new-red]`/`[ok+rc]` 这些
#       **说明行**与 `--list` 的**排除理由**:**原样打印(含中文)**,不过 `ascii_only`
#       (剥掉中文会让理由变成一串残渣,反而没人能读)。
#     - 判词**原文**(含中文)一律落在 `tests/.run_all_logs/summary.log`(UTF-8)与每支日志里。
#     - ★ 逐支表那一栏是 `ascii_only` 后的形态 —— 判词 token 本身是 ASCII,所以它一定还在。
set -u

# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# ── 自检(2026-10-05 修复轮3):**双引号里的反引号**会被 bash 当命令替换执行 ─────────
# 由来(重审的一手证据):`EXCLUDED` 段里那两条**双引号**数组元素含反引号 ⇒ source 时打出
#   **10 行 `command not found`**,而且其中的 `print` **真的执行了** `C:\Windows\system32\print.exe`,
#   把它的 stdout 注进了 `--list` 的排除理由(用户可见输出被污染;每次调用还会**执行一个系统程序**)。
# ★ 去掉什么才会红:把那两条改回**双引号** ⇒ 这里立刻点名并退出 1(它就是为这条设的)。
# ★ 射程(别读多):只查**以 `"` 开头的行**(数组元素那种形态)—— 那是这类事故的唯一形态;
#   `echo "…`…`…"` 那种**有意**的命令替换**不在**射程内(本脚本里没有,也不该有)。
selflint_no_backtick_in_dq() {
	local hits
	hits=$(grep -nP '^[[:space:]]*"[^"]*`' "$0" 2>/dev/null || true)
	if [ -n "$hits" ]; then
		echo "[selflint] FATAL: a backtick sits inside a double-quoted element -- bash runs it as command substitution:"
		printf '%s\n' "$hits"
		echo "          Fix: use single quotes (or drop the backticks). See this function's header."
		return 1
	fi
	# ★ 通过时**也**打一行:否则"启动闸跑过且没误伤"只能靠"输出里没有 FATAL"去**推断**,
	#   而这次全量跑的**目的**正是"证明它在真跑路径上被走过、且没误报"(控制器 2026-10-05 要求)。
	echo "[selflint] ok: no backtick inside a double-quoted element"
	return 0
}
if ! selflint_no_backtick_in_dq; then
	echo "RUN_ALL FAIL(0 runs / selflint: backtick inside double quotes)"
	exit 1
fi

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
# ★★ 2026-10-08(测试经济 D2/D5):原 A 组(10 支非 headless 视觉探针)与原 E 组(8 支无判词/词汇不符的
#   读数工具 + 1 支 helper)、C 组的 `brawl_rollback_probe`(自陈读数不可信)、D 组的 `menu_autotest`
#   **都不再住在本入口的 glob 直径内** ⇒ 相应排除规则一并删除(留着就是"匹配不到文件"的过期规则,
#   本块开头那条闸会直接红)。它们的去处与跑法见 `tests/manual/README.md`;判据与理由见
#   `docs/eng/test-economy.md`(D2 仪器不是守卫 / D5 只证明别的东西 / K1-K5 什么才值得留)。
# ★★ 2026-10-09(测试面削减 90%):本表 **9 条 → 4 条** —— 删掉了 5 条指向**已删文件**的规则
#   (`ground_net_probe` / `reconnect_probe` / `royale_bound_probe` / `royale_c2_probe` / `royale_probe`)。
#   台账:`docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md`。
#   ★ 留下的这 4 条**必须留**:那 4 支仍在枚举集里(`smoke/*.gd` 或 `probe/*.tscn`),
#     清掉规则 ⇒ 承重安全检查(`DANGER_RE`)立刻 FATAL,或它们悄悄进批**占 7777**。
EXCLUDED=(
	# ── B 真链路 / 多进程 / 占 7777 ────────────────────────────────────────
	"tests/probe/rejoin_probe.tscn|B 真链路:自当大厅(池外 29300)+ 拉子进程;由 tests/probe/rejoin_probe.sh 编排"
	"tests/probe/royale_soak_probe.tscn|B 真链路(压力):起大厅 + N 个真 royale_game 客户端;其 .sh 会 kill_port 7777"
	"tests/probe/team_match_probe.tscn|B 真链路:六人;自当大厅(池外 29200)+ 拉子进程"
	"tests/smoke/pvp_match_smoke.gd|B 真链路客户端:要 --role、且要 7777 上有大厅;由 tests/smoke/pvp_match_smoke.sh 编排"
)

# ── 不在本入口 glob 直径内、但要**显式交代**的候选(`pattern|理由`)────────────────
# 为什么单列:它们**不是测试**,而是 `tests/scripts/` 下的**诊断/迁移工具**。本入口只 glob
# `tests/smoke/*.gd` + `tests/probe/*.tscn`(R1 的口径),所以它们不进批 —— 但"不进批"这件事
# 必须**看得见**(否则就是"枚举会过期"那一类静默遗漏)。★ 也正因如此**不把** `tests/scripts/*.gd`
# 加进 glob:那等于让以后任何一个新工具脚本(可能原地写盘)**自动进回归批**。
OUT_OF_SCOPE=(
	"tests/scripts/convert_map.gd|工具(迁移):**原地写回** res://maps/*.cyrm。★ 且今天跑它**会毁图**(债单:registered-debt.md §六.19):两张在库图已是 v4 二进制(CYRM\\x04),它认不出 v2/v3 标记 ⇒ 落进『v1 单字符 250x150』那一支并覆盖写回。"
	"tests/scripts/convert_map_v4.gd|工具(迁移):把 maps/ 全量转 v4 并**原地覆盖**。今天两张图已是 v4 ⇒ 它只会打『跳过』(此刻无害),但它是写盘工具、且没有任何判词行。"
	"tests/scripts/seam_analyze.gd|工具(一次性分析):读 res://tests/_seam_a_old.png / _seam_b_fixed.png —— **这两张图不在库里**(债单:registered-debt.md §六.20)(由 seam_screenshot.gd 生成)⇒ 今天跑它会 load 出 null 再解引用。无判词。"
	'tests/scripts/seam_screenshot.gd|工具 + **非 headless**(头注:需要真实渲染(非 --headless))⇒ 会弹窗抢焦点,硬规定不许 agent 自跑。'
)

# ── 承重安全检查的模式(见文件头「它的盲区」)────────────────────────────────
DANGER_RE='NetBus\.start_server\(|ENetMultiplayerPeer|OS\.create_process\('

ONLY=""
LIST_ONLY=0
CLASSIFY_CHECK=0
while [ $# -gt 0 ]; do
	case "$1" in
		--list) LIST_ONLY=1; shift ;;
		--classify-check) CLASSIFY_CHECK=1; shift ;;
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
		if [ -n "${KNOWN_RED_CLASS[$path]:-}" ]; then
			# ★ M5 修(2026-10-05):**重复路径**原先被关联数组静默折叠(后者覆盖前者)。
			echo "[baseline] FATAL: $KNOWN_RED_FILE:$n lists '$path' twice -- duplicate rows are a baseline problem (the later row used to silently win)."
			BASELINE_BAD=$((BASELINE_BAD + 1))
			continue
		fi
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
#   · ★★ **OK 侧 = "判词三条件"(2026-10-05 三轮;评审 C2 + 重审 C2 残余 + Task 6 假红)**。
#     三条**同时**满足才算判词肯定:
#     ① **形状**:`ALL-OK`,或 `OK` 紧跟行尾/一个标点(即"OK 后面不许再跟空白+正文");
#     ② **位置(2026-10-05 Task 6 改口径;修复轮 1 补第四支)**:命中行必须是**非引擎噪声行**,且它
#        **之后不许再出现"判定形状"的行**(= 判词形状 / 失败 / **分项标记** / **本仓自己的失败·中止词汇**);
#     ③ **不是分项标记**:命中行**不许**是方括号标签(`[OK` / `[ALL-OK`)也**不许**带 `✓`/`✗`。
#     **★ "什么才算推翻判词"(判据的权威定义;判词**之后**的行分三类)**:
#       (a) **引擎噪声行**(定义见下)⇒ **永不推翻**。实测(2026-10-05 快照,盘上 112 份)**28 份**的判词
#           后面就跟这类行(含本支自己:`haste_probe` 判词后面是 `ERROR: PlayerInput…` + backtrace)。
#           ★ 这个数是**快照相关**的(语料一重跑就变;更早那份快照上是 30 ⇒ 评审 M-2),复算法见下。
#           ★ **别读多**:这里**不是**"引擎报错被忽略",而是"判词一旦完整打出来,本入口就**不再**为
#           它之后发生的事负责"—— 与「有意保留 `OK+RC`」(判词 OK、退出时 SIGSEGV 不算红)是**同一条**立场。
#       (b) **判定形状的行** ⇒ **推翻**。四支各有归属:
#           · 判词形状(`OK_RE`)—— 由 `tail -1` 取**最后一条**命中兜住(后面又打了判词行 ⇒ 算数的是后一条);
#           · 失败行(`FAIL_RE`)—— 由**上面的 FAIL 优先**兜住,而且**更重**(整支判 `FAIL` 而不是 `NO-VERDICT`);
#           · 分项标记(`ITEM_RE` = `[OK`/`[ALL-OK`/`✓`/`✗`)与
#             **本仓自己的失败·中止词汇(`SELFFAIL_RE`)** —— **② 代码里真正要查的两支**
#             (前两支结构上不可能落到这里)。
#     **★★ 判准(为什么这些词算"判定形状"、而不是"良性尾行";2026-10-05 修复轮 1,评审 I-1)**:
#       **凡在表达"本支的断言/检查有失败、或没有跑完"的行,都是判定形状。**
#       它与 (a) 类(引擎在说话)和 (c) 类(脚本补一句**说明**)的区别只有一条:**它在对本次运行下判断**。
#       ★ 为什么必须补这一支(评审 I-1 的一手证据):本仓中文失败汇总是**现网词汇**
#       (`grep -rn 'print.*失败\|不通过' tests/{smoke,probe}/*.gd | grep -vcE 'FAIL|✗'` = **33 行**,
#       例 `tests/smoke/app_info_smoke.gd:43`),而 `FAIL_RE` 只认 `FAIL`/`FAILURES` 这类**大写英文** ⇒
#       判词后再出现一句 `APP INFO SMOKE: 3 条失败`:旧口径 `NO-VERDICT`(**归红**),
#       Task 6 初版落 `OK` / **`OK+RC`(本入口明说"不算红")** ⇒ **真红被洗白**。
#     **★ 落地的清单(每项挡什么 / 边界在哪)**:判准是上面那句话,清单只是**今天实现它的词汇** ——
#       · `失败` / `不通过` / `未通过` —— 挡现网的**中文**失败汇总(`N 条失败`、`断言失败`)。
#       · `[Ff]ail` —— 挡**小写/混合大小写**英文失败词(`assertion failed`、`failures=3`);
#         大写 `FAIL` 由上面的 `FAIL_RE` 全局兜住(到这里根本轮不上)。
#       · `[Aa]borted` / `[Dd]id not (run|execute)` / `[Nn]ot executed` / `checks?[[:space:]]+ran`
#         —— 挡"**没跑完 / 一条都没跑**"(`check 12/86 executed; run aborted`、`0 checks ran (early-exit)`)。
#       · ★ **有意不收** `跳过` / `skipped`:本任务要放行的那一行 `  notes: 敌速采样不足…:对比跳过`
#         说的正是"**某一项**因样本不足没测",不是"本支的检查没跑完";收了它就把要修的假红做回来。
#         ⇒ **代价(照实)**:若哪天某支用"跳过"表达"整支没跑完",**本判据读不出来**(落 (c) 类放行)。
#       · ★ **清单之外**的行一律落 (c) 类**放行**;新措辞该按**判准**并进来 —— 不是让 (c) 悄悄兜走,
#         也不是"再加一个词就完事"(那正是本仓"枚举会过期"的病)。
#       (c) **其它任何良性尾行**(`notes: …`、一句说明、**未见过措辞**的引擎消息)⇒ **放行**。
#     **为什么必须三条**(每一轮都是被真实反例逼出来的;记的是**当时那一步**在挡什么):
#       - ① 的形状收紧("OK 后面不许再跟空白+正文")挡的是 `[squash_host] OK     6 ( … )` 这类
#         **分项行**(旧版 ① 只要求"独立的 OK 单词" ⇒ 它会顶掉判词,"判词前就崩"被读成 `OK`);
#       - ③(不是分项标记)挡的是 `PARSE[OK]: res://scenes/mp_lobby.tscn`(`lobby_parse_smoke.log:3`)
#         与 `…verdict 照打 ALL-OK`(`rewind_weapon_probe.log:11`,一条**中文说明行**以 ALL-OK 结尾)
#         ⇒ 不挡的话,截断到真判词之前照样读成 `OK`(这两个反例已并进 `--classify-check`);
#       - ②(位置,2026-10-05 **Task 6 改口径**)挡的是"判词之后**又打了一条判定形状的行**"。
#         ★ **为什么放松(控制器 R26)**:旧口径("命中行必须**就是**最后一条非引擎噪声行")当时**明知**
#         会让"判词之后再打非噪声行"的支**假红**,按"方向安全(假红可查)"接受了;但
#         `haste_probe` 那行 `  notes: …`(约一半跑次会出现)让一支**健康**探针**随机**落 `NO-VERDICT`
#         ⇒ 会训练所有人**忽略 `NO-VERDICT`** —— 那正是 `tests/probe/allscript_probe.gd:14`
#         "一条永远红的闸等于没有闸"的另一面("永远"变成"随机")。新口径只让 (b) 类尾行推翻判词。
#     ★★ **放松了什么 / 会不会把真红读成绿(照实写,别读多)**:放松的正是 (c) 那一类 ——
#       旧口径下"判词 + **任何**非噪声尾行"必红,现在只要尾行**不带判定形状**就算绿。
#       残留的"红读成绿"形状 = 「**一条过 ①③ 的判词形状行、它不是这支的真判词、它之后只有非判定形状
#       的行、且全日志没有 FAIL 字样**」。★ 修复轮 1 后这个区已被 (b) 的第四支**收窄**:
#       凡带"本支的断言有失败 / 没跑完"字样的尾行**不再**落进来(评审 I-1)。
#       实测(Task 6:盘上 112 份日志,新老判据逐份比对,取**固定快照**)——
#       **批年代内容 `changed=0`**;**冻结快照 `changed=1`,而唯一那条 = `haste_probe` 的假红翻类**
#       (`NO-VERDICT` → `OK`,= 本任务要修的那一类,**不是**"红读成绿")⇒ **"真红读成绿"的实例 0 例**。
#       ★ **另一种子形态不属本次放松**:"那条判词形状行**本来就是**最后一条非噪声行"(没有尾行可谈)⇒
#       旧口径**也**判绿 —— 那是旧账、不是新开的口子(重审已实测 `residual false-green truncation points: 0`,
#       典型形态 = `[squash_host] floor frame 44 OK` 这种**以 OK 结尾的分项行**)。
#     ★ **将来新增一种良性尾行会怎样**:只要**不带判定形状**(`[OK`/`[ALL-OK`/`✓`/`✗`,也不带上面
#       那条"本支失败/没跑完"的判准词汇),一律**放行**(不会再假红);若哪天某支把**判词行、分项标记
#       或失败·中止汇总**打在判词**之后**,仍落 `NO-VERDICT`
#       (**方向是安全的**:宁可假红,不把"判词不是最后一条判定行"读成绿)。
#     ★ **第三种真实形态要点名**:判词**带标点**不只有 `SMOKE OK`/`ALL-OK` 两种 ——
#       `lobby_parse_smoke` 的真判词是 `PARSE: 1 项,0 失败 → ALL-OK`(带 `:`、`,`、`→`),
#       `WRAP-OK: …`(带 `-`)、`GRACE_WINDOW OK`(方块名 + 空格)也都是判词形状。
#   · ★ **引擎退出噪声的定义**(②里"非噪声"的判据;清单来自真实日志的**实测尾部形状**):
#     空行 / `at: …` / `[N] …`(backtrace 帧)/ `GDScript backtrace …` /
#     `WARNING: …` / `ERROR: …` / `USER ERROR: …` / `USER WARNING: …` / `SCRIPT ERROR: …` / `Godot Engine v…`。
#     实测(2026-10-05,**28/112**;★ 口径随语料批次 —— 更早那份快照上是 **30**,评审 M-2 复算过):
#     判词后面就跟着这类行(`… leaked at exit` / `at: clear (core/io/resource.cpp:822)`)。
#     **复算**(`$OK_RE`/`$NOISE_RE` 就是上面那两条正则;逐份跑,数"最后一条判词形状行**之后**还有噪声行"的支):
#       n=0; for f in tests/.run_all_logs/smoke/*.log tests/.run_all_logs/probe/*.log; do
#         v=$(tr -d '\r' <"$f" | grep -nE "$OK_RE" | tail -1 | cut -d: -f1); [ -n "$v" ] || continue
#         tr -d '\r' <"$f" | tail -n +$((v + 1)) | grep -qE "$NOISE_RE" && n=$((n + 1)); done
#       echo "$n / $(ls tests/.run_all_logs/*/*.log | wc -l)"
#   · ★ **射程与盲区(落纸;2026-10-05 重写,Task 6 又改了一处)**:
#     - **能给的最强保证(2026-10-05 Task 6 改口径后)** = "**脚本最后一条『判定形状』的行就是判词**"
#       —— 判词之后**只允许**引擎噪声行与**非判定形状**的补充行。(旧措辞是"判词是脚本最后打的东西";
#       那条更强、但把 `haste_probe` 的 `notes:` 尾行也一枪打死 ⇒ 见上面「为什么放松」。)
#     - **有意保留**:判词**打出来之后**才死 ⇒ `OK+RC`(不算红)。那是 `elite_drop_probe` 的形态
#       (判词 OK、退出时 SIGSEGV);这条保证止于"判词被完整打出来了",**不**证明退出干净。
#     - **够不到**:判词形状不像 `OK`/`ALL-OK` 的支(例如只打 `PASS` 或 `✓ 全部通过`)⇒ 落 `NO-VERDICT`
#       (**方向安全,但会假红**;真要为它开口子,得给该支换成 `OK` 形状)。
#     - ★ **2026-10-05 Task 6 删除的一条**:旧文件头写"脚本在**真判词之后**又打了别的**非噪声**行 ⇒
#       也落 `NO-VERDICT`,这是**有意的契约**(判词是最后一句)" —— 那句已**不成立**(那正是本任务要修的
#       假红源)。现行契约是"**判词是最后一条『判定形状』的行**",已写进 `tests/README.md`。
#     - ★ **方向变了的一条(照实说)**:`NOISE` 清单是**实测枚举**的(不是引擎规范)⇒ 将来引擎换一种
#       退出噪声措辞时:旧口径是**假红**(判词+新噪声 ⇒ `NO-VERDICT`,方向安全);新口径下这类行落进
#       (c) 类被**放行**。**代价**:判词之后若出现一条**真报错**、而它既不含 `FAIL` 字样、措辞又不在
#       `NOISE` 清单里,`NO-VERDICT` 不会再兜它(与"有意保留 `OK+RC`"同一立场:判词完整打出来后,
#       善后交给 `rc` 与日志全文)。
#   · ★ log 里 CRLF 存在(实测 Godot 输出有 28 处 `\r\n`)⇒ 判据先把 `\r` 剥掉再处理:
#     `$` 在 grep 里不把 `\r` 当行尾,而 `\r` 又属于 `[:space:]` ⇒ 不剥的话 `SMOKE OK\r` 会被**误判 NO-VERDICT**。
FAIL_RE='(^|[^A-Za-z0-9])FAIL[A-Z]{0,4}([^A-Za-z0-9]|$)'
OK_RE='(^|[^A-Za-z0-9])ALL-OK|(^|[^A-Za-z0-9])OK($|[^A-Za-z0-9[:space:]])'
# ②的"引擎噪声"判据(见上「引擎退出噪声的定义」)
NOISE_RE='^[[:space:]]*$|^[[:space:]]*(at:|\[[0-9]+\]|GDScript backtrace|WARNING|ERROR|USER ERROR|USER WARNING|SCRIPT ERROR|Godot Engine)'
# ③的"分项标记"判据
ITEM_RE='\[[[:space:]]*(ALL-)?OK|✓|✗'
# ②的第四支:**本仓自己的失败·中止词汇**(2026-10-05 修复轮 1;评审 I-1)。
# ★ 判准(权威表述在文件头「判准(为什么这些词算"判定形状")」):
#   **凡在表达"本支的断言/检查有失败、或没有跑完"的行,都是判定形状。**
# ★ 只用在**判词之后**那一侧(②);不加到命中行上(大写 `FAIL` 另由最上面的 `FAIL_RE` 全局兜住)。
# ★ **有意不收** `跳过`/`skipped`:要放行的那一行 `  notes: …:对比跳过` 说的是"某一项没测"。
SELFFAIL_RE='失败|不通过|未通过|[Ff]ail|[Aa]borted|[Dd]id not (run|execute)|[Nn]ot executed|checks?[[:space:]]+ran'

# 单支分类:$1 = 日志路径,$2 = 退出码 ⇒ 设置 VERDICT / VLINE / VLINE_N
# VERDICT ∈ {OK, OK+RC, FAIL, NO-VERDICT, TIMEOUT};见文件头「判据分层」。
classify() {
	local log="$1" rc="$2" hit="" ok_n ok_line tail_judge
	VLINE_N="-"
	if [ "$rc" -eq 124 ]; then
		VERDICT="TIMEOUT"; VLINE="(killed by outer timeout)"
		return
	fi
	# FAIL 优先(fail-closed):一个跑出过 FAIL 的支即使后面又打了 OK 也不算绿。
	# ★ 它**同时**是②里"判词之后出现失败行"的兜底(而且更重:整支 FAIL,不是 NO-VERDICT)——
	#   所以②不必再查 FAIL_RE,见文件头「什么才算推翻判词」(b)。
	hit=$(tr -d '\r' <"$log" 2>/dev/null | grep -nE "$FAIL_RE" | head -1)
	if [ -n "$hit" ]; then VERDICT="FAIL"; VLINE_N="${hit%%:*}"; VLINE="${hit#*:}"; return; fi
	# ① 形状:判词候选 = **最后一条**命中 `OK_RE` 的行(`tail -1` 顺带兜住"判词之后又打了判词行":
	#    那样算数的是后一条)。
	hit=$(tr -d '\r' <"$log" 2>/dev/null | grep -nE "$OK_RE" | tail -1)
	if [ -n "$hit" ]; then
		ok_n="${hit%%:*}"; ok_line="${hit#*:}"
		# ② 位置(2026-10-05 Task 6 改口径;修复轮 1 见评审 I-1):判词之后**还有没有"判定形状"的行**?
		#    ★ 查**两支**:`ITEM_RE`(分项标记)与 `SELFFAIL_RE`(**本仓自己的失败·中止词汇** ——
		#      中文 `N 条失败` / 小写 `assertion failed` / `0 checks ran` / `run aborted`);
		#      另两支结构上落不到这里:判词形状由上面的 `tail -1` 兜住、失败由上面的 FAIL 优先兜住。
		#      良性尾行(`notes: …`,含 `:对比跳过`)一律放行 —— 判准见文件头。
		#    ★ 用 `tail -n +N` 取判词之后的**原文行**,再剔掉引擎噪声行(判词后的噪声实测约 28/112 份)。
		#    ★ 全程用 grep 而不是 awk:同一个 `$NOISE_RE`(grep ERE 里 `\[`/`\]` 是正解),
		#      而 awk 会把 `\[` 报成 "escape sequence treated as plain" —— **警告到 stderr**(实测)。
		tail_judge=$(tr -d '\r' <"$log" 2>/dev/null | tail -n +$((ok_n + 1)) |
			grep -vE "$NOISE_RE" | grep -E "$ITEM_RE|$SELFFAIL_RE" | head -1)
		# ② 命中行自己也不能是**引擎噪声行**(判词是脚本打的,不是引擎打的);③ 不许是分项标记
		if [ -z "$tail_judge" ] &&
			! printf '%s' "$ok_line" | grep -qE "$NOISE_RE" &&
			! printf '%s' "$ok_line" | grep -qE "$ITEM_RE"; then
			VLINE_N="$ok_n"; VLINE="$ok_line"
			if [ "$rc" -eq 0 ]; then VERDICT="OK"; else VERDICT="OK+RC"; VLINE="(rc=$rc) $VLINE"; fi
			return
		fi
	fi
	VERDICT="NO-VERDICT"; VLINE=""
}

# ── 分类器的自检(`--classify-check`)────────────────────────────────────────
# 为什么要有:分类器是**整个入口的判据核心**,而它唯一的"测试"曾是"跑一遍全批看表"。
# 评审 C2 正是用**真实日志的截断**把它跑出缝来的(分项行 `OK` 顶掉了 `NO-VERDICT`)。
# 下面每个 fixture 的**行都是从真实日志里抄的形状**(注明出处),不是凭空编的;
# ★ 每条都写清「去掉什么才会红」。
classify_selfcheck() {
	local d fails=0
	d=$(mktemp -d 2>/dev/null) || { echo "[classify-check] cannot mktemp"; return 1; }

	check_case() {  # $1=name $2=rc $3=expected $4...=lines
		local name="$1" rc="$2" exp="$3"; shift 3
		local file="$d/$name.log" got
		printf '%s\n' "$@" >"$file"
		classify "$file" "$rc"
		got="$VERDICT"
		if [ "$got" = "$exp" ]; then
			printf '  ok   %-32s rc=%-4s -> %s\n' "$name" "$rc" "$got"
		else
			printf '  FAIL %-32s rc=%-4s -> %s (expected %s)\n' "$name" "$rc" "$got" "$exp"
			fails=$((fails + 1))
		fi
	}

	# ① C2 的主案:只有**分项行**、判词一行没打(截断到判词之前)。行抄自
	#    `probe/squash_host_water_probe.log`(评审引用的同一形状)。
	#    去掉"判词形状"收紧(改回"任意独立 OK")⇒ 这条会变 OK / OK+RC ⇒ 红。
	check_case "percheck-only-no-verdict" 0 NO-VERDICT \
		'[squash_host] OK     6 ( _pre_move_vy = 0.0)  max dev 0.0000' \
		'[squash_host] OK     floor 帧 44'
	check_case "percheck-only-crash" 139 NO-VERDICT \
		'[squash_host] OK     6 ( _pre_move_vy = 0.0)  max dev 0.0000'

	# ★★ ①b/①c:重审 C2 **残余**的两个真实反例(2026-10-05 第二轮加;行逐字抄自真实日志):
	#   ★ **去掉什么才会红(2026-10-05 Task 6 订正)**:去掉 **③(不是分项标记)** ⇒ 这两条会变
	#     `OK` / `OK+RC` ⇒ 红。★ **它们不靠 ② 挡** —— ①b 截断后那一行**就是**最后一条非空行,
	#     所以"只认最后一条非空行"单独**挡不住**它(重审已实测);把这句话写准,免得后人以为动 ② 会翻这两条。
	#   ①b 出处 `tests/.run_all_logs/smoke/lobby_parse_smoke.log:3`(真判词是**下一行**
	#        `PARSE: 1 项,0 失败 → ALL-OK` —— 判词**带标点**的第三种形态)。
	check_case "bracket-tag-before-verdict" 0 NO-VERDICT \
		'PARSE[OK]: res://scenes/mp_lobby.tscn'
	check_case "bracket-tag-before-verdict-crash" 139 NO-VERDICT \
		'PARSE[OK]: res://scenes/mp_lobby.tscn'
	#   ①c 出处 `tests/.run_all_logs/probe/rewind_weapon_probe.log:11`(**中文说明行**以 `ALL-OK` 结尾;
	#        真判词是同文件的 `KH RW-WEAPON PROBE: ALL-OK`,后面还跟着引擎退出噪声)。
	check_case "prose-line-ends-with-ALL-OK" 0 NO-VERDICT \
		'[RW-WEAPON] ✓ S2: 越界错误只结束那个函数、verdict 照打 ALL-OK'
	# ★ ①d:真判词**带标点**那条形态本身必须**能**判绿(别把真的也挡了)。
	check_case "verdict-with-punctuation" 0 OK 'PARSE: 1 项,0 失败 → ALL-OK'
	# ★ ①e:"判词之后**只有引擎退出噪声**"必须仍判绿(实测 28 份日志如此;口径随语料批次,见上)。
	check_case "verdict-shaped-then-dash-verdict" 0 OK 'WRAP-OK: 鸟跟随玩家回绕,不再跳远副本'

	# ② 判词是最后一行(最常见形态)→ OK。去掉 OK 侧判据 ⇒ 红。
	check_case "verdict-last" 0 OK 'SQUASH HOST PROBE: ALL-OK'
	check_case "verdict-smoke" 0 OK 'SMOKE OK'
	# ③ 判词**后面**跟着引擎退出噪声(实测 28 份日志如此:`at: clear (core/io/resource.cpp:822)` 等)
	#    ⇒ 仍须 OK(这条守的是"别把逐支表全判成 NO-VERDICT")。
	check_case "verdict-then-exit-noise" 0 OK \
		'LOBBY ROW PROBE: ALL-OK(14 条断言)' \
		'WARNING: 25 ObjectDB instances were leaked at exit (run with --verbose for details).' \
		'   at: cleanup (core/object/object.cpp:2536)'
	# ④ 判词肯定但退出码非 0 ⇒ OK+RC(**不算红**);去掉这一档 ⇒ elite_drop 那种形态会被读成 OK。
	check_case "verdict-then-sigsegv" 139 OK+RC 'ELITE DROP PROBE: OK(真击杀 → 结晶 FX 入账)'
	# ⑤ FAIL 侧:去掉 FAIL 分支 ⇒ 这一条会落到 OK ⇒ 红。
	check_case "fail-token" 1 FAIL 'SMOKE FAILURES: 2' 'RECONNECT SMOKE FAILED: 1'
	# ⑥ 外壳 timeout ⇒ TIMEOUT(rc=124 优先于一切文本)⇒ 去掉这一档 ⇒ 它会按文本判读。
	check_case "outer-timeout" 124 TIMEOUT 'SMOKE OK'
	# ⑦ CRLF:实测 Godot 输出里真有 `\r\n`(28 处)⇒ 判据必须先剥 `\r`。
	#    去掉 `tr -d '\r'` ⇒ `SMOKE OK\r` 落 NO-VERDICT ⇒ 红。
	printf 'SMOKE OK\r\n' >"$d/crlf.log"
	classify "$d/crlf.log" 0
	if [ "$VERDICT" = "OK" ]; then printf '  ok   %-32s rc=%-4s -> %s\n' "crlf-verdict" 0 "$VERDICT"
	else printf '  FAIL %-32s rc=%-4s -> %s (expected OK)\n' "crlf-verdict" 0 "$VERDICT"; fails=$((fails + 1)); fi
	# ⑧ 小写分项行(`  ok  - <名字>`,仓内多支这么打)**从来不该**算判词。
	check_case "lowercase-percheck" 0 NO-VERDICT '  ok  - UP held'

	# ── ⑨ 组(2026-10-05 Task 6):② 改口径后的五条。行抄自**实测日志 / 实测台账**,不是编的 ────
	# ⑨a **判词之后跟良性尾行(`notes:`)⇒ 必须判绿**(这就是本任务修的那个假红)。
	#     出处:`tests/probe/haste_probe.gd:313-315` 的 `  notes: …` + `task-2-control-batch.txt`
	#     「NO-VERDICT 那两次」的日志末尾原文(判词 → notes → 输入桩噪声)。
	#     ★ 去掉什么才会红:把 ② 改回**旧口径**(命中行必须是最后一条非引擎噪声行)⇒ 落 `NO-VERDICT`。
	check_case "benign-note-tail-after-verdict" 0 OK \
		'HASTE PROBE: OK(倍率表/敌速×0.50/敌弹×0.50/玩家移速×2.00/跳跃高度不变/红蓝残影/高亮规则/精英亮黄/松开全卸/回NONE/扣颗粒)' \
		'  notes: 敌速采样不足(普通 128.63 / 加速 0.00):对比跳过' \
		'ERROR: PlayerInput: 子类必须覆写 _switch_index_raw()' \
		'   at: push_error (core/variant/variant_utility.cpp:1023)' \
		'      GDScript backtrace (most recent call first):' \
		'          [0] _switch_index_raw (res://core/net/player_input.gd:127)'
	# ⑨b ★ **这一条就是本次有意放松的那一类(把它钉在判据里,别只写在注释里)**:判词之后跟一条
	#     **顶格、非判定形状**的说明行 ⇒ **放行**。★ 去掉什么才会红:同 ⑨a(旧口径 ⇒ NO-VERDICT)。
	#     ★ 风险口径:这是"放松"的正脸 —— 它能放行良性尾行,也能放行**长得不像判定**的真报错;
	#       兜底是 `rc` 与日志全文(见文件头「射程与盲区」)。
	check_case "benign-prose-tail-after-verdict" 0 OK \
		'REWIND WEAPON PROBE: ALL-OK' \
		'phase 2 finished'
	# ⑨c **判词之后又打了一条"判定形状"的行(分项标记 `✓`)⇒ 必须判红**。
	#     形状出处:`tests/lib/probe_base.gd` 的 `_summary` 在没有新增失败时打 ✓ 汇总行(真实存在的形状)。
	#     ★ 去掉什么才会红:**删掉 ② 里那段 `tail_judge=` 查询** ⇒ 这条会变 `OK+RC` ⇒ 红。
	#     ★ 这一支与 ⑨f/⑨g/⑨h 一起构成 ② 的**位置**那一支(方向 = fail-closed:宁可假红)。
	check_case "item-marker-tail-after-verdict" 139 NO-VERDICT \
		'KH RW-WEAPON PROBE: ALL-OK' \
		'✓ 全部通过'
	# ⑨d **命中行自己是一条引擎噪声行 ⇒ 不是判词**。旧实现靠"必须是最后一条非噪声行"顺带挡住;
	#     新 ② 必须自己挡(否则这条会把 `WARNING: …` 那一行当成判词印进表里)。
	#     ★ 去掉什么才会红:删掉 `! printf '%s' "$ok_line" | grep -qE "$NOISE_RE"` 这一支 ⇒ 变 `OK`。
	check_case "noise-line-cannot-be-verdict" 0 NO-VERDICT \
		'FOO PROBE: OK(1 项)' \
		'WARNING: 25 ObjectDB instances were leaked at exit (OK)'
	# ⑨e **判词之后跟新的失败行 ⇒ 必须判红**(而且比 `NO-VERDICT` 更重:走 FAIL 优先)。
	#     ★ 去掉什么才会红:删掉最上面的 FAIL 分支 ⇒ 它会落到 `OK` ⇒ 红。
	check_case "fail-line-after-verdict" 1 FAIL \
		'FOO PROBE: OK(1 项)' \
		'FOO PROBE: FAILURES: 1'

	# ── ⑨f–⑨h 组(2026-10-05 **修复轮 1**;评审 I-1):**本仓自己的失败·中止词汇**也必须推翻判词 ────
	# ★ 判准(文件头):**凡在表达"本支的断言/检查有失败、或没有跑完"的行,都是判定形状。**
	# ★ 这三条的"去掉什么才会红":把 `SELFFAIL_RE` 从 ② 的 grep 里拿掉
	#   (即回到只查 `ITEM_RE` 的那一版)⇒ 三条全部变绿(⑨f rc=1 那条变 **`OK+RC` = 明确"不算红"**)。
	# ⑨f 中文失败汇总(**现网词汇**:`grep -rn 'print.*失败\|不通过' tests/{smoke,probe}/*.gd | grep -vcE 'FAIL|✗'`
	#     = 33 行;行形状抄自 `tests/smoke/app_info_smoke.gd:43` 那一族)。rc=1 ⇒ 初版会落 `OK+RC`(**不算红**)。
	check_case "repo-failure-words-tail-after-verdict" 1 NO-VERDICT \
		'APP INFO SMOKE: ALL-OK(version=「main #1431」, commits=20)' \
		'APP INFO SMOKE: 3 条失败'
	# ⑨g "**一条都没跑**"的形状(判词之后自称空转 ⇒ 这支其实没验过任何东西)。
	check_case "none-ran-tail-after-verdict" 0 NO-VERDICT \
		'FOO PROBE: ALL-OK' \
		'  notes: 0 checks ran (early-exit before assertions)'
	# ⑨h **小写**英文失败 + 未跑完(`FAIL_RE` 只认大写 ⇒ 初版读不到它)。
	check_case "lowercase-assertion-failed-tail" 0 NO-VERDICT \
		'FOO PROBE: ALL-OK' \
		'check 12/86 executed; run aborted (assertion failed: 3 of 86 checks did not run)'
	# ★ ⑨i **边界**:要放行的那一行里就含"某一项跳过"(`:对比跳过`)⇒ 必须**仍然判绿**
	#   (若把 `跳过`/`skipped` 也收进 `SELFFAIL_RE`,这条立刻变红 = 把本任务要修的假红做回来)。
	check_case "skip-note-tail-still-benign" 0 OK \
		'HASTE PROBE: OK(倍率表/敌速×0.50/敌弹×0.50/玩家移速×2.00/跳跃高度不变/红蓝残影/高亮规则/精英亮黄/松开全卸/回NONE/扣颗粒)' \
		'  notes: 敌速采样不足(普通 128.63 / 加速 0.00):对比跳过'

	rm -rf "$d"
	if [ "$fails" -gt 0 ]; then
		echo "RUN_ALL CLASSIFY-CHECK FAIL($fails cases)"
		return 1
	fi
	echo "RUN_ALL CLASSIFY-CHECK OK(24 cases)"
	return 0
}

# 该支声明的条数闸(真相源 = 它自己的 .gd 源码)⇒ 设置 GATE / GATE_USED
# ★ M1 修(2026-10-05):**光声明不算闸** —— 常量声明了却没人拿它比较,`m 断言闸` 就会虚高,
#   而 `GATE` 栏读起来仍像"这份保证有闸盯着"。所以要求同文件里出现**用它的比较**
#   (`>= EXPECTED_CHECKS` / `!= EXPECTED_CHECKS` / 任何 `<EXPECTED_CHECKS` 形式的比较)。
#   ★ 去掉什么才会红:把某支里的 `if _checks != EXPECTED_CHECKS:` 删掉(常量留着)⇒
#     该支 GATE 栏变成 `-(declared,unused)`,且**不再计入** `m`。
gate_of() {
	local src="$1" declared
	GATE=""; GATE_USED="no"
	[ -f "$src" ] || return 0
	declared=$(grep -oE 'EXPECTED_CHECKS[[:space:]]*:=[[:space:]]*[0-9]+' "$src" 2>/dev/null |
		head -1 | grep -oE '[0-9]+')
	[ -n "$declared" ] || return 0
	if grep -qE 'EXPECTED_CHECKS' "$src" &&
		grep -qE '(>=|<=|==|!=|<|>)[[:space:]]*EXPECTED_CHECKS|EXPECTED_CHECKS[[:space:]]*(==|!=|<|>|>=|<=)' "$src"; then
		GATE_USED="yes"
	fi
	if [ "$GATE_USED" = "yes" ]; then GATE="$declared"; else GATE="-(declared,unused:$declared)"; fi
}

# ── 枚举(glob;绝不写死清单)────────────────────────────────────────────
load_known_red


# ★ `--classify-check`:只跑分类器自检,不枚举、不跑测试(判据核心的回归语料)
if [ "$CLASSIFY_CHECK" -eq 1 ]; then
	classify_selfcheck
	exit $?
fi
shopt -s nullglob
ENUM=()
for f in tests/smoke/*.gd; do ENUM+=("$f"); done
for f in tests/probe/*.tscn; do ENUM+=("$f"); done
# ★ 2026-10-05 补(评审 C1):`tests/probe/*.gd` 里**没有同名 `.tscn`** 的那些也是候选 ——
#   它们只能按 `-s` 跑。原先这一片**既不在枚举、也不在任何排除里**(反向漏洞)。
#   现在它们进枚举;进不了的逐支写在 `EXCLUDED` 的 E 组里(带理由),下面还有机械闸兜底。
for f in tests/probe/*.gd; do
	[ -f "${f%.gd}.tscn" ] && continue      # 有 .tscn 的由上面的 scene glob 负责
	ENUM+=("$f")
done
shopt -u nullglob

N_ENUM=${#ENUM[@]}
if [ "$N_ENUM" -eq 0 ]; then
	echo "[enum] enumerated 0 files -- glob matched nothing. Aborting (a silent empty batch would still print OK)."
	echo "RUN_ALL FAIL(0 runs / enumerated 0)"
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
PRE_PATH=()   # ★ 过滤**之前**的运行集:覆盖率闸(C1)必须看它,不能看 `--only` 之后的那一份
N_SMOKE_ENUM=0; N_PROBE_TSCN_ENUM=0; N_PROBE_GD_ENUM=0; N_EXCLUDED=0
for f in "${ENUM[@]}"; do
	case "$f" in
		tests/smoke/*.gd) N_SMOKE_ENUM=$((N_SMOKE_ENUM + 1)) ;;
		tests/probe/*.tscn) N_PROBE_TSCN_ENUM=$((N_PROBE_TSCN_ENUM + 1)) ;;
		tests/probe/*.gd) N_PROBE_GD_ENUM=$((N_PROBE_GD_ENUM + 1)) ;;
	esac
done

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
					echo "RUN_ALL FAIL(0 runs / $f neither run nor excluded)"
					exit 1
				fi
				mode=scene; src="$f"; target="res://$tscn"
			fi
			;;
		tests/probe/*.tscn)
			mode=scene; src="${f%.tscn}.gd"; target="res://$f"
			;;
		tests/probe/*.gd)
			# 没有同名 `.tscn` ⇒ 只能按 `-s` 跑(跑法见 docs/eng/tests.md)
			mode=smoke; src="$f"; target="res://$f"
			;;
		*) echo "[enum] FATAL: unexpected enumerated path $f"; exit 1 ;;
	esac

	# 承重安全检查(只扫**整行注释以外**的文本)
	if [ -f "$src" ]; then
		if grep -vE '^[[:space:]]*#' "$src" | grep -qE "$DANGER_RE"; then
			echo "[enum] FATAL: $f opens a socket / spawns a process (matches: $DANGER_RE)."
			echo "        Either EXCLUDE it with a reason or fix the probe -- it must not enter the headless batch."
			echo "RUN_ALL FAIL(0 runs / $f tripped the 7777-guard)"
			exit 1
		fi
	fi

	base=$(basename "$f"); base="${base%.*}"
	budget=$([ "$mode" = smoke ] && echo "$SMOKE_BUDGET" || echo "$SCENE_BUDGET")
	if [ -n "${BUDGET_OVERRIDE[$base]:-}" ]; then budget="${BUDGET_OVERRIDE[$base]}"; fi

	PRE_PATH+=("$f")          # 先记账(覆盖率闸 C1 用),再决定这趟跑不跑

	if [ -n "$ONLY" ]; then
		case "$f" in *"$ONLY"*) ;; *) continue ;; esac
	fi

	RUN_MODE+=("$mode"); RUN_PATH+=("$f"); RUN_SRC+=("$src")
	RUN_TARGET+=("$target"); RUN_BUDGET+=("$budget")
done

N_RUN=${#RUN_PATH[@]}

# ── 机械闸(评审 C1):`tests/probe/*.gd` 的**覆盖率断言** ────────────────────
# 每一支 `tests/probe/*.gd` 必须落在三者之一:① 有同名 `.tscn`(由 scene glob 枚举);
# ② 在运行清单里(按 `-s`);③ 在 `EXCLUDED`/`OUT_OF_SCOPE` 里带理由。
# ★ 去掉什么才会红:**把那第三个 glob(`tests/probe/*.gd`)删掉/收窄**(= 回到 C1 爆出来的那个
#   口径)⇒ 那些"没有同名 `.tscn`、又没被排除"的支立刻在这里点名并 FATAL
#   (实测:删掉那条 glob ⇒ 9 支被点名)。
#   ★★ **注意别测错**:光**删掉 `EXCLUDED` 里的一条**是**不会**红的 —— 那支会被第三个 glob
#   **重新收进运行集**(这正是"结构性闭合"想要的效果)。这道闸守的是 **glob 口径本身**,
#   不是"某条排除理由在不在"。
COVER_BAD=()
shopt -s nullglob
for f in tests/probe/*.gd; do
	[ -f "${f%.gd}.tscn" ] && continue         # ① 有 .tscn ⇒ 由 scene 侧负责
	in_run=0
	for p in "${PRE_PATH[@]:-}"; do [ "$p" = "$f" ] && { in_run=1; break; }; done
	[ "$in_run" -eq 1 ] && continue             # ② 按 -s 进批了
	in_excl=0
	for line in "${EXCLUDED[@]}" "${OUT_OF_SCOPE[@]}"; do
		pat="${line%%|*}"
		# shellcheck disable=SC2053
		if [[ "$f" == $pat ]]; then in_excl=1; break; fi
	done
	[ "$in_excl" -eq 1 ] && continue            # ③ 显式排除 + 理由
	COVER_BAD+=("$f")
done
shopt -u nullglob
if [ "${#COVER_BAD[@]}" -gt 0 ]; then
	echo "[enum] FATAL: ${#COVER_BAD[@]} tests/probe/*.gd file(s) are NEITHER run NOR excluded -- they would be silently skipped:"
	for p in "${COVER_BAD[@]}"; do echo "         $p"; done
	echo "        Fix: give them a sibling .tscn, let the -s glob run them, or add an EXCLUDED/OUT_OF_SCOPE row with a reason."
	echo "RUN_ALL FAIL(0 runs / ${#COVER_BAD[@]} probe .gd not covered)"
	exit 1
fi

# ── 机械闸(评审 I1):`known_red.txt` 每条路径必须**真实存在**于候选面 ──────────────
# 判据:该路径出现在枚举集里,或在 `EXCLUDED`/`OUT_OF_SCOPE` 里。否则 ⇒ 红。
# ★ 去掉什么才会红:往 `known_red.txt` 写一条**不存在/已改名**的路径 ⇒ 这里点名并 FATAL。
#   (旧实现只对"这趟跑过的条目"判过期 ⇒ 不存在的路径永远不在这集里 ⇒ **永久死行没人知道**,
#    而那正是"登记簿说谎"。)
BASELINE_GHOST=()
for p in "${!KNOWN_RED_CLASS[@]}"; do
	ok=0
	for f in "${ENUM[@]}"; do [ "$f" = "$p" ] && { ok=1; break; }; done
	if [ "$ok" -eq 0 ]; then
		for line in "${EXCLUDED[@]}" "${OUT_OF_SCOPE[@]}"; do
			pat="${line%%|*}"
			# shellcheck disable=SC2053
			if [[ "$p" == $pat ]]; then ok=1; break; fi
		done
	fi
	[ "$ok" -eq 1 ] || BASELINE_GHOST+=("$p")
done
if [ "${#BASELINE_GHOST[@]}" -gt 0 ]; then
	echo "[baseline] FATAL: ${#BASELINE_GHOST[@]} row(s) in $KNOWN_RED_FILE point at a path that is NOT in the enumeration nor in EXCLUDED/OUT_OF_SCOPE:"
	for p in "${BASELINE_GHOST[@]}"; do echo "         $p"; done
	echo "        Fix: correct the path, or delete the row (a permanently dead row makes the ledger lie)."
	echo "RUN_ALL FAIL(0 runs / ${#BASELINE_GHOST[@]} baseline paths do not exist)"
	exit 1
fi

# ── 打印环境口径 + 清单头 ────────────────────────────────────────────────
echo "==== run_all: headless default batch ===="
echo "[env] GODOT      = $GODOT"
echo "[env] version    = $("$GODOT" --version 2>/dev/null | head -1)"
if lobby_alive; then echo "[env] lobby_alive = true  (7777 has a live lobby -- this batch does NOT touch 7777)";
else echo "[env] lobby_alive = false"; fi
echo "[env] godot procs before = $(tasklist 2>/dev/null | grep -ci godot || true)"
echo "[env] log dir    = $LOG_DIR"
echo "[env] quit-after = $QUIT_AFTER frames (scene probes) ; budget: smoke=${SMOKE_BUDGET}s scene=${SCENE_BUDGET}s (+per-file overrides)"
echo "[enum] enumerated $N_ENUM files (tests/smoke/*.gd = $N_SMOKE_ENUM, tests/probe/*.tscn = $N_PROBE_TSCN_ENUM, tests/probe/*.gd without tscn = $N_PROBE_GD_ENUM)"
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
		echo "RUN_ALL FAIL(${#STALE[@]} stale-exclusions + $BASELINE_BAD baseline-problems / nothing was run)"
		exit 1
	fi
	exit 0
fi

if [ "$N_RUN" -eq 0 ]; then
	echo "[enum] running 0 files -- nothing would be verified. Aborting."
	echo "RUN_ALL FAIL(0 runs / enumerated $N_ENUM, 0 after filter)"
	exit 1
fi

mkdir -p "$LOG_DIR/smoke" "$LOG_DIR/probe"
: >"$SUMMARY"
: >"$FAILED_LIST"

# ── R20(2026-10-05):`tests/.run_all.lock` —— "这一批**在飞**"的可查标记 ────────
# 为什么要有它:闸三靠"单点采样 godot 进程数"和"summary 的 mtime"都**只是窗口**;
#   实测事故就是单点采样落在两支之间的空档 ⇒ 真链路脚本被放行(见文件头/报告「事故与订正」)。
#   锁是**状态**而不是**采样**:`run_real.sh` 见"活锁"就拒绝。★ 陈旧锁(pid 已死 / 心跳超时)
#   判为陈旧 ⇒ `run_real.sh` **打醒目警告后放行**(否则就变成"永远拒绝的闸"那一面)。
LOCK_FILE="tests/.run_all.lock"
LOCK_STALE_SECS="${RUN_ALL_LOCK_STALE_SECS:-600}"   # 心跳超时阈值(秒);★ 活锁 = pid 活着 **且** 心跳在阈值内 ——
                                                    # pid 活着但心跳超时 ⇒ **陈旧 ⇒ run_real 放行**(按代码写,2026-10-05 修复轮3)
lock_write() {
	printf 'pid=%s\nstart=%s\nheartbeat=%s\n' "$$" "$RUN_START_EPOCH" "$(date +%s)" >"$LOCK_FILE" 2>/dev/null || true
}
lock_cleanup() { rm -f "$LOCK_FILE" 2>/dev/null || true; }
RUN_START_EPOCH=$(date +%s)
lock_write
trap 'lock_cleanup' EXIT
trap 'lock_cleanup; exit 130' INT TERM
echo "[lock] holding $LOCK_FILE (pid $$) so tests/run_real.sh refuses to run concurrently"

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
	lock_write          # 心跳:每支一刷(见 R20)。★ 阈值 600s > 单支最长预算 150s ⇒ 正常跑不会因心跳被判陈旧

	classify "$log" "$rc"
	gate_of "$src"
	SEEN_RUN="$SEEN_RUN$path"$'\n'

	# 红的三类(FAIL / NO-VERDICT / TIMEOUT)再看基线:命中且**类别对得上** ⇒ KNOWN-RED
	DISPLAY="$VERDICT"
	case "$VERDICT" in
		OK)
			N_OK=$((N_OK + 1))
			# ★ 只累加**真的被用于比较**的闸(M1);`-(declared,unused:N)` 不计入 `m`
			if [ "$GATE_USED" = "yes" ]; then GATE_SUM=$((GATE_SUM + GATE)); fi
			;;
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
	echo "[known-red] $N_KNOWN registered, not counted as new red (delete the row when it is fixed):"
	printf '%b' "$KNOWN_LIST" | sed 's/^/  KNOWN-RED  /'
else
	# ★ I2 修(2026-10-05):"可能已修好,请删行"这句**只在"这趟真的跑过它、而它没红"时**才成立。
	#   旧写法在 `--only <子集>` 下会打出这句 ⇒ 照做就删掉唯一那条基线 ⇒ 入口回到"永远 FAIL"。
	#   ★ 去掉什么才会红(2026-10-05 修复轮2 订正 —— 原句指向的"请删行"提示已随 I2 删除,那句话已不存在):
	#     把**上面那个**循环里的 `STALE_BASELINE=$((STALE_BASELINE + 1))` 删掉 ⇒ 一条**已修好却没删行**
	#     的基线条目(或指向一支已转绿的支)就**不再报红** ⇒ 登记簿可以永久说谎。
	echo "[known-red] 0 this run (baseline has $( [ "$KNOWN_RED_N" -eq 0 ] && echo 0 || echo "$KNOWN_RED_N" ) row(s))"
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
		echo "RUN_ALL FAIL($N_NEWRED new-red + $N_KNOWN registered + $GATE_BAD gate-problems)"
	else
		echo "RUN_ALL FAIL($N_NEWRED new-red + $N_KNOWN registered)"
	fi
	exit 1
fi

echo
if [ "$N_KNOWN" -gt 0 ]; then
	echo "RUN_ALL OK-WITH-KNOWN-RED($N_RUN runs, $N_KNOWN registered)"
else
	echo "RUN_ALL OK($N_RUN runs / $GATE_SUM gated-assertions)"
fi
exit 0
