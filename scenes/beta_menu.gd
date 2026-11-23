extends Control

# Beta 页(设计系统 v2):结构从 main 的 scenes/beta_menu.gd 迁移 —— 容器优先、零绝对坐标;
# 版式 = UiKit.page → 标题/说明 → 居中卡片行 → 弹性空段 → 返回。
# ★ 卡片 = UiKit.card(Card variation + H2 标题),皮肤全在 Theme 2.0;hover 只改主题 StyleBox 的
#   描边色(动态状态色,契约允许),不再手拼 PanelCarved / HeaderStrip。
# ★ 保留 siri 内容与进入流程:两种 Beta 模式名取 PvpSession.BETA_MODE_NAMES、原文描述/tag/beta_0.0、
#   %CardsRow / %BackBtn、_enter_card 的 PvpSession.reset(true, mode) 与 mp_lobby 目标场景。

const CARDS := [
	{
		"mode": PvpSession.MODE_ROYALE,
		"name": PvpSession.BETA_MODE_NAMES[PvpSession.MODE_ROYALE],
		"tag": "Royale",
		"desc": "时间权柄下的大乱斗——每个人的时间各自流动。\n击杀、拆砖、造成伤害都能榨出时间颗粒,\n回溯带你脱离火线,加速让你先手。",
	},
	{
		"mode": PvpSession.MODE_TEAM,
		"name": PvpSession.BETA_MODE_NAMES[PvpSession.MODE_TEAM],
		"tag": "Team",
		"desc": "三人一队的时间战场——回溯免伤脱离危险,\n消耗时间颗粒加速抢先手;队伍与时间同样重要。",
	},
]

# 卡片最小宽度:SP_10 × 5 + SP_7 = 440(与旧卡同宽;内容驱动下限,描述行靠 autowrap 换行)。
const CARD_MIN_W := UiDesign.SP_10 * 5 + UiDesign.SP_7

var _cards_row: HBoxContainer = null
var _back: Button = null


func _ready() -> void:
	_build_ui()
	for c in CARDS:
		_make_card(c)
	_back.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	_claim_owner(self)


# 运行时建的节点要能被 `%Name` 解析(外部/autotest 可能按 unique name 找):补 owner。
func _claim_owner(n: Node) -> void:
	for c in n.get_children():
		c.owner = self
		_claim_owner(c)


# 页面骨架:背景 + UiKit.page → 标题 / 说明 / 卡片行 / 弹性空段 / 返回。
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.name = "Bg"
	bg.color = UiDesign.C_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var page := UiKit.page(self)
	var title := UiDesign.label("—— Beta ——", UiDesign.T_H1, UiDesign.C_GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(title)

	var subtitle := UiDesign.label("实验性玩法都在这里;规则可能与正式模式不同",
			UiDesign.T_SMALL, UiDesign.C_TEXT_DIM)
	page.add_child(subtitle)

	_cards_row = HBoxContainer.new()
	_cards_row.name = "CardsRow"
	_cards_row.unique_name_in_owner = true
	_cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards_row.add_theme_constant_override("separation", UiDesign.SP_5)
	page.add_child(_cards_row)

	var spacer := Control.new()
	spacer.name = "Spacer"
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.add_child(spacer)

	var footer := HBoxContainer.new()
	footer.name = "Footer"
	page.add_child(footer)
	_back = UiDesign.ui_button("返回", UiDesign.T_H2, Vector2.ZERO, "quiet")
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
		hot.border_color = UiDesign.C_GOLD
		card.mouse_entered.connect(func() -> void:
			card.add_theme_stylebox_override("panel", hot)
			Sfx.play("ui"))
		card.mouse_exited.connect(func() -> void:
			card.remove_theme_stylebox_override("panel"))

	var tag_color: Color = UiDesign.C_MODE_ROYALE \
			if str(c["mode"]) == PvpSession.MODE_ROYALE else UiDesign.C_MODE_TEAM

	var icon_box := VBoxContainer.new()
	icon_box.name = "IconBox"
	icon_box.add_theme_constant_override("separation", UiDesign.SP_1)
	body.add_child(icon_box)
	var dial := TextureRect.new()
	dial.texture = WatchHud.DIAL
	dial.custom_minimum_size = dial.texture.get_size()   # 内容驱动:表盘纹理原尺寸
	dial.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dial.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	dial.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon_box.add_child(dial)
	var tag := UiDesign.label(str(c["tag"]), UiDesign.T_H2, tag_color)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_box.add_child(tag)

	var card_title := UiDesign.ui_label(str(c["name"]), "h2")
	card_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(card_title)

	var desc := UiDesign.label(str(c["desc"]), UiDesign.T_SMALL, UiDesign.C_TEXT_DIM)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(desc)

	var ver := UiDesign.label("beta_0.0", UiDesign.T_SMALL, UiDesign.C_TEXT_DIM)
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
	PvpSession.reset(true, str(c["mode"]))
	get_tree().change_scene_to_file("res://scenes/mp_lobby.tscn")
