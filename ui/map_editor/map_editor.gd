class_name MapEditor
extends Control

const HEADING_COLOR := Color("#a9dcca")
const POINT_HINT := "拖动移动点位 · 双击试玩"
const TOOLS := {
	"brush": {"label": "画笔", "key": KEY_B, "params": ["width", "material", "color"],
		"pick_points": POINT_HINT + " · Alt 在点位下绘制"},
	"erase": {"label": "橡皮", "key": KEY_E, "params": ["width"]},
	"line": {"label": "直线", "key": KEY_L, "params": ["width", "material", "color"]},
	"rect": {"label": "矩形", "key": KEY_NONE, "params": ["outline", "material", "color"]},
	"bucket": {"label": "填充", "key": KEY_G, "params": ["material", "color"]},
	"picker": {"label": "吸管", "key": KEY_I, "params": ["material", "color"]},
	"select": {"label": "选区", "key": KEY_M, "params": ["selection"]},
	"gradient": {"label": "渐变", "key": KEY_NONE, "params": ["color", "end_color"], "min_layer": CyrmMap.FIRST_BACKGROUND},
	"point": {"label": "点位", "key": KEY_P, "params": ["points"], "pick_points": POINT_HINT},
}

var active_tool := "brush"
var _tool: Dictionary:
	get: return TOOLS[active_tool]
var session := MapEditSession.new()
var brush := MapBrush.new()
var canvas := MapEditCanvas.new()
var _workspace := VBoxContainer.new()
var _filename: Label
var _modified: Label
var _status: Label
var _materials_panel: MapEditorMaterials
var _points: MapEditorPoints
var _files: MapEditorFiles
var _toolbar: MapEditorToolbar
var _trial: MapEditorTrial
var _inspector: MapEditorInspector
var _palette: MapEditorToolPalette
var _clipboard: Array = []
var _shortcuts: Dictionary[int, Callable] = {}
var _layers_panel: MapEditorLayers
var _texture_layer := CyrmMap.SCENE
var _dimensions: Label
var _context_title: Label
var draft_path := MapEditorFiles.DRAFT_PATH
var _closing := false
var _auto_quit := true

func _ready() -> void:
	_auto_quit = get_tree().auto_accept_quit
	get_tree().auto_accept_quit = false
	theme = preload("res://ui/map_editor/editor_theme.tres")
	UiDesign.cover(self, UiDesign.shade(Color("#0e1519")))
	add_child(_workspace)
	_workspace.add_theme_constant_override("separation", 10)
	_workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	_files = MapEditorFiles.new(session, _say)
	_files.draft_path = draft_path
	add_child(_files)
	_trial = MapEditorTrial.new()
	add_child(_trial)
	_clipboard = [["复制选区", session.copy_selection, KEY_C], ["剪切选区", _cut, KEY_X], ["粘贴", _paste, KEY_V]]
	_build_ui()
	_trial.setup(session, canvas, _workspace, _say)
	session.changed.connect(_sync_document)
	session.selection_changed.connect(_selection_changed)
	session.cells_changed.connect(canvas.paint_cells)
	session.points_changed.connect(_refresh_points)
	canvas.session = session
	canvas.brush = brush
	canvas.tool_pressed.connect(_tool_pressed)
	_selection_changed()
	var autosave := Timer.new()
	autosave.wait_time = 10.0
	autosave.autostart = true
	autosave.timeout.connect(_files.write_draft)
	add_child(autosave)
	var draft := MapEditFiles.read_draft(_files.draft_path)
	if draft.is_empty():
		_files.open_document(CyrmMap.create(MapEditorFiles.DEFAULT_SIZE), "")
		_say("左键绘制 · 拖动点位移动 · 中键平移 · 滚轮缩放")
	else:
		_files.open_document(draft.map, draft.path, true)
		_say("已恢复上次未保存的草稿")

func _exit_tree() -> void:
	get_tree().auto_accept_quit = _auto_quit

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_node_ready() and not _closing:
		_files.confirm_discard.call_deferred(_leave.bind(true))

func _request_exit() -> void:
	_files.confirm_discard(_leave.bind(false))

