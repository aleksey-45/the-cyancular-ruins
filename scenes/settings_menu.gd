extends Control

# 设置页(UI 设计系统 v1 迁移 M3):整页**容器化**,零绝对坐标。
#
# ── 结构(全部在 _build_page() 里用 UiKit / UiFactory 搭,场景文件只剩根 Control)─────────
#   UiKit.page(self) = MarginContainer(SP_6) → VBox(SP_5)
#     ├─ Header    UiFactory.header_strip(页首标题, T_H1, 居中)
#     ├─ Scroll    ScrollContainer(只纵滚, ScrollBar 用 Kit 皮肤) → HBox(SP_5) → 左/右两列 VBox
#     │     ├─ 左列:UiKit.card ×3(音量 / 联机显示 / 显示)
#     │     │        每行 = _form_row():HBox(定宽标签列 FORM_LABEL_W + 控件;非拉伸控件后接弹簧)
#     │     └─ 右列:UiKit.card(通用:鼠标滚轮切枪)+ UiKit.card(按键映射)→ BindGrid(VBox) 10 行
#     └─ Footer    HBox(恢复默认键位 [Quiet] …弹簧… 返回 [Primary])
#   开关统一 UiFactory.ui_check()(Theme Kit);行高/间距全由容器 + token 决定。
#
# ── 行为零变化(迁移只改版式/结构)────────────────────────────────────────────
#   · Settings 的键名与读写/保存/apply_display 调用、Sfx 音效、所有 toggled/value_changed 接线原样;
#   · 键位捕获(点击→按新键 / Esc 取消)、Esc 返回、返回路径 main_menu.tscn 原样;
#   · 对外契约保持:tests/smoke/binding_contract_smoke.gd 直接读本脚本的 ACTION_NAMES / CAPTURE_* /
#     capture_action(),这些一个都没动。
#   · 控件节点名与迁移前一致,且在运行时登记 owner + unique_name_in_owner(unique name 语义不变)。
#
# ★ 不新增颜色字面量:页面背景取 UiFactory.C_BG;字号只用 T_* token(16 的倍数)。
# ★ 禁止 RegEx(进客户端导出包);禁止 position/size=/手写 StyleBox(本文件零处)。

const ACTION_NAMES := {
	"left": "左移", "right": "右移", "up": "跳跃/上爬", "down": "下蹲/下落",
	"attack": "开火", "R": "重开(单机)",
	"F": "拾取", "Q": "丢弃(长按)",
	"rewind": "时间回溯", "haste": "时间加速",
}

# 表单布局(全部 token 组合,不写魔法数;规则见 docs/systems/presentation/ui-design-system.md §2)
const FORM_LABEL_W := UiFactory.T_H2 * 12   # 384:定宽标签列,容纳 12 个 32px 汉字(最长是「显示子弹尾迹(所有子弹)」)
const BIND_NAME_W := UiFactory.T_H2 * 6     # 192:键位表标签列(6 个 32px 汉字)
const ROW_MIN_H := UiFactory.SP_8           # 48:表单行最小高,让滑块/开关/下拉纵向对齐

var _capturing_action := ""
var _capture_btn: Button = null
var _bind_buttons: Dictionary = {}

var _master: HSlider = null
var _sfx: HSlider = null
var _wheel: CheckButton = null
var _traj: CheckButton = null
var _enemy_hp: CheckButton = null
var _minimap: CheckButton = null
var _minimap_enemy: CheckButton = null
var _res: OptionButton = null
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
	bg.color = UiFactory.C_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var page := UiKit.page(self)
	page.name = "Page"

	var header := UiFactory.header_strip("—— 设 置 ——", UiFactory.T_H1, true)
	header.name = "Header"
	page.add_child(header)

	# 内容区只纵滚:1600×1200 这类窗口下两列卡片放不下时靠滚动,横向永不滚。
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
	cols.add_theme_constant_override("separation", UiFactory.SP_5)
	scroll.add_child(cols)

	var left := VBoxContainer.new()
	left.name = "LeftColumn"
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", UiFactory.SP_5)
	cols.add_child(left)

	var right := VBoxContainer.new()
	right.name = "RightColumn"
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", UiFactory.SP_5)
	cols.add_child(right)

	# 左右分栏:左 = 音量 / 联机显示 / 显示;右 = 通用(滚轮切枪,输入相关)+ 按键映射。
	# 这样两列内容高度接近(1600×1200 的评审截图下也放得下),且不会一侧长一侧空。
	_build_audio_card(left)
	_build_multiplayer_card(left)
	_build_display_card(left)
	_build_general_card(right)
	_build_binding_card(right)
	_build_footer(page)


func _build_audio_card(col: Control) -> void:
	var body := UiKit.card(col, "音量")
	_master = _slider_row(body, "主音量", "MasterSlider")
	_sfx = _slider_row(body, "音效", "SfxSlider")


func _build_general_card(col: Control) -> void:
	var body := UiKit.card(col, "通用")
	_wheel = _switch_row(body, "鼠标滚轮切枪", "WheelCheck")


func _build_multiplayer_card(col: Control) -> void:
	var body := UiKit.card(col, "联机显示")
	_traj = _switch_row(body, "显示子弹尾迹(所有子弹)", "TrajCheck")
	_enemy_hp = _switch_row(body, "显示敌方血量条", "EnemyHpCheck")
	_minimap = _switch_row(body, "打开小地图", "MinimapCheck")
	_minimap_enemy = _switch_row(body, "小地图显示敌方位置", "MinimapEnemyCheck")


