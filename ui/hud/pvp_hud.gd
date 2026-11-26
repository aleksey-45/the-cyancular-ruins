class_name PvpHud
extends CanvasLayer

# 联机对局 HUD 从 Round 读取比分、回合和结算信息。开局倒计时由 Broadcast 推进。

signal leave_requested

const STATUS_BANNER_SCENE := preload("res://ui/hud/status_banner.tscn")

const Mode := MatchFrame.Mode

const BOARD_W := 720.0                                   # 排行榜面板宽
const BOARD_TOP := UiDesign.SP_9 + UiDesign.SP_6         # 96:离屏幕上沿
const BOARD_INSET := 6.0                                 # 内容列相对底板的内缩(像素档)
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
var _timer: Label
var _status_banner: StatusBanner
var _result := Control.new()
var _result_panel: PanelContainer
var _result_title: Label
var _result_subtitle: Label
var _sections: HBoxContainer

var _grace_left := -1.0
var _rows: Array[Label] = []
var _remaining := -1.0
var _leaving := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 130
	var royale := mode == Mode.ROYALE
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
	match mode:
		Mode.ROYALE: _broadcast.set_broadcast(true, "大乱斗", "等待开局…")
		Mode.TEAM: _broadcast.set_broadcast(true, "等待玩家加载", "")
		_: _broadcast.set_broadcast(true, "对战开始", "第 1 局")


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

	_result_panel = UiDesign.menu_panel()
	_result_panel.name = "Panel"
	center.add_child(_result_panel)
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiDesign.SP_5)
	(_result_panel.get_node("Body") as Container).add_child(body)

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
	var back := UiDesign.ui_button("返回主菜单", UiDesign.T_H2, RESULT_BTN_SIZE, "gold")
	back.name = "Back"
	back.pressed.connect(_request_leave)
	body.add_child(back)


# ── 运行期 ─────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _remaining >= 0.0:
		_update_timer(_remaining - delta)
	if _grace_left >= 0.0:
		_update_grace(maxf(0.0, _grace_left - delta))


func set_status(message: String) -> void:
	if _status_banner != null:
		_status_banner.set_text(message)


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
	_result.show()


# 结算标题的队伍颜色来自 RoundProjection。
static func _section_strip(section: Section) -> PanelContainer:
	var strip := UiDesign.header_strip(section.title, UiDesign.T_H2, true)
	var title := strip.get_child(0) as Label
	if title != null:
		title.add_theme_color_override("font_color", section.color)
	return strip


static func _add_result_row(grid: GridContainer, values: Array, color: Color) -> void:
	for value in values:
		grid.add_child(UiDesign.label(str(value), UiDesign.T_H2, color))


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
