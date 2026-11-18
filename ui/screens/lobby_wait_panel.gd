class_name LobbyWaitPanel
extends PanelContainer

signal copy_requested
signal team_requested(side: int)
signal start_requested
signal exit_requested
signal hue_changed(value: float)

var _initial_hue: float
var _title: Button
var _roster: BoxContainer
var _count: Label
var _hue: BoxContainer
var _start: Button
var _teams: Array[Button] = []

func _init(initial_hue: float) -> void:
	_initial_hue = initial_hue

func _ready() -> void:
	var body := VBoxContainer.new()
	body.custom_minimum_size.x = 800
	body.add_theme_constant_override("separation", 20)
	UiFactory.fill_frame(self, body, Vector2(-1, -1))
	_title = UiFactory.action(body, "", Vector2(0, 64), &"BtnGold", copy_requested.emit)
	_title.mouse_default_cursor_shape = CURSOR_POINTING_HAND
	_title.tooltip_text = "点击复制房间号"
	_roster = UiFactory.box(body, 12, true)
	_count = UiFactory.label("", 32, UiFactory.C_TEXT)
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_count)
	var buttons := UiFactory.box(body, 20, false)
	for side in [1, 2]:
		var text := "加入 A 队" if side == 1 else "加入 B 队"
		_teams.append(UiFactory.action(buttons, text, Vector2(240, 56), &"BtnPrimary", team_requested.emit.bind(side)))

	_hue = UiFactory.box(body, 12, false)
	_hue.add_child(UiFactory.label("自己角色颜色:", 32))
	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(320, 30)
	slider.max_value = 360.0
	slider.step = 5.0
	slider.set_value_no_signal(_initial_hue)
	_hue.add_child(slider)
	var chip := UiFactory.shade(UiFactory.hue_preview_color(slider.value), true)
	chip.custom_minimum_size = Vector2(46, 30)
	_hue.add_child(chip)
	slider.value_changed.connect(hue_changed.emit)
	slider.value_changed.connect(func(v: float) -> void: chip.color = UiFactory.hue_preview_color(v))
	_start = UiFactory.action(body, "开始游戏", Vector2(440, 64), &"BtnGold", start_requested.emit)
	UiFactory.action(body, "退出房间", Vector2(440, 56), &"BtnQuiet", exit_requested.emit)

func present(room: Dictionary) -> void:
	_title.text = room["title"]
	_count.text = room["count"]
	for child in _roster.get_children():
		_roster.remove_child(child)
		child.queue_free()
	for row: Array in room["roster"]:
		_roster.add_child(UiFactory.label(row[0], 32, row[1]))
	_hue.visible = not room["team"]
	for i in _teams.size():
		_teams[i].visible = room["team"] and room["my_team"] != i + 1
	_start.visible = room["can_start"]
