extends Control
# 设置菜单:键鼠重映射 / 音量 / 滚轮切枪。
# 全部改动即时生效并经 Settings 持久化(user://settings.cfg)。像素风格,Esc 返回。
# 场景是裸 Control,UI 全在代码里建;控件一律走 UiFactory(像素字体与字号规范的单一来源,
# 字号必须是 16 的倍数)。

const ACTION_NAMES := {
	"left": "左移", "right": "右移", "up": "跳跃/上爬", "down": "下蹲/下落",
	"charge": "冲刺", "attack": "开火", "R": "重开(单机)",
	"F": "拾取", "Q": "丢弃(长按)",
	# ★ 2026-10-02 合并补:KH 的时间玩法把这两个动作加进了 `REMAPPABLE_ACTIONS`,
	#   而主线的 `settings_actions_smoke` 要求两表**逐条对齐**(漏一条就退化成
	#   `ACTION_NAMES.get(action, action)` 显示英文键名)。守卫正是为此而设。
	"rewind": "时间回溯", "haste": "时间加速",
}

var _capturing_action := ""      # 正在等待捕获新键位的动作(""=不在捕获态)
var _capture_btn: Button = null
var _bind_buttons: Dictionary = {}   # action -> Button


# ── 版式常量(第三批尺度,2026-10-03)──
# 页面四周留白(与 `scenes/mp_lobby.gd` 的 PAGE_MARGIN 同一个呼吸量)。
const PAGE_MARGIN := 76
# 页面标题 / 两栏 / 底部动作行之间的空档。
# ★ 这个数**受高度预算约束**:页高是固定的 1440,而右栏(11 个键位格 × 72)本来就高 ——
#   32 会让整页超出一个屏幕高、底部动作行被裁掉(实测过)。改大之前先跑一次临时探针
#   (或直接看 `_beauty_2_settings.png` 那类截图)确认动作行没被切。
const BLOCK_GAP := 24
# 两栏之间。
const COL_GAP := 32
# 一个面板内**节与节、节与条目**之间的空档。
const SECTION_GAP := 20
# 底部两颗按钮之间。
const ACTION_GAP := 24
# 32 号字按钮的最低高度 = 字号(32)+ `UiFactory._btn_box` 的上下内边距(20×2)。
const ROW_H := 72


