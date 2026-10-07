extends ProbeBase

# 菜单武器网格守卫(2026-09-29;清扫「未认领欠账」的 A2 + A5 两项)。
#
# 守两件此前**没有任何自动化判据**的事,两条都是"改错了不报错"的形态:
#
# ① A2 —— 菜单的武器勾选框**真的按注册表建了 N 个**。
#    既有守卫是 `enemy_logic_smoke._phase_weapon_registry` 的 ⑥,而它是**源码级**的:
#    只断言 `_fill_sp_panel` 的函数体里出现了 `WeaponRegistry.all_ids()`。把那个循环改成
#    `for i in 6:` 之类,只要还调着 `all_ids()`,⑥ **照样绿**,而菜单**静默只显示 6 行**。
#    headless 跑 `main_menu.tscn` 也拦不住:该场景**一行都不打印**,而且它不会去按
#    「单人模式」 ->  `_fill_sp_panel` 根本不被调用(实测:临时探针实例化真场景 + 调生产函数,
#    json 7 条时得「勾选框数=7 注册表=7」)。
#    故本探针**真实例化** `main_menu.tscn`、走**生产入口** `_on_single_pressed()`
#    (它就是 `_fill_sp_panel` 唯一的调用点),再数 `CheckList` 容器下的 `CheckButton`。
#    - 容器按**名字**在面板子树里找(不写死路径):2026-10-03 那轮美化给面板外层套了
#      `Body`,写死 `VBox/CheckList` 会虚假失败（测试用例误报）;改名仍会红(见 `_find_named` 的调用点)。
#
# ② A5 —— 勾选框上的文字**只有武器名,不带编号**。
#    那个编号(1..N)**看起来**是键位,而键位是**背包位置**、与 `type_id` 毫无关系
#    (用户 2026-09-25 裁定:菜单上不显示编号)。字号扫描(kh_l4 / kh_l5)抓不到它 ——
#    它只查**整数字面量**,而这两处一处是**变量实参**
#    (`WeaponIcons.make_weapon_check(type_i, …)` 那个 `type_id`)、一处是**`cb.text` 赋值**
#    (`_fill_sp_panel`),都不在其射程内  ->  此前**只有人眼判据**。
#
# - 判据刻意写成 `text == WeaponRegistry.name_of(id)`(**逐字相等**),不是"不含数字":
#   武器名里本来就有数字(`重狙 M82A1` / `霰弹 S686`),而「不含 str(type_id)」那种写法
#   对**将来**的武器名会虚假失败（测试用例误报）(给 id 5 起名 `MP5` 就当场炸),且"名字里恰好没这个数字"也
#   不是契约。真实契约就是「显示文本 == 注册表里的名字,一个字符都不多」—— 加编号也好、
#   加"键位 N"也好,都会破坏逐字相等。
#
# - 覆盖上限(照实登记):本探针只看 `text`。谁把编号画成**另一条 Label / TextureRect**
#   (`WeaponIcons.make_weapon_check` 的 cell 是个 HBox,加子节点很容易),本探针**看不见**。
#   今天那个 cell 只有 `[CheckButton, TextureRect, Label]` 三个子节点,这一档**没有**对应的
#   "子节点数"断言 —— 别把本条读成"菜单上从此不可能再出现任何数字"。
#
# 跑法(场景模式,`--quit-after` 是安全网;headless 即可,本探针不取像素):
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_weapon_grid_probe.tscn
# 判据:末行 "KH MENU-GRID PROBE: ALL-OK"(grep 文本,不看退出码)。

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const LOBBY_PAGE_SRC := "res://scenes/lobby_page.gd"

# 本探针的断言条数。判据 = **实跑条数 == 期望条数**(见 `tests/lib/probe_base.gd` 文件头:
# `ALL-OK` 只证明"没有任何断言失败",**不证明"该跑的断言都跑过"** —— 脚本错误只让出错的
# 那个函数当场结束、调用方继续,后面那些断言被静默跳过而 verdict 照打 ALL-OK)。
const EXPECTED_CHECKS := 8

var _checks := 0


func probe_id() -> String:
	return "MENU-GRID"


func _c(ok: bool, msg: String) -> void:
	_checks += 1
	print(("  ok   " if ok else "  FAIL ") + msg)
	_check(ok, msg)


