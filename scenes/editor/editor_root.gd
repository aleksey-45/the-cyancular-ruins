extends Control

# 编辑器场景根(**只做逻辑/接线**):UI 在 editor_root.tscn(theme=menu_theme.tres);工具/指针在
# editor_tools.gd,命令/弹层在 editor_actions.gd,画布在 editor_canvas.gd,纯逻辑在 core/editor/。
# ★ 进客户端导出包 ⇒ 禁止 RegEx。坐标 = 子格(16px);格 = 子格/4。探针只调公开 API 与 UI 节点。

const TOOLS_SCRIPT := preload("res://scenes/editor/editor_tools.gd")
const ACTIONS_SCRIPT := preload("res://scenes/editor/editor_actions.gd")
const PREVIEW_SCRIPT := preload("res://scenes/editor/editor_preview.gd")
const TILE_DEFS_PATH := "res://data/tile_defs.json"
const THEME := preload("res://ui/theme/menu_theme.tres")
const TAB_DEFAULT_W := 400.0          # 右栏初始宽(tab 最小宽 320 写在 tscn 的 custom_minimum_size)

# tscn 里的按钮节点名 ↔ 语义键(顺序即工具列/模式列顺序)。
const TOOL_BUTTONS := {
	"brush": "ToolBrush", "eraser": "ToolEraser", "line": "ToolLine", "rect": "ToolRect",
	"bucket": "ToolBucket", "eyedrop": "ToolEyedrop", "select": "ToolSelect",
	"gradient": "ToolGradient",
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
var _path_label: Label = null
var _output: RichTextLabel = null
var _selection_info: Label = null
var _meta_info: Label = null
var _message := ""

var _canvas_host: Control = null
var _split: HSplitContainer = null
var _tabs: TabContainer = null
var _preview: Control = null
var _preview_on := false
var _preview_btn: Button = null
var _preview_last_origin := Vector2.INF
var _preview_last_zoom := -1.0


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
	canvas.pointer_down.connect(_tools.pointer_down)
	canvas.pointer_drag.connect(_tools.pointer_drag)
	canvas.pointer_up.connect(_tools.pointer_up)
	canvas.cursor_moved.connect(_on_cursor_moved)
	canvas.zoom_changed.connect(_on_zoom_changed)
	_set_message("新图默认 125×75 格;Ctrl+O 打开、Ctrl+S 保存、H/V 镜像选区", false)
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
	_refresh_palette_texture()
	_set_message("已打开 %s(%s)" % [path, String(res.get("source", "v4"))], false)
	if not (res.get("warnings", []) as Array).is_empty():
		_append_output("打开时校验提示:\n- " + "\n- ".join(res["warnings"]))
	_update_status(Vector2i.ZERO, false)
	return res


func new_map(cells_w: int, cells_h: int, map_name_arg: String = "untitled") -> void:
	doc.new_map(map_name_arg, cells_w, cells_h)
	_path = ""
	canvas.fit_to_map()
	_sync_layer_rows()
	_set_message("已新建 %d×%d 格" % [cells_w, cells_h], false)
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
	_path_label = %PathText
	_output = %Output
	_selection_info = %SelectionInfo
	_meta_info = %MetaInfo
	_canvas_host = %CanvasHost
	_split = %Split
	_tabs = %RightTabs

	# 少数颜色 token 不在 tscn 里重复写值(single source = UiFactory.C_*)。
	# 标题从 32 号亮青降成 16 号弱化:菜单栏是"窗口标题"语气,不跟画布抢焦点。
	(%TitleLabel as Label).theme_type_variation = &"SmallDim"
	for name: String in ["ViewLabel", "ToolLabel", "StatusText", "PathText", "LayersHint",
			"PaletteHint", "BrushHint", "ColorHint", "SelHint", "MetaHint", "ReportHint",
			"SelectionInfo", "MetaInfo"]:
		var l := get_node_or_null("%" + name) as Label
		if l != null:
			l.add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)

	_tabs.set_tab_title(0, "图层")
	_tabs.set_tab_title(1, "调色板")
	_tabs.set_tab_title(2, "选区 & meta")
	_tabs.set_tab_title(3, "校验消息")

	# 图层:7 行静态在 tscn(LayerRow0-6 = Button + 眼睛 CheckButton)。
	for i in EditorConstants.LAYER_COUNT:
		var row := (%LayerRows as VBoxContainer).get_child(i) as HBoxContainer
		var btn := row.get_child(0) as Button
		var vis := row.get_child(1) as CheckButton
		btn.theme_type_variation = &"LayerRow"
		btn.pressed.connect(_on_layer_selected.bind(i))
		vis.toggled.connect(_on_layer_visible_toggled.bind(i))
		_layer_rows.append({"button": btn, "visible": vis})

	# 工具列(左竖直 8 键)
	for key: String in TOOL_BUTTONS:
		var b := get_node("%" + String(TOOL_BUTTONS[key])) as Button
		b.theme_type_variation = &"ToolButton"
		b.pressed.connect(_tools.set_tool.bind(key))
		_tool_buttons[key] = b

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
	color_btn.color_changed.connect(func(c: Color) -> void: _tools.color_value = c)
	var grad_btn := %GradientEndColor as ColorPickerButton
	grad_btn.color = _tools.gradient_end
	grad_btn.color_changed.connect(func(c: Color) -> void: _tools.gradient_end = c)

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

	_tools.message.connect(_set_message)
	_tools.tool_changed.connect(_on_tool_changed)
	_tools.paint_desc_changed.connect(_on_paint_desc_changed)
	_tools.meta_mode_changed.connect(_on_meta_mode_changed)
	_tools.selection_changed.connect(_update_selection_info)
	_on_tool_changed(_tools.tool)
	_on_meta_mode_changed(_tools.meta_mode)
	_layout_split.call_deferred()


