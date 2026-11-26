extends Control

# 选择 Beta 模式后进入联机大厅，所选模式随会话传递。

const CARDS := [
	{
		"mode": WorldSpec.ROYALE,
		"name": PvpSession.BETA_MODE_NAMES[WorldSpec.ROYALE],
		"tag": "Royale",
		"desc": "时间权柄下的大乱斗——每个人的时间各自流动。\n击杀、拆砖、造成伤害都能榨出时间颗粒,\n回溯带你脱离火线,加速让你先手。",
	},
	{
		"mode": WorldSpec.TEAM,
		"name": PvpSession.BETA_MODE_NAMES[WorldSpec.TEAM],
		"tag": "Team",
		"desc": "每队 %d 至 %d 人。回溯可以躲开伤害，\n消耗时间颗粒可以加速。" % [TeamRules.MIN_TEAM, TeamRules.MAX_TEAM],
	},
]

const CARD_MIN_W := UiDesign.SP_10 * 5 + UiDesign.SP_7

@onready var _cards_row: HBoxContainer = %CardsRow
@onready var _back: Button = %BackBtn


func _ready() -> void:
	for c in CARDS:
		_make_card(c)
	_back.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))


func _make_card(c: Dictionary) -> Control:
	var body := UiKit.card(_cards_row)
	var card := body.get_parent().get_parent().get_parent() as PanelContainer
	card.custom_minimum_size = Vector2(CARD_MIN_W, 0)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_enter_card(c))
	var outer := card.get_theme_stylebox("panel") as StyleBoxFlat
	if outer != null:
		# 复制主题样式盒，悬停描边只应用于当前卡片。
		var hot := outer.duplicate() as StyleBoxFlat
		hot.border_color = UiDesign.C_GOLD
		card.mouse_entered.connect(func() -> void:
			card.add_theme_stylebox_override("panel", hot)
			Sfx.play("ui"))
		card.mouse_exited.connect(func() -> void:
			card.remove_theme_stylebox_override("panel"))

	var tag_color: Color = UiDesign.C_MODE_ROYALE \
			if str(c["mode"]) == WorldSpec.ROYALE else UiDesign.C_MODE_TEAM

	var icon_box := VBoxContainer.new()
	icon_box.name = "IconBox"
	icon_box.add_theme_constant_override("separation", UiDesign.SP_1)
	body.add_child(icon_box)
	var dial := TextureRect.new()
	dial.texture = WatchHud.DIAL
	dial.custom_minimum_size = dial.texture.get_size()
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


func _ignore_mouse_recursive(node: Node) -> void:
	for ch in node.get_children():
		if ch is Control:
			(ch as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_mouse_recursive(ch)


func _enter_card(c: Dictionary) -> void:
	Sfx.play("ui")
	PvpSession.reset(true, str(c["mode"]))
	get_tree().change_scene_to_file("res://scenes/mp_lobby.tscn")
