extends Node

# P2 编辑器场景探针:真实例化 editor_root.tscn,走「打开真实地图 → 改一格 → 保存 → 重开 → 再保存」
# 的字节级往返,并检查撤销/重做、校验、画布纹理。
# 去掉什么它才会红:
#   ① 编辑器场景构建失败/缺 API ⇒ ① 组红;
#   ② EditorIO 打开 .cyrm 不迁移/不解码 ⇒ ② 组红;
#   ③ EditorDoc.set_cells 没落到 map(改完读回不一致)⇒ ③ 组红;
#   ④ 保存链 encode/write 丢数据 ⇒ ⑩ 组「重开再存字节相等」红;
#   ⑤ undo/redo 不工作 ⇒ ④ 组红;
#   ⑥ 画布没建视口纹理 ⇒ ⑤ 组红;
#   ⑦ 没按设计系统重画(缺 HSplitContainer / TabContainer / 4 个 tab / 工具栏按钮 / 状态栏)⇒ ⑦ 组红;
#   ⑧ 用了绝对坐标/固定宽度导致控件溢出父容器 ⇒ ⑦ 组「无溢出」红。
# 判据 = 未跑满条数 + 失败清单;退出码只是陪衬。

const EXPECTED_CHECKS := 50
const MAP := "res://maps/newfactory.cyrm"
const A := "user://maps/_editor_scene_probe_a.cyrm"
const EXPORT_C := "user://maps/_editor_scene_probe_export.cyrm"
const USER_EXPORT := "user://maps/untitled.cyrm"
const B := "user://maps/_editor_scene_probe_b.cyrm"
const SUB := Vector2i(20, 20)

var _fails: Array[String] = []
var _checks := 0
var _editor: Control = null
var _doc: EditorDoc = null
var _sp_before := ""
var _mp_before := ""
var _map_before := ""
var _settings_bytes := PackedByteArray()
var _settings_existed := false
var _untitled_existed := false
var _user_export_created := false


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
		print("  ✗ " + msg)


func _ready() -> void:
	await get_tree().process_frame
	_cleanup()
	_backup_settings()

	var scene: PackedScene = load("res://scenes/editor/editor_root.tscn")
	_chk(scene != null, "① 空载守卫:load(editor_root.tscn) 为 null")
	if scene == null:
		_finish()
		return
	_editor = scene.instantiate() as Control
	_chk(_editor != null, "① editor_root.tscn 实例化失败")
	if _editor == null:
		_finish()
		return
	add_child(_editor)
	_editor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_editor.size = Vector2(1600, 900)
	await get_tree().process_frame
	await get_tree().process_frame

	_doc = _editor.get_doc() as EditorDoc
	_chk(_doc != null, "① get_doc() 返回 null")
	if _doc == null:
		_finish()
		return

	var opened: Dictionary = _editor.open_path(MAP)
	_chk(bool(opened.get("ok", false)), "② 打开 %s 失败:%s" % [MAP, String(opened.get("error", ""))])
	if not bool(opened.get("ok", false)):
		_finish()
		return
	var sub_size := _doc.sub_size()
	_chk(sub_size.x > 0 and sub_size.y > 0 and (_doc.map["layers"] as Array).size() == 7,
			"② 打开后尺寸/图层不对:sub=%s layers=%d" % [str(sub_size), (_doc.map["layers"] as Array).size()])

	var before := _doc.get_subcell(SUB.x, SUB.y)
	var target := EditorDesc.neutral_desc(6)   # 纹理 6「描边方块」,tile_defs 合法
	_doc.set_cells([SUB], target)
	_chk(_doc.get_subcell(SUB.x, SUB.y) == target,
			"③ set_cells 未落到 map:期望 0x%08X 实得 0x%08X" % [target, _doc.get_subcell(SUB.x, SUB.y)])
	_chk(_doc.dirty, "③ 改图后 dirty 应为 true")

	_chk(_doc.can_undo(), "④ 改图后应有撤销")
	_doc.undo()
	_chk(_doc.get_subcell(SUB.x, SUB.y) == before,
			"④ undo 未恢复旧值:期望 0x%08X 实得 0x%08X" % [before, _doc.get_subcell(SUB.x, SUB.y)])
	_doc.redo()
	_chk(_doc.get_subcell(SUB.x, SUB.y) == target, "④ redo 未恢复新值")

	var save_a: Dictionary = _editor.save_to(A)
	_chk(bool(save_a.get("ok", false)), "② 保存到 %s 失败:%s" % [A, String(save_a.get("error", ""))])

	var reopened: Dictionary = _editor.open_path(A)
	_chk(bool(reopened.get("ok", false)), "② 重开 %s 失败:%s" % [A, String(reopened.get("error", ""))])
	_chk(_doc.get_subcell(SUB.x, SUB.y) == target,
			"② 重开后改动的子格丢了:期望 0x%08X 实得 0x%08X" % [target, _doc.get_subcell(SUB.x, SUB.y)])

	var save_b: Dictionary = _editor.save_to(B)
	_chk(bool(save_b.get("ok", false)), "② 再保存到 %s 失败:%s" % [B, String(save_b.get("error", ""))])
	var raw_a := FileAccess.get_file_as_bytes(A)
	var raw_b := FileAccess.get_file_as_bytes(B)
	_chk(not raw_a.is_empty() and raw_a == raw_b,
			"② 重开再保存不是逐字节相等(%d vs %d 字节)" % [raw_a.size(), raw_b.size()])

	var report: Dictionary = _editor.validate()
	_chk(report.has("errors") and report.has("warnings"), "⑥ validate() 返回形状不对")

	var canvas: EditorCanvas = _editor.call("get_editor_canvas") as EditorCanvas
	_chk(canvas != null, "⑤ get_editor_canvas() 返回 null")
	if canvas != null:
		var tex = canvas.view_texture()
		_chk(tex != null and tex.get_width() > 0 and tex.get_height() > 0,
				"⑤ 画布视口纹理为空(期望非空)")

	await _check_ui_layout()
	_check_export_and_load()
	_check_deferred_features()
	_restore_settings()
	_cleanup()
	_finish()


