extends Control

# 编辑器场景根(**只做装配/接线/公开 API**):UI 在 editor_root.tscn(theme=menu_theme.tres);工具/指针在
# editor_tools.gd,命令/弹层在 editor_actions.gd,画布在 editor_canvas.gd,左栏+图层卡在 editor_layer_panel.gd,
# 右栏 meta 面板在 editor_meta_panel.gd,预览+试玩在 editor_view_controls.gd,纯逻辑在 core/editor/。
# ★ 进客户端导出包 ⇒ 禁止 RegEx。坐标 = 子格(16px);格 = 子格/4。探针只调公开 API 与 UI 节点。

const TOOLS_SCRIPT := preload("res://scenes/editor/editor_tools.gd")
const ACTIONS_SCRIPT := preload("res://scenes/editor/editor_actions.gd")
const LAYER_PANEL_SCRIPT := preload("res://scenes/editor/editor_layer_panel.gd")
const META_PANEL_SCRIPT := preload("res://scenes/editor/editor_meta_panel.gd")
const VIEW_SCRIPT := preload("res://scenes/editor/editor_view_controls.gd")
const PLAYTEST_SCRIPT := preload("res://scenes/editor/editor_playtest.gd")
const THEME := preload("res://ui/theme/menu_theme.tres")
const RIGHT_DEFAULT_W := 320.0        # 右栏初始宽(图层卡 + 2 Tab;最小宽写在 tscn 的 RightSide)

# tscn 里的按钮节点名 ↔ 语义键(顺序即工具网格顺序)。
const TOOL_BUTTONS := {
	"brush": "ToolBrush", "eraser": "ToolEraser", "line": "ToolLine", "rect": "ToolRect",
	"bucket": "ToolBucket", "eyedrop": "ToolEyedrop", "select": "ToolSelect",
	"move": "ToolMove", "hand": "ToolHand", "gradient": "ToolGradient",
}
# 工具快捷键(无 Ctrl;镜像改到 Shift+H / Shift+V 让位给 移动/手形)。
const TOOL_KEYS := {
	"brush": "B", "eraser": "E", "line": "L", "rect": "R", "bucket": "G",
	"eyedrop": "I", "select": "M", "move": "V", "hand": "H", "gradient": "T",
}
const TOOL_KEYCODES := {
	"brush": KEY_B, "eraser": KEY_E, "line": KEY_L, "rect": KEY_R, "bucket": KEY_G,
	"eyedrop": KEY_I, "select": KEY_M, "move": KEY_V, "hand": KEY_H, "gradient": KEY_T,
}
const META_BUTTONS := {
	"none": "MetaEdit", "player": "MetaPlayer", "respawn1": "MetaRespawn1",
	"respawn2": "MetaRespawn2", "enemy": "MetaEnemy",
}

var doc: EditorDoc = null
var canvas: EditorCanvas = null

var _tools = TOOLS_SCRIPT.new()
var _actions = ACTIONS_SCRIPT.new()
var _layers = LAYER_PANEL_SCRIPT.new()
var _meta = META_PANEL_SCRIPT.new()
var _view = VIEW_SCRIPT.new()

var _path := ""
var _tool_buttons: Dictionary = {}
var _meta_buttons: Dictionary = {}
var _status: Label = null
var _status_info: Label = null
var _doc_label: Label = null
var _path_label: Label = null
var _output: RichTextLabel = null
var _message := ""
var _enemy_types: Array[String] = []
var _canvas_host: Control = null
var _split: HSplitContainer = null
var _tabs: TabContainer = null
var _undo_btn: Button = null
var _redo_btn: Button = null
var _zoom_text: Label = null
var _selection_info: Label = null


