extends Control

# P2 编辑器场景根:画布 + 7 层面板 + 调色板 + 工具 + 打开/保存/校验 + 状态栏。
# ★ 所有纯逻辑都在 core/editor/ 下(EditorDoc / EditorIO / EditorCodec / EditorValidate),本文件只做 UI 与接线;
#   场景探针(tests/probe/editor_scene_probe.gd)只调本文件的公开 API,不点按钮。
# ★ 本脚本进客户端导出包 ⇒ 禁止 RegEx;失败一律给可见文案,不静默吞。
# ★ 坐标:画布内部世界坐标 = 子格(16px);格 = 子格/4;环面归一化由 EditorDoc 兜底。

const CANVAS_SCRIPT := preload("res://scenes/editor/editor_canvas.gd")
const PREVIEW_SCRIPT := preload("res://scenes/editor/editor_preview.gd")
const TILE_DEFS_PATH := "res://data/tile_defs.json"

const TOOL_BRUSH := "brush"
const TOOL_ERASER := "eraser"
const TOOL_LINE := "line"
const TOOL_RECT := "rect"
const TOOL_BUCKET := "bucket"
const TOOL_EYEDROP := "eyedrop"
const TOOL_SELECT := "select"
const TOOL_GRADIENT := "gradient"

const TOOL_LABELS := {
	TOOL_BRUSH: "画笔", TOOL_ERASER: "橡皮", TOOL_LINE: "直线",
	TOOL_RECT: "矩形", TOOL_BUCKET: "油漆桶", TOOL_EYEDROP: "吸管",
	TOOL_SELECT: "选框", TOOL_GRADIENT: "渐变",
}

# meta 放置模式(点画布 = 在当前格放一个;不改地形)。
const META_NONE := "none"
const META_PLAYER := "player"
const META_RESPAWN1 := "respawn1"
const META_RESPAWN2 := "respawn2"
const META_ENEMY := "enemy"
const META_LABELS := {
	META_NONE: "编辑地形", META_PLAYER: "放出生点",
	META_RESPAWN1: "放复活点侧1", META_RESPAWN2: "放复活点侧2", META_ENEMY: "放敌人",
}

# 布局尺寸(等 T1 的 SP_*/T_* token 合入后改为引用 token;集中一处,页面别处不再写魔法数)
const THEME := preload("res://ui/theme/menu_theme.tres")   # 与游戏 UI 同一份主题(字体/下拉/提示)
const FRAME_MARGIN := UiFactory.SP_2   # 根边距 = 8(SP_2)
const FRAME_GAP := 6             # 容器间距(6 无对应 token;视觉上等距 4/8 之间)
const TAB_MIN_W := 320.0         # 右栏 TabContainer 最小宽
const TAB_DEFAULT_W := 400.0     # 右栏初始宽(可拖拽)
const PALETTE_COLUMNS := 5       # 调色板列数(64px 缩略图 × 5 ≈ 336)
const DIALOG_PAD := UiFactory.SP_5     # 标准弹层内容内边距 = 24

var doc: EditorDoc = null
var canvas: EditorCanvas = null

var _path := ""
var _tool := TOOL_BRUSH
var _paint_desc := 0
var _brush_cells := 1
var _color_value := Color(0.0, 0.0, 0.0, 0.0)
var _texture_ids: Array[int] = []
var _layer_rows: Array[Dictionary] = []
var _tool_buttons: Dictionary = {}
var _palette_buttons: Array[Button] = []
var _status: Label = null
var _path_label: Label = null
var _output: RichTextLabel = null
var _message := ""

var _painting := false
var _stroke_begin := Vector2i.ZERO
var _last_cell := Vector2i.ZERO
var _has_last := false

var _canvas_host: Control = null
var _split: HSplitContainer = null
var _tabs: TabContainer = null
var _popup: Window = null

# 后置项:选区 / 剪贴板按钮 / meta 放置 / 颜色 / 真渲染预览
var _meta_mode := META_NONE
var _meta_buttons: Dictionary = {}
var _meta_info: Label = null
var _selection_info: Label = null
var _color_btn: ColorPickerButton = null
var _gradient_end := Color(1.0, 1.0, 1.0, 0.0)
var _gradient_end_btn: ColorPickerButton = null
var _selecting := false
var _select_start := Vector2i.ZERO
var _preview: Control = null
var _preview_on := false
var _preview_btn: Button = null
var _preview_last_origin := Vector2.INF
var _preview_last_zoom := -1.0


func _ready() -> void:
	doc = EditorDoc.new()
	_register_editor_actions()
	_build_ui()
	canvas.set_doc(doc)
	_build_preview()
	doc.changed.connect(_on_doc_changed)
	doc.structure_changed.connect(_on_doc_structure_changed)
	doc.meta_changed.connect(_on_doc_meta_changed)
	canvas.pointer_down.connect(_on_pointer_down)
	canvas.pointer_drag.connect(_on_pointer_drag)
	canvas.pointer_up.connect(_on_pointer_up)
	canvas.cursor_moved.connect(_on_cursor_moved)
	canvas.zoom_changed.connect(_on_zoom_changed)
	_select_tool(TOOL_BRUSH)
	_set_message("新图默认 125×75 格;Ctrl+O 打开、Ctrl+S 保存、H/V 镜像选区", false)
	_update_status(Vector2i.ZERO, false)


func _process(_dt: float) -> void:
	if not _preview_on or _preview == null or canvas == null:
		return
	var origin := canvas.origin
	var zoom := canvas.zoom
	if origin != _preview_last_origin or zoom != _preview_last_zoom:
		_preview_last_origin = origin
		_preview_last_zoom = zoom
		_preview.set_camera(origin, zoom)


# ── 公开 API(场景探针用;也是按钮的落点)──────────────────────────────

func get_doc() -> EditorDoc:
	return doc


func get_editor_canvas() -> EditorCanvas:
	return canvas


func current_path() -> String:
	return _path


