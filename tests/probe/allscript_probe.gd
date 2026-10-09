extends Node

# 全仓脚本加载自检:递归扫 res:// 下全部 .gd 逐个 load(),抓悬空引用/解析错误。
# 场景模式跑(autoload 可用);对"大回退/大合并后的第一件事"特别有用。
#   godot --headless --path . res://tests/probe/allscript_probe.tscn

const SKIP_DIRS := ["res://.godot", "res://builds", "res://releases", "res://gamelogs",
		"res://crashlogs", "res://maps", "res://map", "res://backup", "res://editor/_build",
		"res://_crashtest"]
# ★ 为什么必须收 `res://_crashtest`(2026-10-03,与 `tools/check_naming.py` 里同名的那个根同因):
#   它是 **gitignore 的现场草稿**,里面存着**编译不过的旧 `.gd` 备份**(`pkdbak/`:
#   `pvp_match_client.gd` 已删的 `_delta`/`cell`、`team_game.gd` 还 preload 着搬走的
#   `res://ui/team_hud.tscn`)。不收它 ⇒ 本探针**改前就红 3/288**,而它守的是
#   "大回退/大合并后全仓脚本还能不能解析"这一条 —— 一条**永远红**的闸等于没有闸。
#   ★ 它**不该**改成"把失败降级成提示":那 3 个文件确实解析不过,只是它们**不是本仓的源码**。

