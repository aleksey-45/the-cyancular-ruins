class_name PvpHud
extends CanvasLayer

# 联机 HUD 使用同一帧里的榜单、倒计时和结算内容。

signal return_requested

const STATUS_BANNER_SCENE := preload("res://ui/hud/status_banner.tscn")


const BOARD_W := 720.0                                   # 排行榜面板宽
const BOARD_TOP := UiDesign.SP_9 + UiDesign.SP_6         # 96:离屏幕上沿
const BOARD_INSET := 6.0                                 # 排行榜内容相对底板的内边距。
const BOARD_ROW_WIDTH := 712                             # 720 - SP_2:行内容宽
const BOARD_BG_EXTRA := 34.0                             # 底板比内容多出的高度(上下留白)
const BOARD_DIM_ALPHA := 0.25
const RESULT_DIM_ALPHA := 0.55

const SCORE_TOP := UiDesign.SP_4                          # 16
const GRACE_TOP := UiDesign.SP_9 + UiDesign.SP_2          # 72:记分条(高 52)之下
const PLATE_PAD := Vector2i(UiDesign.MARGIN, UiDesign.SP_2)         # 记分/宽限/延迟底板 24 / 8
const PING_PAD_ROYALE := Vector2i(14, 6)
const RESULT_BTN_SIZE := Vector2(UiDesign.SP_10 * 5 + UiDesign.SP_5 - UiDesign.SP_1,
		UiDesign.SP_10 + UiDesign.SP_2)                             # 420 × 88

var mode := WorldSpec.DUEL
var _broadcast := Broadcast.new()
var _score: Label
var _grace_label: Label
var _grace_wrap: PanelContainer
var _ping: Label
var _board_bg: ColorRect
var _board := VBoxContainer.new()
var _timer: Label
var _status_banner: StatusBanner
var _result := Control.new()
var _result_panel: PanelContainer
var _result_title: Label
var _result_subtitle: Label
var _sections: HBoxContainer

var _shown_round: Dictionary
var _rows: Array[Label] = []
var _return_button: Button


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 130
	var royale := mode == WorldSpec.ROYALE
	_build_board()
	add_child(_broadcast)
	_broadcast.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_score(royale)
	_build_grace()
	_build_ping(royale)
	_build_status()
	_build_result()
	_board_bg.visible = royale
	_board.visible = royale


# ── 构造 ───────────────────────────────────────────────────────────────────

static func _plate(content: Control, pad_x: int, pad_y: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiDesign.hud_plate(panel, pad_x, pad_y)
	panel.add_child(content)
	return panel


func _build_board() -> void:
	_board_bg = ColorRect.new()
	_board_bg.name = "BoardBg"
	_board_bg.color = UiDesign.C_BG
	_board_bg.modulate.a = BOARD_DIM_ALPHA
	_board_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board_bg.anchor_left = 1.0
	_board_bg.anchor_right = 1.0
	_board_bg.offset_left = -(BOARD_W + UiDesign.SP_4)
	_board_bg.offset_right = -UiDesign.SP_4
	_board_bg.offset_top = BOARD_TOP
	_board_bg.offset_bottom = BOARD_TOP + BOARD_BG_EXTRA
	_board_bg.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(_board_bg)

	_board.name = "BoardBox"
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board.add_theme_constant_override("separation", UiDesign.SP_1)
	_board.anchor_left = 1.0
	_board.anchor_right = 1.0
	_board.offset_left = -(BOARD_W - UiDesign.SP_1)
	_board.offset_right = -UiDesign.SP_1
	_board.offset_top = BOARD_TOP + BOARD_INSET
	_board.offset_bottom = BOARD_TOP + BOARD_INSET
	_board.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_board.grow_vertical = Control.GROW_DIRECTION_END
	add_child(_board)

	_board.add_child(UiDesign.label("—— 击杀排行榜 ——", UiDesign.T_H2, UiDesign.C_ACCENT))
	_timer = UiDesign.label("", UiDesign.T_H2, UiDesign.C_TEXT)
	_board.add_child(_timer)


func _build_score(royale: bool) -> void:
	_score = UiDesign.label("", UiDesign.T_H2, UiDesign.C_TEXT)
	_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var score_wrap := _plate(_score, PLATE_PAD.x, PLATE_PAD.y)
	score_wrap.name = "ScoreWrap"
	score_wrap.anchor_left = 0.5
	score_wrap.anchor_right = 0.5
	score_wrap.offset_top = SCORE_TOP
	score_wrap.offset_bottom = SCORE_TOP
	score_wrap.grow_horizontal = Control.GROW_DIRECTION_BOTH
	score_wrap.grow_vertical = Control.GROW_DIRECTION_END
	add_child(score_wrap)
	score_wrap.visible = not royale


func _build_grace() -> void:
	_grace_label = UiDesign.label("", UiDesign.T_H2, UiDesign.C_GRACE)
	_grace_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_grace_wrap = _plate(_grace_label, PLATE_PAD.x, PLATE_PAD.y)
	_grace_wrap.name = "GraceWrap"
	_grace_wrap.anchor_left = 0.5
	_grace_wrap.anchor_right = 0.5
	_grace_wrap.offset_top = GRACE_TOP
	_grace_wrap.offset_bottom = GRACE_TOP
	_grace_wrap.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_grace_wrap.grow_vertical = Control.GROW_DIRECTION_END
	_grace_wrap.hide()
	add_child(_grace_wrap)


func _build_ping(royale: bool) -> void:
	_ping = UiDesign.label("--ms", UiDesign.T_H2, UiDesign.C_TEXT_DIM)
	_ping.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var pad := PING_PAD_ROYALE if royale else PLATE_PAD
	var ping_wrap := _plate(_ping, pad.x, pad.y)
	ping_wrap.name = "PingWrap"
	ping_wrap.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ping_wrap.offset_left = -UiDesign.MARGIN
	ping_wrap.offset_top = -UiDesign.MARGIN
	ping_wrap.offset_right = -UiDesign.MARGIN
	ping_wrap.offset_bottom = -UiDesign.MARGIN
	ping_wrap.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ping_wrap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(ping_wrap)


func _build_status() -> void:
	# 状态横幅位于常规 HUD 上方、结算层下方。
	_status_banner = STATUS_BANNER_SCENE.instantiate() as StatusBanner
	add_child(_status_banner)


func _build_result() -> void:
	var layer_node := CanvasLayer.new()
	layer_node.name = "ResultLayer"
	layer_node.layer = 150
	add_child(layer_node)
	_result.name = "Result"
	_result.hide()
	_result.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer_node.add_child(_result)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = UiDesign.C_BG
	dim.modulate.a = RESULT_DIM_ALPHA
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result.add_child(dim)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result.add_child(center)

	_result_panel = PanelContainer.new()
	_result_panel.name = "Panel"
	center.add_child(_result_panel)
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiDesign.SP_5)
	UiDesign.skin_menu_panel(_result_panel).add_child(body)

	_result_title = UiDesign.ui_label("", "h1")
	_result_title.name = "Title"
	_result_subtitle = UiDesign.ui_label("", "dim")
	_result_subtitle.name = "Subtitle"
	for label: Label in [_result_title, _result_subtitle]:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		body.add_child(label)
	_sections = HBoxContainer.new()
	_sections.name = "Sections"
	_sections.add_theme_constant_override("separation", UiDesign.SP_8)
	_sections.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_child(_sections)
	_return_button = UiDesign.ui_button("返回房间", UiDesign.T_H2, RESULT_BTN_SIZE, "gold")
	_return_button.name = "Back"
	_return_button.pressed.connect(_request_return)
	body.add_child(_return_button)


