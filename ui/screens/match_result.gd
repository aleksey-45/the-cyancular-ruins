class_name MatchResult
extends CanvasLayer

# 对局结算页(**模式无关**)。层位 150。
# - 层位只住在 `ui/match_result.tscn` 里  ->  本控件**只能从场景实例化**,绝不 `MatchResult.new()`(那是 CanvasLayer 默认的 layer 1,画在 HUD/小地图底下且压暗罩盖不住)。
#
# 注意： 两条纪律,改之前先想清楚:
#   ① 本控件**不知道任何模式的规则** —— 不读 NetBus / Settings / 不 import 任何 *Host。
#      模式差异全部由 `ui/match_result_payload.gd` 的三个适配器折成载荷。谁能被 grep 到
#      跨过这条线,谁就是缺陷。
#   ② `leave_requested` **只发一次**(见 `_leaving`):下游 `safe_change_scene` 是一次换场,
#      连发两次会叠加第二次换场(把刚建出来的主菜单当 old 退役)。
#
# - ESC 的**双重语义**在本页是安全的,但依赖一处外部事实:对局中 ESC = 暂停菜单,
#   而 MATCH_OVER 时三个客户端都把暂停菜单 `queue_free` 掉了  ->  不会同时触发两件事。
#   ⚠ 谁将来删掉那两行"销毁暂停菜单",ESC 就会在本页同时开菜单 —— 届时必须回来处理。
#
# - 本页的 ESC 门控前置校验是 **`visible`**(`_unhandled_input` 首行)。 ->  调用方**必须**在"组装解析载荷之前"
#   就让本页可见,否则一具不可见的结算页是 **ESC 够不着**的空壳(按钮也点不到,压暗罩也没有)。
#   这一条今天由 `PvpMatchClient._show_result()` 的"挂载即亮"(先 `show_result({})`、再填真载荷)
#   保证 —— 那里的注释写着为什么"亮出来"不能等到真载荷算出来之后。改本页的可见性时序前先读那条。

signal leave_requested

# - 键名 = 适配器给的列名(`MatchResultPayload.C_*`),标题才是给人看的。
#   `dmg` 已改名 `dealt`(与载荷字段同步);`assists`/`taken` 与 §3.6 的列一一对应。
#   注意： 三个列常量里出现的**每一个**键都必须在这里有标题 —— 漏一个**不报错**,只是那一列的
#      表头退化成**裸英文键名**(下面 `.get(col, col)` 的保底处理),而所有数值断言照样测试全部通过。
#      守卫:`tests/smoke/match_result_payload_smoke.gd` 的 ⑧(键集从三个常量推,不写死清单)。
const COLUMN_TITLES := {"kills": "击杀", "deaths": "阵亡", "assists": "助攻",
		"dealt": "造成", "taken": "承受", "acs": "ACS"}
const NAME_UNITS := 12                 # 昵称定宽(半角单位);换字体要重算
const SIZE_TITLE := 48
const SIZE_BODY := 32
const MASK_COLOR := Color(0, 0, 0, 0.55)   # 全屏压暗罩 —— 与暂停菜单同值。-  它不是 HUD 底板,不属 `0.1` 那一条
const MVP_MARK := "★ "                 # - 取图确认它能渲染(Unifont 覆盖 U+2605);出豆腐块就改 "MVP "

var _leaving := false

# 注意： 静态 UI 结构定义在 `ui/screens/match_result.tscn` 里(2026-10-03 从代码迁出,见
#   `tools/gen_menu_scene.gd`):压暗罩 `Dim` / 面板 `Panel` / 标题 `TitleLabel` / 副题
#   `SubLabel` / 空的 `Sections` / `BackButton`。判据是**外观不变** —— 与改前逐像素比对
#   三个模式各 **差异 0**。
#   - 那个 `.tscn` **承担两项关键职责**:① 根是 `CanvasLayer`,② `layer = 150` **只住在它里面** ——
#     所以本控件**只能从场景实例化**,绝不 `MatchResult.new()`。
#   - 代码建的节点原本就显式起了名(`Root`/`Dim`/`Panel`/`Body`/`TitleLabel`/…),
#     导出时被逐字保留  ->  下面那几条路径与旧代码里的 `name = …` 一一对应。
@onready var _panel: PanelContainer = $Root/Panel
@onready var _title_label: Label = $Root/Panel/Body/VBox/TitleLabel
@onready var _sub_label: Label = $Root/Panel/Body/VBox/SubLabel
@onready var _sections_box: HBoxContainer = $Root/Panel/Body/VBox/Sections