func open_path(path: String) -> Dictionary:
	var res := EditorIO.open_path(path)
	if not bool(res.get("ok", false)):
		_set_message("打开失败:%s" % String(res.get("error", "")), true)
		return res
	doc.load_map(res["map"])
	_path = path
	canvas.set_active_layer(doc.active_layer)
	canvas.fit_to_map()
	_sync_layer_rows()
	_refresh_palette_texture()
	_set_message("已打开 %s(%s)" % [path, String(res.get("source", "v4"))], false)
	if not (res.get("warnings", []) as Array).is_empty():
		_append_output("打开时校验提示:\n- " + "\n- ".join(res["warnings"]))
	_update_status(Vector2i.ZERO, false)
	return res


func new_map(cells_w: int, cells_h: int, map_name: String = "untitled") -> void:
	doc.new_map(map_name, cells_w, cells_h)
	_path = ""
	canvas.fit_to_map()
	_sync_layer_rows()
	_set_message("已新建 %d×%d 格" % [cells_w, cells_h], false)
	_update_status(Vector2i.ZERO, false)


func save_to(path: String) -> Dictionary:
	var res := EditorIO.save_path(path, doc.map)
	if not bool(res.get("ok", false)):
		var lines: Array = ["保存失败:%s" % String(res.get("error", ""))]
		for e in res.get("errors", []):
			lines.append("  error: " + String(e))
		for w in res.get("warnings", []):
			lines.append("  warn: " + String(w))
		_append_output("\n".join(lines))
		_set_message("保存失败:%s" % String(res.get("error", "")), true)
		return res
	_path = path
	doc.dirty = false
	_set_message("已保存 %s(%d 字节)" % [path, int(res.get("bytes", 0))], false)
	if not (res.get("warnings", []) as Array).is_empty():
		_append_output("保存时校验提示:\n- " + "\n- ".join(res["warnings"]))
	_update_status(Vector2i.ZERO, false)
	return res


func _map_name() -> String:
	var n := ""
	if not doc.map.is_empty():
		n = String(doc.map.get("name", ""))
	return "untitled" if n == "" else n


func save_current() -> Dictionary:
	if _path != "":
		return save_to(_path)
	return save_to(EditorIO.default_target(_map_name()))


func validate() -> Dictionary:
	var report := doc.validate()
	_show_report(report)
	return report


# ── UI 构建(容器优先;T3 重画:工具栏 + HSplit + TabContainer + 状态栏)─────────
# ★ 页面不写绝对坐标(position/size/offset):根 = MarginContainer → VBox → 工具栏 / HSplit /
#   状态栏;左右分栏可拖拽,右侧 Tab 页各自滚动。等 T1 的 UiKit / SP_*·T_* token 合入后,
#   下面标注「内容驱动」的尺寸常量改引 token;现在只用 UiFactory 现有公开 API(panel_box /
#   menu_button / label / style_*),不自己拼 StyleBox。

func _build_ui() -> void:
	theme = THEME
	var bg := ColorRect.new()
	bg.name = "Bg"
	bg.color = UiFactory.C_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var frame := MarginContainer.new()
	frame.name = "Frame"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		frame.add_theme_constant_override(String(side), FRAME_MARGIN)
	add_child(frame)

	var layout := VBoxContainer.new()
	layout.name = "Layout"
	layout.add_theme_constant_override("separation", FRAME_GAP)
	frame.add_child(layout)

	layout.add_child(_build_toolbar())

	_split = HSplitContainer.new()
	_split.name = "Split"
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.add_theme_constant_override("separation", FRAME_GAP)
	layout.add_child(_split)
	_split.add_child(_build_canvas_side())
	_split.add_child(_build_tabs())

	layout.add_child(_build_status_bar())
	_layout_split.call_deferred()


# 顶部工具栏 = 两行 HBox/HFlow(窄屏不溢出):第一行标题 + 文件组 + 视图组,
# 第二行编辑组(撤销/重做/复制/剪切/粘贴/清除/水平·垂直镜像)。
func _build_toolbar() -> Control:
	var bar := PanelContainer.new()
	bar.name = "Toolbar"
	bar.add_theme_stylebox_override("panel", UiFactory.panel_box(false))
	var rows := VBoxContainer.new()
	rows.name = "ToolbarRows"
	rows.add_theme_constant_override("separation", 4)
	bar.add_child(rows)

	var main := HBoxContainer.new()
	main.name = "ToolbarMain"
	main.add_theme_constant_override("separation", 6)
	rows.add_child(main)
	main.add_child(UiFactory.label("地图编辑器", 32, UiFactory.C_ACCENT))
	main.add_child(_group_label("文件"))
	main.add_child(_action_button("新建", _on_new_pressed))
	main.add_child(_action_button("打开", _on_open_pressed))
	main.add_child(_action_button("保存", _on_save_pressed))
	main.add_child(_action_button("导出", _on_export_pressed))
	main.add_child(_action_button("导出并加载", _on_export_load_pressed))
	main.add_child(_group_label("视图"))
	_preview_btn = _action_button("预览:关", _on_preview_toggled)
	main.add_child(_preview_btn)
	main.add_child(_action_button("返回", _on_back_pressed))

	var actions := HFlowContainer.new()
	actions.name = "ToolbarActions"
	actions.add_theme_constant_override("h_separation", 6)
	actions.add_theme_constant_override("v_separation", 4)
	rows.add_child(actions)
	actions.add_child(_group_label("编辑"))
	actions.add_child(_action_button("撤销", _on_undo_pressed))
	actions.add_child(_action_button("重做", _on_redo_pressed))
	actions.add_child(_action_button("复制", _on_copy_pressed))
	actions.add_child(_action_button("剪切", _on_cut_pressed))
	actions.add_child(_action_button("粘贴", _on_paste_pressed))
	actions.add_child(_action_button("清除", _on_clear_sel_pressed))
	actions.add_child(_action_button("水平镜像", _on_mirror_h_pressed))
	actions.add_child(_action_button("垂直镜像", _on_mirror_v_pressed))
	return bar


func _group_label(text: String) -> Label:
	return UiFactory.label(text, 16, UiFactory.C_TEXT_MUTE)


func _action_button(text: String, cb: Callable) -> Button:
	# 96×36 = 内容驱动(16px 字 + UiFactory._btn_box 的 40/20 内容边距);不写绝对坐标。
	var b := UiFactory.menu_button(text, 16, Vector2(96, 36), "quiet")
	b.pressed.connect(cb)
	return b


