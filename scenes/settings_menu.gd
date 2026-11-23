extends Control

# 设置页(UI 设计系统 v2 迁移):整页**容器化**,零绝对坐标。
#
# ── 结构(全部在 _build_page() 里用 UiKit / UiDesign 搭,场景文件只剩根 Control + Theme)─────
#   UiKit.page(self) = MarginContainer(SP_6) → VBox(SP_5)
#     ├─ Header    UiDesign.header_strip(页首标题, T_H1, 居中)
#     ├─ Scroll    ScrollContainer(只纵滚;VScrollBar 用 Kit 皮肤) → HBox(SP_5) → 左/右两列 VBox
#     │     ├─ 左列:UiKit.card ×4(音量 / 显示 / 通用 / 战斗显示)
#     │     │        每行 = _form_row():HBox(定宽标签列 FORM_LABEL_W + 控件;非拉伸控件后接弹簧)
#     │     └─ 右列:UiKit.card(按键映射)→ BindGrid(VBox) 10 行
#     └─ Footer    HBox(恢复默认键位 [Quiet] …弹簧… 返回 [Primary])
#   开关统一 UiDesign.ui_check()(Theme Kit);行高/间距全由容器 + token 决定。
#
# ── 与 main 参考版的差异(只改数据适配,不改版式)────────────────────────────────
#   main 用 Settings 的属性 + display_res_index;本仓 Settings 是 get()/store(key) 泛型 API、
#   分辨率用 display_resolution + DISPLAY_RESOLUTIONS,故接线按本仓 API 原样保留,
#   设置项与读写语义与迁移前逐项等价(见 _wire_settings)。
#
# ── 行为零变化(迁移只改版式/结构)──────────────────────────────────────────────
#   · Settings 的键名与读写/save/apply_display 调用、Sfx 音效、所有 toggled/value_changed 接线原样;
#   · 键位捕获(点击→按新键 / Esc 取消)、Esc 返回、返回路径 main_menu.tscn 原样;
#   · ACTION_NAMES / BATTLE_DISPLAY 内容与旧版一致。
#
# ★ 不新增颜色字面量:页面背景取 UiDesign.C_BG;字号/间距只用 T_* / SP_* token。
# ★ 本文件零处 StyleBox / position= / size= / 手写 Color(...)。

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

# 表单布局(全部 token 组合,不写魔法数;规则见 docs/ui.md)
const FORM_LABEL_W := UiDesign.T_H2 * 12   # 384:定宽标签列,容纳 12 个 32px 汉字
const BIND_NAME_W := UiDesign.T_H2 * 6     # 192:键位表标签列(6 个 32px 汉字)
const ROW_MIN_H := UiDesign.SP_8           # 48:表单行最小高,让滑块/开关/下拉纵向对齐

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


# ── 页面骨架(容器优先:谁负责排布就是容器,页面里没有任何绝对坐标)────────────────
func _build_page() -> void:
	# 背景:页面底色唯一来源 = 调色板 token(不写 Color 字面量)。
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

	# 内容区只纵滚:1280×960 这类窗口下两列卡片放不下时靠滚动,横向永不滚。
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.get_v_scroll_bar().theme_type_variation = &"Kit"
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

	# 左右分栏:左 = 音量 / 显示 / 通用 / 战斗显示;右 = 按键映射(10 行,占满一列。
	# 两列内容高度接近,1600×1200 的评审窗口下也不至于一侧长一侧空。
	_build_audio_card(left)
	_build_display_card(left)
	_build_general_card(left)
	_build_battle_card(left)
	_build_binding_card(right)
	_build_footer(page)


func _build_audio_card(col: Control) -> void:
	var body := UiKit.card(col, "音量")
	_master = _slider_row(body, "主音量", "MasterSlider")
	_sfx = _slider_row(body, "音效", "SfxSlider")


func _build_display_card(col: Control) -> void:
	var body := UiKit.card(col, "显示")
	_resolution = _option_row(body, "窗口分辨率", "ResOption")
	_fullscreen = _switch_row(body, "全屏", "FullscreenCheck")


func _build_general_card(col: Control) -> void:
	var body := UiKit.card(col, "通用")
	_wheel = _switch_row(body, "鼠标滚轮切枪", "WheelCheck")


func _build_battle_card(col: Control) -> void:
	var body := UiKit.card(col, "战斗显示")
	_traj = _switch_row(body, BATTLE_DISPLAY[0][1], "TrajCheck")
	_enemy_hp = _switch_row(body, BATTLE_DISPLAY[1][1], "EnemyHpCheck")
	_minimap = _switch_row(body, BATTLE_DISPLAY[2][1], "MinimapCheck")
	_minimap_enemy = _switch_row(body, BATTLE_DISPLAY[3][1], "MinimapEnemyCheck")


func _build_binding_card(col: Control) -> void:
	var body := UiKit.card(col, "按键映射(点击后按新键;Esc 取消)")
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


# ── 表单行(工具)──────────────────────────────────────────────────────────────
# 一行 = HBox(定宽标签列 + 控件)。expand=true:控件吃掉剩余宽度(滑块);false:控件自然宽,
# 后面接一根弹簧把它顶到标签列紧邻处(开关/下拉),避免裸 CheckButton 被宽容器拉成整行。
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
	var cb := UiDesign.ui_check()
	cb.name = node_name
	_form_row(parent, label_text, cb, false)
	return cb


func _option_row(parent: Control, label_text: String, node_name: String) -> OptionButton:
	var ob := OptionButton.new()
	ob.name = node_name
	# 下拉 = 按钮皮肤:用 Theme 2.0 的 Quiet variation(不再逐控件拼样式)。
	ob.theme_type_variation = &"Quiet"
	_form_row(parent, label_text, ob, false)
	return ob


# ── 设置接线(与本仓迁移前逐行等价;main 的属性式 API 在这里改成 get()/store())────────
func _wire_settings() -> void:
	_slider(_master, Settings.get(&"master_volume"), Settings.store.bind(&"master_volume"))
	_slider(_sfx, Settings.get(&"sfx_volume"), Settings.store.bind(&"sfx_volume"))

	_check(_wheel, Settings.get(&"wheel_switch"), Settings.store.bind(&"wheel_switch"))
	_check(_traj, Settings.get(BATTLE_DISPLAY[0][0]), Settings.store.bind(BATTLE_DISPLAY[0][0]))
	_check(_enemy_hp, Settings.get(BATTLE_DISPLAY[1][0]), Settings.store.bind(BATTLE_DISPLAY[1][0]))
	_check(_minimap, Settings.get(BATTLE_DISPLAY[2][0]), Settings.store.bind(BATTLE_DISPLAY[2][0]))
	_check(_minimap_enemy, Settings.get(BATTLE_DISPLAY[3][0]), Settings.store.bind(BATTLE_DISPLAY[3][0]))

	# ★ 下拉选项由 Settings.DISPLAY_RESOLUTIONS 现场生成,不把尺寸表抄进场景 —— 那张表是单一来源。
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


# ── 键位表(右栏):行数由 Settings.REMAPPABLE_ACTIONS 定,故留在代码里 ──
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


# ── 返回 / 键位捕获(与迁移前逐行等价)──────────────────────────────────────────
# ★ 切场景必须延迟到帧末:change_scene_to_file 会同步 memdelete 当前场景,而本函数两条调用路径
# (ESC 的 _unhandled_input 与返回按钮)在切换之后还会碰 self/get_tree()。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred(BACK_SCENE)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# ★ 顺序不能反:先标记事件已处理,再决定去向 —— _go_back() 之后本节点即被移出场景树。
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