func _build_display_card(col: Control) -> void:
	var body := UiKit.card(col, "显示")
	_res = _option_row(body, "分辨率", "ResOption")
	_fullscreen = _switch_row(body, "全屏", "FullscreenCheck")


func _build_binding_card(col: Control) -> void:
	var body := UiKit.card(col, "按键映射(点击后按新键;Esc 取消)")
	_bind_grid = VBoxContainer.new()
	_bind_grid.name = "BindGrid"
	_bind_grid.add_theme_constant_override("separation", UiFactory.SP_1)
	body.add_child(_bind_grid)
	_keep_unique(_bind_grid)


func _build_footer(page: Control) -> void:
	var footer := HBoxContainer.new()
	footer.name = "Footer"
	footer.add_theme_constant_override("separation", UiFactory.SP_4)
	page.add_child(footer)

	_reset_btn = UiFactory.ui_button("恢复默认键位", UiFactory.T_H2, Vector2.ZERO, "quiet")
	_reset_btn.name = "ResetBtn"
	footer.add_child(_reset_btn)
	_keep_unique(_reset_btn)

	var spacer := Control.new()
	spacer.name = "FooterSpacer"
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)

	_back_btn = UiFactory.ui_button("返 回(Esc)", UiFactory.T_H2, Vector2.ZERO, "primary")
	_back_btn.name = "BackBtn"
	footer.add_child(_back_btn)
	_keep_unique(_back_btn)


# ── 表单行(工具)──────────────────────────────────────────────────────────────
# 一行 = HBox(定宽标签列 + 控件)。expand=true:控件吃掉剩余宽度(滑块);false:控件自然宽,
# 后面接一根弹簧把它顶到标签列紧邻处(开关/下拉),避免裸 CheckButton 被宽容器拉成整行。
func _form_row(parent: Control, label_text: String, control: Control, expand: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_MIN_H)
	row.add_theme_constant_override("separation", UiFactory.SP_4)
	parent.add_child(row)

	var label := UiFactory.ui_label(label_text, "body")
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
	_keep_unique(s)
	return s


func _switch_row(parent: Control, label_text: String, node_name: String) -> CheckButton:
	var cb := UiFactory.ui_check()
	cb.name = node_name
	_form_row(parent, label_text, cb, false)
	_keep_unique(cb)
	return cb


func _option_row(parent: Control, label_text: String, node_name: String) -> OptionButton:
	var ob := OptionButton.new()
	ob.name = node_name
	# 下拉 = 按钮皮肤:用 Theme 2.0 的 Quiet variation(旧版是 BtnLegacy;不再逐控件拼样式)。
	ob.theme_type_variation = &"Quiet"
	_form_row(parent, label_text, ob, false)
	_keep_unique(ob)
	return ob


# 控件节点名保持与迁移前一致,并仍登记为唯一名(%MasterSlider 等语义不变)。
# 运行时建的节点没有 owner,unique_name_in_owner 必须先有 owner 才会注册。
func _keep_unique(c: Control) -> void:
	c.owner = self
	c.unique_name_in_owner = true


# ── 设置接线(与迁移前逐行等价)────────────────────────────────────────────────
func _wire_settings() -> void:
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

	# ★ 下拉选项由 Settings.DISPLAY_RESOLUTIONS 现场生成,不把尺寸表抄进场景 —— 那张表是单一来源。
	# ★ 先 clear() 再灌:热重载 / 取图时骨架里可能已经烙进导出那一刻的选项,不清就会变成两份。
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

	_reset_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		Settings.reset_bindings()
		for a in _bind_buttons:
			_refresh_bind_label(a))
	_back_btn.pressed.connect(_go_back)


func _slider(s: HSlider, value: float, on_change: Callable) -> void:
	s.value = value
	s.value_changed.connect(on_change)


func _check(cb: CheckButton, on: bool, on_toggle: Callable) -> void:
	cb.button_pressed = on
	cb.toggled.connect(func(v: bool) -> void:
		Sfx.play("switch")
		on_toggle.call(v))


# ── 键位表(右栏):行数由 Settings.REMAPPABLE_ACTIONS 定,故留在代码里 ──
# ★ 一行 = 名称(定宽列)+ 键位按钮;两栏并排后每列只有半屏宽,所以不并排两对(会超出)。
func _fill_bind_grid() -> void:
	for action in Settings.REMAPPABLE_ACTIONS:
		var label := UiFactory.ui_label(ACTION_NAMES.get(action, action), "body")
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.custom_minimum_size = Vector2(BIND_NAME_W, 0)

		var bind_btn := UiFactory.ui_button("", UiFactory.T_BODY, Vector2.ZERO, "quiet")
		bind_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bind_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bind_btn.pressed.connect(func() -> void: _begin_capture(action, bind_btn))
		_bind_buttons[action] = bind_btn
		_refresh_bind_label(action)

		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0, ROW_MIN_H)
		row.add_theme_constant_override("separation", UiFactory.SP_4)
		row.add_child(label)
		row.add_child(bind_btn)
		_bind_grid.add_child(row)


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
