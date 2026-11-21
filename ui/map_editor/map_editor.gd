class_name MapEditor
extends Control

const HEADING_COLOR := Color("#a9dcca")
const LAYERS := ["前景", "场景", "后景", "背景"]
const POINT_HINT := "拖动移动点位 · 双击试玩"
const TOOLS := {
	"brush": {"label": "画笔", "key": KEY_B, "params": ["width", "material", "color"], "preview": "path",
		"pick_points": POINT_HINT + " · Alt 在点位下绘制"},
	"erase": {"label": "橡皮", "key": KEY_E, "params": ["width"], "preview": "path"},
	"line": {"label": "直线", "key": KEY_L, "params": ["width", "material", "color"], "preview": "line"},
	"rect": {"label": "矩形", "key": KEY_NONE, "params": ["outline", "material", "color"], "preview": "rect"},
	"bucket": {"label": "填充", "key": KEY_G, "params": ["material", "color"]},
	"picker": {"label": "吸管", "key": KEY_I, "params": ["material", "color"]},
	"select": {"label": "选区", "key": KEY_M, "params": ["selection"]},
	"gradient": {"label": "渐变", "key": KEY_NONE, "params": ["color", "end_color"], "preview": "guide", "layer": CyrmMap.COLOR},
	"point": {"label": "点位", "key": KEY_P, "params": ["points"], "pick_points": POINT_HINT},
}
const ENEMY_LABELS := {"jump_bird": "跳鸟", "fly_bird": "飞鸟", "black_bird": "乌鸫"}
const DEFAULT_SIZE := Vector2i(500, 300)

var draft_path := "user://map-editor.draft"
var active_tool := "brush"
var _tool: Dictionary:
	get: return TOOLS[active_tool]
var session := MapEditSession.new()
var brush := MapBrush.new()
var canvas := MapEditCanvas.new()
var trial: SoloLevel
var _workspace := VBoxContainer.new()
var _filename: Label
var _modified: Label
var _status: Label
var _materials: Dictionary[int, Button] = {}
var _place_points: CheckBox
var _point_type := OptionButton.new()
var _point_list := ItemList.new()
var _ink := ColorPickerButton.new()
var _shortcuts: Dictionary[int, Callable] = {}
var _tints: Array[SpinBox] = []
var _tools: Dictionary[String, Button] = {}
var _layers: Array[Button] = []
var _texture_layer := CyrmMap.SCENE
var _dimensions: Label
var _context_title: Label
var _param_rows: Dictionary[String, Control] = {
	"material": FoldableContainer.new(), "color": VBoxContainer.new(),
	"selection": VBoxContainer.new(), "points": VBoxContainer.new(),
}
var _selection_info := Label.new()
var _point_details := HBoxContainer.new()
var _draft_revision := -1
var _closing := false
var _auto_quit := true

func _ready() -> void:
	_auto_quit = get_tree().auto_accept_quit
	get_tree().auto_accept_quit = false
	theme = preload("res://ui/map_editor/editor_theme.tres")
	UiFactory.cover(self, UiFactory.shade(Color("#0e1519")))
	add_child(_workspace)
	_workspace.add_theme_constant_override("separation", 10)
	_workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	_build_ui()
	session.changed.connect(_changed)
	session.selection_changed.connect(_selection_changed)
	session.cells_changed.connect(canvas.paint_cells)
	session.points_changed.connect(_refresh_points)
	canvas.session = session
	canvas.tool_pressed.connect(_tool_pressed)
	_selection_changed()
	var autosave := Timer.new()
	autosave.wait_time = 10.0
	autosave.autostart = true
	autosave.timeout.connect(_write_draft)
	add_child(autosave)
	var draft := MapEditFiles.read_draft(draft_path)
	if draft.is_empty():
		_open_document(CyrmMap.create(DEFAULT_SIZE), "")
		_say("左键绘制 · 拖动点位移动 · 中键平移 · 滚轮缩放")
	else:
		_open_document(draft.map, draft.path, true)
		_say("已恢复上次未保存的草稿")

