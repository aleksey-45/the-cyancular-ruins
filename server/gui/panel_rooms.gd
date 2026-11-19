extends RefCounted


const ROW_H := 60
const ROOM_ROWS_MAX := 6
const MAP_UNITS := 15

const COL_TITLES := ["房号", "模式", "人数", "状态", "端口", "房龄", "地图"]
const COL_WIDTHS := [104, 152, 88, 168, 104, 104, 0]

const STATE_TEXT := {ServerStatus.STATE_WAITING: "等待中",
		ServerStatus.STATE_IN_MATCH: "对局中", ServerStatus.STATE_STALE: "worker 已退出"}

var _host = null
var _sel_block: PanelContainer = null
var _roster_block: PanelContainer = null

var _rows_col: VBoxContainer = null
var _rows: Dictionary = {}
# ★ 初值必须与"空房集合"不同:否则首次刷新判定"集合没变"⇒ 跳过重建 ⇒ 空态那一行永远不建。
var _codes: Array = [""]
var meta_label: Label = null

var selected_code := ""
var selected_kind := ""


func setup(host, sel_block: PanelContainer, roster_block: PanelContainer) -> void:
	_host = host
	_sel_block = sel_block
	_roster_block = roster_block


func _build_rooms_block() -> PanelContainer:
	var panel: PanelContainer = UiFactory.menu_panel(_host.PAD)
	var body := panel.get_node("Body") as PanelContainer
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	body.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	head.add_child(_inset_left(UiFactory.label("房 间", 32, UiFactory.C_GOLD), 16))
	head.add_child(_host._spacer())
	meta_label = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	head.add_child(meta_label)
	col.add_child(head)

	col.add_child(_build_rooms_header())

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_MAXIMIZE_FIRST
	scroll.custom_maximum_size.y = ROOM_ROWS_MAX * ROW_H + (ROOM_ROWS_MAX - 1) * int(_host.ROW_GAP)
	_host._style_vbar(scroll.get_v_scroll_bar())
	_rows_col = VBoxContainer.new()
	_rows_col.add_theme_constant_override("separation", int(_host.ROW_GAP))
	_rows_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_col)
	col.add_child(scroll)
	return panel


func _build_rooms_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	for i in COL_TITLES.size():
		row.add_child(_host._cell(str(COL_TITLES[i]), int(COL_WIDTHS[i]), 32, UiFactory.C_TEXT_DIM))
	return _inset(row, 16)


func _sync_rows(rooms: Array[Dictionary]) -> void:
	var keys: Array = []
	for r in rooms:
		keys.append(ServerStatus.row_key(str(r["kind"]), str(r["code"])))
	if keys != _codes:
		_rebuild_rows(rooms)
		_codes = keys
		return
	for r in rooms:
		_apply_row(_rows[ServerStatus.row_key(str(r["kind"]), str(r["code"]))]["cells"], r)


func _rebuild_rows(rooms: Array[Dictionary]) -> void:
	for c in _rows_col.get_children():
		_rows_col.remove_child(c)
		c.queue_free()
	_rows.clear()
	if rooms.is_empty():
		_rows_col.add_child(UiFactory.label("现在没有房间。玩家建房后会出现在这里。", 32, UiFactory.C_TEXT_MUTE))
		return
	for r in rooms:
		var code := str(r["code"])
		var kind := str(r["kind"])
		var key := ServerStatus.row_key(kind, code)
		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel", UiFactory.row_box())
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		panel.add_child(row)
		var cells: Array[Label] = []
		for i in COL_TITLES.size():
			var l: Label = _host._cell("", int(COL_WIDTHS[i]), 32, UiFactory.C_TEXT)
			row.add_child(l)
			cells.append(l)
		panel.custom_minimum_size.y = ROW_H
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		panel.gui_input.connect(_on_row_input.bind(code, kind))
		_rows_col.add_child(panel)
		_rows[key] = {"panel": panel, "cells": cells, "code": code, "kind": kind}
		_apply_row(cells, r)
	_apply_selection_styles()


