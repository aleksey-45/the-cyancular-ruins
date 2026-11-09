class_name MatchResult
extends CanvasLayer

# 结算页(设计系统 v1 / M4):CanvasLayer + Control 叠加层,面板 = Theme Card + CenterContainer 居中。
# ★ 去掉旧版绝对布局:不再在 show_result 里按 get_combined_minimum_size() 手算 offset_left/top/right/bottom,
#   面板由 CenterContainer 居中,宽度只设内容驱动的下限(SP_10 × 14 = 1120)。
# ★ 分区 = UiKit.section(标题带颜色由 payload 动态给,属允许的动态色);网格间距/字号只引 token。
# ★ 保留:leave_requested 信号、show_result(payload) 的**全部数据绑定**、清场顺序(remove_child 再 queue_free)、
#   COLUMN_TITLES / NAME_UNITS / MVP_MARK 与 Esc 离开行为。

signal leave_requested

const COLUMN_TITLES := {"kills": "击杀", "deaths": "阵亡", "assists": "助攻",
		"dealt": "造成", "taken": "承受", "acs": "ACS"}
const NAME_UNITS := 12
const MVP_MARK := "★ "
# 遮罩不透明度:0.55 时战局背景仍约一半可见(与旧版一致);颜色取 token,alpha 是本页版式参数。
const DIM_ALPHA := 0.55
# 面板宽度下限:SP_10 × 14 = 1120(与旧的 1120 一致,内容驱动下限)。
const PANEL_MIN_W := UiFactory.SP_10 * 14
# 返回按钮下限:SP_10 × 5 = 400 宽、SP_10 = 80 高(旧 420×88 的取整改用 token 组合)。
const BACK_MIN := Vector2(UiFactory.SP_10 * 5, UiFactory.SP_10)

var _leaving := false

@onready var _dim: ColorRect = $Root/Dim
@onready var _panel: PanelContainer = $Root/Center/Panel
@onready var _title_label: Label = $Root/Center/Panel/VBox/TitleLabel
@onready var _sub_label: Label = $Root/Center/Panel/VBox/SubLabel
@onready var _sections_box: HBoxContainer = $Root/Center/Panel/VBox/Sections
@onready var _back_button: Button = $Root/Center/Panel/VBox/BackButton


func _ready() -> void:
	_dim.color = UiFactory.C_BG
	_dim.modulate.a = DIM_ALPHA
	var vbox := $Root/Center/Panel/VBox as VBoxContainer
	vbox.add_theme_constant_override("separation", UiFactory.SP_4)
	_sections_box.add_theme_constant_override("separation", UiFactory.SP_6)
	_panel.custom_minimum_size = Vector2(PANEL_MIN_W, 0)
	_back_button.custom_minimum_size = BACK_MIN
	_back_button.pressed.connect(_request_leave)


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
		_build_section(sections[i], i, columns, mvp)
	visible = true
	set_process_unhandled_input(true)


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


# 分区标题带:标题 = H2,颜色由 payload 给(动态色,唯一允许绕过 token 的地方)。
func _section_band(text: String, color: Color) -> Label:
	var l := UiFactory.label(text, UiFactory.T_H2, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


# 一个分区 = UiKit.section(无标题,标题带自己上色)+ 表头/数据行网格;自己挂到 Sections 上。
func _build_section(sec: Dictionary, idx: int, columns: Array, mvp: Dictionary) -> void:
	var body := UiKit.section(_sections_box, "")
	var box := body.get_parent() as VBoxContainer
	box.name = "Section%d" % idx
	box.add_theme_constant_override("separation", UiFactory.SP_3)
	var color: Color = sec.get("color", UiFactory.C_TEXT)
	body.add_child(_section_band(str(sec.get("label", "")), color))

	var grid := GridContainer.new()
	grid.name = "Rows"
	grid.columns = 2 + columns.size()
	grid.add_theme_constant_override("h_separation", UiFactory.SP_5)
	grid.add_theme_constant_override("v_separation", UiFactory.SP_2)
	grid.add_child(UiFactory.label("#", UiFactory.T_H2, UiFactory.C_TEXT_DIM))
	grid.add_child(UiFactory.label("昵称", UiFactory.T_H2, UiFactory.C_TEXT_DIM))
	for col in columns:
		grid.add_child(UiFactory.label(str(COLUMN_TITLES.get(col, col)), UiFactory.T_H2,
				UiFactory.C_TEXT_DIM))

	var rows: Array = sec.get("rows", [])
	for ri in rows.size():
		var r: Dictionary = rows[ri]
		var is_mvp: bool = int(mvp.get("section", -1)) == idx and int(mvp.get("row", -1)) == ri
		var col: Color = UiFactory.C_TEXT if is_mvp else UiFactory.C_TEXT_DIM
		var mark := MVP_MARK if is_mvp else ""
		grid.add_child(UiFactory.label("%s%d" % [mark, int(r.get("rank", ri + 1))],
				UiFactory.T_H2, col))
		grid.add_child(UiFactory.label(UiFactory.fit_name(str(r.get("name", "")), NAME_UNITS),
				UiFactory.T_H2, col))
		for c in columns:
			grid.add_child(UiFactory.label(str(int(r.get(c, 0))), UiFactory.T_H2, col))
	body.add_child(grid)