# 左半:**竖直工具列**(Photoshop/Inkscape/Aseprite 的 tool palette)+ 画布 host。
# 工具不再横铺一整行:竖向排布把"操作栏/工具/画布"的视觉重量分开,画布占回主导。
func _build_canvas_side() -> Control:
	var side := HBoxContainer.new()
	side.name = "CanvasSide"
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", FRAME_GAP)

	var tool_col := VBoxContainer.new()
	tool_col.name = "ToolStrip"
	tool_col.custom_minimum_size = Vector2(96, 0)
	tool_col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	tool_col.add_theme_constant_override("separation", 4)
	side.add_child(tool_col)
	tool_col.add_child(_group_label("工具"))
	for key in TOOL_LABELS:
		var b := UiFactory.menu_button(String(TOOL_LABELS[key]), 16, Vector2(96, 40), "quiet")
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_select_tool.bind(key))
		tool_col.add_child(b)
		_tool_buttons[key] = b

	_canvas_host = PanelContainer.new()
	_canvas_host.name = "CanvasHost"
	_canvas_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas_host.add_theme_stylebox_override("panel", UiFactory.panel_box(false))
	side.add_child(_canvas_host)

	canvas = CANVAS_SCRIPT.new() as EditorCanvas
	canvas.name = "Canvas"
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas_host.add_child(canvas)
	return side


# 右半:TabContainer(最小宽 320;默认宽 400 由 _layout_split 推 divider)。
func _build_tabs() -> Control:
	_tabs = TabContainer.new()
	_tabs.name = "RightTabs"
	_tabs.custom_minimum_size = Vector2(TAB_MIN_W, 0)
	_tabs.size_flags_horizontal = Control.SIZE_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(_build_layers_tab())
	_tabs.add_child(_build_palette_tab())
	_tabs.add_child(_build_selection_meta_tab())
	_tabs.add_child(_build_report_tab())
	_tabs.set_tab_title(0, "图层")
	_tabs.set_tab_title(1, "调色板")
	_tabs.set_tab_title(2, "选区 & meta")
	_tabs.set_tab_title(3, "校验消息")
	return _tabs


# 让右侧初始宽度 = TAB_DEFAULT_W(可继续拖拽):SplitContainer 默认按子节点最小尺寸分。
func _layout_split() -> void:
	if _split == null or _tabs == null:
		return
	await get_tree().process_frame
	# SplitContainer 的 divider 起始位置按子节点最小尺寸定;负 offset 把 divider 右移(加宽右栏),
	# 正值会被钳回最小宽度 ⇒ 用 -TAB_DEFAULT_W 把右栏初始宽度设成 400(之后可自由拖拽)。
	_split.split_offset = -int(TAB_DEFAULT_W)


# Tab 页统一形态:ScrollContainer(只竖向滚) → VBoxContainer(内容)。返回 [scroll, body]。
func _make_scroll_tab(node_name: String) -> Array:
	var scroll := ScrollContainer.new()
	scroll.name = node_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var body := VBoxContainer.new()
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	scroll.add_child(body)
	scroll.get_v_scroll_bar().theme_type_variation = &"Kit"
	return [scroll, body]


func _build_layers_tab() -> Control:
	var pair := _make_scroll_tab("Layers")
	var body: VBoxContainer = pair[1]
	body.add_child(_section_label("图层(点名字 = 当前编辑层;勾选 = 显示)"))
	for L in EditorConstants.LAYER_COUNT:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var btn := UiFactory.menu_button(String(EditorConstants.LAYER_NAMES[L]), 16,
				Vector2(0, 34), "quiet")
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_layer_selected.bind(L))
		row.add_child(btn)
		var vis := CheckButton.new()
		vis.button_pressed = true
		vis.tooltip_text = "显示/隐藏该层"
		UiFactory.style_check(vis, 16)
		vis.toggled.connect(_on_layer_visible_toggled.bind(L))
		row.add_child(vis)
		body.add_child(row)
		_layer_rows.append({"button": btn, "visible": vis})
	return pair[0]


func _build_palette_tab() -> Control:
	var pair := _make_scroll_tab("Palette")
	var body: VBoxContainer = pair[1]

	body.add_child(_section_label("调色板(点选 = 当前画笔纹理)"))
	var pal := GridContainer.new()
	pal.name = "PaletteGrid"
	pal.columns = PALETTE_COLUMNS
	pal.add_theme_constant_override("h_separation", 4)
	pal.add_theme_constant_override("v_separation", 4)
	body.add_child(pal)
	_build_palette(pal)

	body.add_child(_section_label("画刷"))
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 8)
	size_row.add_child(UiFactory.label("画刷(格)", 16, UiFactory.C_TEXT_DIM))
	var brush_opt := OptionButton.new()
	brush_opt.name = "BrushSizeOption"
	brush_opt.tooltip_text = "画刷格数(1 格 = 4 子格)"
	for n in [1, 3, 5, 7, 9]:
		var idx := brush_opt.item_count
		brush_opt.add_item(str(n))
		brush_opt.set_item_metadata(idx, n)
	brush_opt.selected = 0
	brush_opt.item_selected.connect(func(i: int) -> void:
		_on_brush_size_changed(float(brush_opt.get_item_metadata(i))))
	size_row.add_child(brush_opt)
	body.add_child(size_row)

	# 颜色:只有背景颜色层 3-6 用得到;纹理层落笔仍用调色板。
	body.add_child(_section_label("颜色(背景层 3-6:画笔 / 渐变终点)"))
	var color_row := HBoxContainer.new()
	color_row.add_theme_constant_override("separation", 8)
	color_row.add_child(UiFactory.label("画笔", 16, UiFactory.C_TEXT_DIM))
	_color_btn = ColorPickerButton.new()
	_color_btn.name = "BrushColor"
	_color_btn.color = _color_value
	_color_btn.custom_minimum_size = Vector2(64, 32)
	_color_btn.tooltip_text = "画笔颜色(只作用于颜色层 3-6)"
	_color_btn.color_changed.connect(func(c: Color) -> void: _color_value = c)
	color_row.add_child(_color_btn)
	color_row.add_child(UiFactory.label("渐变终点", 16, UiFactory.C_TEXT_DIM))
	_gradient_end_btn = ColorPickerButton.new()
	_gradient_end_btn.name = "GradientEndColor"
	_gradient_end_btn.color = _gradient_end
	_gradient_end_btn.custom_minimum_size = Vector2(64, 32)
	_gradient_end_btn.tooltip_text = "渐变终点颜色(只作用于颜色层 3-6)"
	_gradient_end_btn.color_changed.connect(func(c: Color) -> void: _gradient_end = c)
	color_row.add_child(_gradient_end_btn)
	body.add_child(color_row)
	return pair[0]