func _exit_tree() -> void:
	get_tree().auto_accept_quit = _auto_quit

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_node_ready() and not _closing:
		_confirm_discard(_leave.bind(true))

func _leave(quit: bool) -> void:
	_closing = true
	MapEditFiles.clear_draft(draft_path)
	if quit: get_tree().quit()
	else: get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _build_ui() -> void:
	var top := PanelContainer.new()
	_workspace.add_child(top)
	var bar := _row(top)
	_label(bar, "地图编辑器", 28, Color("#b7e9d5"))
	bar.add_child(VSeparator.new())
	var cmd := KEY_MASK_META if OS.has_feature("macos") else KEY_MASK_CTRL
	_shortcuts[cmd | KEY_Y] = _travel.bind(1)
	var files := _command_menu(bar, "文件")
	_command(files, "新建地图…", _size_dialog.bind(true), cmd | KEY_N)
	_command(files, "打开地图…", _file_dialog, cmd | KEY_O)
	files.add_separator()
	_command(files, "保存", _save, cmd | KEY_S)
	_command(files, "另存为…", _file_dialog.bind(true), cmd | KEY_MASK_SHIFT | KEY_S)
	files.add_separator()
	_command(files, "返回主菜单", _confirm_discard.bind(_leave.bind(false)))
	var edit := _command_menu(bar, "编辑")
	_command(edit, "撤销", _travel.bind(-1), cmd | KEY_Z)
	_command(edit, "重做", _travel.bind(1), cmd | KEY_MASK_SHIFT | KEY_Z)
	edit.add_separator()
	var clipboard := [["复制选区", session.copy_selection, KEY_C], ["剪切选区", _cut, KEY_X], ["粘贴", _paste, KEY_V]]
	for entry in clipboard:
		_command(edit, entry[0], entry[1], cmd | entry[2])
	edit.add_separator()
	_command(edit, "调整地图尺寸…", _size_dialog.bind(false))
	_command(edit, "地图注记…", _notes_dialog)
	var view := _command_menu(bar, "视图")
	_command(view, "适配全图", canvas.fit)
	view.add_separator()
	for entry in [["坐标标尺", "grid"], ["子格网格", "subgrid"], ["环面预览", "torus"], ["分区标线", "guides"], ["压暗其他层", "dim_others"]]:
		var index := view.item_count
		view.add_check_item(entry[0], index)
		view.set_item_checked(index, canvas.get(entry[1]))
		view.set_item_metadata(index, _toggle_view.bind(view, index, entry[1]))
	bar.add_spacer(false)
	_button(bar, "保存", _save).tooltip_text = "写入当前地图文件"
	_button(bar, "校验", _validate)
	var play := _button(bar, "试玩  F5", start_trial, null, KEY_F5)
	play.theme_type_variation = &"EditorPrimary"
	play.tooltip_text = "从所选点位试玩当前地图，Esc 返回"

	var body := UiFactory.box(_workspace, 8, false)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left := _sidebar(body, 292)
	_label(left, "绘制工具", 24, HEADING_COLOR)
	var tools := _grid(left, 3)
	var tool_group := ButtonGroup.new()
	for id: String in TOOLS:
		var key: Key = TOOLS[id].key
		var button := _button(tools, TOOLS[id].label, _choose_tool.bind(id), tool_group, key)
		button.tooltip_text = button.text + (" " + OS.get_keycode_string(key) if key != KEY_NONE else "")
		_tools[id] = button
	_tools[active_tool].button_pressed = true
	left.add_child(HSeparator.new())
	_build_materials(left)
	var center := UiFactory.box(body, 4, true)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var strip := PanelContainer.new()
	center.add_child(strip)
	var document := _row(strip)
	_modified = _label(document, "● 未保存", 24, Color("#e9c58b"))
	_filename = _flex_label(document)
	_dimensions = _label(document, "", 24, Color("#9aada7"))
	document.add_child(VSeparator.new())
	_button(document, "−", canvas.zoom_at.bind(0.8)).tooltip_text = "缩小"
	var zoom := _label(document, "")
	zoom.custom_minimum_size.x = 72
	zoom.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	canvas.zoom_changed.connect(func(value: float) -> void: zoom.text = "%d%%" % roundi(value * 100.0 / 16))
	_button(document, "+", canvas.zoom_at.bind(1.25)).tooltip_text = "放大"
	_button(document, "适配全图", canvas.fit)
	center.add_child(canvas)

	var right := _sidebar(body, 304)
	_build_layers(right)
	right.add_child(HSeparator.new())
	_context_title = _label(right, "画笔", 24, HEADING_COLOR)
	_build_inspector(right, clipboard)

	var footer := _row(_workspace)
	_status = _flex_label(footer)
	var coords := _label(footer, "")
	canvas.cursor_moved.connect(func(p: Vector2i) -> void:
		coords.text = "子格 %d, %d" % [p.x, p.y] if session.bounds.has_point(p) else "")

