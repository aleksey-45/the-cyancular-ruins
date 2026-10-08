extends Control

# 信息页面：展示版本提交记录、制作团队与特别鸣谢。
# 静态界面结构定义在 info_menu.tscn 中，本脚本负责动态文本装配与信号绑定。
#   这是计划接受的代价("编辑器里看不到动态行")。
#
# - 名单与致谢内容保持严格一致，tests/probe/info_page_probe 测试会对其进行核对校验。

# 制作团队与特别鸣谢名单
const DEV_TEAM := ["RoFtaCD", "KikuchiH", "Lord Nahiz Waugh", "siri2048",
	"ofbwyx", "Lycoris Max", "hsk"]
# 致谢三段:软件/素材(带许可或署名)与文学来源,中间空一档。
const CREDITS := [
	["Godot Engine", "MIT"],
	["GNU Unifont", "SIL OFL 1.1"],
	["Less Perfect DOS VGA", "Zeh Fernando / Laemeur"],
	# 外部技术支持与致谢名单
	["Deepseek", ""],
	["GLM", ""],
	["Thomas Stearns Eliot", ""],
	["Jorge Luis Borges", ""],
]

# 提交记录列表行宽限制与截断设置
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


# 标签控件构建辅助方法
func _mk_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"Small" if size == 16 else &"Body"
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _fill_commits() -> void:
	# 无法获取提交历史时的占位提示处理
	var entries := AppInfo.commit_log()
	if entries.is_empty():
		_commit_list.add_child(_commit_row("(读不到 git 历史:仓库不可用或未安装 git)",
				UiFactory.C_DANGER))
	# 提交记录行文本排版与省略设置
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


# 页面切换延迟至帧末执行
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# 优先标记已处理再执行页面跳转
		get_viewport().set_input_as_handled()
		_go_back()