# ★★ 两栏版式(2026-10-03):本页原先是一个 900 宽的**单列 VBox**,右半屏整片空着 ——
#   左栏放「音量 / 通用 / 联机显示」三节,右栏放「按键映射」,两栏各一块 `menu_panel()`
#   (方向 B 的凿刻边),节标题用 `header_strip()`。面板 / 标题带 / 主次按钮的语汇与
#   单人开局面板、创建房间弹层同一套。
# ★ 判据面(别踩):`settings_display_section_probe` 按**遍历序**要求
#   「鼠标滚轮切枪」在「联机显示」之前、「联机显示」在「按键映射」之前 —— 左栏先建、
#   右栏后建即满足(深度优先遍历:整棵左子树在右子树之前)。文案一个字都不能改。
func _ready() -> void:
	# 不透明深色底:进过单机后全局清屏色是浅蓝,白字会看不清(Esc 仍在 _unhandled_input 处理)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# 整页走 MarginContainer(页面留白)而不是绝对坐标 —— 两栏 + 底部动作行的高度是内容撑的,
	# 写死坐标会在改字号/内边距时错位(本仓在 mp_lobby 那页为此付过代价)。
	var page := MarginContainer.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		page.add_theme_constant_override("margin_" + side, PAGE_MARGIN)
	add_child(page)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", BLOCK_GAP)
	page.add_child(outer)

	# 页面标题 = 同款标题带(与「创 建 房 间」/「—— 单人开局 ——」同一个味道)。
	outer.add_child(UiFactory.header_strip("—— 设 置 ——", 48))

	# ★ 两栏**吃掉剩余高度**:这样底部动作行天然贴到页面下沿(1440 − PAGE_MARGIN),
	#   而不是跟在两栏后面飘在中间;两栏也等高等宽(更整齐)。
	#   ⚠ 代价:内容 min 高一旦超过可用高度,整页会**溢出**(底部动作行被切)—— 上界由
	#   `BLOCK_GAP` / `SECTION_GAP` / 键位格行距(见 `grid` 的 v_separation)三者把控。
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", COL_GAP)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(cols)

	# ── 左栏:音量 / 通用 / 联机显示 ──
	var lvb := _column(cols)
	lvb.add_child(_section("音量"))
	lvb.add_child(UiFactory.slider_row("主音量", Settings.master_volume, CHECK_LABEL_W, func(v: float) -> void:
		Settings.master_volume = v
		Settings.save()))
	lvb.add_child(UiFactory.slider_row("音效", Settings.sfx_volume, CHECK_LABEL_W, func(v: float) -> void:
		Settings.sfx_volume = v
		Settings.save()))

	# ── 通用开关 ──
	lvb.add_child(_section("通用"))
	lvb.add_child(UiFactory.check_row("鼠标滚轮切枪", Settings.wheel_switch, CHECK_LABEL_W, func(on: bool) -> void:
		Settings.wheel_switch = on
		Settings.save()))

	# ── 联机显示 ──
	# ★ 这四个开关原先只长在 1v1 大厅页的右侧面板上,而那页在「大厅合一」里被删了 ⇒
	#   键与读者都还在,但界面上再也改不了。这里把它们放回来。
	# ★ 它们**只写本机 Settings、不上报服务器**(与对局的「房主规则项」不是一回事):
	#   四个键的读者全在本机(pvp_game / royale_game / team_game / bullet_base / minimap)。
	lvb.add_child(_section("联机显示"))
	lvb.add_child(UiFactory.check_row("显示子弹尾迹(所有子弹)", Settings.pvp_show_trajectories,
			CHECK_LABEL_W, func(on: bool) -> void:
		Settings.pvp_show_trajectories = on
		Settings.save()))
	lvb.add_child(UiFactory.check_row("显示敌方血量条", Settings.pvp_show_enemy_hp,
			CHECK_LABEL_W, func(on: bool) -> void:
		Settings.pvp_show_enemy_hp = on
		Settings.save()))
	lvb.add_child(UiFactory.check_row("打开小地图", Settings.pvp_show_minimap,
			CHECK_LABEL_W, func(on: bool) -> void:
		Settings.pvp_show_minimap = on
		Settings.save()))
	lvb.add_child(UiFactory.check_row("小地图显示敌方位置", Settings.pvp_minimap_show_enemy,
			CHECK_LABEL_W, func(on: bool) -> void:
		Settings.pvp_minimap_show_enemy = on
		Settings.save()))

	# ── 右栏:按键映射 ──
	# ★ 键位表从"挤在左列"搬到这里(用户批准的两栏版式)。列数 4 → **2**:
	#   两栏并排后每栏只有半屏宽,一行两对(名称,键位)会超出(实测最小宽 1862 > 页面 1768);
	#   一行一对则宽绰,且纵向空间本来就够(1440 高的设计稿)。
	var rvb := _column(cols)
	rvb.add_child(_section("按键映射(点击后按新键;Esc 取消)"))
	var grid := GridContainer.new()
	grid.columns = 2   # (名称,键位) 一行一对
	grid.add_theme_constant_override("h_separation", 18)
	# 11 行的行距 12 会把整页顶出屏幕(见 BLOCK_GAP 那条注释)。6 是行距,**不是**内边距:
	# 每个键位按钮自己有 20px 的上下内边距,行与行之间不会挤。
	grid.add_theme_constant_override("v_separation", 6)
	rvb.add_child(grid)
	for action in Settings.REMAPPABLE_ACTIONS:
		var name_l := UiFactory.label(ACTION_NAMES.get(action, action), 32)
		name_l.custom_minimum_size = Vector2(200, 0)
		grid.add_child(name_l)
		# 键位按钮是网格单元(不是主菜单按钮列),尺寸经 min_size 传工厂。
		# ★ 高度 40 会被 `_btn_box` 的新内边距顶到 72(32 号字按钮的最低高度),
		#   `_bind_buttons` / 探针都按节点取,不按尺寸 —— 这里写 ROW_H 让源码与画面一致。
		# 按钮**撑满该列剩余宽度**(键位表读起来像一张两列表;空着右半边会显得没画完)。
		var bind_btn := UiFactory.button("", 32, Vector2(220, ROW_H))
		bind_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bind_btn.pressed.connect(func() -> void: _begin_capture(action, bind_btn))
		grid.add_child(bind_btn)
		_bind_buttons[action] = bind_btn
		_refresh_bind_label(action)

	# ── 底部动作 ──
	# 并排放在一行里:HBox 不会把子节点横向拉满(放进 VBox 才会)。
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", ACTION_GAP)
	# 「恢复默认键位」是**有破坏性**的动作(丢掉玩家自己绑的键)⇒ quiet 档;「返 回(Esc)」
	# 是本页的动作行里的主行动 ⇒ 常态档(primary)。
	var reset := UiFactory.button("恢复默认键位", 32, Vector2(360, ROW_H), "quiet")
	reset.pressed.connect(func() -> void:
		Sfx.play("ui")   # 点击音由各 handler 自己出(UiFactory.button 不代挂,防同帧双响)
		Settings.reset_bindings()
		for a in _bind_buttons:
			_refresh_bind_label(a))
	actions.add_child(reset)

	var back := UiFactory.button("返 回(Esc)", 32, Vector2(280, ROW_H))
	back.pressed.connect(_go_back)
	actions.add_child(back)
	outer.add_child(actions)