func _build_materials(parent: Control) -> void:
	var header := _row(parent)
	_label(header, "材质", 24, HEADING_COLOR).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var group := ButtonGroup.new()
	_materials[0] = _button(header, "空气", _pick_material.bind(0), group)
	var grid := _grid(parent, 3)
	var materials := TileDefs.materials()
	for key in materials:
		var id := int(key)
		var button := _button(grid, materials[key].name, _pick_material.bind(id), group)
		button.icon = ImageTexture.create_from_image(TerrainAtlas.tile_image(48, CyrmMap.tile_value(id)))
		button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.add_theme_font_size_override("font_size", 16)
		button.custom_minimum_size = Vector2(70, 100)
		button.tooltip_text = button.text
		_materials[id] = button
	_materials[brush.material_id].button_pressed = true

func _build_layers(parent: Control) -> void:
	var rows := _grid(parent, 3)
	var group := ButtonGroup.new()
	_label(rows, "图层", 24, HEADING_COLOR)
	for title in ["可见", "锁定"]:
		_label(rows, title, 20).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for i in LAYERS.size():
		var name_button := _button(rows, LAYERS[i], _set_layer.bind(i), group)
		name_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_button.button_pressed = i == session.layer
		_layers.append(name_button)
		for property in ["visible", "locked"]:
			var check := _check(rows, "", _layer_flag.bind(i, property), property == "visible")
			check.tooltip_text = ("显示" if property == "visible" else "锁定") + LAYERS[i]
			check.accessibility_name = check.tooltip_text
			check.custom_minimum_size = Vector2(40, 34)
			check.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

func _layer_flag(value: bool, index: int, property: String) -> void:
	if property == "visible":
		canvas.show_layers[index] = value
		canvas.refresh_view()
	else:
		session.locked[index] = value
		canvas.cancel()

