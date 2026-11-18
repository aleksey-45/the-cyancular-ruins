class_name PvpHud
extends CanvasLayer

signal leave_requested

const Mode := MatchFrame.Mode
const BOARD_ROW_WIDTH := 712.0

class Section:
	var title: String
	var color: Color
	var headers: Array
	var rows: Array[Array] = []

class Round:
	var score := ""
	var board: Array[Array] = []
	var banner: Array[String] = []
	var countdown := -1.0
	var remaining := -1.0
	var grace := -1.0
	var timer := ""
	var title := ""
	var subtitle := ""
	var sections: Array[Section] = []

var mode := Mode.DUEL
var _broadcast := Broadcast.new()
var _score: Label
var _grace_label: Label
var _grace_wrap: PanelContainer
var _ping: Label
var _board_bg: ColorRect
var _board := VBoxContainer.new()
var _timer := Label.new()
var _status := CenterContainer.new()
var _status_label: Label
var _result := Control.new()
var _result_panel: PanelContainer
var _result_title := Label.new()
var _result_subtitle := Label.new()
var _sections: HBoxContainer

var _grace_left := -1.0
var _rows: Array[Label] = []
var _remaining := -1.0
var _leaving := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 130
	_board_bg = UiFactory.shade(Color(0, 0, 0, 0.25))
	_board_bg.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	UiFactory.place(self, _board_bg, Rect2(-736, 96, 720, 64), Vector2(1, 0))
	_board.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board.theme = UiFactory.MENU_THEME
	_board.add_theme_constant_override("separation", 4)
	UiFactory.place(self, _board, Rect2(-716, 102, 712, 0), Vector2(1, 0))
	_board.add_child(UiFactory.label("—— 击杀排行榜 ——", 32, UiFactory.C_ACCENT))
	_board.add_child(_timer)
	UiFactory.cover(self, _broadcast)
	var royale := mode == Mode.ROYALE
	_score = _center_label(Color(0.9, 0.95, 1.0))
	var score_wrap := _plate(_score, Vector2(24, 8))
	score_wrap.grow_horizontal = Control.GROW_DIRECTION_BOTH
	UiFactory.place(self, score_wrap, Rect2(0, 16, 0, -16), Vector2(0.5, 0.0))
	score_wrap.visible = not royale
	_grace_label = _center_label(UiFactory.C_GRACE)
	_grace_wrap = _plate(_grace_label, Vector2(24, 8))
	_grace_wrap.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_grace_wrap.hide()
	UiFactory.place(self, _grace_wrap, Rect2(0, 72, 0, -72), Vector2(0.5, 0.0))
	_ping = UiFactory.label("--ms", 32, Color(0.75, 0.8, 0.9, 0.9))
	_ping.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var ping_wrap := _plate(_ping, Vector2(14, 6) if royale else Vector2(24, 8))
	ping_wrap.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ping_wrap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	UiFactory.place(self, ping_wrap, Rect2(-24, -24, 0, 0), Vector2.ONE)
	_build_status()
	_build_result()
	_board_bg.visible = royale
	_board.visible = royale
	match mode:
		Mode.ROYALE: _broadcast.set_broadcast(true, "大乱斗", "等待开局…")
		Mode.TEAM: _broadcast.set_broadcast(true, "等待玩家加载", "")
		_: _broadcast.set_broadcast(true, "对战开始", "第 1 局")

