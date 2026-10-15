extends Control

# 信息整页:三块 = 版本信息(AppInfo)/ 开发团队 / 致谢。
# 静态骨架在 info_menu.tscn 里(见 tools/gen_menu_scene.gd),本脚本只灌动态文本 + 接信号,样式走 menu_theme.tres 的 theme_type_variation;三块内容区(CommitList / TeamBox / CreditsBox)在骨架里是空的 —— 行由本脚本填,编辑器里看不到动态行。
# ★ 名单与致谢是用户给定、逐字照抄:别改写措辞、别补全称、别加版本号、别调次序。零守卫(info_page_probe 已删·2026-10-09)。

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

# ★ ROW_W 必须小于左栏可见内宽,否则 ScrollContainer 照出横向滚动条而省略号落在可视区之外(比不钉更糟);实测 1920 宽、边距 76、两栏 1.25:1 ⇒ 左栏内宽约 850,取 760 留余量。
const ROW_W := 760.0

@onready var _version: Label = %VersionLabel
@onready var _commit_list: VBoxContainer = %CommitList
@onready var _team_box: VBoxContainer = %TeamBox
@onready var _credits_box: VBoxContainer = %CreditsBox


func _ready() -> void:
	_version.text = "当前版本　%s" % AppInfo.version_string()
	_fill_commits()
	for who in DEV_TEAM:
		_team_box.add_child(_mk_label(who, 32, UiFactory.C_WHITE))
	for pair in CREDITS:
		var right := str(pair[1])
		_credits_box.add_child(_mk_label(
				str(pair[0]) if right == "" else "%s　%s" % [str(pair[0]), right],
				32, UiFactory.C_TEXT if right != "" else UiFactory.C_TEXT_DIM))
	%BackBtn.pressed.connect(_go_back)


# 行标签的共用形状,三处细节漏一个就静默变样:字号决定变体(16 用 Small,32 用 Body)、字色必须显式给(默认纯白与 C_TEXT 差 0.122)、mouse_filter = IGNORE(漏了会吃掉滚轮与点击)。
# ★ 形参与 UiFactory.label(text, size, color) 同序 —— 本函数就是它的替身,同序才不会在改写调用点时把 (size, color) 写反。
func _mk_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"Small" if size == 16 else &"Body"
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


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


func _commit_row(text: String, color: Color) -> Label:
	var row := _mk_label(text, 16, color)
	row.custom_minimum_size = Vector2(ROW_W, 0)
	row.size_flags_horizontal = Control.SIZE_FILL
	row.clip_text = true
	row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return row


# ★ 切场景必须延迟到帧末:change_scene_to_file 会同步 memdelete 当前场景,而本函数两条调用路径(ESC 与返回按钮)在切换之后还会碰 self/get_tree()。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# ★ 顺序不能反:先标记已处理,再决定去向(切换之后本节点已被移出树)。
		get_viewport().set_input_as_handled()
		_go_back()