func _build_inspector(parent: Control, clipboard: Array) -> void:
	var width := _spin(parent, "笔宽（子格）", 1, 60, brush.width)
	_param_rows.width = width.get_parent()
	width.value_changed.connect(func(value: float) -> void:
		brush.width = int(value)
		_sync_context()
		canvas.preview.queue_redraw())
	_param_rows.outline = _check(parent, "仅画矩形边框", func(on: bool) -> void: brush.outline = on)
	var tints: FoldableContainer = _param_rows.material
	parent.add_child(tints)
	tints.title = "材质调色"
	tints.folded = true
	var fields := UiFactory.box(tints, 4, true)
	for i in 4:
		var spin := _spin(fields, ["色相", "亮度", "饱和度", "透明度"][i], 0, 7, brush.tint[i])
		spin.value_changed.connect(func(value: float) -> void: brush.tint[i] = int(value))
		_tints.append(spin)
	_check(fields, "仅修改调色", func(on: bool) -> void:
		brush.tint_only = on
		tints.title = "材质调色 · 仅调色" if on else "材质调色")
	parent.add_child(_param_rows.color)
	for property: String in ["color", "end_color"]:
		var row := _row(_param_rows.color)
		var start := property == "color"
		_label(row, "颜色" if start else "终点色").size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var picker := _ink if start else ColorPickerButton.new()
		row.add_child(picker)
		picker.custom_minimum_size = Vector2(85, 34)
		picker.color = brush.get(property)
		picker.color_changed.connect(func(value: Color) -> void: brush.set(property, value))
		if not start: _param_rows.end_color = row
	parent.add_child(_param_rows.selection)
	_param_rows.selection.add_child(_selection_info)
	var actions := _grid(_param_rows.selection, 2)
	for item in clipboard:
		_button(actions, item[0], item[1]).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for item in [["清除选区内容", session.clear_selection, KEY_NONE], ["水平镜像", session.mirror.bind(true), KEY_H],
			["垂直镜像", session.mirror.bind(false), KEY_V]]:
		_button(actions, item[0], item[1], null, item[2]).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(_param_rows.points)
	_place_points = _check(_param_rows.points, "连续放置点位", func(_on: bool) -> void:
		canvas.cancel()
		_sync_context())
	_place_points.tooltip_text = "单击画布放置所选类型，Esc 返回选取"
	_param_rows.points.add_child(_point_type)
	_point_option("单人出生点", {"kind": "player"})
	_point_option("第二出生点", {"kind": "player2"})
	for side in [1, 2]:
		_point_option("侧 %d 复活点" % side, {"kind": "respawn", "side": side})
	for id: String in EnemyType.paths:
		_point_option("敌人 · " + str(ENEMY_LABELS.get(id, id)), {"kind": "enemy", "type": id})
	_param_rows.points.add_child(_point_list)
	_point_list.custom_minimum_size.y = 270
	_point_list.add_theme_font_size_override("font_size", 20)
	_point_list.item_selected.connect(func(index: int) -> void:
		_select_point(_point_list.get_item_metadata(index))
		_choose_tool("point"))
	_point_list.item_activated.connect(func(index: int) -> void:
		canvas.center_on(session.map.points[_point_list.get_item_metadata(index)].cell))
	_point_type.item_selected.connect(_change_point_type)
	_param_rows.points.add_child(_point_details)
	_button(_point_details, "移至…", canvas.pick_point_destination).tooltip_text = "单击目标子格移动所选点位"
	_button(_point_details, "删除", func() -> void: session.commit_point(session.selected_point_id, {}))

func _sync_context() -> void:
	var params: Array = _tool.params
	var hidden_ink := "material" if session.layer == CyrmMap.COLOR else "color"
	for parameter: String in _param_rows:
		_param_rows[parameter].visible = parameter != hidden_ink and params.has(parameter)
	_context_title.text = "关卡点位" if _param_rows.points.visible else _tool.label
	canvas.cursor_width = brush.width if _param_rows.width.visible else 1
	var placing := _place_points.button_pressed
	canvas.point_hint = "" if placing else _tool.get("pick_points", "")
	var point := session.selected_point()
	var kind: String = point.get("kind", "")
	var editable_type := not placing and kind in ["enemy", "respawn"]
	_point_details.visible = not kind.is_empty() and not placing
	_point_type.visible = placing or editable_type
	if editable_type: _point_type.select(_option_for(point))
	for i in _point_type.item_count:
		_point_type.set_item_disabled(i, editable_type and _point_type.get_item_metadata(i).kind != kind)

func _selection_changed() -> void:
	var size_in_cells := session.selection.size
	_selection_info.text = "%d × %d 子格" % [size_in_cells.x, size_in_cells.y] if session.selection.has_area() else "拖动框选范围"
	canvas.preview.queue_redraw()

func _toggle_view(menu: PopupMenu, index: int, property: String) -> void:
	var value := not bool(canvas.get(property))
	menu.set_item_checked(index, value)
	canvas.set(property, value)
	canvas.refresh_view()

static func _command_menu(parent: Control, title: String) -> PopupMenu:
	var menu := MenuButton.new()
	menu.text = title
	menu.set_disable_shortcuts(true)
	parent.add_child(menu)
	var popup := menu.get_popup()
	popup.index_pressed.connect(func(i: int) -> void: popup.get_item_metadata(i).call())
	return popup

