class_name MatchResult
extends CanvasLayer

# 对局结算页(**模式无关**)。层位 150。
#
# ★★ 两条纪律,改之前先想清楚:
#   ① 本控件**不知道任何模式的规则** —— 不读 NetBus / Settings / 不 import 任何 *Host。
#      模式差异全部由 `ui/match_result_payload.gd` 的三个适配器折成载荷。谁能被 grep 到
#      跨过这条线,谁就是缺陷。
#   ② `leave_requested` **只发一次**(见 `_leaving`):下游 `safe_change_scene` 是一次换场,
#      连发两次会叠加第二次换场(把刚建出来的主菜单当 old 退役)。
#
# ★ ESC 的**双重语义**在本页是安全的,但依赖一处外部事实:对局中 ESC = 暂停菜单,
#   而 MATCH_OVER 时三个客户端都把暂停菜单 `queue_free` 掉了 ⇒ 不会同时触发两件事。
#   ⚠ 谁将来删掉那两行"销毁暂停菜单",ESC 就会在本页同时开菜单 —— 届时必须回来处理。

signal leave_requested

const COLUMN_TITLES := {"kills": "击杀", "deaths": "阵亡", "dmg": "伤害", "acs": "ACS"}
const NAME_UNITS := 12                 # 昵称定宽(半角单位);换字体要重算
const SIZE_TITLE := 48
const SIZE_BODY := 32
const MASK_COLOR := Color(0, 0, 0, 0.55)   # 全屏压暗罩 —— 与暂停菜单同值。★ 它不是 HUD 底板,不属 `0.1` 那一条
const MVP_MARK := "★ "                 # ★ 取图确认它能渲染(Unifont 覆盖 U+2605);出豆腐块就改 "MVP "

var _leaving := false
var _sections_box: HBoxContainer = null
var _title_label: Label = null
var _sub_label: Label = null
var _panel: PanelContainer = null


func _ready() -> void:
	UiFactory.apply_font_recursive(self)
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = MASK_COLOR
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var panel := PanelContainer.new()
	_panel = panel
	panel.name = "Panel"
	panel.add_theme_stylebox_override("panel", UiFactory.panel_box())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(1120, 0)
	root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 24)
	panel.add_child(vb)

	_title_label = UiFactory.label("", SIZE_TITLE, UiFactory.C_TEXT)
	_title_label.name = "TitleLabel"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_title_label)

	_sub_label = UiFactory.label("", SIZE_BODY, UiFactory.C_TEXT_DIM)
	_sub_label.name = "SubLabel"
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_sub_label)

	_sections_box = HBoxContainer.new()
	_sections_box.name = "Sections"
	_sections_box.add_theme_constant_override("separation", 48)
	_sections_box.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(_sections_box)

	var back := UiFactory.button("返 回 主 菜 单", SIZE_BODY, Vector2(420, 64))
	back.name = "BackButton"
	back.pressed.connect(_request_leave)
	vb.add_child(back)

	# ★ 上面那几件(全屏压暗罩 / 面板 / 按钮)在 `_ready()` 里就建好了 ⇒ 若不隐藏,
	#   从 `add_child` 到调用方 `show_result()` 之间会露出一块**空面板 + 按钮**的窗。
	#   载荷要等 `show_result()` 才有 ⇒ 这里先藏起来,由它置回 true。
	visible = false


# 唯一入口。★ 缺键一律取默认:**绝不因为缺一个键就崩** —— 结算页崩了玩家就卡在对局里出不去。
func show_result(payload: Dictionary) -> void:
	_title_label.text = str(payload.get("title", ""))
	_sub_label.text = str(payload.get("subtitle", ""))
	_sub_label.visible = not _sub_label.text.is_empty()
	for c in _sections_box.get_children():
		c.queue_free()
	var columns: Array = payload.get("columns", [])
	var mvp: Dictionary = payload.get("mvp", {})
	var sections: Array = payload.get("sections", [])
	for i in sections.size():
		_sections_box.add_child(_build_section(sections[i], i, columns, mvp))
	visible = true
	set_process_unhandled_input(true)
	# ★★ 居中**必须**在内容装好之后、按 `get_combined_minimum_size()` 自己算偏移量。
	#    为什么不能用 `set_anchors_and_offsets_preset(PRESET_CENTER, PRESET_MODE_MINSIZE)`:
	#      · `_ready()` 里那次 `set_anchors_preset(CENTER)` 只定**锚点**,偏移量是 Godot 按
	#        "调用那一刻的尺寸"推的(走 `PRESET_MODE_KEEP_SIZE`),而那时面板还是 0×0
	#        ⇒ 四个偏移量全 0 ⇒ 面板的**左上角**钉在视口中心,内容往右下长出去;
	#      · 换成 `PRESET_MODE_MINSIZE` 也不对 —— Godot 4.7 那一档取的是 `get_minimum_size()`,
	#        **不含 `custom_minimum_size`**;面板实收的尺寸却是 `max(两者)`。实测本页:
	#        `custom_minimum_size.x = 1120` 而内容最小宽只有 476(一个按钮)⇒ 偏移量按 476 算
	#        = 面板被摆在"宽 476"的位置上,随后布局把它撑到 1120,**往右长出去 322px**。
	#    ⇒ 唯一可靠的量就是 `get_combined_minimum_size()`(取图时打过诊断核对:此刻它 = 实收尺寸)。
	#    实测(2026-09-20 取图,`tests/match_result_probe` 的 `user://match_result_0..2.png`):
	#    面板右半截切在屏幕外,3v3 两节时 **B 队的「击杀/阵亡/伤害/ACS」四列整列看不见** ——
	#    而当时**全部数值断言都是绿的**(它们只数 `columns` 与子节点个数,位置一个都照不到)。
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


func _build_section(sec: Dictionary, idx: int, columns: Array, mvp: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.name = "Section%d" % idx
	box.add_theme_constant_override("separation", 12)
	box.add_child(UiFactory.label(str(sec.get("label", "")), SIZE_BODY,
			sec.get("color", UiFactory.C_TEXT)))

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
		# ★ MVP 行用**亮文本**、其余行用暗文本 + MVP 前缀标记 —— 不复用 C_WARN
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
