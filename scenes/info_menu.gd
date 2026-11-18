extends Control

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

func _ready() -> void:
	var page := UiFactory.page(self, "信息", 16)
	var columns := UiFactory.columns(page)
	var version := _section("版本信息", 10)
	UiFactory.column(columns, version, 1.25)
	version.add_child(UiFactory.label("当前版本　%s" % ProjectSettings.get_setting("application/config/release_prefix"), 32))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 300
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	version.add_child(scroll)
	var list: VBoxContainer = UiFactory.box(scroll, 8, true)
	list.custom_minimum_size.x = ROW_W

	var related: VBoxContainer = UiFactory.box(columns, 16, true)
	related.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var team := _related(related, "开发团队 / 特别感谢")
	for who in DEV_TEAM:
		team.add_child(UiFactory.label(who, 32))
	var credits := _related(related, "致谢")
	for pair in CREDITS:
		var right := str(pair[1])
		credits.add_child(UiFactory.label(str(pair[0]) if right.is_empty() else "%s　%s" % [pair[0], right],
				32, UiFactory.C_TEXT_DIM if right.is_empty() else UiFactory.C_TEXT))
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_child(actions)
	var back := UiFactory.menu_button("返回", Vector2(280, 72), &"BtnQuiet")
	actions.add_child(back)
	back.pressed.connect(_go_back)
	_fill_commits(list)

static func _section(title: String, spacing: int) -> VBoxContainer:
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", spacing)
	body.add_child(UiFactory.header_strip(title))
	return body

static func _related(parent: VBoxContainer, title: String) -> VBoxContainer:
	var body := _section(title, 16)
	var panel := UiFactory.framed(body)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	return body

func _fill_commits(list: VBoxContainer) -> void:
	var status := _commit_row("正在读取 GitHub 提交记录…", UiFactory.C_TEXT_DIM)
	list.add_child(status)
	var rows := await CommitHistory.fetch(self)
	if not is_inside_tree():
		return
	if rows.is_empty():
		status.text = "无法读取 GitHub 提交记录"
		status.add_theme_color_override("font_color", UiFactory.C_DANGER)
		return
	status.queue_free()
	for row in rows:
		list.add_child(_commit_row(row, UiFactory.C_TEXT))

func _commit_row(text: String, color: Color) -> Label:
	var row := UiFactory.label(text, 16, color)
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