func _command(menu: PopupMenu, text: String, action: Callable, accelerator := 0) -> void:
	var i := menu.item_count
	menu.add_item(text, i, accelerator)
	menu.set_item_metadata(i, action)
	if accelerator: _shortcuts[accelerator] = action

func _point_option(label: String, fields: Dictionary) -> void:
	_point_type.add_item(label)
	_point_type.set_item_metadata(_point_type.item_count - 1, fields)

func _size_dialog(create: bool) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "新建地图" if create else "调整地图尺寸"
	dialog.ok_button_text = "创建" if create else "调整尺寸"
	var form := VBoxContainer.new()
	form.custom_minimum_size.x = 400
	dialog.add_child(form)
	var initial: Vector2i = DEFAULT_SIZE if create else session.map.size
	var width := _spin(form, "宽（子格）", 1, CyrmMap.MAX_SIZE.x, initial.x)
	var height := _spin(form, "高（子格）", 1, CyrmMap.MAX_SIZE.y, initial.y)
	dialog.confirmed.connect(func() -> void:
		var dims := Vector2i(int(width.value), int(height.value))
		if create:
			_confirm_discard.call_deferred(_open_document.bind(CyrmMap.create(dims), ""))
		else:
			_resize_to.call_deferred(dims))
	_show_dialog(dialog)

func _open_document(map: Dictionary, filename: String, dirty := false) -> void:
	_filename.tooltip_text = filename
	session.open(map, filename, dirty)
	_draft_revision = session.revision
	canvas.fit()

func _changed() -> void:
	_dimensions.text = "%d × %d" % [session.map.size.x, session.map.size.y]
	_filename.text = "未命名.cyrm" if session.path.is_empty() else session.path.get_file()
	_modified.visible = session.dirty()
	if not _modified.visible:
		_draft_revision = session.revision
		MapEditFiles.clear_draft(draft_path)
		_filename.tooltip_text = session.path

func _write_draft() -> void:
	if _draft_revision == session.revision: return
	var error := MapEditFiles.save_draft(draft_path, session.map, session.path)
	if error == OK:
		_draft_revision = session.revision
		_filename.tooltip_text = "%s  草稿 %s" % [session.path, Time.get_time_string_from_system()]
	else:
		_say("草稿保存失败 · " + error_string(error))

func _save(path := session.path) -> void:
	if path.is_empty() or path.begins_with("res://"):
		_file_dialog(true)
		return
	var error := CyrmMap.save_file(session.map, path)
	if error != OK:
		_say("保存失败 · " + error_string(error))
		return
	session.mark_saved(path)
	_say("已保存 " + path.get_file())

func _open_file(path: String) -> void:
	var map := CyrmMap.load_file(path)
	if map.is_empty():
		_say("打开失败 · 无效的地图")
		return
	_open_document(map, path)
	_say("已打开 " + path.get_file())

func _file_dialog(saving := false) -> void:
	var directory := ProjectSettings.globalize_path(MapCatalog.USER_DIR)
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error == OK:
		var filename := session.path.get_file() if not session.path.is_empty() else "新地图.cyrm"
		error = DisplayServer.file_dialog_show(
			"另存为" if saving else "打开地图", directory, filename if saving else "", false,
			DisplayServer.FILE_DIALOG_MODE_SAVE_FILE if saving else DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
			PackedStringArray(["*.cyrm;CYRM 地图"]), _file_selected.bind(saving), get_window().get_window_id())
	if error != OK:
		_say("无法打开系统文件窗口 · " + error_string(error))

func _file_selected(accepted: bool, paths: PackedStringArray, _filter: int, saving: bool) -> void:
	if not accepted or paths.is_empty():
		return
	var path := paths[0]
	if not saving:
		_confirm_discard(_open_file.bind(path))
		return
	if path.get_extension().to_lower() != "cyrm":
		path += ".cyrm"
		if FileAccess.file_exists(path):
			_confirm("覆盖 %s？" % path.get_file(), "覆盖", _save.bind(path))
			return
	_save(path)

