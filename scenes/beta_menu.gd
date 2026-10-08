extends Control

# Beta 实验性玩法入口页面。
# 包含当前各实验性玩法入口卡片，卡片图标由程序化生成。
# 页面基础布局定义在 beta_menu.tscn 中，卡片列表由本脚本动态装配并绑定信号。

const CARDS := [
	{
		"mode": PvpSession.MODE_ROYALE,
		"scene": "res://scenes/mp_lobby.tscn",
		"name": "错乱大乱斗",
		"tag": "Royale",
		"tag_color": Color(0.92, 0.28, 0.24),
		"desc": "时间权柄下的大乱斗——每个人的时间各自流动。\n击杀、拆砖、造成伤害都能榨出时间颗粒,\n回溯带你脱离火线,加速让你先手。",
		"version": "beta_0.0",
	},
	{
		"mode": PvpSession.MODE_TEAM,
		"scene": "res://scenes/mp_lobby.tscn",
		"name": "时空 3v3",
		"tag": "Team",
		"tag_color": Color(0.30, 0.55, 0.95),
		"desc": "三人一队的时间战场——回溯免伤脱离危险,\n加速三倍抢先手;队伍与时间同样重要。",
		"version": "beta_0.0",
	},
]

const CARD_W := 440.0        # 卡片宽度(两张 + 间距远小于页面宽)
const CARD_PAD := Vector2(28, 24)   # 卡内边距(卡比整页面板窄,故不取 64/46 那一档)

@onready var _cards_row: HBoxContainer = %CardsRow


func _ready() -> void:
	for c in CARDS:
		_cards_row.add_child(_make_card(c))
	%BackBtn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))


# 构建卡片容器面板，设置内边距与子控件鼠标事件穿透
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_enter_card(c))
	# hover:外线转金(内亮线不动 —— 凿刻感保留)。duplicate() 免得改到共享样式。
	var outer := card.get_theme_stylebox("panel") as StyleBoxFlat
	var hot := outer.duplicate() as StyleBoxFlat
	hot.border_color = UiFactory.C_GOLD
	card.mouse_entered.connect(func() -> void:
		card.add_theme_stylebox_override("panel", hot)
		Sfx.play("ui"))
	card.mouse_exited.connect(func() -> void:
		card.add_theme_stylebox_override("panel", outer))

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	(card.get_node("Body") as Container).add_child(vb)

	# 画框(图标):程序化怀表 + 下方模式字样(红 Royale / 蓝 Team)
	var icon_box := VBoxContainer.new()
	icon_box.add_theme_constant_override("separation", 2)
	vb.add_child(icon_box)
	var dial := TextureRect.new()
	dial.texture = WatchHud.build_dial_texture()
	dial.custom_minimum_size = Vector2(196, 196)
	dial.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dial.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	dial.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon_box.add_child(dial)
	var tag := UiFactory.label(str(c["tag"]), 32, c["tag_color"])
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_box.add_child(tag)

	# 卡内标题 = 相同标题栏(与页面标题、区块标题保持统一视觉风格)。
	vb.add_child(UiFactory.header_strip(str(c["name"]), 32))

	var desc := UiFactory.label(str(c["desc"]), 16, UiFactory.C_TEXT_DIM)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(desc)

	var ver := UiFactory.label(str(c["version"]), 16, Color(0.55, 0.75, 0.6))
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(ver)

	_ignore_mouse_recursive(card)
	return card


# 把整棵内容子树设成 MOUSE_FILTER_IGNORE(只留外层卡吃点击)—— 点击/悬停的单一落点。
func _ignore_mouse_recursive(node: Node) -> void:
	for ch in node.get_children():
		if ch is Control:
			(ch as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_mouse_recursive(ch)


## 进入某张卡的模式(点击与 autotest 共用同一入口;CARDS[i] 传整张卡的字典)。
func _enter_card(c: Dictionary) -> void:
	Sfx.play("ui")
	PvpSession.reset()
	PvpSession.beta_mode = true
	# 设置大厅预选筛选模式并跳转至大厅
	PvpSession.entry_mode = str(c["mode"])
	get_tree().change_scene_to_file(str(c["scene"]))