func _ready() -> void:
	var ids: Array[int] = WeaponRegistry.all_ids()
	# ① 无效操作守卫:注册表为空时下面几条全会以 `0 == 0` 通过,那是**虚假通过（未有效测试）**。
	_c(ids.size() >= 1, "注册表至少有 1 把武器(实际 %d;为空则本探针其余计数条全是 0==0 假绿)"
			% ids.size())

	# ── 阶段 1:`main_menu` 的禁用武器勾选框(走生产入口 `_on_single_pressed`)──
	var menu = (load(MAIN_MENU_SCENE) as PackedScene).instantiate()
	add_child(menu)
	await get_tree().process_frame
	await get_tree().process_frame
	menu._on_single_pressed()          # ← 生产入口;它内部就是 `_fill_sp_panel`。
	var panel = menu._sp_panel
	var list: VBoxContainer = null
	if panel != null:
		# 注意： 按**节明确提示**在子树里找,不写死路径(`VBox/CheckList`):2026-10-03 那轮美化把
		#   面板改成"基础结构框架在 .tscn、皮与内容在代码里套 `UiFactory.skin_menu_panel()`",
		#   路径多了一层 `Body/` —— 写死路径的探针直接断言失败,而**主题(勾选框数/文案)一个字没变**。
		#   按名找之后,版式再挪一层不会虚假失败（测试用例误报）;而**改名**仍会红(下面那条 `list != null`),
		#   不会退化成静默失明。
		list = _find_named(panel, "CheckList") as VBoxContainer
	_c(panel != null and list != null,
			"`_on_single_pressed()` 建出了单人面板且其中的 `CheckList` 容器在位(面板 %s、列表 %s)"
					% [str(panel), str(list)])

	# 计数:数 **CheckButton 实例**,不数字面量 —— 多一个少一个都红。
	var cbs: Array[CheckButton] = []
	var texts: Array[String] = []
	if list != null:
		for c in list.get_children():
			if c is CheckButton:
				cbs.append(c)
				texts.append((c as CheckButton).text)
	_c(cbs.size() == ids.size(),
			"勾选框数必须等于注册表条数(实际 %d、注册表 %d)——" % [cbs.size(), ids.size()]
			+ " 源码级 ⑥ 对这个数是全盲的(`for i in 6:` 也绿)")

	# 逐字相等(顺序也要对:菜单顺序 == 注册表顺序 == json 顺序)
	var want: Array[String] = []
	for id in ids:
		want.append(WeaponRegistry.name_of(id))
	_c(texts == want,
			"每个勾选框的文字必须是**注册表名逐字**、不带编号(实得 %s、期望 %s)"
					% [str(texts), str(want)])

	# ── 阶段 2:`WeaponIcons.make_weapon_check` 造的那个 cell(两个大厅页共用的另一半)──
	# - 为什么单开一相:菜单上那两处**载体不同** —— `main_menu` 直接写 `cb.text`,
	#   而两个大厅页走 `WeaponIcons.make_weapon_check(type_i, …)`,**编号是变量实参**
	#   (kh_l4 的字号扫描按下标 2 取那个实参,它只管字号)。只钉阶段 1 那一半的话,把编号
	#   加回 `make_weapon_check` 里的 Label 上照样测试全部通过。
	var cell_found := true
	var cell_texts: Array[String] = []
	for id in ids:
		var cell = WeaponIcons.make_weapon_check(id, false, 32, func(_on: bool) -> void: pass)
		var lbl: Label = null
		if cell != null:
			for c in cell.get_children():
				if c is Label:
					lbl = c
					break
		if lbl == null:
			cell_found = false
			if cell != null:
				cell.free()
			break
		cell_texts.append(lbl.text)
		cell.free()
	_c(cell_found, "`WeaponIcons.make_weapon_check()` 对每个 id 都返回了含 Label 的 cell")
	_c(cell_texts == want,
			"`make_weapon_check` 的 Label 文字必须是**注册表名逐字**(实得 %s、期望 %s)"
					% [str(cell_texts), str(want)])

	# 接线:上面验的是 `make_weapon_check` 本身,而两个大厅页**经 `_add_weapon_grid` 调它**
	# —— 只钉函数本身的话,页面改成自己造 cell 就绕过去了,且一条断言都不会红。
	var lb := _read(LOBBY_PAGE_SRC)
	_c(not lb.is_empty(), "读到 %s(读不到就是红,不是静默跳过)" % LOBBY_PAGE_SRC)
	var grid_body := _func_body(_code_only(lb), "_add_weapon_grid")
	_c(grid_body.contains("WeaponIcons.make_weapon_check("),
			"`lobby_page._add_weapon_grid` 必须经 `WeaponIcons.make_weapon_check` 造格子"
			+ "(自己另造 cell = 相②验的那个函数被绕开,而一条断言都不会红)")

	menu.free()

	# ── 收尾自查:实跑条数必须等于期望(裸 append,不自增 _checks)──
	if _checks != EXPECTED_CHECKS:
		_failures.append("实跑 %d 条断言、期望 %d 条(不等 = 有断言被静默跳过,或改了本文件没同步常量)"
				% [_checks, EXPECTED_CHECKS])
	_summary(0, "菜单武器网格:%d 条断言" % _checks)
	_finish()


# 在子树里按**节明确提示**找第一个节点(找不到返回 null)。
# - 为什么不写死路径:单人面板 2026-10-03 起"基础结构框架在 .tscn、皮与内容在代码里套
#   `UiFactory.skin_menu_panel()`",内容比从前多了一层 `Body/` —— 写死路径的探针会**虚假失败（测试用例误报）**,
#   而它要守的东西(勾选框数 == 注册表条数、文案逐字相等)一个字都没变。
# - 但**不许**退化成静默失明:调用点仍然断言 `list != null`  ->  改名 / 删节点照样红。
func _find_named(root: Node, nm: String) -> Node:
	if root.name == nm:
		return root
	for c in root.get_children():
		var hit := _find_named(c, nm)
		if hit != null:
			return hit
	return null
