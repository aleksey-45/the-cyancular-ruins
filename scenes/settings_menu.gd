extends Control
# 设置菜单:键鼠重映射 / 音量 / 滚轮切枪。
# 全部改动即时生效并经 Settings 持久化(user://settings.cfg)。像素风格,Esc 返回。
# 场景是裸 Control,UI 全在代码里建;控件一律走 UiFactory(像素字体与字号规范的单一来源,
# 字号必须是 16 的倍数)。

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

	vb.add_child(UiFactory.label("—— 设 置 ——", 48, UiFactory.C_ACCENT))

	# ── 音量 ──
	vb.add_child(_section("音量"))
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

	# ── 键位 ──
	vb.add_child(_section("按键映射(点击后按新键;Esc 取消)"))
	var grid := GridContainer.new()
	grid.columns = 4   # (名称,键位) 成对一行放两组,避免键位串行
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 8)
	vb.add_child(grid)
	for action in Settings.REMAPPABLE_ACTIONS:
		var name_l := UiFactory.label(ACTION_NAMES.get(action, action), 32)
		name_l.custom_minimum_size = Vector2(200, 0)
		grid.add_child(name_l)
		# 键位按钮是网格单元(不是主菜单按钮列),尺寸经 min_size 传工厂:200×40
		var bind_btn := UiFactory.button("", 32, Vector2(200, 40))
		bind_btn.pressed.connect(func() -> void: _begin_capture(action, bind_btn))
		grid.add_child(bind_btn)
		_bind_buttons[action] = bind_btn
		_refresh_bind_label(action)

	# ── 底部动作 ──
	# 并排放在一行里:VBox 会把子节点横向拉到列宽(900),两个 280 宽的键各自
	# 变成一条 900 宽的横条、文字居中后两侧全是死区(2026-09-13 视觉评析)。
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 24)
	var reset := UiFactory.button("恢复默认键位", 32, Vector2(320, 48))
	reset.pressed.connect(func() -> void:
		Sfx.play("ui")   # 点击音由各 handler 自己出(UiFactory.button 不代挂,防同帧双响)
		Settings.reset_bindings()
		for a in _bind_buttons:
			_refresh_bind_label(a))
	actions.add_child(reset)

	var back := UiFactory.button("返 回(Esc)", 32, Vector2(240, 48))
	back.pressed.connect(_go_back)
	actions.add_child(back)
	vb.add_child(actions)


# 分组标题:强调青,上方多留一档空 —— 和条目文字拉开层级。
# (原先「音量」与「主音量」同字号同颜色,读不出哪个是标题。)
func _section(text: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 18)
	box.add_child(gap)
	box.add_child(UiFactory.label(text, 32, UiFactory.C_ACCENT))
	return box


# 本菜单是纯 UI(无世界、无大物理),普通切场景只会销毁一棵 Control 树;
# 反方向(游戏世界 → 菜单)才需要挂起式切换,见 Level0.safe_change_scene。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


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
	# 键位 API 的既有语义(设计如此,非缺陷):set_binding 先 action_erase_events 再只写这一个
	# → **用户主动重绑 = 该动作从此按单键**(默认多键如 up=W+Space 只留新键);
	# 而显示(get_binding_names)与持久化(save/load_settings)都遍历全部事件,故存档往返**不丢键**。
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


# ── 控件工厂:字体/字号/点击音纪律只有 UiFactory 一份实现 ──
# (CheckButton / HSlider 没有现成的工厂方法 → 走 UiFactory.style_control 套字体与字号。)
# 开关行 = 定宽标签列 + 紧邻的开关。
# 原先返回的是一个裸 CheckButton 直接塞进 900 宽的 VBox:Godot 把它拉伸到 900,
# 开关图标被推到最右 —— 标签在 x=80、开关在 x≈980,中间 800px 死区让两者读成
# 互不相干的两个元素(2026-09-13 视觉评析)。定宽标签列同时让多行的开关纵向对齐。
const CHECK_LABEL_W := 320.0

func _check(text: String, initial: bool, on_toggle: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var lab := UiFactory.label(text, 32, UiFactory.C_TEXT)
	lab.custom_minimum_size = Vector2(CHECK_LABEL_W, 0)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)
	var cb := CheckButton.new()
	cb.button_pressed = initial
	cb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	UiFactory.style_check(cb, 32)
	cb.toggled.connect(func(on: bool) -> void:
		Sfx.play("switch")
		on_toggle.call(on))
	row.add_child(cb)
	return row


func _slider_row(text: String, initial: float, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	# 标签列宽与开关行共用 CHECK_LABEL_W → 滑条与开关纵向对齐成一列。
	var l := UiFactory.label(text, 32, UiFactory.C_TEXT)
	l.custom_minimum_size = Vector2(CHECK_LABEL_W, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = initial
	# 铺满剩余宽度:原先固定 360 宽,右侧 450px 空着,拖拽命中区也偏小。
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(360, 28)
	UiFactory.style_slider(s)
	s.value_changed.connect(func(v: float) -> void: on_change.call(v))
	row.add_child(s)
	return row
