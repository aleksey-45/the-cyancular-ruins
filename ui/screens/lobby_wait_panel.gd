class_name LobbyWaitPanel
extends PanelContainer

# 等待室按传入的房间状态显示成员列表和操作。点击房间标题可复制房间号。

signal copy_requested
signal team_requested(side: int)
signal start_requested
signal exit_requested
signal hue_changed(value: float)

const PANEL_PAD := Vector2(UiDesign.SP_9, UiDesign.SP_6)
const PANEL_MIN_W := UiDesign.SP_10 * 10                # 800:等待室最小宽
const TITLE_MIN_H := UiDesign.SP_9                      # 64
const ROSTER_GAP := UiDesign.SP_3
const TEAM_MIN := Vector2(UiDesign.SP_10 * 3, UiDesign.SP_9 - UiDesign.SP_2)
const START_MIN := Vector2(UiDesign.SP_10 * 5 + UiDesign.SP_7, UiDesign.SP_9)
const EXIT_MIN := Vector2(START_MIN.x, UiDesign.SP_9 - UiDesign.SP_2)
const HUE_SLIDER_MIN_W := UiDesign.SP_10 * 4            # 320
const HUE_CHIP := Vector2(UiDesign.SP_8, UiDesign.SP_5 + UiDesign.SP_1)
# 预览色只随玩家选择的色相改变。
const HUE_PREVIEW_SAT := 0.75
const HUE_PREVIEW_VAL := 1.0

var _initial_hue: float
var _title: Button
var _roster: VBoxContainer
var _count: Label
var _hue: HBoxContainer
var _start: Button
var _teams: Array[Button] = []


func _init(initial_hue: float) -> void:
	_initial_hue = initial_hue


func _ready() -> void:
	UiDesign.skin_menu_panel(self, PANEL_PAD)
	var body := get_node("Body") as Container
	var page := VBoxContainer.new()
	page.name = "Page"
	page.custom_minimum_size.x = PANEL_MIN_W
	page.add_theme_constant_override("separation", UiDesign.SP_5)
	body.add_child(page)

	_build_title(page)
	_build_roster(page)
	_build_team_buttons(page)
	_build_hue_row(page)
	_build_actions(page)


func _build_title(parent: Control) -> void:
	_title = UiDesign.ui_button("", UiDesign.T_H2, Vector2(0, TITLE_MIN_H), "gold")
	_title.name = "RoomCode"
	_title.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_title.tooltip_text = "点击复制房间号"
	_title.pressed.connect(copy_requested.emit)
	parent.add_child(_title)


func _build_roster(parent: Control) -> void:
	_roster = VBoxContainer.new()
	_roster.name = "Roster"
	_roster.add_theme_constant_override("separation", ROSTER_GAP)
	parent.add_child(_roster)
	_count = UiDesign.ui_label("", "body")
	_count.name = "Count"
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(_count)


func _build_team_buttons(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.name = "TeamButtons"
	row.add_theme_constant_override("separation", UiDesign.SP_5)
	parent.add_child(row)
	for side in [1, 2]:
		var text := "加入 A 队" if side == 1 else "加入 B 队"
		var button := UiDesign.ui_button(text, UiDesign.T_H2, TEAM_MIN, "primary")
		button.name = "TeamButton%d" % side
		button.pressed.connect(team_requested.emit.bind(side))
		row.add_child(button)
		_teams.append(button)


func _build_hue_row(parent: Control) -> void:
	_hue = HBoxContainer.new()
	_hue.name = "HueRow"
	_hue.add_theme_constant_override("separation", ROSTER_GAP)
	parent.add_child(_hue)
	var label := UiDesign.ui_label("自己角色颜色:", "body")
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hue.add_child(label)
	var slider := HSlider.new()
	slider.name = "HueSlider"
	slider.max_value = 360.0
	slider.step = 5.0
	slider.set_value_no_signal(_initial_hue)
	slider.custom_minimum_size = Vector2(HUE_SLIDER_MIN_W, 0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hue.add_child(slider)
	var chip := ColorRect.new()
	chip.name = "HueChip"
	chip.mouse_filter = Control.MOUSE_FILTER_STOP
	chip.custom_minimum_size = HUE_CHIP
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.color = _preview_color(slider.value)
	_hue.add_child(chip)
	slider.value_changed.connect(hue_changed.emit)
	slider.value_changed.connect(func(v: float) -> void: chip.color = _preview_color(v))


func _build_actions(parent: Control) -> void:
	_start = UiDesign.ui_button("开始游戏", UiDesign.T_H2, START_MIN, "gold")
	_start.name = "StartBtn"
	_start.pressed.connect(start_requested.emit)
	parent.add_child(_start)
	var exit := UiDesign.ui_button("退出房间", UiDesign.T_H2, EXIT_MIN, "quiet")
	exit.name = "ExitBtn"
	exit.pressed.connect(exit_requested.emit)
	parent.add_child(exit)


func present(room: Dictionary) -> void:
	_title.text = room["title"]
	_count.text = room["count"]
	for child in _roster.get_children():
		_roster.remove_child(child)
		child.queue_free()
	for row: Array in room["roster"]:
		# 成员文字和状态颜色由 LobbyProjection 提供。
		_roster.add_child(UiDesign.label(str(row[0]), UiDesign.T_H2, row[1]))
	_hue.visible = not room["team"]
	for i in _teams.size():
		_teams[i].visible = room["team"] and room["my_team"] != i + 1
	_start.visible = room["can_start"]


static func _preview_color(hue_deg: float) -> Color:
	return Color.from_hsv(fposmod(hue_deg, 360.0) / 360.0, HUE_PREVIEW_SAT, HUE_PREVIEW_VAL)
