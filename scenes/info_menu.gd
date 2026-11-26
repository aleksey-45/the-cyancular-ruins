extends Control

# 信息页显示版本、提交记录、开发团队与致谢。

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

@onready var _version: Label = %VersionLabel
@onready var _commit_list: VBoxContainer = %CommitList
@onready var _team_box: VBoxContainer = %TeamBox
@onready var _credits_box: VBoxContainer = %CreditsBox
@onready var _back: Button = %BackBtn


func _ready() -> void:
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


func _fill_commits() -> void:
	# 加载提示占用提交列表的一行。请求失败时在原处显示错误。
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


# 按滚动区域的宽度显示提交记录，超长文字用省略号截断。
func _commit_row(text: String, color: Color) -> Label:
	var row := UiDesign.label(text, UiDesign.T_SUB, color)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.clip_text = true
	row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return row


# 延迟切换场景，让当前输入回调先完成。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_go_back()