func _apply_row(cells: Array[Label], r: Dictionary) -> void:
	var state := str(r["state"])
	cells[0].text = str(r["code"])
	cells[0].add_theme_color_override("font_color", UiFactory.C_WHITE)

	var kind := str(r["kind"])
	cells[1].text = str(_host.KIND_TEXT.get(kind, kind))
	cells[1].add_theme_color_override("font_color", _kind_color(kind))

	cells[2].text = "%d / %d" % [int(r["players"]), int(r["cap"])]
	cells[2].add_theme_color_override("font_color", UiFactory.C_TEXT)

	cells[3].text = str(STATE_TEXT.get(state, state))
	# ★ 颜色表也用 STATE_* 常量(CM-10):字面量键在加第四态时会静默回落 C_TEXT,"worker 已退出"不再红且不报错。
	cells[3].add_theme_color_override("font_color", {
		ServerStatus.STATE_WAITING: UiFactory.C_TEXT_DIM, ServerStatus.STATE_IN_MATCH: UiFactory.C_GOLD,
		ServerStatus.STATE_STALE: UiFactory.C_DANGER}.get(state, UiFactory.C_TEXT))

	var port := int(r["worker_port"])
	cells[4].text = "—" if port <= 0 else str(port)
	cells[4].add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
	cells[5].text = _mmss(float(r["age_sec"]))
	cells[5].add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
	cells[6].text = UiFactory.fit_name(str(r["map"]), MAP_UNITS)
	cells[6].add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)


func _sync_selection(rooms: Array[Dictionary]) -> void:
	var found: Dictionary = {}
	for r in rooms:
		if str(r["code"]) == selected_code and str(r["kind"]) == selected_kind:
			found = r
			break
	if found.is_empty():
		if not selected_code.is_empty():
			selected_code = ""
			selected_kind = ""
			_host._reset_confirm()
			_show_right(false)
			_apply_selection_styles()
		_host._refresh_log({})
		return
	_show_right(true)
	_host._render_selected(found)
	_host._render_roster(found)
	_host._refresh_log(found)


func _select(code: String, kind: String) -> void:
	if code == selected_code and kind == selected_kind:
		return
	# ★ 改选目标必须撤销武装:否则"武装 A → 改选 B → 再点"会关掉 B(C1)。
	_host._reset_confirm()
	selected_code = code
	selected_kind = kind
	_apply_selection_styles()
	var snap: Dictionary = _host._snapshot()
	if not snap.is_empty():
		_sync_selection(snap["rooms"])


func _on_row_input(event: InputEvent, code: String, kind: String) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_select(code, kind)


func _apply_selection_styles() -> void:
	for key in _rows:
		var panel: PanelContainer = _rows[key]["panel"]
		var row_code := str(_rows[key]["code"])
		var row_kind := str(_rows[key]["kind"])
		panel.add_theme_stylebox_override("panel",
				_row_sb(row_code == selected_code and row_kind == selected_kind))


func _row_sb(selected: bool) -> StyleBoxFlat:
	var sb := UiFactory.row_box()
	if selected:
		sb.border_color = UiFactory.C_ACCENT
		sb.set_border_width_all(2)
	return sb


func _kind_color(kind: String) -> Color:
	match kind:
		"1v1":
			return UiFactory.C_ACCENT
		"royale":
			return UiFactory.C_MODE_ROYALE
		"team":
			return UiFactory.C_MODE_TEAM
	return UiFactory.C_TEXT


func _show_right(v: bool) -> void:
	_sel_block.visible = v
	_roster_block.visible = v


func _inset(c: Control, px: int) -> Control:
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_left", px)
	wrap.add_theme_constant_override("margin_right", px)
	wrap.add_child(c)
	return wrap


func _inset_left(c: Control, px: int) -> Control:
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_left", px)
	wrap.add_child(c)
	return wrap


func _mmss(sec: float) -> String:
	var s := maxi(0, int(sec))
	return "%02d:%02d" % [s / 60, s % 60]