# ★★ 覆盖面下限(2026-10-03,最终整体评审 Important 1):本闸**曾经没有下限** ——
#   一个过宽的 `SKIP_DIRS` 项、一个 `.gdignore`、一次 `DirAccess.open` 失败,都**只让
#   `_total` 变小**,而探针照打 `OK(n)` ⇒ 它是一道 **fail-open** 的闸:自己瞎了也不知道。
#   讽刺点(评审原文点的):同一批里我们刚给 `combat_hud_visual_probe` / `kh_l3_visual_probe`
#   补了条数下限(R19/R41),却把这道自称"本批最大增益"的闸留在无下限状态 —— 而本批
#   **恰好拓宽了** `SKIP_DIRS`(加了 `res://_crashtest`,见上),正是最该有下限的时候。
#
# `EXPECTED_SCRIPTS := 287` 的**数法**(先说 `_total` 在数什么):
#   `_collect("res://")` 递归收 `.gd`(`:77-92`),排除 ① **名字以 `.` 开头的目录**
#   (故 `.godot/`、`.git/`、`.claude/`、`.superpowers/` 里的 scratch `.gd` 一概不在数里)、
#   ② `SKIP_DIRS` 那 10 项、③ 以 `.gd.remap` 结尾的名字。
#   ⇒ `_total` = "res:// 下**参与编译面**的 `.gd` 个数"。
#   283 在 `57aa973` 上由两条**独立**路径对上:探针自己打的 `OK(283)`,与
#   `git ls-files '*.gd' | wc -l` = 283(相等的前提三条:283 个已跟踪 `.gd` 全部落在非点、
#   非 skip 目录里;工作树零个未跟踪 `.gd`;零个 `.gd.remap` —— 三条都实测过)。
#   ★★ **2026-10-04 重测 ⇒ 287**(同日 283 过期;下面留着**逐条可复核**的数法,供下一次照着核):
#     · 净变化 = **+5 新增 − 1 删除**:
#       新增(`git log --diff-filter=A --name-only --pretty=format: 57aa973..HEAD -- '*.gd'`)——
#       `tests/probe/menu_shot_probe.gd`（★ 2026-10-08 测试经济已把它移入 `tests/manual/`）/
#       `tests/probe/rewind_weapon_probe.gd` /
#       `tests/probe/weapon_injected_fire_probe.gd` / `tests/smoke/project_settings_smoke.gd` /
#       `tests/smoke/settings_display_smoke.gd`;
#       删除 —— `DevTools/gamelog/log_viewer.gd`(`9e4ccbe` 把 `DevTools/` 出库;当时它**在**
#       计数面里,因为 `DevTools` 既不点开头、也不在 `SKIP_DIRS`)。
#     · 287 这次同样由**两条独立路径**对上:
#       ① 探针自己打的 `ALLSCRIPT: FAIL(0/287 失败 · 条数闸红(期望 283))` —— 扫到 **287**、`LOAD[FAIL]` **0** 行;
#       ② `git ls-files '*.gd' | wc -l` = **287**;基线可复算:`git ls-tree -r --name-only 57aa973 | grep -c '\.gd$'` = **283**。
#     · 三条前提**逐条重测**(当天):`git ls-files '*.gd'` 里**零个**路径落在点目录或 `SKIP_DIRS`;
#       `git ls-files --others --exclude-standard '*.gd'` = **0**;`find . -name '*.gd.remap'`(排除 `.godot/`)= **0**。
#     · 另有**第三条**、不依赖 git 的核法:按 `_collect` 的同一套排除规则在文件系统上数 `.gd`
#       (排除点目录与 `SKIP_DIRS`、排除 `*.remap`)= **287**。
#   ⇒ 它同时钉住"没有少、也没有多",故下面用 `!=` 而不是 `<`。
# ★ 它是**覆盖面**闸,不是质量闸:以后**故意**增删 `.gd` 时它会红并点名两个数,照着改这个
#   常量即可 —— 那正是"覆盖变了得有人过目"的意思。**别把它降级成 `<`**(对"多扫了一条"
#   就瞎了,而多出来的可能正是 scratch 副本)。
#   ★★ **2026-10-08 ⇒ 286**(测试经济 D2/D5;当日 287 过期)，**同日 Task 4 新增 `tests/smoke/server_input_sanitize_smoke.gd` ⇒ 287**:
#     · 净变化 = **−1**,是**删除**:`tests/probe/perf_probe.gd`(它的读数是"服务器清格子格"算法的
#       **第二份口径**、且仍是 v3 的 `*2`/`x/2` ⇒ **读数本身不可信**,留在 `tests/` 只会误导)。
#       `git ls-files '*.gd' | wc -l` = **286** 独立对上。
#   ★★ **2026-10-08 同日再加两条(同一批 Task 4 / Task 5 各新增 1 支 `-s` 冒烟)⇒ 现行 288**:
#       `tests/smoke/server_input_sanitize_smoke.gd`(服务端输入收口)与
#       `tests/smoke/rpc_channel_contract_smoke.gd`(RPC 通道契约)。
#     · ★★ **一个必须写下来的反直觉点**:同日把 **22 个文件"移动"**出去(18 支人工仪器 +
#       `brawl_rollback_probe` → `tests/manual/`、2 支 helper → `tests/harness/`)**没有**改变这个数 ——
#       因为 `_collect("res://")` 数的是**编译面**,它**不看入口的 glob**。⇒ 本闸管的是
#       "res:// 下参与编译的 `.gd` 有没有被静默增删",**不是**"测试有多少";想让测试面变小,
#       得**删文件**,移动不算。
#     · ★ 处置上**有意区分"不再当守卫"与"删"**:`brawl_rollback_probe` 作为守卫不可靠(读 N≥4
#       自身在抖),但它是 `PredictionRollback._close_enough` 容差常数的**测量台** ——
#       `core/net/prediction_rollback.gd` 的注释指着它说"要重测得重跑它" ⇒ **移**到 `tests/manual/`;
#       `perf_probe` 是**读数本身错** ⇒ **删**。
#   ⇒ 上面 283/287 那几段是**历史值**(数法留着供复核),现行值以本常量为准。
#   ★★ **2026-10-09 ⇒ 158**(测试面削减 90%;前值 288 至此过期):
#     · 净变化 = **−130**,**全部是删除**(用户裁定的一批;台账:
#       `docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md`)。
#       ★ 这一批正好**印证**上面那条反直觉点:2026-10-08 那批是"**移动**" ⇒ 本数纹丝不动;
#       本批是"**删文件**" ⇒ 它真的动了(288 → 158)。两道口径的分工在这里第二次被实测分开。
#     · 158 由**两条独立路径**对上(与 283/287/288 那几次同规):
#       ① `git ls-files '*.gd' | wc -l` = **158**;
#       ② `git ls-files --others --exclude-standard '*.gd'` = **0**;`find . -name '*.gd.remap'`(排除 `.godot/`)= **0**。
#       另:`SKIP_DIRS` 不含 `tests/`,故 288 − 130 = 158 是直接相减,不经任何近似。
#     · ★ 本常量是**手改**为实测值的 —— 按本文件"它同时钉住没有少、也没有多"的同规,
#       这不是"让闸变绿",而是这批改动的**验收判据之一**:它同时证明"测试面删到位了"
#       与"没有误删产品 `.gd`"(后者若发生,`git ls-files` 与 `_total` 会**一起**变,
#       这条闸本身抓不到 —— 所以它必须**配合**删除清单逐文件认领,不能单飞)。
const EXPECTED_SCRIPTS := 158