# 一栏 = 一块菜单面板(凿刻边)+ 它 `Body` 里的内容 VBox。
# ★★ 内容**必须**加在 `Body` 里 —— 只有 `Body` 承载 `menu_panel()` 的内边距;加在外层
#    等于 padding 完全失效、内容直接顶到外线上(画面上只表现为"挤",**不报错**)。
func _column(parent: Node) -> VBoxContainer:
	var panel := UiFactory.menu_panel()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", SECTION_GAP)
	(panel.get_node("Body") as Container).add_child(vb)
	return vb


# 分组标题 = 同款标题带(方向 B 的器物感;与两栏的面板边、按钮描边同一套语汇)。
# (原先「音量」与「主音量」同字号同颜色,读不出哪个是标题;现由标题带的底 + 金色区分。)
func _section(text: String) -> PanelContainer:
	return UiFactory.header_strip(text, 32)


# 本菜单是纯 UI(无世界、无大物理),普通切场景只会销毁一棵 Control 树;
# 反方向(游戏世界 → 菜单)才需要挂起式切换,见 Level0.safe_change_scene。
# ★★ 切场景**必须延迟到帧末**:`change_scene_to_file` 会**同步 memdelete** 当前场景,
#   同步切等于把还在调用栈上的本节点抽掉 —— 本函数有两条调用路径(ESC 的 `_unhandled_input`
#   与「返 回(Esc)」按钮的 `pressed` 信号),两条都在切换之后还会碰 `self`/`get_tree()`。
#   2026-10-01 用户报"设置界面按 ESC 崩溃",根因就是这条:ESC 那条路上紧接着调
#   `get_viewport()`(headless 实测报 `Cannot call method 'set_input_as_handled' on a null value`),
#   真机上是悬垂指针。守卫:`tests/probe/settings_esc_probe.gd`。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# ★ 顺序不能反:**先**标记事件已处理,**再**决定去向。
		#   `_go_back()` 之后本节点即被移出场景树,那时 `get_viewport()` 已经拿不到东西了。
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
# 标签列宽:取「本页最长的那个行标签」再留一档(最长的「显示子弹尾迹(所有子弹)」≈344px)。
# ★ 320 时那一行会把开关往右顶出去 ~24px,四个开关**不在同一列**上(而这类"看着只是不齐、
#   不报错"的版式问题没有任何守卫)—— 384 让四个开关与两条滑条在同一条竖线上。
const CHECK_LABEL_W := 384.0



