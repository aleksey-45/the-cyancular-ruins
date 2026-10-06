extends Control

# Beta 模式入口界面（实验性玩法统一由此进入）。
# 界面构成：主标题 + 返回按钮 + 若干卡片式选项（表盘图标 + 模式名称 + 规则介绍 + 版本标识）。
# 当前支持两种模式（PvP 时间玩法）：
#   · 错乱大乱斗（图标为怀表表盘 + 红色 Royale 标识）→ 进入大乱斗大厅（Beta 状态）
#   · 时空 3v3（图标为怀表表盘 + 蓝色 Team 标识）→ 进入 3v3 大厅（Beta 状态）
# 卡片图标通过程序化绘制生成（复用 WatchHud.build_dial_texture，无需额外图片资源）。
#
# 模式状态传递说明：PvpSession.enter_mode() 会重置状态（beta_mode = false），
# 因此先执行 enter_mode 后设置 beta_mode = true，再切换至大厅场景。

const CARDS := [
	{
		"mode": PvpSession.MODE_ROYALE,
		"scene": "res://scenes/royale_lobby.tscn",
		"name": "错乱大乱斗",
		"tag": "Royale",
		"tag_color": Color(0.92, 0.28, 0.24),
		"desc": "融入时间控制机制的大乱斗——每位玩家独立掌控时间流动。\\n击杀对手、破坏瓦片、造成伤害均可获取时间粒子,\\n时空回溯助你规避伤害,时间加速助你抢占先机。",
		"version": "beta_0.0",
	},
	{
		"mode": PvpSession.MODE_TEAM,
		"scene": "res://scenes/team_lobby.tscn",
		"name": "时空 3v3",
		"tag": "Team",
		"tag_color": Color(0.30, 0.55, 0.95),
		"desc": "三人成队的团队时空战场——回溯免伤脱离危险,\\n三倍加速抢占先手;团队协作与时间掌控同样重要。",
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
	PvpSession.enter_mode(str(c["mode"]))
	PvpSession.beta_mode = true
	get_tree().change_scene_to_file(str(c["scene"]))


static func _card_style(border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.10, 0.14)
	sb.border_color = border
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(18)
	return sb