# ── P3 导出两动作:只写文件的 export_to + Export&Load 的 Settings/MazeGenerator 状态 ──
func _check_export_and_load() -> void:
	var res: Dictionary = _editor.export_and_load(EXPORT_C, true, false)
	_chk(bool(res.get("ok", false)), "⑥ export_and_load 失败:%s" % String(res.get("error", "")))
	_chk(Settings.sp_map_path == EXPORT_C,
			"⑥ 导出并加载后 Settings.sp_map_path 应为 %s(实得 %s)" % [EXPORT_C, Settings.sp_map_path])
	_chk(MazeGenerator.map_file_path() == EXPORT_C,
			"⑥ 导出并加载后下一次 map_file_path() 应返回该文件(实得 %s)" % MazeGenerator.map_file_path())
	_chk(Settings.mp_map_path == _mp_before,
			"⑥ PvP 地图设置不该被「导出并加载」改动(%s → %s)" % [_mp_before, Settings.mp_map_path])
	# persist=true ⇒ Settings.save() 必须把单人地图路径写进 user://settings.cfg(下次开局仍用它)。
	var cf := ConfigFile.new()
	var cfg_ok := cf.load("user://settings.cfg") == OK
	_chk(cfg_ok and String(cf.get_value("single", "map_path", "")) == EXPORT_C,
			"⑥ 导出并加载的持久化没写进 settings.cfg(single/map_path=「%s」)" % String(cf.get_value("single", "map_path", "")))
	var exp: Dictionary = _editor.export_to("user")
	_chk(bool(exp.get("ok", false)), "⑥ 导出(只写文件)失败:%s" % String(exp.get("error", "")))
	_user_export_created = bool(exp.get("ok", false))
	_chk(_user_export_created and FileAccess.file_exists(USER_EXPORT)
			and FileAccess.get_file_as_bytes(USER_EXPORT).size() > 0,
			"⑥ 导出后文件应存在且非空:%s" % USER_EXPORT)


# ── 后置项:选区/剪贴板/镜像/渐变/meta 可视化/真渲染预览(都在场景里真接一遍) ──
# ── T3 设计系统重画:工具栏 / HSplitContainer / TabContainer(4 页)/ 状态栏 / 无溢出 ──
# ★ 这里只查结构与几何(节点类型、可见性、尺寸、是否在父 rect 内),不查颜色字面量:
#   去掉容器化或改回固定 400px 自绘右栏 ⇒ 溢出/尺寸断言红;删 tab 页 ⇒ 条数与标题红。
const UI_TAB_TITLES := [["图层"], ["调色板"], ["选区", "meta"], ["校验", "消息"]]
const UI_TOOLBAR_TEXTS := ["新建", "打开", "保存", "导出", "导出并加载",
		"撤销", "重做", "复制", "剪切", "粘贴", "清除", "水平镜像", "垂直镜像", "返回", "预览"]


