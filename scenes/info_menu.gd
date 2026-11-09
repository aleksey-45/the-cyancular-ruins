extends Control

# 信息页(设计系统 v1 / M4):容器优先,零绝对坐标;版式 = UiKit.page → 两栏 Card。
# ★ 颜色/字号/间距只引 UiFactory 的 token;分区标题 = UiKit.card 的 H2,不再手拼 PanelCarved / HeaderStrip
#   (旧变体只留给未迁移页面)。
# ★ 保留:全部文本与顺序、%VersionLabel / %CommitList / %TeamBox / %CreditsBox / %BackBtn 五个 unique name、
#   _go_back 返回路径与 Esc 行为、AppInfo 读不到 git 时的兜底文案与 C_DANGER 配色。

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
	_version.text = "当前版本　%s" % AppInfo.version_string()
	_fill_commits()
	for who in DEV_TEAM:
		_team_box.add_child(UiFactory.label(who, UiFactory.T_H2, UiFactory.C_WHITE))
	for pair in CREDITS:
		var right := str(pair[1])
		_credits_box.add_child(UiFactory.label(
				str(pair[0]) if right == "" else "%s　%s" % [str(pair[0]), right],
				UiFactory.T_H2, UiFactory.C_TEXT if right != "" else UiFactory.C_TEXT_DIM))
	_back.pressed.connect(_go_back)
	_claim_owner(self)


# 运行时建的节点要能被 `%Name` 解析(外部/autotest 可能按 unique name 找):补 owner。
func _claim_owner(n: Node) -> void:
	for c in n.get_children():
		c.owner = self
		_claim_owner(c)


# 页面骨架:背景 + Margin(SP_6)→VBox(SP_5)→ 标题 / 两栏 / 返回。
# 两栏都是内容驱动:左栏版本卡片吃掉剩余高度(提交列表滚动),右栏团队/致谢两张卡片按内容排。
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.name = "Bg"
	bg.color = UiFactory.C_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var page := UiKit.page(self)
	var title := UiFactory.label("信 息", UiFactory.T_H1, UiFactory.C_GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(title)

	var columns := HBoxContainer.new()
	columns.name = "Columns"
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", UiFactory.SP_5)
	page.add_child(columns)

	var left := VBoxContainer.new()
	left.name = "Left"
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.25
	left.add_theme_constant_override("separation", UiFactory.SP_4)
	columns.add_child(left)
	var right := VBoxContainer.new()
	right.name = "Right"
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", UiFactory.SP_4)
	columns.add_child(right)

	# ── 左栏:版本 + 提交历史(唯一吃高度的一栏)──
	var version_card := UiKit.card(left, "版 本 信 息")
	_card_frame(version_card).size_flags_vertical = Control.SIZE_EXPAND_FILL
	version_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_version = UiFactory.label("", UiFactory.T_H2, UiFactory.C_WHITE)
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
	_commit_list.add_theme_constant_override("separation", UiFactory.SP_2)
	scroll.add_child(_commit_list)

	# ── 右栏:团队 / 致谢(按内容排,不抢高度)──
	var team_card := UiKit.card(right, "开 发 团 队 / 特 别 感 谢")
	_team_box = VBoxContainer.new()
	_team_box.name = "TeamBox"
	_team_box.unique_name_in_owner = true
	_team_box.add_theme_constant_override("separation", UiFactory.SP_4)
	team_card.add_child(_team_box)
	var credits_card := UiKit.card(right, "致 谢")
	_credits_box = VBoxContainer.new()
	_credits_box.name = "CreditsBox"
	_credits_box.unique_name_in_owner = true
	_credits_box.add_theme_constant_override("separation", UiFactory.SP_4)
	credits_card.add_child(_credits_box)

	var footer := HBoxContainer.new()
	footer.name = "Footer"
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_child(footer)
	_back = UiFactory.ui_button("返 回", UiFactory.T_H2, Vector2.ZERO, "quiet")
	_back.name = "BackBtn"
	_back.unique_name_in_owner = true
	footer.add_child(_back)


# UiKit.card 返回的是 body;骨架 = Card(PanelContainer)→Margin→VBox→Body,
# 需要给卡片本体设 size_flags 时往上三层拿(版式参数,不是样式)。
func _card_frame(body: VBoxContainer) -> PanelContainer:
	return body.get_parent().get_parent().get_parent() as PanelContainer


func _fill_commits() -> void:
	# ★ 空历史兜底:发布版常跑在没有 git 的机器上,那时 AppInfo.commit_log() 返回 [] ⇒ 左栏会是个没有解释的空框,而解释正是本页存在的理由;文案沿用 main_menu._fill_version_panel 那一句,别改写措辞。
	# ★ 颜色取 C_DANGER 而不是 C_TEXT_DIM:它表的是「读不到」这一异常,而 C_TEXT_DIM 在本页已被两条无许可的致谢占用,且旧字面量本就是暖色。
	var entries := AppInfo.commit_log()
	if entries.is_empty():
		_commit_list.add_child(_commit_row("(读不到 git 历史:仓库不可用或未安装 git)",
				UiFactory.C_DANGER))
	for e in entries:
		_commit_list.add_child(_commit_row("%s  %s  %s" % [str(e["hash"]), str(e["time"]),
				str(e["subject"])], UiFactory.C_TEXT))


# 提交行:16 号正文、宽度由滚动区决定(不再钉 ROW_W 固定宽),超长省略号截断。
func _commit_row(text: String, color: Color) -> Label:
	var row := UiFactory.label(text, UiFactory.T_BODY, color)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.clip_text = true
	row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return row


func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_go_back()