# ── 运行期 ─────────────────────────────────────────────────────────────────

func display(state: Dictionary) -> void:
	var round: Dictionary = state.round
	if not is_same(_shown_round, round):
		_score.text = round.score
		_show_board(round.board)
		if not round.title.is_empty() and round != _shown_round:
			_show_result(round)
		_shown_round = round
	_result.visible = not round.title.is_empty()
	_broadcast.display(state.title if not _result.visible else "", round.banner[1], state.punch)
	_timer.text = state.timer
	_grace_label.text = state.grace
	_grace_wrap.visible = not state.grace.is_empty()

func set_ping(ms: int) -> void:
	_ping.text = "%dms" % ms
	_ping.add_theme_color_override("font_color", UiDesign.ping_color(ms))

func set_status(message: String) -> void:
	_status_banner.set_text(message)

func show_connected(ms: int) -> void:
	set_ping(ms)
	set_status("")
	_return_button.disabled = false
	_return_button.text = "返回房间"

func _show_result(round: Dictionary) -> void:
	for child in _sections.get_children():
		_sections.remove_child(child)
		child.queue_free()
	_result_title.text = round.title
	_result_subtitle.text = round.subtitle
	for section in round.sections:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", UiDesign.SP_3)
		box.add_child(_section_strip(section))
		var grid := GridContainer.new()
		grid.columns = section.headers.size()
		grid.add_theme_constant_override("h_separation", UiDesign.SP_5)
		grid.add_theme_constant_override("v_separation", UiDesign.SP_2)
		_add_result_row(grid, section.headers, UiDesign.C_TEXT_DIM)
		for row in section.rows:
			_add_result_row(grid, row[1], UiDesign.C_TEXT if row[0] else UiDesign.C_TEXT_DIM)
		box.add_child(grid)
		_sections.add_child(box)


# 结算标题的队伍颜色来自 RoundProjection。
static func _section_strip(section: Dictionary) -> PanelContainer:
	return UiDesign.header_strip(section.title, UiDesign.T_H2, true, section.color)


static func _add_result_row(grid: GridContainer, values: Array, color: Color) -> void:
	for value in values:
		grid.add_child(UiDesign.label(str(value), UiDesign.T_H2, color))


func _request_return() -> void:
	if _return_button.disabled: return
	_return_button.disabled = true
	_return_button.text = "等待其他玩家返回房间…"
	return_requested.emit()


func _unhandled_input(event: InputEvent) -> void:
	if _result.visible and event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_request_return()


func _show_board(rows: Array) -> void:
	var resized := _rows.size() != rows.size()
	while _rows.size() > rows.size():
		var row: Label = _rows.pop_back()
		_board.remove_child(row)
		row.queue_free()
	while _rows.size() < rows.size():
		var row := UiDesign.label("", UiDesign.T_H2, UiDesign.C_TEXT)
		row.custom_minimum_size.x = BOARD_ROW_WIDTH
		row.size_flags_horizontal = Control.SIZE_FILL
		row.clip_text = true
		_board.add_child(row)
		_rows.append(row)
	if resized:
		_board_bg.offset_bottom = _board_bg.offset_top + _board.get_combined_minimum_size().y + BOARD_BG_EXTRA
	for i in rows.size():
		_rows[i].text = rows[i][0]
		_rows[i].add_theme_color_override("font_color", rows[i][1])