func _ready() -> void:
	# - 压暗罩的颜色**以本常量为准**(`.tscn` 里那份只是编辑器里的初始值)——
	#   留一条真值来源,免得两处各写一个 0.55 谁也不知道该信哪个。
	($Root/Dim as ColorRect).color = MASK_COLOR
	$Root/Panel/Body/VBox/BackButton.pressed.connect(_request_leave)
	# - 说明:**不再调 `UiFactory.apply_font_recursive(self)`**。旧代码里那一句是在
	#   子节点建好之后把像素字体刷满整棵树;现在整棵树都挂在本页的 `Theme` 上
	#   (`.tscn` 的 `Root.theme`),字体由 Theme 的 `default_font` 提供 —— 两者渲染等价
	#   (Task 2 逐屏取图验过),而下面三个模式的逐像素比对也是 0。
	# - `visible = false` 仍写在 `.tscn` 里:`show_result()` 才置回 true。
	#   若不隐藏,从实例化到 `show_result()` 之间会露出一块**空面板 + 按钮**的窗。


# 唯一入口。-  缺键一律取默认:**绝不因为缺一个键就崩** —— 结算页崩了玩家就卡在对局里出不去。
func show_result(payload: Dictionary) -> void:
	_title_label.text = str(payload.get("title", ""))
	_sub_label.text = str(payload.get("subtitle", ""))
	_sub_label.visible = not _sub_label.text.is_empty()
	# 注意： 清场必须**先 `remove_child` 再 `queue_free`**(与 `scenes/weapons/weapon_pickup.gd`
	#    的 `configure()` 逐字相同机制)。只 `queue_free` 的话节点只是被**标记**,要到帧末才真的
	#    没掉 —— 本帧剩下的时间里旧节仍然是 `_sections_box` 的子节点,于是:
	#      ① 下面新加进来的 `Section0`/`Section1` **名字仍被占着**  ->  Godot 给**新**节点自动
	#         改名成 `Section0@2`/`Section1@2`(此后按名字取节点再也取不到);
	#      ② 再往下那次 `get_combined_minimum_size()` 把**新旧两份一起**量进去  ->  偏移量按
	#         约两倍宽算,而布局一旦按它摆定就**不会重算**  ->  这一实例从此永久偏宽、偏离
	#         (全程不报错)。
	#    - 触发不是假设:3v3 的 `round_state` 会带**第二次** MATCH_OVER 载荷(新 mvp)进来。
	#      `remove_child` 让名字当场释放,`get_children()` 里也就只剩还活着的那些。
	for c in _sections_box.get_children():
		_sections_box.remove_child(c)
		c.queue_free()
	var columns: Array = payload.get("columns", [])
	var mvp: Dictionary = payload.get("mvp", {})
	var sections: Array = payload.get("sections", [])
	for i in sections.size():
		_sections_box.add_child(_build_section(sections[i], i, columns, mvp))
	visible = true
	set_process_unhandled_input(true)
	# 注意： 居中**必须**在内容装好之后、按 `get_combined_minimum_size()` 自己算偏移量。
	#    为什么不能用 `set_anchors_and_offsets_preset(PRESET_CENTER, PRESET_MODE_MINSIZE)`:
	#      - `_ready()` 里那次 `set_anchors_preset(CENTER)` 只定**锚点**,偏移量是 Godot 按
	#        "调用那一刻的尺寸"推的(走 `PRESET_MODE_KEEP_SIZE`),而那时面板还是 0×0
	#         ->  四个偏移量全 0  ->  面板的**左上角**钉在视口中心,内容往右下长出去;
	#      - 换成 `PRESET_MODE_MINSIZE` 也不对 —— Godot 4.7 那一档取的是 `get_minimum_size()`,
	#        **不含 `custom_minimum_size`**;面板实收的尺寸却是 `max(两者)`。实测本页:
	#        `custom_minimum_size.x = 1120` 而内容最小宽只有 476(一个按钮) ->  偏移量按 476 算
	#        = 面板被摆在"宽 476"的位置上,随后布局把它撑到 1120,**往右长出去 322px**。
	#     ->  唯一可靠的量就是 `get_combined_minimum_size()`(取图时打过诊断核对:此刻它 = 实收尺寸)。
	#    实测(2026-09-20 取图,`tests/probe/match_result_probe` 的 `user://match_result_0..2.png`):
	#    面板右半截切在屏幕外,3v3 两节时 **B 队的「击杀/阵亡/伤害/ACS」四列整列看不见** ——
	#    而当时**全部数值断言都是绿的**(它们只数 `columns` 与子节点个数,位置一个都无法覆盖检测)。
	#    锚点已是 (0.5,0.5)(`_ready()` 那次),偏移量取 ±半尺寸即为居中。
	var half := _panel.get_combined_minimum_size() * 0.5
	_panel.offset_left = -half.x
	_panel.offset_top = -half.y
	_panel.offset_right = half.x
	_panel.offset_bottom = half.y