func _leave(quit: bool) -> void:
	_closing = true
	_files.discard_draft()
	if quit: get_tree().quit()
	else: get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _build_ui() -> void:
	_toolbar = MapEditorToolbar.new()
	_workspace.add_child(_toolbar)
	_toolbar.setup(canvas)
	_shortcuts.merge(_toolbar.shortcuts)
	var cmd := KEY_MASK_META if OS.has_feature("macos") else KEY_MASK_CTRL
	_shortcuts[cmd | KEY_S] = _files.save
	_toolbar.new_requested.connect(func() -> void: _files.size_dialog(true))
	_toolbar.open_requested.connect(_files.open_dialog)
	_toolbar.save_requested.connect(_files.save)
	_toolbar.save_as_requested.connect(_files.open_dialog.bind(true))
	_toolbar.undo_requested.connect(_travel.bind(session.undo))
	_toolbar.redo_requested.connect(_travel.bind(session.redo))
	_toolbar.copy_requested.connect(session.copy_selection)
	_toolbar.cut_requested.connect(_cut)
	_toolbar.paste_requested.connect(_paste)
	_toolbar.resize_requested.connect(_files.size_dialog.bind(false))
	_toolbar.notes_requested.connect(_notes_dialog)
	_toolbar.validate_requested.connect(_validate)
	_toolbar.play_requested.connect(start_trial)
	_toolbar.exit_requested.connect(_request_exit)

	var body := UiDesign.box(_workspace, 8, false)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left := _sidebar(body, 292)
	_palette = MapEditorToolPalette.new()
	left.add_child(_palette)
	_palette.setup(TOOLS, active_tool)
	_palette.tool_selected.connect(_choose_tool)
	_shortcuts.merge(_palette.shortcuts)
	left.add_child(HSeparator.new())
	_build_materials(left)

	var center := UiDesign.box(body, 4, true)
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
	_inspector = MapEditorInspector.new()
	right.add_child(_inspector)
	_inspector.setup(session, brush, canvas, _clipboard, _sync_context)
	_points = _inspector.points
	_points.place_button.toggled.connect(func(_placing: bool) -> void:
		canvas.cancel()
		_sync_context())
	_points.point_selected.connect(func(id: int) -> void:
		_select_point(id)
		_choose_tool("point"))
	_points.point_activated.connect(func(id: int) -> void:
		canvas.center_on(session.map.points[id].cell))

	var footer := _row(_workspace)
	_status = _flex_label(footer)
	var coords := _label(footer, "")
	canvas.cursor_moved.connect(func(p: Vector2i) -> void:
		coords.text = "子格 %d, %d" % [p.x, p.y] if session.bounds.has_point(p) else "")

func _build_materials(parent: Control) -> void:
	_materials_panel = MapEditorMaterials.new()
	parent.add_child(_materials_panel)
	_materials_panel.setup(brush)
	_materials_panel.material_selected.connect(_pick_material)

func _build_layers(parent: Control) -> void:
	_layers_panel = MapEditorLayers.new()
	parent.add_child(_layers_panel)
	_layers_panel.setup(session, canvas)
	_layers_panel.layer_selected.connect(_set_layer)

func _sync_context() -> void:
	var params: Array = _tool.params
	var hidden_ink := "material" if session.on_background else "color"
	_inspector.sync(params, hidden_ink)
	_context_title.text = "关卡点位" if params.has("points") else _tool.label
	canvas.cursor_width = brush.width if params.has("width") else 1
	canvas.point_hint = "" if _points.is_placing() else _tool.get("pick_points", "")

func _sync_document() -> void:
	_filename.text = "未命名.cyrm" if session.path.is_empty() else session.path.get_file()
	_filename.tooltip_text = session.path
	_modified.visible = session.dirty()
	_dimensions.text = "%d × %d" % [session.map.size.x, session.map.size.y]

func _selection_changed() -> void:
	_inspector.set_selection(session.selection)
	canvas.preview.queue_redraw()

func _validate() -> void:
	_trial.validate()

func _choose_tool(id: String, layer := -1) -> void:
	canvas.cancel()
	var old_layer := session.layer
	if id != active_tool or layer < 0: _points.reset_placing()
	active_tool = id
	if layer >= 0: session.layer = layer
	session.layer = maxi(session.layer, _tool.get("min_layer", 0))
	if canvas.dim_others and old_layer != session.layer: canvas.refresh_view()
	if not session.on_background: _texture_layer = session.layer
	_layers_panel.select_layer(session.layer)
	_palette.select_tool(id)
	_sync_context()
	_say(_palette.tooltip(id))

