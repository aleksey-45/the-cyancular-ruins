class_name MatchResult
extends CanvasLayer

# 对局结算页(模式无关),层位 150。★ 层位只住在 ui/match_result.tscn 里 ⇒ 本控件只能从场景实例化,绝不 MatchResult.new()
#   (那是 CanvasLayer 默认的 layer 1,画在 HUD/小地图底下且压暗罩盖不住)。
# ★★ 两条纪律:① 本控件不知道任何模式的规则(不读 NetBus / Settings、不 import 任何 *Host),模式差异全部由 ui/match_result_payload.gd 的三个适配器折成载荷 —— 谁能被 grep 到跨过这条线,谁就是缺陷;
#   ② leave_requested 只发一次(见 _leaving):下游 safe_change_scene 是一次换场,连发两次会叠加第二次换场(把刚建出来的主菜单当 old 退役)。
# ★ 本页的 ESC 闸门是 visible(_unhandled_input 首行)⇒ 调用方必须在"折载荷之前"就让本页可见,否则一具不可见的结算页是 ESC 够不着、按钮也点不到的空壳(今天由 PvpMatchClient._show_result() 的"挂载即亮"保证)。
# ★ ESC 的双重语义在本页安全,但依赖一处外部事实:MATCH_OVER 时三个客户端都把暂停菜单 queue_free 掉了 ⇒ 不会同时触发两件事;⚠ 谁将来删掉那两行,ESC 就会在本页同时开菜单。

signal leave_requested

# ★ 键名 = 适配器给的列名(MatchResultPayload.C_*),标题才是给人看的。★★ 三个列常量里出现的每一个键都必须在这里有标题 —— 漏一个不报错,只是那列表头退化成裸英文键名(下面 .get(col, col) 的兜底),而所有数值断言照样全绿。零守卫(match_result_payload_smoke 已删·2026-10-09)。
const COLUMN_TITLES := {"kills": "击杀", "deaths": "阵亡", "assists": "助攻",
		"dealt": "造成", "taken": "承受", "acs": "ACS"}
const NAME_UNITS := 12                 # 昵称定宽(半角单位);换字体要重算
const SIZE_TITLE := 48
const SIZE_BODY := 32
const MASK_COLOR := Color(0, 0, 0, 0.55)   # 全屏压暗罩 —— 与暂停菜单同值。★ 它不是 HUD 底板,不属 `0.1` 那一条
const MVP_MARK := "★ "                 # ★ 取图确认它能渲染(Unifont 覆盖 U+2605);出豆腐块就改 "MVP "

var _leaving := false

@onready var _panel: PanelContainer = $Root/Panel
@onready var _title_label: Label = $Root/Panel/Body/VBox/TitleLabel
@onready var _sub_label: Label = $Root/Panel/Body/VBox/SubLabel
@onready var _sections_box: HBoxContainer = $Root/Panel/Body/VBox/Sections


func _ready() -> void:
	# ★ 压暗罩的颜色以本常量为准(.tscn 里那份只是编辑器里的初始值)—— 留一条真值来源,免得两处各写一个 0.55 谁也不知道该信哪个。
	($Root/Dim as ColorRect).color = MASK_COLOR
	$Root/Panel/Body/VBox/BackButton.pressed.connect(_request_leave)


# 唯一入口。★ 缺键一律取默认:绝不因为缺一个键就崩 —— 结算页崩了玩家就卡在对局里出不去。
func show_result(payload: Dictionary) -> void:
	_title_label.text = str(payload.get("title", ""))
	_sub_label.text = str(payload.get("subtitle", ""))
	_sub_label.visible = not _sub_label.text.is_empty()
	# ★★ 清场必须先 remove_child 再 queue_free:只 queue_free 的话节点只是被标记、帧末才真的没掉,本帧剩下的时间里旧节点仍是 _sections_box 的子节点 ⇒
	#   ① 新加进来的 Section0/Section1 名字仍被占着 ⇒ Godot 给新节点自动改名成 Section0@2(此后按名字取节点再也取不到);② 紧跟的 get_combined_minimum_size() 把新旧两份一起量进去 ⇒ 偏移量按约两倍宽算,而布局一旦摆定就不重算(全程不报错)。★ 触发不是假设:3v3 的 round_state 会带第二次 MATCH_OVER 载荷(新 mvp)进来。
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
	# ★★ 居中必须在内容装好之后、按 get_combined_minimum_size() 自己算偏移量。为什么不能用 set_anchors_and_offsets_preset(PRESET_CENTER, PRESET_MODE_MINSIZE):_ready() 里那次只定锚点,
	#   偏移量按"调用那一刻的尺寸"推(那时面板还是 0×0)⇒ 左上角钉在视口中心、内容往右下长出去;换 PRESET_MODE_MINSIZE 也不对 —— Godot 4.7 那一档取 get_minimum_size()、不含 custom_minimum_size,
	#   实测 custom_minimum_size.x = 1120 而内容最小宽只有 476 ⇒ 面板被摆在"宽 476"的位置上、随后被撑到 1120,往右长出去 322px(而当时全部数值断言都是绿的)。锚点已是 (0.5,0.5),偏移量取 ±半尺寸即为居中。
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
		var col: Color = UiFactory.C_TEXT if is_mvp else UiFactory.C_TEXT_DIM
		var mark := MVP_MARK if is_mvp else ""
		grid.add_child(UiFactory.label("%s%d" % [mark, int(r.get("rank", ri + 1))], SIZE_BODY, col))
		grid.add_child(UiFactory.label(UiFactory.fit_name(str(r.get("name", "")), NAME_UNITS),
				SIZE_BODY, col))
		for c in columns:
			grid.add_child(UiFactory.label(str(int(r.get(c, 0))), SIZE_BODY, col))
	box.add_child(grid)
	return box