func _confirm_discard(proceed: Callable) -> void:
	if session.dirty():
		_confirm("当前地图有未保存的修改。放弃这些修改？", "放弃修改", proceed)
	else:
		proceed.call()

func _confirm(text: String, action: String, proceed: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.dialog_text = text
	dialog.ok_button_text = action
	dialog.confirmed.connect(proceed)
	_show_dialog(dialog, Vector2i(620, 190))

func _show_dialog(dialog: ConfirmationDialog, size_hint := Vector2i.ZERO) -> void:
	dialog.cancel_button_text = "取消"
	add_child(dialog)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible: dialog.queue_free())
	dialog.popup_centered(size_hint)

func _resize_to(dims: Vector2i) -> void:
	if dims == session.map.size:
		return
	var apply_change := func() -> void:
		session.resize_map(dims)
		canvas.fit()
	if dims.x < session.map.size.x or dims.y < session.map.size.y:
		var cropped: Array[String] = []
		var bounds := Rect2i(Vector2i.ZERO, dims)
		for row: Dictionary in session.map.points.values():
			if not bounds.has_point(row.cell):
				cropped.append("%s %s" % [row.kind, row.cell])
		var warning := "画布将裁至 %d × %d 格。" % [dims.x, dims.y]
		if not cropped.is_empty():
			warning += "\n将移除 %d 个越界点位：%s" % [cropped.size(), "、".join(cropped.slice(0, 6))]
		_confirm(warning + "\n可用撤销恢复。", "调整尺寸", apply_change)
	else:
		apply_change.call()

func _validate() -> void:
	var map := session.map
	var problem := SpawnPicker.validate_multiplayer_spawns(map)
	var solo := SpawnPicker.single_spawn(map)
	var sides := SpawnPicker.respawn_cells(map)
	var summary := "侧 1 / 侧 2：%d / %d" % [sides[1].size(), sides[2].size()]
	if problem.is_empty():
		for mode: String in PvpSession.MODE_NAMES:
			var limit := SpawnPicker.player_limit(sides, mode)
			var label := "点位不足"
			if mode == PvpSession.MODE_ROYALE:
				label = "最多 %d 人" % limit if limit else "点位不足，至少需要 %d 人" % RoomOptions.MIN_PLAYERS
			elif limit: label = "通过"
			summary += "    %s：%s" % [PvpSession.mode_name(mode), label]
	else:
		summary += "    " + problem
	_say("单人：%s    %s" % ["无起点" if solo == SpawnPicker.NO_CELL else str(solo), summary])

func _choose_tool(id: String, layer := -1) -> void:
	canvas.cancel()
	var old_layer := session.layer
	if id != active_tool or layer < 0: _place_points.set_pressed_no_signal(false)
	active_tool = id
	if layer >= 0: session.layer = layer
	if _tool.has("layer"): session.layer = _tool.layer
	if canvas.dim_others and old_layer != session.layer: canvas.refresh_view()
	if session.layer != CyrmMap.COLOR: _texture_layer = session.layer
	_layers[session.layer].button_pressed = true
	var button := _tools[id]
	button.button_pressed = true
	_sync_context()
	_say(button.tooltip_text)

func _set_layer(index: int) -> void:
	var id := active_tool if _tool.get("layer", index) == index else "brush"
	_choose_tool(id, index)

func _pick_material(id: int) -> void:
	brush.material_id = id
	var keep_tool: bool = "material" in _tool.params and active_tool != "picker"
	_choose_tool(active_tool if keep_tool else "brush", _texture_layer)
	canvas.grab_focus()

func _reflect_ink() -> void:
	if session.layer == CyrmMap.COLOR:
		_ink.color = brush.color
	else:
		_materials[brush.material_id].button_pressed = true
		for i in _tints.size():
			_tints[i].set_value_no_signal(brush.tint[i])
	_say("已取样")

func _travel(direction: int) -> void:
	canvas.cancel()
	session.travel(direction)

