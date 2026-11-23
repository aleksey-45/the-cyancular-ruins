extends Control

# 信息页(设计系统 v2):结构从 main 的 scenes/info_menu.gd 迁移 —— 容器优先、零绝对坐标,
# 版式 = UiKit.page → 两栏 UiKit.card;标题/空态/致谢行只用 UiDesign 的 token 与 variation。
# ★ 保留 siri 内容与行为:开发团队/致谢原文、版本行读 release_prefix、GitHub 提交记录异步拉取
#   (CommitHistory.fetch)、读不到时的兜底文案与 C_DANGER 配色、返回主菜单与 Esc 行为。
# ★ 保留 main 的五个 unique name(%VersionLabel / %CommitList / %TeamBox / %CreditsBox / %BackBtn),
#   运行时建的节点在末尾补 owner,`%Name` 才能解析。

const DEV_TEAM := ["RoFtaCD", "KikuchiH", "Lord Nahiz Waugh", "siri2048",
	"ofbwyx", "Lycoris Max", "hsk"]
const CREDITS := [
	["Godot Engine", "MIT"],
	["GNU Unifont", "SIL OFL 1.1"],
	["Less Perfect DOS VGA", "Zeh Fernando / Laemeur"],
	["Deepseek", ""],
	["GLM", ""],
	["Thomas Stearns Eliot", ""],
	["Jorge Luis Borges", ""],
]

var _version: Label = null
var _commit_list: VBoxContainer = null
var _team_box: VBoxContainer = null
var _credits_box: VBoxContainer = null
var _back: Button = null


func _ready() -> void:
	_build_ui()
	_version.text = "当前版本　%s v%s" % [ProjectSettings.get_setting("application/config/release_prefix"),
			ProjectSettings.get_setting("application/config/version")]
	_fill_commits()
	for who in DEV_TEAM:
		_team_box.add_child(UiDesign.label(who, UiDesign.T_H2, UiDesign.C_WHITE))
	for pair in CREDITS:
		var right := str(pair[1])
		_credits_box.add_child(UiDesign.label(
				str(pair[0]) if right == "" else "%s　%s" % [str(pair[0]), right],
				UiDesign.T_H2, UiDesign.C_TEXT if right != "" else UiDesign.C_TEXT_DIM))
	_back.pressed.connect(_go_back)
	_claim_owner(self)


# 运行时建的节点要能被 `%Name` 解析(外部/autotest 可能按 unique name 找):补 owner。
func _claim_owner(n: Node) -> void:
	for c in n.get_children():
		c.owner = self
		_claim_owner(c)


# 页面骨架:背景 + UiKit.page(Margin SP_6 → VBox SP_5)→ 标题 / 两栏 / 返回。
# 左栏版本卡片吃掉剩余高度(提交列表滚动),右栏团队/致谢两张卡片按内容排。
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.name = "Bg"
	bg.color = UiDesign.C_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var page := UiKit.page(self)
	var title := UiDesign.label("信息", UiDesign.T_H1, UiDesign.C_GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(title)

	var columns := HBoxContainer.new()
	columns.name = "Columns"
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", UiDesign.SP_5)
	page.add_child(columns)

	var left := VBoxContainer.new()
	left.name = "Left"
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.25
	left.add_theme_constant_override("separation", UiDesign.SP_4)
	columns.add_child(left)
	var right := VBoxContainer.new()
	right.name = "Right"
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", UiDesign.SP_4)
	columns.add_child(right)

	# ── 左栏:版本 + 提交历史(唯一吃高度的一栏)──
	var version_card := UiKit.card(left, "版本信息")
	_card_frame(version_card).size_flags_vertical = Control.SIZE_EXPAND_FILL
	version_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_version = UiDesign.label("", UiDesign.T_H2, UiDesign.C_WHITE)
	_version.name = "VersionLabel"
	_version.unique_name_in_owner = true
	version_card.add_child(_version)
	var scroll := ScrollContainer.new()
	scroll.name = "CommitScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	version_card.add_child(scroll)
	_commit_list = VBoxContainer.new()
	_commit_list.name = "CommitList"
	_commit_list.unique_name_in_owner = true
	_commit_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_commit_list.add_theme_constant_override("separation", UiDesign.SP_2)
	scroll.add_child(_commit_list)

	# ── 右栏:团队 / 致谢(按内容排,不抢高度)──
	var team_card := UiKit.card(right, "开发团队 / 特别感谢")
	_team_box = VBoxContainer.new()
	_team_box.name = "TeamBox"
	_team_box.unique_name_in_owner = true
	_team_box.add_theme_constant_override("separation", UiDesign.SP_4)
	team_card.add_child(_team_box)
	var credits_card := UiKit.card(right, "致谢")
	_credits_box = VBoxContainer.new()
	_credits_box.name = "CreditsBox"
	_credits_box.unique_name_in_owner = true
	_credits_box.add_theme_constant_override("separation", UiDesign.SP_4)
	credits_card.add_child(_credits_box)

	var footer := HBoxContainer.new()
	footer.name = "Footer"
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_child(footer)
	_back = UiDesign.ui_button("返回", UiDesign.T_H2, Vector2.ZERO, "quiet")
	_back.name = "BackBtn"
	_back.unique_name_in_owner = true
	footer.add_child(_back)


# UiKit.card 返回的是 body;骨架 = Card(PanelContainer)→Margin→VBox→Body,
# 需要给卡片本体设 size_flags 时往上三层拿(版式参数,不是样式)。
func _card_frame(body: VBoxContainer) -> PanelContainer:
	return body.get_parent().get_parent().get_parent() as PanelContainer


func _fill_commits() -> void:
	# siri 的提交历史来自 GitHub(异步);未返回前先占一行状态,失败沿用 siri 的兜底文案与 C_DANGER。
	var status := _commit_row("正在读取 GitHub 提交记录…", UiDesign.C_TEXT_DIM)
	_commit_list.add_child(status)
	var rows := await CommitHistory.fetch(self)
	if not is_inside_tree():
		return
	if rows.is_empty():
		status.text = "无法读取 GitHub 提交记录"
		status.add_theme_color_override("font_color", UiDesign.C_DANGER)
		return
	status.queue_free()
	for row in rows:
		_commit_list.add_child(_commit_row(row, UiDesign.C_TEXT))


# 提交行:16 号正文、宽度由滚动区决定,超长省略号截断。
func _commit_row(text: String, color: Color) -> Label:
	var row := UiDesign.label(text, UiDesign.T_SUB, color)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.clip_text = true
	row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return row


# 返回主菜单的操作延迟执行,使本次输入回调能够先结束。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_go_back()
