class_name UiKit
extends RefCounted

# 创建容器和通用控件，布局使用 UiDesign 的间距常量，样式来自主题类型变体。
# 控件布局与样式约定见 docs/construction/2026-11-23-ui-full-replacement-plan.md 的「实现约定」。

# ── 页面骨架 ────────────────────────────────────────────────────────────────

## 页面根:给 parent 挂一个 MarginContainer(SP_6)→ VBox(SP_5),返回 VBox 供页面填内容。
static func page(parent: Control, margin: int = UiDesign.SP_6, gap: int = UiDesign.SP_5) -> VBoxContainer:
	var margin_box := MarginContainer.new()
	margin_box.name = "Page"
	margin_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin_box.add_theme_constant_override("margin_left", margin)
	margin_box.add_theme_constant_override("margin_right", margin)
	margin_box.add_theme_constant_override("margin_top", margin)
	margin_box.add_theme_constant_override("margin_bottom", margin)
	parent.add_child(margin_box)
	var vb := VBoxContainer.new()
	vb.name = "Body"
	vb.add_theme_constant_override("separation", gap)
	margin_box.add_child(vb)
	return vb


## 顶部工具条:给 parent 挂一个 Bar 面板 + Margin(SP_4) + HBox(SP_3),返回 HBox 供调用方加按钮。
static func toolbar(parent: Control) -> HBoxContainer:
	var barrier := MarginContainer.new()
	barrier.add_theme_constant_override("margin_left", UiDesign.SP_4)
	barrier.add_theme_constant_override("margin_right", UiDesign.SP_4)
	barrier.add_theme_constant_override("margin_top", UiDesign.SP_2)
	barrier.add_theme_constant_override("margin_bottom", UiDesign.SP_2)
	var row := HBoxContainer.new()
	row.name = "Toolbar"
	row.add_theme_constant_override("separation", UiDesign.SP_3)
	barrier.add_child(row)
	var panel := UiDesign.ui_panel("bar")
	panel.add_child(barrier)
	parent.add_child(panel)
	return row


## 底部状态条:Bar 面板 + HBox(SP_3),返回 HBox;文本用 UiDesign.ui_label(..., "dim")。
static func status_bar(parent: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "StatusBar"
	row.add_theme_constant_override("separation", UiDesign.SP_3)
	var barrier := MarginContainer.new()
	barrier.add_theme_constant_override("margin_left", UiDesign.SP_4)
	barrier.add_theme_constant_override("margin_right", UiDesign.SP_4)
	barrier.add_theme_constant_override("margin_top", UiDesign.SP_1)
	barrier.add_theme_constant_override("margin_bottom", UiDesign.SP_1)
	barrier.add_child(row)
	var panel := UiDesign.ui_panel("bar")
	panel.add_child(barrier)
	parent.add_child(panel)
	return row


# ── 分栏 / 分页 ────────────────────────────────────────────────────────────

## 左右分栏:HSplitContainer(Kit),返回容器;调用方 add_child 左右两半。
static func split(parent: Control, min_left: int = 320, min_right: int = 320) -> HSplitContainer:
	var s := HSplitContainer.new()
	s.name = "Split"
	s.add_theme_constant_override("minimum_grab_thickness", UiDesign.SP_2)
	s.add_theme_constant_override("separation", UiDesign.SP_2)
	s.set_meta("ui_kit_min", Vector2i(min_left, min_right))
	parent.add_child(s)
	return s


## 右侧 Tab 页:TabContainer(Kit),返回容器;页面用 add_tab() 加。
static func tab_panel(parent: Control, min_width: int = 320) -> TabContainer:
	var tabs := TabContainer.new()
	tabs.name = "Tabs"
	tabs.custom_minimum_size = Vector2(min_width, 0)
	parent.add_child(tabs)
	return tabs


## 给 TabContainer 加一页(标题 + 可滚动内容),返回内容 VBox(SP_4)。
static func add_tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", UiDesign.SP_4)
	scroll.add_child(vb)
	return vb


# ── 卡片 / 分区 / 列表行 ───────────────────────────────────────────────────

## 卡片:Card 面板 + VBox(SP_3) + H2 标题;返回 body VBox 供调用方填内容。
static func card(parent: Control, title: String = "") -> VBoxContainer:
	var panel := UiDesign.ui_panel("card")
	parent.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", UiDesign.SP_3)
	var barrier := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		barrier.add_theme_constant_override("margin_" + side, UiDesign.SP_4)
	barrier.add_child(vb)
	panel.add_child(barrier)
	if title != "":
		vb.add_child(UiDesign.ui_label(title, "h2"))
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiDesign.SP_2)
	vb.add_child(body)
	return body


## 分区:VBox(SP_2) + H2 标题;返回 body VBox。
static func section(parent: Control, title: String) -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", UiDesign.SP_2)
	parent.add_child(vb)
	if title != "":
		vb.add_child(UiDesign.ui_label(title, "h2"))
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiDesign.SP_2)
	vb.add_child(body)
	return body


## 列表行:Plain 面板 + 图标 + 标题/副标题两行;返回整行(调用方自行接 gui_input/按钮)。
static func list_row(parent: Control, icon: Texture2D, title: String, subtitle: String) -> PanelContainer:
	var panel := UiDesign.ui_panel("plain")
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(panel)
	var barrier := MarginContainer.new()
	barrier.add_theme_constant_override("margin_left", UiDesign.SP_3)
	barrier.add_theme_constant_override("margin_right", UiDesign.SP_3)
	barrier.add_theme_constant_override("margin_top", UiDesign.SP_2)
	barrier.add_theme_constant_override("margin_bottom", UiDesign.SP_2)
	panel.add_child(barrier)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiDesign.SP_3)
	barrier.add_child(row)
	if icon != null:
		var tex := TextureRect.new()
		tex.texture = icon
		tex.custom_minimum_size = Vector2(UiDesign.SP_7, UiDesign.SP_6)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		row.add_child(tex)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	row.add_child(info)
	info.add_child(UiDesign.ui_label(title, "body"))
	if subtitle != "":
		info.add_child(UiDesign.ui_label(subtitle, "dim"))
	return panel


## 创建使用 Kit 主题变体的对话框。调用方填充内容并按需显示。
static func dialog(parent: Node, title: String, ok_text: String = "确定") -> AcceptDialog:
	var d := AcceptDialog.new()
	d.title = title
	d.ok_button_text = ok_text
	d.theme_type_variation = &"Kit"
	parent.add_child(d)
	return d


## 水平分隔线(SP_4 粗细的占位,不画线;需要线用 HSeparator)。
static func gap(parent: Control, h: int = 0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h if h > 0 else UiDesign.SP_1)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(c)
	return c
