extends Control
# 设置菜单:键鼠重映射 / 音量 / 滚轮切枪 / 联机显示。全部改动即时生效并经 Settings 持久化(user://settings.cfg),Esc 返回。
# ★ 静态骨架在 settings_menu.tscn 里(见 tools/gen_menu_scene.gd),本脚本只填动态部分(键位表每一行)与接信号:版式全在 .tscn 里,改版式去编辑器拖、别回来加常量;样式走 menu_theme.tres 的 theme_type_variation,不再调 UiFactory 的套皮函数。
# ★ 键位表 / 开关 / 滑条的取值仍由本脚本从 Settings 灌进去(骨架里存的是导出那一刻的值)。

const ACTION_NAMES := {
	"left": "左移", "right": "右移", "up": "跳跃/上爬", "down": "下蹲/下落",
	"charge": "冲刺", "attack": "开火", "R": "重开(单机)",
	"F": "拾取", "Q": "丢弃(长按)",
	# ★ ACTION_NAMES 与 Settings.REMAPPABLE_ACTIONS 必须逐条对齐:漏一条就退化成 ACTION_NAMES.get(action, action)、界面显示英文键名。零守卫(settings_actions_smoke 已删·2026-10-09)。
	"rewind": "时间回溯", "haste": "时间加速",
}

# 32 号字按钮的最低高度 = 字号 32 + UiFactory._btn_box 的上下内边距(20×2);迁移后只有键位表那几个按钮还用得上它。
const ROW_H := 72
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
@onready var _res: OptionButton = %ResOption
@onready var _fullscreen: CheckButton = %FullscreenCheck
@onready var _bind_grid: GridContainer = %BindGrid


func _ready() -> void:
	# 音量滑条不出声:本文件的 _slider() 只灌值 + 接 value_changed,不播 Sfx —— 别顺手给滑条补一个点击音。
	_slider(_master, Settings.master_volume, func(v: float) -> void:
		Settings.master_volume = v
		Settings.save())
	_slider(_sfx, Settings.sfx_volume, func(v: float) -> void:
		Settings.sfx_volume = v
		Settings.save())

	# ★ 先灌值再接信号:button_pressed = x 会发 toggled,顺序反了会在建控件那一刻就把值写回 Settings 并播一次开关音(见 _check():它也是先值后连)。
	_check(_wheel, Settings.wheel_switch, func(on: bool) -> void:
		Settings.wheel_switch = on
		Settings.save())
	# ★ 这四个开关原先只长在 1v1 大厅页的右侧面板上,那页在「大厅合一」里被删了 ⇒ 键与读者都还在、界面上却改不了,这里放回来;它们只写本机 Settings、不上报服务器(与对局的房主规则项不是一回事)。
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

	# ★ 下拉选项由 Settings.DISPLAY_RESOLUTIONS 现场生成,不把尺寸表抄进 .tscn —— 那张表是单一来源,抄一份进场景就是第二个真相源。
	# ★ 先 clear() 再灌:骨架里可能已经烙进导出那一刻的选项(重生成 / 取图时会发生),不清就会变成两份。
	_res.clear()
	for size in Settings.DISPLAY_RESOLUTIONS:
		_res.add_item("%d×%d" % [size.x, size.y])
	# ★ 与 _check() 同一口径:先灌值再连信号 —— selected 赋值与 select() 都不发 item_selected,这里不会在建控件时误写回 Settings。
	_res.selected = Settings.display_res_index
	_res.item_selected.connect(func(i: int) -> void:
		Settings.display_res_index = i
		Settings.save()
		Settings.apply_display())
	# ★ 全屏走既有 _check() 包一层,与其它开关同款:只在 toggled 里写 Settings(自带 Sfx 与先值后连)。
	_check(_fullscreen, Settings.display_fullscreen, func(on: bool) -> void:
		Settings.display_fullscreen = on
		Settings.save()
		Settings.apply_display())

	_fill_bind_grid()

	# ── 底部动作 ── 恢复默认键位是有破坏性的动作(丢掉玩家自己绑的键)⇒ quiet 档(在骨架里已定)。
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


# ── 键位表(右栏):行数由 Settings.REMAPPABLE_ACTIONS 定,故留在代码里 ──
# ★ 列数 2 ⇒ 一行一对(名称, 键位):两栏并排后每栏只有半屏宽,一行两对会超出(实测最小宽 1862 > 页面 1768);columns 与行距在骨架里定。
func _fill_bind_grid() -> void:
	for action in Settings.REMAPPABLE_ACTIONS:
		var name_l := Label.new()
		name_l.text = ACTION_NAMES.get(action, action)
		# ★★ 这两行是外观契约的一部分,别顺手删:① 字色是 C_WHITE 而不是 Theme 的 C_TEXT(UiFactory.label() 默认就是纯白,不写就吃 Theme,实测差 9220 个像素);② mouse_filter = IGNORE 同款,漏了会让这一列吃掉点击(键位按钮就在同一行里)。
		name_l.add_theme_color_override("font_color", UiFactory.C_WHITE)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_l.custom_minimum_size = Vector2(BIND_NAME_W, 0)
		_bind_grid.add_child(name_l)
		# 键位按钮是网格单元(不是主菜单按钮列);★ 高度 40 会被按钮内边距顶到 72,这里写 ROW_H 让源码与画面一致。
		var bind_btn := Button.new()
		bind_btn.theme_type_variation = &"BtnLegacy"   # = 旧的 `button(…, "primary")` 那一档
		bind_btn.custom_minimum_size = Vector2(BIND_BTN_W, ROW_H)
		bind_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bind_btn.pressed.connect(func() -> void: _begin_capture(action, bind_btn))
		_bind_grid.add_child(bind_btn)
		_bind_buttons[action] = bind_btn
		_refresh_bind_label(action)


# ★ 切场景必须延迟到帧末:change_scene_to_file 会同步 memdelete 当前场景,而本函数两条调用路径(ESC 的 _unhandled_input 与返回按钮)在切换之后还会碰 self/get_tree()(headless 实测 Cannot call method set_input_as_handled on a null value,真机上是悬垂指针)。零守卫(settings_esc_probe 已删·2026-10-09)。
# 本菜单是纯 UI(无世界、无大物理),普通切场景只销毁一棵 Control 树;反方向(游戏世界 → 菜单)才需要挂起式切换,见 Level0.safe_change_scene。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# ★ 顺序不能反:先标记事件已处理,再决定去向 —— _go_back() 之后本节点即被移出场景树,那时 get_viewport() 已经拿不到东西。
		get_viewport().set_input_as_handled()
		if _capturing_action != "":
			_cancel_capture()
		else:
			_go_back()


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
		# 修饰键单独按下不作为绑定(留给组合键的未来扩展)。
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
	# 键位 API 的既有语义(设计如此,非缺陷):set_binding 先 action_erase_events 再只写这一个 ⇒ 用户主动重绑 = 该动作从此按单键(默认多键如 up=W+Space 只留新键)。
	# 而显示(get_binding_names)与持久化(save/load_settings)都遍历全部事件,故存档往返不丢键。
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