func _cut() -> void:
	if not session.locked[session.layer] and session.copy_selection(): session.clear_selection()

func _paste() -> void:
	var at := canvas.mouse_cell
	if not session.bounds.has_point(at):
		at = session.selection.position if session.selection.has_area() else Vector2i.ZERO
	session.paste(at)

func _option_for(point: Dictionary) -> int:
	var choice := point.duplicate()
	choice.erase("cell")
	for i in _point_type.item_count:
		if _point_type.get_item_metadata(i) == choice: return i
	return -1

func _point_label(id: int) -> String:
	var point: Dictionary = session.map.points[id]
	return "%s  %s" % [_point_type.get_item_text(_option_for(point)), point.cell]

func _point_index(id: int) -> int:
	if id < 0: return -1
	for i in _point_list.item_count:
		if _point_list.get_item_metadata(i) == id: return i
	return -1

func _refresh_points(updated_id: int) -> void:
	canvas.cancel()
	canvas.markings.queue_redraw()
	var existing := _point_index(updated_id)
	if existing >= 0:
		_point_list.set_item_text(existing, _point_label(updated_id))
	else:
		_point_list.clear()
		for id in session.point_ids():
			var index := _point_list.add_item(_point_label(id))
			_point_list.set_item_metadata(index, id)
			if id == session.selected_point_id: _point_list.select(index)
	_sync_context()

func _select_point(id: int) -> void:
	session.selected_point_id = id
	canvas.markings.queue_redraw()
	_point_list.deselect_all()
	var index := _point_index(id)
	if index >= 0:
		_point_list.select(index)
		_point_list.ensure_current_is_visible.call_deferred()

func _tool_pressed(cell: Vector2i, event: InputEventMouseButton, point_id: int) -> void:
	if canvas.destination_point_id >= 0:
		var id := canvas.destination_point_id
		canvas.cancel()
		if event.double_click: start_trial(cell)
		else: session.commit_point(id, cell)
	elif point_id >= 0 or active_tool == "point":
		_point_pressed(cell, point_id, event.double_click)
	elif active_tool == "select":
		_selection_pressed(cell, event.shift_pressed)
	elif active_tool == "picker":
		brush.sample(session, cell)
		_reflect_ink()
	elif session.locked[session.layer]:
		_say("当前图层已锁定")
	elif active_tool == "bucket":
		brush.bucket(cell, session)
	elif active_tool == "gradient" and not session.selection.has_area():
		_say("先框选要绘制渐变的区域")
	else:
		var preview: String = _tool.preview
		if "outline" in _tool.params and brush.outline: preview = "outline"
		var paint := brush.gradient.bind(session) if active_tool == "gradient" else brush.stroke.bind(session, active_tool)
		canvas.begin_drag(preview, paint)

func _selection_pressed(cell: Vector2i, shift: bool) -> void:
	var moving := session.selection.has_point(cell) and not shift
	canvas.begin_drag("move" if moving else "select", func(path: Array[Vector2i]) -> void:
		if moving: session.move_selection(path[-1] - path[0])
		else: session.selection = MapEditSession.cell_box(path[0], path[-1]))

func _point_pressed(cell: Vector2i, id: int, double_click: bool) -> void:
	if _place_points.button_pressed:
		var fields: Dictionary = _point_type.get_selected_metadata()
		var placed := session.place_point(fields.merged({"cell": cell}))
		if placed >= 0: _select_point(placed)
		return
	if double_click and active_tool == "point":
		start_trial(session.map.points[id].cell if id >= 0 else cell)
		return
	_select_point(id)
	_choose_tool("point")
	if id < 0:
		_say("此处没有点位 · 双击可从这里试玩")
		return
	var anchor: Vector2i = session.selected_point().cell
	canvas.begin_drag("point_drag", func(path: Array[Vector2i]) -> void:
		session.commit_point(id, session.dragged_point_cell(anchor, path[0], path[-1])))

func _change_point_type(index: int) -> void:
	var choice: Dictionary = _point_type.get_item_metadata(index)
	var point := session.selected_point()
	if not _place_points.button_pressed and point.get("kind") == choice.kind:
		session.commit_point(session.selected_point_id, choice.merged({"cell": point.cell}))

