extends Control
# 设置菜单(实验分支 KikuchiHeinr):键鼠重映射 / 音量 / 滚轮切枪 / 老版UI 开关。
# 全部改动即时生效并经 Settings 持久化(user://settings.cfg)。像素风格,Esc 返回。

const PIXEL_FONT := "res://assets/fonts/less_perfect_dos_vga.ttf"
const ACTION_NAMES := {
	"left": "左移", "right": "右移", "up": "跳跃/上爬", "down": "下蹲/下落",
	"charge": "冲刺", "attack": "开火", "R": "重开(单机)",
}

var _capturing_action := ""      # 正在等待捕获新键位的动作(""=不在捕获态)
var _capture_btn: Button = null
var _bind_buttons: Dictionary = {}   # action -> Button


func _ready() -> void:
	# 不透明深色底:进过单机后全局清屏色是浅蓝,白字会看不清(Esc 仍在 _unhandled_input 处理)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var vb := VBoxContainer.new()
	vb.position = Vector2(80, 50)
	vb.custom_minimum_size = Vector2(900, 0)
	vb.add_theme_constant_override("separation", 16)
	add_child(vb)

	var title := _label("—— 设 置 ——", 56, Color(0.55, 0.95, 1.0))
	vb.add_child(title)

	# ── 音量 ──
	vb.add_child(_label("音量", 30))
	vb.add_child(_slider_row("主音量", Settings.master_volume, func(v: float) -> void:
		Settings.master_volume = v
		Settings.save()))
	vb.add_child(_slider_row("音效", Settings.sfx_volume, func(v: float) -> void:
		Settings.sfx_volume = v
		Settings.save()))

	# ── 通用开关 ──
	vb.add_child(_check("鼠标滚轮切枪", Settings.wheel_switch, func(on: bool) -> void:
		Settings.wheel_switch = on
		Settings.save()))
	vb.add_child(_check("换弹装填(实验性,仅单机)", Settings.reload_enabled, func(on: bool) -> void:
		Settings.reload_enabled = on
		Settings.save()))
	vb.add_child(_check("使用老版主菜单 UI", Settings.old_ui, func(on: bool) -> void:
		Settings.old_ui = on
		Settings.save()))

	# ── 键位 ──
	vb.add_child(_label("按键映射(点击后按新键;Esc 取消)", 30))
	var grid := GridContainer.new()
	grid.columns = 4   # (名称,键位) 成对一行放两组,避免键位串行
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 8)
	vb.add_child(grid)
	for action in Settings.REMAPPABLE_ACTIONS:
		var name_l := _label(ACTION_NAMES.get(action, action), 24)
		name_l.custom_minimum_size = Vector2(200, 0)
		grid.add_child(name_l)
		var bind_btn := Button.new()
		bind_btn.custom_minimum_size = Vector2(200, 40)
		_style(bind_btn, 24)
		bind_btn.pressed.connect(func() -> void: _begin_capture(action, bind_btn))
		grid.add_child(bind_btn)
		_bind_buttons[action] = bind_btn
		_refresh_bind_label(action)

	var reset := _button("恢复默认键位", 24)
	reset.pressed.connect(func() -> void:
		Settings.reset_bindings()
		for a in _bind_buttons:
			_refresh_bind_label(a))
	vb.add_child(reset)

	# ── 返回 ──
	var back := _button("返 回(Esc)", 30)
	back.pressed.connect(_go_back)
	vb.add_child(back)


func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file("res://Scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _capturing_action != "":
			_cancel_capture()
		else:
			_go_back()
		get_viewport().set_input_as_handled()


# ── 键位捕获 ──
func _begin_capture(action: String, btn: Button) -> void:
	Sfx.play("ui")
	_cancel_capture()
	_capturing_action = action
	_capture_btn = btn
	btn.text = "按任意键…"


func _cancel_capture() -> void:
	if _capturing_action == "":
		return
	var action := _capturing_action
	_capturing_action = ""
	_capture_btn = null
	_refresh_bind_label(action)


func _input(event: InputEvent) -> void:
	if _capturing_action == "":
		return
	var ev: InputEvent = null
	if event is InputEventKey and event.pressed:
		# 修饰键单独按下不作为绑定(留给组合键的未来扩展)
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
	_capturing_action = ""
	_refresh_bind_label_for(_capture_btn)
	_capture_btn = null
	get_viewport().set_input_as_handled()


func _refresh_bind_label(action: String) -> void:
	if action != "" and _bind_buttons.has(action):
		_refresh_bind_label_for(_bind_buttons[action])


func _refresh_bind_label_for(btn: Button) -> void:
	if btn == null:
		return
	var action := Settings.REMAPPABLE_ACTIONS.filter(func(a: String) -> bool:
		return _bind_buttons.get(a) == btn)
	if action.is_empty():
		return
	btn.text = Settings.get_binding_names(action[0])


func _event_name(ev: InputEvent) -> String:
	if ev is InputEventKey:
		return OS.get_keycode_string((ev as InputEventKey).physical_keycode)
	if ev is InputEventMouseButton:
		match (ev as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT: return "鼠标左键"
			MOUSE_BUTTON_RIGHT: return "鼠标右键"
			MOUSE_BUTTON_MIDDLE: return "鼠标中键"
			MOUSE_BUTTON_WHEEL_UP: return "滚轮上"
			MOUSE_BUTTON_WHEEL_DOWN: return "滚轮下"
			_: return "鼠标键 %d" % (ev as InputEventMouseButton).button_index
	return "?"


# ── 控件工厂 ──
func _style(c: Control, font_size: int) -> void:
	c.add_theme_font_size_override("font_size", font_size)
	var pf: FontFile = load(PIXEL_FONT)
	if pf != null:
		c.add_theme_font_override("font", pf)


func _label(text: String, size: int, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	_style(l, size)
	return l


func _button(text: String, size: int) -> Button:
	var b := Button.new()
	b.text = text
	_style(b, size)
	b.custom_minimum_size = Vector2(280, 48)
	b.pressed.connect(func() -> void: Sfx.play("ui"))
	return b


func _check(text: String, initial: bool, on_toggle: Callable) -> CheckButton:
	var cb := CheckButton.new()
	cb.text = text
	_style(cb, 26)
	cb.button_pressed = initial
	cb.toggled.connect(func(on: bool) -> void:
		Sfx.play("switch")
		on_toggle.call(on))
	return cb


func _slider_row(text: String, initial: float, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var l := _label(text, 26)
	l.custom_minimum_size = Vector2(160, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = initial
	s.custom_minimum_size = Vector2(360, 28)
	s.value_changed.connect(func(v: float) -> void: on_change.call(v))
	row.add_child(s)
	return row