func _ready() -> void:
	doc = EditorDoc.new()
	# 从试玩回来:取回同一个 EditorDoc(撤销栈/选区都还在),并还原被临时钉住的地图路径。
	var restored := PLAYTEST_SCRIPT.take_restore()
	if not restored.is_empty():
		doc = restored["doc"] as EditorDoc
		_path = String(restored.get("path", ""))
		MazeGenerator.set_map_file(String(restored.get("picked_map", "")))
	Level0.playtest_mode = false
	canvas = %Canvas as EditorCanvas
	_tools.setup(doc, canvas)
	_actions.setup(self)
	_layers.setup(self, doc, canvas, _tools, _tool_buttons, TOOL_KEYS)
	_register_editor_actions()
	_wire_ui()
	_layers.wire()
	canvas.set_doc(doc)
	_view.build()
	doc.changed.connect(_on_doc_changed)
	doc.structure_changed.connect(_on_doc_structure_changed)
	doc.meta_changed.connect(_on_doc_meta_changed)
	doc.history_changed.connect(_update_history_buttons)
	# 关窗也要拦未保存改动:auto_accept_quit=false ⇒ 由本场景的 _notification 决定退不退。
	get_tree().auto_accept_quit = false
	canvas.pointer_down.connect(_tools.pointer_down)
	canvas.pointer_drag.connect(_tools.pointer_drag)
	canvas.pointer_up.connect(_tools.pointer_up)
	canvas.cursor_moved.connect(_on_cursor_moved)
	canvas.zoom_changed.connect(_on_zoom_changed)
	if not restored.is_empty():
		_adopt_restored_doc.call_deferred()
	else:
		_set_message("新图 125×75 格;F1 快捷键 · F5 试玩 · Ctrl+G 跳转 · 右键小地图跳转;Ctrl+O 打开、Ctrl+S 保存", false)
	_update_status(Vector2i.ZERO, false)


# 试玩返回后的画布/面板同步:文档对象是原样取回的,但场景是新建的 ⇒ 相机/图层行/调色板要重新喂一遍。
func _adopt_restored_doc() -> void:
	canvas.set_active_layer(doc.active_layer)
	canvas.fit_to_map()
	_layers.sync_layer_rows()
	_layers.sync_tool_availability()
	_layers.refresh_palette_texture()
	_update_zoom_label()
	_update_history_buttons()
	if doc.map.is_empty():
		_set_message("已从试玩返回:地图是空的", false)
	else:
		_set_message("已从试玩返回(未保存改动与撤销栈都还在)", false)


func _process(dt: float) -> void:
	_view.process(dt)


# 关窗(Alt+F4 / 窗口 X)也要拦未保存改动:_ready 里把 auto_accept_quit 置 false,
# 这里收 NOTIFICATION_WM_CLOSE_REQUEST —— dirty 走确认弹层,干净才真退。
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	if doc != null and doc.dirty:
		_actions.confirm_quit()
	else:
		get_tree().quit()


func _exit_tree() -> void:
	# 离开编辑器(返回主菜单 / 导出并加载 / 被测例释放)必须还原,否则主菜单也关不掉窗口。
	if get_tree() != null:
		get_tree().auto_accept_quit = true


# ── 公开 API(场景探针用;也是按钮/命令层的落点)──────────────────────────

func get_doc() -> EditorDoc:
	return doc


func get_editor_canvas() -> EditorCanvas:
	return canvas


func current_path() -> String:
	return _path


func map_name() -> String:
	var n := ""
	if not doc.map.is_empty():
		n = String(doc.map.get("name", ""))
	return "untitled" if n == "" else n


func notify(text: String, is_error: bool = false) -> void:
	_set_message(text, is_error)


func open_path(path: String) -> Dictionary:
	var res := EditorIO.open_path(path)
	if not bool(res.get("ok", false)):
		_set_message("打开失败:%s" % String(res.get("error", "")), true)
		return res
	doc.load_map(res["map"])
	_path = path
	canvas.set_active_layer(doc.active_layer)
	canvas.fit_to_map()
	_layers.sync_layer_rows()
	_layers.sync_tool_availability()
	_layers.refresh_palette_texture()
	_set_message("已打开 %s(%s)" % [path, String(res.get("source", "v4"))], false)
	if not (res.get("warnings", []) as Array).is_empty():
		_append_output("打开时校验提示:\n- " + "\n- ".join(res["warnings"]))
	_update_zoom_label()
	_update_history_buttons()
	_update_status(Vector2i.ZERO, false)
	return res


