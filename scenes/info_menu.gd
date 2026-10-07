extends Control

# 「信 息」整页(2026-10-03,取代主菜单上的版本信息弹层)。
# 三块:版本信息(AppInfo) / 开发团队 / 致谢。
#
# 注意： **静态 UI 结构定义在 `info_menu.tscn` 里**(2026-10-03 从代码迁出,见 `tools/gen_menu_scene.gd`)。
#   判据是**外观不变** —— 导出的基础结构与改前基线逐像素比对:**差异 0 / 2764800**。
#   本脚本只做两件事:**灌动态文本** + **接信号**;样式走 `ui/theme/menu_theme.tres` 的
#   `theme_type_variation`,不再调 `UiFactory` 的套皮函数。
# - 三块内容区(`CommitList` / `TeamBox` / `CreditsBox`)在基础结构框架里**是空的** —— 行由本脚本填。
#   这是计划接受的代价("编辑器里看不到动态行")。
#
# - 名单与致谢是**用户给定、逐字照抄**的 —— 切勿随意改写、别补全称、别调次序。
#   `tests/probe/info_page_probe` 把它们逐字钉住了(它自带一份同构的表做对账)。

# - 2026-10-04 用户给定:补 ofbwyx / Lycoris Max / hsk(**顺序照抄**),标题相应改成「开发团队/特别感谢」。
const DEV_TEAM := ["RoFtaCD", "KikuchiH", "Lord Nahiz Waugh", "siri2048",
	"ofbwyx", "Lycoris Max", "hsk"]
# 致谢三段:软件/素材(带许可或署名)与文学来源,中间空一档。
const CREDITS := [
	["Godot Engine", "MIT"],
	["GNU Unifont", "SIL OFL 1.1"],
	["Less Perfect DOS VGA", "Zeh Fernando / Laemeur"],
	# - 2026-10-04 用户要求:加 Deepseek 与 GLM(**不写版本号**),插在两位作家**前面**。
	["Deepseek", ""],
	["GLM", ""],
	["Thomas Stearns Eliot", ""],
	["Jorge Luis Borges", ""],
]

# 提交行的**严格约束宽度**。注意： 它**必须小于左栏的可见内宽**,否则:
#   ScrollContainer 照样出横向滚动条,而**省略号落在可视区之外** —— 比不钉还糟
#   (既滚动又看不见截断提示)。实测(2026-10-03,左栏换成 `menu_panel()` 后):
#   1920 宽、页面边距 76、两栏 1.25:1  ->  左栏内宽 ≈ 850  ->  取 760 留余量。
#   - 别照抄被取代的 `version_panel.tscn` 的 1100:那个面板本身 1180 宽,放得下。
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


# 行标签的**共用形状**。-  三处细节都是 `UiFactory.label()` 的既有行为,漏一个就静默变样:
#   ① 字号决定变体(16 → `Small`,32 → `Body`);② 字色**显式**给(默认是纯白 `C_WHITE`,
#   而 `C_TEXT` 是另一个值 —— 两者单通道差 0.122,实测能差出上千像素);
#   ③ `mouse_filter = IGNORE` 相同机制:漏了这些行会**拦截屏蔽滚轮与点击事件**(在 ScrollContainer 里尤其明显)。
# - 形参与 `UiFactory.label(text, size, color)` **同序** —— 刻意如此:
#   本函数就是它的替身,同序才不会在改写调用点时把 (size, color) 写反
#   (2026-10-03 真写反过一次,GDScript 当场 Parse Error、整屏脚本没加载)。
func _mk_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"Small" if size == 16 else &"Body"
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _fill_commits() -> void:
	# 注意： 空历史保底处理(2026-10-03,评审 Important #2):发布版 exe 常跑在**没有 git** 的机器上,
	#   那时 `AppInfo.commit_log()` 返回 `[]`  ->  左栏是一个**没有任何解释的空框**,
	#   而那恰恰是这一页存在的理由。文案**逐字沿用**被取代的
	#   `main_menu._fill_version_panel` 那一句(别改写措辞,`info_page_probe` 逐字钉着它)。
	# - 颜色:旧实现用的是字面量 `Color(0.9, 0.6, 0.5)`(暖色告警);改用既有 token ——
	#   取 **`C_DANGER`** 而不是 `C_TEXT_DIM`,两个理由:
	#     ① 它表的是「**读不到**」这一异常;而 `C_TEXT_DIM` 的既定语义是「占位符/说明文字」,
	#        且在**本页**它已经被两条无许可的致谢(`Thomas Stearns Eliot` / `Jorge Luis Borges`)占用
	#         ->  用它会让这行解释与那两条正文同色,读起来仍是"内容"而不是"为什么是空的"。
	#     ② 旧字面量本就是暖色:`C_DANGER`(0.900,0.400,0.400)与它的 RGB 距离 ≈0.22,
	#        而 `C_TEXT_DIM`(0.510,0.573,0.639)≈0.41 —— 前者更接近被取代的那一版。
	# - 它**与提交行同一套排版**(严格约束行宽 + 末尾省略号):一来长文案不会顶出面板,
	#   二来空历史时它就是左栏里的**第一条(也是唯一一条)行** —— 排版与提交行不相同机制的话,
	#   `info_page_probe` 那条「严格约束行宽 ≤ 滚动区宽」量的对象会悄悄变成另一类控件。
	var entries := AppInfo.commit_log()
	if entries.is_empty():
		_commit_list.add_child(_commit_row("(读不到 git 历史:仓库不可用或未安装 git)",
				UiFactory.C_DANGER))
	# - 提交行**严格约束行宽 + 末尾省略号**:ScrollContainer 不收缩子节点,而提交标题长短不一,
	#   最长的那条会把 Label 的最小宽度顶到面板之外 —— 每一行都在右沿被切成半个字。
	#   (这条是从被取代的 `version_panel.tscn` / `main_menu._fill_version_panel` 继承的实测。)
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


# - 切场景**必须延迟到帧末** —— `change_scene_to_file` 会**同步 memdelete** 当前场景,
# 同步切等于把还在调用栈上的本节点抽掉。本函数有两条调用路径(ESC 与「返 回」按钮),
# 两条都在切换之后还会碰 `self`/`get_tree()`。仓内先例:`settings_menu._go_back`。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# - 顺序不能反:**先**标记已处理,**再**决定去向(切换之后本节点已被移出树)。
		get_viewport().set_input_as_handled()
		_go_back()