func _build_selection_meta_tab() -> Control:
	var pair := _make_scroll_tab("SelectionMeta")
	var body: VBoxContainer = pair[1]

	body.add_child(_section_label("选区(选框工具拖矩形;Ctrl+C/X/V、Del、H/V)"))
	_selection_info = UiFactory.label("无选区", 16, UiFactory.C_TEXT_DIM)
	_selection_info.name = "SelectionInfo"
	body.add_child(_selection_info)
	var sel_grid := GridContainer.new()
	sel_grid.columns = 3
	sel_grid.add_theme_constant_override("h_separation", 4)
	sel_grid.add_theme_constant_override("v_separation", 4)
	var sel_actions := [
		["复制", _on_copy_pressed], ["剪切", _on_cut_pressed], ["粘贴", _on_paste_pressed],
		["清除", _on_clear_sel_pressed], ["水平镜像", _on_mirror_h_pressed], ["垂直镜像", _on_mirror_v_pressed],
	]
	for pair_action in sel_actions:
		var b := UiFactory.menu_button(String(pair_action[0]), 16, Vector2(96, 34), "quiet")
		b.pressed.connect(pair_action[1])
		sel_grid.add_child(b)
	body.add_child(sel_grid)

	body.add_child(_section_label("出生点 / 复活点 / 敌人(点模式再点画布)"))
	var meta_grid := GridContainer.new()
	meta_grid.columns = 3
	meta_grid.add_theme_constant_override("h_separation", 4)
	meta_grid.add_theme_constant_override("v_separation", 4)
	for key in META_LABELS:
		var b := UiFactory.menu_button(String(META_LABELS[key]), 16, Vector2(96, 34), "quiet")
		b.pressed.connect(_set_meta_mode.bind(key))
		meta_grid.add_child(b)
		_meta_buttons[key] = b
	body.add_child(meta_grid)
	_meta_info = UiFactory.label("", 16, UiFactory.C_TEXT_DIM)
	_meta_info.name = "MetaInfo"
	body.add_child(_meta_info)
	var clear_meta_btn := UiFactory.menu_button("清空全部 meta", 16, Vector2(200, 34), "quiet")
	clear_meta_btn.pressed.connect(_on_clear_meta_pressed)
	body.add_child(clear_meta_btn)
	return pair[0]


func _build_report_tab() -> Control:
	var body := VBoxContainer.new()
	body.name = "Report"
	body.add_theme_constant_override("separation", 6)
	body.add_child(_section_label("校验 / 消息"))
	var validate_btn := UiFactory.menu_button("校验地图", 16, Vector2(160, 34), "quiet")
	validate_btn.pressed.connect(_on_validate_pressed)
	body.add_child(validate_btn)
	_output = RichTextLabel.new()
	_output.name = "Output"
	_output.custom_minimum_size = Vector2(0, 180)
	_output.bbcode_enabled = false
	_output.scroll_following = true
	_output.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_output)
	return body


func _build_status_bar() -> Control:
	var bar := PanelContainer.new()
	bar.name = "StatusBar"
	bar.add_theme_stylebox_override("panel", UiFactory.panel_box(false))
	var row := HBoxContainer.new()
	row.name = "StatusRow"
	row.add_theme_constant_override("separation", UiFactory.SP_2)
	_status = UiFactory.label("", 16, UiFactory.C_TEXT_DIM)
	_status.name = "StatusText"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	row.add_child(_status)
	_path_label = UiFactory.label("未命名", 16, UiFactory.C_TEXT_DIM)
	_path_label.name = "PathText"
	_path_label.clip_text = true
	row.add_child(_path_label)
	bar.add_child(row)
	return bar


func _section_label(text: String) -> Label:
	return UiFactory.label(text, 16, UiFactory.C_TEXT_DIM)


func _build_palette(container: GridContainer) -> void:
	var defs = JSON.parse_string(FileAccess.get_file_as_string(TILE_DEFS_PATH))
	var tiles: Dictionary = defs.get("tiles", {}) if defs is Dictionary else {}
	var ids: Array[int] = []
	for k in tiles:
		ids.append(int(String(k)))
	ids.sort()
	_texture_ids = ids
	var src := TerrainAtlas.source_image()
	for tid in ids:
		var b := Button.new()
		b.custom_minimum_size = Vector2(64, 64)      # 缩略图边长,内容驱动(等 SP_*/T_* token 后替换)
		b.tooltip_text = "%d %s" % [tid, String((tiles[str(tid)] as Dictionary).get("name", ""))]
		var img: Image = src.get_region(TerrainAtlas.source_rect(tid - 1))
		b.icon = ImageTexture.create_from_image(img)
		b.expand_icon = false
		UiFactory.style_button(b, "quiet")
		b.pressed.connect(_on_palette_pressed.bind(tid))
		container.add_child(b)
		_palette_buttons.append(b)
	_on_palette_pressed(_texture_ids[0] if not _texture_ids.is_empty() else 1)



func _refresh_palette_texture() -> void:
	if _texture_ids.is_empty():
		return
	var tex := EditorDesc.tex_of(_paint_desc)
	if tex == 0:
		return
	_paint_desc = EditorDesc.neutral_desc(tex)
	_mark_palette(tex)


func _mark_palette(tex: int) -> void:
	for i in _palette_buttons.size():
		var b := _palette_buttons[i]
		b.modulate = UiFactory.C_WHITE if _texture_ids[i] == tex else Color(1, 1, 1, 0.55)


# ── 交互 ───────────────────────────────────────────────────────────────