static func _center_label(color: Color) -> Label:
	var label := UiFactory.label("", 32, color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label

static func _plate(content: Control, margin: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", UiFactory.plate(UiFactory.C_PLATE, margin))
	panel.add_child(content)
	return panel

func _build_status() -> void:
	var layer_node := CanvasLayer.new()
	layer_node.layer = 140
	add_child(layer_node)
	_status.hide()
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFactory.place(layer_node, _status, Rect2(0, 128, 0, 0))
	_status.anchor_right = 1.0
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", UiFactory.panel_box(false))
	_status.add_child(panel)
	_status_label = UiFactory.label("", 32, UiFactory.C_DANGER)
	panel.add_child(_status_label)

func _build_result() -> void:
	var layer_node := CanvasLayer.new()
	layer_node.layer = 150
	add_child(layer_node)
	_result.hide()
	_result.theme = UiFactory.MENU_THEME
	UiFactory.cover(layer_node, _result)
	UiFactory.cover(_result, UiFactory.shade(Color(0, 0, 0, 0.55), true))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 24)
	_result_panel = UiFactory.framed(body)
	_result_panel.custom_minimum_size.x = 1120
	UiFactory.place(_result, _result_panel, Rect2(), Vector2(0.5, 0.5))
	_result_title.theme_type_variation = &"H1"
	_result_subtitle.theme_type_variation = &"Dim"
	for label in [_result_title, _result_subtitle]:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		body.add_child(label)
	_sections = UiFactory.box(body, 48, false)
	_sections.alignment = BoxContainer.ALIGNMENT_CENTER
	UiFactory.action(body, "返回主菜单", Vector2(420, 88), &"BtnGold", _request_leave)

func _process(delta: float) -> void:
	if _remaining >= 0.0:
		_update_timer(_remaining - delta)
	if _grace_left >= 0.0:
		_update_grace(maxf(0.0, _grace_left - delta))

func set_status(message: String) -> void:
	_status_label.text = message
	_status.visible = not message.is_empty()

func set_ping(ms: int) -> void:
	_ping.text = "%dms" % ms
	_ping.add_theme_color_override("font_color", UiFactory.ping_color(ms))

func _update_grace(seconds: float) -> void:
	_grace_left = seconds
	_grace_wrap.visible = seconds >= 0.0
	if _grace_wrap.visible:
		_grace_label.text = "对手掉线中,等待重连… 剩余 %ds" % ceili(seconds)

func show_round(round: Round) -> void:
	_score.text = round.score
	_update_grace(round.grace)
	if mode == Mode.ROYALE:
		_show_board(round.board)
	_remaining = -1.0
	if round.remaining >= 0.0:
		_update_timer(round.remaining)
	elif not round.timer.is_empty():
		_timer.text = round.timer
	if round.countdown >= 0.0:
		_broadcast.start_countdown(round.countdown, round.banner[1])
	elif not round.banner.is_empty():
		_broadcast.set_broadcast(not round.banner[0].is_empty(), round.banner[0], round.banner[1])
	if not round.title.is_empty() and not _result.visible:
		_show_result(round)

func _show_result(round: Round) -> void:
	_result_title.text = round.title
	_result_subtitle.text = round.subtitle
	_result_subtitle.visible = mode != Mode.ROYALE
	for section in round.sections:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 12)
		box.add_child(UiFactory.header_strip(section.title, 32, true, section.color))
		var grid := GridContainer.new()
		grid.columns = section.headers.size()
		grid.add_theme_constant_override("h_separation", 24)
		grid.add_theme_constant_override("v_separation", 8)
		_add_result_row(grid, section.headers, UiFactory.C_TEXT_DIM)
		for row in section.rows:
			_add_result_row(grid, row[1], UiFactory.C_TEXT if row[0] else UiFactory.C_TEXT_DIM)
		box.add_child(grid)
		_sections.add_child(box)
	_result.show()
	var half := _result_panel.get_combined_minimum_size() * 0.5
	_result_panel.offset_left = -half.x
	_result_panel.offset_top = -half.y
	_result_panel.offset_right = half.x
	_result_panel.offset_bottom = half.y

static func _add_result_row(grid: GridContainer, values: Array, color: Color) -> void:
	for value in values:
		grid.add_child(UiFactory.label(str(value), 32, color))

func _request_leave() -> void:
	if not _leaving:
		_leaving = true
		leave_requested.emit()

func _unhandled_input(event: InputEvent) -> void:
	if _result.visible and event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_request_leave()

func _update_timer(seconds: float) -> void:
	_remaining = maxf(seconds, 0.0)
	var whole := int(_remaining)
	_timer.text = "剩余时间  %d:%02d" % [whole / 60, whole % 60]

func _show_board(rows: Array[Array]) -> void:
	var resized := _rows.size() != rows.size()
	while _rows.size() > rows.size():
		var row: Label = _rows.pop_back()
		_board.remove_child(row)
		row.queue_free()
	while _rows.size() < rows.size():
		var row := UiFactory.label("", 32, UiFactory.C_TEXT)
		row.custom_minimum_size.x = BOARD_ROW_WIDTH
		row.size_flags_horizontal = Control.SIZE_FILL
		row.clip_text = true
		_board.add_child(row)
		_rows.append(row)
	if resized:
		_board_bg.size.y = _board.get_combined_minimum_size().y + 34
	for i in rows.size():
		_rows[i].text = rows[i][0]
		_rows[i].add_theme_color_override("font_color", rows[i][1])