func new_map(cells_w: int, cells_h: int, map_name_arg: String = "untitled") -> void:
	doc.new_map(map_name_arg, cells_w, cells_h)
	_path = ""
	canvas.fit_to_map()
	_layers.sync_layer_rows()
	_layers.sync_tool_availability()
	_set_message("已新建 %d×%d 格" % [cells_w, cells_h], false)
	_update_zoom_label()
	_update_history_buttons()
	_update_status(Vector2i.ZERO, false)


func save_to(path: String) -> Dictionary:
	var res := EditorIO.save_path(path, doc.map)
	if not bool(res.get("ok", false)):
		var lines: Array = ["保存失败:%s" % String(res.get("error", ""))]
		for e in res.get("errors", []):
			lines.append("  error: " + String(e))
		for w in res.get("warnings", []):
			lines.append("  warn: " + String(w))
		_append_output("\n".join(lines))
		_set_message("保存失败:%s" % String(res.get("error", "")), true)
		_show_output_tab()
		return res
	_path = path
	doc.dirty = false
	_set_message("已保存 %s(%d 字节)" % [path, int(res.get("bytes", 0))], false)
	if not (res.get("warnings", []) as Array).is_empty():
		_append_output("保存时校验提示:\n- " + "\n- ".join(res["warnings"]))
	_update_status(Vector2i.ZERO, false)
	return res


func save_current() -> Dictionary:
	if _path != "":
		return save_to(_path)
	return save_to(EditorIO.default_target(map_name()))


func validate() -> Dictionary:
	var report := doc.validate()
	_show_report(report)
	return report


func export_to(target: String) -> Dictionary:
	return _export_target(map_name(), target == "exe")


func _export_target(target_name: String, to_exe_dir: bool) -> Dictionary:
	var res: Dictionary
	if to_exe_dir:
		res = EditorIO.copy_to_exe_dir(doc.map, target_name)
	else:
		res = EditorIO.save_path(EditorIO.default_target(target_name), doc.map)
	if not bool(res.get("ok", false)):
		_append_output("导出失败:%s" % String(res.get("error", "")))
		_set_message("导出失败:%s" % String(res.get("error", "")), true)
		return res
	_path = String(res.get("path", _path))
	doc.dirty = false
	_append_output("已导出:%s(%d 字节)" % [_path, int(res.get("bytes", 0))])
	_set_message("已导出:%s" % _path, false)
	_update_status(Vector2i.ZERO, false)
	return res


# 导出并加载到游戏内:写文件 → Settings.sp_map_path → Settings.save() → MazeGenerator.set_map_file()。
# ★ switch_scene=true 时回单人开局;persist=false 只改内存(场景探针用,避免动用户 settings.cfg)。
func export_and_load(path: String, persist: bool = true, switch_scene: bool = true) -> Dictionary:
	if path.is_empty():
		return {"ok": false, "error": "exportAndLoad: 路径为空"}
	var res := save_to(path)
	if not bool(res.get("ok", false)):
		return res
	Settings.sp_map_path = path
	if persist:
		Settings.save()
	MazeGenerator.set_map_file(path)
	RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()
	Level0.pvp_mode = false
	CombatComponent.pvp_arena = false
	_set_message("已导出并设为单人地图:%s" % path, false)
	_append_output("下一次单人开局将使用:%s(PvP 不受影响:联机地图由大厅/服务端下发的 path 覆盖)" % path)
	if switch_scene:
		get_tree().change_scene_to_file("res://scenes/level_0.tscn")
	return res


# ── 预览 / 试玩的公开转发(探针与命令层只用 root 这几个口)────────────────

func get_preview() -> Control:
	return _view.get_preview()


func is_preview_on() -> bool:
	return _view.is_preview_on()


func set_preview(on: bool) -> void:
	_view.set_preview(on)


func set_preview_hour(hour: float) -> void:
	_view.set_hour(hour)


func get_preview_hour() -> float:
	return _view.get_hour()


func start_playtest(spawn_cell: Vector2i = Vector2i(-1, -1)) -> Dictionary:
	return _view.start_playtest(spawn_cell)


# ── UI 接线(scene 树见 editor_root.tscn;这里只连信号 + 填动态内容)──────────

