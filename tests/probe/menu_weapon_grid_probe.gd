extends ProbeBase


const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const LOBBY_PAGE_SRC := "res://scenes/lobby_page.gd"

# 预期断言总数
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
	_c(ids.size() >= 1, "武器注册表包含有效武器配置(实际 %d 把)" % ids.size())

	# 阶段 1：主菜单单人面板中的武器禁用复选框
	var menu = (load(MAIN_MENU_SCENE) as PackedScene).instantiate()
	add_child(menu)
	await get_tree().process_frame
	await get_tree().process_frame
	menu._on_single_pressed()
	var panel = menu._sp_panel
	var list: VBoxContainer = null
	if panel != null:
		list = _find_named(panel, "CheckList") as VBoxContainer
	_c(panel != null and list != null,
			"_on_single_pressed() 创建单人面板及 CheckList 列表容器")

	var cbs: Array[CheckButton] = []
	var texts: Array[String] = []
	if list != null:
		for c in list.get_children():
			if c is CheckButton:
				cbs.append(c)
				texts.append((c as CheckButton).text)
	_c(cbs.size() == ids.size(),
			"复选框数量应与注册表配置数量一致(实际 %d，注册表 %d)" % [cbs.size(), ids.size()])

	var want: Array[String] = []
	for id in ids:
		want.append(WeaponRegistry.name_of(id))
	_c(texts == want,
			"每个复选框的文本应与武器名称一致(实得 %s，期望 %s)" % [str(texts), str(want)])

	# 阶段 2：WeaponIcons.make_weapon_check 生成的单元格组件
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
	_c(cell_found, "WeaponIcons.make_weapon_check 为各武器生成含 Label 的单元格")
	_c(cell_texts == want,
			"单元格 Label 文本应与武器名称一致(实得 %s，期望 %s)" % [str(cell_texts), str(want)])

	var lb := _read(LOBBY_PAGE_SRC)
	_c(not lb.is_empty(), "成功读取大厅源码文件: %s" % LOBBY_PAGE_SRC)
	var grid_body := _func_body(_code_only(lb), "_add_weapon_grid")
	_c(grid_body.contains("WeaponIcons.make_weapon_check("),
			"lobby_page._add_weapon_grid 应调用 WeaponIcons.make_weapon_check 构建武器单元格")

	menu.free()

	if _checks != EXPECTED_CHECKS:
		_failures.append("实际执行断言数 %d 与预期 EXPECTED_CHECKS=%d 不一致"
				% [_checks, EXPECTED_CHECKS])
	_summary(0, "菜单武器网格: %d 条断言" % _checks)
	_finish()


func _find_named(root: Node, nm: String) -> Node:
	if root.name == nm:
		return root
	for c in root.get_children():
		var hit := _find_named(c, nm)
		if hit != null:
			return hit
	return null