func _fill_menu(mb: MenuButton, items: Array) -> void:
	var pop := mb.get_popup()
	pop.theme = THEME
	for i in items.size():
		pop.add_item(String((items[i] as Array)[0]), i)
	pop.id_pressed.connect(func(id: int) -> void:
		var cb: Callable = (items[id] as Array)[1]
		cb.call())


# 让右侧初始宽度 = TAB_DEFAULT_W(可继续拖拽):SplitContainer 默认按子节点最小尺寸分。
func _layout_split() -> void:
	if _split == null or _tabs == null:
		return
	await get_tree().process_frame
	# 负 offset 把 divider 右移(加宽右栏);正值会被钳回最小宽度 ⇒ -TAB_DEFAULT_W = 初始 400。
	_split.split_offset = -int(TAB_DEFAULT_W)


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
		b.custom_minimum_size = Vector2(64, 64)              # 缩略图边长(内容驱动)
		b.tooltip_text = "%d %s" % [tid, String((tiles[str(tid)] as Dictionary).get("name", ""))]
		var img: Image = src.get_region(TerrainAtlas.source_rect(tid - 1))
		b.icon = ImageTexture.create_from_image(img)
		b.expand_icon = false
		UiFactory.style_button(b, "quiet")
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
		_palette_buttons[i].modulate = UiFactory.C_WHITE if _texture_ids[i] == tex \
				else Color(1, 1, 1, 0.55)


# ── 工具/图层/meta 的显示态 ─────────────────────────────────────────────

func _on_tool_changed(key: String) -> void:
	for k: String in _tool_buttons:
		var b: Button = _tool_buttons[k]
		b.theme_type_variation = &"ToolActive" if k == key else &"ToolButton"
	_update_status(Vector2i.ZERO, false)


func _on_paint_desc_changed(desc: int) -> void:
	_mark_palette(EditorDesc.tex_of(desc))


func _on_meta_mode_changed(key: String) -> void:
	for k: String in _meta_buttons:
		var b: Button = _meta_buttons[k]
		b.theme_type_variation = &"ToolActive" if k == key else &"FlatButton"
		b.modulate = UiFactory.C_WHITE


func _on_layer_selected(L: int) -> void:
	doc.active_layer = L
	canvas.set_active_layer(L)
	_sync_layer_rows()
	_update_status(Vector2i.ZERO, false)


func _on_layer_visible_toggled(on: bool, L: int) -> void:
	canvas.set_layer_visible(L, on)