func _wire_ui() -> void:
	_status = %StatusText
	_status_info = %StatusInfo
	_doc_label = %DocLabel
	_path_label = %PathText
	_output = %Output
	_selection_info = %SelectionInfo
	_canvas_host = %CanvasHost
	_split = %Split
	_tabs = %RightTabs
	_view.setup(self, doc, canvas, _canvas_host)
	_meta.setup(self, doc, _tools, %MetaInfo, %MetaList, %MetaToggle)

	# 少数颜色 token 不在 tscn 里重复写值(single source = UiFactory.C_*)。
	# 标题从 32 号亮青降成 16 号弱化:菜单栏是"窗口标题"语气,不跟画布抢焦点。
	(%TitleLabel as Label).theme_type_variation = &"SmallDim"
	for name: String in ["ViewLabel", "ToolsHint", "BrushHint", "ColorHint", "PaletteHint", "HelpHint",
			"LayersHint", "StatusInfo", "DocLabel", "PathText", "SelHint", "MetaHint",
			"ReportHint", "SelectionInfo", "MetaInfo", "MetaListHint", "EnemyTypeLabel", "ZoomText"]:
		var l := get_node_or_null("%" + name) as Label
		if l != null:
			l.add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
	# 状态栏消息是「当前发生了什么」,比右侧读数(尺寸/层/子格)更重要 ⇒ 亮一档。
	(%StatusText as Label).add_theme_color_override("font_color", UiFactory.C_TEXT)
	# 面板分组标题 = 比内容亮一档 + 上方留白。像素字只有 16 一档可选(32 留给卡片/页面标题),
	# 所以层次靠「对比 + 间距 + 位置 + 分组」建立,不靠字号。内容行一律 C_TEXT_DIM 或 accent(选中态)。
	for name: String in ["SelectionTitle", "MetaTitle", "MetaListHint",
			"ToolsHint", "BrushHint", "ColorHint", "PaletteHint"]:
		var h := get_node_or_null("%" + name) as Label
		if h != null:
			h.add_theme_color_override("font_color", UiFactory.C_TEXT)
			h.custom_minimum_size = Vector2(0, 26)

	_tabs.set_tab_title(0, "选区 & meta")
	_tabs.set_tab_title(1, "校验消息")

	# 工具网格(左栏 10 键;悬停提示带快捷键)
	for key: String in TOOL_BUTTONS:
		var b := get_node("%" + String(TOOL_BUTTONS[key])) as Button
		b.theme_type_variation = &"ToolButton"
		b.tooltip_text = "%s (%s)" % [_tools.label_of(key), String(TOOL_KEYS.get(key, ""))]
		b.pressed.connect(_tools.set_tool.bind(key))
		_tool_buttons[key] = b

	# 顶栏撤销/重做/保存/跳转/帮助:高频动作从菜单提到一级。
	for nm: String in ["UndoBtn", "RedoBtn", "JumpBtn", "HelpBtn"]:
		(get_node("%" + nm) as Button).theme_type_variation = &"FlatButton"
	(%UndoBtn as Button).pressed.connect(_actions.undo)
	(%RedoBtn as Button).pressed.connect(_actions.redo)
	(%SaveBtn as Button).pressed.connect(_actions.save_pressed)
	(%JumpBtn as Button).pressed.connect(_actions.jump_dialog)
	(%HelpBtn as Button).pressed.connect(_actions.shortcut_help)
	_undo_btn = %UndoBtn
	_redo_btn = %RedoBtn

	# 菜单栏(文件 5 项 / 编辑 8 项;popup 项是动态内容)
	_fill_menu(%FileMenu as MenuButton, [
		["新建", _actions.new_map_dialog], ["打开", _actions.open_dialog],
		["保存", _actions.save_pressed], ["导出", _actions.export_dialog],
		["导出并加载", _actions.export_load_pressed]])
	_fill_menu(%EditMenu as MenuButton, [
		["撤销", _actions.undo], ["重做", _actions.redo], ["复制", _actions.copy],
		["剪切", _actions.cut], ["粘贴", _actions.paste], ["清除", _actions.clear_selection],
		["水平镜像", _actions.mirror.bind("h")], ["垂直镜像", _actions.mirror.bind("v")]])
	# 顶栏命令:菜单用 MenuButton 基础扁平皮,视图按钮用 FlatButton(透明底,hover 才出底)。
	(%FileMenu as MenuButton).theme_type_variation = &""
	(%EditMenu as MenuButton).theme_type_variation = &""
	# 顶栏只有一个主行动 = 保存:accent 字 + 左侧 accent 条(复用紧凑强调皮);其余全部 FlatButton。
	(%SaveBtn as Button).theme_type_variation = &"ToolActive"
	for nm: String in ["PreviewBtn", "PlaytestBtn", "BackBtn"]:
		(get_node("%" + nm) as Button).theme_type_variation = &"FlatButton"
	(%BackBtn as Button).pressed.connect(_actions.back)
	_view.wire(%PreviewBtn as Button, %PlaytestBtn as Button)

	# 右栏的次级按钮(选区 6 / meta 5 / 校验)统一扁平;当前态由 _on_*_changed 换 variation。
	for nm: String in ["SelCopy", "SelCut", "SelPaste", "SelClear", "SelMirrorH", "SelMirrorV",
			"MetaEdit", "MetaPlayer", "MetaRespawn1", "MetaRespawn2", "MetaEnemy",
			"ClearMetaBtn", "ValidateBtn"]:
		var b := get_node_or_null("%" + nm) as Button
		if b != null:
			b.theme_type_variation = &"FlatButton"

	# 调色板缩略图是动态内容(图集按 tile_defs 生成);按钮列表本身也在 tscn 之外生成。
	_layers.build_palette(%PaletteGrid as GridContainer)

	var brush_opt := %BrushSizeOption as OptionButton
	for n in [1, 3, 5, 7, 9]:
		brush_opt.add_item(str(n))
		brush_opt.set_item_metadata(brush_opt.item_count - 1, n)
	brush_opt.selected = 0
	brush_opt.item_selected.connect(func(i: int) -> void:
		_tools.set_brush_cells(float(brush_opt.get_item_metadata(i))))
	_tools.set_brush_cells(1.0)

	var color_btn := %BrushColor as ColorPickerButton
	color_btn.color = _tools.color_value
	color_btn.color_changed.connect(func(c: Color) -> void: _tools.set_color(c))
	# 工具层改色(吸管/初始化)也要回写到取色器;相等时不回写,避免 set_color ↔ 取色器信号成环。
	_tools.color_changed.connect(func(c: Color) -> void:
		if not color_btn.color.is_equal_approx(c):
			color_btn.color = c)
	var grad_btn := %GradientEndColor as ColorPickerButton
	grad_btn.color = _tools.gradient_end
	grad_btn.color_changed.connect(func(c: Color) -> void: _tools.gradient_end = c)

	# 敌人类型下拉:单一数据源 = data/enemies.json(默认值也是合法 id,不再写死 "slime")。
	_load_enemy_types()
	_meta.set_enemy_types(_enemy_types)
	var enemy_opt := %EnemyTypeOption as OptionButton
	for type_id: String in _enemy_types:
		enemy_opt.add_item(type_id)
	if not _enemy_types.is_empty():
		enemy_opt.selected = 0
		_tools.set_enemy_type(_enemy_types[0])
	enemy_opt.item_selected.connect(func(i: int) -> void:
		if i >= 0 and i < _enemy_types.size():
			_tools.set_enemy_type(_enemy_types[i]))

	var sel_actions := {"SelCopy": _actions.copy, "SelCut": _actions.cut, "SelPaste": _actions.paste,
		"SelClear": _actions.clear_selection, "SelMirrorH": _actions.mirror.bind("h"),
		"SelMirrorV": _actions.mirror.bind("v")}
	for name: String in sel_actions:
		(get_node("%" + name) as Button).pressed.connect(sel_actions[name])
	for key: String in META_BUTTONS:
		var b := get_node("%" + String(META_BUTTONS[key])) as Button
		b.pressed.connect(_tools.set_meta_mode.bind(key))
		_meta_buttons[key] = b
	(%ClearMetaBtn as Button).pressed.connect(_meta.clear_all)
	(%ClearMetaBtn as Button).add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
	(%ValidateBtn as Button).pressed.connect(_actions.validate)

	# 状态栏缩放控件(与滚轮 / ± 快捷键同源;百分比 = zoom / 默认档)。
	_zoom_text = %ZoomText
	for nm: String in ["ZoomOutBtn", "ZoomInBtn", "FitBtn"]:
		(get_node("%" + nm) as Button).theme_type_variation = &"FlatButton"
	(%ZoomOutBtn as Button).pressed.connect(canvas.zoom_out)
	(%ZoomInBtn as Button).pressed.connect(canvas.zoom_in)
	(%FitBtn as Button).pressed.connect(_on_fit_pressed)

	# 移动工具的画布拖拽落点:画布只发几何信号,doc 写入在工具层。
	canvas.selection_move_started.connect(_on_selection_move_started)
	canvas.selection_move_finished.connect(_tools.apply_selection_move)
	canvas.meta_drag_started.connect(_on_meta_drag_started)
	canvas.meta_drag_finished.connect(_tools.apply_meta_move)
	canvas.player_playtest_requested.connect(_view.on_player_marker_clicked)

	_tools.message.connect(_set_message)
	_tools.tool_changed.connect(_on_tool_changed)
	_tools.paint_desc_changed.connect(_on_paint_desc_changed)
	_tools.meta_mode_changed.connect(_on_meta_mode_changed)
	_tools.selection_changed.connect(_update_selection_info)
	_on_tool_changed(_tools.tool)
	_on_meta_mode_changed(_tools.meta_mode)
	_layers.sync_tool_availability()
	_meta.sync()
	_update_history_buttons()
	_update_zoom_label()
	_layout_split.call_deferred()