func _notes_dialog() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "地图注记"
	var field := TextEdit.new()
	field.custom_minimum_size = Vector2(650, 290)
	field.text = session.map.notes
	dialog.add_child(field)
	dialog.confirmed.connect(func() -> void: session.put_notes(field.text))
	_show_dialog(dialog)

func start_trial(cell: Vector2i = session.selected_point().get("cell", SpawnPicker.NO_CELL)) -> void:
	if trial != null:
		return
	var map := session.map
	var spawn := cell if session.bounds.has_point(cell) else SpawnPicker.single_spawn(map)
	if spawn == SpawnPicker.NO_CELL:
		_say("地图没有可用起点")
		return
	trial = SoloLevel.create(map, spawn, WeaponRegistry.enabled_ids([]))
	canvas.cancel()
	_workspace.hide()
	add_child(trial)
	var hint := CanvasLayer.new()
	hint.layer = 160
	trial.add_child(hint)
	var text := UiFactory.label("试玩    Esc 返回地图编辑器", 28)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.add_theme_constant_override("outline_size", 5)
	hint.add_child(text)
	text.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	text.offset_top = 22
	text.offset_bottom = 66

func finish_trial() -> void:
	if trial == null:
		return
	get_tree().paused = false
	remove_child(trial)
	trial.queue_free()
	trial = null
	_workspace.show()
	canvas.grab_focus()
	_say("已返回编辑现场")

func _input(event: InputEvent) -> void:
	if trial != null and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		finish_trial.call_deferred()

func _shortcut_input(event: InputEvent) -> void:
	if trial != null or not event is InputEventKey or not event.pressed or event.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	var key: Key = event.get_keycode_with_modifiers()
	if focus is LineEdit or focus is TextEdit:
		if not focus.get_parent() is SpinBox or _shortcuts.get(key) != _save: return
	match key:
		KEY_DELETE:
			if active_tool == "point": session.commit_point(session.selected_point_id, {})
			else: session.clear_selection()
		KEY_ESCAPE:
			if not canvas.cancel():
				if _place_points.button_pressed:
					_choose_tool("point")
				else:
					session.selection = Rect2i()
		_:
			if not _shortcuts.has(key):
				return
			_shortcuts[key].call()
	get_viewport().set_input_as_handled()

func _say(text: String) -> void:
	_status.text = text
	_status.tooltip_text = text

static func _row(parent: Control) -> HBoxContainer:
	return UiFactory.box(parent, 6, false) as HBoxContainer

static func _grid(parent: Control, columns: int) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = columns
	parent.add_child(grid)
	return grid

static func _label(parent: Control, text: String, font_size := 24, color := Color(0.812, 0.859, 0.843)) -> Label:
	var label := UiFactory.label(text, font_size, color)
	parent.add_child(label)
	return label

static func _flex_label(parent: Control) -> Label:
	var label := _label(parent, "")
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label

func _button(parent: Control, text: String, action: Callable, group: ButtonGroup = null, shortcut := KEY_NONE) -> Button:
	var button := Button.new()
	button.text = text
	if group:
		button.toggle_mode = true
		button.button_group = group
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if shortcut: _shortcuts[shortcut] = action
	parent.add_child(button)
	button.pressed.connect(action)
	return button

static func _sidebar(parent: Control, width: float) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = width
	parent.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var column := UiFactory.box(scroll, 9, true) as VBoxContainer
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return column

static func _check(parent: Control, text: String, action: Callable, value := false) -> CheckBox:
	var check := CheckBox.new()
	check.text = text
	check.button_pressed = value
	parent.add_child(check)
	check.toggled.connect(action)
	return check

static func _spin(parent: Control, text: String, minimum: int, maximum: int, value: int) -> SpinBox:
	var line := _row(parent)
	_label(line, text).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.value = value
	spin.custom_minimum_size.x = 112
	line.add_child(spin)
	return spin