func _on_palette_pressed(tid: int) -> void:
	_paint_desc = EditorDesc.neutral_desc(tid)
	if _tool == TOOL_EYEDROP or _tool == TOOL_ERASER:
		_select_tool(TOOL_BRUSH)
	_mark_palette(tid)
	canvas.set_preview_desc(_paint_desc)


func _select_tool(key: String) -> void:
	_tool = key
	for k in _tool_buttons:
		var b: Button = _tool_buttons[k]
		b.theme_type_variation = &"BtnAccent" if k == key else &"BtnQuiet"
		b.modulate = UiFactory.C_WHITE
	canvas.set_preview_desc(0 if key == TOOL_ERASER else _paint_desc)
	if key == TOOL_SELECT:
		_set_message("选框:在画布上拖出矩形", false)
	elif key == TOOL_GRADIENT:
		_set_message("渐变:在颜色层(3-6)从起点拖到终点(两端颜色见右栏「颜色」)", false)


func _on_brush_size_changed(v: float) -> void:
	_brush_cells = maxi(1, int(v))
	canvas.set_brush_preview(_brush_cells)


func _on_layer_selected(L: int) -> void:
	doc.active_layer = L
	canvas.set_active_layer(L)
	_sync_layer_rows()
	_update_status(Vector2i.ZERO, false)


func _on_layer_visible_toggled(on: bool, L: int) -> void:
	canvas.set_layer_visible(L, on)


func _sync_layer_rows() -> void:
	for L in _layer_rows.size():
		var row: Dictionary = _layer_rows[L]
		var b: Button = row["button"]
		b.modulate = UiFactory.C_WHITE if L == doc.active_layer else Color(1, 1, 1, 0.6)


func _on_pointer_down(sub: Vector2i, button: int, _shift: bool, _ctrl: bool) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	if _meta_mode != META_NONE:
		_place_meta_at(sub)
		return
	_painting = true
	_stroke_begin = sub
	_has_last = false
	match _tool:
		TOOL_SELECT:
			_selecting = true
			_select_start = _cell_of(sub)
			doc.set_selection(_sub_rect_cells(_select_start, _select_start))
			canvas.set_selection(doc.selection)
			_update_selection_info()
		TOOL_GRADIENT:
			pass                              # 渐变在 pointer_up 时按起点/终点落笔
		TOOL_BRUSH, TOOL_ERASER:
			doc.begin_stroke()
			_stamp(sub)
			_last_cell = _cell_of(sub)
			_has_last = true
		TOOL_BUCKET:
			doc.begin_stroke()
			doc.flood_fill(sub, _current_value())
			doc.end_stroke()
			_painting = false
		TOOL_EYEDROP:
			_paint_desc = doc.sample(sub.x, sub.y)
			_refresh_palette_texture()
			_select_tool(TOOL_BRUSH)
			_painting = false
		_: 
			doc.begin_stroke()


func _on_pointer_drag(sub: Vector2i) -> void:
	if not _painting:
		return
	if _tool == TOOL_SELECT:
		doc.set_selection(_sub_rect_cells(_select_start, _cell_of(sub)))
		canvas.set_selection(doc.selection)
		canvas.queue_redraw()
		_update_selection_info()
		return
	if _tool == TOOL_BRUSH or _tool == TOOL_ERASER:
		if _has_last:
			var from := _last_cell
			var to := _cell_of(sub)
			for c in EditorGeometry.line_cells(from.x, from.y, to.x, to.y):
				_stamp_cell(c)
			_last_cell = to
		else:
			_stamp(sub)
			_has_last = true
		_last_cell = _cell_of(sub)


func _on_pointer_up(sub: Vector2i) -> void:
	if not _painting:
		return
	match _tool:
		TOOL_SELECT:
			_selecting = false
			doc.set_selection(_sub_rect_cells(_select_start, _cell_of(sub)))
			canvas.set_selection(doc.selection)
			_update_selection_info()
		TOOL_GRADIENT:
			var res := doc.paint_gradient(_stroke_begin, sub,
					_color_u32(_color_value), _color_u32(_gradient_end))
			if bool(res.get("ok", false)):
				_set_message("渐变已应用(%d 个子格)" % int(res.get("count", 0)), false)
			else:
				_set_message("渐变失败:%s" % String(res.get("error", "")), true)
		TOOL_LINE:
			for c in EditorGeometry.line_cells(
					_cell_of(_stroke_begin).x, _cell_of(_stroke_begin).y,
					_cell_of(sub).x, _cell_of(sub).y):
				_stamp_cell(c)
		TOOL_RECT:
			var r := EditorGeometry.norm_region(
					_cell_of(_stroke_begin).x, _cell_of(_stroke_begin).y,
					_cell_of(sub).x, _cell_of(sub).y)
			for y in range(int(r["y"]), int(r["y"]) + int(r["h"])):
				for x in range(int(r["x"]), int(r["x"]) + int(r["w"])):
					_stamp_cell(Vector2i(x, y))
	doc.end_stroke()
	_painting = false
	_has_last = false


# 格矩形(含两端)→ 子格矩形(选区单位是子格)。
func _sub_rect_cells(a: Vector2i, b: Vector2i) -> Rect2i:
	var r := EditorGeometry.norm_region(a.x, a.y, b.x, b.y)
	var s := EditorConstants.SUB_PER_CELL
	return Rect2i(int(r["x"]) * s, int(r["y"]) * s, int(r["w"]) * s, int(r["h"]) * s)


func _stamp(sub: Vector2i) -> void:
	_stamp_cell(_cell_of(sub))


func _stamp_cell(cell: Vector2i) -> void:
	var off := EditorGeometry.brush_offsets(_brush_cells)
	var value := _current_value()
	var cells: Array[Vector2i] = []
	for dy in range(-int(off["lo"]), int(off["hi"]) + 1):
		for dx in range(-int(off["lo"]), int(off["hi"]) + 1):
			var cx := cell.x + dx
			var cy := cell.y + dy
			for sy in EditorConstants.SUB_PER_CELL:
				for sx in EditorConstants.SUB_PER_CELL:
					cells.append(Vector2i(cx * EditorConstants.SUB_PER_CELL + sx,
							cy * EditorConstants.SUB_PER_CELL + sy))
	doc.set_cells(cells, value)


