extends Control
# 设置菜单:键鼠重映射 / 音量 / 滚轮切枪 / 联机显示。
# 全部改动即时生效并经 Settings 持久化(user://settings.cfg)。像素风格,Esc 返回。
#
# 设置页面：控制音频音量、显示选项与按键映射。
# 静态布局结构定义在 settings_menu.tscn 中，本脚本负责装配按键行并绑定配置。

const ACTION_NAMES := {
	"left": "左移", "right": "右移", "up": "跳跃/上爬", "down": "下蹲/下落",
	"charge": "冲刺", "attack": "开火", "R": "重开(单机)",
	"F": "拾取", "Q": "丢弃(长按)",
	# 按键动作映射表
	"rewind": "时间回溯", "haste": "时间加速",
}

# 按钮尺寸常量
const ROW_H := 72
# 键位表里的名字列宽(基础结构框架里那几行静态标签的宽度是同源的另一份,改这里要一起改)。
const BIND_NAME_W := 200.0
const BIND_BTN_W := 220.0

var _capturing_action := ""      # 正在等待捕获新键位的动作(""=不在捕获态)
var _capture_btn: Button = null
var _bind_buttons: Dictionary = {}   # action -> Button

@onready var _master: HSlider = %MasterSlider
@onready var _sfx: HSlider = %SfxSlider
@onready var _wheel: CheckButton = %WheelCheck
@onready var _traj: CheckButton = %TrajCheck
@onready var _enemy_hp: CheckButton = %EnemyHpCheck
@onready var _minimap: CheckButton = %MinimapCheck
@onready var _minimap_enemy: CheckButton = %MinimapEnemyCheck
@onready var _bind_grid: GridContainer = %BindGrid


func _ready() -> void:
	# ── 音量设置 ──（滑条调节不播放音效，
	#   与键位按钮那一档不同 —— 切勿随意给滑条补一个点击音)
	_slider(_master, Settings.master_volume, func(v: float) -> void:
		Settings.master_volume = v
		Settings.save())
	_slider(_sfx, Settings.sfx_volume, func(v: float) -> void:
		Settings.sfx_volume = v
		Settings.save())

	# ── 通用 / 联机显示 ──
	# 先设置初始值再连接信号，避免初始化触发额外反馈
	_check(_wheel, Settings.wheel_switch, func(on: bool) -> void:
		Settings.wheel_switch = on
		Settings.save())
	# - 这四个原先只长在 1v1 大厅页的右侧面板上,而那页在「大厅合一」里被删了  -> 
	#   键与读者都还在,但界面上再也改不了。这里把它们放回来。
	# 本地设置项存储
	_check(_traj, Settings.pvp_show_trajectories, func(on: bool) -> void:
		Settings.pvp_show_trajectories = on
		Settings.save())
	_check(_enemy_hp, Settings.pvp_show_enemy_hp, func(on: bool) -> void:
		Settings.pvp_show_enemy_hp = on
		Settings.save())
	_check(_minimap, Settings.pvp_show_minimap, func(on: bool) -> void:
		Settings.pvp_show_minimap = on
		Settings.save())
	_check(_minimap_enemy, Settings.pvp_minimap_show_enemy, func(on: bool) -> void:
		Settings.pvp_minimap_show_enemy = on
		Settings.save())

	_fill_bind_grid()

	# ── 底部动作 ──
	# 恢复默认设置确认
	%ResetBtn.pressed.connect(func() -> void:
		Sfx.play("ui")   # 点击音由各 handler 自己出(UiFactory.button 不代挂,防同帧双响)
		Settings.reset_bindings()
		for a in _bind_buttons:
			_refresh_bind_label(a))
	%BackBtn.pressed.connect(_go_back)


func _slider(s: HSlider, value: float, on_change: Callable) -> void:
	s.value = value
	s.value_changed.connect(on_change)


func _check(cb: CheckButton, on: bool, on_toggle: Callable) -> void:
	cb.button_pressed = on
	cb.toggled.connect(func(v: bool) -> void:
		Sfx.play("switch")
		on_toggle.call(v))


# ── 键位映射表 ──
func _fill_bind_grid() -> void:
	for action in Settings.REMAPPABLE_ACTIONS:
		var name_l := Label.new()
		name_l.text = ACTION_NAMES.get(action, action)
		# 键位列表行文字样式与鼠标过滤配置
		#      (键位按钮就在同一行里)。
		name_l.add_theme_color_override("font_color", UiFactory.C_WHITE)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_l.custom_minimum_size = Vector2(BIND_NAME_W, 0)
		_bind_grid.add_child(name_l)
		# 键位按钮是网格单元(不是主菜单按钮列)。-  高度 40 会被按钮内边距顶到 72,
		
		var bind_btn := Button.new()
		bind_btn.theme_type_variation = &"BtnLegacy"
		bind_btn.custom_minimum_size = Vector2(BIND_BTN_W, ROW_H)
		bind_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bind_btn.pressed.connect(func() -> void: _begin_capture(action, bind_btn))
		_bind_grid.add_child(bind_btn)
		_bind_buttons[action] = bind_btn
		_refresh_bind_label(action)


# 本菜单是纯 UI(无世界、无大物理),普通切场景只会销毁一棵 Control 树;
# 反方向(游戏世界 → 菜单)才需要挂起式切换,见 Level0.safe_change_scene。
# 页面返回延迟至帧末执行，防止悬空引用
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# 先消费输入事件再执行返回
		get_viewport().set_input_as_handled()
		if _capturing_action != "":
			_cancel_capture()
		else:
			_go_back()


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
	# 重绑按键后更新映射并持久化保存
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
