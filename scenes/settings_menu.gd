extends Control

const ACTION_NAMES := {
	"left": "左移", "right": "右移", "up": "跳跃/上爬", "down": "下蹲/下落",
	"charge": "冲刺", "attack": "开火", "R": "换弹/重开", "F": "拾取", "Q": "丢弃(长按)",
	"rewind": "时间回溯", "haste": "时间加速",
}
const BATTLE_DISPLAY := [
	[&"pvp_show_trajectories", "显示武器弹丸尾迹"],
	[&"pvp_show_enemy_hp", "显示其他玩家血量条"],
	[&"pvp_show_minimap", "打开小地图"],
	[&"pvp_minimap_show_enemy", "小地图显示其他玩家"],
]

var _capturing_action := ""
var _bind_buttons: Dictionary = {}
var _resolution := OptionButton.new()

func _ready() -> void:
	var page := UiFactory.page(self, "—— 设置 ——", 16, true)
	var columns := UiFactory.columns(page)
	var options := VBoxContainer.new()
	options.add_theme_constant_override("separation", 24)
	UiFactory.column(columns, options)
	_heading(options, "音量")
	for spec in [[&"master_volume", "主音量"], [&"sfx_volume", "音效"]]:
		var slider := HSlider.new()
		slider.custom_minimum_size = Vector2(360, 28)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.max_value = 1.0
		slider.step = 0.05
		_row(options, spec[1], slider)
		slider.set_value_no_signal(Settings.get(spec[0]))
		slider.value_changed.connect(Settings.store.bind(spec[0]))
	_heading(options, "显示")
	_setup_resolution(options)
	_heading(options, "通用")
	_toggle(options, "鼠标滚轮切枪", &"wheel_switch")
	_heading(options, "战斗显示")
	for spec in BATTLE_DISPLAY:
		_toggle(options, spec[1], spec[0])

	var keys := VBoxContainer.new()
	keys.add_theme_constant_override("separation", 24)
	UiFactory.column(columns, keys)
	_heading(keys, "按键映射(点击后按新键;Esc 取消)")
	_fill_bind_grid(keys)

	var actions := UiFactory.box(page, 24, false)
	UiFactory.action(actions, "恢复默认键位", Vector2(360, 72), &"", _reset)
	UiFactory.action(actions, "返回(Esc)", Vector2(280, 72), &"", _go_back)

func _setup_resolution(options: VBoxContainer) -> void:
	_resolution.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_resolution.tooltip_text = "窗口会按屏幕可用区域等比例缩小；游戏视野不变。"
	_row(options, "窗口分辨率", _resolution)
	for resolution in Settings.DISPLAY_RESOLUTIONS:
		_resolution.add_item("%d × %d" % [resolution.x, resolution.y])
	_resolution.select(Settings.DISPLAY_RESOLUTIONS.find(Settings.display_resolution))
	_resolution.disabled = Settings.display_fullscreen
	_resolution.item_selected.connect(func(index: int) -> void:
		Settings.display_resolution = Settings.DISPLAY_RESOLUTIONS[index]
		Settings.apply_display()
		Settings.save())
	var fullscreen := _toggle(options, "全屏", &"display_fullscreen")
	fullscreen.toggled.connect(func(on: bool) -> void:
		_resolution.disabled = on
		Settings.apply_display())

static func _heading(parent: VBoxContainer, title: String) -> void:
	parent.add_child(UiFactory.header_strip(title))

static func _row(parent: VBoxContainer, text: String, control: Control) -> void:
	var row := UiFactory.box(parent, 16, false)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 384
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	row.add_child(control)

func _toggle(parent: VBoxContainer, text: String, key: StringName) -> CheckButton:
	var widget := CheckButton.new()
	widget.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_row(parent, text, widget)
	widget.set_pressed_no_signal(Settings.get(key))
	widget.toggled.connect(Settings.store.bind(key))
	widget.toggled.connect(func(_on: bool) -> void: Sfx.play("switch"))
	return widget

func _fill_bind_grid(parent: VBoxContainer) -> void:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 8)
	parent.add_child(grid)
	for action in Settings.REMAPPABLE_ACTIONS:
		var label := Label.new()
		label.text = ACTION_NAMES.get(action, action)
		label.add_theme_color_override("font_color", Color.WHITE)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.custom_minimum_size = Vector2(200, 0)
		grid.add_child(label)
		var button := UiFactory.menu_button(Settings.get_binding_names(action), Vector2(220, 72), &"BtnBinding")
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if action == "R":
			button.tooltip_text = "存活时换弹。单人模式倒地后倒带并重开关卡。"
		button.pressed.connect(_begin_capture.bind(action))
		grid.add_child(button)
		_bind_buttons[action] = button

func _reset() -> void:
	Sfx.play("ui")
	Settings.reset_bindings()
	for action in _bind_buttons:
		_refresh_bind_label(action)

func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _capturing_action != "":
			_cancel_capture()
		else:
			_go_back()


func _begin_capture(action: String) -> void:
	Sfx.play("ui")
	_cancel_capture()
	_capturing_action = action
	_bind_buttons[action].text = "按任意键…"


func _cancel_capture() -> void:
	if _capturing_action == "":
		return
	var action := _capturing_action
	_capturing_action = ""
	_refresh_bind_label(action)


func _input(event: InputEvent) -> void:
	if _capturing_action == "":
		return
	var ev: InputEvent = null
	if event is InputEventKey and event.pressed:
		# Shift、Ctrl 和 Alt 单独按下时不会绑定。Esc 结束本次按键设置。
		if event.physical_keycode in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_ESCAPE]:
			if event.physical_keycode == KEY_ESCAPE:
				_cancel_capture()
				get_viewport().set_input_as_handled()
			return
		ev = event
	elif event is InputEventMouseButton and event.pressed:
		ev = event
	if ev == null:
		return
	Settings.set_binding(_capturing_action, ev)
	Sfx.play("switch")
	_cancel_capture()
	get_viewport().set_input_as_handled()


func _refresh_bind_label(action: String) -> void:
	_bind_buttons[action].text = Settings.get_binding_names(action)
