extends Control

# Beta 页(设计系统 v1 / M4):容器优先,零绝对坐标;版式 = UiKit.page → 标题/说明 → 居中卡片行 → 返回。
# ★ 颜色/字号/间距只引 UiFactory 的 token;卡片 = UiKit.card(Card 变体 + H2 标题),不再手拼
#   PanelCarved / HeaderStrip 旧变体;hover 只改主题 StyleBox 的描边色(动态状态色,契约允许)。
# ★ 保留:全部文本与顺序(错乱大乱斗 / 时空对抗 / Royale / Team / beta_0.0 …)、%CardsRow / %BackBtn、
#   CARDS 数据形状与 _enter_card 的进入流程(PvpSession 状态 + 目标场景)。

const CARDS := [
	{
		"mode": PvpSession.MODE_ROYALE,
		"scene": "res://scenes/mp_lobby.tscn",
		"name": "错乱大乱斗",
		"tag": "Royale",
		"desc": "时间权柄下的大乱斗——每个人的时间各自流动。\n击杀、拆砖、造成伤害都能榨出时间颗粒,\n回溯带你脱离火线,加速让你先手。",
		"version": "beta_0.0",
	},
	{
		"mode": PvpSession.MODE_TEAM,
		"scene": "res://scenes/mp_lobby.tscn",
		"name": "时空对抗",
		"tag": "Team",
		"desc": "三人一队的时间战场——回溯免伤脱离危险,\n加速三倍抢先手;队伍与时间同样重要。",
		"version": "beta_0.0",
	},
]

# 卡片最小宽度:SP_10 × 5 + SP_7 = 440(与旧卡同宽;内容驱动下限,描述行靠 autowrap 换行,不写死行高)。
const CARD_MIN_W := UiFactory.SP_10 * 5 + UiFactory.SP_7

var _cards_row: HBoxContainer = null
var _back: Button = null


func _ready() -> void:
	_build_ui()
	for c in CARDS:
		_make_card(c)   # UiKit.card 已把卡片挂到 CardsRow,这里不再 add_child
	_back.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	_claim_owner(self)


# 运行时建的节点要能被 `%Name` 解析(外部/autotest 可能按 unique name 找):补 owner。
func _claim_owner(n: Node) -> void:
	for c in n.get_children():
		c.owner = self
		_claim_owner(c)


# 页面骨架:背景 + Margin(SP_6)→VBox(SP_5)→ 标题 / 说明 / 卡片行 / 弹性空段 / 返回。
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.name = "Bg"
	bg.color = UiFactory.C_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var page := UiKit.page(self)
	var title := UiFactory.label("—— Beta ——", UiFactory.T_H1, UiFactory.C_GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(title)

	var subtitle := UiFactory.label("实验性玩法都在这里;规则可能与正式模式不同",
			UiFactory.T_BODY, UiFactory.C_TEXT_DIM)
	page.add_child(subtitle)

	_cards_row = HBoxContainer.new()
	_cards_row.name = "CardsRow"
	_cards_row.unique_name_in_owner = true
	_cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards_row.add_theme_constant_override("separation", UiFactory.SP_5)
	page.add_child(_cards_row)

	var spacer := Control.new()
	spacer.name = "Spacer"
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(spacer)

	var footer := HBoxContainer.new()
	footer.name = "Footer"
	page.add_child(footer)
	_back = UiFactory.ui_button("返 回", UiFactory.T_H2, Vector2.ZERO, "quiet")
	_back.name = "BackBtn"
	_back.unique_name_in_owner = true
	footer.add_child(_back)


# 单张 beta 卡:可点整卡进入;Card 皮肤来自 Theme,只有 hover 描边色在代码里动态改(允许的状态色)。
func _make_card(c: Dictionary) -> Control:
	var body := UiKit.card(_cards_row)
	var card := _card_frame(body)
	card.custom_minimum_size = Vector2(CARD_MIN_W, 0)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_enter_card(c))
	var outer := card.get_theme_stylebox("panel") as StyleBoxFlat
	if outer != null:
		var hot := outer.duplicate() as StyleBoxFlat
		hot.border_color = UiFactory.C_GOLD
		card.mouse_entered.connect(func() -> void:
			card.add_theme_stylebox_override("panel", hot)
			Sfx.play("ui"))
		card.mouse_exited.connect(func() -> void:
			card.remove_theme_stylebox_override("panel"))

	var tag_color: Color = UiFactory.C_MODE_ROYALE \
			if str(c["mode"]) == PvpSession.MODE_ROYALE else UiFactory.C_MODE_TEAM

	var icon_box := VBoxContainer.new()
	icon_box.name = "IconBox"
	icon_box.add_theme_constant_override("separation", UiFactory.SP_1)
	body.add_child(icon_box)
	var dial := TextureRect.new()
	dial.texture = WatchHud.build_dial_texture()
	dial.custom_minimum_size = dial.texture.get_size()   # 内容驱动:表盘纹理原尺寸
	dial.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dial.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	dial.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon_box.add_child(dial)
	var tag := UiFactory.label(str(c["tag"]), UiFactory.T_H2, tag_color)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_box.add_child(tag)

	var card_title := UiFactory.ui_label(str(c["name"]), "h2")
	card_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(card_title)

	var desc := UiFactory.label(str(c["desc"]), UiFactory.T_BODY, UiFactory.C_TEXT_DIM)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(desc)

	var ver := UiFactory.label(str(c["version"]), UiFactory.T_BODY, UiFactory.C_TEXT_DIM)
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(ver)

	_ignore_mouse_recursive(card)
	return card


# UiKit.card 返回的是 body;骨架 = Card(PanelContainer)→Margin→VBox→Body。
func _card_frame(body: VBoxContainer) -> PanelContainer:
	return body.get_parent().get_parent().get_parent() as PanelContainer


func _ignore_mouse_recursive(node: Node) -> void:
	for ch in node.get_children():
		if ch is Control:
			(ch as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_mouse_recursive(ch)


func _enter_card(c: Dictionary) -> void:
	Sfx.play("ui")
	PvpSession.reset()
	PvpSession.beta_mode = true
	PvpSession.entry_mode = str(c["mode"])
	get_tree().change_scene_to_file(str(c["scene"]))
