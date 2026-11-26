extends Control

# 设置页的两栏布局由容器管理。表单和键位列表在运行时创建，并与 Settings 同步。

const ACTION_NAMES := {
	"left": "左移", "right": "右移", "up": "跳跃/上爬", "down": "下蹲/下落",
	"attack": "开火", "R": "换弹/重开", "F": "拾取", "Q": "丢弃(长按)",
	"rewind": "时间回溯", "haste": "时间加速",
}
const BATTLE_DISPLAY := [
	[&"pvp_show_trajectories", "显示武器弹丸尾迹"],
	[&"pvp_show_enemy_hp", "显示其他玩家血量条"],
	[&"pvp_show_minimap", "打开小地图"],
	[&"pvp_minimap_show_enemy", "小地图显示其他玩家"],
]

const FORM_LABEL_W := UiDesign.T_H2 * 12   # 表单标签列为 12 个全角字预留宽度。
const BIND_NAME_W := UiDesign.T_H2 * 6     # 键位名称列为 6 个全角字预留宽度。
const ROW_MIN_H := UiDesign.SP_8

const BACK_SCENE := "res://scenes/main_menu.tscn"

var _capturing_action := ""
var _bind_buttons: Dictionary = {}

var _master: HSlider = null
var _sfx: HSlider = null
var _wheel: CheckButton = null
var _traj: CheckButton = null
var _enemy_hp: CheckButton = null
var _minimap: CheckButton = null
var _minimap_enemy: CheckButton = null
var _resolution: OptionButton = null
var _fullscreen: CheckButton = null
var _bind_grid: VBoxContainer = null
var _reset_btn: Button = null
var _back_btn: Button = null


func _ready() -> void:
	_build_page()
	_wire_settings()


func _build_page() -> void:
	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.color = UiDesign.C_BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var page := UiKit.page(self)
	page.name = "Page"

	var header := UiDesign.header_strip("—— 设 置 ——", UiDesign.T_H1, true)
	header.name = "Header"
	page.add_child(header)

	# 内容区高度不足时允许纵向滚动。
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(scroll)

	var cols := HBoxContainer.new()
	cols.name = "Columns"
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", UiDesign.SP_5)
	scroll.add_child(cols)

	var left := VBoxContainer.new()
	left.name = "LeftColumn"
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", UiDesign.SP_5)
	cols.add_child(left)

	var right := VBoxContainer.new()
	right.name = "RightColumn"
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", UiDesign.SP_5)
	cols.add_child(right)

	_build_audio_card(left)
	_build_display_card(left)
	_build_general_card(left)
	_build_battle_card(left)
	_build_binding_card(right)
	_build_footer(page)


func _build_audio_card(col: Control) -> void:
	var body := UiKit.card(col, "音量").body
	_master = _slider_row(body, "主音量", "MasterSlider")
	_sfx = _slider_row(body, "音效", "SfxSlider")


func _build_display_card(col: Control) -> void:
	var body := UiKit.card(col, "显示").body
	_resolution = _option_row(body, "窗口分辨率", "ResOption")
	_fullscreen = _switch_row(body, "全屏", "FullscreenCheck")


func _build_general_card(col: Control) -> void:
	var body := UiKit.card(col, "通用").body
	_wheel = _switch_row(body, "鼠标滚轮切枪", "WheelCheck")


func _build_battle_card(col: Control) -> void:
	var body := UiKit.card(col, "战斗显示").body
	_traj = _switch_row(body, BATTLE_DISPLAY[0][1], "TrajCheck")
	_enemy_hp = _switch_row(body, BATTLE_DISPLAY[1][1], "EnemyHpCheck")
	_minimap = _switch_row(body, BATTLE_DISPLAY[2][1], "MinimapCheck")
	_minimap_enemy = _switch_row(body, BATTLE_DISPLAY[3][1], "MinimapEnemyCheck")


func _build_binding_card(col: Control) -> void:
	var body := UiKit.card(col, "按键映射(点击后按新键;Esc 取消)").body
	_bind_grid = VBoxContainer.new()
	_bind_grid.name = "BindGrid"
	_bind_grid.add_theme_constant_override("separation", UiDesign.SP_1)
	body.add_child(_bind_grid)


func _build_footer(page: Control) -> void:
	var footer := HBoxContainer.new()
	footer.name = "Footer"
	footer.add_theme_constant_override("separation", UiDesign.SP_4)
	page.add_child(footer)

	_reset_btn = UiDesign.ui_button("恢复默认键位", UiDesign.T_H2, Vector2.ZERO, "quiet")
	_reset_btn.name = "ResetBtn"
	footer.add_child(_reset_btn)

	var spacer := Control.new()
	spacer.name = "FooterSpacer"
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)

	_back_btn = UiDesign.ui_button("返回(Esc)", UiDesign.T_H2, Vector2.ZERO, "primary")
	_back_btn.name = "BackBtn"
	footer.add_child(_back_btn)


# 滑块填充剩余宽度。开关和下拉框按最小尺寸显示，后方的占位控件填充余下空间。
func _form_row(parent: Control, label_text: String, control: Control, expand: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_MIN_H)
	row.add_theme_constant_override("separation", UiDesign.SP_4)
	parent.add_child(row)

	var label := UiDesign.ui_label(label_text, "body")
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(FORM_LABEL_W, 0)
	row.add_child(label)

	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if expand:
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	if not expand:
		var spacer := Control.new()
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(spacer)
	return row