func _load_enemy_types() -> void:
	_enemy_types.clear()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/enemies.json"))
	if parsed is Dictionary:
		for item in (parsed as Dictionary).get("enemies", []):
			if item is Dictionary and (item as Dictionary).has("id"):
				_enemy_types.append(String((item as Dictionary)["id"]))
	if _enemy_types.is_empty():
		_enemy_types = ["jump_bird", "fly_bird", "black_bird"]


func _fill_menu(mb: MenuButton, items: Array) -> void:
	var pop := mb.get_popup()
	pop.theme = THEME
	for i in items.size():
		pop.add_item(String((items[i] as Array)[0]), i)
	pop.id_pressed.connect(func(id: int) -> void:
		var cb: Callable = (items[id] as Array)[1]
		cb.call())


# 让右侧初始宽度 = RIGHT_DEFAULT_W(可继续拖拽):SplitContainer 默认按子节点最小尺寸分。
func _layout_split() -> void:
	if _split == null or _tabs == null:
		return
	await get_tree().process_frame
	# 负 offset 把 divider 右移(加宽右栏);正值会被钳回最小宽度 ⇒ -RIGHT_DEFAULT_W = 初始 320。
	_split.split_offset = -int(RIGHT_DEFAULT_W)


# ── 工具/meta 放置的显示态 ─────────────────────────────────────────────

