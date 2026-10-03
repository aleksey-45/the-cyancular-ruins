extends Control

# 「信 息」整页(2026-10-03,取代主菜单上的版本信息弹层)。
# 三块:版本信息(AppInfo) / 开发团队 / 致谢。场景是裸 Control,UI 全在代码里建;
# 控件一律走 UiFactory(像素字体与字号规范的单一来源),字号必须是 16 的倍数。
#
# ★ 名单与致谢是**用户给定、逐字照抄**的 —— 别顺手改写、别补全称、别调次序。
#   `tests/probe/info_page_probe` 把它们逐字钉住了。

const DEV_TEAM := ["RoFtaCD", "KikuchiH", "Lord Nahiz Waugh", "siri2048"]
# 致谢三段:软件/素材(带许可或署名)与文学来源,中间空一档。
const CREDITS := [
	["Godot Engine", "MIT"],
	["GNU Unifont", "SIL OFL 1.1"],
	["Less Perfect DOS VGA", "Zeh Fernando / Laemeur"],
	["Thomas Stearns Eliot", ""],
	["Jorge Luis Borges", ""],
]

# 提交行的固定宽度(见 `_fill_version_block` 里"钉死行宽"那段)。
const ROW_W := 900.0


func _ready() -> void:
	# 不透明深色底:进过单机后全局清屏色是浅蓝,白字会看不清(与 settings_menu 同一形态)。
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var vb := VBoxContainer.new()
	vb.position = Vector2(60, 40)
	vb.custom_minimum_size = Vector2(1800, 0)
	vb.add_theme_constant_override("separation", 20)
	add_child(vb)
	vb.add_child(UiFactory.label("信 息", 48, UiFactory.C_ACCENT))

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 30)
	vb.add_child(cols)
	_fill_version_block(cols)
	_fill_right_blocks(cols)

	var back_row := HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	var back := UiFactory.button("返 回", 32, Vector2(280, 48))
	back.pressed.connect(_go_back)
	back_row.add_child(back)
	vb.add_child(back_row)


func _fill_version_block(parent: Node) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiFactory.panel_box())
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# ★ 2026-10-03:简报的 `_fill_version_block` 漏了这一行(整块左栏从不入树)。
	#   后果是"版本信息"这一栏**一点都看不见**,而且只有本探针会红 ——
	#   右栏(`_fill_right_blocks`)有对应的 `parent.add_child(col)`,两栏的形状本该对称。
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	box.add_child(UiFactory.label("版 本 信 息", 32, UiFactory.C_ACCENT))
	box.add_child(UiFactory.label("当前版本　%s" % AppInfo.version_string(), 32))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 900)
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.custom_minimum_size = Vector2(ROW_W, 0)
	scroll.add_child(list)
	# ★ 提交行**钉死行宽 + 末尾省略号**:ScrollContainer 不收缩子节点,而提交标题长短不一,
	#   最长的那条会把 Label 的最小宽度顶到面板之外 —— 每一行都在右沿被切成半个字。
	#   (这条是从被取代的 `version_panel.tscn` / `main_menu._fill_version_panel` 继承的实测。)
	for e in AppInfo.commit_log():
		var row := UiFactory.label("%s  %s  %s" % [str(e["hash"]), str(e["time"]), str(e["subject"])],
				16, UiFactory.C_TEXT)
		row.custom_minimum_size = Vector2(ROW_W, 0)
		row.size_flags_horizontal = Control.SIZE_FILL
		row.clip_text = true
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		list.add_child(row)


func _fill_right_blocks(parent: Node) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 24)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(col)

	var team := PanelContainer.new()
	team.add_theme_stylebox_override("panel", UiFactory.panel_box())
	var tbox := VBoxContainer.new()
	tbox.add_theme_constant_override("separation", 8)
	team.add_child(tbox)
	tbox.add_child(UiFactory.label("开 发 团 队", 32, UiFactory.C_ACCENT))
	for who in DEV_TEAM:
		tbox.add_child(UiFactory.label(who, 32))
	col.add_child(team)

	var cred := PanelContainer.new()
	cred.add_theme_stylebox_override("panel", UiFactory.panel_box())
	var cbox := VBoxContainer.new()
	cbox.add_theme_constant_override("separation", 8)
	cred.add_child(cbox)
	cbox.add_child(UiFactory.label("致 谢", 32, UiFactory.C_ACCENT))
	for pair in CREDITS:
		var right := str(pair[1])
		cbox.add_child(UiFactory.label(
				str(pair[0]) if right == "" else "%s　%s" % [str(pair[0]), right],
				32, UiFactory.C_TEXT if right != "" else UiFactory.C_TEXT_DIM))
	col.add_child(cred)


# ★ 切场景**必须延迟到帧末** —— `change_scene_to_file` 会**同步 memdelete** 当前场景,
#   同步切等于把还在调用栈上的本节点抽掉。本函数有两条调用路径(ESC 与「返 回」按钮),
#   两条都在切换之后还会碰 `self`/`get_tree()`。仓内先例:`settings_menu._go_back`。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# ★ 顺序不能反:**先**标记已处理,**再**决定去向(切换之后本节点已被移出树)。
		get_viewport().set_input_as_handled()
		_go_back()