func _check_ui_layout() -> void:
	# 等布局结算(含 editor_root 的 _layout_split 延后一帧推右栏宽)
	await get_tree().process_frame
	await get_tree().process_frame

	var split := _editor.find_child("Split", true, false) as HSplitContainer
	_chk(split != null and split.is_visible_in_tree(),
			"⑦ 找不到可见的 HSplitContainer(Split)")
	var tabs := _editor.find_child("RightTabs", true, false) as TabContainer
	_chk(tabs != null and tabs.is_visible_in_tree(),
			"⑦ 找不到可见的 TabContainer(RightTabs)")
	if split == null or tabs == null:
		# 结构没建出来时补足条数,避免条数闸把后续所有断言算成「中途夭折」
		for _i in 11:
			_chk(false, "⑦ 结构缺失:跳过后续布局断言")
		return

	_chk(tabs.get_tab_count() == 4,
			"⑦ 右栏 Tab 数期望 4(图层/调色板/选区&meta/校验·消息),实得 %d" % tabs.get_tab_count())
	var titles_ok := tabs.get_tab_count() == 4
	for i in tabs.get_tab_count():
		var title := tabs.get_tab_title(i)
		var wants: Array = UI_TAB_TITLES[i] if i < UI_TAB_TITLES.size() else []
		for w: String in wants:
			if title.find(w) < 0:
				titles_ok = false
	_chk(titles_ok, "⑦ Tab 标题应含 图层/调色板/选区·meta/校验·消息(实得 %s)" % str(_tab_titles(tabs)))

	var hidden := 0
	for i in tabs.get_tab_count():
		if tabs.is_tab_hidden(i):
			hidden += 1
	_chk(hidden == 0, "⑦ 4 个 Tab 都应为可见状态,实得隐藏 %d 个" % hidden)

	_chk(tabs.size.x >= 320.0,
			"⑦ 右栏最小宽度应 >= 320px(实得 %.1f)" % tabs.size.x)
	_chk(tabs.size.x >= 380.0 and tabs.size.x <= 420.0,
			"⑦ 右栏初始宽度应 ≈ 400px(实得 %.1f)" % tabs.size.x)

	# 分栏可拖拽:把 divider 往左拖 = 加宽右栏,右栏尺寸必须跟着变。
	var before_w := tabs.size.x
	split.split_offset -= 120
	await get_tree().process_frame
	var dragged_w := tabs.size.x
	split.split_offset += 120
	await get_tree().process_frame
	_chk(dragged_w > before_w + 60.0 and absf(tabs.size.x - before_w) < 2.0,
			"⑦ 拖拽分栏应改变右栏宽(前 %.1f / 拖后 %.1f / 复位 %.1f)" % [before_w, dragged_w, tabs.size.x])

	# 工具栏按钮(文件 5 + 视图 2 + 编辑 8)
	var toolbar := _editor.find_child("Toolbar", true, false) as Control
	var bar_texts := {}
	if toolbar != null:
		for node in toolbar.find_children("*", "Button", true, false):
			bar_texts[(node as Button).text] = true
	var missing: Array[String] = []
	for t: String in UI_TOOLBAR_TEXTS:
		var hit := false
		for got: String in bar_texts:
			if got.begins_with(t):
				hit = true
				break
		if not hit:
			missing.append(t)
	_chk(toolbar != null and toolbar.is_visible_in_tree() and missing.is_empty(),
			"⑦ 工具栏应含「文件/编辑/视图」全部按钮(缺 %s)" % str(missing))

	# 工具条(画笔/橡皮/…/渐变 8 个)
	var strip := _editor.find_child("ToolStrip", true, false) as Control
	var tool_n := 0
	if strip != null:
		tool_n = strip.find_children("*", "Button", true, false).size()
	_chk(strip != null and strip.is_visible_in_tree() and tool_n == 8,
			"⑦ 左栏工具条应有 8 个工具按钮(实得 %d)" % tool_n)

	# 图层页:7 层按钮
	var layer_btns := 0
	for node in tabs.get_child(0).find_children("*", "Button", true, false):
		if _is_layer_button((node as Button).text):
			layer_btns += 1
	_chk(layer_btns == 7, "⑦ 图层页应有 7 层按钮(实得 %d)" % layer_btns)

	# 调色板页:缩略图按钮 > 0
	var pal := tabs.get_child(1).find_child("PaletteGrid", true, false) as GridContainer
	_chk(pal != null and pal.get_child_count() >= 10,
			"⑦ 调色板页应铺纹理缩略图(实得 %d 个)" % (pal.get_child_count() if pal != null else 0))

	# 状态栏:存在、可见、有高度,且状态文本/路径文本都在
	var status := _editor.find_child("StatusBar", true, false) as Control
	var status_text := _editor.find_child("StatusText", true, false) as Label
	var path_text := _editor.find_child("PathText", true, false) as Label
	_chk(status != null and status.is_visible_in_tree() and status.size.y > 0.0
			and status_text != null and path_text != null,
			"⑦ 状态栏应存在且含状态/路径文本(status=%s)" % str(status))

	# 无溢出:每个可见 Control 都在父 Control 的 rect 内(容差 1px)。
	var bad: Array[String] = []
	_collect_overflow(_editor, bad)
	_chk(bad.is_empty(), "⑦ 控件溢出父容器(应为 0 个):%s" % str(bad))


