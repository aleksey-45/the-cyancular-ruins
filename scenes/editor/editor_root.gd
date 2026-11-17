extends Control

# 编辑器场景根(**只做逻辑/接线**):UI 在 editor_root.tscn(theme=menu_theme.tres);工具/指针在
# editor_tools.gd,命令/弹层在 editor_actions.gd,画布在 editor_canvas.gd,纯逻辑在 core/editor/。
# ★ 进客户端导出包 ⇒ 禁止 RegEx。坐标 = 子格(16px);格 = 子格/4。探针只调公开 API 与 UI 节点。

const TOOLS_SCRIPT := preload("res://scenes/editor/editor_tools.gd")
const ACTIONS_SCRIPT := preload("res://scenes/editor/editor_actions.gd")
const PREVIEW_SCRIPT := preload("res://scenes/editor/editor_preview.gd")
const TILE_DEFS_PATH := "res://data/tile_defs.json"
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

var _path := ""
var _texture_ids: Array[int] = []
var _layer_rows: Array[Dictionary] = []
var _tool_buttons: Dictionary = {}
var _meta_buttons: Dictionary = {}
var _palette_buttons: Array[Button] = []
var _status: Label = null
var _status_info: Label = null
var _doc_label: Label = null
var _path_label: Label = null
var _output: RichTextLabel = null
var _selection_info: Label = null
var _meta_info: Label = null
var _meta_list: VBoxContainer = null
var _enemy_type_opt: OptionButton = null
var _message := ""
var _enemy_types: Array[String] = []
var _color_nodes: Array[Control] = []
var _palette_nodes: Array[Control] = []

var _canvas_host: Control = null
var _split: HSplitContainer = null
var _tabs: TabContainer = null
var _preview: Control = null
var _preview_on := false
var _preview_btn: Button = null
var _preview_last_origin := Vector2.INF
var _preview_last_zoom := -1.0
var _undo_btn: Button = null
var _redo_btn: Button = null
var _zoom_text: Label = null


func _ready() -> void:
	doc = EditorDoc.new()
	canvas = %Canvas as EditorCanvas
	_tools.setup(doc, canvas)
	_actions.setup(self)
	_register_editor_actions()
	_wire_ui()
	canvas.set_doc(doc)
	_build_preview()
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
	_set_message("新图 125×75 格;F1 快捷键 · Ctrl+G 跳转 · 右键小地图跳转;Ctrl+O 打开、Ctrl+S 保存", false)
	_update_status(Vector2i.ZERO, false)


func _process(_dt: float) -> void:
	if not _preview_on or _preview == null or canvas == null:
		return
	var origin := canvas.origin
	var zoom := canvas.zoom
	if origin != _preview_last_origin or zoom != _preview_last_zoom:
		_preview_last_origin = origin
		_preview_last_zoom = zoom
		_preview.set_camera(origin, zoom)


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
	_sync_layer_rows()
	_sync_layer_tool_availability()
	_refresh_palette_texture()
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
	_sync_layer_rows()
	_sync_layer_tool_availability()
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


# ── UI 接线(scene 树见 editor_root.tscn;这里只连信号 + 填动态内容)──────────

