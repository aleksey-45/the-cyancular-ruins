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

# 提交行的**钉死宽度**。★★ 它**必须小于左栏的可见内宽**,否则:
#   ScrollContainer 照样出横向滚动条,而**省略号落在可视区之外** —— 比不钉还糟
#   (既滚动又看不见截断提示)。实测:1:1 时左栏内宽 829、加了下面那句
#   `size_flags_stretch_ratio` 之后是 927 ⇒ 取 760,两种布局下都留余量。
#   ★ 别照抄被取代的 `version_panel.tscn` 的 1100:那个面板本身 1180 宽,放得下。
const ROW_W := 760.0


func _ready() -> void:
	# 不透明深色底:进过单机后全局清屏色是浅蓝,白字会看不清(与 settings_menu 同一形态)。
	# ★ 下面这个 `Color(0.07, 0.09, 0.13)` 是**既有字面量**,与 `scenes/settings_menu.gd:25`
	#   同款(两页各硬编码了一份)。★ 它**与 `UiFactory.C_BG` = (0.039, 0.059, 0.094) 并不是
	#   同一个值** —— 所以**不能**"顺手换成 `C_BG`":换了会**静默改变这两页的底色**。
	#   计划 ③ 统一调色板时应把这一处与 settings_menu 那处**一起**并进 `UiFactory`
	#   (并决定要不要连带改掉底色值);本计划不新增颜色,故此处不动。
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
	# ★★ 设计 §3.10 的「左 1.25 : 右 1」**只能靠 stretch_ratio 表达** ——
	#    `ScrollContainer` 的**最小尺寸不向上传播**子节点的最小宽度,所以指望用
	#    `ROW_W` 把左栏撑宽是徒劳的(实测:两栏会塌成 1:1 = 885/885)。
	panel.size_flags_stretch_ratio = 1.25
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
	# ★★ 空历史兜底(2026-10-03,评审 Important #2):发布版 exe 常跑在**没有 git** 的机器上,
	#   那时 `AppInfo.commit_log()` 返回 `[]` ⇒ 左栏是一个**没有任何解释的空框**,
	#   而那恰恰是这一页存在的理由。文案**逐字沿用**被取代的
	#   `main_menu._fill_version_panel` 那一句(别改写措辞,`info_page_probe` 逐字钉着它)。
	# ★ 颜色:旧实现用的是字面量 `Color(0.9, 0.6, 0.5)`(暖色告警)。本计划不新增颜色字面量,
	#   故改用既有 token —— 取 **`C_DANGER`** 而不是 `C_TEXT_DIM`,两个理由:
	#     ① 它表的是「**读不到**」这一异常;而 `C_TEXT_DIM` 的既定语义是「占位符/说明文字」,
	#        且在**本页**它已经被两条无许可的致谢(`Thomas Stearns Eliot` / `Jorge Luis Borges`)占用
	#        ⇒ 用它会让这行解释与那两条正文同色,读起来仍是"内容"而不是"为什么是空的"。
	#     ② 旧字面量本就是暖色:`C_DANGER`(0.900,0.400,0.400)与它的 RGB 距离 ≈0.22,
	#        而 `C_TEXT_DIM`(0.510,0.573,0.639)≈0.41 —— 前者更接近被取代的那一版。
	# ★ 它**与提交行同一套排版**(钉死行宽 + 末尾省略号):一来长文案不会顶出面板,
	#   二来空历史时它就是左栏里的**第一条(也是唯一一条)行** —— 排版与提交行不同款的话,
	#   `info_page_probe` 那条「钉死行宽 ≤ 滚动区宽」量的对象会悄悄变成另一类控件。
	var entries := AppInfo.commit_log()
	if entries.is_empty():
		var note := UiFactory.label("(读不到 git 历史:仓库不可用或未安装 git)", 32, UiFactory.C_DANGER)
		note.custom_minimum_size = Vector2(ROW_W, 0)
		note.size_flags_horizontal = Control.SIZE_FILL
		note.clip_text = true
		note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		list.add_child(note)
	# ★ 提交行**钉死行宽 + 末尾省略号**:ScrollContainer 不收缩子节点,而提交标题长短不一,
	#   最长的那条会把 Label 的最小宽度顶到面板之外 —— 每一行都在右沿被切成半个字。
	#   (这条是从被取代的 `version_panel.tscn` / `main_menu._fill_version_panel` 继承的实测。)
	for e in entries:
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