func _slider_row(parent: Control, label_text: String, node_name: String) -> HSlider:
	var s := HSlider.new()
	s.name = node_name
	s.max_value = 1.0
	s.step = 0.05
	_form_row(parent, label_text, s, true)
	return s


func _switch_row(parent: Control, label_text: String, node_name: String) -> CheckButton:
	var cb := CheckButton.new()
	cb.name = node_name
	_form_row(parent, label_text, cb, false)
	return cb


func _option_row(parent: Control, label_text: String, node_name: String) -> OptionButton:
	var ob := OptionButton.new()
	ob.name = node_name
	ob.theme_type_variation = &"Quiet"
	_form_row(parent, label_text, ob, false)
	return ob


# 设置项的读取、写入与信号绑定。
func _wire_settings() -> void:
	_slider(_master, Settings.get(&"master_volume"), Settings.store.bind(&"master_volume"))
	_slider(_sfx, Settings.get(&"sfx_volume"), Settings.store.bind(&"sfx_volume"))

	_check(_wheel, Settings.get(&"wheel_switch"), Settings.store.bind(&"wheel_switch"))
	_check(_traj, Settings.get(BATTLE_DISPLAY[0][0]), Settings.store.bind(BATTLE_DISPLAY[0][0]))
	_check(_enemy_hp, Settings.get(BATTLE_DISPLAY[1][0]), Settings.store.bind(BATTLE_DISPLAY[1][0]))
	_check(_minimap, Settings.get(BATTLE_DISPLAY[2][0]), Settings.store.bind(BATTLE_DISPLAY[2][0]))
	_check(_minimap_enemy, Settings.get(BATTLE_DISPLAY[3][0]), Settings.store.bind(BATTLE_DISPLAY[3][0]))

	# 选项索引与 Settings.DISPLAY_RESOLUTIONS 对应，选择后按同一索引读取尺寸。
	_resolution.clear()
	for resolution in Settings.DISPLAY_RESOLUTIONS:
		_resolution.add_item("%d × %d" % [resolution.x, resolution.y])
	_resolution.select(Settings.DISPLAY_RESOLUTIONS.find(Settings.display_resolution))
	_resolution.disabled = Settings.display_fullscreen
	_resolution.tooltip_text = "窗口会按屏幕可用区域等比例缩小;游戏视野不变。"
	_resolution.item_selected.connect(func(index: int) -> void:
		Settings.display_resolution = Settings.DISPLAY_RESOLUTIONS[index]
		Settings.apply_display()
		Settings.save())
	_check(_fullscreen, Settings.get(&"display_fullscreen"), Settings.store.bind(&"display_fullscreen"))
	_fullscreen.toggled.connect(func(on: bool) -> void:
		_resolution.disabled = on
		Settings.apply_display())

	_fill_bind_grid()

	_reset_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		Settings.reset_bindings()
		for action in _bind_buttons:
			_refresh_bind_label(action))
	_back_btn.pressed.connect(_go_back)


func _slider(s: HSlider, value: float, on_change: Callable) -> void:
	s.set_value_no_signal(value)
	s.value_changed.connect(on_change)


func _check(cb: CheckButton, on: bool, on_toggle: Callable) -> void:
	cb.set_pressed_no_signal(on)
	cb.toggled.connect(func(v: bool) -> void:
		Sfx.play("switch")
		on_toggle.call(v))


func _fill_bind_grid() -> void:
	for action in Settings.REMAPPABLE_ACTIONS:
		var label := UiDesign.ui_label(ACTION_NAMES.get(action, action), "body")
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.custom_minimum_size = Vector2(BIND_NAME_W, 0)

		var bind_btn := UiDesign.ui_button(Settings.get_binding_names(action),
				UiDesign.T_H2, Vector2.ZERO, "quiet")
		bind_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bind_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if action in ["left", "right"]:
			bind_btn.tooltip_text = "快速按两次此键可向该方向横冲。"
		if action == "R":
			bind_btn.tooltip_text = "存活时换弹。单人模式倒地后倒带并重开关卡。"
		bind_btn.pressed.connect(_begin_capture.bind(action))
		_bind_buttons[action] = bind_btn

		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0, ROW_MIN_H)
		row.add_theme_constant_override("separation", UiDesign.SP_4)
		row.add_child(label)
		row.add_child(bind_btn)
		_bind_grid.add_child(row)


# 延迟切换，让当前输入回调先完成。引擎切换时立即将旧场景移出场景树，帧末再释放。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred(BACK_SCENE)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# 先标记 Esc 已处理，再取消键位录入或请求返回。
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
	if _capturing_action == "" or not event.is_pressed() or event.is_echo():
		return
	if event.is_action_pressed(&"ui_cancel") or (event is InputEventKey and event.physical_keycode == KEY_ESCAPE):
		_cancel_capture()
	elif event is InputEventKey or event is InputEventMouseButton:
		Settings.set_binding(_capturing_action, event)
		Sfx.play("switch")
		_cancel_capture()
	else:
		return
	get_viewport().set_input_as_handled()


func _refresh_bind_label(action: String) -> void:
	_bind_buttons[action].text = Settings.get_binding_names(action)