func _tab_titles(tabs: TabContainer) -> Array[String]:
	var out: Array[String] = []
	for i in tabs.get_tab_count():
		out.append(tabs.get_tab_title(i))
	return out


func _is_layer_button(text: String) -> bool:
	for name in EditorConstants.LAYER_NAMES:
		if text == String(name):
			return true
	return false


func _collect_overflow(node: Node, bad: Array[String]) -> void:
	for child in node.get_children():
		if child is Window:
			continue                                  # 标准弹层是独立窗口,不参与页面 rect 检查
		if child is Control:
			var c: Control = child
			var p := c.get_parent() as Control
			if p != null and c.is_visible_in_tree():
				var pr := Rect2(Vector2.ZERO, p.size)
				var cr := Rect2(c.position, c.size)
				if cr.position.x < pr.position.x - 1.0 or cr.position.y < pr.position.y - 1.0 						or cr.end.x > pr.end.x + 1.0 or cr.end.y > pr.end.y + 1.0:
					bad.append("%s(%s)" % [c.name, c.get_class()])
		_collect_overflow(child, bad)


func _check_deferred_features() -> void:
	var sel := Rect2i(0, 0, 8, 8)
	_doc.set_selection(sel)
	_chk(_doc.has_selection() and _doc.selection == sel, "⑨ 选区设置/回读:%s" % str(_doc.selection))

	var d := EditorDesc.neutral_desc(6)
	_doc.active_layer = 1
	var cells: Array[Vector2i] = []
	for sy in 2:
		for sx in 2:
			cells.append(Vector2i(SUB.x + sx, SUB.y + sy))
	_doc.set_cells(cells, d)
	_doc.set_selection(Rect2i(SUB.x, SUB.y, 2, 2))
	var copied := _doc.copy_selection()
	_chk(bool(copied.get("ok", false)) and int(copied.get("w", 0)) == 2 and int(copied.get("h", 0)) == 2,
			"⑨ 复制 2×2 选区:%s" % str(copied))

	var at := Vector2i(60, 60)
	_doc.set_selection(Rect2i())
	var pasted := _doc.paste_clipboard(at)
	_chk(bool(pasted.get("ok", false)) and _doc.get_subcell(at.x * 4, at.y * 4) == d,
			"⑨ 粘贴到格 (60,60) 未落到 map(实得 0x%08X)" % _doc.get_subcell(at.x * 4, at.y * 4))

	# 真图在 (80,80) 附近本来就有地形 ⇒ 先把 4×4 选区清成空气再摆左两列,期望值不依赖原图内容。
	var d2 := EditorDesc.neutral_desc(7)
	var clear_cells: Array[Vector2i] = []
	var left: Array[Vector2i] = []
	for sy in 4:
		for sx in 4:
			clear_cells.append(Vector2i(80 + sx, 80 + sy))
			if sx < 2:
				left.append(Vector2i(80 + sx, 80 + sy))
	_doc.set_cells(clear_cells, 0)
	_doc.set_cells(left, d2)
	_doc.set_selection(Rect2i(80, 80, 4, 4))
	var mirrored := _doc.mirror_selection("h")
	_chk(bool(mirrored.get("ok", false)) and _doc.get_subcell(83, 80) == d2 and _doc.get_subcell(80, 80) == 0,
			"⑨ 水平镜像选区未翻转到右列")

	_doc.active_layer = 3
	var grad := _doc.paint_gradient(Vector2i(0, 0),
			Vector2i(_doc.sub_size().x - 1, _doc.sub_size().y - 1), 0xFF0000FF, 0x0000FFFF)
	var g0 := _doc.get_subcell(0, 0) & 0xFFFFFFFF
	_chk(bool(grad.get("ok", false)) and g0 == 0xFF0000FF,
			"⑨ 颜色层渐变起点应= rgba0(实得 0x%08X)" % g0)

	# 真图本来就可能带 PvP 出生点/复活点 ⇒ 全部用「加之前 vs 加之后」的差来断言。
	var players_before := (_doc.map["players"] as Array).size()
	var respawns_before := (_doc.map["respawns"] as Array).size()
	var enemies_before := (_doc.map["enemies"] as Array).size()
	_doc.add_player(Vector2i(3, 3))
	_doc.add_respawn(1, Vector2i(4, 4))
	_doc.add_enemy("slime", Vector2i(5, 5))
	_chk((_doc.map["players"] as Array).size() == players_before + 1
			and (_doc.map["respawns"] as Array).size() == respawns_before + 1
			and (_doc.map["enemies"] as Array).size() == enemies_before + 1,
			"⑨ meta add_player/add_respawn/add_enemy 数量不对")
	_chk(_doc.remove_player_at(Vector2i(3, 3)) and (_doc.map["players"] as Array).size() == players_before,
			"⑨ remove_player_at 未删掉")
	var expected_clear := players_before + (respawns_before + 1) + (enemies_before + 1)
	var cleared := _doc.clear_meta("all")
	_chk(cleared == expected_clear
			and (_doc.map["players"] as Array).is_empty()
			and (_doc.map["respawns"] as Array).is_empty()
			and (_doc.map["enemies"] as Array).is_empty(),
			"⑨ clear_meta(all) 应删 %d 条并清空(实得 %d)" % [expected_clear, cleared])

	_editor.set_preview(true)
	var preview: Control = _editor.get_preview()
	_chk(bool(_editor.is_preview_on()) and preview != null, "⑨ 打开预览失败")
	if preview != null:
		var st: Dictionary = preview.stats()
		_chk(bool(st.get("ready", false)) and int(st.get("tiles", 0)) > 0,
				"⑨ 预览应已建好并铺了瓦片:%s" % str(st))
	_editor.set_preview(false)
	_chk(not bool(_editor.is_preview_on()), "⑨ 关闭预览失败")