func _current_value() -> int:
	if _tool == TOOL_ERASER:
		return 0
	if EditorConstants.is_color_layer(doc.active_layer):
		return _color_u32(_color_value)
	return _paint_desc


func _cell_of(sub: Vector2i) -> Vector2i:
	return Vector2i(floori(sub.x / float(EditorConstants.SUB_PER_CELL)),
			floori(sub.y / float(EditorConstants.SUB_PER_CELL)))


static func _color_u32(c: Color) -> int:
	var r := clampi(int(round(c.r * 255.0)), 0, 255)
	var g := clampi(int(round(c.g * 255.0)), 0, 255)
	var b := clampi(int(round(c.b * 255.0)), 0, 255)
	var a := clampi(int(round(c.a * 255.0)), 0, 255)
	return (r << 24) | (g << 16) | (b << 8) | a


# ── doc / 画布 回调 ─────────────────────────────────────────────────────

func _on_doc_changed(_layer: int, _subcells: PackedInt32Array) -> void:
	_update_status(Vector2i.ZERO, false)


func _on_doc_structure_changed() -> void:
	canvas.refresh()
	_sync_layer_rows()


func _on_cursor_moved(sub: Vector2i) -> void:
	_update_status(sub, true)


func _on_zoom_changed(_zoom: float) -> void:
	_update_status(Vector2i.ZERO, false)


func _on_doc_meta_changed() -> void:
	# meta 改动不发 changed(没有 cells 变更):标记画在 _draw 里,重画即可。
	canvas.queue_redraw()
	_sync_meta_info()
	_update_status(Vector2i.ZERO, false)


# ── 后置项:选区 / 剪贴板 / meta / 预览 ───────────────────────────────

func get_preview() -> Control:
	return _preview


func is_preview_on() -> bool:
	return _preview_on


func set_preview(on: bool) -> void:
	if _preview == null:
		return
	_preview_on = on
	_preview.visible = on
	_preview.set_active(on)
	if _preview_btn != null:
		_preview_btn.text = "预览:开" if on else "预览:关"
	if on:
		_preview_last_origin = canvas.origin
		_preview_last_zoom = canvas.zoom
		_preview.set_camera(canvas.origin, canvas.zoom)
	_set_message("预览:%s" % ("开(复用游戏渲染管线)" if on else "关(快速画布)"), false)


func _on_preview_toggled() -> void:
	set_preview(not _preview_on)


func _build_preview() -> void:
	if _preview != null:
		return
	_preview = PREVIEW_SCRIPT.new()
	_preview.name = "Preview"
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE     # 让画布继续收鼠标(预览是只读层)
	_canvas_host.add_child(_preview)
	_preview.setup(doc)
	_preview.set_active(false)
	_preview.visible = false


func _set_meta_mode(key: String) -> void:
	_meta_mode = key
	for k in _meta_buttons:
		var b: Button = _meta_buttons[k]
		b.modulate = UiFactory.C_WHITE if k == key else Color(1, 1, 1, 0.6)
	if key != META_NONE:
		_set_message("放置模式:%s(点画布放置;再点一次「编辑地形」退出)" % String(META_LABELS.get(key, key)), false)


func _place_meta_at(sub: Vector2i) -> void:
	var cell := _cell_of(sub)
	var placed := -1
	match _meta_mode:
		META_PLAYER:
			placed = doc.add_player(cell)
		META_RESPAWN1:
			placed = doc.add_respawn(1, cell)
		META_RESPAWN2:
			placed = doc.add_respawn(2, cell)
		META_ENEMY:
			placed = doc.add_enemy("slime", cell)
	if placed >= 0:
		_set_message("已放置%s @ (%d,%d)" % [String(META_LABELS.get(_meta_mode, _meta_mode)), cell.x, cell.y], false)
	else:
		_set_message("放置失败:%s" % String(META_LABELS.get(_meta_mode, _meta_mode)), true)


func _sync_meta_info() -> void:
	if _meta_info == null or doc == null or doc.map.is_empty():
		return
	var players: Array = doc.map.get("players", [])
	var respawns: Array = doc.map.get("respawns", [])
	var enemies: Array = doc.map.get("enemies", [])
	var side1 := 0
	var side2 := 0
	for r in respawns:
		if int((r as Dictionary).get("side", 0)) == 1:
			side1 += 1
		else:
			side2 += 1
	_meta_info.text = "出生点 %d · 复活点 侧1 %d / 侧2 %d · 敌人 %d" % [
		players.size(), side1, side2, enemies.size()]


func _on_clear_meta_pressed() -> void:
	var n := doc.clear_meta("all")
	_set_message("已清空 meta(%d 条)" % n, false)
	_sync_meta_info()


func _update_selection_info() -> void:
	if _selection_info == null:
		return
	if doc == null or not doc.has_selection():
		_selection_info.text = "无选区"
		return
	var r := doc.selection
	_selection_info.text = "%d×%d 子格 @ (%d,%d)" % [r.size.x, r.size.y, r.position.x, r.position.y]


func _on_copy_pressed() -> void:
	var res := doc.copy_selection()
	if bool(res.get("ok", false)):
		_set_message("已复制 %d 个子格" % int(res.get("count", 0)), false)
	else:
		_set_message("复制失败:%s" % String(res.get("error", "")), true)


func _on_cut_pressed() -> void:
	var res := doc.cut_selection()
	if bool(res.get("ok", false)):
		_set_message("已剪切到剪贴板", false)
	else:
		_set_message("剪切失败:%s" % String(res.get("error", "")), true)


func _on_paste_pressed() -> void:
	if doc.clipboard.is_empty():
		_set_message("剪贴板是空的(先复制或剪切一块)", true)
		return
	var at := Vector2i.ZERO
	if doc.has_selection():
		at = doc.selection.position / EditorConstants.SUB_PER_CELL
	var res := doc.paste_clipboard(at)
	if bool(res.get("ok", false)):
		_set_message("已粘贴到格 %s" % str(at), false)
	else:
		_set_message("粘贴失败:%s" % String(res.get("error", "")), true)


func _on_clear_sel_pressed() -> void:
	var n := doc.clear_selection_cells()
	_set_message("已清除选区(%d 个子格)" % n, false)