func _on_tool_changed(key: String) -> void:
	for k: String in _tool_buttons:
		var b: Button = _tool_buttons[k]
		b.theme_type_variation = &"ToolActive" if k == key else &"ToolButton"
	# 预览是盖在画布上的一层:移动/手形要看到选区框与 meta 标记,开着预览就先把预览关掉。
	if (key == "move" or key == "hand") and _view.is_preview_on():
		_view.set_preview(false)
	_update_status(Vector2i.ZERO, false)


func _on_paint_desc_changed(desc: int) -> void:
	_layers.mark_palette(EditorDesc.tex_of(desc))


func _on_meta_mode_changed(key: String) -> void:
	for k: String in _meta_buttons:
		var b: Button = _meta_buttons[k]
		b.theme_type_variation = &"ToolActive" if k == key else &"FlatButton"
		b.modulate = UiFactory.C_WHITE
	_update_status(Vector2i.ZERO, false)


# ── doc / 画布 回调 ─────────────────────────────────────────────────────

func _on_doc_changed(_layer: int, _subcells: PackedInt32Array) -> void:
	_update_history_buttons()
	_update_status(Vector2i.ZERO, false)


func _on_doc_structure_changed() -> void:
	canvas.refresh()
	canvas.set_selection(doc.selection)       # 换图/新建清了 doc.selection,别让旧选框留在画布上
	_layers.sync_layer_rows()
	_layers.sync_tool_availability()
	_meta.sync()
	_update_selection_info()
	_update_history_buttons()


