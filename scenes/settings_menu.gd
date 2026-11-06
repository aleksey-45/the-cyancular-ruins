extends Control

const ACTION_NAMES := {
	"left": "左移", "right": "右移", "up": "跳跃/上爬", "down": "下蹲/下落",
	"attack": "开火", "R": "重开(单机)",
	"F": "拾取", "Q": "丢弃(长按)",
	"rewind": "时间回溯", "haste": "时间加速",
}

const ROW_H := 72
const BIND_NAME_W := 200.0
const BIND_BTN_W := 220.0

var _capturing_action := ""
var _capture_btn: Button = null
var _bind_buttons: Dictionary = {}

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
	_slider(_master, Settings.master_volume, func(v: float) -> void:
		Settings.master_volume = v
		Settings.save())
	_slider(_sfx, Settings.sfx_volume, func(v: float) -> void:
		Settings.sfx_volume = v
		Settings.save())

	_check(_wheel, Settings.wheel_switch, func(on: bool) -> void:
		Settings.wheel_switch = on
		Settings.save())
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
	_res.selected = Settings.display_res_index
	_res.item_selected.connect(func(i: int) -> void:
		Settings.display_res_index = i
		Settings.save()
		Settings.apply_display())
	_check(_fullscreen, Settings.display_fullscreen, func(on: bool) -> void:
		Settings.display_fullscreen = on
		Settings.save()
		Settings.apply_display())

	_fill_bind_grid()

	%ResetBtn.pressed.connect(func() -> void:
		Sfx.play("ui")
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
		var bind_btn := Button.new()
		bind_btn.theme_type_variation = &"BtnLegacy"
		bind_btn.custom_minimum_size = Vector2(BIND_BTN_W, ROW_H)
		bind_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bind_btn.pressed.connect(func() -> void: _begin_capture(action, bind_btn))
		_bind_grid.add_child(bind_btn)
		_bind_buttons[action] = bind_btn
		_refresh_bind_label(action)


# ★ 切场景必须延迟到帧末:change_scene_to_file 会同步 memdelete 当前场景,而本函数两条调用路径(ESC 的 _unhandled_input 与返回按钮)在切换之后还会碰 self/get_tree()(headless 实测 Cannot call method set_input_as_handled on a null value,真机上是悬垂指针)。
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


const CAPTURE_IGNORE := 0
const CAPTURE_ACCEPT := 1
const CAPTURE_CANCEL := 2

static func capture_action(event: InputEvent) -> int:
	var key := event as InputEventKey
	if key != null:
		if not key.pressed:
			return CAPTURE_IGNORE
		return CAPTURE_CANCEL if key.physical_keycode == KEY_ESCAPE else CAPTURE_ACCEPT
	var btn := event as InputEventMouseButton
	if btn != null:
		return CAPTURE_ACCEPT if btn.pressed else CAPTURE_IGNORE
	return CAPTURE_IGNORE


func _input(event: InputEvent) -> void:
	if _capturing_action == "":
		return
	match capture_action(event):
		CAPTURE_IGNORE:
			return
		CAPTURE_CANCEL:
			get_viewport().set_input_as_handled()
			_cancel_capture()
			return
	Settings.set_binding(_capturing_action, event)
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