func _mirror(axis: String) -> void:
	if not doc.has_selection():
		_set_message("先框选一块,再镜像", false)
		return
	var res := doc.mirror_selection(axis)
	if bool(res.get("ok", false)):
		_set_message("镜像 %s:改动 %d 个子格" % ["水平" if axis == "h" else "垂直", int(res.get("count", 0))], false)
	else:
		_set_message("镜像失败:%s" % String(res.get("error", "")), true)


func _on_mirror_h_pressed() -> void:
	_mirror("h")


func _on_mirror_v_pressed() -> void:
	_mirror("v")


# ── 动作 ───────────────────────────────────────────────────────────────

func _on_undo_pressed() -> void:
	if not doc.undo():
		_set_message("没有可撤销的操作", true)


func _on_redo_pressed() -> void:
	if not doc.redo():
		_set_message("没有可重做的操作", true)


func _on_new_pressed() -> void:
	var ctx := {}
	var dlg := _open_dialog("新建地图", "新建", func(body: VBoxContainer) -> void:
		ctx["name"] = _dialog_line(body, "名字", "untitled")
		ctx["w"] = _dialog_line(body, "宽(格)", "125")
		ctx["h"] = _dialog_line(body, "高(格)", "75"))
	dlg.confirmed.connect(func() -> void:
		var size := EditorValidate.clamp_map_size((ctx["w"] as LineEdit).text,
				(ctx["h"] as LineEdit).text)
		new_map(int(size["w"]), int(size["h"]), (ctx["name"] as LineEdit).text))


func _on_open_pressed() -> void:
	_open_dialog("打开地图", "关闭", func(body: VBoxContainer) -> void:
		var maps := EditorIO.list_maps()
		if maps.is_empty():
			body.add_child(UiFactory.label("没有找到 .cyrm", 16, UiFactory.C_TEXT_DIM))
			return
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(520, 400)      # 列表可视区 = 内容驱动
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		body.add_child(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 6)
		scroll.add_child(list)
		for path in maps:
			list.add_child(_map_card(path)))


func _on_save_pressed() -> void:
	if _path != "":
		save_to(_path)
	else:
		_on_save_as_pressed()


func _on_save_as_pressed() -> void:
	var ctx := {}
	var dlg := _open_dialog("保存为", "保存", func(body: VBoxContainer) -> void:
		ctx["path"] = _dialog_line(body, "路径", EditorIO.default_target(_map_name())))
	dlg.confirmed.connect(func() -> void:
		save_to((ctx["path"] as LineEdit).text))


func _on_validate_pressed() -> void:
	validate()


# ── P3 导出两动作(公开 API;探针也走这里) ─────────────────────────────
# 导出(只写文件):target = "user" 落 user://maps/;target = "exe" 复制到 exe 同目录。
func export_to(target: String) -> Dictionary:
	return _export_target(_map_name(), target == "exe")


func _export_target(map_name: String, to_exe_dir: bool) -> Dictionary:
	var res: Dictionary
	if to_exe_dir:
		res = EditorIO.copy_to_exe_dir(doc.map, map_name)
	else:
		res = EditorIO.save_path(EditorIO.default_target(map_name), doc.map)
	if not bool(res.get("ok", false)):
		_append_output("导出失败:%s" % String(res.get("error", "")))
		_set_message("导出失败:%s" % String(res.get("error", "")), true)
		return res
	_path = String(res.get("path", _path))
	doc.dirty = false
	_append_output("已导出:%s(%d 字节)" % [_path, int(res.get("bytes", 0))])
	_set_message("已导出:%s" % _path, false)
	_update_status(Vector2i.ZERO, false)
	return res


# 导出并加载到游戏内:写文件 → Settings.sp_map_path → Settings.save() → MazeGenerator.set_map_file()。
# ★ switch_scene=true 时回单人开局;persist=false 只改内存(场景探针用,避免动用户 settings.cfg)。
func export_and_load(path: String, persist: bool = true, switch_scene: bool = true) -> Dictionary:
	if path.is_empty():
		return {"ok": false, "error": "exportAndLoad: 路径为空"}
	var res := save_to(path)
	if not bool(res.get("ok", false)):
		return res
	Settings.sp_map_path = path
	if persist:
		Settings.save()
	MazeGenerator.set_map_file(path)
	RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()
	Level0.pvp_mode = false
	CombatComponent.pvp_arena = false
	_set_message("已导出并设为单人地图:%s" % path, false)
	_append_output("下一次单人开局将使用:%s(PvP 不受影响:联机地图由大厅/服务端下发的 path 覆盖)" % path)
	if switch_scene:
		get_tree().change_scene_to_file("res://scenes/level_0.tscn")
	return res


func _on_export_pressed() -> void:
	var ctx := {}
	var dlg := _open_dialog("导出到…", "导出", func(body: VBoxContainer) -> void:
		ctx["name"] = _dialog_line(body, "名字", _map_name())
		var target := OptionButton.new()
		target.add_item("user://maps(默认,可写)", 0)
		target.add_item("exe 同目录(外置地图优先)", 1)
		UiFactory.style_control(target, 16)
		body.add_child(target)
		ctx["target"] = target)
	dlg.confirmed.connect(func() -> void:
		_export_named((ctx["name"] as LineEdit).text, (ctx["target"] as OptionButton).selected == 1))


func _export_named(map_name: String, to_exe_dir: bool) -> void:
	_export_target(map_name, to_exe_dir)


func _on_export_load_pressed() -> void:
	if _path == "":
		export_and_load(EditorIO.default_target(_map_name()))
		return
	export_and_load(_path)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# ── 弹层(标准 ConfirmationDialog / AcceptDialog;不再自绘居中 PanelContainer)──
# ★ 内容 = dialog 的自定义子容器(VBoxContainer);窗口尺寸由内容最小尺寸推,不用 position/size 手摆。
# ★ 取消/确认走标准按钮:确认回调只做动作,关窗由 dialog 自己收(dialog_hide_on_ok 默认 true)。