func _on_cursor_moved(sub: Vector2i) -> void:
	_update_status(sub, true)


func _on_zoom_changed(_zoom: float) -> void:
	_update_zoom_label()
	_update_status(Vector2i.ZERO, false)


func _on_doc_meta_changed() -> void:
	canvas.queue_redraw()
	_meta.sync()
	_update_history_buttons()
	_update_status(Vector2i.ZERO, false)


# 移动工具开始拖选区 / 拖 meta 标记时给一行提示(落点写入在工具层)。
func _on_selection_move_started() -> void:
	_set_message("移动选区:松开左键落位(Esc 不生效,可直接撤销)", false)


func _on_meta_drag_started(kind: String, index: int) -> void:
	_set_message("拖动%s#%d:松开左键落位" % [_tools.meta_label_of(kind), index], false)


func _on_fit_pressed() -> void:
	canvas.fit_to_map()


func _update_selection_info() -> void:
	if _selection_info == null or doc == null:
		return
	if not doc.has_selection():
		_selection_info.text = "无选区"
		return
	var r := doc.selection
	_selection_info.text = "%d×%d 子格 @ (%d,%d)" % [r.size.x, r.size.y, r.position.x, r.position.y]


# ── 状态栏 / 校验输出 / 快捷键 ─────────────────────────────────────────

func _show_report(report: Dictionary) -> void:
	var errors: Array = report.get("errors", [])
	var warnings: Array = report.get("warnings", [])
	var lines: Array[String] = []
	lines.append("校验:%d error / %d warning" % [errors.size(), warnings.size()])
	for e in errors:
		lines.append("  [error] " + String(e))
	for w in warnings:
		lines.append("  [warn] " + String(w))
	if not errors.is_empty():
		_set_message("校验失败:%s" % String(errors[0]), true)
	else:
		_set_message("校验通过(%d 条提示)" % warnings.size(), false)
	_append_output("\n".join(lines))
	_show_output_tab()


# 校验/保存失败的结果藏在 Tab 里等于没给 ⇒ 自动切到「校验消息」。
func _show_output_tab() -> void:
	if _tabs != null and _tabs.get_tab_count() > 1:
		_tabs.current_tab = 1


# 撤销/重做按钮的可用态跟 doc 栈走(菜单项仍恒可点,点了给「没有可撤销的操作」)。
func _update_history_buttons() -> void:
	if _undo_btn != null:
		_undo_btn.disabled = doc == null or not doc.can_undo()
	if _redo_btn != null:
		_redo_btn.disabled = doc == null or not doc.can_redo()


# 状态栏缩放百分比:默认档 16 px/子格 = 100%。
func _update_zoom_label() -> void:
	if _zoom_text == null or canvas == null:
		return
	_zoom_text.text = "%d%%" % roundi(canvas.zoom / EditorCanvas.ZOOM_DEFAULT * 100.0)


func _append_output(text: String) -> void:
	if _output == null:
		return
	_output.append_text(text + "\n")


func _set_message(text: String, is_error: bool) -> void:
	_message = text
	_append_output(("[FAIL] " if is_error else "") + text)
	_update_status(Vector2i.ZERO, false)


func _update_status(sub: Vector2i, _has_cursor: bool) -> void:
	var dirty_mark := ""
	if doc != null and doc.dirty:
		dirty_mark = " ●"
	if _doc_label != null and doc != null and doc.map.is_empty():
		_doc_label.text = "未命名" + dirty_mark
	if _status == null or _status_info == null or doc == null or doc.map.is_empty():
		if _status != null:
			_status.text = _message
		if _status_info != null:
			_status_info.text = ""
		if _path_label != null:
			_path_label.text = _path if _path != "" else "未命名"
		return
	var cells := doc.sub_size() / EditorConstants.SUB_PER_CELL
	var wrapped := Vector2i(posmod(sub.x, doc.sub_size().x), posmod(sub.y, doc.sub_size().y))
	var desc := doc.get_subcell(wrapped.x, wrapped.y)
	var mode_text := ""
	if _tools.meta_mode != "none":
		mode_text = " · 放置:%s" % _tools.meta_label_of(_tools.meta_mode)
	var file_name := _path.get_file() if _path != "" else "未命名"
	_status.text = _message
	_status_info.text = "%d×%d 格 · 层 %s · 工具 %s%s · 子格 (%d,%d) · 0x%08X" % [
		cells.x, cells.y, String(EditorConstants.LAYER_NAMES[doc.active_layer]),
		_tools.tool_label(), mode_text, wrapped.x, wrapped.y, desc]
	if _doc_label != null:
		var shown := file_name if file_name.length() <= 24 else file_name.left(24) + "…"
		_doc_label.text = shown + dirty_mark
		_doc_label.tooltip_text = _path if _path != "" else "尚未落盘"
	_path_label.text = _path if _path != "" else "未命名"


