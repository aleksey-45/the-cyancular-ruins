extends RefCounted

# 左栏「作画上下文」+ 右栏图层卡:7 层行、按层渐进披露、纹理调色板。
# 无 class_name(调用方 preload),与 editor_tools/editor_actions 同规;root 只持有并转发。

const TILE_DEFS_PATH := "res://data/tile_defs.json"

var page: Control = null
var doc: EditorDoc = null
var canvas: EditorCanvas = null
var tools = null
var tool_buttons: Dictionary = {}      # root 持有(顶栏/快捷键也读),这里共享引用只读
var tool_keys: Dictionary = {}         # 工具键 → 快捷键字母(单一来源在 root 的 TOOL_KEYS)
var texture_ids: Array[int] = []
var layer_rows: Array[Dictionary] = []
var palette_buttons: Array[Button] = []
var color_nodes: Array[Control] = []
var palette_nodes: Array[Control] = []


func setup(p: Control, d: EditorDoc, c: EditorCanvas, t, tool_btns: Dictionary,
		keys: Dictionary) -> void:
	page = p
	doc = d
	canvas = c
	tools = t
	tool_buttons = tool_btns
	tool_keys = keys


## 接线:图层 7 行(tscn 静态)+ 渐进披露的两组节点。调色板按钮是动态内容,由 build_palette 建。
func wire() -> void:
	color_nodes.clear()
	color_nodes.append(page.get_node("%ColorHint") as Control)
	color_nodes.append(page.get_node("%BrushColorRow") as Control)
	color_nodes.append(page.get_node("%GradientEndRow") as Control)
	palette_nodes.clear()
	palette_nodes.append(page.get_node("%PaletteHint") as Control)
	palette_nodes.append(page.get_node("%PaletteScroll") as Control)
	for i in EditorConstants.LAYER_COUNT:
		var row := (page.get_node("%LayerRows") as VBoxContainer).get_child(i) as HBoxContainer
		var btn := row.get_child(0) as Button
		var vis := row.get_child(1) as CheckButton
		btn.theme_type_variation = &"LayerRow"
		btn.pressed.connect(on_layer_selected.bind(i))
		vis.toggled.connect(on_layer_visible_toggled.bind(i))
		layer_rows.append({"button": btn, "visible": vis})


func build_palette(container: GridContainer) -> void:
	var defs = JSON.parse_string(FileAccess.get_file_as_string(TILE_DEFS_PATH))
	var tiles: Dictionary = defs.get("tiles", {}) if defs is Dictionary else {}
	var ids: Array[int] = []
	for k in tiles:
		ids.append(int(String(k)))
	ids.sort()
	texture_ids = ids
	var src := TerrainAtlas.source_image()
	for tid in ids:
		var b := Button.new()
		# 缩略图缩到 56px:图集源砖是 64px,但调色板要 3 列塞进 268px 左栏(64px + 按钮内边距会撑到 82)。
		b.custom_minimum_size = Vector2(56, 56)              # 缩略图边长(内容驱动)
		b.tooltip_text = "%d %s" % [tid, String((tiles[str(tid)] as Dictionary).get("name", ""))]
		var img: Image = src.get_region(TerrainAtlas.source_rect(tid - 1))
		img.resize(56, 56, Image.INTERPOLATE_NEAREST)
		b.icon = ImageTexture.create_from_image(img)
		b.expand_icon = false
		b.theme_type_variation = &"BtnCompact"
		b.toggle_mode = true                             # 选中态用按钮 pressed 样式,不再只靠 modulate
		b.pressed.connect(func() -> void: tools.set_paint_desc(EditorDesc.neutral_desc(tid)))
		container.add_child(b)
		palette_buttons.append(b)
	tools.set_paint_desc(EditorDesc.neutral_desc(texture_ids[0] if not texture_ids.is_empty() else 1))


func refresh_palette_texture() -> void:
	if texture_ids.is_empty():
		return
	var tex := EditorDesc.tex_of(tools.paint_desc)
	if tex == 0:
		return
	tools.set_paint_desc(EditorDesc.neutral_desc(tex))


func mark_palette(tex: int) -> void:
	for i in palette_buttons.size():
		var on := texture_ids[i] == tex
		palette_buttons[i].set_pressed_no_signal(on)
		palette_buttons[i].modulate = Color(1, 1, 1, 1.0 if on else 0.85)


func on_layer_selected(layer: int) -> void:
	doc.active_layer = layer
	canvas.set_active_layer(layer)
	sync_layer_rows()
	sync_tool_availability()
	if EditorConstants.is_color_layer(layer):
		page.call("notify", "颜色层:用左栏「颜色」画笔;渐变只作用于选区", false)
	else:
		page.call("notify", "纹理层:点左栏调色板选纹理;颜色工具不可用", false)


func on_layer_visible_toggled(on: bool, layer: int) -> void:
	canvas.set_layer_visible(layer, on)


## 按当前层的类型决定「工具/面板」可用性;切层后当前工具若变得不适用(渐变)⇒ 自动回画笔。
func sync_tool_availability() -> void:
	if doc == null or tools == null:
		return
	var is_color := EditorConstants.is_color_layer(doc.active_layer)
	var grad := tool_buttons.get("gradient") as Button
	if grad != null:
		grad.disabled = not is_color
		grad.tooltip_text = "渐变 (%s)%s" % [String(tool_keys.get("gradient", "")),
				"" if is_color else " · 仅颜色层 3-6"]
	for b in palette_buttons:
		b.disabled = is_color
	var pal_grid := page.get_node_or_null("%PaletteGrid") as GridContainer
	if pal_grid != null:
		pal_grid.modulate = Color(1, 1, 1, 0.45 if is_color else 1.0)
	var pal_hint := page.get_node_or_null("%PaletteHint") as Label
	if pal_hint != null:
		pal_hint.text = "纹理调色板"
		pal_hint.tooltip_text = "调色板(颜色层用「颜色」画笔)" if is_color else "点选 = 画笔纹理"
	var brush_color := page.get_node_or_null("%BrushColor") as ColorPickerButton
	var grad_color := page.get_node_or_null("%GradientEndColor") as ColorPickerButton
	if brush_color != null:
		brush_color.disabled = not is_color
	if grad_color != null:
		grad_color.disabled = not is_color
	# 渐进披露:纹理层只露调色板,颜色层只露颜色;另一组整块隐藏(不再常驻置灰)。
	for n: Control in color_nodes:
		if n != null:
			n.visible = is_color
	for n: Control in palette_nodes:
		if n != null:
			n.visible = not is_color
	if not is_color and tools.tool == "gradient":
		tools.set_tool("brush")
		page.call("notify", "当前是纹理层:渐变不可用,已切回画笔", false)


func sync_layer_rows() -> void:
	for i in layer_rows.size():
		var b: Button = (layer_rows[i] as Dictionary)["button"]
		b.theme_type_variation = &"LayerActive" if i == doc.active_layer else &"LayerRow"
		var vis: CheckButton = (layer_rows[i] as Dictionary)["visible"]
		# 当前层恒可见(canvas 语义):眼睛对它禁用并强制显示为"开",不再出现「控件说关、画布还在画」。
		var is_active := i == doc.active_layer
		vis.disabled = is_active
		vis.tooltip_text = "当前编辑层不可隐藏(先切到其它层)" if is_active else "显示/隐藏该层"
		if is_active:
			vis.set_pressed_no_signal(true)
		vis.modulate = Color(1, 1, 1, 1.0 if is_active else (0.8 if vis.button_pressed else 0.35))