func _request_leave() -> void:
	if _leaving:
		return
	_leaving = true
	leave_requested.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_request_leave()


# 区块标题带:复用 `UiFactory.header_strip`(C_HEADER 底 + 只有下边一条 C_BORDER 线),
# 只把标题色换成该节自己的颜色 —— **保留 3v3 的「一眼看出 A/B 队」**(队色),
# 而不是把两节都统一着色为相同的金色。这与 `scenes/mp_lobby.gd` 的 `_card_header` 同一条取法
# (相同版式 + 自带颜色),不为"统一"丢掉队色这一条有玩法语义的信息。
func _section_band(text: String, color: Color) -> PanelContainer:
	var strip := UiFactory.header_strip(text, SIZE_BODY)
	var l := strip.get_child(0) as Label
	if l != null:
		l.add_theme_color_override("font_color", color)
	return strip


func _build_section(sec: Dictionary, idx: int, columns: Array, mvp: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.name = "Section%d" % idx
	box.add_theme_constant_override("separation", 12)
	# 区块标题 = 相同标题栏(`header_strip` 的形状),标题色取该节自己的颜色。
	box.add_child(_section_band(str(sec.get("label", "")), sec.get("color", UiFactory.C_TEXT)))

	var grid := GridContainer.new()
	grid.name = "Rows"
	grid.columns = 2 + columns.size()          # 名次 + 昵称 + 数据列
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 8)
	grid.add_child(UiFactory.label("#", SIZE_BODY, UiFactory.C_TEXT_DIM))
	grid.add_child(UiFactory.label("昵称", SIZE_BODY, UiFactory.C_TEXT_DIM))
	for col in columns:
		grid.add_child(UiFactory.label(str(COLUMN_TITLES.get(col, col)), SIZE_BODY,
				UiFactory.C_TEXT_DIM))

	var rows: Array = sec.get("rows", [])
	for ri in rows.size():
		var r: Dictionary = rows[ri]
		var is_mvp: bool = int(mvp.get("section", -1)) == idx and int(mvp.get("row", -1)) == ri
		# - MVP 行用**亮文本**、其余行用暗文本 + MVP 前缀标记 —— 不复用 C_WARN
		#   (它只表「弹夹见底」)也不复用 C_ACCENT(它与队 B 的 `#80F4FF` 太近)。
		var col: Color = UiFactory.C_TEXT if is_mvp else UiFactory.C_TEXT_DIM
		var mark := MVP_MARK if is_mvp else ""
		grid.add_child(UiFactory.label("%s%d" % [mark, int(r.get("rank", ri + 1))], SIZE_BODY, col))
		grid.add_child(UiFactory.label(UiFactory.fit_name(str(r.get("name", "")), NAME_UNITS),
				SIZE_BODY, col))
		for c in columns:
			grid.add_child(UiFactory.label(str(int(r.get(c, 0))), SIZE_BODY, col))
	box.add_child(grid)
	return box