func _register_editor_actions() -> void:
	_action("editor_undo", [KEY_Z], true)
	_action("editor_redo", [KEY_Y], true)
	_action("editor_save", [KEY_S], true)
	_action("editor_open", [KEY_O], true)
	_action("editor_zoom_in", [KEY_EQUAL, KEY_KP_ADD], false)
	_action("editor_zoom_out", [KEY_MINUS, KEY_KP_SUBTRACT], false)
	_action("editor_copy", [KEY_C], true)
	_action("editor_cut", [KEY_X], true)
	_action("editor_paste", [KEY_V], true)
	_action("editor_delete", [KEY_DELETE], false)
	_action("editor_fit", [KEY_F], false)
	_action("editor_help", [KEY_F1], false)
	_action("editor_playtest", [KEY_F5], false)
	_action("editor_jump", [KEY_G], true)
	# 镜像让位给 移动(V)/ 手形(H):单键 H/V = 工具,Shift+H / Shift+V = 镜像。
	_action("editor_mirror_h", [KEY_H], false, true)
	_action("editor_mirror_v", [KEY_V], false, true)
	for key: String in TOOL_KEYCODES:
		_action("editor_tool_" + key, [int(TOOL_KEYCODES[key])], false)


func _action(name: String, keys: Array, ctrl: bool, shift: bool = false) -> void:
	if InputMap.has_action(name):
		return
	InputMap.add_action(name)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		ev.ctrl_pressed = ctrl
		ev.shift_pressed = shift
		InputMap.action_add_event(name, ev)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	# ★ 先判带 Ctrl / Shift 的组合,再判单键工具:InputMap 的 action 匹配不要求「多出来的修饰键」为空,
	#   否则 Ctrl+V(粘贴)会被裸 V(移动工具)吃掉、Shift+H/V(镜像)会被 H/V(工具)吃掉。
	if event.is_action_pressed("editor_undo"):
		_actions.undo()
	elif event.is_action_pressed("editor_redo"):
		_actions.redo()
	elif event.is_action_pressed("editor_save"):
		save_current()
	elif event.is_action_pressed("editor_open"):
		_actions.open_dialog()
	elif event.is_action_pressed("editor_fit"):
		canvas.fit_to_map()
	elif event.is_action_pressed("editor_help"):
		_actions.shortcut_help()
	elif event.is_action_pressed("editor_playtest"):
		_view.start_playtest(_view.first_player_cell())
	elif event.is_action_pressed("editor_jump"):
		_actions.jump_dialog()
	elif event.is_action_pressed("editor_zoom_in"):
		canvas.zoom_in()
	elif event.is_action_pressed("editor_zoom_out"):
		canvas.zoom_out()
	elif event.is_action_pressed("editor_copy"):
		_actions.copy()
	elif event.is_action_pressed("editor_cut"):
		_actions.cut()
	elif event.is_action_pressed("editor_paste"):
		_actions.paste()
	elif event.is_action_pressed("editor_delete"):
		_actions.clear_selection()
	elif event.is_action_pressed("editor_mirror_h"):
		_actions.mirror("h")
	elif event.is_action_pressed("editor_mirror_v"):
		_actions.mirror("v")
	else:
		# 工具切换(单键)是最后的兜底:没有修饰键组合命中才轮到它。
		for key: String in TOOL_KEYS:
			if event.is_action_pressed("editor_tool_" + key):
				_tools.set_tool(key)
				return