func _open_dialog(title_text: String, ok_text: String, fill: Callable) -> ConfirmationDialog:
	_close_popup()
	var dlg := ConfirmationDialog.new()
	dlg.name = "Dialog"
	dlg.title = title_text
	dlg.ok_button_text = ok_text
	dlg.cancel_button_text = "取消"
	dlg.theme = THEME
	dlg.theme_type_variation = &"Kit"
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiFactory.SP_2)
	dlg.add_child(body)
	_popup = dlg
	fill.call(body)
	add_child(dlg)
	# 尺寸 = 内容最小尺寸 + 弹层内边距(内容驱动;等 T1 的 SP_* token 合入后替换)。
	var want := body.get_combined_minimum_size() + Vector2(DIALOG_PAD * 2, DIALOG_PAD * 3)
	dlg.popup_centered(Vector2i(int(want.x), int(want.y)))
	return dlg


func _close_popup() -> void:
	if is_instance_valid(_popup):
		_popup.hide()
		_popup.queue_free()
	_popup = null


func _dialog_line(parent: VBoxContainer, label_text: String, default_text: String) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiFactory.SP_2)
	row.add_child(UiFactory.label(label_text, 16, UiFactory.C_TEXT_DIM))
	var edit := LineEdit.new()
	edit.text = default_text
	edit.custom_minimum_size = Vector2(320, 36)      # 输入框宽度 = 内容驱动
	UiFactory.style_line_edit(edit)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	parent.add_child(row)
	return edit


# 打开弹层里的地图卡片(缩略图复用 MapCatalog,与主菜单选图同一套缓存/显示名)。
func _map_card(path: String) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UiFactory.row_box())
	card.custom_minimum_size = Vector2(420, 0)       # 卡片最小宽 = 内容驱动
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			open_path(path)
			_close_popup())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiFactory.SP_2)
	card.add_child(row)
	var thumb := TextureRect.new()
	thumb.texture = MapCatalog.texture(path, 2)
	thumb.custom_minimum_size = Vector2(120, 72)      # 缩略图框 = 内容驱动
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	row.add_child(thumb)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)
	info.add_child(UiFactory.label(MapCatalog.display_name(path), 16, UiFactory.C_TEXT))
	info.add_child(UiFactory.label(path, 16, UiFactory.C_TEXT_DIM))
	return card


# ── 校验输出 / 状态 / 快捷键 ───────────────────────────────────────────

func _show_report(report: Dictionary) -> void:
	var errors: Array = report.get("errors", [])
	var warnings: Array = report.get("warnings", [])
	var lines: Array[String] = []
	lines.append("校验:%d error / %d warning" % [errors.size(), warnings.size()])
	for e in errors:
		lines.append("  [error] " + String(e))
	for w in warnings:
		lines.append("  [warn] " + String(w))
	if not errors.is_empty():
		for e in errors:
			_set_message("校验失败:%s" % String(e), true)
			break
	else:
		_set_message("校验通过(%d 条提示)" % warnings.size(), false)
	_append_output("\n".join(lines))


func _append_output(text: String) -> void:
	if _output == null:
		return
	_output.append_text(text + "\n")


func _set_message(text: String, is_error: bool) -> void:
	_message = text
	_append_output(("[FAIL] " if is_error else "") + text)
	_update_status(Vector2i.ZERO, false)


func _update_status(sub: Vector2i, _has_cursor: bool) -> void:
	if _status == null or doc == null or doc.map.is_empty():
		if _status != null:
			_status.text = _message
		return
	var cells := doc.sub_size() / EditorConstants.SUB_PER_CELL
	var wrapped := Vector2i(posmod(sub.x, doc.sub_size().x), posmod(sub.y, doc.sub_size().y))
	var desc := doc.get_subcell(wrapped.x, wrapped.y)
	var dirty := "未保存" if doc.dirty else "已保存"
	_status.text = "%s · 尺寸 %d×%d 格 · 层 %s · 工具 %s · 子格 (%d,%d) · 值 0x%08X · 缩放 %d px/子格 · %s" % [
		_message, cells.x, cells.y, String(EditorConstants.LAYER_NAMES[doc.active_layer]),
		String(TOOL_LABELS.get(_tool, _tool)), wrapped.x, wrapped.y, desc,
		int(canvas.zoom), dirty]
	_path_label.text = ("● " if doc.dirty else "") + (_path if _path != "" else "未命名")


func _register_editor_actions() -> void:
	_action("editor_undo", [KEY_Z], true)
	_action("editor_redo", [KEY_Y], true)
	_action("editor_save", [KEY_S], true)
	_action("editor_open", [KEY_O], true)
	_action("editor_zoom_in", [KEY_EQUAL, KEY_KP_ADD], true)
	_action("editor_zoom_out", [KEY_MINUS, KEY_KP_SUBTRACT], true)
	_action("editor_copy", [KEY_C], true)
	_action("editor_cut", [KEY_X], true)
	_action("editor_paste", [KEY_V], true)
	_action("editor_delete", [KEY_DELETE], false)
	_action("editor_mirror_h", [KEY_H], false)
	_action("editor_mirror_v", [KEY_V], false)


func _action(name: String, keys: Array, ctrl: bool) -> void:
	if InputMap.has_action(name):
		return
	InputMap.add_action(name)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		ev.ctrl_pressed = ctrl
		InputMap.action_add_event(name, ev)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	if event.is_action_pressed("editor_undo"):
		doc.undo()
	elif event.is_action_pressed("editor_redo"):
		doc.redo()
	elif event.is_action_pressed("editor_save"):
		save_current()
	elif event.is_action_pressed("editor_open"):
		_on_open_pressed()
	elif event.is_action_pressed("editor_zoom_in"):
		canvas.zoom_in()
	elif event.is_action_pressed("editor_zoom_out"):
		canvas.zoom_out()
	elif event.is_action_pressed("editor_copy"):
		_on_copy_pressed()
	elif event.is_action_pressed("editor_cut"):
		_on_cut_pressed()
	elif event.is_action_pressed("editor_paste"):
		_on_paste_pressed()
	elif event.is_action_pressed("editor_delete"):
		_on_clear_sel_pressed()
	elif event.is_action_pressed("editor_mirror_h"):
		_mirror("h")
	elif event.is_action_pressed("editor_mirror_v"):
		_mirror("v")