func _sync_layer_rows() -> void:
	for L in _layer_rows.size():
		var b: Button = (_layer_rows[L] as Dictionary)["button"]
		b.theme_type_variation = &"LayerActive" if L == doc.active_layer else &"LayerRow"
		var vis: CheckButton = (_layer_rows[L] as Dictionary)["visible"]
		# 眼睛开关:开=亮一档(0.8),关=压暗(0.35);不再 7 个高亮青胶囊同时抢眼。
		vis.modulate = Color(1, 1, 1, 0.8 if vis.button_pressed else 0.35)


# ── doc / 画布 回调 ─────────────────────────────────────────────────────

func _on_doc_changed(_layer: int, _subcells: PackedInt32Array) -> void:
	_update_status(Vector2i.ZERO, false)


func _on_doc_structure_changed() -> void:
	canvas.refresh()
	_sync_layer_rows()


func _on_cursor_moved(sub: Vector2i) -> void:
	_update_status(sub, true)


func _on_zoom_changed(_zoom: float) -> void:
	_update_status(Vector2i.ZERO, false)


func _on_doc_meta_changed() -> void:
	canvas.queue_redraw()
	_sync_meta_info()
	_update_status(Vector2i.ZERO, false)


func _on_clear_meta_pressed() -> void:
	_set_message("已清空 meta(%d 条)" % doc.clear_meta("all"), false)
	_sync_meta_info()


func _sync_meta_info() -> void:
	if _meta_info == null or doc == null or doc.map.is_empty():
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


func _append_output(text: String) -> void:
	if _output == null:
		return
	_output.append_text(text + "\n")


func _set_message(text: String, is_error: bool) -> void:
	_message = text
	_append_output(("[FAIL] " if is_error else "") + text)
	_update_status(Vector2i.ZERO, false)


func _update_status(sub: Vector2i, _has_cursor: bool) -> void:
	if _status == null or doc == null or doc.map.is_empty():
		if _status != null:
			_status.text = _message
		return
	var cells := doc.sub_size() / EditorConstants.SUB_PER_CELL
	var wrapped := Vector2i(posmod(sub.x, doc.sub_size().x), posmod(sub.y, doc.sub_size().y))
	var desc := doc.get_subcell(wrapped.x, wrapped.y)
	var dirty := "未保存" if doc.dirty else "已保存"
	_status.text = "%s · 尺寸 %d×%d 格 · 层 %s · 工具 %s · 子格 (%d,%d) · 值 0x%08X · 缩放 %d px/子格 · %s" % [
		_message, cells.x, cells.y, String(EditorConstants.LAYER_NAMES[doc.active_layer]),
		_tools.tool_label(), wrapped.x, wrapped.y, desc, int(canvas.zoom), dirty]
	_path_label.text = ("● " if doc.dirty else "") + (_path if _path != "" else "未命名")


func _register_editor_actions() -> void:
	_action("editor_undo", [KEY_Z], true)
	_action("editor_redo", [KEY_Y], true)
	_action("editor_save", [KEY_S], true)
	_action("editor_open", [KEY_O], true)
	_action("editor_zoom_in", [KEY_EQUAL, KEY_KP_ADD], true)
	_action("editor_zoom_out", [KEY_MINUS, KEY_KP_SUBTRACT], true)
	_action("editor_copy", [KEY_C], true)
	_action("editor_cut", [KEY_X], true)
	_action("editor_paste", [KEY_V], true)
	_action("editor_delete", [KEY_DELETE], false)
	_action("editor_mirror_h", [KEY_H], false)
	_action("editor_mirror_v", [KEY_V], false)


func _action(name: String, keys: Array, ctrl: bool) -> void:
	if InputMap.has_action(name):
		return
	InputMap.add_action(name)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		ev.ctrl_pressed = ctrl
		InputMap.action_add_event(name, ev)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	if event.is_action_pressed("editor_undo"):
		doc.undo()
	elif event.is_action_pressed("editor_redo"):
		doc.redo()
	elif event.is_action_pressed("editor_save"):
		save_current()
	elif event.is_action_pressed("editor_open"):
		_actions.open_dialog()
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
