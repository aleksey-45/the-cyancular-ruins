class_name MatchResult
extends CanvasLayer

# 对局结算页面：
# 独立于特定玩法模式，由 MatchResultPayload 适配层提供数据载荷。
# 负责展示全场比分、数据统计表格、MVP 标识以及退出结算等交互。

signal leave_requested

# 统计列英中对照表
const COLUMN_TITLES := {"kills": "击杀", "deaths": "阵亡", "assists": "助攻",
		"dealt": "造成", "taken": "承受", "acs": "ACS"}
const NAME_UNITS := 12                 # 昵称最大字符显示宽度
const SIZE_TITLE := 48
const SIZE_BODY := 32
const MASK_COLOR := Color(0, 0, 0, 0.55)   # 背景半透明遮罩
const MVP_MARK := "★ "                 # MVP 标识前缀

var _leaving := false

@onready var _panel: PanelContainer = $Root/Panel
@onready var _title_label: Label = $Root/Panel/Body/VBox/TitleLabel
@onready var _sub_label: Label = $Root/Panel/Body/VBox/SubLabel
@onready var _sections_box: HBoxContainer = $Root/Panel/Body/VBox/Sections


func _ready() -> void:
	($Root/Dim as ColorRect).color = MASK_COLOR
	$Root/Panel/Body/VBox/BackButton.pressed.connect(_request_leave)


# 填充结算数据载荷并显示界面
func show_result(payload: Dictionary) -> void:
	_title_label.text = str(payload.get("title", ""))
	_sub_label.text = str(payload.get("subtitle", ""))
	_sub_label.visible = not _sub_label.text.is_empty()
	# 移除历史子节点以防重复挂载
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
	# 动态根据内容尺寸居中对齐面板
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


# 构造队伍或分段标题栏
func _section_band(text: String, color: Color) -> PanelContainer:
	var strip := UiFactory.header_strip(text, SIZE_BODY)
	var l := strip.get_child(0) as Label
	if l != null:
		l.add_theme_color_override("font_color", color)
	return strip


# 构建各分段的数据表格
func _build_section(sec: Dictionary, idx: int, columns: Array, mvp: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.name = "Section%d" % idx
	box.add_theme_constant_override("separation", 12)
	box.add_child(_section_band(str(sec.get("label", "")), sec.get("color", UiFactory.C_TEXT)))

	var grid := GridContainer.new()
	grid.name = "Rows"
	grid.columns = 2 + columns.size()          # 名次、昵称与各统计数据列
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