func _set_layer(index: int) -> void:
	var id := active_tool if index >= _tool.get("min_layer", 0) else "brush"
	_choose_tool(id, index)

func _pick_material(id: int) -> void:
	brush.material_id = id
	var keep_tool: bool = "material" in _tool.params and active_tool != "picker"
	_choose_tool(active_tool if keep_tool else "brush", _texture_layer)
	canvas.grab_focus()

func _reflect_ink() -> void:
	if session.on_background:
		_inspector.set_ink(brush.color)
	else:
		_materials_panel.select_material(brush.material_id)
		_inspector.set_tints(brush.tint)
	_say("已取样")

func _travel(action: Callable) -> void:
	canvas.cancel()
	action.call()

func _cut() -> void:
	if not session.locked[session.layer] and session.copy_selection(): session.clear_selection()

func _paste() -> void:
	var at := canvas.mouse_cell
	if not session.bounds.has_point(at):
		at = session.selection.position if session.selection.has_area() else Vector2i.ZERO
	session.paste(at)

func _refresh_points(updated_id: int) -> void:
	canvas.cancel()
	canvas.markings.queue_redraw()
	_points.refresh(updated_id)

func _select_point(id: int) -> void:
	session.selected_point_id = id
	canvas.markings.queue_redraw()
	_points.select(id)

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
		var paint := brush.gradient.bind(session) if active_tool == "gradient" else brush.stroke.bind(session, active_tool)
		canvas.begin_drag(active_tool, paint)

func _selection_pressed(cell: Vector2i, shift: bool) -> void:
	var moving := session.selection.has_point(cell) and not shift
	canvas.begin_drag("move" if moving else "select", func(path: Array[Vector2i]) -> void:
		if moving: session.move_selection(path[-1] - path[0])
		else: session.selection = MapEditSession.cell_box(path[0], path[-1]))

func _point_pressed(cell: Vector2i, id: int, double_click: bool) -> void:
	if _points.is_placing():
		var placed := session.place_point(_points.placed_fields().merged({"cell": cell}))
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

func _notes_dialog() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "地图注记"
	var field := TextEdit.new()
	field.custom_minimum_size = Vector2(650, 290)
	field.text = session.map.notes
	dialog.add_child(field)
	dialog.confirmed.connect(func() -> void: session.put_notes(field.text))
	_files.show_dialog(dialog)

func start_trial(cell: Vector2i = session.selected_point().get("cell", SpawnPicker.NO_CELL)) -> void:
	_trial.start(cell)

func finish_trial() -> void:
	_trial.finish()

func _input(event: InputEvent) -> void:
	if _trial.active() and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		finish_trial.call_deferred()

func _shortcut_input(event: InputEvent) -> void:
	if _trial.active() or not event is InputEventKey or not event.pressed or event.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	var key: Key = event.get_keycode_with_modifiers()
	if key != KEY_ESCAPE and (focus is LineEdit or focus is TextEdit):
		if not focus.get_parent() is SpinBox or _shortcuts.get(key) != _files.save: return
	match key:
		KEY_DELETE:
			if active_tool == "point": session.commit_point(session.selected_point_id, {})
			else: session.clear_selection()
		KEY_ESCAPE:
			if not canvas.cancel():
				if _points.is_placing():
					_choose_tool("point")
				elif session.selection.has_area():
					session.selection = Rect2i()
				else:
					_request_exit.call_deferred()
		_:
			if not _shortcuts.has(key):
				return
			_shortcuts[key].call()
	get_viewport().set_input_as_handled()

func _say(text: String) -> void:
	_status.text = text
	_status.tooltip_text = text

static func _row(parent: Control) -> HBoxContainer:
	return UiDesign.box(parent, 6, false) as HBoxContainer

static func _label(parent: Control, text: String, font_size := 24, color := Color(0.812, 0.859, 0.843)) -> Label:
	var label := UiDesign.label(text, font_size, color)
	parent.add_child(label)
	return label

static func _flex_label(parent: Control) -> Label:
	var label := _label(parent, "")
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label

static func _button(parent: Control, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
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
	var column := UiDesign.box(scroll, 9, true) as VBoxContainer
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return column