func _backup_settings() -> void:
	_sp_before = Settings.sp_map_path
	_mp_before = Settings.mp_map_path
	_map_before = MazeGenerator.map_file_path()
	_settings_existed = FileAccess.file_exists("user://settings.cfg")
	if _settings_existed:
		_settings_bytes = FileAccess.get_file_as_bytes("user://settings.cfg")
	_untitled_existed = FileAccess.file_exists(USER_EXPORT)


func _restore_settings() -> void:
	Settings.sp_map_path = _sp_before
	Settings.mp_map_path = _mp_before
	MazeGenerator.set_map_file(_map_before)
	if _settings_existed:
		var f := FileAccess.open("user://settings.cfg", FileAccess.WRITE)
		if f != null:
			f.store_buffer(_settings_bytes)
			f.close()
	elif FileAccess.file_exists("user://settings.cfg"):
		DirAccess.remove_absolute("user://settings.cfg")


func _cleanup() -> void:
	for p in [A, B, EXPORT_C]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	if _user_export_created and not _untitled_existed and FileAccess.file_exists(USER_EXPORT):
		DirAccess.remove_absolute(USER_EXPORT)


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		print("EDITOR SCENE PROBE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		get_tree().quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR SCENE PROBE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		get_tree().quit(1)
		return
	print("EDITOR SCENE PROBE: ALL-OK(%d 条断言)" % _checks)
	get_tree().quit(0)
