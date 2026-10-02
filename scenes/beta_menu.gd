extends Control

# Beta 入口页(2026-09-28,用户指定):以后所有实验性玩法都从这里进。
# 页面 = 标题 + 返回 + 若干「画框型选项」卡片(画框图标 + 模式名栏 + 简介栏 + 版本栏)。
# 当前两张卡(P2 线,PvP 时间玩法),2026-10-03 起都进**统一大厅** `mp_lobby`:
#   · 错乱大乱斗(图标 = 单机怀表 + 下方红色 Royale 字样)→ mp_lobby(beta 态,预选大乱斗筛选)
#   · 时空 3v3(图标 = 单机怀表 + 下方蓝色 Team 字样)→ mp_lobby(beta 态,预选 3v3 筛选)
# 卡片图标是**程序化生成**的(复用 WatchHud.build_dial_texture,不引入美术资源)。
#
# ★ beta 态怎么传给大厅页:PvpSession.reset() 会把 beta_mode 清成 false,
#   所以先 reset 再置 beta_mode = true,然后切场景 —— 大厅页在 _ready 里读它。
# ★ 预选的**筛选**模式走 `entry_mode`(不是凭据的 `room_mode`):大厅页 `_ready` 末尾按它
#   调 `_set_filter`,于是从 Beta 进来时列表已经筛在该模式上(直接进大厅时它是 "")。

const CARDS := [
	{
		"mode": PvpSession.MODE_ROYALE,
		"scene": "res://scenes/mp_lobby.tscn",
		"name": "错乱大乱斗",
		"tag": "Royale",
		"tag_color": Color(0.92, 0.28, 0.24),
		"desc": "时间权柄下的大乱斗——每个人的时间各自流动。\\n击杀、拆砖、造成伤害都能榨出时间颗粒,\\n回溯带你脱离火线,加速让你先手。",
		"version": "beta_0.0",
	},
	{
		"mode": PvpSession.MODE_TEAM,
		"scene": "res://scenes/mp_lobby.tscn",
		"name": "时空 3v3",
		"tag": "Team",
		"tag_color": Color(0.30, 0.55, 0.95),
		"desc": "三人一队的时间战场——回溯免伤脱离危险,\\n加速三倍抢先手;队伍与时间同样重要。",
		"version": "beta_0.0",
	},
]


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var title := UiFactory.label("—— Beta ——", 48, UiFactory.C_ACCENT)
	title.position = Vector2(80, 48)
	root.add_child(title)
	var hint := UiFactory.label("实验性玩法都在这里;规则可能与正式模式不同", 16, UiFactory.C_TEXT_DIM)
	hint.position = Vector2(84, 108)
	root.add_child(hint)

	var back := UiFactory.button("返 回", 32, Vector2(240, 56))
	back.position = Vector2(80, get_viewport_rect().size.y - 120.0)
	back.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	root.add_child(back)

	var row := HBoxContainer.new()
	row.position = Vector2(80, 190)
	row.add_theme_constant_override("separation", 36)
	root.add_child(row)
	for c in CARDS:
		row.add_child(_make_card(c))


# 画框型选项 = 画框(图标)+ 模式名栏 + 简介栏 + 版本栏。整卡可点,hover 提亮。
func _make_card(c: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(400, 430)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.add_theme_stylebox_override("panel", _card_style(UiFactory.C_ACCENT))
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed 				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_enter_card(c))
	card.mouse_entered.connect(func() -> void:
		card.add_theme_stylebox_override("panel", _card_style(Color(1.0, 0.85, 0.3)))
		Sfx.play("ui"))
	card.mouse_exited.connect(func() -> void:
		card.add_theme_stylebox_override("panel", _card_style(UiFactory.C_ACCENT)))

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	card.add_child(vb)

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

	var name_l := UiFactory.label(str(c["name"]), 48)
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(name_l)

	var desc := UiFactory.label(str(c["desc"]), 16, UiFactory.C_TEXT_DIM)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(desc)

	var ver := UiFactory.label(str(c["version"]), 16, Color(0.55, 0.75, 0.6))
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(ver)
	return card


## 进入某张卡的模式(点击与 autotest 共用同一入口;CARDS[i] 传整张卡的字典)。
func _enter_card(c: Dictionary) -> void:
	Sfx.play("ui")
	PvpSession.reset()
	PvpSession.beta_mode = true
	# ★ 预选**筛选**模式(不是凭据的模式):大厅页 `_ready` 末尾读它调 `_set_filter`。
	#   `CARDS[i]["mode"]` 不是死字段 —— 从 2026-10-03 起它重新有读者,就是这一行。
	PvpSession.entry_mode = str(c["mode"])
	get_tree().change_scene_to_file(str(c["scene"]))


static func _card_style(border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.10, 0.14)
	sb.border_color = border
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(18)
	return sb