var _fails: Array[String] = []
var _total := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for p in _collect("res://"):
		_total += 1
		var s = load(p)
		# ★★ 2026-10-02 合并时实测补的判据:只判 `s == null` **抓不到解析错误** ——
		#   GDScript 解析失败时 `load()` 仍返回**非 null** 的、只是 `can_instantiate() == false`
		#   的 GDScript。实测:往树上放一个引用未声明标识符的脚本,旧实现照样打
		#   "ALLSCRIPT: OK(N 个脚本全部加载)"(`load()` 只在"文件不存在/资源类型不认"时才返回 null)。
		#   ⇒ 必须**两条都判**。合并时就有一个真解析错误(`pvp_match_client.gd` 的 `_delta` /
		#   `cell` 未声明)从旧判据下溜过去,是靠 `team_room_smoke` 红才发现的。
		var broken := s is GDScript and not (s as GDScript).can_instantiate()
		if s == null or broken:
			_fails.append(p)
			print("LOAD[FAIL]: %s(%s)" % [p, "解析失败/不可实例化" if broken else "load() 返回 null"])
	# ★ 收尾两道(与 `tests/lib/probe_base.gd` 的 `_checks >= EXPECTED_CHECKS` 同一条纪律,
	#   只是这里的"条数"是**被扫的脚本数**):① 扫到的脚本数 `!= EXPECTED_SCRIPTS` ⇒ 红
	#   (**两侧都红**:少了是覆盖缺口,多了是覆盖变了);② 有加载失败 ⇒ 红。
	#   判词**点名条数**,否则"闸红了"与"扫描面塌了"在输出上分不出来。
	var count_ok := _total == EXPECTED_SCRIPTS
	if not count_ok:
		print("ALLSCRIPT: 条数闸 FAIL —— 实扫 %d 个脚本,期望 %d(覆盖面对不上;见本文件头部)"
				% [_total, EXPECTED_SCRIPTS])
	if _fails.is_empty() and count_ok:
		print("ALLSCRIPT: OK(%d 个脚本全部加载)" % _total)
		get_tree().quit(0)
	else:
		# 条数闸红时把原因并进裁决行 —— 否则会打出一行像"零失败"的 `FAIL(0/131 失败)`。
		print("ALLSCRIPT: FAIL(%d/%d 失败%s)" % [_fails.size(), _total,
				("" if count_ok else " · 条数闸红(期望 %d)" % EXPECTED_SCRIPTS)])
		get_tree().quit(1)


func _collect(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var p := dir_path.path_join(name)
		if dir.current_is_dir():
			if not name.begins_with(".") and not SKIP_DIRS.has(p):
				out.append_array(_collect(p))
		elif name.ends_with(".gd") and not name.ends_with(".gd.remap"):
			out.append(p)
		name = dir.get_next()
	return out
