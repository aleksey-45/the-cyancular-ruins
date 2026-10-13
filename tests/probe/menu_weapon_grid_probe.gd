extends ProbeBase


const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const LOBBY_PAGE_SRC := "res://scenes/lobby_page.gd"

# 本探针预期的断言总数。成功判据要求实际执行数严格等于期望值（参见 `tests/lib/probe_base.gd`：
# `ALL-OK` 仅证明未出现显式断言失败，不能保证所有预期断言均已实际执行 —— 脚本运行时异常会导致
# 异常函数提前退出而静默跳过后续断言）。
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
	# ① 无效操作防御性校验:注册表为空时下面几条全会以 `0 == 0` 通过,那是测试漏报。
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
		list = _find_named(panel, "CheckList") as VBoxContainer
	_c(panel != null and list != null,
			"`_on_single_pressed()` 建出了单人面板且其中的 `CheckList` 容器在位(面板 %s、列表 %s)"
					% [str(panel), str(list)])

	# 计数:数 CheckButton 实例,不数字面量 —— 多一个少一个都红。
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
	# - 为什么单开一相:菜单上那两处载体不同 —— `main_menu` 直接写 `cb.text`,
	#   而两个大厅页走 `WeaponIcons.make_weapon_check(type_i, …)`,编号是变量实参
	#   (kh_l4 的字号扫描按下标 2 取那个实参,它只管字号)。只钉阶段 1 那一半的话,把编号
	#   加回 `make_weapon_check` 里的 Label 上照样全部断言通过。
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


func _find_named(root: Node, nm: String) -> Node:
	if root.name == nm:
		return root
	for c in root.get_children():
		var hit := _find_named(c, nm)
		if hit != null:
			return hit
	return null