func _wire_ui() -> void:
	_status = %StatusText
	_status_info = %StatusInfo
	_doc_label = %DocLabel
	_path_label = %PathText
	_output = %Output
	_selection_info = %SelectionInfo
	_meta_info = %MetaInfo
	_meta_list = %MetaList
	_canvas_host = %CanvasHost
	_split = %Split
	_tabs = %RightTabs

	# 少数颜色 token 不在 tscn 里重复写值(single source = UiFactory.C_*)。
	# 标题从 32 号亮青降成 16 号弱化:菜单栏是"窗口标题"语气,不跟画布抢焦点。
	(%TitleLabel as Label).theme_type_variation = &"SmallDim"
	for name: String in ["ViewLabel", "ToolsHint", "BrushHint", "ColorHint", "PaletteHint", "HelpHint",
			"LayersHint", "StatusText", "StatusInfo", "DocLabel", "PathText", "SelHint", "MetaHint",
			"ReportHint", "SelectionInfo", "MetaInfo", "MetaListHint", "EnemyTypeLabel", "ZoomText"]:
		var l := get_node_or_null("%" + name) as Label
		if l != null:
			l.add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
	for name: String in ["SelectionTitle", "MetaTitle"]:
		var h := get_node_or_null("%" + name) as Label
		if h != null:
			h.add_theme_color_override("font_color", UiFactory.C_TEXT)
	_color_nodes.clear()
	_color_nodes.append(%ColorHint as Control)
	_color_nodes.append(%BrushColorRow as Control)
	_color_nodes.append(%GradientEndRow as Control)
	_palette_nodes.clear()
	_palette_nodes.append(%PaletteHint as Control)
	_palette_nodes.append(%PaletteScroll as Control)

	_tabs.set_tab_title(0, "选区 & meta")
	_tabs.set_tab_title(1, "校验消息")

	# 图层:7 行静态在 tscn(LayerRow0-6 = Button + 眼睛 CheckButton);卡片常驻,不随 Tab 切走。
	for i in EditorConstants.LAYER_COUNT:
		var row := (%LayerRows as VBoxContainer).get_child(i) as HBoxContainer
		var btn := row.get_child(0) as Button
		var vis := row.get_child(1) as CheckButton
		btn.theme_type_variation = &"LayerRow"
		btn.pressed.connect(_on_layer_selected.bind(i))
		vis.toggled.connect(_on_layer_visible_toggled.bind(i))
		_layer_rows.append({"button": btn, "visible": vis})

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
	(%PreviewBtn as Button).theme_type_variation = &"FlatButton"
	(%BackBtn as Button).theme_type_variation = &"FlatButton"
	_preview_btn = %PreviewBtn
	_preview_btn.pressed.connect(_on_preview_toggled)
	(%BackBtn as Button).pressed.connect(_actions.back)

	# 右栏的次级按钮(选区 6 / meta 5 / 校验)统一扁平;当前态由 _on_*_changed 换 variation。
	for nm: String in ["SelCopy", "SelCut", "SelPaste", "SelClear", "SelMirrorH", "SelMirrorV",
			"MetaEdit", "MetaPlayer", "MetaRespawn1", "MetaRespawn2", "MetaEnemy",
			"ClearMetaBtn", "ValidateBtn"]:
		var b := get_node_or_null("%" + nm) as Button
		if b != null:
			b.theme_type_variation = &"FlatButton"

	# 调色板缩略图是动态内容(图集按 tile_defs 生成);按钮列表本身也在 tscn 之外生成。
	_build_palette(%PaletteGrid as GridContainer)

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
	_enemy_type_opt = %EnemyTypeOption as OptionButton
	for type_id: String in _enemy_types:
		_enemy_type_opt.add_item(type_id)
	if not _enemy_types.is_empty():
		_enemy_type_opt.selected = 0
		_tools.set_enemy_type(_enemy_types[0])
	_enemy_type_opt.item_selected.connect(func(i: int) -> void:
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
	(%ClearMetaBtn as Button).pressed.connect(_on_clear_meta_pressed)
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

	_tools.message.connect(_set_message)
	_tools.tool_changed.connect(_on_tool_changed)
	_tools.paint_desc_changed.connect(_on_paint_desc_changed)
	_tools.meta_mode_changed.connect(_on_meta_mode_changed)
	_tools.selection_changed.connect(_update_selection_info)
	_on_tool_changed(_tools.tool)
	_on_meta_mode_changed(_tools.meta_mode)
	_sync_layer_tool_availability()
	_sync_meta_info()
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


func _build_palette(container: GridContainer) -> void:
	var defs = JSON.parse_string(FileAccess.get_file_as_string(TILE_DEFS_PATH))
	var tiles: Dictionary = defs.get("tiles", {}) if defs is Dictionary else {}
	var ids: Array[int] = []
	for k in tiles:
		ids.append(int(String(k)))
	ids.sort()
	_texture_ids = ids
	var src := TerrainAtlas.source_image()
	for tid in ids:
		var b := Button.new()
		# 缩略图缩到 56px:图集源砖是 64px,但调色板要 3 列塞进 268px 左栏(64px + 按钮内边距会撑到 82)。
		b.custom_minimum_size = Vector2(56, 56)              # 缩略图边长(内容驱动)
		b.tooltip_text = "%d %s" % [tid, String((tiles[str(tid)] as Dictionary).get("name", ""))]
		var img: Image = src.get_region(TerrainAtlas.source_rect(tid - 1))
		img.resize(56, 56, Image.INTERPOLATE_NEAREST)
		b.icon = ImageTexture.create_from_image(img)
		b.expand_icon = false
		b.theme_type_variation = &"BtnCompact"
		b.toggle_mode = true                             # 选中态用按钮 pressed 样式,不再只靠 modulate
		b.pressed.connect(func() -> void: _tools.set_paint_desc(EditorDesc.neutral_desc(tid)))
		container.add_child(b)
		_palette_buttons.append(b)
	_tools.set_paint_desc(EditorDesc.neutral_desc(_texture_ids[0] if not _texture_ids.is_empty() else 1))


func _refresh_palette_texture() -> void:
	if _texture_ids.is_empty():
		return
	var tex := EditorDesc.tex_of(_tools.paint_desc)
	if tex == 0:
		return
	_tools.set_paint_desc(EditorDesc.neutral_desc(tex))


func _mark_palette(tex: int) -> void:
	for i in _palette_buttons.size():
		var on := _texture_ids[i] == tex
		_palette_buttons[i].set_pressed_no_signal(on)
		_palette_buttons[i].modulate = Color(1, 1, 1, 1.0 if on else 0.85)


# ── 工具/图层/meta 的显示态 ─────────────────────────────────────────────

func _on_tool_changed(key: String) -> void:
	for k: String in _tool_buttons:
		var b: Button = _tool_buttons[k]
		b.theme_type_variation = &"ToolActive" if k == key else &"ToolButton"
	# 预览是盖在画布上的一层:移动/手形要看到选区框与 meta 标记,开着预览就先把预览关掉。
	if (key == "move" or key == "hand") and _preview_on:
		set_preview(false)
	_update_status(Vector2i.ZERO, false)


func _on_paint_desc_changed(desc: int) -> void:
	_mark_palette(EditorDesc.tex_of(desc))


func _on_meta_mode_changed(key: String) -> void:
	for k: String in _meta_buttons:
		var b: Button = _meta_buttons[k]
		b.theme_type_variation = &"ToolActive" if k == key else &"FlatButton"
		b.modulate = UiFactory.C_WHITE
	_update_status(Vector2i.ZERO, false)


func _on_layer_selected(L: int) -> void:
	doc.active_layer = L
	canvas.set_active_layer(L)
	_sync_layer_rows()
	_sync_layer_tool_availability()
	if EditorConstants.is_color_layer(L):
		_set_message("颜色层:用左栏「颜色」画笔;渐变只作用于选区", false)
	else:
		_set_message("纹理层:点左栏调色板选纹理;颜色工具不可用", false)
	_update_status(Vector2i.ZERO, false)


func _on_layer_visible_toggled(on: bool, L: int) -> void:
	canvas.set_layer_visible(L, on)


# ── 按当前层的类型决定「工具/面板」可用性 ─────────────────────────────────
# 纹理层 0-2:调色板/纹理解析适用,颜色选择器与渐变不适用;
# 颜色层 3-6:颜色/渐变适用,纹理调色板不适用(画笔直接用颜色画)。
# 切层后当前工具若变得不适用(渐变)⇒ 自动回画笔,避免下一次落笔才报错。
func _sync_layer_tool_availability() -> void:
	if doc == null or _tools == null:
		return
	var is_color := EditorConstants.is_color_layer(doc.active_layer)
	var grad := _tool_buttons.get("gradient") as Button
	if grad != null:
		grad.disabled = not is_color
		grad.tooltip_text = "渐变 (%s)%s" % [String(TOOL_KEYS.get("gradient", "")),
				"" if is_color else " · 仅颜色层 3-6"]
	for b in _palette_buttons:
		b.disabled = is_color
	var pal_grid := get_node_or_null("%PaletteGrid") as GridContainer
	if pal_grid != null:
		pal_grid.modulate = Color(1, 1, 1, 0.45 if is_color else 1.0)
	var pal_hint := get_node_or_null("%PaletteHint") as Label
	if pal_hint != null:
		pal_hint.text = "调色板(颜色层用「颜色」画笔)" if is_color else "纹理调色板(点选 = 画笔纹理)"
	var brush_color := get_node_or_null("%BrushColor") as ColorPickerButton
	var grad_color := get_node_or_null("%GradientEndColor") as ColorPickerButton
	if brush_color != null:
		brush_color.disabled = not is_color
	if grad_color != null:
		grad_color.disabled = not is_color
	# 渐进披露:纹理层只露调色板,颜色层只露颜色;另一组整块隐藏(不再常驻置灰)。
	for n: Control in _color_nodes:
		if n != null:
			n.visible = is_color
	for n: Control in _palette_nodes:
		if n != null:
			n.visible = not is_color
	if not is_color and _tools.tool == "gradient":
		_tools.set_tool("brush")
		_set_message("当前是纹理层:渐变不可用,已切回画笔", false)


func _sync_layer_rows() -> void:
	for L in _layer_rows.size():
		var b: Button = (_layer_rows[L] as Dictionary)["button"]
		b.theme_type_variation = &"LayerActive" if L == doc.active_layer else &"LayerRow"
		var vis: CheckButton = (_layer_rows[L] as Dictionary)["visible"]
		# 当前层恒可见(canvas 语义):眼睛对它禁用并强制显示为"开",不再出现「控件说关、画布还在画」。
		var is_active := L == doc.active_layer
		vis.disabled = is_active
		vis.tooltip_text = "当前编辑层不可隐藏(先切到其它层)" if is_active else "显示/隐藏该层"
		if is_active:
			vis.set_pressed_no_signal(true)
		vis.modulate = Color(1, 1, 1, 1.0 if is_active else (0.8 if vis.button_pressed else 0.35))


# ── doc / 画布 回调 ─────────────────────────────────────────────────────

func _on_doc_changed(_layer: int, _subcells: PackedInt32Array) -> void:
	_update_history_buttons()
	_update_status(Vector2i.ZERO, false)


func _on_doc_structure_changed() -> void:
	canvas.refresh()
	canvas.set_selection(doc.selection)       # 换图/新建清了 doc.selection,别让旧选框留在画布上
	_sync_layer_rows()
	_sync_layer_tool_availability()
	_sync_meta_info()
	_update_selection_info()
	_update_history_buttons()


func _on_cursor_moved(sub: Vector2i) -> void:
	_update_status(sub, true)


func _on_zoom_changed(_zoom: float) -> void:
	_update_zoom_label()
	_update_status(Vector2i.ZERO, false)


func _on_doc_meta_changed() -> void:
	canvas.queue_redraw()
	_sync_meta_info()
	_update_history_buttons()
	_update_status(Vector2i.ZERO, false)


# 移动工具开始拖选区 / 拖 meta 标记时给一行提示(落点写入在工具层)。
func _on_selection_move_started() -> void:
	_set_message("移动选区:松开左键落位(Esc 不生效,可直接撤销)", false)


func _on_meta_drag_started(kind: String, index: int) -> void:
	_set_message("拖动%s#%d:松开左键落位" % [_tools.meta_label_of(kind), index], false)


func _on_fit_pressed() -> void:
	canvas.fit_to_map()


func _on_clear_meta_pressed() -> void:
	_set_message("已清空 meta(%d 条)" % doc.clear_meta("all"), false)
	_sync_meta_info()


func _sync_meta_info() -> void:
	if _meta_info == null or doc == null:
		return
	if doc.map.is_empty():
		_meta_info.text = ""
		_rebuild_meta_list()
		return
	var players: Array = doc.map.get("players", [])
	var respawns: Array = doc.map.get("respawns", [])
	var side1 := 0
	var side2 := 0
	for r in respawns:
		if int((r as Dictionary).get("side", 0)) == 1:
			side1 += 1
		else:
			side2 += 1
	_meta_info.text = "出生点 %d · 复活点 侧1 %d / 侧2 %d · 敌人 %d" % [
		players.size(), side1, side2, (doc.map.get("enemies", []) as Array).size()]
	_rebuild_meta_list()


# 已放置 meta 列表:每条一行(标签 + 敌人类型下拉 + 删除),点行内「删除」= 单条删除。
func _rebuild_meta_list() -> void:
	if _meta_list == null:
		return
	for child in _meta_list.get_children():
		_meta_list.remove_child(child)
		child.queue_free()
	if doc == null or doc.map.is_empty():
		return
	for ent: Dictionary in doc.meta_entries():
		var entry := ent
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var kind := String(entry["kind"])
		var label := Label.new()
		label.theme_type_variation = &"Small"
		label.add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.custom_minimum_size = Vector2(80, 0)
		label.clip_text = true
		match kind:
			"player":
				label.text = "出生点 #%d @ (%d,%d)" % [int(entry["index"]) + 1, int(entry["x"]), int(entry["y"])]
			"respawn":
				label.text = "复活点 侧%d #%d @ (%d,%d)" % [int(entry["side"]),
						int(entry["index"]) + 1, int(entry["x"]), int(entry["y"])]
			_:
				label.text = "敌人 %s #%d @ (%d,%d)" % [String(entry.get("type", "")),
						int(entry["index"]) + 1, int(entry["x"]), int(entry["y"])]
		label.tooltip_text = label.text
		row.add_child(label)
		if kind == "enemy":
			var items: Array[String] = _enemy_types.duplicate()
			var cur_type := String(entry.get("type", ""))
			if not items.has(cur_type):
				items.append(cur_type)
			var opt := OptionButton.new()
			for id: String in items:
				opt.add_item(id)
			opt.selected = items.find(cur_type)
			opt.theme_type_variation = &"Kit"
			opt.custom_minimum_size = Vector2(96, 0)
			opt.clip_text = true
			opt.size_flags_horizontal = Control.SIZE_SHRINK_END
			opt.item_selected.connect(func(i: int) -> void:
				if i >= 0 and i < items.size():
					doc.set_meta_enemy_type(int(entry["index"]), items[i]))
			row.add_child(opt)
		var del := Button.new()
		del.text = "删除"
		del.tooltip_text = "删除这条 %s(可撤销)" % kind
		del.theme_type_variation = &"FlatButton"
		del.custom_minimum_size = Vector2(48, 26)
		del.pressed.connect(func() -> void:
			if doc.remove_meta_at(kind, int(entry["index"])):
				_set_message("已删除一条 %s" % _tools.meta_label_of(kind), false))
		row.add_child(del)
		_meta_list.add_child(row)


func _update_selection_info() -> void:
	if _selection_info == null:
		return
	if doc == null or not doc.has_selection():
		_selection_info.text = "无选区"
		return
	var r := doc.selection
	_selection_info.text = "%d×%d 子格 @ (%d,%d)" % [r.size.x, r.size.y, r.position.x, r.position.y]


# ── 真渲染预览 ─────────────────────────────────────────────────────────

func get_preview() -> Control:
	return _preview


func is_preview_on() -> bool:
	return _preview_on


func set_preview(on: bool) -> void:
	if _preview == null:
		return
	_preview_on = on
	_preview.visible = on
	_preview.set_active(on)
	if _preview_btn != null:
		_preview_btn.text = "预览:开" if on else "预览:关"
	if on:
		_preview_last_origin = canvas.origin
		_preview_last_zoom = canvas.zoom
		_preview.set_camera(canvas.origin, canvas.zoom)
	_set_message("预览:%s" % ("开(复用游戏渲染管线)" if on else "关(快速画布)"), false)


func _on_preview_toggled() -> void:
	set_preview(not _preview_on)


func _build_preview() -> void:
	if _preview != null:
		return
	_preview = PREVIEW_SCRIPT.new()
	_preview.name = "Preview"
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE      # 让画布继续收鼠标(预览是只读层)
	_canvas_host.add_child(_preview)
	_preview.setup(doc)
	_preview.set_active(false)
	_preview.visible = false


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
